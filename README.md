# Vault TPM Authentication Lab

A Vault Enterprise lab on an Ubuntu VM. You configure TPM auth yourself, log in
with a TPM-backed application key, then put one workload behind an owner-only
Unix socket whose agent logs in as that same role.

## Prerequisites

Everything runs on a macOS host driving an Ubuntu 24.04 VM via Multipass.

Vault TPM authentication requires Vault Enterprise `2.2.0+ent`. Put the Enterprise
licence at `.vault-license` before `task provision-demo`.

| Tool | Why |
|---|---|
| `multipass` | hosts the lab VM — required |
| `task` ([go-task](https://taskfile.dev)) | runs everything — required |
| `jq` | parses Vault JSON — required |
| `git` | required |
| `graphviz`, `librsvg` | optional — only to re-render diagrams with `task docs:diagram` |
| `shellcheck`, `gitleaks`, `pre-commit` | optional — only for `task lint` |

```bash
brew install --cask multipass
brew install go-task jq graphviz librsvg shellcheck gitleaks pre-commit
```

## Walkthrough

`task provision-demo` launches the VM, installs the TPM tooling and Vault, and
starts the software TPM and the Vault dev server. It does not enable auth
methods, write policies, or enrol a device.

Commands marked **on device** have to run where the TPM is. In this lab that is
the VM. Commands marked **anywhere** only talk to Vault.

### Prepare the VM

On the host:

```bash
task provision-demo
task shell
```

In the VM:

```bash
source ~/lab/env.sh
```

`~/lab/env.sh` sets `VAULT_ADDR`, `VAULT_CACERT`, and `VAULT_TOKEN=root`.

### Secret and policy

```bash
vault kv put secret/devices/node01 \
  message="hello from vault, attested by TPM key"

vault policy write device-read - <<'EOF'
path "secret/data/devices/*" {
  capabilities = ["read"]
}
EOF
```

### Enable TPM auth and enrol this TPM

Anywhere — enable the method:

```bash
vault auth enable tpm
vault write auth/tpm/config default_cert_ttl=2160h
```

On device — enrol the endorsement key:

```bash
vault tpm enroll \
  -name=node01 \
  -tpm-device-path=/run/swtpm/device.sock \
  -metadata=lab=tpm-lab

tpm_id=$(vault tpm ek -tpm-device-path=/run/swtpm/device.sock -format=json | jq -r .tpm_id)
```

Anywhere — bind a role to that TPM id:

```bash
vault write auth/tpm/role/machine-cli \
  tpm_ids="$tpm_id" \
  token_policies=device-read \
  token_ttl=15m \
  token_max_ttl=1h
```

### Attest and log in

On device. Attest creates the application key for this role. `unset` drops the
root token from the shell so the login is the TPM method.

```bash
unset VAULT_TOKEN
mkdir -p ~/lab/cli-tpm

vault tpm attest \
  -role-name=machine-cli \
  -tpm-device-path=/run/swtpm/device.sock \
  -tpm-state-dir="$HOME/lab/cli-tpm" \
  -cert-subject-CN=node01.devices.lab.local

vault login -method=tpm -no-store \
  -tpm-state-dir="$HOME/lab/cli-tpm" \
  -tpm-device-path=/run/swtpm/device.sock \
  role_name=machine-cli

token=$(env -u VAULT_TOKEN vault login -method=tpm -no-store -field=token \
  -tpm-state-dir="$HOME/lab/cli-tpm" \
  -tpm-device-path=/run/swtpm/device.sock \
  role_name=machine-cli)

VAULT_TOKEN="$token" vault kv get secret/devices/node01
```

### Socket proxy

Leave the VM shell. On the host, `task proxy:socket` creates the `payments`
user and starts one Vault Agent on `/run/vault-proxy/payments.sock`. The agent
attests as `machine-cli` and forces that token onto the socket.

```bash
task proxy:socket
task shell
```

In the VM, the workload does not use a Vault token of its own. Only `payments`
can open the socket:

```bash
echo $VAULT_TOKEN
sudo -u payments env \
  VAULT_ADDR=unix:///run/vault-proxy/payments.sock \
  vault kv get secret/devices/node01
```

## All tasks

```bash
task --list
```

That is the authoritative catalogue. `task shell` opens the VM.
`task logs:tpm` and `task logs:vault` follow the software TPM and Vault journals.

[`docs/architecture.md`](docs/architecture.md) covers the topology, what the TPM
does and does not guarantee, and how the lab maps onto a production deployment.

## Reset and cleanup

```bash
task reset   # wipe lab state inside the VM, keep the VM
task clean   # delete and purge the VM entirely
task rebuild # clean, then rebuild the whole lab from scratch
```

All lab state — keys, certificates, Vault configuration — lives inside the VM. The host
holds nothing but this source tree.
