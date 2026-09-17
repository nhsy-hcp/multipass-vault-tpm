# Vault dev server with TLS, run as a supervised unit rather than a nohup job.
#
# REFERENCE COPY. Templates live on the host and are never transferred into the
# VM, so the authoritative content is the heredoc in scripts/20_vault_unit.sh.
# Keep the two in sync.
#
# Installed as /etc/systemd/system/vault-dev.service. The binary is the Vault
# Enterprise private beta installed by 00_provision.sh at /usr/local/bin/vault,
# and the Enterprise licence is passed via VAULT_LICENSE_PATH.
#
# -dev-listen-address is omitted on purpose. It defaults to 127.0.0.1:8200, and
# the dev TLS certificate is issued for 127.0.0.1 only — binding anywhere else
# would break the client's certificate verification.

[Unit]
Description=Vault dev server (TLS) for the TPM cert-auth lab
Documentation=https://developer.hashicorp.com/vault/docs/commands/server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${LAB_USER}
Group=${LAB_USER}
WorkingDirectory=${LAB_DIR}
Environment=VAULT_LICENSE_PATH=${LAB_DIR}/vault.hclic
ExecStart=/usr/local/bin/vault server -dev -dev-tls -dev-root-token-id=root -dev-tls-cert-dir=${LAB_TLS_DIR}
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
