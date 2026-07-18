#include <metal_stdlib>
using namespace metal;

// StereoShift Metal pipeline. Pass order (see MetalStereoRenderer.makeSBS):
//   1. depthRefine             — joint-bilateral depth filter guided by the RGB image,
//                                plus percentile normalization and gamma. Aligns depth
//                                edges with image edges so warped silhouettes don't halo.
//   2. depthRefine (coarse) + depthFlatten — a second, very wide joint bilateral at 1/8
//                                resolution forms an edge-aware large-scale base;
//                                depthFlatten then crushes depth detail that has no
//                                supporting image structure. Removes the model's
//                                low-amplitude depth wobble on flat surfaces
//                                (curved-background artifact) while keeping true
//                                slopes and real relief.
//   3. depthDilateAxis (H dir, V) per eye — max-filter dilation of near depth into the
//                                background. Horizontal dilation is DIRECTIONAL: it only
//                                grows toward the side where that eye's disocclusion
//                                trails (right for the right eye, left for the left eye),
//                                so the clean side of every silhouette keeps true
//                                background parallax instead of a flattened halo band.
//   4. depthGaussianAxis (H, V) per eye — softens the dilated depth so disocclusions
//                                stretch smoothly instead of tearing.
//   5. stereoWarp ×2           — damped fixed-point iterative inverse warp around a
//                                convergence plane: disparity = (depth - convergence) *
//                                maxShift. Pixels whose converged source lands inside a
//                                nearer occluder (disocclusion) are resampled with the
//                                local dilated disparity at the output position.
//   6. composeSBS              — packs left/right into a double-width frame.

constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);

inline float luma709(float3 c) {
    return dot(c, float3(0.2126, 0.7152, 0.0722));
}

// Joint bilateral filter on the depth map using the RGB frame as the guide,
// followed by range normalization (percentile min/max computed on the CPU) and gamma.
// The depth texture is the raw model output (float16, model resolution); `depthCrop`
// maps full-frame UVs into the content region of that texture, so this single pass
// performs the letterbox crop + edge-aware upsample + normalize in one resample.
//
// sigmaColor adapts to local image structure when `adaptive` is 1: where the image is
// flat (walls, sky), color binding is loosened so the spatial term irons out the
// model's low-amplitude depth undulation (which otherwise reads as a "curved"
// background in stereo); near image edges, binding tightens to the passed sigmaColor
// so silhouettes snap. `adaptive` is 0 for the coarse large-scale-base pass, whose
// color gate must stay tight everywhere so foreign depth never seeps across object
// boundaries.
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
    constant float &adaptive     [[buffer(8)]],
    uint2 gid                    [[thread_position_in_grid]])
{
    uint w = outDepth.get_width();
    uint h = outDepth.get_height();
    if (gid.x >= w || gid.y >= h) return;

    float2 invSize = float2(1.0 / float(w), 1.0 / float(h));
    float2 uv = (float2(gid) + 0.5) * invSize;

    float3 centerColor = sourceTexture.sample(linearSampler, uv).rgb;

    // Local image-edge strength from 1px luma differences.
    float lL = luma709(sourceTexture.sample(linearSampler, uv - float2(invSize.x, 0.0)).rgb);
    float lR = luma709(sourceTexture.sample(linearSampler, uv + float2(invSize.x, 0.0)).rgb);
    float lT = luma709(sourceTexture.sample(linearSampler, uv - float2(0.0, invSize.y)).rgb);
    float lB = luma709(sourceTexture.sample(linearSampler, uv + float2(0.0, invSize.y)).rgb);
    float edgeStrength = abs(lR - lL) + abs(lB - lT);
    float flatness = 1.0 - smoothstep(0.02, 0.15, edgeStrength);
    float sigmaC = mix(sigmaColor, 0.22, flatness * adaptive);

    float invTwoSigmaS2 = 1.0 / (2.0 * sigmaSpatial * sigmaSpatial);
    float invTwoSigmaC2 = 1.0 / (2.0 * sigmaC * sigmaC);

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

// Flattens unsupported depth undulation. The base is the refined depth resampled to a
// coarse grid by an image-guided joint bilateral with a very wide spatial sigma (see
// MetalStereoRenderer — it reuses the depthRefine kernel). A wide EDGE-AWARE base
// preserves true slopes and large shapes (a receding floor, a wall seen at an angle)
// and never mixes depth across object boundaries, but it cannot follow the large-scale
// non-linear wobble the model leaves on flat surfaces, so that wobble lands entirely
// in `detail`. Detail is then kept only where the image has structure to back it (an
// edge or visible shading gradient); on textureless regions it is crushed — invisible
// to the viewer anyway, since a textureless surface shows no warp distortion. This
// keeps planar backgrounds planar in stereo without touching real, image-supported
// relief.
kernel void depthFlatten(
    texture2d<float, access::sample> sourceTexture  [[texture(0)]],
    texture2d<float, access::sample> coarseTexture  [[texture(1)]],
    texture2d<float, access::read>   refinedTexture [[texture(2)]],
    texture2d<float, access::write>  outDepth       [[texture(3)]],
    uint2 gid                  [[thread_position_in_grid]])
{
    uint w = outDepth.get_width();
    uint h = outDepth.get_height();
    if (gid.x >= w || gid.y >= h) return;

    float2 invSize = float2(1.0 / float(w), 1.0 / float(h));
    float2 uv = (float2(gid) + 0.5) * invSize;

    float base = coarseTexture.sample(linearSampler, uv).r;
    float refined = refinedTexture.read(gid).r;
    float detail = refined - base;

    // Image support for the detail: luma gradients at 1px (edges, texture) and at an
    // 8px span (broad shading on rounded surfaces, e.g. faces). A textureless wall
    // stays under both thresholds even with a smooth lighting gradient.
    float lL = luma709(sourceTexture.sample(linearSampler, uv - float2(invSize.x, 0.0)).rgb);
    float lR = luma709(sourceTexture.sample(linearSampler, uv + float2(invSize.x, 0.0)).rgb);
    float lT = luma709(sourceTexture.sample(linearSampler, uv - float2(0.0, invSize.y)).rgb);
    float lB = luma709(sourceTexture.sample(linearSampler, uv + float2(0.0, invSize.y)).rgb);
    float g1 = abs(lR - lL) + abs(lB - lT);
    float w8 = invSize.x * 8.0, h8 = invSize.y * 8.0;
    float lL8 = luma709(sourceTexture.sample(linearSampler, uv - float2(w8, 0.0)).rgb);
    float lR8 = luma709(sourceTexture.sample(linearSampler, uv + float2(w8, 0.0)).rgb);
    float lT8 = luma709(sourceTexture.sample(linearSampler, uv - float2(0.0, h8)).rgb);
    float lB8 = luma709(sourceTexture.sample(linearSampler, uv + float2(0.0, h8)).rgb);
    float g8 = abs(lR8 - lL8) + abs(lB8 - lT8);

    float support = max(smoothstep(0.03, 0.12, g1), smoothstep(0.05, 0.20, g8));
    float keep = mix(0.3, 1.0, support);

    outDepth.write(float4(base + detail * keep, 0.0, 0.0, 1.0), gid);
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

// Inverse warp producing one eye view.
//
// direction: -1.0 for left eye, +1.0 for right eye
// maxShift:  maximum per-eye pixel displacement
// convergence: normalized depth of the zero-parallax (screen) plane; nearer content
//              pops out, farther content recedes behind the screen
// edgeTaper: distance in pixels over which behind-screen disparity fades to zero at
//            the left/right borders (avoids smearing clamped edge pixels into view)
// holeThresh: depth margin (normalized) for disocclusion detection
//
// depthTexture is the per-eye dilated+feathered depth (drives a stable iteration);
// sharpTexture is the undilated refined depth (grounds the occlusion test).
kernel void stereoWarp(
    texture2d<float, access::sample> sourceTexture [[texture(0)]],
    texture2d<float, access::sample> depthTexture  [[texture(1)]],
    texture2d<float, access::sample> sharpTexture  [[texture(2)]],
    texture2d<float, access::write>  outTexture    [[texture(3)]],
    constant float &direction   [[buffer(0)]],
    constant float &maxShift    [[buffer(1)]],
    constant float &convergence [[buffer(2)]],
    constant float &edgeTaper   [[buffer(3)]],
    constant float &holeThresh  [[buffer(4)]],
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

    float2 outUV = float2(xPix / fw, yNorm);
    float dOut = sharpTexture.sample(linearSampler, outUV).r;

    // Damped fixed-point iteration solves the inverse warp: find the source column
    // whose disparity lands it on this output pixel. Depth at silhouettes forms a
    // step, which makes the raw iteration oscillate between the occluder and the
    // background side; averaging successive estimates damps it into convergence.
    float sourceX = xPix;
    for (int i = 0; i < 4; i++) {
        float d = depthTexture.sample(linearSampler, float2(sourceX / fw, yNorm)).r;
        float disparity = (d - convergence) * maxShift;
        if (disparity < 0.0) {
            disparity *= negativeTaper;
        }
        float candidate = xPix + (direction * disparity);
        sourceX = (i == 0) ? candidate : ((sourceX + candidate) * 0.5);
    }

    // If the converged source sits inside a distinctly nearer object than this
    // pixel's own depth, the pixel is disoccluded — the source position is an
    // occluder, not a match. Resample with the local dilated disparity at the
    // output position, which is guaranteed to pull background from the visible
    // side of the silhouette instead of bleeding occluder color into the hole.
    float dSrc = sharpTexture.sample(linearSampler, float2(clamp(sourceX / fw, 0.0, 1.0), yNorm)).r;
    if (dSrc > dOut + holeThresh) {
        float d = depthTexture.sample(linearSampler, outUV).r;
        float disparity = (d - convergence) * maxShift;
        if (disparity < 0.0) {
            disparity *= negativeTaper;
        }
        sourceX = xPix + (direction * disparity);
    }

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
