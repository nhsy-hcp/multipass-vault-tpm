# Lab environment for the Vault TPM auth lab.
#
# REFERENCE COPY. Templates live on the host and are never transferred into the
# VM, so the authoritative content is the heredoc in scripts/00_provision.sh.
# Keep the two in sync.
#
# Rendered to ${LAB_DIR}/env.sh. Every lab shell sources this file, and
# as_lab_user() in scripts/lib/common.sh sources it too, so a `multipass shell`
# session and an automated step see exactly the same environment.

export LAB_DIR="${LAB_DIR}"
export LAB_TPM_DIR="${LAB_TPM_DIR}"

# TPM connection. Each software TPM serves a unix socket, and tpm2-tools and
# the Vault CLI reach the same TPM through the same path. On real hardware this
# becomes /dev/tpmrm0 (TCTI "device:/dev/tpmrm0") and nothing else changes.
#
# Written with :- defaults so a caller can point one command at the attacker
# TPM without editing this file — that is how the Part 8 demos simulate a
# different machine:
#   vault tpm ek -tpm-device-path=${ATTACKER_TPM_DEVICE_PATH}
#   TPM2TOOLS_TCTI=swtpm:path=${ATTACKER_TPM_DEVICE_PATH} tpm2_getrandom 8 --hex
export TPM_DEVICE_PATH="${TPM_DEVICE_PATH:-${TPM_SOCK}}"
export TPM2TOOLS_TCTI="${TPM2TOOLS_TCTI:-swtpm:path=${TPM_SOCK}}"
export ATTACKER_TPM_DEVICE_PATH="${ATTACKER_TPM_SOCK}"

# Vault dev server with TLS. The dev certificate is issued for 127.0.0.1 only,
# which is why client and server both live inside the VM.
export VAULT_ADDR="https://127.0.0.1:8200"
export VAULT_CACERT="${LAB_TLS_DIR}/vault-ca.pem"
export VAULT_TOKEN="root"
