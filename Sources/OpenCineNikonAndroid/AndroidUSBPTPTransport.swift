#if os(Android)

    import OpenCineJNISupport
    import Foundation

    /// Swift-side owner for the Kotlin `UsbPtpTransport` global reference.
    ///
    /// Kotlin vends only raw endpoint reads/writes. This class attaches a
    /// Swift-owned thread to the JVM for each call, carefully preserving a
    /// Kotlin-owned caller thread when a close originates from JNI.
    final class JNIUSBPTPTransportHandle: @unchecked Sendable, USBPTPRawIO {
        private let vm: UnsafeMutablePointer<JavaVM?>
        private let writeBulkMethod: jmethodID
        private let readBulkMethod: jmethodID
        private let readEventMethod: jmethodID
        private let isClosedMethod: jmethodID
        private let closeMethod: jmethodID
        private let lock = NSLock()
        private var transport: jobject?
        /// Calls currently using the JNI global reference outside [lock].
        private var activeCalls = 0
        /// Once set, no new endpoint call may begin; existing calls finish or
        /// are interrupted by Kotlin's concurrent `close()` implementation.
        private var closeRequested = false
        /// The Java/Kotlin close call must finish before its global reference
        /// can be released from the last in-flight endpoint call.
        private var closeDelivered = false

        init?(
            env: UnsafeMutablePointer<JNIEnv?>,
            transport: jobject?
        ) {
            let fns = table(env)
            var vm: UnsafeMutablePointer<JavaVM?>?
            guard fns.GetJavaVM!(env, &vm) == JNI_OK,
                let vm,
                let transport,
                let global = fns.NewGlobalRef!(env, transport)
            else {
                return nil
            }
            guard let type = fns.GetObjectClass!(env, global) else {
                fns.DeleteGlobalRef!(env, global)
                return nil
            }
            defer { fns.DeleteLocalRef!(env, type) }
            // Resolve each method independently and clear a pending
            // NoSuchMethodError on miss. Without ExceptionClear, a single
            // missing (e.g. R8-stripped) method crashes the Kotlin caller of
            // sessionConnectUsb even though this initializer returns nil.
            guard
                let writeBulkMethod = instanceMethod(
                    env, type, "writeBulk", "([BI)I"),
                let readBulkMethod = instanceMethod(
                    env, type, "readBulk", "(II)[B"),
                let readEventMethod = instanceMethod(
                    env, type, "readEvent", "(II)[B"),
                let isClosedMethod = instanceMethod(
                    env, type, "isClosed", "()Z"),
                let closeMethod = instanceMethod(env, type, "close", "()V")
            else {
                fns.DeleteGlobalRef!(env, global)
                return nil
            }
            self.vm = vm
            self.transport = global
            self.writeBulkMethod = writeBulkMethod
            self.readBulkMethod = readBulkMethod
            self.readEventMethod = readEventMethod
            self.isClosedMethod = isClosedMethod
            self.closeMethod = closeMethod
        }

        func writeBulk(_ bytes: [UInt8], timeoutMilliseconds: Int) -> Int? {
            invoke { env, reference in
                guard let array = javaByteArray(env, bytes) else { return nil }
                defer { table(env).DeleteLocalRef!(env, array) }
                var arguments = [
                    jvalue(l: array),
                    jvalue(i: jint(timeoutMilliseconds)),
                ]
                return Int(
                    table(env).CallIntMethodA!(
                        env, reference, writeBulkMethod, &arguments))
            }
        }

        func readBulk(maxBytes: Int, timeoutMilliseconds: Int) -> [UInt8]? {
            read(
                method: readBulkMethod,
                maxBytes: maxBytes,
                timeoutMilliseconds: timeoutMilliseconds
            )
        }

        func readEvent(maxBytes: Int, timeoutMilliseconds: Int) -> [UInt8]? {
            read(
                method: readEventMethod,
                maxBytes: maxBytes,
                timeoutMilliseconds: timeoutMilliseconds
            )
        }

        func isClosed() -> Bool {
            invoke { env, reference in
                var arguments = jvalue()
                return table(env).CallBooleanMethodA!(
                    env, reference, isClosedMethod, &arguments) != 0
            } ?? true
        }

        func close() {
            lock.lock()
            guard let reference = transport, !closeRequested else {
                lock.unlock()
                return
            }
            closeRequested = true
            lock.unlock()
            withEnvironment { env in
                let fns = table(env)
                var arguments = jvalue()
                fns.CallVoidMethodA!(env, reference, closeMethod, &arguments)
            }
            lock.lock()
            closeDelivered = true
            let releasedReference = releaseReferenceIfReadyLocked()
            lock.unlock()
            deleteGlobalReference(releasedReference)
        }

        private func read(
            method: jmethodID,
            maxBytes: Int,
            timeoutMilliseconds: Int
        ) -> [UInt8]? {
            invoke { env, reference in
                var arguments = [
                    jvalue(i: jint(maxBytes)),
                    jvalue(i: jint(timeoutMilliseconds)),
                ]
                guard
                    let array = table(env).CallObjectMethodA!(
                        env, reference, method, &arguments)
                else {
                    return nil
                }
                defer { table(env).DeleteLocalRef!(env, array) }
                return swiftBytes(env, array)
            }
        }

        private func invoke<Result>(
            _ body: (UnsafeMutablePointer<JNIEnv?>, jobject) -> Result?
        ) -> Result? {
            lock.lock()
            guard !closeRequested, let reference = transport else {
                lock.unlock()
                return nil
            }
            activeCalls += 1
            lock.unlock()

            // Do not hold [lock] around a JNI endpoint call. A USB bulk read
            // can block until its timeout; holding this lock would prevent
            // `close()` from reaching Kotlin to cancel/release that read.
            let result = withEnvironment { env in body(env, reference) }

            lock.lock()
            activeCalls -= 1
            let releasedReference = releaseReferenceIfReadyLocked()
            lock.unlock()
            deleteGlobalReference(releasedReference)
            return result
        }

        /// Returns the global ref only after close reached Kotlin and no JNI
        /// endpoint call can still use it. Caller must hold [lock].
        private func releaseReferenceIfReadyLocked() -> jobject? {
            guard closeRequested, closeDelivered, activeCalls == 0 else { return nil }
            let reference = transport
            transport = nil
            return reference
        }

        private func deleteGlobalReference(_ reference: jobject?) {
            guard let reference else { return }
            _ = withEnvironment { env in
                table(env).DeleteGlobalRef!(env, reference)
                return ()
            }
        }

        private func withEnvironment<Result>(
            _ body: (UnsafeMutablePointer<JNIEnv?>) -> Result?
        ) -> Result? {
            // SAFETY: JavaVM is supplied by the JVM at JNI entry and its invoke
            // table remains valid while the process owns this global reference.
            let invoke = vm.pointee!.pointee
            var rawEnvironment: UnsafeMutableRawPointer?
            let environmentStatus = invoke.GetEnv!(vm, &rawEnvironment, JNI_VERSION_1_6)
            let environment: UnsafeMutablePointer<JNIEnv?>?
            let attachedHere: Bool
            if environmentStatus == JNI_EDETACHED {
                var attachedEnvironment: UnsafeMutablePointer<JNIEnv?>?
                guard invoke.AttachCurrentThread!(vm, &attachedEnvironment, nil) == JNI_OK else {
                    return nil
                }
                environment = attachedEnvironment
                attachedHere = true
            } else {
                guard environmentStatus == JNI_OK, let rawEnvironment else { return nil }
                environment = rawEnvironment.assumingMemoryBound(to: JNIEnv?.self)
                attachedHere = false
            }
            defer {
                if attachedHere {
                    _ = invoke.DetachCurrentThread!(vm)
                }
            }
            guard let env = environment else { return nil }
            return body(env)
        }
    }

#endif
