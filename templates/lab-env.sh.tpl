# Lab environment for the Vault TPM cert-auth lab.
#
# REFERENCE COPY. Templates live on the host and are never transferred into the
# VM, so the authoritative content is the heredoc in scripts/00_provision.sh.
# Keep the two in sync.
#
# Rendered to ${LAB_DIR}/env.sh. Every lab shell sources this file, and
# as_lab_user() in scripts/lib/common.sh sources it too, so a `multipass shell`
# session and an automated step see exactly the same environment.

export LAB_DIR="${LAB_DIR}"

# TPM connection. The software TPM speaks TCP, so the TCTI names a port rather
# than /dev/tpmrm0 — on real hardware this is the only line that changes.
#
# Both are written with a :- default so a caller can point a single command at
# the attacker TPM (port ${ATTACKER_TPM_PORT}) without editing this file:
#   TPM2TOOLS_TCTI=swtpm:port=${ATTACKER_TPM_PORT} tpm2_getrandom 8 --hex
# That is how the Part 8.1 stolen-key demo simulates a different machine.
export TPM2TOOLS_TCTI="${TPM2TOOLS_TCTI:-swtpm:port=${TPM_PORT}}"
export TPM2OPENSSL_TCTI="${TPM2OPENSSL_TCTI:-swtpm:port=${TPM_PORT}}"

# Vault dev server with TLS. The dev certificate is issued for 127.0.0.1 only,
# which is why client and server both live inside the VM.
export VAULT_ADDR="https://127.0.0.1:8200"
export VAULT_CACERT="${LAB_TLS_DIR}/vault-ca.pem"
export VAULT_TOKEN="root"
