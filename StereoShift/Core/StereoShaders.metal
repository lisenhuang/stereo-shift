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
constexpr sampler nearestSampler(coord::normalized, address::clamp_to_edge, filter::nearest);

// Joint bilateral filter on the depth map using the RGB frame as the guide,
// followed by range normalization (percentile min/max computed on the CPU) and gamma.
kernel void depthRefine(
    texture2d<float, access::sample> sourceTexture [[texture(0)]],
    texture2d<float, access::sample> depthTexture  [[texture(1)]],
    texture2d<float, access::write>  outDepth      [[texture(2)]],
    constant int   &radius       [[buffer(0)]],
    constant float &sigmaSpatial [[buffer(1)]],
    constant float &sigmaColor   [[buffer(2)]],
    constant float &minDepth     [[buffer(3)]],
    constant float &invRange     [[buffer(4)]],
    constant float &gamma        [[buffer(5)]],
    uint2 gid                    [[thread_position_in_grid]])
{
    uint w = outDepth.get_width();
    uint h = outDepth.get_height();
    if (gid.x >= w || gid.y >= h) return;

    float2 outputSize = float2(float(w), float(h));
    float2 uv = (float2(gid) + 0.5) / outputSize;
    float2 depthSize = float2(
        float(depthTexture.get_width()), float(depthTexture.get_height())
    );
    float2 depthPosition = (uv * depthSize) - 0.5;
    int2 centerDepthIndex = int2(floor(depthPosition + 0.5));
    int2 maximumDepthIndex = int2(
        int(depthTexture.get_width()) - 1, int(depthTexture.get_height()) - 1
    );

    float3 centerColor = sourceTexture.sample(linearSampler, uv).rgb;
    float invTwoSigmaS2 = 1.0 / (2.0 * sigmaSpatial * sigmaSpatial);
    float invTwoSigmaC2 = 1.0 / (2.0 * sigmaColor * sigmaColor);

    float localMinimum = INFINITY;
    float localMaximum = -INFINITY;
    for (int dy = -radius; dy <= radius; dy++) {
        for (int dx = -radius; dx <= radius; dx++) {
            int2 depthIndex = clamp(
                centerDepthIndex + int2(dx, dy), int2(0), maximumDepthIndex
            );
            float2 sampleUV = (float2(depthIndex) + 0.5) / depthSize;
            float d = depthTexture.sample(nearestSampler, sampleUV).r;
            localMinimum = min(localMinimum, d);
            localMaximum = max(localMaximum, d);
        }
    }
    float modeMidpoint = (localMinimum + localMaximum) * 0.5;

    float sum = 0.0;
    float weightSum = 0.0;
    float lowModeSum = 0.0;
    float lowModeWeight = 0.0;
    float lowModeSpatialWeight = 0.0;
    float highModeSum = 0.0;
    float highModeWeight = 0.0;
    float highModeSpatialWeight = 0.0;
    // Gather distinct raw-depth texels, then compare each texel's corresponding RGB
    // location with the high-resolution output pixel. Measuring the window in model
    // texels gives the same edge support at 600 px, 12 MP, and 48 MP; the previous
    // output-pixel lattice became sub-texel and phase-sensitive on large photos.
    for (int dy = -radius; dy <= radius; dy++) {
        for (int dx = -radius; dx <= radius; dx++) {
            int2 depthIndex = clamp(
                centerDepthIndex + int2(dx, dy), int2(0), maximumDepthIndex
            );
            float2 sampleUV = (float2(depthIndex) + 0.5) / depthSize;
            float2 spatialOffset = float2(depthIndex) - depthPosition;
            float d = depthTexture.sample(nearestSampler, sampleUV).r;
            float3 colorDelta = sourceTexture.sample(linearSampler, sampleUV).rgb - centerColor;
            float spatialWeight = exp(
                -dot(spatialOffset, spatialOffset) * invTwoSigmaS2
            );
            float weight = spatialWeight
                         * exp(-dot(colorDelta, colorDelta) * invTwoSigmaC2);
            sum += d * weight;
            weightSum += weight;
            if (d <= modeMidpoint) {
                lowModeSum += d * weight;
                lowModeWeight += weight;
                lowModeSpatialWeight += spatialWeight;
            } else {
                highModeSum += d * weight;
                highModeWeight += weight;
                highModeSpatialWeight += spatialWeight;
            }
        }
    }

    float depth = (weightSum > 0.0) ? (sum / weightSum) : depthTexture.sample(linearSampler, uv).r;
    float normalizedLocalRange = (localMaximum - localMinimum) * invRange;
    if (radius > 1
        && normalizedLocalRange >= 0.08
        && lowModeWeight > 0.00001
        && highModeWeight > 0.00001) {
        // A depth discontinuity is two surfaces, not a fractional surface between them.
        // Compare each mode's average RGB affinity (normalizing out unequal sample
        // counts), then keep one mode. If color evidence is genuinely ambiguous, retain
        // the raw center mode so fine texture cannot toggle the result row by row.
        float lowAffinity = lowModeWeight / max(lowModeSpatialWeight, 0.00001);
        float highAffinity = highModeWeight / max(highModeSpatialWeight, 0.00001);
        float affinityDifference = abs(highAffinity - lowAffinity);
        float affinityScale = max(max(highAffinity, lowAffinity), 0.00001);
        bool chooseHigh;
        if (affinityDifference > affinityScale * 0.08) {
            chooseHigh = highAffinity > lowAffinity;
        } else {
            int2 clampedCenterIndex = clamp(
                centerDepthIndex, int2(0), maximumDepthIndex
            );
            float2 centerDepthUV = (float2(clampedCenterIndex) + 0.5) / depthSize;
            float centerRawDepth = depthTexture.sample(nearestSampler, centerDepthUV).r;
            chooseHigh = centerRawDepth > modeMidpoint;
        }
        depth = chooseHigh
            ? (highModeSum / highModeWeight)
            : (lowModeSum / lowModeWeight);
    }
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

struct WarpSolution {
    float sourceX;
    float depth;
    float residual;
};

// Find a source point for one destination sample. A softened depth discontinuity can
// make fixed-point iteration bounce between its foreground and background sides. The
// old residual tie threshold then picked a different side for adjacent rows, producing
// long comb-like teeth. Reject samples inside that transition and make gap/overlap
// visibility depend on the physical surface order, not on a phase-sensitive residual.
inline WarpSolution solveWarpSource(
    texture2d<float, access::sample> depthTexture,
    float destinationX,
    float yNorm,
    float imageWidth,
    float direction,
    float maxShift,
    float convergence,
    float edgeTaper,
    int iterations)
{
    int candidateCount = (iterations > 3) ? 3 : 1;

    float validSourceX = destinationX;
    float validDepth = -INFINITY;
    float validResidual = INFINITY;
    bool foundValidRoot = false;

    float anySourceX = destinationX;
    float anyDepth = INFINITY;
    float anyResidual = INFINITY;

    for (int candidateIndex = 0; candidateIndex < candidateCount; candidateIndex++) {
        float seedOffset = 0.0;
        if (candidateIndex == 1) seedOffset = -maxShift;
        if (candidateIndex == 2) seedOffset = maxShift;

        float sourceX = clamp(destinationX + seedOffset, 0.5, imageWidth - 0.5);
        for (int i = 0; i < iterations; i++) {
            float d = depthTexture.sample(
                linearSampler, float2(sourceX / imageWidth, yNorm)
            ).r;
            float disparity = edgeSafeDisparity(
                d, convergence, maxShift, direction, destinationX, imageWidth, edgeTaper
            );
            sourceX = clamp(
                destinationX + (direction * disparity), 0.5, imageWidth - 0.5
            );
        }

        float candidateDepth = depthTexture.sample(
            linearSampler, float2(sourceX / imageWidth, yNorm)
        ).r;
        float candidateDisparity = edgeSafeDisparity(
            candidateDepth,
            convergence,
            maxShift,
            direction,
            destinationX,
            imageWidth,
            edgeTaper
        );
        float projectedX = sourceX - (direction * candidateDisparity);
        float residual = abs(projectedX - destinationX);

        float depthLeft = depthTexture.sample(
            linearSampler,
            float2(clamp(sourceX - 0.5, 0.5, imageWidth - 0.5) / imageWidth, yNorm)
        ).r;
        float depthRight = depthTexture.sample(
            linearSampler,
            float2(clamp(sourceX + 0.5, 0.5, imageWidth - 0.5) / imageWidth, yNorm)
        ).r;
        float disparityLeft = edgeSafeDisparity(
            depthLeft,
            convergence,
            maxShift,
            direction,
            destinationX,
            imageWidth,
            edgeTaper
        );
        float disparityRight = edgeSafeDisparity(
            depthRight,
            convergence,
            maxShift,
            direction,
            destinationX,
            imageWidth,
            edgeTaper
        );
        bool stableSurface = abs(disparityRight - disparityLeft) <= 0.75;
        bool validRoot = stableSurface && residual <= 0.25;

        // Every invalid candidate participates in a deterministic far-surface fallback.
        // Residual is only a tie-breaker between essentially equal-depth surfaces.
        if (candidateDepth < anyDepth - 0.01
            || (abs(candidateDepth - anyDepth) <= 0.01 && residual < anyResidual)) {
            anySourceX = sourceX;
            anyDepth = candidateDepth;
            anyResidual = residual;
        }

        // At a true overlap the closest surface wins. Transition-ramp samples never
        // reach this branch, so depth ordering cannot promote a phantom in-between root.
        if (validRoot
            && (!foundValidRoot
                || candidateDepth > validDepth + 0.01
                || (abs(candidateDepth - validDepth) <= 0.01 && residual < validResidual))) {
            validSourceX = sourceX;
            validDepth = candidateDepth;
            validResidual = residual;
            foundValidRoot = true;
        }
    }

    if (foundValidRoot) {
        return WarpSolution { validSourceX, validDepth, validResidual };
    }
    return WarpSolution { anySourceX, anyDepth, anyResidual };
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
    float fh = float(h);
    float xPix = float(gid.x) + 0.5;
    float yPix = float(gid.y) + 0.5;
    float yNorm = yPix / fh;

    WarpSolution solution = solveWarpSource(
        depthTexture,
        xPix,
        yNorm,
        fw,
        direction,
        maxShift,
        convergence,
        edgeTaper,
        iterations
    );
    float2 sampleUV = float2(solution.sourceX / fw, yNorm);
    float4 color = sourceTexture.sample(linearSampler, sampleUV);

    if (iterations > 3 && maxShift > 0.0) {
        float xLeft = clamp(solution.sourceX - 0.75, 0.5, fw - 0.5);
        float xRight = clamp(solution.sourceX + 0.75, 0.5, fw - 0.5);
        float yUp = clamp(yPix - 0.75, 0.5, fh - 0.5) / fh;
        float yDown = clamp(yPix + 0.75, 0.5, fh - 0.5) / fh;
        float depthLeft = depthTexture.sample(
            linearSampler, float2(xLeft / fw, yNorm)
        ).r;
        float depthRight = depthTexture.sample(
            linearSampler, float2(xRight / fw, yNorm)
        ).r;
        float depthUp = depthTexture.sample(
            linearSampler, float2(solution.sourceX / fw, yUp)
        ).r;
        float depthDown = depthTexture.sample(
            linearSampler, float2(solution.sourceX / fw, yDown)
        ).r;
        float depthGradient = max(
            abs(depthRight - depthLeft), abs(depthDown - depthUp)
        );
        float coverageBlend = smoothstep(0.35, 1.25, depthGradient * maxShift);

        if (coverageBlend > 0.0) {
            float3 coverageColor = float3(0.0);
            for (int sampleIndex = 0; sampleIndex < 4; sampleIndex++) {
                float offsetX = ((sampleIndex & 1) == 0) ? -0.25 : 0.25;
                float offsetY = ((sampleIndex & 2) == 0) ? -0.25 : 0.25;
                float subpixelY = clamp(yPix + offsetY, 0.5, fh - 0.5) / fh;
                WarpSolution subpixelSolution = solveWarpSource(
                    depthTexture,
                    xPix + offsetX,
                    subpixelY,
                    fw,
                    direction,
                    maxShift,
                    convergence,
                    edgeTaper,
                    iterations
                );
                coverageColor += sourceTexture.sample(
                    linearSampler, float2(subpixelSolution.sourceX / fw, subpixelY)
                ).rgb;
            }
            // Only depth-edge pixels pay for supersampling. This smooths the final
            // silhouette coverage without softening texture across the rest of a photo.
            color.rgb = mix(color.rgb, coverageColor * 0.25, coverageBlend);
        }
    }
    outTexture.write(float4(color.rgb, 1.0), uint2(gid.x + outputXOffset, gid.y));
}
