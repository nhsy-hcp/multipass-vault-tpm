#!/bin/bash
# Part 9 addendum: does the agent survive its token's maximum TTL?
set -euo pipefail
STAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${STAGE_DIR}/common.sh"

# -----------------------------------------------------------------------------
# Not part of the narrated demo. Part 9 shows the agent attesting and logging
# in; this shows what happens afterwards, when the token it holds can no longer
# be renewed.
#
# The role gives out 15m tokens with a 1h maximum and no period, so roughly
# every twenty minutes the agent's lifetime watcher gives up renewing and the
# auth handler logs in again. That re-authentication is an mTLS login with the
# certificate the agent already holds — no fresh attestation, so Vault's per-EK
# rate limit never enters it. It is also where a slot leak would show: if each
# login leaked one of swtpm's three transient slots, the third login in the
# life of one agent process could not load its key, and the agent would report
# nothing while the template server collected 403s. Vault 2.2.0 frees the slot
# after every login; this script is the regression test for that, so it also
# reports the free slots before and after.
#
# Waiting an hour to see that is no way to test it, so this script lowers the
# role's TTLs to 1m/3m for the duration, runs the agent through several cycles
# in minutes, and puts the TTLs back from an EXIT trap armed before the write —
# the same discipline as the Part 8 demos, which undo their own Vault state.
#
# Like those demos it reports rather than asserts, and exits 0 either way.
# -----------------------------------------------------------------------------

DEVICE="${1:-node01}"
# Minutes as the second argument, because multipass exec does not carry the
# host's environment into the guest: task agent:soak SOAK_MINUTES=10
SOAK_MINUTES="${2:-6}"
SOAK_TOKEN_TTL="${SOAK_TOKEN_TTL:-1m}"
SOAK_TOKEN_MAX_TTL="${SOAK_TOKEN_MAX_TTL:-3m}"

# Three successful authentications is the point: the first login, the
# re-authentication after it, and the one after that — the login a leaked slot
# per login would make impossible.
SOAK_TARGET_AUTHS="${SOAK_TARGET_AUTHS:-3}"

TPM_MOUNT="tpm"
TPM_ROLE="devices"
ROLE_PATH="auth/${TPM_MOUNT}/role/${TPM_ROLE}"

DEVICE_DIR="${TPM_DIR}/${DEVICE}"
AGENT_DIR="${VM_DIR}/agent"
AGENT_HCL="${AGENT_DIR}/agent.hcl"
SINK="${AGENT_DIR}/token"
TPL_OUT="${AGENT_DIR}/message.txt"

log_step "Agent soak: re-authentication across the token's maximum TTL (${DEVICE})"

require_cmd jq systemctl || die "missing prerequisites"
[[ -f "${VM_DIR}/env.sh" ]] || die "no ${VM_DIR}/env.sh — run 'task provision' first"
[[ -S "${TPM_SOCK}" ]] || die "no device TPM at ${TPM_SOCK} — run 'task tpm' first"
[[ -s "${DEVICE_DIR}/tpm_id" ]] || die "no TPM ID for ${DEVICE} — run 'task enrol' first"
[[ -s "${AGENT_HCL}" ]] || die "no agent configuration — run 'task demo:agent' first"
systemctl cat vault-agent >/dev/null 2>&1 \
  || die "no vault-agent unit — run 'task demo:agent' first"
wait_for "Vault to be unsealed" 60 as_lab_user vault status \
  || die "Vault is not answering — inspect with: journalctl -u vault-dev --no-pager -n 50"

# --- what the role says now --------------------------------------------------
log_step "1. The role as the operator left it"

role_json="$(as_lab_user vault read -format=json "${ROLE_PATH}" 2>/dev/null)" \
  || die "cannot read ${ROLE_PATH} — has dev-mode Vault restarted? Run 'task config && task enrol'"

# Read every field back and write them all again. Vault 2.2.0 keeps the fields
# a partial write leaves out, but losing tpmgroup_ids would take the role's
# trust in the group with it, so the restore does not depend on that.
orig_ttl="$(jq -r '.data.token_ttl' <<<"${role_json}")"
orig_max_ttl="$(jq -r '.data.token_max_ttl' <<<"${role_json}")"
groups="$(jq -r '(.data.tpmgroup_ids // []) | join(",")' <<<"${role_json}")"
policies="$(jq -r '(.data.token_policies // []) | join(",")' <<<"${role_json}")"
display_name="$(jq -r '.data.display_name // ""' <<<"${role_json}")"

[[ -n "${groups}" ]] \
  || die "${ROLE_PATH} has no tpmgroup_ids — refusing to rewrite it blind"

log_detail "  token_ttl=${orig_ttl}s token_max_ttl=${orig_max_ttl}s"
log_detail "  tpmgroup_ids=${groups} token_policies=${policies}"

write_role() {
  local ttl="$1" max_ttl="$2"
  vault_run vault write "${ROLE_PATH}" \
    tpmgroup_ids="${groups}" \
    display_name="${display_name}" \
    token_policies="${policies}" \
    token_ttl="${ttl}" \
    token_max_ttl="${max_ttl}"
}

# --- armed before the first write --------------------------------------------
# An aborted run must not leave the lab handing out 1m tokens.
restored=0
cleanup() {
  (( restored == 1 )) && return 0
  restored=1
  log_info ""
  log_info "Restoring ${ROLE_PATH} and stopping the agent..."
  systemctl stop vault-agent >/dev/null 2>&1 || true
  rm -f "${SINK}" "${TPL_OUT}"
  write_role "${orig_ttl}s" "${orig_max_ttl}s" >/dev/null 2>&1 || true
  flush_tpm_contexts "${TPM_SOCK}"
}
trap cleanup EXIT
# EXIT alone is enough for the Part 8 demos, which finish in seconds. This one
# runs for minutes and an operator will interrupt it: bash does not run an EXIT
# trap when an untrapped signal kills the shell, and the lab would be left
# handing out 1m tokens. cleanup guards against running twice.
trap 'cleanup; exit 130' INT TERM

log_step "2. Shortening the role's TTLs for the run"
log_detail "  ${SOAK_TOKEN_TTL} tokens with a ${SOAK_TOKEN_MAX_TTL} maximum, so the agent reaches the"
log_detail "  re-authentication in minutes rather than the hour the lab normally takes."
write_role "${SOAK_TOKEN_TTL}" "${SOAK_TOKEN_MAX_TTL}"

# --- run it ------------------------------------------------------------------
log_step "3. Running the agent"

systemctl stop vault-agent >/dev/null 2>&1 || true
flush_tpm_contexts "${TPM_SOCK}"

slots_before="$(free_transient_slots "${TPM_SOCK}")"

since="$(date '+%Y-%m-%d %H:%M:%S')"
show_cmd systemctl start vault-agent
systemctl start vault-agent

if ! wait_for_unit vault-agent 30; then
  log_detail "$(journalctl -u vault-agent --no-pager -n 20 | sed 's/^/    /')"
  die "vault-agent did not stay active — inspect with: journalctl -u vault-agent --no-pager -n 50"
fi

deadline=$(( $(date +%s) + SOAK_MINUTES * 60 ))
auths=0
reauths=0
renewals=0

log_info ""
log_info "Watching for ${SOAK_MINUTES} minutes, or until ${SOAK_TARGET_AUTHS} authentications..."

agent_log() { journalctl -u vault-agent --no-pager --since "${since}" 2>/dev/null; }

while (( $(date +%s) < deadline )); do
  log="$(agent_log)"
  auths="$(grep -c 'authentication successful' <<<"${log}" || true)"
  reauths="$(grep -c 'done channel triggered, re-authenticating' <<<"${log}" || true)"
  renewals="$(grep -c 'renewed auth token' <<<"${log}" || true)"
  (( auths >= SOAK_TARGET_AUTHS )) && break
  sleep 10
done

# --- what happened -----------------------------------------------------------
log_step "4. What the agent did"

slots_after="$(free_transient_slots "${TPM_SOCK}")"

log_detail "$(agent_log \
  | grep -E 'auth\.handler|tpmattest|token written|rendered' \
  | sed -E 's/^.*(agent[.:])/\1/; s/^/    /' | tail -16)"

log_info ""
report_expect "at least ${SOAK_TARGET_AUTHS} successful authentications" \
              "${auths}"
report_expect "at least one 'done channel triggered, re-authenticating'" \
              "${reauths}"
report_expect "renewals between them" "${renewals}"

if (( auths >= SOAK_TARGET_AUTHS && reauths >= 1 )); then
  log_ok "the agent re-authenticated past token_max_ttl and kept its identity"
elif (( reauths >= 1 && auths < SOAK_TARGET_AUTHS )); then
  log_warn "re-authentication started but did not complete — the wedge this test exists for"
  log_detail "  Check the free slots below and 'journalctl -u swtpm@device': a silent"
  log_detail "  retry loop shows up there as several disconnects a second."
else
  log_warn "the token never reached its maximum TTL in ${SOAK_MINUTES}m — raise SOAK_MINUTES"
fi

log_info ""
report_expect "transient slots still free at the end (0x3 is all of them)" \
              "before ${slots_before}, after ${slots_after}"

# The sink is the unattended half: a token that kept being replaced.
if [[ -s "${SINK}" ]]; then
  agent_token="$(cat "${SINK}")"
  show_cmd env 'VAULT_TOKEN=<agent-sink>' vault token lookup -format=json
  lookup="$(as_lab_user_allow_fail env "VAULT_TOKEN=${agent_token}" \
    vault token lookup -format=json 2>&1)" || true
  if jq -e . >/dev/null 2>&1 <<<"${lookup}"; then
    report_expect "a live token in the sink, tpm_id ${DEVICE}'s" \
                  "ttl $(jq -r '.data.ttl' <<<"${lookup}")s, tpm_id $(jq -r '.data.meta.tpm_id // "(none)"' <<<"${lookup}")"
  else
    report_expect "a live token in the sink" "lookup failed: ${lookup}"
  fi
else
  report_expect "a token in ${SINK}" "the sink is empty"
fi

log_info ""
log_info "The TTLs go back to ${orig_ttl}s/${orig_max_ttl}s on the way out."
