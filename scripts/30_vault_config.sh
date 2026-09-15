#!/bin/bash
# Parts 4-5: build the device CA, then the secret, policy and cert auth role.
# Runs as root inside the VM; every vault/openssl call is delegated to the lab
# user so the artefacts it leaves behind are usable from an interactive shell.
set -euo pipefail
STAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${STAGE_DIR}/common.sh"

DOMAIN="${1:-devices.lab.local}"

# The demo secret belongs to node01. The policy below covers every device path,
# so enrolling a second device needs no change here.
DEMO_DEVICE="node01"

CA_PEM="${LAB_PKI_DIR}/lab_device_ca.pem"
SENTINEL="${LAB_STATE_DIR}/config.json"

# Vault CLI output is captured as root, so ownership has to be applied on the
# way to disk rather than relying on the creating process.
write_lab_file() {
  local dest="$1" tmp
  tmp="$(mktemp)"
  cat > "${tmp}"
  install -o "${LAB_USER}" -g "${LAB_USER}" -m 0644 "${tmp}" "${dest}"
  rm -f "${tmp}"
}

# True when the named mount is already present at the given path ("pki/").
mount_enabled() {
  local kind="$1" path="$2"
  as_lab_user vault "${kind}" list -format=json 2>/dev/null \
    | jq -e --arg p "${path}" 'has($p)' >/dev/null 2>&1
}

log_step "Parts 4-5: device CA, demo secret, policy and cert auth"

require_cmd jq install || die "missing tooling — run 'task provision' first"
[[ -f "${LAB_DIR}/env.sh" ]] || die "no ${LAB_DIR}/env.sh — run 'task provision' first"

lab_mkdir "${LAB_PKI_DIR}" "${LAB_STATE_DIR}"

# Vault dev mode is in-memory: a restart wipes every mount configured below.
# Waiting here makes this script safe to run immediately after 'task vault'.
wait_for "Vault to be unsealed" 60 as_lab_user vault status \
  || die "Vault is not responding — check 'task logs:vault'"

vault_addr="$(as_lab_user printenv VAULT_ADDR)"
[[ -n "${vault_addr}" ]] || die "VAULT_ADDR is not exported by ${LAB_DIR}/env.sh"

# --- Part 4: the device CA --------------------------------------------------
log_step "Part 4: device CA on the pki secrets engine"

if mount_enabled secrets "pki/"; then
  log_detected "the pki secrets engine already mounted" "skipping enable"
else
  log_info "Enabling the pki secrets engine"
  as_lab_user vault secrets enable pki
fi

# Tuning is an upsert, so it is always safe to re-apply.
log_info "Tuning pki max lease TTL to 87600h (10 years)"
as_lab_user vault secrets tune -max-lease-ttl=87600h pki

# Generating a root twice either errors or silently leaves a second root on the
# mount, so generation is gated on whether the mount already has one.
if as_lab_user vault read pki/cert/ca >/dev/null 2>&1; then
  log_detected "an existing root CA on the pki mount" "skipping generation"
  if [[ ! -s "${CA_PEM}" ]]; then
    # State can drift: the mount survives while the PEM is lost (e.g. after a
    # 'task reset' that clears the lab dir). Re-fetch rather than regenerate.
    log_info "Re-fetching the CA certificate to ${CA_PEM}"
    as_lab_user vault read -field=certificate pki/cert/ca | write_lab_file "${CA_PEM}"
  fi
else
  log_info "Generating root CA 'Lab Device Root CA' (ttl 87600h)"
  as_lab_user vault write -field=certificate pki/root/generate/internal \
    common_name="Lab Device Root CA" ttl=87600h | write_lab_file "${CA_PEM}"
fi
[[ -s "${CA_PEM}" ]] || die "device CA PEM is missing or empty: ${CA_PEM}"
log_ok "device CA at ${CA_PEM}"

log_info "Publishing issuing and CRL URLs"
as_lab_user vault write pki/config/urls \
  issuing_certificates="${vault_addr}/v1/pki/ca" \
  crl_distribution_points="${vault_addr}/v1/pki/crl"

log_info "Writing the 'devices' role for ${DOMAIN} (client certs only)"
as_lab_user vault write pki/roles/devices \
  allowed_domains="${DOMAIN}" \
  allow_subdomains=true \
  key_type=any \
  client_flag=true \
  server_flag=false \
  max_ttl=720h

log_step "Verify: the device CA certificate"
as_lab_user openssl x509 -in "${CA_PEM}" -noout -subject -dates

ca_serial="$(as_lab_user openssl x509 -in "${CA_PEM}" -noout -serial)"
ca_serial="${ca_serial#serial=}"
log_detail "CA serial: ${ca_serial}"

# --- Part 5: secret, policy, cert auth --------------------------------------
log_step "Part 5.1: the secret the device should be able to read"
as_lab_user vault kv put "secret/devices/${DEMO_DEVICE}" \
  message="hello from vault, attested by TPM key"

log_step "Part 5.2: least-privilege policy 'device-read'"
# Read-only on the KV v2 data path. Part 7.3 proves the write is denied.
as_lab_user vault policy write device-read - <<'EOF'
path "secret/data/devices/*" {
  capabilities = ["read"]
}
EOF
log_ok "policy device-read written"

log_step "Part 5.3: enable and configure cert auth"
if mount_enabled auth "cert/"; then
  log_detected "the cert auth method already enabled" "skipping enable"
else
  log_info "Enabling the cert auth method"
  as_lab_user vault auth enable cert
fi

# The trust anchor is the CA, not any individual device certificate: a device
# enrolled later is trusted the moment Vault's PKI signs its CSR.
log_info "Trusting the device CA for *.${DOMAIN} (15m token, 1h max)"
as_lab_user vault write auth/cert/certs/tpm-devices \
  display_name=tpm-devices \
  certificate=@"${CA_PEM}" \
  allowed_common_names="*.${DOMAIN}" \
  token_policies=device-read \
  token_ttl=15m \
  token_max_ttl=1h

log_step "Verify: the cert auth role"
as_lab_user vault read auth/cert/certs/tpm-devices

# --- sentinel ---------------------------------------------------------------
# Later scripts gate on this file: it records that Parts 4-5 completed against a
# particular domain and CA, and survives nothing that Vault itself forgets.
jq -n \
  --arg domain "${DOMAIN}" \
  --arg ca_serial "${ca_serial}" \
  --arg ca_pem "${CA_PEM}" \
  --arg device "${DEMO_DEVICE}" \
  --arg configured_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{
     status: "complete",
     domain: $domain,
     ca_serial: $ca_serial,
     ca_pem: $ca_pem,
     demo_device: $device,
     pki_role: "pki/roles/devices",
     cert_auth_role: "auth/cert/certs/tpm-devices",
     configured_at: $configured_at
   }' | write_lab_file "${SENTINEL}"

log_ok "Parts 4-5 complete — state recorded in ${SENTINEL}"
log_info ''
log_info "Next: task enrol — create the device key inside the TPM and enrol it."
