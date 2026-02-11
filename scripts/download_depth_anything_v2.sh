#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEST_DIR="${REPO_ROOT}/StereoShift/Resources"
MODEL_ID="${DEPTH_ANYTHING_V2_MODEL_ID:-apple/coreml-depth-anything-v2-small}"
MODEL_PACKAGE_NAME="${DEPTH_ANYTHING_V2_MODEL_PACKAGE_NAME:-DepthAnythingV2SmallF32.mlpackage}"
DEST_MODEL="${DEST_DIR}/${MODEL_PACKAGE_NAME}"
INCLUDE_PATTERN="${MODEL_PACKAGE_NAME}/**"
ZIP_NAME="${MODEL_PACKAGE_NAME}.zip"

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
  local destination="$1"
  if [[ "${DOWNLOAD_TOOL}" == "hf" ]]; then
    hf download "${MODEL_ID}" --repo-type model --include "${INCLUDE_PATTERN}" --include "${ZIP_NAME}" --local-dir "${destination}" >/dev/null
  else
    huggingface-cli download "${MODEL_ID}" --repo-type model --include "${INCLUDE_PATTERN}" --include "${ZIP_NAME}" --local-dir "${destination}" >/dev/null
  fi
}

find_package() {
  local search_dir="$1"
  local found_model
  local found_archive
  local unzip_dir

  found_model="$(find "${search_dir}" -type d -name "${MODEL_PACKAGE_NAME}" | head -n 1 || true)"
  if [[ -n "${found_model}" ]]; then
    echo "${found_model}"
    return 0
  fi

  found_archive="$(find "${search_dir}" -type f -name "${ZIP_NAME}" | head -n 1 || true)"
  if [[ -z "${found_archive}" ]]; then
    return 1
  fi

  unzip_dir="${search_dir}/unzipped"
  mkdir -p "${unzip_dir}"
  unzip -q -o "${found_archive}" -d "${unzip_dir}"
  found_model="$(find "${unzip_dir}" -type d -name "${MODEL_PACKAGE_NAME}" | head -n 1 || true)"
  if [[ -n "${found_model}" ]]; then
    echo "${found_model}"
    return 0
  fi

  return 1
}

echo "Downloading ${MODEL_PACKAGE_NAME} from ${MODEL_ID}..."
if ! download_model "${TMP_DIR}"; then
  echo "Failed to download from ${MODEL_ID}."
  exit 1
fi

FOUND_MODEL="$(find_package "${TMP_DIR}" || true)"
if [[ -z "${FOUND_MODEL}" ]]; then
  cat <<MSG
Could not find ${MODEL_PACKAGE_NAME} in ${MODEL_ID}.

You can override defaults:
  DEPTH_ANYTHING_V2_MODEL_ID=<repo-id>
  DEPTH_ANYTHING_V2_MODEL_PACKAGE_NAME=<package-name>.mlpackage
MSG
  exit 1
fi

rm -rf "${DEST_MODEL}"
cp -R "${FOUND_MODEL}" "${DEST_MODEL}"
echo "Model installed to: ${DEST_MODEL}"
