#if canImport(CoreImage)
import CoreImage
import OpenCineMedia

public enum MonitorBlockArtifactCompositor {
    private static let flatSmoothKernel: CIKernel? = CIKernel(
        source: """
            kernel vec4 flatSmooth(sampler src, float r, float gateGain, float strength) {
              vec2 p = destCoord();
              vec4 c4 = sample(src, samplerTransform(src, p));
              vec4 c0 = sample(src, samplerTransform(src, p + vec2(-r, -r)));
              vec4 c1 = sample(src, samplerTransform(src, p + vec2(0.0, -r)));
              vec4 c2 = sample(src, samplerTransform(src, p + vec2( r, -r)));
              vec4 c3 = sample(src, samplerTransform(src, p + vec2(-r, 0.0)));
              vec4 c5 = sample(src, samplerTransform(src, p + vec2( r, 0.0)));
              vec4 c6 = sample(src, samplerTransform(src, p + vec2(-r,  r)));
              vec4 c7 = sample(src, samplerTransform(src, p + vec2(0.0,  r)));
              vec4 c8 = sample(src, samplerTransform(src, p + vec2( r,  r)));
              vec4 mean = (c0 + c1 + c2 + c3 + c4 + c5 + c6 + c7 + c8) / 9.0;
              vec3 w = vec3(0.2126, 0.7152, 0.0722);
              float m = dot(mean.rgb, w);
              // Mean absolute deviation, not variance: same decision, no squaring, and it stays in
              // code-value units so the gate is readable as "levels out of 255".
              float dev = abs(dot(c0.rgb, w) - m) + abs(dot(c1.rgb, w) - m)
                        + abs(dot(c2.rgb, w) - m) + abs(dot(c3.rgb, w) - m)
                        + abs(dot(c4.rgb, w) - m) + abs(dot(c5.rgb, w) - m)
                        + abs(dot(c6.rgb, w) - m) + abs(dot(c7.rgb, w) - m)
                        + abs(dot(c8.rgb, w) - m);
              dev = dev / 9.0;
              float flatness = clamp(1.0 - dev * gateGain, 0.0, 1.0);
              return vec4(mix(c4.rgb, mean.rgb, flatness * strength), c4.a);
            }
            """)

    /// Adds a small amount of per-pixel noise to break up the periodicity of what blocking is left.
    ///
    /// This does not remove error, it makes the remaining error harder to *detect*, which is a
    /// different and much cheaper goal. Blocking is objectionable out of proportion to its magnitude
    /// because it is a regular lattice and the visual system locks onto periodic structure; measured
    /// against ground truth, a boundary filter moved PSNR by +0.06 dB while dropping the blockiness
    /// ratio from 1.85 to 1.50. Magnitude was never the thing that mattered. AV1 ships film-grain
    /// synthesis as a normative feature for the same reason.
    ///
    /// Applied at **source** resolution, after the look. That reads like the wrong place for a
    /// masker (the eye sees display pixels) but the artifact and the noise are magnified by the
    /// same uniform upscale, so their spatial-frequency relationship is preserved exactly, and it
    /// costs no extra full-drawable pass.
    ///
    /// White noise via a hash, not blue noise: blue noise masks better per unit visibility, but it
    /// needs a texture to sample and this needs nothing. Upgrade path if it reads as too coarse.
    private static let ditherKernel: CIKernel? = CIKernel(
        source: """
            kernel vec4 blockDither(sampler src, float amplitude) {
              vec2 p = destCoord();
              vec4 c = sample(src, samplerTransform(src, p));
              float n = fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453123);
              return vec4(c.rgb + (n - 0.5) * amplitude, c.a);
            }
            """)

    /// Smooths flat regions of `source` to soften block steps, leaving detail untouched. Returns
    /// `source` unchanged when the kernel is unavailable, never drops the frame.
    ///
    /// The caller must keep this OFF the measurement path: zebras would under-report clipping and
    /// peaking would measure its own smoothing. The graph owner retains the separate measurement input.
    public static func applyFlatSmoothing(
        to source: CIImage, settings: MonitorBlockSmoothing, extent: CGRect
    ) -> CIImage {
        guard let kernel = flatSmoothKernel, settings.strength > 0 else { return source }
        let clamped = source.clampedToExtent()
        guard
            let smoothed = kernel.apply(
                extent: extent,
                roiCallback: { _, rect in rect.insetBy(dx: -settings.radius, dy: -settings.radius)
                },
                arguments: [
                    clamped,
                    settings.radius,
                    // Gate expressed as "levels out of 255" at the call site; the kernel wants its
                    // reciprocal so the comparison is a multiply.
                    1.0 / max(settings.gateLevels / 255.0, 1e-6),
                    settings.strength,
                ])
        else { return source }
        return smoothed.cropped(to: extent)
    }

    /// Adds masking noise over `image`. Returns `image` unchanged when the kernel is unavailable.
    public static func applyDither(
        to image: CIImage, settings: MonitorBlockDither, extent: CGRect
    ) -> CIImage {
        guard let kernel = ditherKernel, settings.levels > 0 else { return image }
        guard
            let dithered = kernel.apply(
                extent: extent,
                roiCallback: { _, rect in rect },
                arguments: [image.clampedToExtent(), settings.levels / 255.0])
        else { return image }
        return dithered.cropped(to: extent)
    }

}
#endif
