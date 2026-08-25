#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage:
  terraform-stage.sh validate <stage>
  terraform-stage.sh plan <stage> <tfvars> <backend> <plan> <manifest>
  terraform-stage.sh apply <stage> <backend> <plan> <manifest>
USAGE
  exit 2
}

[[ $# -ge 2 ]] || usage

mode="$1"
stage="$2"
repository_root="${BUILD_SOURCESDIRECTORY:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
stage_directory="$repository_root/stages/$stage"

[[ -d "$stage_directory" ]] || { echo "Unknown Terraform stage: $stage" >&2; exit 2; }

profile_override() {
  case "$stage" in
    01-organization|02-governance|03-production)
      printf '%s\n' '-var=management_profile='
      ;;
    05-gitlab-oidc)
      printf '%s\n' '-var=aws_profile='
      ;;
  esac
}

init_backend() {
  local backend_file="$1"

  terraform -chdir="$stage_directory" init \
    -input=false \
    -reconfigure \
    -lockfile=readonly \
    -backend-config="$backend_file"
}

case "$mode" in
  validate)
    terraform -chdir="$stage_directory" init \
      -backend=false \
      -input=false \
      -lockfile=readonly
    terraform -chdir="$stage_directory" validate -no-color
    ;;

  plan)
    [[ $# -eq 6 ]] || usage
    tfvars_file="$3"
    backend_file="$4"
    plan_file="$5"
    manifest_file="$6"

    [[ -f "$tfvars_file" ]] || { echo "Terraform variables file not found: $tfvars_file" >&2; exit 2; }
    [[ -f "$backend_file" ]] || { echo "Terraform backend file not found: $backend_file" >&2; exit 2; }

    init_backend "$backend_file"
    mkdir -p "$(dirname "$plan_file")"

    plan_args=(
      -input=false
      -no-color
      -detailed-exitcode
      -lock-timeout=5m
      -out="$plan_file"
      -var-file="$tfvars_file"
    )
    profile_arg="$(profile_override || true)"
    [[ -n "$profile_arg" ]] && plan_args+=("$profile_arg")

    set +e
    terraform -chdir="$stage_directory" plan "${plan_args[@]}"
    plan_status=$?
    set -e

    if [[ "$plan_status" -gt 2 ]]; then
      exit "$plan_status"
    fi

    cat > "$manifest_file" <<MANIFEST
source_version=${BUILD_SOURCEVERSION:?BUILD_SOURCEVERSION must be set by Azure Pipelines}
stage=$stage
terraform_version=$(terraform version -json | tr '\n' ' ')
MANIFEST
    ;;

  apply)
    [[ $# -eq 5 ]] || usage
    backend_file="$3"
    plan_file="$4"
    manifest_file="$5"

    [[ -f "$backend_file" ]] || { echo "Terraform backend file not found: $backend_file" >&2; exit 2; }
    [[ -f "$plan_file" ]] || { echo "Terraform plan artifact not found: $plan_file" >&2; exit 2; }
    [[ -f "$manifest_file" ]] || { echo "Terraform plan manifest not found: $manifest_file" >&2; exit 2; }
    grep -Fxq "source_version=${BUILD_SOURCEVERSION:?BUILD_SOURCEVERSION must be set by Azure Pipelines}" "$manifest_file" \
      || { echo "Terraform plan was not created from this pipeline commit." >&2; exit 2; }
    grep -Fxq "stage=$stage" "$manifest_file" \
      || { echo "Terraform plan stage does not match apply stage." >&2; exit 2; }

    init_backend "$backend_file"
    terraform -chdir="$stage_directory" apply -input=false "$plan_file"
    ;;

  *)
    usage
    ;;
esac
