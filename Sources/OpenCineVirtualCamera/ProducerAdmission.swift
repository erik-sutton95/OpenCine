/// Filters metadata for clients already admitted by the CMIO platform.
/// This policy makes no cryptographic claim about an unavailable signing hint.
public enum ProducerAdmission {
    public static func accepts(signingHint: String?) -> Bool {
        guard let signingHint, signingHint != "unknown" else { return true }
        return signingHint.hasPrefix("com.opencapture.") && signingHint.hasSuffix(".module")
    }
}
