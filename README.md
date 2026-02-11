# StereoShift (V1)

StereoShift is a minimal iOS 17+ SwiftUI app that converts:

- One 2D photo -> Side-by-Side (Left|Right) stereo image
- One 2D video -> Side-by-Side (Left|Right) stereo video

All processing runs on-device.

## Tech Stack

- Swift + SwiftUI
- Core ML (`apple/coreml-depth-anything-v2-small`, Small F32)
- AVFoundation reader/writer pipeline
- CPU stereo warp + lightweight hole fill

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

2. The script installs Small F32 by default. The model package path is:

- `/Users/easonsmith/Desktop/practice/StereoShift/StereoShift/StereoShift/Resources/DepthAnythingV2SmallF32.mlpackage`

`DepthEstimator` will load either compiled `.mlmodelc` or compile `.mlpackage` at runtime.

## Build & Run

1. Open `/Users/easonsmith/Desktop/practice/StereoShift/StereoShift/StereoShift.xcodeproj`
2. Select an iOS 17+ device or simulator
3. Build and run
4. Pick a photo or video, adjust `3D Strength`, tap `Generate`

## Output Formats

- Photo output: PNG (saved temporary file + share sheet + save to Photos)
- Video output: MP4 (H.264), SBS frame width is doubled

Audio is currently omitted in V1 for stability and simpler offline processing.

## Stereo Algorithm (V1)

`StereoRenderer` performs:

1. Normalize depth map to [0, 1]
2. Heuristic near/far orientation correction
3. Mild box blur to reduce depth noise
4. Disparity from depth and `3D Strength`
5. Inverse warp to left/right images
6. Horizontal fill for edge/disocclusion holes
7. Concatenate left and right into SBS

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
