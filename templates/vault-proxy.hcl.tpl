# Workflow 3 per-application Vault Agent proxy. ${APP} is payments or analytics.
#
# REFERENCE COPY. Templates live on the host and are never transferred into the
# VM, so the authoritative content is the heredoc in scripts/81_app_proxies.sh.
# Keep the two in sync.
#
# Vault 2.2.0+ent puts TPM auto-auth on `vault agent`, not `vault proxy`
# (`unknown auto-auth method type tpm` from the proxy subcommand). The agent
# still exposes the unix listener and forces its auto-auth token.

vault {
  address = "https://127.0.0.1:8200"
  ca_cert = "${LAB_TLS_DIR}/vault-ca.pem"
}

tpm_cert "host_identity" {
  mount_path = "auth/tpm"
  role_name  = "${APP}-app"

  tpm {
    device_path = "${SWTPM_UNIX_SOCK}"
  }

  renew {
    percent_renew_before_expiry = 20
    min_backoff                 = "5s"
    max_backoff                 = "5m"
  }

  csr {
    CN = "${DEVICE_CN}"
  }

  destination {
    path  = "/var/lib/vault-agent/${APP}/tpm"
    umask = "077"
  }
}

auto_auth {
  method "tpm" {
    mount_path = "auth/tpm"
    config = {
      tpm_cert  = "host_identity"
      role_name = "${APP}-app"
    }
  }
}

api_proxy {
  use_auto_auth_token = "force"
}

listener "unix" {
  address      = "/run/vault-proxy/${APP}.sock"
  socket_mode  = "600"
  socket_user  = "${APP}"
  socket_group = "${APP}"
  tls_disable  = true
}
