// JNI plumbing shared by the Swift JNI facades (the apps' Android libraries and the
// integration facades in this package): env table access and copies between JVM and Swift
// values. Coarse boundary rules apply: strings, byte arrays and primitive arrays only.
//
// Moved from OpenZCine's Android facade (SwiftCoreJNI.swift). Compiles empty on Darwin.
@_exported import OpenCineJNI

#if os(Android)

    // MARK: - JNI plumbing

    /// Returns the JNI function table for an env handle.
    ///
    /// SAFETY: The JVM always passes a non-nil env with a fully populated
    /// function table to native methods (JNI spec); the same guarantee applies to
    /// every function-pointer slot force-unwrapped below.
    public func table(_ env: UnsafeMutablePointer<JNIEnv?>) -> JNINativeInterface {
        env.pointee!.pointee
    }

    /// Converts a Swift string to a JVM-owned `jstring` local reference.
    public func javaString(
        _ env: UnsafeMutablePointer<JNIEnv?>, _ value: String
    ) -> jstring? {
        value.withCString { table(env).NewStringUTF!(env, $0) }
    }

    /// Copies a `jstring` into a Swift `String`.
    public func swiftString(
        _ env: UnsafeMutablePointer<JNIEnv?>, _ value: jstring?
    ) -> String? {
        guard let value,
            let chars = table(env).GetStringUTFChars!(env, value, nil)
        else { return nil }
        defer { table(env).ReleaseStringUTFChars!(env, value, chars) }
        return String(cString: chars)
    }

    /// Copies a `jbyteArray` into a Swift `[UInt8]`.
    public func swiftBytes(
        _ env: UnsafeMutablePointer<JNIEnv?>, _ value: jbyteArray?, maximumCount: Int? = nil
    ) -> [UInt8]? {
        guard let value else { return nil }
        let fns = table(env)
        let length = Int(fns.GetArrayLength!(env, value))
        guard length >= 0 else { return nil }
        guard maximumCount.map({ length <= $0 }) ?? true else { return nil }
        guard length > 0 else { return [] }
        var out = [UInt8](repeating: 0, count: length)
        out.withUnsafeMutableBytes { raw in
            fns.GetByteArrayRegion!(
                env, value, 0, jsize(length),
                raw.baseAddress?.assumingMemoryBound(to: jbyte.self))
        }
        return out
    }

    /// Copies a Swift byte buffer into a new JVM `byte[]` local reference.
    public func javaByteArray(
        _ env: UnsafeMutablePointer<JNIEnv?>, _ bytes: [UInt8]
    ) -> jbyteArray? {
        let fns = table(env)
        guard let array = fns.NewByteArray!(env, jsize(bytes.count)) else { return nil }
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            fns.SetByteArrayRegion!(
                env, array, 0, jsize(bytes.count), base.assumingMemoryBound(to: jbyte.self))
        }
        return array
    }

    /// Copies unsigned PTP values (represented losslessly as signed Int64s)
    /// into a JVM-owned `long[]` local reference.
    public func javaLongArray(
        _ env: UnsafeMutablePointer<JNIEnv?>, _ values: [Int64]
    ) -> jlongArray? {
        let fns = table(env)
        guard let array = fns.NewLongArray!(env, jsize(values.count)) else { return nil }
        values.withUnsafeBufferPointer { buffer in
            fns.SetLongArrayRegion!(env, array, 0, jsize(values.count), buffer.baseAddress)
        }
        return array
    }

    /// Copies a Swift `Int32` buffer into a JVM-owned `int[]` local reference.
    public func javaIntArray(
        _ env: UnsafeMutablePointer<JNIEnv?>, _ values: [Int32]
    ) -> jintArray? {
        let fns = table(env)
        guard let array = fns.NewIntArray!(env, jsize(values.count)) else { return nil }
        values.withUnsafeBufferPointer { buffer in
            fns.SetIntArrayRegion!(env, array, 0, jsize(values.count), buffer.baseAddress)
        }
        return array
    }

    /// Copies a Swift float buffer into a new JVM `float[]` local reference.
    public func javaFloatArray(
        _ env: UnsafeMutablePointer<JNIEnv?>, _ values: [Float]
    ) -> jfloatArray? {
        let fns = table(env)
        guard let array = fns.NewFloatArray!(env, jsize(values.count)) else { return nil }
        values.withUnsafeBufferPointer { buffer in
            fns.SetFloatArrayRegion!(env, array, 0, jsize(values.count), buffer.baseAddress)
        }
        return array
    }

    /// Copies a bounded JVM `float[]` into Swift-owned storage.
    public func swiftFloats(
        _ env: UnsafeMutablePointer<JNIEnv?>, _ value: jfloatArray?, maximumCount: Int
    ) -> [Float]? {
        guard let value else { return nil }
        let fns = table(env)
        let length = Int(fns.GetArrayLength!(env, value))
        guard length <= maximumCount else { return nil }
        guard length > 0 else { return [] }
        var values = [Float](repeating: 0, count: length)
        values.withUnsafeMutableBufferPointer { buffer in
            fns.GetFloatArrayRegion!(env, value, 0, jsize(length), buffer.baseAddress)
        }
        return values
    }

    /// Looks up an instance method and clears a missing-method exception. The caller decides
    /// whether an absent method is acceptable or makes its adapter unavailable.
    public func instanceMethod(
        _ env: UnsafeMutablePointer<JNIEnv?>, _ type: jclass?,
        _ name: String, _ signature: String
    ) -> jmethodID? {
        let fns = table(env)
        let method = name.withCString { namePointer in
            signature.withCString { signaturePointer in
                fns.GetMethodID!(env, type, namePointer, signaturePointer)
            }
        }
        if method == nil { fns.ExceptionClear!(env) }
        return method
    }

    /// Resolves an additive listener callback while preserving the legacy-descriptor fallback.
    public func optionalInstanceMethod(
        _ env: UnsafeMutablePointer<JNIEnv?>, _ type: jclass?,
        _ name: String, _ signature: String
    ) -> jmethodID? {
        instanceMethod(env, type, name, signature)
    }

#endif
