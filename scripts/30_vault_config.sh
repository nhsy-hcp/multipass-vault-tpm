#!/bin/bash
# Parts 4-5: enable the tpm auth method with its internal CA, then the demo
# secret, the least-privilege policy, the device group and role, and the
# orchestrator credential that enrols devices.
# Runs as root inside the VM; every vault call is delegated to the lab user so
# the artefacts it leaves behind are usable from an interactive shell.
set -euo pipefail
STAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${STAGE_DIR}/common.sh"

DOMAIN="${1:-devices.lab.local}"

# The demo secret belongs to node01. The policy below covers every device path,
# so enrolling a second device needs no change here.
DEMO_DEVICE="node01"

SENTINEL="${LAB_STATE_DIR}/config.json"

# Vault Enterprise's tpm auth method. It carries its own CA: device certificates
# are issued by the mount itself at the end of an EK/AK attestation, so there is
# no PKI secrets engine and no CSR signing anywhere in this lab.
TPM_MOUNT="tpm"
TPM_GROUP="devices"
TPM_ROLE="devices"

# The provisioning orchestrator: the identity that registers a device's
# endorsement key and admits it to the group the role trusts. Scoped to exactly
# that, and created here because issuing it is part of the same
# trust-establishing job as everything else in Parts 4-5. See Part 5.5 below.
ORCH_POLICY="enrol-orchestrator"
ORCH_TOKEN_FILE="${LAB_STATE_DIR}/orchestrator.token"

# True when the named mount is already present at the given path ("tpm/").
mount_enabled() {
  local kind="$1" path="$2"
  as_lab_user vault "${kind}" list -format=json 2>/dev/null \
    | jq -e --arg p "${path}" 'has($p)' >/dev/null 2>&1
}

log_step "Parts 4-5: tpm auth method, demo secret, policy, device group and role"

require_cmd jq install || die "missing tooling — run 'task provision' first"
[[ -f "${LAB_DIR}/env.sh" ]] || die "no ${LAB_DIR}/env.sh — run 'task provision' first"

lab_mkdir "${LAB_STATE_DIR}"

# Vault dev mode is in-memory: a restart wipes every mount configured below.
# Waiting here makes this script safe to run immediately after 'task vault'.
wait_for "Vault to be unsealed" 60 as_lab_user vault status \
  || die "Vault is not responding — check 'task logs:vault'"

vault_ver="$(as_lab_user vault version)"
[[ "${vault_ver}" == *"+ent"* ]] \
  || die "the tpm auth method is Vault Enterprise only, and this is not an Enterprise build: ${vault_ver}"

# --- Part 4: the tpm auth method and its internal CA -------------------------
log_step "Part 4: enable the tpm auth method (its CA issues the device certificates)"

if mount_enabled auth "${TPM_MOUNT}/"; then
  log_detected "the tpm auth method already enabled at auth/${TPM_MOUNT}" "skipping enable"
else
  log_info "Enabling the tpm auth method at auth/${TPM_MOUNT}"
  as_lab_user vault auth enable -path="${TPM_MOUNT}" tpm
fi

# The mount keeps an active CA and a pre-generated next CA and rotates between
# them on its own. Nothing here is exported or trusted by hand: a certificate
# is valid because this mount issued it, and only this mount can. Device
# certificates default to 24h — re-running 'task enrol' refreshes them.
log_info "Configuring the internal CA (device certificates live 24h)"
as_lab_user vault write "auth/${TPM_MOUNT}/config" default_cert_ttl=24h

log_step "Verify: auth/${TPM_MOUNT}/config"
as_lab_user vault read "auth/${TPM_MOUNT}/config"

# --- Part 5: secret, policy, group, role, orchestrator ------------------------
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

log_step "Part 5.3: the '${TPM_GROUP}' TPM group"
# A role can trust individual TPM IDs or a group of them. The group is the
# indirection that keeps enrolment least-privilege: admitting a device means
# adding its TPM ID to this group, which the orchestrator may do, rather than
# editing the auth role, which it may not — a role write could also change
# token_policies, and that is an escalation path, not an enrolment.
if as_lab_user vault read -format=json "identity/tpmgroup/name/${TPM_GROUP}" >/dev/null 2>&1; then
  log_detected "an existing TPM group '${TPM_GROUP}'" "keeping its members"
else
  log_info "Creating TPM group '${TPM_GROUP}' (empty until 'task enrol' adds a device)"
  as_lab_user vault write "identity/tpmgroup" name="${TPM_GROUP}" metadata="domain=${DOMAIN}" >/dev/null
fi
group_id="$(as_lab_user vault read -field=id "identity/tpmgroup/name/${TPM_GROUP}")"
[[ -n "${group_id}" ]] || die "could not read the id of TPM group '${TPM_GROUP}'"
log_ok "group ${TPM_GROUP} = ${group_id}"

log_step "Part 5.4: the '${TPM_ROLE}' role (15m token, 1h max)"
# The trust anchor is the group, not any individual TPM: a device enrolled
# later is trusted the moment its TPM ID joins the group. 'vault write' is an
# upsert, so re-running resets the role to the intended shape.
as_lab_user vault write "auth/${TPM_MOUNT}/role/${TPM_ROLE}" \
  tpmgroup_ids="${group_id}" \
  display_name=tpm-devices \
  token_policies=device-read \
  token_ttl=15m \
  token_max_ttl=1h

log_step "Verify: the tpm auth role"
as_lab_user vault read "auth/${TPM_MOUNT}/role/${TPM_ROLE}"

log_step "Part 5.5: the orchestrator credential that enrols devices"
# The device side of enrolment needs no Vault credential at all: the
# attestation endpoints are unauthenticated, because possession of an
# endorsement key that Vault already knows IS the credential. What remains
# privileged is telling Vault which endorsement keys to know — registering an
# EK and admitting it to the group. Doing that with the dev root token would
# leave the operator side holding unlimited privilege in the very step whose
# point is least privilege.
#
# So the provisioning system gets an identity of its own: three paths, and
# nothing else. It cannot alter the auth role, read a secret, touch another
# group, or mint tokens. The device-side attestation is what 'task enrol'
# demonstrates; this is the other half.
log_info "Writing the '${ORCH_POLICY}' policy (register EKs, admit them to '${TPM_GROUP}')"
as_lab_user vault policy write "${ORCH_POLICY}" - <<EOF
# Register a device's endorsement key. Vault derives the TPM ID from it.
path "identity/tpm" {
  capabilities = ["update"]
}

# Read a registration back by name, to confirm it and recover the TPM ID.
path "identity/tpm/name/*" {
  capabilities = ["read"]
}

# Admit a registered TPM to the group the '${TPM_ROLE}' role trusts. This is
# the only group the orchestrator can touch, and it cannot touch the role.
path "identity/tpmgroup/name/${TPM_GROUP}" {
  capabilities = ["read", "update"]
}
EOF
log_ok "policy ${ORCH_POLICY} written"

# Vault dev mode is in-memory, so in practice Vault has already forgotten any
# earlier token by the time this re-runs. Against a live Vault it would not
# have: a re-run would leave the previous orchestrator token valid for the rest
# of its TTL and referenced by nothing. Revoke first, so re-running 'task
# config' narrows standing privilege rather than accumulating it.
if [[ -s "${ORCH_TOKEN_FILE}" ]]; then
  if as_lab_user_allow_fail vault token revoke "$(cat "${ORCH_TOKEN_FILE}")" >/dev/null 2>&1; then
    log_detected "a previous orchestrator token" "revoked before minting its replacement"
  else
    log_detected "a stale orchestrator token" "already expired, or gone with the last Vault restart"
  fi
fi

log_info "Minting the orchestrator token (24h, policy ${ORCH_POLICY})"
# -ttl, not -period: a periodic token renews for ever, which is the right shape
# for a long-running agent and the wrong one for a demonstration of bounded
# privilege. 24h outlives any demo session, and a Vault restart kills it sooner.
#
# -no-default-policy so the transcript shows exactly the three paths above.
orch_json="$(as_lab_user vault token create \
  -policy="${ORCH_POLICY}" \
  -no-default-policy \
  -ttl=24h \
  -display-name="${ORCH_POLICY}" \
  -format=json)"
orch_token="$(printf '%s' "${orch_json}" | jq -r '.auth.client_token // empty')"
[[ -n "${orch_token}" ]] || die "vault token create returned no client_token for ${ORCH_POLICY}"

# 0600, not 0644: every other lab artefact is a public key, a certificate or a
# key handle only this TPM can use. This one is a bearer credential.
printf '%s' "${orch_token}" | write_lab_file "${ORCH_TOKEN_FILE}" 0600
log_ok "orchestrator token at ${ORCH_TOKEN_FILE} (owner ${LAB_USER}, mode 0600)"
log_detail "Policies: $(printf '%s' "${orch_json}" | jq -r '.auth.policies | join(", ")')"
log_detail "TTL:      $(printf '%s' "${orch_json}" | jq -r '.auth.lease_duration')s"
log_detail "It can register an EK and admit it to '${TPM_GROUP}'. It cannot change the"
log_detail "'${TPM_ROLE}' role, read a secret, or mint a token."

# --- sentinel ---------------------------------------------------------------
# Later scripts gate on this file: it records that Parts 4-5 completed against a
# particular domain, mount and group, and survives nothing that Vault itself
# forgets.
jq -n \
  --arg domain "${DOMAIN}" \
  --arg device "${DEMO_DEVICE}" \
  --arg mount "${TPM_MOUNT}" \
  --arg group "${TPM_GROUP}" \
  --arg group_id "${group_id}" \
  --arg role "${TPM_ROLE}" \
  --arg orch_policy "${ORCH_POLICY}" \
  --arg orch_token_file "${ORCH_TOKEN_FILE}" \
  --arg configured_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{
     status: "complete",
     domain: $domain,
     demo_device: $device,
     tpm_auth_mount: ("auth/" + $mount),
     tpm_group: $group,
     tpm_group_id: $group_id,
     tpm_role: ("auth/" + $mount + "/role/" + $role),
     orchestrator_policy: $orch_policy,
     orchestrator_token_file: $orch_token_file,
     configured_at: $configured_at
   }' | write_lab_file "${SENTINEL}"

log_ok "Parts 4-5 complete — state recorded in ${SENTINEL}"
log_info ''
log_info "Next: task enrol — register the device's endorsement key and attest it."
