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
feature: the lab installs the GA Vault Enterprise package from HashiCorp's apt repository
inside the VM, and you supply the licence.

![Topology](docs/diagrams/topology.png)

## Prerequisites

Everything runs on a macOS host driving an Ubuntu 24.04 VM via Multipass (arm64 on Apple
Silicon, amd64 on Intel — both work).

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

One file that is **not** in this repository and never will be:

| File | What it is |
|---|---|
| A Vault Enterprise licence | Its text pasted into `.env` as `VAULT_LICENSE` on one line (`task init` seeds `.env` from `.env.template`); `.env` is gitignored |

`task provision` pushes the licence into the VM, skipping the copy on later runs when the
installed copy already matches, and installs `vault-enterprise` from HashiCorp's apt
repository at the version pinned by `VAULT_VERSION` (default `2.2.0+ent-1`, overridable
in `.env`), holding it there so an `apt upgrade` cannot move it.

## Quick start

```bash
task deps    # verify host tooling and that VAULT_LICENSE is set in .env
task init    # one-time project setup (pre-commit hooks, .env)
task all     # launch the VM, provision it, start the TPMs and Vault, enrol node01
task demo    # the narrated walkthrough, every negative test, the Vault Agent and its proxies
```

`task all` takes a few minutes on first run; each of its steps is idempotent and
individually re-runnable.

`task demo` pauses between parts so there is room to narrate, printing each Vault
command as it runs; press ⏎ to go on, `q` to stop and be told how to resume.
`PAUSE=0 task demo` runs it straight through in under a minute. `.env` (seeded by
`task init`) can override that, the VM name, the device name and domain, the Vault
version, and holds the licence.

## All tasks

```bash
task --list
```

That is the authoritative catalogue — build steps, individual demo segments,
`task shell`, and `task logs:tpm` / `task logs:vault` / `task logs:agent` /
`task logs:proxy` for the systemd units.

## Beyond the login: agents for workloads

The last three parts of `task demo` take the operator out of the loop:

| Part | Task | What it shows |
|---|---|---|
| 9 | `task demo:agent` | Vault Agent attests, logs in and renders a secret with no operator and no starting token |
| 10 | `task demo:proxy` | A workload talks to `http://127.0.0.1:8100` and never holds a token — the agent forces its own TPM-authenticated one onto every request |
| 11 | `task demo:multi-app` | Two applications on one TPM, each with its own agent, role and owner-only Unix socket — and the checks that neither can reach the other's secret, socket or the TPM |

The TPM proves which machine is asking, not which application; Part 11 shows where the
boundary between applications has to come from instead.

## Documentation

[`docs/architecture.md`](docs/architecture.md) covers the topology, the enrolment and
login trust chain, what the TPM does and does not guarantee, the Vault Agent doing the
same login unattended and as a per-application proxy, what was learned by running Vault 2.2.0, a task-by-task
walkthrough, troubleshooting, and how the lab maps onto a production deployment.

## Reset and cleanup

```bash
task reset   # wipe lab state inside the VM (including both TPMs' seeds), keep the VM
task clean   # delete and purge the VM entirely
task rebuild # clean, then rebuild the whole lab from scratch
```

All lab state — keys, certificates, Vault configuration — lives inside the VM. The host
holds nothing but this source tree and the gitignored `.env`, whose only secret is the
licence.
