#!/usr/bin/env bash

set -uo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: security-scan.sh <source-directory> <output-directory>

Runs the repository security checks used by the Azure DevOps pipeline.
Reports are written as SARIF files into the output directory.
EOF
}

if [[ "$#" -ne 2 ]]; then
  usage
  exit 2
fi

source_dir=$1
output_dir=$2

if [[ ! -d "$source_dir" ]]; then
  echo "Source directory does not exist: $source_dir" >&2
  exit 2
fi

mkdir -p "$output_dir"

# Pin both the release and the immutable image digest. This avoids a pipeline
# changing behavior because a mutable registry tag was moved.
gitleaks_image='zricethezav/gitleaks:v8.27.2@sha256:ebfeb6fd4f2c37fa371d3731ebfa662fdf80f93cd37d3b4771bb82263edff8d0'
trivy_image='aquasec/trivy:0.66.0@sha256:086971aaf400beebd94e8300fd8ea623774419597169156cec56eec5b00dfb1e'

gitleaks_status=0
trivy_status=0

docker run --rm --user "$(id -u):$(id -g)" \
  -v "$source_dir:/src:ro" \
  -v "$output_dir:/out:rw" \
  "$gitleaks_image" detect \
  --source=/src \
  --no-banner \
  --redact \
  --report-format sarif \
  --report-path=/out/gitleaks.sarif \
  --exit-code 1 || gitleaks_status=$?

# Scan every Terraform stage, including the manually bootstrapped state
# bucket. A finding in an optional stage is still reviewed before that stage
# is enabled in production.
docker run --rm --user "$(id -u):$(id -g)" \
  -v "$source_dir:/src:ro" \
  -v "$output_dir:/out:rw" \
  "$trivy_image" --quiet config \
  --misconfig-scanners terraform \
  --severity HIGH,CRITICAL \
  --format sarif \
  --output /out/trivy-config.sarif \
  --exit-code 1 \
  /src/stages || trivy_status=$?

if [[ "$gitleaks_status" -ne 0 || "$trivy_status" -ne 0 ]]; then
  echo "Security gate failed: gitleaks=$gitleaks_status trivy=$trivy_status" >&2
  exit 1
fi

echo "Security gate passed: no committed secrets and no HIGH/CRITICAL Terraform misconfigurations."
