// JNI exports of the Kotlin class com.opencapture.opencine.frameio.FrameioNative (Android
// `:frameio`), moved from OpenZCine's Android facade so every app's Swift Android library links
// one Frame.io wire. The class name, package and member names are the native contract: change
// both sides in step and compare `llvm-nm -D` of an app's `.so` with the `external fun`s.
// Coarse boundary: strings and primitives only. Compiles empty on Darwin.
#if os(Android)

    import Foundation
    import OpenCineFrameIO
    import OpenCineJNISupport

    /// The digest result of one platform call; JNI work happens on the calling thread only.
    private final class FrameioDigestReply: @unchecked Sendable {
        var failed = false
    }

    /// SHA-256 through the Android platform digest: `FrameioNative.sha256(byte[]): byte[]` on the
    /// calling JNI object (`java.security.MessageDigest`). The PKCE injected digest contract.
    private func platformSHA256(
        _ env: UnsafeMutablePointer<JNIEnv?>, _ owner: jobject, _ input: Data
    ) -> Data? {
        let fns = table(env)
        guard let bytes = javaByteArray(env, Array(input)) else { return nil }
        defer { fns.DeleteLocalRef!(env, bytes) }
        guard let type = fns.GetObjectClass!(env, owner) else { return nil }
        defer { fns.DeleteLocalRef!(env, type) }
        guard let method = fns.GetMethodID!(env, type, "sha256", "([B)[B") else {
            if fns.ExceptionCheck!(env) != 0 { fns.ExceptionClear!(env) }
            return nil
        }
        var arguments = [jvalue(l: bytes)]
        let result = fns.CallObjectMethodA!(env, owner, method, &arguments)
        if fns.ExceptionCheck!(env) != 0 {
            fns.ExceptionClear!(env)
            return nil
        }
        guard let result else { return nil }
        defer { fns.DeleteLocalRef!(env, result) }
        guard let digest = swiftBytes(env, result, maximumCount: 32), digest.count == 32 else {
            return nil
        }
        return Data(digest)
    }

    /// `FrameioNative.beginAuthorization(clientID, redirectURI): String?` starts a shared-core
    /// PKCE transaction. The JSON wire contains a verifier: process-local, never logged.
    @_cdecl("Java_com_opencapture_opencine_frameio_FrameioNative_beginAuthorization")
    public func frameioNativeBeginAuthorization(
        env: UnsafeMutablePointer<JNIEnv?>, this: jobject?, clientID: jstring?,
        redirectURI: jstring?
    ) -> jstring? {
        guard
            let this,
            let clientID = swiftString(env, clientID),
            let redirectURI = swiftString(env, redirectURI)
        else { return nil }
        // The digest closure runs synchronously inside this native call, on this thread.
        nonisolated(unsafe) let env = env
        nonisolated(unsafe) let owner = this
        let reply = FrameioDigestReply()
        let payload = AndroidFrameioWire.beginAuthorization(
            clientID: clientID, redirectURI: redirectURI
        ) { input in
            guard let digest = platformSHA256(env, owner, input) else {
                reply.failed = true
                return Data()
            }
            return digest
        }
        guard !reply.failed, let payload else { return nil }
        return javaString(env, payload)
    }

    /// `FrameioNative.parseRedirect(redirectURI, callbackURI, expectedState): String?` validates
    /// exact redirect identity plus OAuth state and returns only the code. Never logged.
    @_cdecl("Java_com_opencapture_opencine_frameio_FrameioNative_parseRedirect")
    public func frameioNativeParseRedirect(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?, redirectURI: jstring?,
        callbackURI: jstring?, expectedState: jstring?
    ) -> jstring? {
        guard
            let redirectURI = swiftString(env, redirectURI),
            let callbackURI = swiftString(env, callbackURI),
            let expectedState = swiftString(env, expectedState),
            let code = AndroidFrameioWire.parseRedirect(
                redirectURI: redirectURI, callbackURI: callbackURI, expectedState: expectedState)
        else { return nil }
        return javaString(env, code)
    }

    /// `FrameioNative.tokenRequest(kind, clientID, redirectURI, code, verifier, refreshToken)`
    /// plans the shared Adobe IMS form request. The form can carry a code or refresh token.
    @_cdecl("Java_com_opencapture_opencine_frameio_FrameioNative_tokenRequest")
    public func frameioNativeTokenRequest(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?, kind: jstring?, clientID: jstring?,
        redirectURI: jstring?, code: jstring?, verifier: jstring?, refreshToken: jstring?
    ) -> jstring? {
        guard
            let kind = swiftString(env, kind),
            let clientID = swiftString(env, clientID),
            let redirectURI = swiftString(env, redirectURI),
            let payload = AndroidFrameioWire.tokenRequest(
                kind: kind, clientID: clientID, redirectURI: redirectURI,
                code: swiftString(env, code), verifier: swiftString(env, verifier),
                refreshToken: swiftString(env, refreshToken))
        else { return nil }
        return javaString(env, payload)
    }

    /// `FrameioNative.apiRequest(operation, accountID, workspaceID, folderID, fileID, name,
    /// fileSize): String?` plans one portable V4 endpoint and JSON body.
    @_cdecl("Java_com_opencapture_opencine_frameio_FrameioNative_apiRequest")
    public func frameioNativeAPIRequest(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?, operation: jstring?,
        accountID: jstring?, workspaceID: jstring?, folderID: jstring?, fileID: jstring?,
        name: jstring?, fileSize: jlong
    ) -> jstring? {
        guard
            let operation = swiftString(env, operation),
            let payload = AndroidFrameioWire.apiRequest(
                operation: operation,
                accountID: swiftString(env, accountID), workspaceID: swiftString(env, workspaceID),
                folderID: swiftString(env, folderID), fileID: swiftString(env, fileID),
                name: swiftString(env, name), fileSize: Int64(fileSize))
        else { return nil }
        return javaString(env, payload)
    }

    /// `FrameioNative.decodeResponse(operation, response): String?` decodes API JSON through the
    /// shared Codable models. The raw response is never logged here.
    @_cdecl("Java_com_opencapture_opencine_frameio_FrameioNative_decodeResponse")
    public func frameioNativeDecodeResponse(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?, operation: jstring?,
        response: jstring?
    ) -> jstring? {
        guard
            let operation = swiftString(env, operation),
            let response = swiftString(env, response),
            let decoded = AndroidFrameioWire.decodedResponse(
                operation: operation, response: response)
        else { return nil }
        return javaString(env, decoded)
    }

    /// `FrameioNative.mediaTypeForFilename(filename): String` asks the shared policy for the
    /// upload MIME family.
    @_cdecl("Java_com_opencapture_opencine_frameio_FrameioNative_mediaTypeForFilename")
    public func frameioNativeMediaTypeForFilename(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?, filename: jstring?
    ) -> jstring? {
        let filename = swiftString(env, filename) ?? ""
        return javaString(env, AndroidFrameioWire.mediaType(forFilename: filename))
    }

#endif
