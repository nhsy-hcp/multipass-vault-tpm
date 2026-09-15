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

log_step "Part 5.4: one-shot AppRole for enrolment"
# Enrolment is the one moment a device has no certificate yet, so it cannot use
# cert auth to get the credential that signs its first CSR. Something has to
# bootstrap it. Handing over the dev root token would mean the device holds
# unlimited privilege — delete every mount, mint any certificate, read every
# secret — purely to obtain a certificate it is already entitled to.
#
# 'device-enrol' is the smallest credential that can do the job and nothing
# else: one capability on one path. It cannot read secrets, cannot alter the
# cert auth trust anchor, and cannot issue against any other PKI role.
if mount_enabled auth "approle/"; then
  log_detected "the approle auth method already enabled" "skipping enable"
else
  log_info "Enabling the approle auth method"
  as_lab_user vault auth enable approle
fi

log_info "Writing the 'device-enrol' policy (sign CSRs only)"
# Deliberately a single stanza. 'update' on pki/sign/devices is what signing a
# CSR requires; anything beyond that would widen the blast radius of a leaked
# SecretID for no benefit to the demo.
as_lab_user vault policy write device-enrol - <<'EOF'
path "pki/sign/devices" {
  capabilities = ["update"]
}
EOF
log_ok "policy device-enrol written"

log_info "Creating the 'device-enrol' AppRole (single-use SecretID)"
# 'vault write' is an upsert, so re-running this resets the role to the
# intended shape rather than erroring — no guard needed.
#
# secret_id_num_uses=1 is the property on show: the credential is spent by the
# first login and is worthless to anyone who copies it afterwards. Every later
# authentication uses the TPM key and the certificate signed here, so this
# credential is needed exactly once in a device's lifetime.
#
# token_num_uses=3 rather than 1 is deliberate. Signing the CSR is a single
# request, but the enrolment script also looks the token up to narrate what it
# was granted; a use-limit tripping mid-demo is a worse failure than a slightly
# looser bound. The SecretID stays strictly single-use — that is the behaviour
# being demonstrated, and the token is short-lived regardless.
as_lab_user vault write auth/approle/role/device-enrol \
  token_policies=device-enrol \
  secret_id_num_uses=1 \
  secret_id_ttl=10m \
  token_ttl=5m \
  token_max_ttl=10m \
  token_num_uses=3

log_step "Verify: the device-enrol AppRole"
as_lab_user vault read auth/approle/role/device-enrol

# The table above is long and the limits that matter are scattered through it,
# so restate them as one line for the demo transcript.
enrol_role_json="$(as_lab_user vault read -format=json auth/approle/role/device-enrol)"
enrol_limits="$(printf '%s' "${enrol_role_json}" \
  | jq -r '.data | "\(.secret_id_num_uses) \(.secret_id_ttl) \(.token_ttl) \(.token_max_ttl) \(.token_num_uses)"')"
read -r sid_uses sid_ttl tok_ttl tok_max tok_uses <<<"${enrol_limits}"
log_detail "SecretID: ${sid_uses} use(s), TTL ${sid_ttl}s"
log_detail "Token:    TTL ${tok_ttl}s, max ${tok_max}s, ${tok_uses} uses"

# The RoleID is the stable half of an AppRole credential and is not a secret —
# it identifies the role, it does not authorise anything without a SecretID.
# It is the part you would bake into an image, so showing it is useful.
enrol_role_id="$(as_lab_user vault read -field=role_id auth/approle/role/device-enrol/role-id)"
log_detail "RoleID:   ${enrol_role_id}"
log_ok "AppRole device-enrol ready — SecretID is minted per enrolment, not here"

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
     approle_role: "auth/approle/role/device-enrol",
     enrol_policy: "device-enrol",
     configured_at: $configured_at
   }' | write_lab_file "${SENTINEL}"

log_ok "Parts 4-5 complete — state recorded in ${SENTINEL}"
log_info ''
log_info "Next: task enrol — create the device key inside the TPM and enrol it."
