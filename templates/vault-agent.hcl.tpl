# Vault Agent configuration for the Part 9 demo.
#
# REFERENCE COPY. Templates live on the host and are never transferred into the
# VM, so the authoritative content is the heredoc in scripts/80_agent.sh.
# Keep the two in sync.
#
# Rendered to ${VM_DIR}/agent/agent.hcl, 0640, owned by the lab user.
#
# The config has two halves, and the split is the whole lesson of Part 9:
#
#   tpm_cert "<device>"   gets and keeps the certificate. It attests on first
#                         run, persists ak.blob, app.blob, ca_chain.pem,
#                         client-key.json and client.crt under
#                         destination.path, and schedules its own renewal
#                         inside the certificate's lifetime. On restart it
#                         tries to reuse what it persisted, but on swtpm the
#                         check needs more than the three transient slots
#                         ("out of memory for object contexts"), so it
#                         re-attests on every start. Harmless: min_backoff
#                         below covers Vault's per-EK rate limit.
#   auto_auth             uses that certificate to log in over mTLS and writes
#                         the resulting token to a sink.
#
# Traps found by running it:
#
#   1. role_name belongs in the tpm_cert block. Vault 2.2.0 also accepts it in
#      the method's config map without complaint; keep it in one place.
#   2. Unknown keys in these blocks are dropped without a word. A csr block
#      with a misnamed field is ignored and the certificate's common name
#      falls back to the hostname. Nothing checks the common name anyway (see
#      docs/architecture.md, Trust model), but a typo in any other key is just
#      as invisible.
#
# An empty tpm_cert block segfaults the agent rather than failing validation.

vault {
  address = "https://127.0.0.1:8200"
  ca_cert = "${TLS_DIR}/vault-ca.pem"
}

tpm_cert "${DEVICE}" {
  role_name  = "devices"
  mount_path = "auth/tpm"

  # On real hardware this is /dev/tpmrm0 and nothing else changes.
  tpm {
    device_path = "${TPM_SOCK}"
  }

  destination {
    path = "${TPM_DIR}/agent"
  }

  renew {
    min_validity_percentage = 50
  }
}

auto_auth {
  method {
    type       = "tpm"
    mount_path = "auth/tpm"

    # Vault rate-limits attestation to one per EK every ten seconds.
    min_backoff = "10s"
    max_backoff = "2m"

    config = {
      tpm_cert = "${DEVICE}"
    }
  }

  sink {
    type = "file"
    config = {
      path = "${VM_DIR}/agent/token"
    }
  }
}

template {
  source      = "${VM_DIR}/agent/message.tpl"
  destination = "${VM_DIR}/agent/message.txt"
  perms       = "0640"
}
