# Workflow 3 Vault Agent API proxy. One instance per app:
# vault-proxy@payments, vault-proxy@analytics.
#
# REFERENCE COPY. Templates live on the host and are never transferred into the
# VM, so the authoritative content is the heredoc in scripts/81_app_proxies.sh.
# Keep the two in sync.
#
# ExecStart uses `vault agent` because 2.2.0+ent registers method "tpm"
# there, not under `vault proxy`.

[Unit]
Description=Vault agent API proxy for %i (TPM auto-auth)
After=network-online.target vault-dev.service swtpm-unix-bridge.service
Wants=vault-dev.service swtpm-unix-bridge.service

[Service]
Type=simple
ExecStart=/usr/local/bin/vault agent -config=/etc/vault-proxy/%i.hcl
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
