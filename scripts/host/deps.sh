#!/bin/bash
# Host dependency check. Runs on macOS, never inside the VM.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# Host scratch lives in the project, per the project convention. Create it here
# so anything running later can rely on it existing.
export LAB_TMP="${PROJECT_ROOT}/.tmp"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

log_step "Host dependencies"

missing=0
required=(multipass task jq git)
optional=(shellcheck gitleaks pre-commit dot)

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
      *)    log_warn "$c not installed — 'task lint' will fail. Install: brew install $c" ;;
    esac
  fi
done

if (( missing )); then
  die "install the missing required tools and re-run 'task deps'"
fi

log_step "Multipass"
multipass version | sed 's/^/  /'

# Vault Enterprise is a private beta binary copied by hand into .bin/, never an
# apt package. Report rather than fail: `task provision` is the hard gate.
log_step "Vault Enterprise binary"
VAULT_BIN="${1:-.bin/vault_2.2.0-beta1+ent_linux_arm64}"
VAULT_LICENSE="${2:-.bin/vault.hclic}"
if [[ -f "${PROJECT_ROOT}/${VAULT_BIN}" ]]; then
  log_ok "${VAULT_BIN}"
else
  log_warn "${VAULT_BIN} not found — copy the private beta binary into .bin/ before 'task provision'"
fi
if [[ -f "${PROJECT_ROOT}/${VAULT_LICENSE}" ]]; then
  log_ok "${VAULT_LICENSE}"
else
  log_warn "${VAULT_LICENSE} not found — Vault Enterprise will not start without a licence"
fi

log_info ''
log_detail "Apple Silicon hosts create arm64 guests; the Vault binary is linux/arm64 and"
log_detail "the Ubuntu TPM packages publish arm64 builds, so no changes are needed."

log_ok "host is ready — next: task all"
