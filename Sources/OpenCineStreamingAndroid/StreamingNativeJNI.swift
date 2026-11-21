// JNI exports of the Kotlin class com.opencapture.opencine.streaming.StreamingNative (Android
// `:streaming`). The class name, package and member names are the native contract: change both
// sides in step and compare `llvm-nm -D` of an app's `.so` with the `external fun`s. Coarse
// boundary: strings, byte arrays and primitives only. Every run call returns the binary reply
// `StreamRunWire` documents. Compiles empty on Darwin.
#if os(Android)

    import Foundation
    import OpenCineJNISupport

    /// The largest single media input: one H.264 access unit or one AAC frame.
    private let maximumMediaBytes = 8 * 1024 * 1024

    private func reply(_ env: UnsafeMutablePointer<JNIEnv?>, _ bytes: [UInt8]) -> jbyteArray? {
        javaByteArray(env, bytes)
    }

    private func ended(_ env: UnsafeMutablePointer<JNIEnv?>) -> jbyteArray? {
        javaByteArray(env, StreamRunWire.shared.stop(owner: "", nowNs: 0))
    }

    /// `StreamingNative.create(presetId, enteredServerUrl, streamKey, formatJson, nowNs): String`.
    @_cdecl("Java_com_opencapture_opencine_streaming_StreamingNative_create")
    public func streamingNativeCreate(
        _ env: UnsafeMutablePointer<JNIEnv?>, _: jobject?, presetID: jstring?, enteredServerURL: jstring?,
        streamKey: jstring?, formatJSON: jstring?, nowNs: jlong
    ) -> jstring? {
        guard let preset = swiftString(env, presetID), let key = swiftString(env, streamKey),
            let format = swiftString(env, formatJSON)
        else { return javaString(env, #"{"error":"invalidServerURL"}"#) }
        let server = swiftString(env, enteredServerURL) ?? ""
        return javaString(
            env,
            StreamRunWire.shared.create(
                presetID: preset, enteredServerURL: server, streamKey: key, formatJSON: format, nowNs: nowNs))
    }

    /// `StreamingNative.start(owner): ByteArray`.
    @_cdecl("Java_com_opencapture_opencine_streaming_StreamingNative_start")
    public func streamingNativeStart(
        _ env: UnsafeMutablePointer<JNIEnv?>, _: jobject?, owner: jstring?
    ) -> jbyteArray? {
        guard let owner = swiftString(env, owner) else { return ended(env) }
        return reply(env, StreamRunWire.shared.start(owner: owner))
    }

    /// `StreamingNative.connected(owner, nowNs): ByteArray`.
    @_cdecl("Java_com_opencapture_opencine_streaming_StreamingNative_connected")
    public func streamingNativeConnected(
        _ env: UnsafeMutablePointer<JNIEnv?>, _: jobject?, owner: jstring?, nowNs: jlong
    ) -> jbyteArray? {
        guard let owner = swiftString(env, owner) else { return ended(env) }
        return reply(env, StreamRunWire.shared.connected(owner: owner, nowNs: nowNs))
    }

    /// `StreamingNative.received(owner, bytes, nowNs): ByteArray`.
    @_cdecl("Java_com_opencapture_opencine_streaming_StreamingNative_received")
    public func streamingNativeReceived(
        _ env: UnsafeMutablePointer<JNIEnv?>, _: jobject?, owner: jstring?, bytes: jbyteArray?, nowNs: jlong
    ) -> jbyteArray? {
        guard let owner = swiftString(env, owner),
            let bytes = swiftBytes(env, bytes, maximumCount: maximumMediaBytes)
        else { return ended(env) }
        return reply(env, StreamRunWire.shared.received(owner: owner, bytes: bytes, nowNs: nowNs))
    }

    /// `StreamingNative.connectionLost(owner, nowNs): ByteArray`.
    @_cdecl("Java_com_opencapture_opencine_streaming_StreamingNative_connectionLost")
    public func streamingNativeConnectionLost(
        _ env: UnsafeMutablePointer<JNIEnv?>, _: jobject?, owner: jstring?, nowNs: jlong
    ) -> jbyteArray? {
        guard let owner = swiftString(env, owner) else { return ended(env) }
        return reply(env, StreamRunWire.shared.connectionLost(owner: owner, nowNs: nowNs))
    }

    /// `StreamingNative.wrote(owner, count, nowNs): ByteArray`.
    @_cdecl("Java_com_opencapture_opencine_streaming_StreamingNative_wrote")
    public func streamingNativeWrote(
        _ env: UnsafeMutablePointer<JNIEnv?>, _: jobject?, owner: jstring?, count: jint, nowNs: jlong
    ) -> jbyteArray? {
        guard let owner = swiftString(env, owner), count >= 0 else { return ended(env) }
        return reply(env, StreamRunWire.shared.wrote(owner: owner, count: Int(count), nowNs: nowNs))
    }

    /// `StreamingNative.tick(owner, nowNs): ByteArray`.
    @_cdecl("Java_com_opencapture_opencine_streaming_StreamingNative_tick")
    public func streamingNativeTick(
        _ env: UnsafeMutablePointer<JNIEnv?>, _: jobject?, owner: jstring?, nowNs: jlong
    ) -> jbyteArray? {
        guard let owner = swiftString(env, owner) else { return ended(env) }
        return reply(env, StreamRunWire.shared.tick(owner: owner, nowNs: nowNs))
    }

    /// `StreamingNative.stop(owner, nowNs): ByteArray`.
    @_cdecl("Java_com_opencapture_opencine_streaming_StreamingNative_stop")
    public func streamingNativeStop(
        _ env: UnsafeMutablePointer<JNIEnv?>, _: jobject?, owner: jstring?, nowNs: jlong
    ) -> jbyteArray? {
        guard let owner = swiftString(env, owner) else { return ended(env) }
        return reply(env, StreamRunWire.shared.stop(owner: owner, nowNs: nowNs))
    }

    /// `StreamingNative.publishVideoConfig(owner, sps, pps, nowNs): ByteArray`.
    @_cdecl("Java_com_opencapture_opencine_streaming_StreamingNative_publishVideoConfig")
    public func streamingNativePublishVideoConfig(
        _ env: UnsafeMutablePointer<JNIEnv?>, _: jobject?, owner: jstring?, sps: jbyteArray?, pps: jbyteArray?,
        nowNs: jlong
    ) -> jbyteArray? {
        guard let owner = swiftString(env, owner), let sps = swiftBytes(env, sps, maximumCount: 65_535),
            let pps = swiftBytes(env, pps, maximumCount: 65_535)
        else { return ended(env) }
        return reply(env, StreamRunWire.shared.publishVideoConfig(owner: owner, sps: sps, pps: pps, nowNs: nowNs))
    }

    /// `StreamingNative.publishVideo(owner, annexB, isKeyframe, decodeMs, presentMs, nowNs): ByteArray`.
    @_cdecl("Java_com_opencapture_opencine_streaming_StreamingNative_publishVideo")
    public func streamingNativePublishVideo(
        _ env: UnsafeMutablePointer<JNIEnv?>, _: jobject?, owner: jstring?, annexB: jbyteArray?,
        isKeyframe: jboolean, decodeMs: jint, presentMs: jint, nowNs: jlong
    ) -> jbyteArray? {
        guard let owner = swiftString(env, owner),
            let annexB = swiftBytes(env, annexB, maximumCount: maximumMediaBytes)
        else { return ended(env) }
        return reply(
            env,
            StreamRunWire.shared.publishVideo(
                owner: owner, annexB: annexB, isKeyframe: isKeyframe != 0,
                decodeMs: UInt32(bitPattern: decodeMs), presentMs: UInt32(bitPattern: presentMs), nowNs: nowNs))
    }

    /// `StreamingNative.publishAudioConfig(owner, audioSpecificConfig, nowNs): ByteArray`.
    @_cdecl("Java_com_opencapture_opencine_streaming_StreamingNative_publishAudioConfig")
    public func streamingNativePublishAudioConfig(
        _ env: UnsafeMutablePointer<JNIEnv?>, _: jobject?, owner: jstring?, audioSpecificConfig: jbyteArray?,
        nowNs: jlong
    ) -> jbyteArray? {
        guard let owner = swiftString(env, owner),
            let config = swiftBytes(env, audioSpecificConfig, maximumCount: 64)
        else { return ended(env) }
        return reply(
            env, StreamRunWire.shared.publishAudioConfig(owner: owner, audioSpecificConfig: config, nowNs: nowNs))
    }

    /// `StreamingNative.publishAudio(owner, raw, presentMs, nowNs): ByteArray`.
    @_cdecl("Java_com_opencapture_opencine_streaming_StreamingNative_publishAudio")
    public func streamingNativePublishAudio(
        _ env: UnsafeMutablePointer<JNIEnv?>, _: jobject?, owner: jstring?, raw: jbyteArray?, presentMs: jint,
        nowNs: jlong
    ) -> jbyteArray? {
        guard let owner = swiftString(env, owner), let raw = swiftBytes(env, raw, maximumCount: 65_536)
        else { return ended(env) }
        return reply(
            env,
            StreamRunWire.shared.publishAudio(
                owner: owner, raw: raw, presentMs: UInt32(bitPattern: presentMs), nowNs: nowNs))
    }

    /// `StreamingNative.close(owner): Unit` retires the run.
    @_cdecl("Java_com_opencapture_opencine_streaming_StreamingNative_close")
    public func streamingNativeClose(_ env: UnsafeMutablePointer<JNIEnv?>, _: jobject?, owner: jstring?) {
        if let owner = swiftString(env, owner) { StreamRunWire.shared.close(owner: owner) }
    }

    /// `StreamingNative.presets(): String` (JSON array).
    @_cdecl("Java_com_opencapture_opencine_streaming_StreamingNative_presets")
    public func streamingNativePresets(_ env: UnsafeMutablePointer<JNIEnv?>, _: jobject?) -> jstring? {
        javaString(env, StreamRunWire.shared.presetsJSON())
    }

    /// `StreamingNative.format(presetId, width, height, fpsNum, fpsDen, connected): String?`.
    @_cdecl("Java_com_opencapture_opencine_streaming_StreamingNative_format")
    public func streamingNativeFormat(
        _ env: UnsafeMutablePointer<JNIEnv?>, _: jobject?, presetID: jstring?, width: jint, height: jint,
        fpsNum: jint, fpsDen: jint, connected: jintArray?
    ) -> jstring? {
        outputFormat(env, presetID, width, height, fpsNum, fpsDen, connected, choice: nil)
    }

    /// `StreamingNative.formatFor(presetId, width, height, fpsNum, fpsDen, connected, choice): String?`.
    @_cdecl("Java_com_opencapture_opencine_streaming_StreamingNative_formatFor")
    public func streamingNativeFormatFor(
        _ env: UnsafeMutablePointer<JNIEnv?>, _: jobject?, presetID: jstring?, width: jint, height: jint,
        fpsNum: jint, fpsDen: jint, connected: jintArray?, choice: jstring?
    ) -> jstring? {
        outputFormat(env, presetID, width, height, fpsNum, fpsDen, connected, choice: swiftString(env, choice) ?? "")
    }

    private func outputFormat(
        _ env: UnsafeMutablePointer<JNIEnv?>, _ presetID: jstring?, _ width: jint, _ height: jint,
        _ fpsNum: jint, _ fpsDen: jint, _ connected: jintArray?, choice: String?
    ) -> jstring? {
        guard let preset = swiftString(env, presetID) else { return nil }
        var sizes: [Int32] = []
        if let connected {
            let fns = table(env)
            let length = Int(fns.GetArrayLength!(env, connected))
            guard length >= 0, length <= 64 else { return nil }
            sizes = [Int32](repeating: 0, count: length)
            if length > 0 {
                sizes.withUnsafeMutableBufferPointer { buffer in
                    fns.GetIntArrayRegion!(env, connected, 0, jsize(length), buffer.baseAddress)
                }
            }
        }
        guard
            let json = StreamRunWire.shared.formatJSON(
                presetID: preset, selectedWidth: Int(width), selectedHeight: Int(height), fpsNum: Int(fpsNum),
                fpsDen: Int(fpsDen), connected: sizes, choice: choice ?? "cameraFeed")
        else { return nil }
        return javaString(env, json)
    }

    /// `StreamingNative.checkDestination(presetId, enteredServerUrl, streamKey): String` (JSON).
    @_cdecl("Java_com_opencapture_opencine_streaming_StreamingNative_checkDestination")
    public func streamingNativeCheckDestination(
        _ env: UnsafeMutablePointer<JNIEnv?>, _: jobject?, presetID: jstring?, enteredServerURL: jstring?,
        streamKey: jstring?
    ) -> jstring? {
        let preset = swiftString(env, presetID) ?? ""
        let server = swiftString(env, enteredServerURL) ?? ""
        let key = swiftString(env, streamKey) ?? ""
        return javaString(
            env,
            StreamRunWire.shared.checkDestination(presetID: preset, enteredServerURL: server, streamKey: key))
    }

    /// `StreamingNative.canStream(route): Boolean`.
    @_cdecl("Java_com_opencapture_opencine_streaming_StreamingNative_canStream")
    public func streamingNativeCanStream(
        _ env: UnsafeMutablePointer<JNIEnv?>, _: jobject?, route: jstring?
    ) -> jboolean {
        guard let route = swiftString(env, route) else { return 0 }
        return StreamRunWire.shared.canStream(route: route) ? 1 : 0
    }

#endif
