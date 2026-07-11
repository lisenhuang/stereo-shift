#include <metal_stdlib>
using namespace metal;

// StereoShift Metal pipeline. Pass order (see MetalStereoRenderer.makeSBS):
//   1. depthRefine             — joint-bilateral depth filter guided by the RGB image,
//                                plus percentile normalization and gamma.
//   2a. quality photos         — keep the edge-aligned depth for multi-root visibility.
//   2b. fast video profile     — max-dilate + Gaussian feather support map.
//   3. stereoWarp ×2           — profile-dependent fixed-point inverse warp around a
//                                convergence plane, written directly into SBS output.

constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);

// Joint bilateral filter on the depth map using the RGB frame as the guide,
// followed by range normalization (percentile min/max computed on the CPU) and gamma.
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
            float d = depthTexture.sample(linearSampler, sampleUV).r;
            float3 colorDelta = sourceTexture.sample(linearSampler, sampleUV).rgb - centerColor;
            float weight = exp(-dot(offset, offset) * invTwoSigmaS2)
                         * exp(-dot(colorDelta, colorDelta) * invTwoSigmaC2);
            sum += d * weight;
            weightSum += weight;
        }
    }

    float depth = (weightSum > 0.0) ? (sum / weightSum) : depthTexture.sample(linearSampler, uv).r;
    depth = clamp((depth - minDepth) * invRange, 0.0, 1.0);
    depth = pow(depth, gamma);
    outDepth.write(float4(depth, depth, depth, 1.0), gid);
}

// Separable max-filter dilation along one axis (axis = (1,0) or (0,1)).
kernel void depthDilateAxis(
    texture2d<float, access::read>  inDepth  [[texture(0)]],
    texture2d<float, access::write> outDepth [[texture(1)]],
    constant int2 &axis       [[buffer(0)]],
    constant int  &radius     [[buffer(1)]],
    constant int  &sampleStep [[buffer(2)]],
    uint2 gid                 [[thread_position_in_grid]])
{
    uint w = outDepth.get_width();
    uint h = outDepth.get_height();
    if (gid.x >= w || gid.y >= h) return;

    int maxX = int(inDepth.get_width()) - 1;
    int maxY = int(inDepth.get_height()) - 1;
    // Seed with the pixel's own depth so dilation stays extensive (output >= input)
    // regardless of radius/sampleStep parity, which a -radius stride start can skip.
    float maxVal = inDepth.read(gid).r;
    for (int o = -radius; o <= radius; o += sampleStep) {
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

// Inverse warp producing one eye view.
//
// direction: -1.0 for left eye, +1.0 for right eye
// maxShift:  maximum per-eye pixel displacement
// convergence: normalized depth of the zero-parallax (screen) plane; nearer content
//              pops out, farther content recedes behind the screen
// edgeTaper: distance in pixels over which disparity fades at the border toward which
//            this eye would sample (avoids smearing clamped edge pixels into view)
// iterations: quality-dependent fixed-point solve count
// outputXOffset: 0 for the left half, source width for the right half
inline float edgeSafeDisparity(
    float depth,
    float convergence,
    float maxShift,
    float direction,
    float destinationX,
    float imageWidth,
    float edgeTaper)
{
    float disparity = (depth - convergence) * maxShift;
    float sourceDelta = direction * disparity;
    float distanceToRiskBorder = (sourceDelta < 0.0)
        ? max(destinationX - 0.5, 0.0)
        : max((imageWidth - 0.5) - destinationX, 0.0);
    float taper = (edgeTaper > 0.0)
        ? clamp(distanceToRiskBorder / edgeTaper, 0.0, 1.0)
        : 1.0;
    return disparity * taper;
}

kernel void stereoWarp(
    texture2d<float, access::sample> sourceTexture [[texture(0)]],
    texture2d<float, access::sample> depthTexture  [[texture(1)]],
    texture2d<float, access::write>  outTexture    [[texture(2)]],
    constant float &direction   [[buffer(0)]],
    constant float &maxShift    [[buffer(1)]],
    constant float &convergence [[buffer(2)]],
    constant float &edgeTaper   [[buffer(3)]],
    constant int   &iterations  [[buffer(4)]],
    constant uint  &outputXOffset [[buffer(5)]],
    uint2 gid                   [[thread_position_in_grid]])
{
    uint w = sourceTexture.get_width();
    uint h = sourceTexture.get_height();
    if (gid.x >= w || gid.y >= h) return;
    if (gid.x + outputXOffset >= outTexture.get_width()) return;

    float fw = float(w);
    float xPix = float(gid.x) + 0.5;
    float yNorm = (float(gid.y) + 0.5) / float(h);

    // Fixed-point iteration solves the inverse warp: find the source column whose
    // disparity lands it on this output pixel. Sampling depth at the converged source
    // position (instead of the destination) keeps silhouettes geometrically stable.
    // Quality mode starts from both sides of a possible discontinuity. At an overlap,
    // the closest valid root wins; in a disoccluded gap with no exact root, the farther
    // candidate wins so the background stretches instead of duplicating the foreground.
    int candidateCount = (iterations > 3) ? 3 : 1;
    float bestSourceX = xPix;
    float bestDepth = 0.0;
    float bestResidual = INFINITY;
    bool foundValidRoot = false;

    for (int candidateIndex = 0; candidateIndex < candidateCount; candidateIndex++) {
        float seedOffset = 0.0;
        if (candidateIndex == 1) seedOffset = -maxShift;
        if (candidateIndex == 2) seedOffset = maxShift;

        float sourceX = clamp(xPix + seedOffset, 0.5, fw - 0.5);
        for (int i = 0; i < iterations; i++) {
            float d = depthTexture.sample(linearSampler, float2(sourceX / fw, yNorm)).r;
            float disparity = edgeSafeDisparity(
                d, convergence, maxShift, direction, xPix, fw, edgeTaper
            );
            sourceX = clamp(xPix + (direction * disparity), 0.5, fw - 0.5);
        }

        float candidateDepth = depthTexture.sample(
            linearSampler, float2(sourceX / fw, yNorm)
        ).r;
        float candidateDisparity = edgeSafeDisparity(
            candidateDepth, convergence, maxShift, direction, xPix, fw, edgeTaper
        );
        float projectedX = sourceX - (direction * candidateDisparity);
        float residual = abs(projectedX - xPix);
        bool isValidRoot = residual <= 0.75;

        if (isValidRoot) {
            if (!foundValidRoot || candidateDepth > bestDepth) {
                bestSourceX = sourceX;
                bestDepth = candidateDepth;
                bestResidual = residual;
            }
            foundValidRoot = true;
        } else if (!foundValidRoot) {
            bool clearlyBetterResidual = residual < (bestResidual - 0.25);
            bool comparableResidual = abs(residual - bestResidual) <= 0.25;
            if (clearlyBetterResidual || (comparableResidual && candidateDepth < bestDepth)) {
                bestSourceX = sourceX;
                bestDepth = candidateDepth;
                bestResidual = residual;
            }
        }
    }

    float2 sampleUV = float2(bestSourceX / fw, yNorm);
    float4 color = sourceTexture.sample(linearSampler, sampleUV);
    outTexture.write(float4(color.rgb, 1.0), uint2(gid.x + outputXOffset, gid.y));
}
