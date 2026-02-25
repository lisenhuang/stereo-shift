# Model Resource Placement

Place the Depth Anything Core ML package in this folder using this name:

- `DepthAnythingV2SmallF16.mlpackage`

At runtime, `DepthEstimator` will load either:

- `DepthAnythingV2SmallF16.mlmodelc` (compiled model), or
- `DepthAnythingV2SmallF16.mlpackage` (compiled on first launch)

Use the helper script at `/Users/easonsmith/Desktop/practice/StereoShift/StereoShift/scripts/download_depth_anything_v2.sh`.
Examples:

- F16: `./scripts/download_depth_anything_v2.sh`

If automatic download fails, place a compatible `.mlpackage` here manually.
