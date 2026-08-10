#include <metal_stdlib>
using namespace metal;

// StereoShift Metal pipeline. Pass order (see MetalStereoRenderer.makeSBS):
//   1. depthRefine             — joint-bilateral depth filter guided by the RGB image,
//                                plus percentile normalization and gamma. Aligns depth
//                                edges with image edges so warped silhouettes don't halo.
//   2. depthDilateAxis (H dir, V) per eye — small max-filter dilation of near depth
//                                across the silhouette's color fringe. Horizontal
//                                dilation is DIRECTIONAL: it only grows toward the side
//                                where that eye's disocclusion trails (right for the
//                                right eye, left for the left eye), so the clean side of
//                                every silhouette keeps true background parallax.
//   3. depthGaussianAxis (H, V) per eye — light feather that anti-aliases the dilated
//                                depth steps so the warp's sub-step refinement stays
//                                smooth.
//   4. stereoWarp ×2           — occlusion-ordered scanline search around a convergence
//                                plane: disparity = (depth - convergence) * maxShift.
//                                Scanning from the pop-out side makes the nearest
//                                surface win wherever sources overlap, and disoccluded
//                                gaps stretch the adjacent background across the hole.
//   5. composeSBS              — packs left/right into a double-width frame.

constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);

// Joint bilateral filter on the depth map using the RGB frame as the guide,
// followed by range normalization (percentile min/max computed on the CPU) and gamma.
// The depth texture is the raw model output (float16, model resolution); `depthCrop`
// maps full-frame UVs into the content region of that texture, so this single pass
// performs the content crop + edge-aware upsample + normalize in one resample.
kernel void depthRefine(
    texture2d<float, access::sample> sourceTexture [[texture(0)]],
    texture2d<float, access::sample> depthTexture  [[texture(1)]],
    texture2d<float, access::write>  outDepth      [[texture(2)]],
    constant int   &radius       [[buffer(0)]],
    constant int   &sampleStep   [[buffer(1)]],
    constant float &sigmaSpatial [[buffer(2)]],
    constant float &sigmaColor   [[buffer(3)]],
    constant float &minDepth     [[buffer(4)]],
    constant float &invRange     [[buffer(5)]],
    constant float &gamma        [[buffer(6)]],
    constant float4 &depthCrop   [[buffer(7)]],
    uint2 gid                    [[thread_position_in_grid]])
{
    uint w = outDepth.get_width();
    uint h = outDepth.get_height();
    if (gid.x >= w || gid.y >= h) return;

    float2 invSize = float2(1.0 / float(w), 1.0 / float(h));
    float2 uv = (float2(gid) + 0.5) * invSize;

    float3 centerColor = sourceTexture.sample(linearSampler, uv).rgb;
    float invTwoSigmaS2 = 1.0 / (2.0 * sigmaSpatial * sigmaSpatial);
    float invTwoSigmaC2 = 1.0 / (2.0 * sigmaColor * sigmaColor);

    float sum = 0.0;
    float weightSum = 0.0;
    // Anchor the stride to a multiple of sampleStep so offset (0,0) — the pixel's own
    // depth — is always sampled, even when radius is odd and sampleStep is 2.
    int start = -(radius / sampleStep) * sampleStep;
    for (int dy = start; dy <= radius; dy += sampleStep) {
        for (int dx = start; dx <= radius; dx += sampleStep) {
            float2 offset = float2(dx, dy);
            float2 sampleUV = uv + (offset * invSize);
            float2 depthUV = depthCrop.xy + (sampleUV * depthCrop.zw);
            float d = depthTexture.sample(linearSampler, depthUV).r;
            float3 colorDelta = sourceTexture.sample(linearSampler, sampleUV).rgb - centerColor;
            float weight = exp(-dot(offset, offset) * invTwoSigmaS2)
                         * exp(-dot(colorDelta, colorDelta) * invTwoSigmaC2);
            sum += d * weight;
            weightSum += weight;
        }
    }

    float depth = (weightSum > 0.0) ? (sum / weightSum)
                                    : depthTexture.sample(linearSampler, depthCrop.xy + (uv * depthCrop.zw)).r;
    depth = clamp((depth - minDepth) * invRange, 0.0, 1.0);
    depth = pow(depth, gamma);
    outDepth.write(float4(depth, depth, depth, 1.0), gid);
}

// Separable max-filter dilation along one axis (axis = (1,0) or (0,1)).
// dirSign > 0: one-sided, propagates near depth toward +axis (offsets [-radius, 0]);
// dirSign < 0: one-sided toward -axis (offsets [0, +radius]);
// dirSign = 0: symmetric. One-sided horizontal dilation grows near depth only into
// the disocclusion side of a silhouette, which is what the warp actually needs.
kernel void depthDilateAxis(
    texture2d<float, access::read>  inDepth  [[texture(0)]],
    texture2d<float, access::write> outDepth [[texture(1)]],
    constant int2 &axis       [[buffer(0)]],
    constant int  &radius     [[buffer(1)]],
    constant int  &sampleStep [[buffer(2)]],
    constant int  &dirSign    [[buffer(3)]],
    uint2 gid                 [[thread_position_in_grid]])
{
    uint w = outDepth.get_width();
    uint h = outDepth.get_height();
    if (gid.x >= w || gid.y >= h) return;

    int maxX = int(inDepth.get_width()) - 1;
    int maxY = int(inDepth.get_height()) - 1;
    int oStart = -radius;
    int oEnd = radius;
    if (dirSign > 0) {
        oStart = -radius;
        oEnd = 0;
    } else if (dirSign < 0) {
        oStart = 0;
        oEnd = radius;
    }
    // Seed with the pixel's own depth so dilation stays extensive (output >= input)
    // regardless of radius/sampleStep parity, which a -radius stride start can skip.
    float maxVal = inDepth.read(gid).r;
    for (int o = oStart; o <= oEnd; o += sampleStep) {
        int sx = clamp(int(gid.x) + (o * axis.x), 0, maxX);
        int sy = clamp(int(gid.y) + (o * axis.y), 0, maxY);
        maxVal = max(maxVal, inDepth.read(uint2(sx, sy)).r);
    }
    outDepth.write(float4(maxVal, maxVal, maxVal, 1.0), gid);
}

// Separable Gaussian blur along one axis.
kernel void depthGaussianAxis(
    texture2d<float, access::read>  inDepth  [[texture(0)]],
    texture2d<float, access::write> outDepth [[texture(1)]],
    constant int2  &axis   [[buffer(0)]],
    constant int   &radius [[buffer(1)]],
    constant float &sigma  [[buffer(2)]],
    uint2 gid              [[thread_position_in_grid]])
{
    uint w = outDepth.get_width();
    uint h = outDepth.get_height();
    if (gid.x >= w || gid.y >= h) return;

    int maxX = int(inDepth.get_width()) - 1;
    int maxY = int(inDepth.get_height()) - 1;
    float invTwoSigma2 = 1.0 / (2.0 * sigma * sigma);
    float sum = 0.0;
    float weightSum = 0.0;
    for (int o = -radius; o <= radius; o++) {
        int sx = clamp(int(gid.x) + (o * axis.x), 0, maxX);
        int sy = clamp(int(gid.y) + (o * axis.y), 0, maxY);
        float weight = exp(-float(o * o) * invTwoSigma2);
        sum += inDepth.read(uint2(sx, sy)).r * weight;
        weightSum += weight;
    }
    outDepth.write(float4(sum / weightSum, 0.0, 0.0, 1.0), gid);
}

// Inverse warp producing one eye view via an occlusion-ordered scanline search.
//
// direction: -1.0 for left eye, +1.0 for right eye
// maxShift:  maximum per-eye pixel displacement
// convergence: normalized depth of the zero-parallax (screen) plane; nearer content
//              pops out, farther content recedes behind the screen
// edgeTaper: distance in pixels over which behind-screen disparity fades to zero at
//            the left/right borders (avoids smearing clamped edge pixels into view)
// stepSize:  scan step in pixels
//
// A source column S with disparity disp(S) = (depth(S) - convergence) * maxShift
// appears in this eye at x = S - direction * disp(S). For each output column the
// kernel scans the candidate offset t = S - x from the maximum pop-out offset toward
// the maximum recede offset and stops at the first t with
// direction * t <= disp(x + t). Scanning from the pop-out side makes the nearest
// surface win wherever several sources land on the same output pixel, and in a
// disoccluded gap the scan runs past the silhouette onto the background, which
// stretches it across the hole — occlusion and hole fill both fall out of the scan
// order. Sampling at x + direction * disp then refines the hit below the step size
// (near the crossing, t ≈ direction * disp under locally constant depth).
kernel void stereoWarp(
    texture2d<float, access::sample> sourceTexture [[texture(0)]],
    texture2d<float, access::sample> depthTexture  [[texture(1)]],
    texture2d<float, access::write>  outTexture    [[texture(2)]],
    constant float &direction   [[buffer(0)]],
    constant float &maxShift    [[buffer(1)]],
    constant float &convergence [[buffer(2)]],
    constant float &edgeTaper   [[buffer(3)]],
    constant float &stepSize    [[buffer(4)]],
    uint2 gid                   [[thread_position_in_grid]])
{
    uint w = outTexture.get_width();
    uint h = outTexture.get_height();
    if (gid.x >= w || gid.y >= h) return;

    float fw = float(w);
    float xPix = float(gid.x) + 0.5;
    float yNorm = (float(gid.y) + 0.5) / float(h);

    float borderDistance = min(xPix, fw - xPix);
    float negativeTaper = (edgeTaper > 0.0) ? clamp(borderDistance / edgeTaper, 0.0, 1.0) : 1.0;

    // Normalized depth confines disparity to
    // [-convergence * maxShift, (1 - convergence) * maxShift], so the scan covers
    // exactly maxShift pixels. `direction * t` decreases by `step` each iteration
    // (the two `direction` factors cancel, so this holds for both eyes) from the
    // pop-out bound down to the recede bound, which always satisfies the stop
    // condition (tapering only shrinks |disparity|). The bounded loop terminates
    // regardless; `disparity` is assigned before the stop check every iteration,
    // so a floating-point tie that falls through the final iteration still leaves
    // the correct recede-bound disparity in place.
    float step = max(stepSize, 0.5);
    int iterations = int(ceil(maxShift / step)) + 1;
    float t = direction * (1.0 - convergence) * maxShift;
    float disparity = 0.0;
    for (int i = 0; i < iterations; i++) {
        float d = depthTexture.sample(linearSampler, float2((xPix + t) / fw, yNorm)).r;
        disparity = (d - convergence) * maxShift;
        if (disparity < 0.0) {
            disparity *= negativeTaper;
        }
        if (direction * t <= disparity) break;
        t -= direction * step;
    }

    float sourceX = xPix + (direction * disparity);
    float2 sampleUV = float2(clamp(sourceX / fw, 0.0, 1.0), yNorm);
    float4 color = sourceTexture.sample(linearSampler, sampleUV);
    outTexture.write(float4(color.rgb, 1.0), gid);
}

// Compose SBS — copies left and right eye textures into a double-width output.
kernel void composeSBS(
    texture2d<float, access::read>  leftTexture  [[texture(0)]],
    texture2d<float, access::read>  rightTexture [[texture(1)]],
    texture2d<float, access::write> outTexture   [[texture(2)]],
    uint2 gid                                    [[thread_position_in_grid]])
{
    uint halfW = leftTexture.get_width();
    uint outH  = outTexture.get_height();
    if (gid.y >= outH) return;

    if (gid.x < halfW) {
        // Left half
        float4 c = leftTexture.read(gid);
        outTexture.write(c, gid);
    } else if (gid.x < halfW * 2) {
        // Right half
        float4 c = rightTexture.read(uint2(gid.x - halfW, gid.y));
        outTexture.write(c, gid);
    }
}
