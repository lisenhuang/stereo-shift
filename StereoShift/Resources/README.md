# Model Resource Placement

Place one or more Depth Anything Core ML packages in this folder using these names:

- `DepthAnythingV2SmallF16.mlpackage`
- `DepthAnythingV2SmallF32.mlpackage`
- `DepthAnythingV3SmallF16.mlpackage`

At runtime, `DepthEstimator` will load either:

- `DepthAnythingV2SmallF16.mlmodelc` (compiled model), or
- `DepthAnythingV2SmallF16.mlpackage` (compiled on first launch)
- `DepthAnythingV2SmallF32.mlmodelc` (compiled model), or
- `DepthAnythingV2SmallF32.mlpackage` (compiled on first launch)
- `DepthAnythingV3SmallF16.mlmodelc` (compiled model), or
- `DepthAnythingV3SmallF16.mlpackage` (compiled on first launch)

Use the helper script at `/Users/easonsmith/Desktop/practice/StereoShift/StereoShift/scripts/download_depth_anything_v2.sh`.
Examples:

- F16: `./scripts/download_depth_anything_v2.sh`
- F32: `DEPTH_ANYTHING_V2_MODEL_PACKAGE_NAME=DepthAnythingV2SmallF32.mlpackage ./scripts/download_depth_anything_v2.sh`

If automatic download fails, place a compatible `.mlpackage` here manually.

Depth Anything v3 Small is currently converted from ONNX using:

- `/Users/easonsmith/Desktop/practice/StereoShift/StereoShift/scripts/convert_depth_anything_v3_small_onnx_to_coreml.py`
