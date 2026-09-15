# Vault TPM-Backed Cert Auth Lab

A self-contained lab that shows a machine authenticating to HashiCorp Vault with a TLS
client certificate whose private key was generated **inside a TPM** and can never be
exported from it. Vault's PKI engine signs the device's CSR, the cert auth method
validates the resulting certificate over mTLS and hands back a short-lived token scoped
to a single secret. This matters because the usual alternatives — a bearer token in a
file, or a PEM private key on disk — can be copied off the machine and replayed
anywhere; a TPM-held key cannot. The lab's negative tests prove it: the same key blob,
presented against a different TPM, simply fails the handshake.

![Topology](docs/diagrams/topology.png)

## Prerequisites

Everything runs on a macOS host driving an Ubuntu 24.04 VM via Multipass.

| Tool | Why |
|---|---|
| `multipass` | hosts the lab VM — required |
| `task` ([go-task](https://taskfile.dev)) | runs everything — required |
| `jq` | parses Vault JSON — required |
| `git` | required |
| `graphviz` | optional — only to re-render the diagrams with `task docs:diagram` |
| `shellcheck`, `gitleaks`, `pre-commit` | optional — only for `task lint` |

```bash
brew install --cask multipass
brew install go-task jq graphviz shellcheck gitleaks pre-commit
```

## Quick start

```bash
task deps    # verify host tooling
task init    # one-time project setup (pre-commit hooks, .env)
task all     # launch the VM, provision it, start the TPMs and Vault, enrol node01
task demo    # the narrated walkthrough, including every negative test
```

`task all` takes a few minutes on first run; each of its steps is idempotent and
individually re-runnable. `task demo` takes under a minute.

## All tasks

```bash
task --list
```

That is the authoritative catalogue — build steps, individual demo segments,
`task shell`, and `task logs:tpm` / `task logs:vault` for the two systemd units.

## Documentation

[`docs/architecture.md`](docs/architecture.md) covers the topology, the enrolment and
login trust chain, what the TPM does and does not guarantee, a task-by-task walkthrough,
troubleshooting, and how the lab maps onto a production deployment.

## Reset and cleanup

```bash
task reset   # wipe lab state inside the VM, keep the VM
task clean   # delete and purge the VM entirely
task rebuild # clean, then rebuild the whole lab from scratch
```

All lab state — keys, certificates, Vault configuration — lives inside the VM. The host
holds nothing but this source tree.
