#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEST_DIR="${REPO_ROOT}/StereoShift/Resources"
DEST_MODEL="${DEST_DIR}/DepthAnythingV2BaseFP16.mlpackage"
DEFAULT_MODEL_IDS=(
  "apple/coreml-depth-anything-v2-base"
)

if [[ -n "${DEPTH_ANYTHING_V2_BASE_MODEL_ID:-}" ]]; then
  MODEL_IDS=("${DEPTH_ANYTHING_V2_BASE_MODEL_ID}")
else
  MODEL_IDS=("${DEFAULT_MODEL_IDS[@]}")
fi

mkdir -p "${DEST_DIR}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

if command -v hf >/dev/null 2>&1; then
  DOWNLOAD_TOOL="hf"
elif command -v huggingface-cli >/dev/null 2>&1; then
  DOWNLOAD_TOOL="huggingface-cli"
else
  cat <<'MSG'
Missing Hugging Face CLI.
Install one of:
  pip install -U huggingface_hub
Then run this script again.
MSG
  exit 1
fi

download_model() {
  local model_id="$1"
  local destination="$2"
  if [[ "${DOWNLOAD_TOOL}" == "hf" ]]; then
    hf download "${model_id}" --repo-type model --include "*.mlpackage/**" --include "*.mlpackage.zip" --local-dir "${destination}" >/dev/null
  else
    huggingface-cli download "${model_id}" --repo-type model --include "*.mlpackage/**" --include "*.mlpackage.zip" --local-dir "${destination}" >/dev/null
  fi
}

find_package() {
  local search_dir="$1"
  local found_model
  local found_archive
  local unzip_dir

  found_model="$(find "${search_dir}" -type d -name "*.mlpackage" | head -n 1 || true)"
  if [[ -n "${found_model}" ]]; then
    echo "${found_model}"
    return 0
  fi

  found_archive="$(find "${search_dir}" -type f -name "*.mlpackage.zip" | head -n 1 || true)"
  if [[ -z "${found_archive}" ]]; then
    return 1
  fi

  unzip_dir="${search_dir}/unzipped"
  mkdir -p "${unzip_dir}"
  unzip -q -o "${found_archive}" -d "${unzip_dir}"
  found_model="$(find "${unzip_dir}" -type d -name "*.mlpackage" | head -n 1 || true)"
  if [[ -n "${found_model}" ]]; then
    echo "${found_model}"
    return 0
  fi

  return 1
}

for model_id in "${MODEL_IDS[@]}"; do
  attempt_dir="${TMP_DIR}/$(echo "${model_id}" | tr '/:' '__')"
  mkdir -p "${attempt_dir}"
  echo "Trying ${model_id}..."

  if ! download_model "${model_id}" "${attempt_dir}"; then
    echo "Failed to download from ${model_id}."
    continue
  fi

  found_model="$(find_package "${attempt_dir}" || true)"
  if [[ -z "${found_model}" ]]; then
    echo "No .mlpackage asset found in ${model_id}."
    continue
  fi

  rm -rf "${DEST_MODEL}"
  cp -R "${found_model}" "${DEST_MODEL}"
  echo "Model installed from ${model_id} to: ${DEST_MODEL}"
  exit 0
done

cat <<MSG
Unable to download a Depth Anything v2 Base Core ML package automatically.

As of February 11, 2026, Apple's Core ML Depth Anything collection only lists:
  - apple/coreml-depth-anything-v2-small

To use ViT-B, provide a compatible Base Core ML package manually:
  ${DEST_MODEL}

Optional:
  DEPTH_ANYTHING_V2_BASE_MODEL_ID=<your-model-repo-id> ${0}
MSG

exit 1
