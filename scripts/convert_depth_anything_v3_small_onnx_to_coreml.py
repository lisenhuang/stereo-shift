#!/usr/bin/env python3
"""
Converts Depth Anything v3 Small ONNX (onnx-community/depth-anything-v3-small)
into a Core ML .mlpackage suitable for iOS.

This uses:
  - onnx + onnx2torch to import the ONNX graph into a Torch module
  - a small wrapper to adapt input/output for Core ML (image -> depth)
  - coremltools to export an ML Program package

Notes:
  - The ONNX model expects `pixel_values` shaped (N, T, 3, H, W).
    We wrap it to accept a single RGB image tensor (N, 3, H, W).
  - Normalization: (x - mean) / std, with ImageNet mean/std.
"""

from __future__ import annotations

import argparse
import os
import shutil
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--onnx", required=True, help="Path to model.onnx")
    parser.add_argument("--onnx-data", required=True, help="Path to model.onnx_data")
    parser.add_argument("--output", required=True, help="Output .mlpackage path")
    parser.add_argument("--size", type=int, default=518, help="Square input size (default: 518)")
    return parser.parse_args()


def main() -> None:
    args = parse_args()

    onnx_path = Path(args.onnx).expanduser().resolve()
    onnx_data_path = Path(args.onnx_data).expanduser().resolve()
    output_path = Path(args.output).expanduser().resolve()
    input_size = int(args.size)

    if not onnx_path.exists():
        raise SystemExit(f"Missing ONNX file: {onnx_path}")
    if not onnx_data_path.exists():
        raise SystemExit(f"Missing ONNX external weights: {onnx_data_path}")
    if onnx_path.parent != onnx_data_path.parent:
        raise SystemExit("--onnx and --onnx-data must be in the same directory.")

    # Lazy imports so this script can be present without deps installed.
    import onnx  # type: ignore
    from onnx.external_data_helper import load_external_data_for_model  # type: ignore
    from onnx2torch import convert as onnx2torch_convert  # type: ignore
    import onnx2torch.converter as onnx2torch_converter  # type: ignore
    import torch  # type: ignore
    import coremltools as ct  # type: ignore
    import numpy as np  # type: ignore

    # coremltools doesn't implement bicubic upsampling conversion in the PyTorch frontend.
    # Depth Anything uses some cubic resizes; approximate them with bilinear for conversion.
    try:
        import onnx2torch.node_converters.resize as onnx2torch_resize  # type: ignore

        if hasattr(onnx2torch_resize, "_MODES_MAPPING"):
            onnx2torch_resize._MODES_MAPPING[("cubic", 2)] = "bilinear"
    except Exception:
        pass

    # onnx2torch's converter registry has incomplete coverage for opset 18.
    # The Depth Anything v3 ONNX export uses opset 18, but most operators are
    # compatible with earlier converter implementations. Add a fallback that
    # retries older opset versions when a v18 converter isn't registered.
    original_get_converter = onnx2torch_converter.get_converter

    def get_converter_with_fallback(domain, operation_type, version):  # type: ignore[no-untyped-def]
        try:
            return original_get_converter(domain=domain, operation_type=operation_type, version=version)
        except NotImplementedError:
            if version <= 1:
                raise
            for fallback_version in (13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1):
                if fallback_version >= version:
                    continue
                try:
                    return original_get_converter(
                        domain=domain,
                        operation_type=operation_type,
                        version=fallback_version,
                    )
                except NotImplementedError:
                    continue
            raise

    onnx2torch_converter.get_converter = get_converter_with_fallback  # type: ignore[assignment]

    # Use dynamic layer norm (compute normalized_shape from runtime tensor shape)
    # because shape inference for this ONNX graph includes symbolic dims and can
    # produce invalid static normalized_shape values during import.
    try:
        from onnx2torch.node_converters.layer_norm import (  # type: ignore
            AXIS_DEFAULT_VALUE,
            EPSILON_DEFAULT_VALUE,
            OnnxLayerNorm,
        )
        from onnx2torch.node_converters.registry import (  # type: ignore
            OperationDescription,
            _CONVERTER_REGISTRY,
        )
        from onnx2torch.utils.common import (  # type: ignore
            OperationConverterResult,
            onnx_mapping_from_node,
        )

        def _layer_norm_dynamic(node, graph):  # type: ignore[no-untyped-def]  # pylint: disable=unused-argument
            axis = node.attributes.get("axis", AXIS_DEFAULT_VALUE)
            epsilon = node.attributes.get("epsilon", EPSILON_DEFAULT_VALUE)
            return OperationConverterResult(
                torch_module=OnnxLayerNorm(axis=axis, epsilon=epsilon),
                onnx_mapping=onnx_mapping_from_node(node),
            )

        key = OperationDescription(domain="", operation_type="LayerNormalization", version=17)
        _CONVERTER_REGISTRY[key] = _layer_norm_dynamic
    except Exception:
        pass

    print(f"Loading ONNX: {onnx_path}")
    onnx_model = onnx.load(str(onnx_path))
    load_external_data_for_model(onnx_model, str(onnx_path.parent))

    # Some exports encode missing optional Clip inputs as empty strings ("").
    # onnx2torch treats "" as a real tensor name and fails, but for Clip the
    # position doesn't matter (optional min/max). Only normalize Clip nodes.
    for node in onnx_model.graph.node:
        if node.op_type != "Clip":
            continue
        if "" not in node.input:
            continue
        cleaned = [name for name in node.input if name != ""]
        del node.input[:]
        node.input.extend(cleaned)

    print("Converting ONNX -> Torch (onnx2torch)...")
    base_model = onnx2torch_convert(onnx_model)
    base_model.eval()

    # ImageNet normalization (common for ViT backbones). If Depth Anything v3 uses
    # different preprocessing, adjust these values.
    mean = torch.tensor([0.485, 0.456, 0.406]).view(1, 3, 1, 1)
    std = torch.tensor([0.229, 0.224, 0.225]).view(1, 3, 1, 1)

    class DepthAnythingV3Wrapper(torch.nn.Module):
        def __init__(self, model: torch.nn.Module) -> None:
            super().__init__()
            self.model = model

        def forward(self, image: torch.Tensor) -> torch.Tensor:
            # image: (N, 3, H, W) in [0, 1], RGB
            x = (image - mean.to(image.device)) / std.to(image.device)
            x = x.unsqueeze(1)  # (N, 1, 3, H, W)
            outputs = self.model(x)
            # ONNX outputs: predicted_depth, confidence, extrinsics, intrinsics
            depth = outputs[0] if isinstance(outputs, (list, tuple)) else outputs
            # Expected shapes: (N, 1, H, W) or (N, 1, 1, H, W)
            while depth.dim() > 4:
                depth = depth.squeeze(1)
            if depth.dim() == 4 and depth.shape[1] == 1:
                depth = depth[:, 0, :, :]
            return depth

    wrapped = DepthAnythingV3Wrapper(base_model).eval()

    example = torch.rand(1, 3, input_size, input_size)
    traced = torch.jit.trace(wrapped, example)

    # coremltools expects constant scalar values to be provided as 0-rank ndarrays
    # or numpy scalars. Some graphs can yield Python floats during value inference
    # (e.g. constant-folded sign/div patterns), which triggers:
    #   "Types should have zero-rank ndarray input, got 1.0 instead."
    # Monkeypatch the float scalar setters to auto-wrap Python scalars.
    try:
        from coremltools.converters.mil.mil.types import type_double  # type: ignore

        def _patch_scalar_setter(cls):  # type: ignore[no-untyped-def]
            prop = cls.val

            def _setter(self, v):  # type: ignore[no-untyped-def]
                if isinstance(v, (float, int)):
                    v = np.array(v)
                return prop.fset(self, v)

            cls.val = prop.setter(_setter)

        for _cls in (type_double.fp16, type_double.fp32, type_double.fp64):
            _patch_scalar_setter(_cls)
    except Exception:
        pass

    if output_path.exists():
        if output_path.is_dir():
            shutil.rmtree(output_path)
        else:
            output_path.unlink()

    print("Converting Torch -> Core ML (mlprogram)...")
    mlmodel = ct.convert(
        traced,
        source="pytorch",
        inputs=[
            ct.ImageType(
                name="image",
                shape=example.shape,
                scale=1 / 255.0,
                bias=[0.0, 0.0, 0.0],
                color_layout=ct.colorlayout.RGB,
            )
        ],
        minimum_deployment_target=ct.target.iOS17,
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
    )

    print(f"Saving: {output_path}")
    output_path.parent.mkdir(parents=True, exist_ok=True)
    mlmodel.save(str(output_path))

    # Quick sanity output for humans.
    try:
        spec = mlmodel.get_spec()
        print("Core ML inputs:", [i.name for i in spec.description.input])
        print("Core ML outputs:", [o.name for o in spec.description.output])
    except Exception:
        pass

    print("Done.")


if __name__ == "__main__":
    main()
