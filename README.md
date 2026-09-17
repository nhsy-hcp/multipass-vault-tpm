# Vault TPM Auth Lab

A self-contained lab that shows a machine authenticating to HashiCorp Vault with
**Vault Enterprise's `tpm` auth method**: the device is identified by its TPM's
endorsement key, it proves possession of that key through an EK/AK attestation, Vault's
internal CA issues it a client certificate, and every login is an mTLS handshake signed
inside the TPM by a key that can never be exported. The device holds no Vault token to
enrol — the silicon is the credential. The lab's negative tests prove it: the same key
blobs against a different TPM fail the integrity check before the handshake even starts,
and a TPM Vault has not registered cannot begin attestation at all.

**This lab is for Vault Enterprise only.** The `tpm` auth method is an Enterprise
feature, and the lab runs from a private beta build that you copy into `.bin/` by hand.

![Topology](docs/diagrams/topology.png)

## Prerequisites

Everything runs on a macOS host driving an Ubuntu 24.04 arm64 VM via Multipass.

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

Two files that are **not** in this repository and never will be, both placed by hand:

| File | What it is |
|---|---|
| `.bin/vault_2.2.0-beta1+ent_linux_arm64` | The Vault Enterprise private beta binary (linux/arm64) |
| `.bin/vault.hclic` | Your Vault Enterprise licence |

`.bin/` is gitignored. `task provision` copies both into the VM, installs the binary at
`/usr/local/bin/vault`, and skips the copy on later runs when the installed copy already
matches. Different paths can be set in `.env` (see `.env.template`).

## Quick start

```bash
task deps    # verify host tooling and that .bin/ holds the binary and licence
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
`task shell`, and `task logs:tpm` / `task logs:vault` for the systemd units.

## Documentation

[`docs/architecture.md`](docs/architecture.md) covers the topology, the enrolment and
login trust chain, what the TPM does and does not guarantee, what was learned by
running the beta, a task-by-task walkthrough, troubleshooting, and how the lab maps onto
a production deployment.

## Reset and cleanup

```bash
task reset   # wipe lab state inside the VM (including both TPMs' seeds), keep the VM
task clean   # delete and purge the VM entirely
task rebuild # clean, then rebuild the whole lab from scratch
```

All lab state — keys, certificates, Vault configuration — lives inside the VM. The host
holds nothing but this source tree and the two files in `.bin/`.
