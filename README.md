# StereoShift (V1)

StereoShift is a minimal iOS 17+ SwiftUI app that converts:

- One 2D photo -> Side-by-Side (Left|Right) stereo image
- One 2D video -> Side-by-Side (Left|Right) stereo video

All processing runs on-device.

## Tech Stack

- Swift + SwiftUI
- Core ML (`apple/coreml-depth-anything-v2-small`, Small F16)
- AVFoundation reader/writer pipeline
- Metal GPU-accelerated stereo rendering pipeline

## Project Layout

- `/Users/easonsmith/Desktop/practice/StereoShift/StereoShift/StereoShift/App`
- `/Users/easonsmith/Desktop/practice/StereoShift/StereoShift/StereoShift/UI`
- `/Users/easonsmith/Desktop/practice/StereoShift/StereoShift/StereoShift/Core`
- `/Users/easonsmith/Desktop/practice/StereoShift/StereoShift/StereoShift/Resources`

## Model Setup

1. Download and install the model package:

```bash
/Users/easonsmith/Desktop/practice/StereoShift/StereoShift/scripts/download_depth_anything_v2.sh
```

2. The script installs Small F16 by default. The model package path is:

- `/Users/easonsmith/Desktop/practice/StereoShift/StereoShift/StereoShift/Resources/DepthAnythingV2SmallF16.mlpackage`

`DepthEstimator` will load either compiled `.mlmodelc` or compile `.mlpackage` at runtime.

## Build & Run

1. Open `/Users/easonsmith/Desktop/practice/StereoShift/StereoShift/StereoShift.xcodeproj`
2. Select an iOS 17+ device or simulator
3. Build and run
4. Pick a photo or video, adjust `3D Strength`, tap `Generate`

## Output Formats

- Photo output: PNG (saved temporary file + share sheet + save to Photos)
- Video output: MP4 (H.264), SBS frame width is doubled

Video conversion preserves the original audio track when possible.

## Depth Pipeline

StereoShift currently packages Depth Anything V2 Small F16:

1. Stretch the input `CVPixelBuffer` to the model's fixed `518x392` BGRA input. This uses the full model canvas instead of losing resolution to letterbox padding.
2. Run Core ML inference.
3. Keep the native `518x392` half-float grayscale output (`kCVPixelFormatType_OneComponent16Half`) without an 8-bit conversion or full-resolution intermediate.
4. Feed that depth texture to the Metal renderer, which samples it in normalized coordinates and performs RGB-guided upsampling at output resolution.

For Portrait/LiDAR photos that contain embedded disparity or depth, StereoShift prefers that camera-derived depth and preserves it as half-float after robust percentile normalization.

Implementation references:

- `/Users/easonsmith/Desktop/practice/StereoShift/StereoShift/StereoShift/Core/DepthEstimator.swift`
- `/Users/easonsmith/Desktop/practice/StereoShift/StereoShift/StereoShift/Core/StereoRenderer.swift`

### Depth Anything V2 Small F16

Model I/O:

- Input: one fixed `518x392` BGRA image feature named `image`.
- Output: one image feature named `depth` as a grayscale `CVPixelBuffer` (`kCVPixelFormatType_OneComponent16Half`).

## SBS Rendering Pipeline (Metal GPU)

StereoShift uses a Metal compute pipeline with separate still-photo quality and video-oriented fast paths:

1. **Depth Refine** (`depthRefine`): A joint bilateral upsampler gathers a fixed 5x5 neighborhood of distinct native depth texels while using the full-resolution RGB frame as its guide. At strong discontinuities it preserves the foreground or background depth mode instead of inventing a fractional surface between them, then normalizes with robust 2%/98% bounds.

2. **Quality photo warp** (`stereoWarp`): Five fixed-point iterations run from three candidate roots around each possible depth discontinuity. Roots inside an unstable depth ramp are rejected; the closest stable surface wins at overlaps and the farther candidate fills disocclusions. A 2x2 subpixel coverage solve runs only at depth edges to anti-alias sloped silhouettes without softening the rest of the photo.

3. **Fast video warp**: The lower-cost profile retains conservative max-dilation/feathering and a three-iteration inverse solve for throughput.

4. **Direct SBS output**: Each eye writes directly into its half of one CVPixelBuffer-backed Metal texture. This removes the two eye textures, compose texture, and CPU readback that previously inflated peak memory for high-resolution photos.

Key implementation details:

- All passes use Metal compute kernels dispatched via `MTLComputeCommandEncoder`
- CVPixelBuffer ↔ MTLTexture conversion uses `CVMetalTextureCache` for zero-copy GPU access
- `maxShift` is derived from `baselinePerEye × 3D Strength × (width / 1440)` — proportional to frame width so all resolutions get the same perceived depth — and capped at 2.5% of width for comfort
- Flat or statistically collapsed depth maps receive effectively zero disparity instead of a false full-range 3D effect
- For video, depth normalization statistics are exponentially smoothed across frames (`StereoRenderer.makeSBSVideoFrame`) to prevent depth-scale flicker
- CPU and CIKernel render engines are preserved as fallbacks if Metal is unavailable

Implementation references:

- `StereoShift/Core/StereoShaders.metal` — Metal compute kernels
- `StereoShift/Core/MetalStereoRenderer.swift` — GPU pipeline manager
- `StereoShift/Core/StereoRenderer.swift` — render engine routing

## Manual Test Checklist

- Portrait photo
- Landscape photo
- High-resolution photo (12MP)
- Short video (5-10s)
- Longer video (1-2 min)

Verify:

- App does not crash
- Output opens in Photos
- Strength slider visibly changes depth effect
- UI follows system light/dark appearance
