#!/usr/bin/env python3
"""
Emits one entry for `StereoShift/Resources/depth-models.json` (see
`Core/DepthModelCatalog.swift`) describing a Core ML depth model hosted on Hugging Face.

Every byte count and SHA-256 in the entry comes from the Hub API or from hashing the
actual file — nothing is typed by hand:

  - The repo's current commit is pinned (`sha` from /api/models/<repo>), or `--revision`
    is used verbatim, so the download URLs never move under an installed app.
  - `/api/models/<repo>/tree/<sha>/<package-dir>?recursive=true` lists the files. For
    LFS files the Hub reports `lfs.oid`, which IS the SHA-256 of the content, so no
    download is needed. Small non-LFS files (e.g. `Manifest.json`) are downloaded and
    hashed locally.
  - With `--local <path/to/Model.mlpackage>` the tree is walked and hashed on disk
    instead; when the Hub is reachable the local set is cross-checked against it so an
    entry can never describe files that are not actually hosted.

Each file gets two mirrors, in priority order:

  1. https://huggingface.co/<repo>/resolve/<sha>/<package-dir>/<path>
     (LFS files redirect to signed CDN URLs that expire after about an hour, which is
     why the app treats resume data as disposable and simply restarts a failed file.)
  2. <github-release-base>/<model-id>-<version>-<path with "/" replaced by "_">
     GitHub release assets cannot contain "/", so the package-relative path is
     flattened, e.g.
       Data/com.apple.CoreML/weights/weight.bin
     becomes the asset
       DepthAnythingV3SmallF16-2026.09.1-Data_com.apple.CoreML_weights_weight.bin
     Upload the same bytes (same SHA-256) under that name when cutting the release.

Files are listed smallest first so a bad package fails on `Manifest.json` /
`model.mlmodel` before the multi-hundred-megabyte `weight.bin` is fetched.

Only Apache-2.0 / MIT repos are accepted (the app refuses anything else too). The
Depth Anything 3 Large / Giant / Nested weights and Depth Anything V2 Base / Large
are CC-BY-NC and must never be added to the catalog.

Examples:

  # DA3 Small, pinned to the repo's current commit:
  scripts/emit_depth_model_catalog_entry.py \\
      --repo mlboydaisuke/Depth-Anything-3-Small-CoreML \\
      --package-dir DepthAnythingV3_small_504.mlpackage \\
      --model-id DepthAnythingV3SmallF16 --version 2026.09.1 --tier small \\
      --min-ram-gb 3 --recommended-ram-gb 4 --video-recommended

  # Same, but hash a local copy and validate the Core ML contract with coremltools:
  scripts/emit_depth_model_catalog_entry.py ... \\
      --local ~/Downloads/DepthAnythingV3_small_504.mlpackage --validate

Standard library only (urllib, json, hashlib, argparse). `coremltools` is imported
only when `--validate` is passed.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

HF_API_BASE = "https://huggingface.co/api/models"
HF_RESOLVE_BASE = "https://huggingface.co"
DEFAULT_GITHUB_RELEASE_BASE = "https://github.com/lisenhuang/stereo-shift/releases/download/models-v1"

# Mirrors `DepthModelCatalogEntry.allowedLicenses` (SPDX id) and the Hub's card spelling.
ALLOWED_LICENSES = {"Apache-2.0", "MIT"}
HUB_LICENSE_TO_SPDX = {"apache-2.0": "Apache-2.0", "mit": "MIT"}
LICENSE_URLS = {
    "Apache-2.0": "https://www.apache.org/licenses/LICENSE-2.0",
    "MIT": "https://opensource.org/license/mit",
}

# Mirrors `DepthModel` raw values in Core/Stereo3DOptions.swift. Unknown ids are not
# rejected (the app treats them as "requires app update"), only warned about.
KNOWN_MODEL_IDS = {
    "DepthAnythingV2SmallF16",
    "DepthAnythingV3SmallF16",
    "DepthAnythingV3BaseF16",
    "DepthAnythingV3MonoLargeF16",
}

TIERS = ("small", "base", "large")
FORMATS = ("mlpackage", "mlmodelc")
DEPTH_OUTPUT_NAME = "depth"
USER_AGENT = "StereoShift-catalog-tool/1.0"


@dataclass
class CatalogFile:
    path: str  # relative to the package directory, "/"-separated
    bytes: int
    sha256: str


# MARK: - Hub access


def fetch_json(url: str):
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "application/json"})
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)


def fetch_bytes(url: str) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=300) as response:
        return response.read()


def sha256_of_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_of_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def repo_info(repo: str) -> dict:
    return fetch_json(f"{HF_API_BASE}/{repo}")


def resolve_url(repo: str, revision: str, package_dir: str, relative_path: str) -> str:
    quoted = "/".join(urllib.parse.quote(part) for part in f"{package_dir}/{relative_path}".split("/"))
    return f"{HF_RESOLVE_BASE}/{repo}/resolve/{revision}/{quoted}"


def github_asset_name(model_id: str, version: str, relative_path: str) -> str:
    return f"{model_id}-{version}-{relative_path.replace('/', '_')}"


def github_mirror_url(base: str, model_id: str, version: str, relative_path: str) -> str:
    return f"{base.rstrip('/')}/{urllib.parse.quote(github_asset_name(model_id, version, relative_path))}"


def hub_files(repo: str, revision: str, package_dir: str) -> list[CatalogFile]:
    """Lists the package's files from the Hub, hashing only what the API does not hash."""
    quoted_dir = "/".join(urllib.parse.quote(part) for part in package_dir.split("/"))
    listing = fetch_json(f"{HF_API_BASE}/{repo}/tree/{revision}/{quoted_dir}?recursive=true")
    prefix = package_dir.rstrip("/") + "/"
    files: list[CatalogFile] = []

    for item in listing:
        if item.get("type") != "file":
            continue
        full_path = item["path"]
        if not full_path.startswith(prefix):
            raise SystemExit(f"Unexpected path outside the package: {full_path}")
        relative_path = full_path[len(prefix):]
        size = int(item["size"])
        lfs = item.get("lfs")
        if lfs and lfs.get("oid"):
            digest = str(lfs["oid"]).lower()
            if int(lfs.get("size", size)) != size:
                raise SystemExit(f"LFS size disagrees with tree size for {full_path}")
        else:
            # Non-LFS (small) file: the Hub only exposes the git blob id, so hash the bytes.
            url = resolve_url(repo, revision, package_dir, relative_path)
            print(f"Hashing non-LFS file {relative_path} ({size} bytes)…", file=sys.stderr)
            data = fetch_bytes(url)
            if len(data) != size:
                raise SystemExit(f"Downloaded {len(data)} bytes for {relative_path}, expected {size}")
            digest = sha256_of_bytes(data)
        validate_digest(digest, relative_path)
        files.append(CatalogFile(path=relative_path, bytes=size, sha256=digest))

    if not files:
        raise SystemExit(f"No files found under {package_dir} in {repo}@{revision}")
    return files


# MARK: - Local access


def local_files(package_path: Path) -> list[CatalogFile]:
    if not package_path.is_dir():
        raise SystemExit(f"--local must point at a package directory: {package_path}")
    files: list[CatalogFile] = []
    for root, dirnames, filenames in os.walk(package_path):
        dirnames[:] = sorted(d for d in dirnames if not d.startswith("."))
        for name in sorted(filenames):
            if name.startswith("."):
                continue
            file_path = Path(root) / name
            relative_path = file_path.relative_to(package_path).as_posix()
            print(f"Hashing {relative_path}…", file=sys.stderr)
            files.append(CatalogFile(path=relative_path, bytes=file_path.stat().st_size, sha256=sha256_of_file(file_path)))
    if not files:
        raise SystemExit(f"No files found under {package_path}")
    return files


def cross_check(local: list[CatalogFile], remote: list[CatalogFile]) -> None:
    """The entry's URLs point at the Hub, so the local tree must be byte-identical to it."""
    local_by_path = {f.path: f for f in local}
    remote_by_path = {f.path: f for f in remote}
    problems: list[str] = []
    for path in sorted(set(local_by_path) | set(remote_by_path)):
        a = local_by_path.get(path)
        b = remote_by_path.get(path)
        if a is None:
            problems.append(f"missing locally: {path}")
        elif b is None:
            problems.append(f"not on the Hub: {path}")
        elif a.bytes != b.bytes or a.sha256 != b.sha256:
            problems.append(f"differs from the Hub: {path} (local {a.bytes} B {a.sha256[:12]}…, hub {b.bytes} B {b.sha256[:12]}…)")
    if problems:
        raise SystemExit("Local package does not match the pinned Hub revision:\n  " + "\n  ".join(problems))


# MARK: - Validation


def validate_digest(digest: str, label: str) -> None:
    if len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest):
        raise SystemExit(f"Bad SHA-256 for {label}: {digest}")


def validate_package_layout(files: list[CatalogFile], fmt: str) -> None:
    paths = {f.path for f in files}
    if fmt == "mlpackage":
        required = {"Manifest.json", "Data/com.apple.CoreML/model.mlmodel"}
        missing = required - paths
        if missing:
            raise SystemExit(f"Package is missing required .mlpackage files: {sorted(missing)}")
        if not any(p.startswith("Data/com.apple.CoreML/weights/") for p in paths):
            raise SystemExit("Package has no weights under Data/com.apple.CoreML/weights/")
    for f in files:
        if f.bytes <= 0:
            raise SystemExit(f"Zero-length file in package: {f.path}")


def validate_with_coremltools(package_path: Path) -> tuple[int, int]:
    """Checks the contract `DepthOutputAdapter.validateContract` enforces at load time:
    exactly one image input with a fixed size, and an output named `depth`.
    Returns (inputWidth, inputHeight) read from the model."""
    try:
        import coremltools as ct  # type: ignore
    except ImportError as error:
        raise SystemExit("--validate needs coremltools: pip install coremltools") from error

    spec = ct.utils.load_spec(str(package_path))
    description = spec.description
    image_inputs = [i for i in description.input if i.type.WhichOneof("Type") == "imageType"]
    if len(image_inputs) != 1:
        raise SystemExit(f"Expected exactly one image input, found {len(image_inputs)} "
                         f"(inputs: {[i.name for i in description.input]})")
    image_type = image_inputs[0].type.imageType
    width, height = int(image_type.width), int(image_type.height)
    if width <= 0 or height <= 0:
        raise SystemExit("Image input does not have a fixed size; the app needs a fixed input.")

    output_names = [o.name for o in description.output]
    if DEPTH_OUTPUT_NAME not in output_names:
        raise SystemExit(f"No output named \"{DEPTH_OUTPUT_NAME}\" (outputs: {output_names})")
    print(f"coremltools: {width}×{height} image input, outputs {output_names} — OK", file=sys.stderr)
    return width, height


def spdx_license(card_license: Optional[str], override: Optional[str]) -> str:
    if override:
        if override not in ALLOWED_LICENSES:
            raise SystemExit(f"--license must be one of {sorted(ALLOWED_LICENSES)}; CC-BY-NC models may not be added.")
        return override
    if not card_license:
        raise SystemExit("The repo does not declare a license; pass --license Apache-2.0 or MIT only if you have verified it.")
    spdx = HUB_LICENSE_TO_SPDX.get(str(card_license).lower())
    if spdx is None:
        raise SystemExit(f"Repo license \"{card_license}\" is not redistributable in the app; refusing to emit an entry.")
    return spdx


# MARK: - Entry


def build_entry(args: argparse.Namespace, revision: str, license_id: str, files: list[CatalogFile],
                input_width: int, input_height: int) -> dict:
    package_name = Path(args.package_dir.rstrip("/")).name
    if not package_name.endswith(f".{args.format}"):
        raise SystemExit(f"Package name {package_name} does not end with .{args.format}")

    ordered = sorted(files, key=lambda f: (f.bytes, f.path))
    catalog_files = [
        {
            "path": f.path,
            "urls": [
                resolve_url(args.repo, revision, args.package_dir, f.path),
                github_mirror_url(args.github_release_base, args.model_id, args.version, f.path),
            ],
            "bytes": f.bytes,
            "sha256": f.sha256,
        }
        for f in ordered
    ]

    # Key order mirrors `DepthModelCatalogEntry` so diffs against the catalog stay readable.
    return {
        "id": args.model_id,
        "version": args.version,
        "format": args.format,
        "packageName": package_name,
        "tier": args.tier,
        "license": license_id,
        "licenseURL": args.license_url or LICENSE_URLS[license_id],
        "sourceURL": f"{HF_RESOLVE_BASE}/{args.repo}",
        "inputWidth": input_width,
        "inputHeight": input_height,
        "minimumOS": args.minimum_os,
        "minimumPhysicalMemoryGB": float(args.min_ram_gb),
        "recommendedPhysicalMemoryGB": float(args.recommended_ram_gb),
        "estimatedPeakMemoryMB": args.estimated_peak_memory_mb,
        "visible": not args.hidden,
        "recommended": args.recommended,
        "videoRecommended": args.video_recommended,
        "files": catalog_files,
        "provenance": {
            "sourceRepo": args.repo,
            "sourceRevision": revision,
            "converter": args.converter,
        },
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", required=True, help="Hugging Face repo id, e.g. mlboydaisuke/Depth-Anything-3-Small-CoreML")
    parser.add_argument("--package-dir", required=True, help="Path of the .mlpackage / .mlmodelc directory inside the repo")
    parser.add_argument("--model-id", required=True, help="A DepthModel rawValue, e.g. DepthAnythingV3SmallF16")
    parser.add_argument("--version", required=True, help="Catalog version string, e.g. 2026.09.1 (bumping forces a re-download)")
    parser.add_argument("--tier", required=True, choices=TIERS)
    parser.add_argument("--min-ram-gb", required=True, type=float, help="Below this the entry is blocked on iOS devices")
    parser.add_argument("--recommended-ram-gb", required=True, type=float, help="Below this the entry shows a warning")
    parser.add_argument("--video-recommended", action="store_true", help="Mark the model as suitable for video")
    parser.add_argument("--recommended", action="store_true", help="Mark the model as the recommended pick")
    parser.add_argument("--hidden", action="store_true", help="Emit visible=false (kept for staged rollouts)")
    parser.add_argument("--format", default="mlpackage", choices=FORMATS)
    parser.add_argument("--revision", help="Pin this commit instead of the repo's current sha")
    parser.add_argument("--license", help="SPDX id override (Apache-2.0 or MIT only)")
    parser.add_argument("--license-url", help="Override the license URL")
    parser.add_argument("--minimum-os", default="17.0")
    parser.add_argument("--input-width", type=int, default=504, help="Model input width (overridden by --validate)")
    parser.add_argument("--input-height", type=int, default=504, help="Model input height (overridden by --validate)")
    parser.add_argument("--estimated-peak-memory-mb", type=int, default=None, help="Measured on device; omit until known")
    parser.add_argument("--converter", default=None, help="Free-text provenance, e.g. the conversion script used")
    parser.add_argument("--github-release-base", default=DEFAULT_GITHUB_RELEASE_BASE,
                        help="GitHub Releases download base used for the second mirror URL")
    parser.add_argument("--local", type=Path, default=None,
                        help="Hash a local package tree instead of listing the Hub (cross-checked when reachable)")
    parser.add_argument("--validate", action="store_true",
                        help="Load the local package with coremltools and check the input/output contract (needs --local)")
    parser.add_argument("--output", type=Path, default=None, help="Write the entry here instead of stdout")
    args = parser.parse_args()

    if args.validate and args.local is None:
        parser.error("--validate requires --local")
    if args.min_ram_gb > args.recommended_ram_gb:
        parser.error("--min-ram-gb must not exceed --recommended-ram-gb")
    if "/" not in args.repo:
        parser.error("--repo must look like <owner>/<name>")
    if args.model_id not in KNOWN_MODEL_IDS:
        print(f"warning: {args.model_id} is not a DepthModel case; the app will show it as \"Requires app update\".",
              file=sys.stderr)
    return args


def main() -> None:
    args = parse_args()

    # 1. Pin the revision and check the license from the model card.
    card_license: Optional[str] = None
    revision = args.revision
    info: Optional[dict] = None
    try:
        info = repo_info(args.repo)
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError) as error:
        if revision is None or args.license is None:
            raise SystemExit(f"Could not reach the Hugging Face API for {args.repo}: {error}. "
                             "Pass --revision and --license to work offline.") from error
        print(f"warning: Hub unreachable ({error}); trusting --revision/--license.", file=sys.stderr)
    if info is not None:
        card_license = (info.get("cardData") or {}).get("license")
        if revision is None:
            revision = info.get("sha")
            if not revision:
                raise SystemExit("The Hub did not report a commit sha; pass --revision.")
    license_id = spdx_license(card_license, args.license)
    print(f"{args.repo} @ {revision} ({license_id})", file=sys.stderr)

    # 2. Collect files: from the Hub, or from disk (cross-checked against the Hub).
    if args.local is not None:
        files = local_files(args.local.expanduser().resolve())
        try:
            cross_check(files, hub_files(args.repo, revision, args.package_dir))
        except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError) as error:
            print(f"warning: could not cross-check against the Hub: {error}", file=sys.stderr)
    else:
        files = hub_files(args.repo, args.revision or revision, args.package_dir)
    validate_package_layout(files, args.format)

    # 3. Optional Core ML contract check; also the authoritative input size.
    input_width, input_height = args.input_width, args.input_height
    if args.validate:
        input_width, input_height = validate_with_coremltools(args.local.expanduser().resolve())

    entry = build_entry(args, revision, license_id, files, input_width, input_height)
    text = json.dumps(entry, indent=2) + "\n"
    if args.output:
        args.output.write_text(text)
        print(f"Wrote {args.output}", file=sys.stderr)
    else:
        sys.stdout.write(text)


if __name__ == "__main__":
    main()
