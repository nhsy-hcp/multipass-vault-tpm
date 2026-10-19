#!/bin/bash
# Host dependency check. Runs on macOS, never inside the VM.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# Host scratch lives in the project, per the project convention. Create it here
# so anything running later can rely on it existing.
export SCRATCH_DIR="${PROJECT_ROOT}/.tmp"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

log_step "Host dependencies"

missing=0
required=(multipass task jq git)
optional=(shellcheck gitleaks pre-commit dot rsvg-convert)

for c in "${required[@]}"; do
  if command -v "$c" >/dev/null 2>&1; then
    log_ok "$c"
  else
    log_error "$c is required but not installed"
    missing=1
  fi
done

for c in "${optional[@]}"; do
  if command -v "$c" >/dev/null 2>&1; then
    log_ok "$c"
  else
    case "$c" in
      dot)  log_warn "graphviz not installed — 'task docs:diagram' will fail. Install: brew install graphviz" ;;
      rsvg-convert) log_warn "librsvg not installed — 'task docs:diagram' will fail. Install: brew install librsvg" ;;
      *)    log_warn "$c not installed — 'task lint' will fail. Install: brew install $c" ;;
    esac
  fi
done

if (( missing )); then
  die "install the missing required tools and re-run 'task deps'"
fi

log_step "Multipass"
multipass version | sed 's/^/  /'

# Vault Enterprise itself is installed from apt inside the VM; only the
# licence text comes from the host, as VAULT_LICENSE in .env. Never printed.
# Report rather than fail: `task provision` is the hard gate.
log_step "Vault Enterprise licence"
if [[ -n "${VAULT_LICENSE:-}" ]]; then
  log_ok "VAULT_LICENSE set (${#VAULT_LICENSE} characters)"
else
  log_warn "VAULT_LICENSE is empty — paste your licence text into .env before 'task provision'"
fi

log_info ''
log_detail "Apple Silicon hosts create arm64 guests, Intel hosts amd64; the HashiCorp and"
log_detail "Ubuntu repositories publish both, so no changes are needed."

log_ok "host is ready — next: task all"
