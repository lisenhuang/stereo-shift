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

## Depth Pipelines (v2 vs v3)

StereoShift uses the same high-level flow for all depth models:

1. Preprocess the input `CVPixelBuffer` into the model's expected size/format.
2. Run Core ML inference.
3. Decode the model output into a normalized depth buffer.
4. Crop/resize the depth buffer back to the original media dimensions.
5. Feed the depth buffer into the SBS renderer (shared for v2/v3).

Implementation references:

- `/Users/easonsmith/Desktop/practice/StereoShift/StereoShift/StereoShift/Core/DepthEstimator.swift`
- `/Users/easonsmith/Desktop/practice/StereoShift/StereoShift/StereoShift/Core/StereoRenderer.swift`

### Depth Anything v2 (Small F16/F32)

Model I/O:

- Input: one image feature (named `image`) as a `CVPixelBuffer` (BGRA).
  - The generated interface notes: short side ~`518` and the long side should be a multiple of `14`.
  - `DepthEstimator` will aspect-fit into a model-sized canvas (letterbox) and records a content rect for later crop-back.
- Output: one image feature named `depth` as a grayscale `CVPixelBuffer` (`kCVPixelFormatType_OneComponent16Half`).

StereoShift postprocess:

- Crop the letterboxed padding away using the recorded content rect, then resize back to the original image/video size.
- Standardize the resulting depth buffer into a grayscale BGRA `CVPixelBuffer` for downstream rendering.

### Depth Anything v3 (Small F16/F32)

Model I/O:

- Input: one image feature (named `image`) as a `CVPixelBuffer` (BGRA), fixed `518x518`.
- Output: one `MLMultiArray` (named `var_7994`) with shape `1x518x518` (Float16 or Float32).

StereoShift postprocess:

- Convert the `MLMultiArray` to an 8-bit normalized depth map using percentile clipping to avoid outliers:
  - F16: 1%..99%
  - F32: 0.5%..99.5%
- Invert polarity for v3 so the renderer always uses the convention: larger depth value = closer.
- Crop/resize depth back to the original size like v2.

## SBS Rendering Pipeline (Metal GPU)

StereoShift uses a Metal compute shader pipeline for stereo rendering, running entirely on the GPU for maximum speed. The pipeline consists of four compute passes executed in a single command buffer:

1. **Depth Max Filter** (`depthMaxFilter` kernel): Dilates foreground depth values into background regions using a max-pool operation within a configurable radius. This pre-fills occlusion areas so the subsequent warp has valid depth everywhere, preventing holes.

2. **Stereo Warp — Left Eye** (`stereoWarpMetal` kernel, direction = -1): Inverse warps the source image using the filtered depth map. Each output pixel samples depth (3×3 neighborhood average for stability), computes a horizontal shift proportional to depth × maxShift, and bilinear-samples the source at the shifted coordinate.

3. **Stereo Warp — Right Eye** (`stereoWarpMetal` kernel, direction = +1): Same inverse warp in the opposite direction to produce the right eye view.

4. **Compose SBS** (`composeSBS` kernel): Copies left and right eye textures side-by-side into a double-width output texture.

Key implementation details:

- All passes use Metal compute kernels dispatched via `MTLComputeCommandEncoder`
- CVPixelBuffer ↔ MTLTexture conversion uses `CVMetalTextureCache` for zero-copy GPU access
- The `maxShift` parameter (baseline disparity) is derived from `baselinePerEye × 3D Strength`
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
