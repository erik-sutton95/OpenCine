#if os(iOS)
import OpenCineCore
import OpenCineDJI

extension MultiviewCameraPolicy where Camera == DjiAppleSighting {
    /// DJI's Multiview camera policy: the captured model support (`MulticamSupport`) decides which
    /// bodies may join a stage, with the operator's experimental opt-in, and which show a picture.
    /// Members are found by probing the shared network. Kotlin twin: `MultiviewCameraPolicy.dji`
    /// in `:dji`.
    public static var dji: MultiviewCameraPolicy<DjiAppleSighting> {
        MultiviewCameraPolicy(
            qualification: { camera, experimental in
                MulticamSupport.qualification(camera.model, experimental: experimental)
            },
            hasPreview: { MulticamSupport.hasPreview($0.model) })
    }
}
#endif
