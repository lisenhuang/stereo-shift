#!/usr/bin/env python3
"""
Convert a monocular depth model to a Core ML package that satisfies StereoShift's
"canonical depth" contract, so the app can take the zero-cost passthrough path:

  input : one RGB image (fixed size, multiple of 14 per side), ImageNet
          normalization baked into the graph
  output: ONE Grayscale16Half image named "depth", values in [0, 1],
          larger = nearer (inverse depth divided by its max)

This is what Apple's `coreml-depth-anything-v2-small` package already does. For
models that predict DEPTH (larger = farther, e.g. Depth Anything 3) pass
`--semantics depth` and the wrapper applies `1 / max(d, eps)` BEFORE normalizing —
never `1 - x`, which flattens the foreground.

Model loaders
  --loader transformers --model-id <hf id>
        Uses transformers.AutoModelForDepthEstimation. Works for Depth Anything V2 /
        Distill-Any-Depth style checkpoints (and Depth Anything 3 once transformers
        ships a port). Output is taken from `.predicted_depth`.
  --loader torchscript --model-path <file.pt>
        A TorchScript module whose forward(image_nchw_normalized) returns the depth
        map as (N, H, W) or (N, 1, H, W). Use this for Depth Anything 3 any-view
        models: export them with john-rocky/CoreML-Models
        `conversion_scripts/convert_depth_anything_v3.py --size 504` style rewrites
        (RoPE cartesian_prod, camera-token insert, meshgrid) to TorchScript first,
        then run this script so the canonical tail is added.

Facts baked in (verified against coremltools docs):
  * GRAYSCALE_FLOAT16 image outputs require an explicit
    minimum_deployment_target >= iOS16; we use iOS17 to match the app.
  * With an iOS16+ target and fp16 compute precision, unannotated outputs default
    to float16, so every dtype here is pinned explicitly.

Requirements: python3, torch, coremltools >= 7 (and transformers for that loader).

Example
  python3 scripts/convert_depth_model_canonical.py \
      --loader torchscript --model-path /tmp/da3_small_504.pt \
      --semantics depth --width 504 --height 504 \
      --output /tmp/DepthAnythingV3SmallF16.mlpackage --parity-check
"""

from __future__ import annotations

import argparse
import shutil
import sys
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--loader", choices=["transformers", "torchscript"], required=True)
    parser.add_argument("--model-id", help="Hugging Face model id (transformers loader)")
    parser.add_argument("--model-path", help="TorchScript .pt file (torchscript loader)")
    parser.add_argument("--semantics", choices=["inverse", "depth"], required=True,
                        help="'inverse' if the model predicts disparity/inverse depth (larger = nearer), "
                             "'depth' if it predicts depth (larger = farther)")
    parser.add_argument("--width", type=int, default=518, help="input width, multiple of 14 (default 518)")
    parser.add_argument("--height", type=int, default=392, help="input height, multiple of 14 (default 392)")
    parser.add_argument("--eps", type=float, default=1e-6, help="floor for depth before the reciprocal")
    parser.add_argument("--output", required=True, help="output .mlpackage path")
    parser.add_argument("--parity-check", action="store_true",
                        help="run the torch wrapper and the Core ML package on a test image and compare")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if args.width % 14 or args.height % 14:
        raise SystemExit("--width and --height must be multiples of 14 (DINOv2 patch size)")

    import numpy as np  # type: ignore
    import torch  # type: ignore
    import coremltools as ct  # type: ignore

    base = load_model(args, torch)
    base.eval()

    mean = torch.tensor([0.485, 0.456, 0.406]).view(1, 3, 1, 1)
    std = torch.tensor([0.229, 0.224, 0.225]).view(1, 3, 1, 1)

    class CanonicalDepthWrapper(torch.nn.Module):
        """image in [0, 1] RGB → normalized inverse depth in [0, 1], larger = nearer."""

        def __init__(self, model: torch.nn.Module, semantics: str, eps: float) -> None:
            super().__init__()
            self.model = model
            self.semantics = semantics
            self.eps = eps

        def forward(self, image: torch.Tensor) -> torch.Tensor:
            x = (image - mean.to(image.device)) / std.to(image.device)
            raw = self.model(x)
            depth = extract_depth(raw)
            # Bring to (N, 1, H, W) at the INPUT resolution so the app's aspect-fill
            # inverse mapping round-trips exactly.
            while depth.dim() > 4:
                depth = depth.squeeze(1)
            if depth.dim() == 3:
                depth = depth.unsqueeze(1)
            if depth.shape[-2:] != image.shape[-2:]:
                depth = torch.nn.functional.interpolate(depth, size=image.shape[-2:], mode="bilinear", align_corners=False)
            if self.semantics == "depth":
                # Reciprocal, not 1 - x: keeps near-range separation intact.
                depth = 1.0 / torch.clamp(depth, min=self.eps)
            depth = torch.relu(depth)
            # Divide-by-max, exactly like Apple's V2 package (no min subtraction):
            # the app's percentile normalize does the rest on the GPU.
            peak = torch.amax(depth, dim=(1, 2, 3), keepdim=True)
            depth = depth / torch.clamp(peak, min=1e-6)
            return depth

    wrapped = CanonicalDepthWrapper(base, args.semantics, args.eps).eval()
    example = torch.rand(1, 3, args.height, args.width)
    with torch.no_grad():
        traced = torch.jit.trace(wrapped, example)

    output_path = Path(args.output).expanduser().resolve()
    if output_path.exists():
        shutil.rmtree(output_path) if output_path.is_dir() else output_path.unlink()

    print("Converting to Core ML (mlprogram, fp16, iOS 17)…")
    mlmodel = ct.convert(
        traced,
        source="pytorch",
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS17,
        compute_precision=ct.precision.FLOAT16,
        inputs=[ct.ImageType(name="image", shape=example.shape, scale=1 / 255.0, color_layout=ct.colorlayout.RGB)],
        outputs=[ct.ImageType(name="depth", color_layout=ct.colorlayout.GRAYSCALE_FLOAT16)],
    )
    mlmodel.short_description = (
        f"StereoShift canonical depth contract v1: Grayscale16Half 'depth' in [0,1], larger = nearer "
        f"({args.semantics} model, {args.width}x{args.height})."
    )
    mlmodel.save(str(output_path))
    print(f"Saved {output_path}")

    validate_package(mlmodel, args.width, args.height)

    if args.parity_check:
        parity_check(mlmodel, wrapped, args.width, args.height, np, torch)


def load_model(args: argparse.Namespace, torch):  # type: ignore[no-untyped-def]
    if args.loader == "transformers":
        if not args.model_id:
            raise SystemExit("--model-id is required with --loader transformers")
        from transformers import AutoModelForDepthEstimation  # type: ignore

        model = AutoModelForDepthEstimation.from_pretrained(args.model_id)

        class TransformersAdapter(torch.nn.Module):
            def __init__(self, inner):  # type: ignore[no-untyped-def]
                super().__init__()
                self.inner = inner

            def forward(self, x):  # type: ignore[no-untyped-def]
                return self.inner(pixel_values=x).predicted_depth

        return TransformersAdapter(model)

    if not args.model_path:
        raise SystemExit("--model-path is required with --loader torchscript")
    return torch.jit.load(args.model_path, map_location="cpu")


def extract_depth(raw):  # type: ignore[no-untyped-def]
    """First tensor of whatever the model returned (tuple/list/dict/tensor)."""
    if isinstance(raw, (list, tuple)):
        return raw[0]
    if isinstance(raw, dict):
        for key in ("depth", "predicted_depth"):
            if key in raw:
                return raw[key]
        return next(iter(raw.values()))
    return raw


def validate_package(mlmodel, width: int, height: int) -> None:  # type: ignore[no-untyped-def]
    spec = mlmodel.get_spec()
    inputs = list(spec.description.input)
    outputs = list(spec.description.output)
    problems = []
    if len(inputs) != 1 or not inputs[0].type.HasField("imageType"):
        problems.append("expected exactly one image input")
    else:
        image = inputs[0].type.imageType
        if image.width != width or image.height != height:
            problems.append(f"input is {image.width}x{image.height}, expected {width}x{height}")
    if len(outputs) != 1 or outputs[0].name != "depth" or not outputs[0].type.HasField("imageType"):
        problems.append("expected exactly one image output named 'depth'")
    else:
        # GRAYSCALE_FLOAT16 == ImageFeatureType.ColorSpace.GRAYSCALE_FLOAT16 (value 30)
        color_space = outputs[0].type.imageType.colorSpace
        if color_space != 30:
            problems.append(f"output color space is {color_space}, expected GRAYSCALE_FLOAT16 (30)")
    if problems:
        raise SystemExit("Contract validation FAILED: " + "; ".join(problems))
    print("Contract validation OK: image in → Grayscale16Half 'depth' out")


def parity_check(mlmodel, wrapped, width: int, height: int, np, torch) -> None:  # type: ignore[no-untyped-def]
    from PIL import Image  # type: ignore

    rng = np.random.default_rng(7)
    pixels = (rng.random((height, width, 3)) * 255).astype(np.uint8)
    # Add structure so the depth head produces a non-flat map.
    yy, xx = np.mgrid[0:height, 0:width]
    pixels[..., 0] = (255 * xx / max(width - 1, 1)).astype(np.uint8)
    pixels[..., 1] = (255 * yy / max(height - 1, 1)).astype(np.uint8)
    image = Image.fromarray(pixels, "RGB")

    with torch.no_grad():
        reference = wrapped(torch.from_numpy(pixels).permute(2, 0, 1).unsqueeze(0).float() / 255.0)[0, 0].numpy()
    prediction = mlmodel.predict({"image": image})["depth"]
    predicted = np.array(prediction, dtype=np.float32)
    if predicted.ndim == 3:
        predicted = predicted[..., 0]
    error = float(np.abs(predicted - reference).mean())
    corr = float(np.corrcoef(predicted.ravel(), reference.ravel())[0, 1])
    print(f"Parity: mean |Δ| = {error:.5f}, Pearson r = {corr:.5f}, range = [{predicted.min():.3f}, {predicted.max():.3f}]")
    if corr < 0.999 or predicted.max() > 1.0001 or predicted.min() < 0:
        raise SystemExit("Parity check FAILED (see numbers above)")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
