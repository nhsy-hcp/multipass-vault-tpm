# CLAUDE.md

## What this is

A demonstration lab: a macOS host drives a Multipass Ubuntu 24.04 VM running two
software TPMs (`swtpm`), a **Vault Enterprise** dev server with TLS, and the Vault CLI
acting as a device that enrols with Vault's `tpm` auth method by EK/AK attestation and
logs in over mTLS with a key generated inside — and non-exportable from — the TPM. The
repo is a `Taskfile.yml`, a set of numbered bash scripts pushed into the VM, and the
documentation in `docs/`.

**Vault Enterprise only.** The `tpm` auth method does not exist in OSS Vault. The
binary is a private beta, `.bin/vault_2.2.0-beta1+ent_linux_arm64`, with its licence at
`.bin/vault.hclic`. Both are copied there by hand, both are gitignored, and **nothing in
`.bin/` is ever committed**. `task provision` pushes them into the VM; apt is not
involved in installing Vault at all.

## Golden rule

**All lab state lives inside the VM.** The host holds source and the two files in
`.bin/`, nothing else. There are no keys, certificates, TPM state or Vault data on the
macOS side, and there never should be — the `.gitignore` blocks `*.pem`, `*.crt`,
`*.csr`, `*.key`, `*.serial`, `*.tpmkey`, `*.hclic` and `.bin/` for that reason. If you
find yourself looking for `client.crt` on the host, you are in the wrong place: it is at
`~/lab/tpm/node01/` inside the VM. Inspect it with `task shell` or `multipass exec`.

## Task catalogue

Run `task --list` for the authoritative version. Grouped by purpose:

**Host**

| Task | Purpose |
|---|---|
| `deps` | Check host dependencies (multipass, task, jq, git; optional graphviz, shellcheck, gitleaks, pre-commit) and that `.bin/` holds the Vault binary and licence |
| `init` | One-time setup — install pre-commit hooks, seed `.env` |

**VM lifecycle**

| Task | Purpose |
|---|---|
| `launch` | Create the Multipass VM (no-op if it exists) |
| `start` (`up`) | Start a stopped VM |
| `stop` (`down`) | Stop the VM, keeping lab state on disk |
| `shell` | Interactive shell in the VM |
| `clean` | Delete and purge the VM entirely |
| `rebuild` | `clean`, then `all` |

**Lab build** — each step idempotent and individually re-runnable

| Task | Purpose |
|---|---|
| `all` | launch → provision → tpm → vault → config → enrol |
| `provision` | Part 1: push the Vault Enterprise binary and licence from `.bin/`, install TPM tooling |
| `tpm` | Part 2: start both software TPMs as systemd units, each on a unix socket |
| `vault` | Part 3: start the Vault dev server (TLS, licensed) as a systemd unit |
| `config` | Parts 4–5: tpm auth mount and CA, KV secret, `device-read` policy, `devices` TPM group and role, orchestrator policy and token |
| `enrol` | Part 6: read the EK, register it as the orchestrator, attest as the device (no token) |

**Demo**

| Task | Purpose |
|---|---|
| `demo` | The full narrated run (Parts 6–8) |
| `demo:nonexportable` | The key files are TPM-sealed handles, not private keys |
| `demo:login` | Part 7: mTLS login with the TPM-held key |
| `demo:privilege` | Part 7.3: read succeeds, write denied |
| `demo:negative` | Part 8: all five negative tests in order |
| `demo:negative:stolen-key` | 8.1: the blobs fail the integrity check on a different TPM |
| `demo:negative:unenrolled-tpm` | 8.2: an unregistered EK is refused at `gentpmcert/begin` |
| `demo:negative:untrusted-ca` | 8.3: a genuinely attested cert from another mount's CA is rejected |
| `demo:negative:wrong-role` | 8.4: a trusted-CA cert bound to a different TPM and role is rejected |
| `demo:negative:revoked-token` | 8.5: a revoked token can no longer read |

**Maintenance**

| Task | Purpose |
|---|---|
| `reset` | Wipe lab state and TPM seeds inside the VM, keep the VM, binary and licence |
| `logs` / `logs:tpm` / `logs:vault` | Journals for `swtpm@device`, `swtpm@attacker`, `vault-dev` |
| `lint` | pre-commit: shellcheck, gitleaks |
| `docs:diagram` | Re-render `docs/diagrams/*.dot` to PNG (needs graphviz) |

## Conventions

- **Script naming.** In-VM scripts are `scripts/NN_*.sh`, numbered in execution order.
  Host-only scripts live in `scripts/host/`. Shared helpers in `scripts/lib/common.sh`.
- **How scripts reach the VM.** The internal `_run` task does
  `multipass transfer` of `common.sh` and every script into the guest staging
  directory (`VM_STAGE`, currently `/tmp/tpm-lab`), then
  `multipass exec … sudo -E bash $VM_STAGE/NN_*.sh <args>`. Scripts therefore run as
  **root**, and each resolves its own location into `STAGE_DIR` and sources
  `"${STAGE_DIR}/common.sh"` — never a hardcoded path, so the staging directory can move.
  All scripts are transferred every time, because the Part 8 demos invoke `50_login.sh`
  directly. The Vault binary is pushed separately by `scripts/host/push_vault_bin.sh`,
  from `task provision` only, and only when its sha256 differs from the installed copy.

  Temp files: the **host** uses the project-local `.tmp/` (never `/tmp`, never the
  session scratchpad); inside the **VM**, `/tmp` is correct and `VM_STAGE` namespaces it.
- **`as_lab_user` for everything.** Because scripts run as root, every `vault` and
  `tpm2_*` invocation goes through `as_lab_user`, which drops to the `ubuntu` user and
  sources `~/lab/env.sh` first. TPM key blobs must be created by the same user that will
  later use them, and lab artefacts must not end up root-owned.
- **One socket per TPM.** Each swtpm serves `~/lab/tpmstate/<instance>/swtpm.sock`
  (plus a `.ctrl` socket for the swtpm TCTI). tpm2-tools use
  `TPM2TOOLS_TCTI=swtpm:path=<sock>`; the Vault CLI uses `-tpm-device-path=<sock>` /
  `tpmDevice=<sock>`. `common.sh` exports `TPM_SOCK` and `ATTACKER_TPM_SOCK`. There are
  no TCP ports any more.
- **Flush before touching the TPM through Vault.** A raw socket has no resource
  manager, and `vault login -method=tpm` leaks one transient handle per call; swtpm has
  three slots. Call `flush_tpm_contexts [sock]` before every `vault tpm …` or
  `vault login -method=tpm`. Lab-only: `/dev/tpmrm0` does this itself.
- **Always `-no-store` on login.** Otherwise the device token replaces the root token in
  the lab user's `~/.vault-token`.
- **Idempotence is required.** Any script may be re-run at any time. Use `wait_for_unit`
  for readiness rather than `sleep`, `write_if_changed` before reloading systemd, and
  never attest when a certificate that is still good for an hour exists — Vault
  rate-limits attestation per EK (about ten seconds), so scripts that must attest retry
  after a 12-second wait.
- **Reporting, not asserting.** The Part 8 scripts print expected-vs-actual via
  `report_expect` and let the operator judge, rather than failing the task.
- **Linting.** All shell must pass `shellcheck --severity=warning`; `task lint` runs the
  pre-commit hooks including gitleaks.
- **British spelling** throughout: "enrol", "behaviour", "artefact".

## Gotchas

- **Vault dev mode is in-memory.** Restarting `vault-dev` wipes the tpm auth mount and
  its CA, the `identity/tpm` registry, the policies, the KV secret and every token —
  including the orchestrator token at `~/lab/state/orchestrator.token`. The fix is
  always `task config && task enrol` — never a full rebuild.
- **Never "fix" the demo with a software key or a PEM certificate.** If the TPM path
  fails, diagnose the TPM path. The whole point is that the key exists only inside the
  TPM and that Vault issued the certificate only after attestation.
- **The device holds no token — on purpose.** `gentpmcert/begin`, `gentpmcert/finish`
  and `auth/tpm/login` are unauthenticated: possession of a registered EK is the
  credential. Device-side commands in `40_enrol_device.sh` and `50_login.sh` set
  `VAULT_TOKEN` to a placeholder so the transcript proves root is not on the wire. Do not
  "simplify" by letting them inherit `VAULT_TOKEN=root` from `env.sh`.
- **The orchestrator/device split in `scripts/40_enrol_device.sh` is the point.** Three
  privilege domains: the operator (root, `task config`) configures trust; the
  orchestrator (scoped token, `enrol-orchestrator` policy) registers the EK in
  `identity/tpm` and admits it to the `devices` **group**; the device (no token) attests.
  The role trusts the group, not individual IDs, precisely so the orchestrator never
  needs write access to the auth role — a role write could change `token_policies`.
  Do not register the EK with root because it is shorter, do not give the orchestrator
  `auth/tpm/role/*`, and do not bind the role to `tpm_ids` directly. See
  `docs/architecture.md` → Trust model.
- **`disabled=true` on a TPM record does nothing in this beta.** It blocked neither
  attestation nor login when tested. Revocation means removing the TPM from the group,
  deleting the record, or revoking tokens. Retest on new builds.
- **The attacker TPM is not a spare.** `swtpm@attacker` exists so the Part 8 tests can
  present the device's blobs to a TPM with a different storage seed (8.1), attest from an
  EK Vault has never seen (8.2), and act as a legitimate device of another role (8.4).
  It must keep its own state directory and must never share a seed with `swtpm@device`.
  8.2 deletes any registration 8.4 left behind, so the two can run in either order.
- **8.3 uses a second tpm auth mount** (`auth/tpm-rogue`) as the "untrusted CA": same
  TPM, same EK, a real attestation, a different internal CA. A mount refuses attestation
  until its `config` has been written once, even though every field has a default.
- **`.plans/` and `.tmp/` are gitignored.** The migration plan at
  `.plans/tpm-auth-method-migration.md` records the design and the empirical findings,
  but it is not committed — do not link to it from `README.md` or `docs/`.
- **Diagram PNGs are committed.** `docs/diagrams/*.png` are generated from the `.dot`
  sources but tracked in git so the docs render on GitHub. Edit the `.dot`, then run
  `task docs:diagram` and commit both.
- **Git operations need explicit confirmation** and specific file paths — no `git add .`.
