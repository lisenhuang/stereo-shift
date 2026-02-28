#include <metal_stdlib>
using namespace metal;

// Depth max filter — dilates foreground depth into background regions.
// This pre-fills occlusion areas so that the subsequent inverse warp has valid depth
// everywhere, preventing holes. Matches Spatial Media Toolkit's depthmax2 shader.
kernel void depthMaxFilter(
    texture2d<float, access::read>  inDepth  [[texture(0)]],
    texture2d<float, access::write> outDepth [[texture(1)]],
    constant float &radius                   [[buffer(0)]],
    constant float &increment                [[buffer(1)]],
    uint2 gid                                [[thread_position_in_grid]])
{
    if (gid.x >= outDepth.get_width() || gid.y >= outDepth.get_height()) return;

    int r = int(radius);
    float step = max(increment, 1.0);
    float maxVal = 0.0;

    for (float dy = -float(r); dy <= float(r); dy += step) {
        for (float dx = -float(r); dx <= float(r); dx += step) {
            int sx = int(gid.x) + int(dx);
            int sy = int(gid.y) + int(dy);
            sx = clamp(sx, 0, int(inDepth.get_width()) - 1);
            sy = clamp(sy, 0, int(inDepth.get_height()) - 1);
            float d = inDepth.read(uint2(sx, sy)).r;
            maxVal = max(maxVal, d);
        }
    }

    outDepth.write(float4(maxVal, maxVal, maxVal, 1.0), gid);
}

// Stereo warp — inverse warps the source image using the depth map to produce
// a shifted view (left or right eye). Matches Spatial Media Toolkit's
// stereoImageFromDepthMetal shader.
//
// direction: +1.0 for left eye, -1.0 for right eye
// maxShift:  maximum pixel displacement (baseline * strength)
kernel void stereoWarpMetal(
    texture2d<float, access::sample> sourceTexture [[texture(0)]],
    texture2d<float, access::sample> depthTexture  [[texture(1)]],
    texture2d<float, access::write>  outTexture    [[texture(2)]],
    constant float &direction                      [[buffer(0)]],
    constant float &maxShift                       [[buffer(1)]],
    uint2 gid                                      [[thread_position_in_grid]])
{
    uint outW = outTexture.get_width();
    uint outH = outTexture.get_height();
    if (gid.x >= outW || gid.y >= outH) return;

    constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);

    float2 uv = float2((float(gid.x) + 0.5) / float(outW),
                        (float(gid.y) + 0.5) / float(outH));

    // Sample depth at this output pixel position (3x3 neighborhood average for stability)
    float texelW = 1.0 / float(outW);
    float texelH = 1.0 / float(outH);
    float sum = 0.0;
    sum += depthTexture.sample(linearSampler, uv + float2(-texelW, -texelH)).r;
    sum += depthTexture.sample(linearSampler, uv + float2(0.0,     -texelH)).r;
    sum += depthTexture.sample(linearSampler, uv + float2( texelW, -texelH)).r;
    sum += depthTexture.sample(linearSampler, uv + float2(-texelW,  0.0)).r;
    sum += depthTexture.sample(linearSampler, uv).r;
    sum += depthTexture.sample(linearSampler, uv + float2( texelW,  0.0)).r;
    sum += depthTexture.sample(linearSampler, uv + float2(-texelW,  texelH)).r;
    sum += depthTexture.sample(linearSampler, uv + float2(0.0,      texelH)).r;
    sum += depthTexture.sample(linearSampler, uv + float2( texelW,  texelH)).r;
    float depthValue = clamp(sum / 9.0, 0.0, 1.0);

    // Horizontal shift in normalized coordinates
    float shiftNorm = direction * depthValue * maxShift / float(outW);
    float2 sampleUV = float2(clamp(uv.x + shiftNorm, 0.0, 1.0), uv.y);

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
