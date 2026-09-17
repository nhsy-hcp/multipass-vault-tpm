#!/bin/bash
# Reset the lab inside the VM without destroying the VM itself.
#
# Three teardown granularities exist:
#   task reset  — this script: wipe lab state, keep the VM and its packages
#   task stop   — stop the VM, keep everything on disk
#   task clean  — delete and purge the VM entirely
#
# Reset is the one to reach for between demo rehearsals: it is fast because the
# package install and the Vault binary from Part 1 are preserved.
set -euo pipefail
STAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${STAGE_DIR}/common.sh"

log_step "Resetting lab state"

log_info "Stopping lab services..."
systemctl stop vault-dev swtpm@device swtpm@attacker 2>/dev/null || true
log_ok "services stopped"

# Vault dev mode is in-memory, so stopping the unit has already discarded every
# mount, policy, TPM registration and token. Only on-disk artefacts need
# clearing. The licence stays: it belongs to the binary, not the lab state.
log_info "Removing certificates, key handles and lab state..."
rm -rf \
  "${LAB_TPM_DIR:?}" \
  "${LAB_STATE_DIR:?}" \
  "${LAB_TLS_DIR:?}" \
  "${LAB_DIR:?}/logs"
log_ok "lab artefacts removed"

# New storage seeds, new endorsement keys: every registration Vault held for
# the old TPMs would be stale anyway, and every blob is now unrecoverable.
log_info "Clearing both software TPMs (new storage seeds, new EKs)..."
rm -rf "${TPM_STATE_ROOT}/device" "${TPM_STATE_ROOT}/attacker"
install -d -o "${LAB_USER}" -g "${LAB_USER}" -m 0700 \
  "${TPM_STATE_ROOT}/device" "${TPM_STATE_ROOT}/attacker"
log_ok "TPM state cleared"

lab_mkdir "${LAB_DIR}" "${LAB_STATE_DIR}" "${LAB_TLS_DIR}" "${LAB_TPM_DIR}" "${LAB_DIR}/logs"

log_info ""
log_ok "Lab reset. Packages, the Vault binary and the VM are untouched."
log_info "Rebuild with: task tpm && task vault && task config && task enrol"
log_detail "(or simply: task all)"
