# Architecture

## Overview

Most machine-to-machine authentication rests on something copyable. A Vault token in a
file, an AppRole secret ID, a PEM private key next to its certificate — each is just
bytes. Anyone who can read the file can become the machine, anywhere, for as long as the
credential lives. Rotation shortens the window; it does not close it.

A TPM changes the shape of the problem. A key created inside the TPM never exists
outside it in usable form. What lands on disk is a blob encrypted to that TPM's storage
root key: an opaque object the TPM can load and use, and that no other TPM can. The
credential stops being data you hold and becomes a capability the hardware grants.

This lab demonstrates the whole chain end to end:

- a device key generated **inside** a TPM 2.0, never exported;
- Vault's PKI engine acting as the device CA and signing that device's CSR;
- Vault's cert auth method validating the certificate over mTLS and issuing a
  short-lived, least-privilege token;
- negative tests proving that a stolen key blob, a certificate from an untrusted CA, a
  certificate with the wrong common name, and a revoked token all fail.

The TPM is a software TPM (`swtpm`) rather than silicon, because macOS does not expose a
TPM to Multipass guests. Everything above the TCTI layer is identical to real hardware.

## Topology

![Topology](diagrams/topology.png)

| Component | What it is | Why it lives where it does |
|---|---|---|
| Terminal / `Taskfile.yml` | The only thing on the macOS host | The host holds source, never lab state |
| Multipass CLI | Creates the VM; `multipass transfer` + `exec` push scripts in | The lab needs Linux, systemd and a TPM stack |
| `swtpm@device` (tcp :2321) | Software TPM 2.0, systemd unit | macOS exposes no TPM to guests, so the VM provides its own |
| `swtpm@attacker` (tcp :2331) | A second software TPM with a **different storage seed** | Stands in for "a different machine" during the Part 8.1 stolen-key test. Used by that test only |
| Device client | `openssl` with the `tpm2` provider | Drives key generation, the CSR, and the mTLS login |
| `vault-dev` (https://127.0.0.1:8200) | `vault server -dev -dev-tls`, systemd unit | Dev mode keeps the lab to one command; TLS is required for cert auth |
| PKI engine | The device CA plus the `devices` issuing role | Signs device CSRs for `*.devices.lab.local` |
| cert auth method | Role `tpm-devices`, trusting the device CA | Validates the client certificate and issues the token |
| KV v2 secret | `secret/devices/node01` | The thing the device is actually trying to read |

Two constraints explain the layout:

- **macOS does not expose a TPM to Multipass guests.** `swtpm` provides one inside the
  VM. On real hardware the only change is pointing the TCTI at `device:/dev/tpmrm0`
  instead of `swtpm:port=2321` — nothing above that line changes.
- **Vault's dev TLS certificate is issued for `127.0.0.1` only.** Putting the client and
  the server side by side in the same VM keeps the server-side TLS trust trivial, so the
  demo stays focused on the *client* certificate.

## Enrolment and login flow

![Enrolment](diagrams/enrolment.png)

The trust chain, step by step:

1. **Key generation inside the TPM.** `openssl genpkey -provider tpm2` asks the TPM to
   create a P-256 key pair. The private half is generated in the TPM and stays there.

   What touches disk is not a private key. The output file begins
   `-----BEGIN TSS2 PRIVATE KEY-----`: the key object wrapped to this TPM's storage root
   key. `openssl pkey` can extract the *public* key from it and nothing else. Any TPM
   with a different storage seed will refuse to load it.
2. **The CSR is signed by the TPM.** `openssl req -new` produces a CSR whose signature
   was computed inside the TPM. That signature is the proof of possession, and it never
   required the key to leave.
3. **The orchestrator mints a wrapped SecretID.** Holding an `enrol-orchestrator`
   token — *not* the root token —
   `vault write -f -wrap-ttl=120s auth/approle/role/device-enrol/secret-id` returns a
   *response-wrapping* token rather than the SecretID itself. Minting is a privileged
   act: it needs `update` on `auth/approle/role/device-enrol/secret-id`, and that
   capability plus `read` on the RoleID path is the orchestrator's entire privilege. It
   cannot sign a CSR, read a secret, or inspect the role it mints for. This is the
   provisioning system's job, not the device's.

   Wrapping normally costs no extra permission — Vault authorises the call against the
   target path as usual and wraps the reply afterwards. The `enrol-orchestrator` policy
   sets `min_wrapping_ttl` on that path, which inverts it: an *unwrapped* mint is denied.
   Tamper-evidence is enforced rather than merely conventional.
4. **The wrapping token is delivered to the device.** This is the one step Vault cannot
   help with, and it is where the remaining trust sits. See
   [Bootstrapping the first certificate](#bootstrapping-the-first-certificate).
5. **The device unwraps it.** `vault unwrap -field=secret_id <wrapping-token>` yields
   the SecretID. The wrapping token unwraps exactly once; the SecretID itself is good
   for one use and ten minutes.
6. **The device logs in to AppRole.** It receives the public `role_id` alongside the
   wrapping token — the orchestrator read it in step 3, because at this moment the
   device holds no token of its own — then
   `vault write auth/approle/login role_id=… secret_id=…`. Back comes a `device-enrol`
   token: `token_ttl=5m`, `token_max_ttl=10m`, `token_num_uses=3`, and exactly one
   capability — `update` on `pki/sign/devices`.
7. **Vault signs the CSR.** `vault write pki/sign/devices`, authorised by that
   `device-enrol` token and nothing stronger, issues a client certificate for
   `CN=node01.devices.lab.local`, chained to the lab device CA, with the TLS Web Client
   Authentication extended key usage.
8. **mTLS login.** `openssl s_client` opens a TLS connection to Vault presenting that
   certificate, and the TPM computes the `CertificateVerify` signature that proves the
   client holds the matching private key. The login request to `auth/cert/login` rides
   over that connection.
9. **Vault validates.** The cert auth method checks that the presented chain terminates
   at the configured device CA, and that the common name matches
   `*.devices.lab.local`. Either check failing means no token.
10. **A scoped token comes back.** Policies `default` and `device-read`, a 15-minute TTL
    and a one-hour maximum.
11. **The device uses it.** It reads `secret/devices/node01` successfully; a write to the
    same path is denied.

Steps 3–6 happen **once per device, ever**. Every login after enrolment is step 8
onwards: the TPM key and the certificate are the credential, so no bootstrap secret needs
to remain on the device afterwards.

Note the split in step 8: Vault's own CLI and Vault Agent load client keys from PEM
files, so neither can use a key that exists only inside a TPM. That is why the lab drives
the handshake with `openssl s_client` and its `tpm2` provider. A production client would
instead load the key as a `crypto.Signer` and build a `tls.Certificate` in code.

## Trust model

| Party | What it actually trusts / guarantees |
|---|---|
| Vault cert auth | Only the **device CA certificate**. Any certificate chaining to it, with a matching common name, is a valid device |
| Vault PKI | Whoever holds a token permitted to write `pki/sign/devices`. That is now a `device-enrol` AppRole token with that one capability and nothing else — and the right to mint its SecretID is itself confined to the `enrol-orchestrator` policy, so "whoever can mint" is now a named, auditable identity rather than root |
| The TPM | That the private key cannot be extracted, and that every signature was produced by that specific TPM |
| The certificate | Binds a name to a public key. It says nothing about *where* the key lives — that fact is established only at enrolment time |

What the TPM does **not** give you:

- **It binds the key to the machine, not to a user or a process.** Anyone with
  sufficient privilege on the running device — root, or any account permitted to talk to
  `/dev/tpmrm0` — can ask the TPM to sign. The key cannot be stolen and used elsewhere;
  it can absolutely be *used* in place by a local attacker.
- **It does not prove the key was TPM-resident to Vault.** Vault sees an ordinary client
  certificate. The TPM residency is an assertion made by whatever enrolled the device.
  Closing that gap requires EK/AK attestation during enrolment, which this lab does not
  implement.
- **It does not gate on boot state by default.** A key can be bound to PCR values so it
  is only usable when the measured boot chain matches; that is a stretch goal here (see
  below), not part of the automated run.
- **It does not revoke anything.** Certificate lifetime, CRLs and token TTLs remain
  Vault's job.

The honest summary: a TPM converts a copyable secret into a machine-bound one. That
defeats credential exfiltration, which is the common case. It does not defeat an
attacker who already owns the running machine.

### Bootstrapping the first certificate

Everything above assumes the device already has a certificate. Getting the *first* one is
the hard part, because at that moment the device has no identity Vault recognises.

The lab used to solve this by handing the device the dev root token and letting it call
`pki/sign/devices` directly. It now uses a response-wrapped, one-shot AppRole SecretID
instead. That is a genuine improvement, and worth being precise about what it buys:

| Before | Now |
|---|---|
| Root token on the device | `device-enrol` token with one capability: `update` on `pki/sign/devices` |
| Unlimited uses, unlimited scope | SecretID good for one use and 10 minutes; the token for 5 minutes and 3 uses |
| Could read every secret, rewrite cert auth trust, issue for any PKI role | Can do none of those — only sign a CSR against the `devices` role |
| Compromise is total and silent | Compromise is bounded, and a replay of the wrapping token fails visibly |
| The *minting* side held the root token | The minting side holds an `enrol-orchestrator` token: `update` on one SecretID path, `read` on one RoleID path. Compromising the provisioning system yields device certificates, not the whole Vault |

The credential is needed exactly once per device lifetime. After enrolment every login
uses the TPM key and the certificate, so nothing standing is left behind on the device.

Three limits, stated plainly:

- **It shrinks the bootstrap secret; it does not remove it.** Something still has to
  deliver the wrapping token to the device. That is Vault's *secure introduction*
  problem, and it recurses: whatever channel carries the wrapping token needs its own
  trust, which needs its own bootstrap.
- **Response wrapping makes interception detectable, not impossible.** It does not keep
  the SecretID secret so much as guarantee that only one party ever reads it. The
  wrapping token unwraps exactly once, so if an attacker unwraps it first the legitimate
  device's unwrap fails — loudly, and at a moment somebody is watching. Detection, not
  prevention.
- **This is trust-by-delivery, not trust-by-hardware.** Vault signs the CSR because the
  caller held a valid SecretID, not because the key is demonstrably inside a TPM. The
  version that binds enrolment to the actual hardware is EK/AK attestation, where the
  TPM proves its own identity before Vault will issue. That is out of scope here:
  `swtpm` has no manufacturer endorsement key certificate to chain to, so there is
  nothing to verify against.

### Operator, orchestrator and device

The split is the teaching point, so it is worth naming which side holds what. There are
three privilege domains, not two:

| | Operator | Orchestrator / provisioning system | Device |
|---|---|---|---|
| Token held | Root | `enrol-orchestrator`, minted by the operator, 24h | Only the `device-enrol` token it obtained itself |
| Privilege | Configure trust: mounts, policies, auth methods, the CA | `update` on `auth/approle/role/device-enrol/secret-id`, `read` on `.../role-id` — can mint enrolment credentials for any device, and nothing else | `update` on `pki/sign/devices` — can sign a CSR against the `devices` role and nothing else |
| Sees the SecretID? | n/a — it is not involved in enrolment | No. It only ever handles the wrapping token | Yes, once, via `vault unwrap` |
| When | Once, at lab build (`task config`) | Once per device, at provisioning time (`task enrol`, 6.4.1) | Once per device, at first boot (`task enrol`, 6.4.2–6.4.4) |

Minting a SecretID is itself a privileged operation. Moving it off the device does not
make it free — it concentrates it somewhere that can be audited, rate-limited and kept
off the device. Giving that act its own scoped identity, rather than performing it with
root, is what stops "the provisioning system is compromised" from meaning "Vault is
compromised": an attacker holding the orchestrator token can obtain device certificates,
which is bad, but cannot read a secret, rewrite the cert auth trust anchor, or mint
itself anything stronger.

Be honest about the recursion, though: root created the orchestrator's token, so root
remains the ultimate authority in this lab. The claim is not that root vanished — it is
that root is not on the wire when a device enrols, and the privilege that *is* present
there is bounded, named and auditable.

Note what did **not** change: `task config` still runs as root. That is correct. It is
the operator establishing trust — creating the device CA, the issuing role, the policies,
the cert auth role, the AppRole, and the orchestrator's own credential. Issuing the
orchestrator its token belongs there for the same reason: handing out privilege is the
operator's job, exercising it is not. Configuring Vault is a root-shaped job. A device
authenticating to Vault is not, and neither is minting its bootstrap credential — those
are the two steps that moved.

## What each part proves

| Lab part | Task | What to conclude |
|---|---|---|
| 1–3 | `task provision`, `task tpm`, `task vault` | The environment is reproducible: TPM and Vault both come up as managed systemd units |
| 4–5 | `task config` | Trust is configured explicitly — a device CA, one issuing role, the `device-read`, `device-enrol` and `enrol-orchestrator` policies, the `device-enrol` AppRole, the orchestrator's token, one cert auth role. The one step that legitimately uses the root token |
| 6 | `task enrol` | The device identity is created inside the TPM and signed by Vault; no key material moved, and no root token anywhere in the step — the orchestrator mints with a scoped token, and the CSR is signed with a one-shot AppRole token |
| 6.2 | `task demo:nonexportable` | The file on disk is a TSS2 wrapped blob. Only a public key can be recovered from it |
| 7 | `task demo:login` | A TPM-held key authenticates to Vault over mTLS and returns a real token |
| 7.3 | `task demo:privilege` | The token is least-privilege: the read succeeds, the write is denied |
| 8.1 | `task demo:negative:stolen-key` | Copying the key blob is worthless — a different TPM cannot load it, so the handshake never completes |
| 8.2 | `task demo:negative:no-cert` | Cert auth genuinely requires a client certificate; there is no fallback path |
| 8.3 | `task demo:negative:untrusted-ca` | A TPM key alone proves nothing. The certificate must chain to the trusted device CA |
| 8.4 | `task demo:negative:wrong-cn` | Even a certificate from the trusted CA is rejected if the common name is outside `allowed_common_names` |
| 8.5 | `task demo:negative:revoked-token` | Hardware binding does not outlive revocation; a revoked token is dead immediately |

`task demo` runs all of the above in order.

> **On the rejection messages in 8.2–8.4.** Vault answers 8.2 with `client
> certificate must be supplied`, but returns the *same* message for both 8.3 and
> 8.4 — `failed to match all constraints for this login certificate`. It does not
> say which constraint failed, so the two cases are distinguished by what you
> changed, not by the error text. Worth saying out loud when presenting, because
> an audience will reasonably expect the errors to differ.

### Observations from building this

Four things behaved differently from the obvious expectation, all confirmed by
running the lab on Ubuntu 24.04 arm64 rather than by reading documentation:

| Expectation | Reality |
|---|---|
| The TPM package name is stable | It is release-specific. On 24.04 it is `libtss2-tcti-swtpm0t64` — the `t64` transition. `task provision` resolves it dynamically rather than hardcoding either spelling |
| `swtpm_setup` must manufacture state first | Not for this lab. `--flags not-need-init,startup-clear` is sufficient; `swtpm_setup` only adds EK and platform certificates, which nothing here uses |
| Load `-provider tpm2` first, since the TPM is the point | The opposite. Loading `tpm2` first sends ordinary hashing to the TPM and exhausts its object slots mid-handshake. Load `default` first — see the troubleshooting table |
| A permission error on the TPM state dir is a file-ownership problem | It is AppArmor. The directory can be owned correctly and still be denied |

## Lab layout inside the VM

All lab state lives inside the VM, owned by the `ubuntu` user, under `~/lab`:

| Path | Contents |
|---|---|
| `~/lab/env.sh` | The TCTI and Vault environment (`TPM2TOOLS_TCTI`, `TPM2OPENSSL_TCTI`, `VAULT_ADDR`, `VAULT_CACERT`, `VAULT_TOKEN`). Every scripted command sources this, so an interactive `task shell` session sees exactly the same environment |
| `~/lab/state/` | Lab state: `config.json` (the Parts 4-5 sentinel) and `orchestrator.token` (mode 0600 — the scoped credential `task enrol` spends to mint the device's SecretID) |
| `~/lab/tpmstate/` | Software TPM state, one directory per swtpm instance. The device TPM's storage seed lives here — this is what makes the key blob machine-bound |
| `~/lab/vault-tls/` | The dev server's own TLS material: `vault-ca.pem`, `vault-cert.pem`, `vault-key.pem` |
| `~/lab/pki/` | Device PKI artefacts: the lab device CA certificate, the TPM key blob, the CSR, the issued device certificate and its serial |

Two systemd units run the daemons:

| Unit | Role |
|---|---|
| `swtpm@device` | The device's software TPM on tcp :2321 |
| `swtpm@attacker` | A second, independently seeded TPM on tcp :2331, used only by the Part 8.1 test |
| `vault-dev` | `vault server -dev -dev-tls` on https://127.0.0.1:8200 |

Running them as units rather than the source guide's `nohup` plus PID files is a
deliberate departure: readiness becomes `systemctl is-active` instead of a blind `sleep`,
restarts are ordinary `systemctl restart`, and logs come from `journalctl` rather than
files nobody rotates. The attacker TPM also gets its own port rather than displacing the
device TPM, so the stolen-key test no longer requires stopping and restarting the real
one.

## Running it

| Task | What happens | What to expect |
|---|---|---|
| `task deps` | Checks host tooling | Required tools listed as ok; warnings for missing optional ones |
| `task init` | Installs pre-commit hooks, seeds `.env` from the template | One-time, host only |
| `task launch` | Creates the Multipass VM | No-op if `tpm-lab` already exists |
| `task provision` | Installs swtpm, tpm2-tools, tpm2-openssl and Vault in the VM | Slowest step; safe to re-run |
| `task tpm` | Installs and starts both swtpm units | Both units active; `tpm2_getrandom` returns bytes |
| `task vault` | Starts the Vault dev server unit | `vault status` shows `Sealed false`, `Storage Type inmem` |
| `task config` | Enables PKI, generates the device CA, creates the `devices` role, writes the KV secret, the `device-read`, `device-enrol` and `enrol-orchestrator` policies, the `device-enrol` AppRole and the orchestrator's scoped token, enables and configures cert auth | Re-runnable; this is the step to repeat after a Vault restart. Uses the root token, correctly — this is the operator provisioning trust |
| `task enrol` | Generates the TPM key, builds the CSR, mints a response-wrapped one-shot SecretID as the orchestrator, then redeems it as the device to sign the CSR | Certificate with the expected subject, issuer and client-auth EKU; no root token used at any point in the step |
| `task all` | All of the above in order | Ends with "Lab ready" |
| `task demo:nonexportable` | Shows the TSS2 header and the public-key-only extraction | The talking point that lands hardest |
| `task demo:login` | The mTLS login | A client token with policies `default` and `device-read` |
| `task demo:privilege` | Read then write with the device token | Read succeeds, write is denied |
| `task demo:negative` | All five negative tests in order | Each prints its expected and actual outcome for the operator to judge |
| `task demo` | The complete narrated run | Roughly a minute |
| `task shell` | Interactive shell in the VM | `source ~/lab/env.sh` to work by hand |
| `task logs`, `task logs:tpm`, `task logs:vault` | Journals for the lab units | |
| `task reset` | Clears lab state, keeps the VM | Rebuild with `task tpm vault config enrol` |
| `task clean` / `task rebuild` | Destroy the VM / destroy and rebuild | |
| `task lint` | pre-commit: shellcheck, gitleaks | Must pass before committing |
| `task docs:diagram` | Re-renders both PNGs from the `.dot` sources | Needs graphviz on the host |

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `tpm2_getrandom` hangs or errors | The device TPM is not running, or the TCTI variables are not set | `systemctl is-active swtpm@device`; `journalctl -u swtpm@device -n 50`; in an interactive shell, `source ~/lab/env.sh` |
| `swtpm@device` fails with `SWTPM_NVRAM_Lock_Dir: Could not open lockfile: Permission denied` | AppArmor, not file ownership. Ubuntu's `usr.bin.swtpm` profile allows state only under `owner @{HOME}/**` and `owner /var/lib/swtpm/**` | The lab keeps state in `~/lab/tpmstate`, which the profile already permits. If you move `STATE_ROOT` elsewhere, expect this. Confirm with `sudo dmesg \| grep -i apparmor` |
| OpenSSL cannot load the `tpm2` provider | `tpm2-openssl` missing | Re-run `task provision` |
| OpenSSL reports the TCTI cannot be found | The `libtss2-tcti-swtpm` package is missing; its name carries a release-specific suffix on 24.04 | Re-run `task provision`, which resolves the package name dynamically |
| The login produces no token and no obvious error | The TLS handshake failed before the request was sent | Re-run the `openssl s_client` invocation by hand without `-quiet` and without discarding stderr, so the handshake error is visible |
| OpenSSL cannot read the private key | The `default` provider or the TCTI variable is missing — the `tpm2` provider alone is not enough | Pass both providers, and `source ~/lab/env.sh` |
| Handshake dies with `tpm2::cannot hash ... out of memory for object contexts`, then `tls_process_cert_verify:bad signature` | **Provider order.** With `-provider tpm2` first, OpenSSL routes ordinary SHA-256 hashing to the TPM and swtpm exhausts its transient object slots mid-handshake. The message looks like a certificate fault but is resource exhaustion | Load `default` first: `-provider default -provider tpm2`. The TPM still signs, because only it can decode a TSS2 blob |
| Vault CLI complains the certificate is signed by an unknown authority | `VAULT_CACERT` points somewhere else | It must be `~/lab/vault-tls/vault-ca.pem` |
| Every Vault path 404s or permission-denies at once | The Vault dev server restarted and its in-memory state is gone | `task config && task enrol` |
| `vault-dev` will not start | Port 8200 already held, or the TLS directory is unwritable | `journalctl -u vault-dev -n 50` |
| The stolen-key test appears to *succeed* | The client is still pointed at the device TPM | Check which TCTI port the test used; both `swtpm@device` and `swtpm@attacker` should be active, on 2321 and 2331 |
| Multipass commands hang on the host | The VM is stopped or suspended | `multipass info tpm-lab`; `task start` |

Because Vault dev mode is entirely in-memory, "all the configuration vanished" is the
single most common failure, and `task config && task enrol` is always the answer. Nothing
needs rebuilding from scratch for that.

## From lab to production

| Lab | Production |
|---|---|
| `swtpm` over `swtpm:port=2321` | Hardware or firmware TPM via `device:/dev/tpmrm0` — the only change below the application layer |
| `vault server -dev -dev-tls` | HA cluster with Raft storage, a real server certificate, and auto-unseal |
| Root CA generated inside the PKI mount | Intermediate PKI mount chained to the enterprise root, with the root kept offline |
| Root token for operator work — `task config` only. Minting enrolment SecretIDs uses the scoped `enrol-orchestrator` token, and the device never holds either | Scoped admin policies throughout; the root token generated only for break-glass and revoked afterwards |
| The orchestrator's token written to a file on the same box, minted fresh on every `task config` | The provisioning system authenticates as its own workload identity, with short-lived credentials it renews rather than a token at rest |
| `openssl s_client` driving the handshake | A client that loads the TPM key as a `crypto.Signer`, builds a `tls.Certificate`, and calls `auth/cert/login` through a Vault SDK |
| Enrolment authorised by a response-wrapped, single-use AppRole SecretID, still trusting that the key is in a TPM | Automated enrolment gated by EK/AK attestation, so Vault has cryptographic evidence of TPM residency before it signs, rather than trusting whoever received the wrapping token |
| 24-hour certificates, CRL loaded manually | Short-lived certificates with automatic renewal, plus OCSP or scheduled CRL refresh |
| One `tpm-devices` cert auth role for everything, and one shared `device-enrol` AppRole | Per-fleet or per-role trust entries, each with its own policies and common-name constraints; per-device or per-batch enrolment roles with CIDR binding |
| The wrapping token handed to the device in-process, inside one VM | A real secure-introduction channel — an image-baked token, a cloud instance identity document, or a hardware root of trust — with the delivery step audited |
| A single KV secret | Per-device paths templated on the certificate's identity alias, so devices cannot read each other's secrets |
| No boot-state gating | Keys sealed to PCR policy, so a tampered boot chain loses access |
| Audit device optional | Audit devices mandatory, shipped off-host, with per-device entity aliases for attribution |

## Stretch goals not automated

The source guide's Part 9 describes four extensions that are documented but deliberately
not scripted, because each one needs judgement or code rather than another idempotent
step:

- **Certificate revocation with a CRL.** Revoke the device certificate through
  `pki/revoke`, fetch the PEM CRL from the PKI mount, and load it into cert auth as a
  named CRL. The next login is refused. Recovery means either deleting that CRL entry or
  re-enrolling with a fresh CSR. Worth demonstrating live, but it leaves the lab in a
  state that needs a manual decision to undo.
- **Identity and audit inspection.** Enable a file audit device, log in, and follow the
  token to its entity. Each device certificate produces its own entity alias, which is
  what gives per-device attribution in the audit log — the practical payoff of cert auth
  over a shared credential.
- **PCR binding.** Create the key under a PCR policy (`tpm2_createpolicy --policy-pcr`,
  `tpm2_create -L`, `tpm2_encodeobject`) so the TPM will only use it when the selected
  PCRs match, then extend one of those PCRs and watch the login fail. This is the step
  that turns "this machine" into "this machine, booted the way we expect". It needs the
  parent key template to match what the tpm2 OpenSSL provider expects, which is
  version-sensitive enough to be left manual.
- **A production-style client.** Replace `openssl s_client` with a small Go program that
  loads the TPM key as a `crypto.Signer` (for example via `go-tpm` or
  `go-tpm-keyfiles`), assembles a `tls.Certificate`, and calls `auth/cert/login` through
  the Vault Go SDK. This is what you would actually ship to devices, and it removes the
  lab's one piece of scaffolding.
