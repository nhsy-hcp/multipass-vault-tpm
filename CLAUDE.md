# CLAUDE.md

## What this is

A demonstration lab: a macOS host drives a Multipass Ubuntu 24.04 VM running two
software TPMs (`swtpm`), a **Vault Enterprise** dev server with TLS, and the Vault CLI
acting as a device that enrols with Vault's `tpm` auth method by EK/AK attestation and
logs in over mTLS with a key generated inside — and non-exportable from — the TPM. The
repo is a `Taskfile.yml`, a set of numbered bash scripts pushed into the VM, and the
documentation in `docs/`.

**Vault Enterprise only.** The `tpm` auth method does not exist in OSS Vault. Vault is
the GA `vault-enterprise` package, installed inside the VM from HashiCorp's apt
repository by `task provision`, pinned to `VAULT_VERSION` (default `2.2.0+ent-1`) and
held with `apt-mark hold`. The licence text lives on the host as `VAULT_LICENSE` in
`.env` — Vault's own variable name; `.env` is gitignored and **a licence is never
committed**.

## Golden rule

**All lab state lives inside the VM.** The host holds source only, plus `.env`, which
carries the licence text and no other secret. There are no keys, certificates,
TPM state or Vault data on the macOS side, and there never should be — the `.gitignore`
blocks `*.pem`, `*.crt`, `*.csr`, `*.key`, `*.serial`, `*.tpmkey` and `*.hclic` (a backstop now
that the licence is text in `.env`) for that reason. If you
find yourself looking for `client.crt` on the host, you are in the wrong place: it is at
`~/lab/tpm/node01/` inside the VM. Inspect it with `task shell` or `multipass exec`.

## Task catalogue

Run `task --list` for the authoritative version. Grouped by purpose:

**Host**

| Task | Purpose |
|---|---|
| `deps` | Check host dependencies (multipass, task, jq, git; optional graphviz, shellcheck, gitleaks, pre-commit) and that `VAULT_LICENSE` is non-empty (reported without printing it) |
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
| `provision` | Part 1: install and hold `vault-enterprise` at `VAULT_VERSION` from HashiCorp's apt repo, push the licence, install TPM tooling |
| `tpm` | Part 2: start both software TPMs as systemd units, each on a unix socket |
| `vault` | Part 3: start the Vault dev server (TLS, licensed) as a systemd unit |
| `config` | Parts 4–5: tpm auth mount and CA, KV secret, `device-read` policy, `devices` TPM group and role, orchestrator policy and token |
| `enrol` | Part 6: read the EK, register it as the orchestrator, attest as the device (no token) |

**Demo**

| Task | Purpose |
|---|---|
| `demo` | The full narrated run (Parts 6–11), pausing between parts — `PAUSE=0 task demo` runs it straight through |
| `demo:nonexportable` | The key files are TPM-sealed handles, not private keys |
| `demo:login` | Part 7: mTLS login with the TPM-held key |
| `demo:privilege` | Part 7.3: read succeeds, write denied |
| `demo:negative` | Part 8: all five negative tests in order |
| `demo:negative:stolen-key` | 8.1: the blobs fail the integrity check on a different TPM |
| `demo:negative:unenrolled-tpm` | 8.2: an unregistered EK is refused at `gentpmcert/begin` |
| `demo:negative:untrusted-ca` | 8.3: a genuinely attested cert from another mount's CA is rejected |
| `demo:negative:wrong-role` | 8.4: a trusted-CA cert bound to a different TPM and role is rejected |
| `demo:negative:revoked-token` | 8.5: a revoked token can no longer read |
| `demo:agent` | Part 9: Vault Agent attests, logs in and renders a secret unattended |
| `demo:proxy` | Part 10: a workload reads through a localhost agent API proxy (`127.0.0.1:8100`) holding no token; a caller's root token is ignored |
| `demo:multi-app` | Part 11: per-application agents (`payments`, `analytics`) on owner-only unix sockets, and six boundary checks |

**Maintenance**

| Task | Purpose |
|---|---|
| `reset` | Wipe lab state and TPM seeds inside the VM, keep the VM, Vault package and licence |
| `logs` / `logs:tpm` / `logs:vault` / `logs:agent` / `logs:proxy` | Journals for `swtpm@device`, `swtpm@attacker`, `vault-dev`, `vault-agent`, `vault-proxy-single` and `vault-proxy@*` |
| `agent:soak` | Run the agent past its token's max TTL (role temporarily at 1m/3m, restored from a trap) and report whether it re-authenticates and how many TPM slots are free — ~6m, not part of `task demo` |
| `tpm:flush` | Flush transient objects and sessions on both TPMs, and report the free slots — recovery after an interrupted run left a key loaded |
| `lint` | pre-commit: shellcheck, gitleaks |
| `docs:diagram` | Re-render `docs/diagrams/*.dot` and `*.svg` to PNG (needs graphviz and librsvg) |

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
  directly. The licence is pushed separately by `scripts/host/push_licence.sh`, from
  `task provision` only, and only when its sha256 differs from the installed copy: it
  reads `VAULT_LICENSE` from the environment — never argv — and installs it as the
  `vault-dev` unit's `EnvironmentFile`, `/etc/vault-dev.env` (root:root 0600). Vault
  itself comes from apt, installed by `00_provision.sh`.

  Temp files: the **host** uses the project-local `.tmp/` (never `/tmp`, never the
  session scratchpad); inside the **VM**, `/tmp` is correct and `VM_STAGE` namespaces it.
- **`as_lab_user` for everything.** Because scripts run as root, every `vault` and
  `tpm2_*` invocation goes through `as_lab_user`, which drops to the `ubuntu` user
  (`VM_USER`) and sources `~/lab/env.sh` first. In-VM layout variables in `common.sh`
  carry no `LAB_` prefix: `VM_USER`, `VM_DIR`, `STATE_DIR`, `TLS_DIR`, `TPM_DIR`,
  `SCRATCH_DIR`. Device attest directories are `DEVICE_DIR` locals, never `STATE_DIR`. TPM key blobs must be created by the same user that will
  later use them, and lab artefacts must not end up root-owned.
- **Show the command, never retype it.** Vault commands go through `vault_run`,
  `vault_run_allow_fail` or `vault_run_stdin` (the heredoc policy writes), which print
  the argv they are about to run via `show_cmd`/`fmt_cmd`. A hand-written `log_detail`
  beside a call drifts from it — `50_login.sh` was printing `tpm-state-dir=…` while
  running something else. Where the token matters more than the command, wrap it
  locally and label the identity: `as_orchestrator` in `40_enrol_device.sh`,
  `vault_as_device` in `60_privilege.sh`. `fmt_cmd` redacts real bearer tokens but
  deliberately shows `VAULT_TOKEN=device-holds-no-token`.
  Narration is written to **fd 9**, a duplicate of stderr taken once in `common.sh` —
  not stdout (callers parse it as JSON) and not stderr (the `report_expect` callers
  capture `2>&1` and would report the banner as the "actual" outcome). Probes —
  `mount_enabled`, readiness `vault status`, `vault read … >/dev/null 2>&1` existence
  checks — stay on plain `as_lab_user`: show what configures or demonstrates, not what
  merely looks.
- **Pausing is host-side.** `task demo` pauses between parts via the internal `_pause`
  task and `scripts/host/pause.sh`, gated on `PAUSE` (default 1). It must stay on the
  host: `multipass exec` has no pty flag and gets stdin only when its caller had one,
  and Parts 8.1/8.3/8.4 capture `50_login.sh … 2>&1`, so an in-VM prompt could be
  swallowed. The script reads `/dev/tty` on its own fd and skips rather than blocks
  when there is no terminal — never let a pause hang CI.
- **One socket per TPM.** Each swtpm serves `~/lab/tpmstate/<instance>/swtpm.sock`
  (plus a `.ctrl` socket for the swtpm TCTI). tpm2-tools use
  `TPM2TOOLS_TCTI=swtpm:path=<sock>`; the Vault CLI uses `-tpm-device-path=<sock>` on
  both `vault tpm attest` and `vault login -method=tpm` (flags, not K=V — in 2.2.0 GA
  the login method's only config keys are `role_name` and `mount`). `common.sh` exports `TPM_SOCK` and `ATTACKER_TPM_SOCK`. There are
  no TCP ports.
- **Attest through `tpm_attest`.** `common.sh` owns the device-side attestation call:
  no token, flush first, retry on the per-EK rate limit. Scripts call it rather than
  inlining `vault tpm attest`, so the rate-limit retry lives in one place.
  `NO_TOKEN` and `mount_enabled` live there too.
- **Flush before touching the TPM through Vault.** Vault 2.2.0 frees its own transient
  handles, but a raw socket has no resource manager: a client killed mid-call can still
  leave a key loaded, and swtpm has only three slots. Call `flush_tpm_contexts [sock]`
  before every `vault tpm …` or `vault login -method=tpm` as cheap insurance. Lab-only:
  `/dev/tpmrm0` does this itself.
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
  always `task config && task enrol` — never a full rebuild. `task config` deletes the
  certificates under `~/lab/tpm/*/` whenever it enables a fresh mount, because they were
  issued by a CA that no longer exists; without that, `task enrol` would keep them and
  login would fail. Keep that behaviour.
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
  orchestrator (scoped token, `enrol-orchestrator` policy: two paths) registers the EK
  in `identity/tpm` and admits it to the `devices` **group**; the device (no token)
  attests.
  The role trusts the group, not individual IDs, precisely so the orchestrator never
  needs write access to the auth role — a role write could change `token_policies`.
  Do not register the EK with root because it is shorter, do not give the orchestrator
  `auth/tpm/role/*`, and do not bind the role to `tpm_ids` directly. See
  `docs/architecture.md` → Trust model.
- **The common name is not an identity.** The device chooses its own CN at attestation
  and nothing checks it; the TPM ID and role in the SAN are what `auth/tpm/login`
  enforces. Never present the CN as "who this is" in narration or docs, and never build
  policy on it.
- **Revocation has four levers.** `disabled=true` on `identity/tpm/name/<device>`
  blocks both attestation (`403 permission denied`) and login (`authentication failed`),
  and `disabled=false` restores both — the reversible one. The others are removing the
  TPM from the group, deleting the record, and revoking tokens.
- **The attacker TPM is not a spare.** `swtpm@attacker` exists so the Part 8 tests can
  present the device's blobs to a TPM with a different storage seed (8.1), attest from an
  EK Vault has never seen (8.2), and act as a legitimate device of another role (8.4).
  It must keep its own state directory and must never share a seed with `swtpm@device`.
  8.2 and 8.4 keep separate state directories (`unenrolled`, `attacker`) so neither
  inherits the other's certificate.
- **The Part 8 tests undo their own Vault state.** 8.3 disables `auth/tpm-rogue` and 8.4
  deletes `node99` and `auth/tpm/role/other`, both from an `EXIT` trap armed before the
  writes, so an aborted run cleans up too. Without that the mount accumulates scaffolding
  nobody configured, visible in `vault auth list` for the rest of the demo. 8.2 still
  deletes any 8.4 registration defensively, for a run killed before its trap fired — keep
  that, and keep the traps.
- **8.3 uses a second tpm auth mount** (`auth/tpm-rogue`) as the "untrusted CA": same
  TPM, same EK, a real attestation, a different internal CA. A mount refuses attestation
  until its `config` has been written once, even though every field has a default.
- **The Part 9 agent breaks three lab conventions on purpose — keep all three.** Its
  unit is installed **disabled** and started by hand by `80_agent.sh`, never
  `enable --now` like every other unit: dev-mode Vault forgets the mount on restart, so
  an enabled agent would start at boot ahead of `task config && task enrol`, fail, and
  retry on a backoff for ever. It attests into its **own** directory
  (`~/lab/tpm/agent/`), because pointing `destination { path }` at `~/lab/tpm/node01/`
  would reissue over the material Parts 7 and 8 depend on. And it is **stopped on the
  way out** by an `EXIT` trap armed before the start, because it holds the device TPM
  and swtpm has three transient slots. The start gate checks `identity/tpmgroup`
  membership rather than a file, because the registry is in memory while
  `~/lab/tpm/node01/tpm_id` survives a Vault restart — `ConditionPathExists` cannot
  express it. The role is 15m/1h with no period, deliberately, so the agent logs in
  again at every `token_max_ttl`; do not give it a `token_period` — a token that renews
  for ever is the wrong shape for a TPM identity. `task agent:soak` is the regression
  test for that re-authentication, and it must keep restoring the role's TTLs from its
  trap (it traps `INT`/`TERM` as well as `EXIT`, because it runs for minutes and gets
  interrupted).
- **The agent's `tpm_cert` block is not the CLI's flags.** `auto_auth` references a
  named `tpm_cert` block (`config = { tpm_cert = "node01" }`) which carries
  `role_name`, `mount_path` and the `tpm` / `destination` / `renew` sub-blocks.
  Keep `role_name` in the `tpm_cert` block only (repeating it in the method's `config`
  map is accepted silently). An empty `tpm_cert {}` block segfaults the agent, and
  unknown keys anywhere in it are dropped in silence. See `docs/architecture.md` →
  Vault Agent.
- **The Parts 10–11 proxies keep the Part 9 conventions, plus two of their own.** Both
  run `vault agent` with an `api_proxy` stanza — **not** `vault proxy`, which in 2.2.0 has
  no `tpm` auto-auth method — and must keep `use_auto_auth_token = "force"`, which is what
  makes a caller's root token irrelevant. Units disabled, started by their script, own
  attest directories, stopped and flushed from an `EXIT` trap, a 12s wait before each
  agent start (a rate-limited agent retries ~45s later). Part 11's agents run as **root**,
  deliberately: only root can set `socket_user` to another uid, and an agent running as
  the application's user would hand that user the TPM — and a login as any role the
  `devices` group is trusted for. Their attest directories are `~/lab/tpm/app-<app>/`,
  root 0700, one level down so `task config`'s stale-certificate sweep and `task reset`
  cover them. `payments-app` and `analytics-app` trust the `devices` **group**, like
  `devices` — the TPM identifies the host, never the application; the OS draws that
  boundary. Do not "fix" that with `tpm_ids` or per-app groups.
- **`.env` beats the command line for `VM_NAME`.** The Taskfile's `dotenv` values win over
  `task VM_NAME=…`, so a second VM needs `VM_NAME` changed in `.env` (or removed from it),
  not a CLI override — otherwise the run quietly targets `tpm-lab`.
- **`.plans/` and `.tmp/` are gitignored.** The migration plan at
  `.plans/tpm-auth-method-migration.md` records the design and the empirical findings,
  but it is not committed — do not link to it from `README.md` or `docs/`.
- **Diagram PNGs are committed.** `docs/diagrams/*.png` are generated from the `.dot`
  sources but tracked in git so the docs render on GitHub. Edit the `.dot`, then run
  `task docs:diagram` and commit both.
- **The licence is in `.env`, so `.env` is a secret.** Never print, echo or pass
  `VAULT_LICENSE` on a command line or through a Task template (`{{.VAULT_LICENSE}}`) —
  Task echoes commands. Scripts read it from the environment.
- **Git operations need explicit confirmation** and specific file paths — no `git add .`.
