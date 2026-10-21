#!/usr/bin/env bash
# Local checks only: never runs a real Terraform plan or apply.
set -Eeuo pipefail

trap 'check_exit=$?; printf "Error: Terraform check failed at line %s (exit %s).\n" "$LINENO" "$check_exit" >&2; exit "$check_exit"' ERR

if [[ $# -ne 0 ]]; then
  echo "Usage: $0" >&2
  exit 2
fi

if ! command -v terraform >/dev/null 2>&1; then
  echo "Error: terraform must be installed and available on PATH." >&2
  exit 127
fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
terraform_dir="$(cd -- "$script_dir/../terraform" && pwd)"
export TF_IN_AUTOMATION=1

printf '\nChecking Terraform formatting...\n'
terraform fmt -check -recursive "$terraform_dir"

check_configuration() {
  local configuration_dir="$1"
  printf '\nChecking %s\n' "$configuration_dir"
  # Skip remote backend initialization; keep the reviewed provider selections.
  terraform -chdir="$configuration_dir" init -backend=false -input=false -lockfile=readonly
  terraform -chdir="$configuration_dir" validate
  # Every current test suite declares a mocked AWS provider.
  terraform -chdir="$configuration_dir" test
}

check_configuration "$terraform_dir/environments/dev"

# Run module-local tests too: root tests do not automatically run child suites.
for module_dir in "$terraform_dir"/modules/*; do
  [[ -d "$module_dir" ]] || continue
  check_configuration "$module_dir"
done

printf '\nAll Terraform formatting, initialization, validation, and mocked tests passed.\n'
