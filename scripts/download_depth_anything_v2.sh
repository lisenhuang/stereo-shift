#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEST_DIR="${REPO_ROOT}/StereoShift/Resources"
DEST_MODEL="${DEST_DIR}/DepthAnythingV2SmallFP16.mlpackage"
MODEL_ID="apple/coreml-depth-anything-v2-small"

mkdir -p "${DEST_DIR}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

if command -v hf >/dev/null 2>&1; then
  hf download "${MODEL_ID}" --repo-type model --include "*.mlpackage/**" --local-dir "${TMP_DIR}"
elif command -v huggingface-cli >/dev/null 2>&1; then
  huggingface-cli download "${MODEL_ID}" --repo-type model --include "*.mlpackage/**" --local-dir "${TMP_DIR}"
else
  cat <<'MSG'
Missing Hugging Face CLI.
Install one of:
  pip install -U huggingface_hub
Then run this script again.
MSG
  exit 1
fi

FOUND_MODEL="$(find "${TMP_DIR}" -type d -name "*.mlpackage" | head -n 1)"
if [[ -z "${FOUND_MODEL}" ]]; then
  echo "No .mlpackage was downloaded from ${MODEL_ID}."
  exit 1
fi

rm -rf "${DEST_MODEL}"
cp -R "${FOUND_MODEL}" "${DEST_MODEL}"

echo "Model installed to: ${DEST_MODEL}"
