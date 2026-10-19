# Vault Agent with TPM auto-auth — the Part 9 demo's daemon.
#
# REFERENCE COPY. Templates live on the host and are never transferred into the
# VM, so the authoritative content is the heredoc in scripts/80_agent.sh.
# Keep the two in sync.
#
# Installed as /etc/systemd/system/vault-agent.service, and deliberately left
# DISABLED — unlike swtpm@.service and vault-dev.service, which are enabled.
# Vault dev mode is in-memory, so a reboot brings back a Vault with no tpm auth
# mount, no CA and no identity/tpm registry. An enabled agent would start ahead
# of 'task config && task enrol', fail to authenticate, and retry on a backoff
# indefinitely. The two units that hold state are enabled; this one consumes
# state that does not survive, so 80_agent.sh starts it by hand after checking
# that the orchestrator has admitted the TPM to the group.
#
# Environment=VAULT_TOKEN= is load-bearing. ${VM_DIR}/env.sh exports
# VAULT_TOKEN=root and the agent must not inherit it: the claim of Part 9 is
# that the daemon starts with no credential whatsoever.
#
# ConditionPathExists points at the TPM ID that 'task enrol' writes. The agent
# issues its own certificate but cannot register its own endorsement key, so it
# is useless until the orchestrator has run; the condition makes it refuse
# rather than fail if anything ever starts it too early.

[Unit]
Description=Vault Agent (TPM auto-auth) for the TPM auth lab
Documentation=https://developer.hashicorp.com/vault/docs/agent-and-proxy/agent
After=network-online.target vault-dev.service swtpm@device.service
Wants=network-online.target
ConditionPathExists=${TPM_DIR}/${DEVICE}/tpm_id

[Service]
Type=simple
User=${VM_USER}
Group=${VM_USER}
WorkingDirectory=${VM_DIR}/agent
Environment=VAULT_TOKEN=
ExecStart=/usr/bin/vault agent -config=${VM_DIR}/agent/agent.hcl
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
