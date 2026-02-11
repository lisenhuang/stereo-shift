# Model Resource Placement

Place the downloaded Depth Anything v2 Core ML package in this folder using this exact name:

`DepthAnythingV2SmallF32.mlpackage`

At runtime, `DepthEstimator` will load either:

- `DepthAnythingV2SmallF32.mlmodelc` (compiled model), or
- `DepthAnythingV2SmallF32.mlpackage` (compiled on first launch)

Use the helper script at `/Users/easonsmith/Desktop/practice/StereoShift/StereoShift/scripts/download_depth_anything_v2.sh`.
If automatic download fails, place a compatible `.mlpackage` here manually.
