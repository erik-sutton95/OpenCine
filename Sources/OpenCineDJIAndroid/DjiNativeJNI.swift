// JNI exports behind OpenCine's Kotlin `com.opencapture.opencine.dji.DjiNative` (Android/dji).
//
// Hand-written `@_cdecl` shims; each name is `Java_com_opencapture_opencine_dji_DjiNative_<external
// fun>`, so the Kotlin class name is part of the contract. An app links this target (product
// OpenCineDJIAndroid) into its Swift Android library and the exports ship in that `.so`.
// Coarse boundary: strings, byte arrays and primitives only. Compiles empty on Darwin.
#if os(Android)

    import OpenCineJNISupport
    import Foundation
    import OpenCineDJI

    private final class DepacketizerStore: @unchecked Sendable {
        let lock = NSLock()
        var boxes: [Int64: HevcDepacketizerBox] = [:]
        var next: Int64 = 1
    }

    private let depacketizerStore = DepacketizerStore()

    // MARK: - DJI wire

    @_cdecl("Java_com_opencapture_opencine_dji_DjiNative_encodeDuml")
    public func swiftCoreEncodeDuml(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?,
        sender: jint, receiver: jint, seq: jint, flags: jint,
        cmdSet: jint, cmdId: jint, payload: jbyteArray?
    ) -> jbyteArray? {
        let frame = Duml.Frame(
            sender: UInt8(truncatingIfNeeded: sender),
            receiver: UInt8(truncatingIfNeeded: receiver),
            seq: UInt16(truncatingIfNeeded: seq),
            flags: UInt8(truncatingIfNeeded: flags),
            cmdSet: UInt8(truncatingIfNeeded: cmdSet),
            cmdId: UInt8(truncatingIfNeeded: cmdId),
            payload: swiftBytes(env, payload) ?? []
        )
        return javaByteArray(env, Duml.encode(frame))
    }

    @_cdecl("Java_com_opencapture_opencine_dji_DjiNative_scanDuml")
    public func swiftCoreScanDuml(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?, data: jbyteArray?
    ) -> jbyteArray? {
        guard let bytes = swiftBytes(env, data) else { return javaByteArray(env, [0, 0]) }
        return javaByteArray(env, DjiNativeWire.packFrames(DumlTransport.scanFrames(bytes)))
    }

    @_cdecl("Java_com_opencapture_opencine_dji_DjiNative_unpackStatusString")
    public func swiftCoreUnpackStatusString(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?, payload: jbyteArray?
    ) -> jstring? {
        javaString(env, Duml.unpackStatusString(swiftBytes(env, payload) ?? []))
    }

    @_cdecl("Java_com_opencapture_opencine_dji_DjiNative_encodeCommand")
    public func swiftCoreEncodeCommand(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?,
        kind: jint, seq: jint, extra: jstring?
    ) -> jbyteArray? {
        guard let commandKind = DjiNativeWire.CommandKind(rawValue: kind) else { return nil }
        guard
            let frame = DjiNativeWire.encodeCommand(
                kind: commandKind,
                seq: UInt16(truncatingIfNeeded: seq),
                extra: swiftString(env, extra)
            )
        else { return nil }
        return javaByteArray(env, Duml.encode(frame))
    }

    @_cdecl("Java_com_opencapture_opencine_dji_DjiNative_bleAdvertModelId")
    public func swiftCoreBleAdvertModelId(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?, payload: jbyteArray?
    ) -> jint {
        guard let bytes = swiftBytes(env, payload), let id = BleAdvert.modelId(bytes) else {
            return -1
        }
        return jint(id)
    }

    @_cdecl("Java_com_opencapture_opencine_dji_DjiNative_resolveCameraModel")
    public func swiftCoreResolveCameraModel(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?,
        modelId: jint, name: jstring?, address: jstring?, djiCid: jboolean
    ) -> jstring? {
        let id: Int? = modelId < 0 ? nil : Int(modelId)
        return javaString(
            env,
            DjiNativeWire.cameraModelJSON(
                modelId: id, name: swiftString(env, name),
                address: swiftString(env, address), djiCid: djiCid != 0))
    }

    @_cdecl("Java_com_opencapture_opencine_dji_DjiNative_transportHeader")
    public func swiftCoreTransportHeader(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?,
        pktType: jint, payloadLen: jint, sessionId: jint, seq: jint
    ) -> jbyteArray? {
        javaByteArray(
            env,
            DumlTransport.transportHeader(
                pktType: UInt8(truncatingIfNeeded: pktType),
                payloadLen: Int(payloadLen),
                sessionId: UInt16(truncatingIfNeeded: sessionId),
                seq: UInt16(truncatingIfNeeded: seq)
            )
        )
    }

    @_cdecl("Java_com_opencapture_opencine_dji_DjiNative_routingHeader")
    public func swiftCoreRoutingHeader(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?,
        seq: jint, cmdCounter: jint, drone: jboolean
    ) -> jbyteArray? {
        javaByteArray(
            env,
            DumlTransport.routingHeader(
                seq: UInt16(truncatingIfNeeded: seq),
                cmdCounter: UInt8(truncatingIfNeeded: cmdCounter),
                drone: drone != 0
            )
        )
    }

    @_cdecl("Java_com_opencapture_opencine_dji_DjiNative_handshakePayload")
    public func swiftCoreHandshakePayload(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?, baseSeq: jint
    ) -> jbyteArray? {
        javaByteArray(
            env, DumlTransport.handshakePayload(baseSeq: UInt16(truncatingIfNeeded: baseSeq)))
    }

    @_cdecl("Java_com_opencapture_opencine_dji_DjiNative_ackPayload")
    public func swiftCoreAckPayload(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?,
        peerCursor: jint, ackedDataCursor: jint, extraCursor: jint
    ) -> jbyteArray? {
        javaByteArray(
            env,
            DumlTransport.ackPayload(
                peerCursor: UInt16(truncatingIfNeeded: peerCursor),
                ackedDataCursor: UInt16(truncatingIfNeeded: ackedDataCursor),
                extraCursor: UInt16(truncatingIfNeeded: extraCursor)
            )
        )
    }

    @_cdecl("Java_com_opencapture_opencine_dji_DjiNative_transportSeq")
    public func swiftCoreTransportSeq(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?, datagram: jbyteArray?
    ) -> jint {
        guard let bytes = swiftBytes(env, datagram),
            let seq = DumlTransport.transportSeq(bytes)
        else { return -1 }
        return jint(seq)
    }

    @_cdecl("Java_com_opencapture_opencine_dji_DjiNative_applyStatus")
    public func swiftCoreApplyStatus(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?,
        cmdSet: jint, cmdId: jint, payload: jbyteArray?, previousJSON: jstring?
    ) -> jstring? {
        let frame = Duml.Frame(
            sender: 0,
            receiver: 0,
            seq: 0,
            flags: 0,
            cmdSet: UInt8(truncatingIfNeeded: cmdSet),
            cmdId: UInt8(truncatingIfNeeded: cmdId),
            payload: swiftBytes(env, payload) ?? []
        )
        // Recognition depends only on the frame, so reject non-status frames before copying
        // and parsing the previous status.
        var probe = CameraStatus()
        guard CameraStatusDecoder.apply(frame, to: &probe) else { return nil }
        var status = DjiNativeWire.status(fromJSON: swiftString(env, previousJSON) ?? "{}")
        CameraStatusDecoder.apply(frame, to: &status)
        return javaString(env, DjiNativeWire.statusJSON(status))
    }

    @_cdecl("Java_com_opencapture_opencine_dji_DjiNative_depacketizerCreate")
    public func swiftCoreDepacketizerCreate(
        env _: UnsafeMutablePointer<JNIEnv?>, this _: jobject?
    ) -> jlong {
        depacketizerStore.lock.lock()
        defer { depacketizerStore.lock.unlock() }
        let handle = depacketizerStore.next
        depacketizerStore.next += 1
        depacketizerStore.boxes[handle] = HevcDepacketizerBox()
        return handle
    }

    @_cdecl("Java_com_opencapture_opencine_dji_DjiNative_depacketizerFeed")
    public func swiftCoreDepacketizerFeed(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?,
        handle: jlong, payload: jbyteArray?
    ) -> jbyteArray? {
        guard let bytes = swiftBytes(env, payload) else { return nil }
        depacketizerStore.lock.lock()
        guard let box = depacketizerStore.boxes[handle] else {
            depacketizerStore.lock.unlock()
            return nil
        }
        let completed = box.depacketizer.feed(bytes)
        depacketizerStore.lock.unlock()
        guard let completed else { return nil }
        return javaByteArray(env, completed)
    }

    @_cdecl("Java_com_opencapture_opencine_dji_DjiNative_depacketizerDropped")
    public func swiftCoreDepacketizerDropped(
        env _: UnsafeMutablePointer<JNIEnv?>, this _: jobject?, handle: jlong
    ) -> jint {
        depacketizerStore.lock.lock()
        defer { depacketizerStore.lock.unlock() }
        return jint(depacketizerStore.boxes[handle]?.depacketizer.droppedIncomplete ?? 0)
    }

    @_cdecl("Java_com_opencapture_opencine_dji_DjiNative_depacketizerReset")
    public func swiftCoreDepacketizerReset(
        env _: UnsafeMutablePointer<JNIEnv?>, this _: jobject?, handle: jlong
    ) {
        depacketizerStore.lock.lock()
        depacketizerStore.boxes[handle]?.depacketizer.reset()
        depacketizerStore.lock.unlock()
    }

    @_cdecl("Java_com_opencapture_opencine_dji_DjiNative_depacketizerDestroy")
    public func swiftCoreDepacketizerDestroy(
        env _: UnsafeMutablePointer<JNIEnv?>, this _: jobject?, handle: jlong
    ) {
        depacketizerStore.lock.lock()
        depacketizerStore.boxes.removeValue(forKey: handle)
        depacketizerStore.lock.unlock()
    }

    @_cdecl("Java_com_opencapture_opencine_dji_DjiNative_gimbalStickEncode")
    public func swiftCoreGimbalStickEncode(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?,
        x: jdouble, y: jdouble, invertPan: jboolean, sensitivity: jint
    ) -> jstring? {
        javaString(
            env,
            DjiNativeWire.gimbalStickEncode(
                x: Double(x), y: Double(y), invertPan: invertPan != 0,
                sensitivity: Int(sensitivity)))
    }

    @_cdecl("Java_com_opencapture_opencine_dji_DjiNative_camFovChipWrite")
    public func swiftCoreCamFovChipWrite(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?, currentFactor: jdouble
    ) -> jstring? {
        javaString(env, DjiNativeWire.camFovChipWrite(currentFactor: Double(currentFactor)))
    }

    @_cdecl("Java_com_opencapture_opencine_dji_DjiNative_feedWatchdogAction")
    public func swiftCoreFeedWatchdogAction(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?, snapshotJSON: jstring?
    ) -> jstring? {
        javaString(
            env,
            DjiNativeWire.feedWatchdogAction(
                snapshotJSON: swiftString(env, snapshotJSON) ?? "{}"))
    }

    @_cdecl("Java_com_opencapture_opencine_dji_DjiNative_feedWatchdogCreate")
    public func swiftCoreFeedWatchdogCreate(
        env _: UnsafeMutablePointer<JNIEnv?>, this _: jobject?
    ) -> jlong {
        jlong(DjiNativeWire.feedWatchdogCreate())
    }

    @_cdecl("Java_com_opencapture_opencine_dji_DjiNative_feedWatchdogTick")
    public func swiftCoreFeedWatchdogTick(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?,
        handle: jlong, snapshotJSON: jstring?
    ) -> jstring? {
        javaString(
            env,
            DjiNativeWire.feedWatchdogTick(
                handle: Int64(handle),
                snapshotJSON: swiftString(env, snapshotJSON) ?? "{}"))
    }

    @_cdecl("Java_com_opencapture_opencine_dji_DjiNative_feedWatchdogReset")
    public func swiftCoreFeedWatchdogReset(
        env _: UnsafeMutablePointer<JNIEnv?>, this _: jobject?, handle: jlong
    ) {
        DjiNativeWire.feedWatchdogReset(handle: Int64(handle))
    }

    @_cdecl("Java_com_opencapture_opencine_dji_DjiNative_feedWatchdogDestroy")
    public func swiftCoreFeedWatchdogDestroy(
        env _: UnsafeMutablePointer<JNIEnv?>, this _: jobject?, handle: jlong
    ) {
        DjiNativeWire.feedWatchdogDestroy(handle: Int64(handle))
    }

    @_cdecl("Java_com_opencapture_opencine_dji_DjiNative_cameraSoftAPDecision")
    public func swiftCoreCameraSoftAPDecision(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?,
        kind: jstring?, requestJSON: jstring?
    ) -> jstring? {
        javaString(
            env,
            DjiNativeWire.cameraSoftAPDecision(
                kind: swiftString(env, kind) ?? "",
                requestJSON: swiftString(env, requestJSON) ?? "{}"))
    }

    @_cdecl("Java_com_opencapture_opencine_dji_DjiNative_exposureLockDecision")
    public func swiftCoreExposureLockDecision(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?,
        kind: jstring?, requestJSON: jstring?
    ) -> jstring? {
        javaString(
            env,
            DjiNativeWire.exposureLockDecision(
                kind: swiftString(env, kind) ?? "",
                requestJSON: swiftString(env, requestJSON) ?? "{}"))
    }

    @_cdecl("Java_com_opencapture_opencine_dji_DjiNative_multicamDecision")
    public func swiftCoreMulticamDecision(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?,
        kind: jstring?, requestJSON: jstring?
    ) -> jstring? {
        javaString(
            env,
            DjiNativeWire.multicamDecision(
                kind: swiftString(env, kind) ?? "",
                requestJSON: swiftString(env, requestJSON) ?? "{}"))
    }

    @_cdecl("Java_com_opencapture_opencine_dji_DjiNative_multiviewRecoveryCreate")
    public func swiftCoreMultiviewRecoveryCreate(
        env _: UnsafeMutablePointer<JNIEnv?>, this _: jobject?
    ) -> jlong {
        jlong(DjiNativeWire.multiviewRecoveryCreate())
    }

    @_cdecl("Java_com_opencapture_opencine_dji_DjiNative_multiviewRecoveryCall")
    public func swiftCoreMultiviewRecoveryCall(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?,
        handle: jlong, op: jstring?, snapshotJSON: jstring?
    ) -> jstring? {
        javaString(
            env,
            DjiNativeWire.multiviewRecoveryCall(
                handle: Int64(handle), op: swiftString(env, op) ?? "",
                snapshotJSON: swiftString(env, snapshotJSON) ?? "{}"))
    }

    @_cdecl("Java_com_opencapture_opencine_dji_DjiNative_multiviewRecoveryDestroy")
    public func swiftCoreMultiviewRecoveryDestroy(
        env _: UnsafeMutablePointer<JNIEnv?>, this _: jobject?, handle: jlong
    ) {
        DjiNativeWire.multiviewRecoveryDestroy(handle: Int64(handle))
    }

#endif
