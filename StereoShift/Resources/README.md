# Resources

Two things live here that matter to the depth pipeline: the bundled depth model and
the catalog of models the app can download.

## Bundled model

Place the Depth Anything Core ML package in this folder using this name:

- `DepthAnythingV2SmallF16.mlpackage`

At runtime, `DepthEstimator` will load either:

- `DepthAnythingV2SmallF16.mlmodelc` (compiled model), or
- `DepthAnythingV2SmallF16.mlpackage` (compiled on first launch)

Use the helper script at `scripts/download_depth_anything_v2.sh` (run from the repo root):

- F16: `./scripts/download_depth_anything_v2.sh`

If automatic download fails, place a compatible `.mlpackage` here manually.

The bundled model is always available and is the fallback whenever a downloaded model
is missing or fails to load.

## `depth-models.json` — the depth model catalog

`depth-models.json` lists every depth model the app knows about, decoded by
`Core/DepthModelCatalog.swift` (`DepthModelCatalogLoader.loadBundled()`). The same
schema is used for an optional remote copy that is merged over the bundled one.

The catalog deliberately carries **no rendering semantics**. Output encoding, depth
convention, tuning and compute units are compiled into `DepthModel`
(`Core/Stereo3DOptions.swift`), so a bad catalog can never invert or flatten the stereo.
An entry is usable only when its `id` equals a `DepthModel.rawValue` and its `license`
is on `DepthModelCatalogEntry.allowedLicenses`.

```jsonc
{
  "schemaVersion": 1,        // must equal DepthModelCatalog.currentSchemaVersion
  "minAppBuild": 25,         // CFBundleVersion; older apps ignore a remote catalog
  "models": [ /* DepthModelCatalogEntry, bundled model first */ ]
}
```

Entry fields (`DepthModelCatalogEntry`):

| Field | Meaning |
|:--|:--|
| `id` | A `DepthModel.rawValue`. Unknown ids show as "Requires app update". |
| `version` | Download version; bumping it forces a re-download and is the on-disk directory name. |
| `format` | `bundled` (nothing to download), `mlpackage` (compiled on device) or `mlmodelc` (loaded as-is). |
| `packageName` | Directory name of the package, e.g. `DepthAnythingV3_small_504.mlpackage`. |
| `tier` | `small` / `base` / `large`, for grouping in Settings. |
| `license`, `licenseURL`, `sourceURL` | SPDX id (Apache-2.0 or MIT only), license text, and the model's source page. |
| `inputWidth`, `inputHeight` | Fixed model input size. |
| `minimumOS` | e.g. `"17.0"`; blocked on older systems. |
| `minimumPhysicalMemoryGB`, `recommendedPhysicalMemoryGB` | Blocked below the minimum, warned below the recommendation (never on a Mac). |
| `estimatedPeakMemoryMB` | Measured on device once known; `null` until then. |
| `visible`, `recommended`, `videoRecommended` | Presentation flags. |
| `files[]` | The per-file download contract, below. |
| `provenance` | `sourceRepo`, `sourceRevision` (pinned commit sha) and `converter`. |

### Per-file download contract

A package is downloaded **file by file**, never as an archive. Every entry in `files[]`
is:

```json
{
  "path": "Data/com.apple.CoreML/weights/weight.bin",
  "urls": ["https://huggingface.co/…/resolve/<sha>/<package>/<path>",
           "https://github.com/lisenhuang/stereo-shift/releases/download/models-v1/<asset>"],
  "bytes": 68565888,
  "sha256": "a4c37eb9…"
}
```

- `path` is relative to the package directory and is recreated verbatim inside
  `<packageName>` in the staging area (`DepthModelLibrary`).
- `urls` are mirrors in priority order: **Hugging Face first, GitHub Releases second**.
  The Hugging Face URL is pinned to the commit in `provenance.sourceRevision`, so the
  bytes behind it can never change. Hugging Face `resolve` URLs redirect to signed CDN
  URLs that expire after about an hour, so `URLSession` resume data may go stale; a
  failed file is restarted from the next mirror rather than resumed blindly.
- `bytes` and `sha256` are verified for every file before anything is compiled or
  installed. A mismatch is `StereoPipelineError.modelChecksumMismatch` and the staging
  directory is discarded.
- Files are listed smallest first (`Manifest.json`, `model.mlmodel`, `weight.bin`) so a
  wrong package fails before the multi-hundred-megabyte weights are fetched.
- Free space needed is `2.2 × totalBytes + 100 MB` for `mlpackage` (compiling writes a
  second tree) and `1.1 × totalBytes + 100 MB` for `mlmodelc`
  (`DepthModelCompatibility.requiredFreeBytes`).

Each `.mlpackage` is exactly three files: `Manifest.json`,
`Data/com.apple.CoreML/model.mlmodel` and `Data/com.apple.CoreML/weights/weight.bin`.

### GitHub Releases mirror naming

GitHub release assets cannot contain `/`, so the second URL of every file uses a
flattened asset name:

```
<model-id>-<version>-<path with "/" replaced by "_">
```

For example `Data/com.apple.CoreML/weights/weight.bin` of `DepthAnythingV3SmallF16`
version `2026.09.1` is uploaded to the `models-v1` release of
`github.com/lisenhuang/stereo-shift` as

```
DepthAnythingV3SmallF16-2026.09.1-Data_com.apple.CoreML_weights_weight.bin
```

The mirror must hold the **same bytes** (same SHA-256) as the Hugging Face file. When a
model's `version` is bumped, upload a fresh set of assets under the new version.

### Generating an entry

Never type sizes or hashes by hand. `scripts/emit_depth_model_catalog_entry.py`
(Python 3 standard library only) pins the repo's current commit, lists the package
through the Hugging Face API, takes each LFS file's `oid` as its SHA-256, downloads and
hashes the small non-LFS files (`Manifest.json`), and prints one entry ready to paste
into `models[]`:

```bash
scripts/emit_depth_model_catalog_entry.py \
    --repo mlboydaisuke/Depth-Anything-3-Small-CoreML \
    --package-dir DepthAnythingV3_small_504.mlpackage \
    --model-id DepthAnythingV3SmallF16 --version 2026.09.1 --tier small \
    --min-ram-gb 3 --recommended-ram-gb 4 --video-recommended \
    --converter "john-rocky/CoreML-Models conversion_scripts/convert_depth_anything_v3.py"
```

Useful options:

- `--revision <sha>` pins a specific commit instead of the repo head.
- `--local <path/to/Model.mlpackage>` hashes a local tree instead (cross-checked
  against the Hub when reachable), and `--validate` additionally loads it with
  `coremltools` to confirm the contract `DepthOutputAdapter.validateContract` enforces:
  exactly one fixed-size image input and an output named `depth`.
- `--github-release-base` changes the mirror base
  (default `https://github.com/lisenhuang/stereo-shift/releases/download/models-v1`).
- `--recommended`, `--hidden`, `--format mlmodelc`, `--minimum-os`,
  `--estimated-peak-memory-mb` set the remaining fields.

The script refuses repos whose model card license is not Apache-2.0 or MIT.

### Current entries

Sizes are decimal megabytes, as `ByteCountFormatter` shows them in Settings.

| id | Source | Package | Size |
|:--|:--|:--|:--|
| `DepthAnythingV2SmallF16` | `apple/coreml-depth-anything-v2-small` (bundled) | `DepthAnythingV2SmallF16.mlpackage` | in app |
| `DepthAnythingV3SmallF16` | `mlboydaisuke/Depth-Anything-3-Small-CoreML` | `DepthAnythingV3_small_504.mlpackage` | 68.9 MB |
| `DepthAnythingV3BaseF16` | `mlboydaisuke/Depth-Anything-3-Base-CoreML` | `DepthAnythingV3_base_504.mlpackage` | 233.5 MB |
| `DepthAnythingV3MonoLargeF16` | `sdkv2/DepthAnythingV3Mono-CoreML` | `DepthAnythingV3Mono.mlpackage` | 668.5 MB |

### Remote catalog

A remote copy of the same JSON may be fetched and merged over the bundled one
(`DepthModelCatalogLoader.merge`). The remote copy can add entries and change
versions, files, requirements and flags, but it can never remove or hide the bundled
model, and it is ignored entirely when its `schemaVersion` differs or its
`minAppBuild` is higher than the running app's build.

### License policy

Only Apache-2.0 and MIT models may appear in the catalog, bundled or remote. The
following are **CC-BY-NC** (non-commercial) and must never be added, however good they
look in a benchmark:

- Depth Anything 3 **Large**, **Giant** and **Nested** (`DA3-LARGE`, `DA3-GIANT`, `DA3NESTED-*`)
- Depth Anything V2 **Base** and **Large**

Apple Depth Pro is research-only and is excluded for the same reason. The Depth Anything
3 Small / Base weights and the DA3 Mono Large weights are Apache-2.0.

`StereoShiftTests/DepthModelCatalogTests.swift` checks the bundled catalog on every test
run: ids map to `DepthModel` cases, licenses are allowed, and every downloadable entry has
three files with 64-hex SHA-256s, byte counts and a Hugging Face + GitHub URL pair.
