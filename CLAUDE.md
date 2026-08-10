# CLAUDE.md

Guidance for AI assistants (Claude Code) working in this repository.

## ⚠️ ALWAYS bump the version + build number on every code change

Whenever you change app code (Swift, Metal, resources, or build settings) as part of a
task, you MUST increment the version and build number **in the same change**:

- **Build number** — `CURRENT_PROJECT_VERSION`: increment by 1 every time (e.g. `18` → `19`).
- **Version** — `MARKETING_VERSION`: bump the patch component for normal changes
  (e.g. `1.2.2` → `1.2.3`). Use a minor bump (`1.3.0`) only for a notable feature, and reset patch to 0.

Both keys live in `StereoShift.xcodeproj/project.pbxproj` and each appears **8 times**
(StereoShift + StereoShiftShareExtension targets × Debug/Release × build configs).
**All occurrences must stay identical** — update every one, or the build is inconsistent.

Current values: `MARKETING_VERSION = 1.3.0`, `CURRENT_PROJECT_VERSION = 23`.

Quick way to bump the build number across all 8 occurrences (run from repo root, then
verify with the grep below):

```bash
# Build number: 23 -> 24 (the FROM value must match "Current values" above)
sed -i '' 's/CURRENT_PROJECT_VERSION = 23;/CURRENT_PROJECT_VERSION = 24;/g' StereoShift.xcodeproj/project.pbxproj
# Version: 1.3.0 -> 1.3.1
sed -i '' 's/MARKETING_VERSION = 1.3.0;/MARKETING_VERSION = 1.3.1;/g' StereoShift.xcodeproj/project.pbxproj

# Verify both now show a single, updated value across all 8 sites:
grep -oE '(MARKETING_VERSION|CURRENT_PROJECT_VERSION) = [^;]+' StereoShift.xcodeproj/project.pbxproj | sort | uniq -c
```

Mention the new version/build in your summary so it's visible in review.

> Note: CLAUDE.md is guidance Claude reads, not an enforced hook — it relies on the
> assistant following it. For a guaranteed, automatic bump on every edit, configure a
> hook in `.claude/settings.json` (ask, or use the `/update-config` skill).

## Project overview

StereoShift is an iOS 17+ SwiftUI app that converts 2D photos and videos into
side-by-side (SBS) stereo 3D entirely on-device. Depth comes from a Core ML model
(Depth Anything V2 Small F16); stereo views are synthesized by a Metal compute pipeline.

Layout (`StereoShift/`):
- `App/` — app entry point, theme, language
- `UI/` — SwiftUI flows (`HomeView`, `PhotoFlowView`, `VideoFlowView`, previews)
- `Core/` — the conversion pipeline (see below)
- `Resources/` — `DepthAnythingV2SmallF16.mlpackage` (the only depth model)

### Conversion pipeline (Core/)
- `DepthEstimator.swift` — Core ML depth inference + pre/post-processing
- `StereoRenderer.swift` — engine routing; computes disparity, depth stats, convergence;
  owns the Metal branch and CPU/CIKernel fallbacks
- `MetalStereoRenderer.swift` + `StereoShaders.metal` — the production GPU path:
  depth refine (RGB-guided joint bilateral, consumes the raw float16 model output and
  does the crop + upsample in one pass; the model input is aspect-fill stretched, so
  every model pixel is content) → per-eye directional max-dilate → light Gaussian
  feather → occlusion-ordered scanline-search inverse warp around a convergence plane
  (nearest surface wins by scan order; disocclusions stretch background) → SBS compose
- `VideoProcessor.swift` — AVFoundation read → per-frame depth + SBS → H.264 write;
  uses a `VideoTemporalSession` to smooth depth stats across frames
- `SpatialMediaConverter.swift` — splits MV-HEVC spatial media into SBS

Both UI flows force `renderEngine = .metal`, so the Metal path is what ships; the
CPU/CIKernel paths exist only as fallbacks. See `README.md` for the full pipeline writeup.

## Build & test

```bash
# Build (no signing needed)
xcodebuild -project StereoShift.xcodeproj -scheme StereoShift \
  -destination 'generic/platform=iOS Simulator' -configuration Debug build \
  CODE_SIGNING_ALLOWED=NO

# Test
xcodebuild -project StereoShift.xcodeproj -scheme StereoShift \
  -destination 'platform=iOS Simulator,name=iPhone 16' test CODE_SIGNING_ALLOWED=NO
```

Always confirm the project still builds before finishing a code change.

## Conventions

- `xcuserdata/` is gitignored and untracked — do not re-add it. Xcode rewrites the
  per-user scheme plist (`orderHint`) automatically; that churn is not project data.
- Keep new code consistent with the surrounding file's style and comment density.
- **Never commit automatically.** Make and stage changes, but only run `git commit`
  when the user explicitly asks. Leave the working tree for the user to review.
