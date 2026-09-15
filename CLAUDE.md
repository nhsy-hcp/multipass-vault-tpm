# CLAUDE.md

## What this is

A demonstration lab: a macOS host drives a Multipass Ubuntu 24.04 VM running a software
TPM (`swtpm`), a Vault dev server with TLS, and an OpenSSL client that authenticates to
Vault's cert auth method using a TLS key generated inside — and non-exportable from —
the TPM. The repo is a `Taskfile.yml`, a set of numbered bash scripts pushed into the VM,
and the documentation in `docs/`.

## Golden rule

**All lab state lives inside the VM.** The host holds source only. There are no keys,
certificates, TPM state or Vault data on the macOS side, and there never should be — the
`.gitignore` blocks `*.pem`, `*.crt`, `*.csr`, `*.key`, `*.serial`, `*.tpmkey` for that
reason. If you find yourself looking for `node01.crt` on the host, you are in the wrong
place: it is at `~/lab/pki/` inside the VM. Inspect it with `task shell` or
`multipass exec`.

## Task catalogue

Run `task --list` for the authoritative version. Grouped by purpose:

**Host**

| Task | Purpose |
|---|---|
| `deps` | Check host dependencies (multipass, task, jq, git; optional graphviz, shellcheck, gitleaks, pre-commit) |
| `init` | One-time setup — install pre-commit hooks, seed `.env` |

**VM lifecycle**

| Task | Purpose |
|---|---|
| `launch` | Create the Multipass VM (no-op if it exists) |
| `start` (`up`) | Start a stopped VM |
| `stop` (`down`) | Stop the VM, keeping lab state on disk |
| `shell` | Interactive shell in the VM |
| `clean` | Delete and purge the VM entirely |
| `rebuild` | `clean`, then `lab` |

**Lab build** — each step idempotent and individually re-runnable

| Task | Purpose |
|---|---|
| `lab` | launch → provision → tpm → vault → config → enrol |
| `provision` | Part 1: install TPM tooling and Vault in the VM |
| `tpm` | Part 2: start both software TPMs as systemd units |
| `vault` | Part 3: start the Vault dev server (TLS) as a systemd unit |
| `config` | Parts 4–5: PKI device CA, KV secret, policy, cert auth |
| `enrol` | Part 6: create the device key in the TPM and enrol it with Vault |

**Demo**

| Task | Purpose |
|---|---|
| `demo` | The full narrated run (Parts 6–8) |
| `demo:nonexportable` | The key file is a TPM-wrapped blob, not a private key |
| `demo:login` | Part 7: mTLS login with the TPM-held key |
| `demo:privilege` | Part 7.3: read succeeds, write denied |
| `demo:negative` | Part 8: all five negative tests in order |
| `demo:negative:stolen-key` | 8.1: the blob is useless against a different TPM |
| `demo:negative:no-cert` | 8.2: login without a client certificate |
| `demo:negative:untrusted-ca` | 8.3: cert must chain to the device CA |
| `demo:negative:wrong-cn` | 8.4: trusted CA, wrong common name |
| `demo:negative:revoked-token` | 8.5: a revoked token can no longer read |

**Maintenance**

| Task | Purpose |
|---|---|
| `reset` | Wipe lab state inside the VM, keep the VM |
| `logs` / `logs:tpm` / `logs:vault` | Journals for `swtpm@device`, `swtpm@attacker`, `vault-dev` |
| `lint` | pre-commit: shellcheck, gitleaks |
| `docs:diagram` | Re-render `docs/diagrams/*.dot` to PNG (needs graphviz) |

## Conventions

- **Script naming.** In-VM scripts are `scripts/NN_*.sh`, numbered in execution order.
  Host-only scripts live in `scripts/host/`. Shared helpers in `scripts/lib/common.sh`.
- **How scripts reach the VM.** The internal `_run` task does
  `multipass transfer` of `common.sh` and the script into `/tmp`, then
  `multipass exec … sudo -E bash /tmp/NN_*.sh <args>`. Scripts therefore run as **root**
  and source `/tmp/common.sh`, not a relative path.
- **`as_lab_user` for everything.** Because scripts run as root, every `vault`, `openssl`
  and `tpm2_*` invocation goes through `as_lab_user`, which drops to the `ubuntu` user
  and sources `~/lab/env.sh` first. TPM key blobs must be created by the same user that
  will later use them, and lab artefacts must not end up root-owned.
- **Idempotence is required.** Any script may be re-run at any time. Use `wait_for_unit`
  for readiness rather than `sleep`, and `write_if_changed` before reloading systemd.
- **Reporting, not asserting.** The Part 8 scripts print expected-vs-actual via
  `report_expect` and let the operator judge, rather than failing the task.
- **Linting.** All shell must pass `shellcheck --severity=warning`; `task lint` runs the
  pre-commit hooks including gitleaks.
- **British spelling** throughout: "enrol", "behaviour", "artefact".

## Gotchas

- **Vault dev mode is in-memory.** Restarting `vault-dev` wipes the PKI mount, the
  policy, cert auth and the KV secret. The fix is always `task config && task enrol` —
  never a full rebuild.
- **Never "fix" the demo with a software key.** If the TPM path fails, diagnose the TPM
  path. Generating a plain EC key and pointing OpenSSL at it makes every command succeed
  and destroys the entire point of the lab.
- **The attacker TPM is not a spare.** `swtpm@attacker` on :2331 exists solely so Part
  8.1 can present the device's key blob to a TPM with a different storage seed. It must
  keep its own state directory and must never share a seed with `swtpm@device`.
- **`.plans/` and `.tmp/` are gitignored.** The source guide at
  `.plans/vault-tpm-cert-auth-lab.md` is the substantive reference for what the lab does,
  but it is not committed — do not link to it from `README.md` or `docs/`.
- **Diagram PNGs are committed.** `docs/diagrams/*.png` are generated from the `.dot`
  sources but tracked in git so the docs render on GitHub. Edit the `.dot`, then run
  `task docs:diagram` and commit both.
- **Git operations need explicit confirmation** and specific file paths — no `git add .`.
