# Architecture

## Overview

Most machine-to-machine authentication rests on something copyable. A Vault token in a
file, an AppRole secret ID, a PEM private key next to its certificate — each is just
bytes. Anyone who can read the file can become the machine, anywhere, for as long as the
credential lives. Rotation shortens the window; it does not close it.

A TPM changes the shape of the problem. A key created inside the TPM never exists
outside it in usable form. What lands on disk is a handle: the key's public area plus a
private area encrypted to that TPM's storage key, an object the TPM can load and use and
that no other TPM can. The credential stops being data you hold and becomes a capability
the hardware grants.

**This lab requires Vault Enterprise.** It uses the `tpm` auth method, which is an
Enterprise feature. Vault Enterprise 2.2.0 is installed inside the VM from HashiCorp's
apt repository, and the licence text is pushed in from `VAULT_LICENSE` in the gitignored
`.env`. No licence is ever committed.

The lab demonstrates the whole chain end to end:

- a device identified by its TPM's **endorsement key** (EK), registered with Vault by a
  provisioning orchestrator that holds a narrowly scoped token;
- the device proving, with **no Vault token at all**, that it holds that EK — a
  two-phase EK/AK attestation — and receiving a client certificate from the auth
  method's own internal CA;
- an application key generated inside the TPM, certified by the attestation key, and
  used to sign the mTLS login handshake;
- the tpm auth method validating the certificate and issuing a short-lived,
  least-privilege token;
- negative tests proving that stolen key blobs, an unregistered TPM, a certificate from a
  different CA, a certificate bound to a different TPM and role, and a revoked token all
  fail;
- Vault Agent doing the device's work unattended, then standing in front of workloads as
  an API proxy — one on localhost HTTP, and one per application behind an owner-only
  Unix socket.

![TPM authentication with Vault](diagrams/tpm-auth-overview.png)

The TPM is a software TPM (`swtpm`) rather than silicon, because macOS does not expose a
TPM to Multipass guests. Everything above the device path is identical to real hardware.

## Topology

![Topology](diagrams/topology.png)

| Component | What it is | Why it lives where it does |
|---|---|---|
| Terminal / `Taskfile.yml` | The only thing on the macOS host, plus `.env` holding the licence text | The host holds source, never lab state |
| Multipass CLI | Creates the VM; `multipass transfer` + `exec` push scripts (and, once, the licence) in | The lab needs Linux, systemd and a TPM stack |
| `swtpm@device` | Software TPM 2.0, systemd unit, serving `~/lab/tpmstate/device/swtpm.sock` | macOS exposes no TPM to guests, so the VM provides its own |
| `swtpm@attacker` | A second software TPM with a **different storage seed**, and therefore a different EK | Stands in for "a different machine" during the Part 8 tests. Used by those tests only |
| Device client | The Vault CLI: `vault tpm ek`, `vault tpm attest`, `vault login -method=tpm` | Reads the EK, runs the attestation, drives the mTLS login — all against the TPM socket |
| `vault-dev` (https://127.0.0.1:8200) | `vault server -dev -dev-tls`, Vault Enterprise, systemd unit | Dev mode keeps the lab to one command; TLS is required for a client-certificate login |
| `identity/tpm` | Vault's registry of endorsement keys, and the `devices` TPM group | Which silicon the operator has decided to trust |
| tpm auth method | Mount `auth/tpm`: an internal CA, and the role `devices` bound to the group | Verifies the attestation, issues the certificate, validates it at login, issues the token |
| KV v2 secret | `secret/devices/node01` | The thing the device is actually trying to read |

Two constraints explain the layout:

- **macOS does not expose a TPM to Multipass guests.** `swtpm` provides one inside the
  VM, on a unix socket. On real hardware the only change is pointing at
  `/dev/tpmrm0` instead of `~/lab/tpmstate/device/swtpm.sock` — nothing above that line
  changes.
- **Vault's dev TLS certificate is issued for `127.0.0.1` only.** Putting the client and
  the server side by side in the same VM keeps the server-side TLS trust trivial, so the
  demo stays focused on the *client* certificate.

## Enrolment and login flow

![Enrolment](diagrams/enrolment.png)

The same flow as a sequence. `Operator` holds the root token, `Orchestrator` a scoped
`enrol-orchestrator` token, and `Device` no token at all — the arrows show where each
one is on the wire. Parts 4–5 run once at lab build, 6.1–6.3 once per device, and
Part 7 on every login thereafter.

```mermaid
sequenceDiagram
    actor Op as Operator
    participant Orch as Orchestrator
    participant Dev as Device
    participant TPM as TPM
    participant V as Vault

    Note over Dev: holds no Vault token, ever

    Note over Op,V: Parts 4-5 — task config, once, as root
    Op->>V: auth enable tpm, write auth/tpm/config
    V->>V: create the mount's internal CA
    Op->>V: create the devices TPM group and the role bound to it
    Op->>V: write the device-read and enrol-orchestrator policies
    V-->>Op: enrol-orchestrator token, 24h, two paths
    Op->>Orch: hand over the scoped token

    Note over Dev,TPM: Part 6.1 — read the endorsement key
    Dev->>TPM: vault tpm ek
    TPM-->>Dev: EK public key, its private half never leaves the chip
    Dev->>Orch: EK public key — public, so nothing secret is delivered

    Note over Orch,V: Part 6.2 — registration, scoped token, not root
    Orch->>V: write identity/tpm name=node01 tpm_ek_public_key=@ek.pub
    V-->>Orch: tpm_id = sha256 of the EK public key DER
    Orch->>V: read identity/tpmgroup/name/devices
    V-->>Orch: the existing member_tpm_ids
    Orch->>V: write member_tpm_ids = existing + tpm_id

    Note over Dev,V: Part 6.3 — attestation, unauthenticated
    Dev->>TPM: create a fresh attestation key
    TPM-->>Dev: AK public area and parameters
    Dev->>V: gentpmcert/begin with the EK public key and the AK parameters
    V->>V: is the EK registered, and does the role trust it via the group?
    V-->>Dev: challenge — a secret encrypted to the EK, bound to the AK name
    Dev->>TPM: TPM2_ActivateCredential on the challenge
    TPM-->>Dev: the decrypted secret, only because the AK and EK share this TPM
    Dev->>TPM: create the application key, have the AK certify it
    TPM-->>Dev: application key public area, CSR and certification
    Dev->>V: gentpmcert/finish with the secret, the CSR and the certification
    V-->>Dev: client.crt from the internal CA, SAN carries the tpm_id and the role
    Note right of Dev: app.blob and ak.blob on disk are sealed handles, not keys

    Note over Dev,V: Part 7 — mTLS login, every time, still no token
    Dev->>TPM: flush transient handles
    Dev->>V: TLS handshake to auth/tpm/login, presenting client.crt
    Dev->>TPM: sign the handshake transcript with the application key
    TPM-->>Dev: the signature — the key itself never leaves
    Dev->>V: the signed handshake completes the connection
    V->>V: signed by this mount's CA, and is the SAN tpm_id trusted by the role?
    V-->>Dev: client token — default and device-read, 15m TTL, 1h max
    Dev->>V: kv get secret/devices/node01
    V-->>Dev: the secret
    Dev->>V: kv put secret/devices/node01
    V-->>Dev: permission denied
```

The mermaid block above is its own source — unlike `diagrams/*.dot`, it needs no
`task docs:diagram` step, and GitHub renders it in place.

The trust chain, step by step:

1. **The endorsement key.** `vault tpm ek` reads the EK public key from the TPM and
   prints it with its TPM ID. The EK is derived from a seed burned into the TPM at
   manufacture; its private half never leaves the chip. The TPM ID is nothing more than
   the SHA-256 of the EK public key's DER encoding — `task enrol` recomputes it locally
   with `openssl` to show there is no hidden registry value.
2. **The orchestrator registers the device.** Holding an `enrol-orchestrator` token —
   *not* the root token — it writes the EK to `identity/tpm` as `node01`, then adds the
   resulting TPM ID to the `devices` TPM group. That is its entire privilege: `update` on
   `identity/tpm` and `read`/`update` on `identity/tpmgroup/name/devices`. It cannot
   read the auth role, let alone change it, and it cannot read a secret.

   The group is the indirection that keeps this least-privilege. The auth role trusts
   the group, so admitting a device means editing group membership, which the
   orchestrator may do, rather than editing the role, which it may not — a role write
   could also change `token_policies`, and that is an escalation path, not an enrolment.
3. **The device begins attestation — with no token.** `vault tpm attest` creates a fresh
   attestation key (AK) in the TPM and calls `auth/tpm/role/devices/gentpmcert/begin`
   with the EK public key and the AK's parameters. Vault looks the EK up in
   `identity/tpm`, checks that the role trusts it (directly or through a group), and
   returns a challenge: a secret encrypted so that only that EK can decrypt it, bound to
   the AK's name.
4. **The TPM answers the challenge.** `TPM2_ActivateCredential` decrypts the secret. The
   TPM will only do so if the AK really lives in the same TPM as the EK — which is what
   binds the freshly created AK to the manufactured identity.
5. **The device finishes attestation.** It generates the application key in the TPM, has
   the AK certify that the key was created there with the attributes it claims, builds a
   CSR for it, and calls `gentpmcert/finish` with the decrypted secret, the CSR and the
   certification.
6. **Vault's internal CA issues the certificate.** The mount's own CA — created when the
   method was enabled and rotated automatically — signs a client certificate whose
   Subject Alternative Name carries two OtherNames: the TPM ID and the role name. Those
   two are the identity. The common name, `node01.devices.lab.local`, is whatever the
   device passed as `-cert-subject-CN`; Vault records it but never checks it. The certificate, the CA chain and the two key handles
   (`app.blob`, `ak.blob`) land in the device's state directory.
7. **mTLS login.** `vault login -method=tpm` opens a TLS connection presenting that
   certificate and asks the TPM to compute the handshake signature with the application
   key. The request goes to `auth/tpm/login`.
8. **Vault validates.** The certificate must be signed by *this mount's* internal CA, and
   the TPM ID in its SAN must be one the requested role trusts. Either check failing
   means no token.
9. **A scoped token comes back.** Policies `default` and `device-read`, a 15-minute TTL,
   a one-hour maximum, and metadata naming the TPM ID, the role and the common name.
10. **The device uses it.** It reads `secret/devices/node01` successfully; a write to the
    same path is denied.

Steps 1–6 happen **once per device, ever** — or once per certificate lifetime, since
`task enrol` re-attests only when the certificate is within an hour of expiry. Every
login after enrolment is step 7 onwards: the TPM key and the certificate are the
credential, and there is no bootstrap secret on the device to leave behind, because there
never was one.

## Trust model

| Party | What it actually trusts / guarantees |
|---|---|
| Vault tpm auth | Its **own internal CA**, and the **TPM group** bound to the role. A certificate it issued, for a TPM ID the role trusts, is a valid device |
| `identity/tpm` | Whoever holds a token permitted to write it — the `enrol-orchestrator` policy, so "whoever can register a device" is a named, auditable identity rather than root |
| The attestation | That the AK and the application key were created inside the TPM that holds the registered EK. This is cryptographic evidence of TPM residency, not an assertion by whoever provisioned the device |
| The TPM | That the private keys cannot be extracted (`fixedtpm`, `fixedparent`), and that every signature was produced by that specific TPM |
| The certificate | Binds a TPM ID and a role to a public key. Because it was issued only after attestation, it *does* say where the key lives. The common name is **self-asserted** by the device and enforced by nothing — do not template policy on it; use the TPM ID |

What the TPM does **not** give you:

- **It binds the key to the machine, not to a user or a process.** Anyone with
  sufficient privilege on the running device — root, or any account permitted to talk to
  `/dev/tpmrm0` — can ask the TPM to sign. The key cannot be stolen and used elsewhere;
  it can absolutely be *used* in place by a local attacker.
- **It does not gate on boot state by default.** A key can be bound to PCR values so it
  is only usable when the measured boot chain matches; the Vault CLI's key template does
  not do that, and this lab does not either.
- **It does not revoke anything.** Certificate lifetime, disabling a TPM record and token
  TTLs remain Vault's job — and see the observations below on what `disabled` does.

The honest summary: a TPM converts a copyable secret into a machine-bound one, and
attestation lets Vault verify that conversion happened rather than take it on trust.
That defeats credential exfiltration, which is the common case. It does not defeat an
attacker who already owns the running machine.

### Bootstrapping the first certificate

Everything above assumes the device already has a certificate. Getting the *first* one is
usually the hard part, because at that moment the device has no identity Vault
recognises — and the traditional answers (a wrapped AppRole SecretID, a token baked into
an image) all amount to delivering a secret to the device somehow.

The tpm auth method dissolves the problem rather than solving it. The device *does* have
an identity Vault can recognise before it holds any credential: its endorsement key. The
attestation endpoints are unauthenticated by design — confirmed empirically: a call with
no token, or with a bogus token, gets a `400` for a malformed request rather than a
`403` — because possession of a registered EK is the credential. Nothing is delivered to
the device. What travels is the EK *public* key, from the device to the orchestrator,
and it is public.

| A delivered-secret bootstrap | The tpm auth method |
|---|---|
| A response-wrapped, one-shot AppRole SecretID delivered to the device | Nothing delivered. The device proves possession of an EK Vault already knows |
| A short-lived enrolment token on the device, permitted to have a CSR signed | No token on the device, ever. `VAULT_TOKEN` is set to a placeholder during enrolment so the transcript proves it |
| Trust-by-delivery: Vault signs the CSR because the caller holds a valid SecretID | Trust-by-hardware: Vault issues because the TPM answered a challenge only the registered EK could decrypt |
| Secure introduction is the acknowledged weak link | Secure introduction is replaced by EK registration, which happens out of band and needs no secrecy |
| Whoever delivers SecretIDs can mint enrolment credentials for any device | The orchestrator can register EKs and admit them to one group, and nothing else |

The residual trust is in the registry: whoever can write `identity/tpm` and the group
decides which silicon counts. That is the orchestrator, and its policy is two paths.
Compromising it yields the ability to enrol attacker-controlled TPMs, which is bad, but
not the ability to read a secret, change what the role grants, or mint a token.

### Operator, orchestrator and device

The split is the teaching point, so it is worth naming which side holds what. There are
three privilege domains:

| | Operator | Orchestrator / provisioning system | Device |
|---|---|---|---|
| Token held | Root | `enrol-orchestrator`, minted by the operator, 24h | **None** |
| Privilege | Configure trust: the mount, its CA, the group, the role, the policies | `update` on `identity/tpm`, `read`+`update` on `identity/tpmgroup/name/devices` — can register a TPM and admit it, and nothing else | Attest (unauthenticated) and log in (unauthenticated). Everything it can do, it can do because of what its TPM holds |
| When | Once, at lab build (`task config`) | Once per device, at provisioning time (`task enrol`, 6.2) | Once per device for attestation (`task enrol`, 6.3); every login thereafter |

Be honest about the recursion: root created the orchestrator's token, so root remains
the ultimate authority in this lab. The claim is not that root vanished — it is that
root is not on the wire when a device enrols, that the privilege that *is* present there
is bounded and named, and that the device side carries no privilege at all.

`task config` still runs as root. That is correct. It is the operator establishing trust
— enabling the auth method, configuring its CA, creating the group, the role, the
policies, and the orchestrator's own credential. Handing out privilege is the operator's
job; exercising it is not.

## What each part proves

| Lab part | Task | What to conclude |
|---|---|---|
| 1–3 | `task provision`, `task tpm`, `task vault` | The environment is reproducible: Vault Enterprise is installed from apt at a pinned version, and the TPMs and Vault come up as managed systemd units |
| 4–5 | `task config` | Trust is configured explicitly — the tpm auth mount and its CA, the `devices` group and role, the `device-read` and `enrol-orchestrator` policies, and the orchestrator's token. The one step that legitimately uses the root token |
| 6 | `task enrol` | The device's identity is its EK. The orchestrator registers it with a scoped token; the device attests with no token at all, and the certificate it receives names its TPM |
| 6.4 | `task demo:nonexportable` | The files on disk are TPM handles: `KeyBlob` is ciphertext, `openssl` cannot load them, the public area carries `fixedtpm` and `fixedparent`, and the public key matches the certificate |
| 7 | `task demo:login` | A TPM-held key authenticates to Vault over mTLS and returns a real token, whose metadata names the TPM |
| 7.3 | `task demo:privilege` | The token is least-privilege: the read succeeds, the write is denied |
| 8.1 | `task demo:negative:stolen-key` | Copying the state directory is worthless — a different TPM fails the blob's integrity check, so the handshake never starts |
| 8.2 | `task demo:negative:unenrolled-tpm` | An EK Vault has not registered is refused at `gentpmcert/begin`: attestation is open to anyone, and useful only to registered silicon |
| 8.3 | `task demo:negative:untrusted-ca` | A genuinely attested certificate from a *different* tpm auth mount is rejected; each mount trusts only its own CA. The stand-in mount is disabled again on the way out |
| 8.4 | `task demo:negative:wrong-role` | A genuine certificate from the trusted CA, for a TPM the `devices` role does not trust, is rejected; the same certificate is accepted by its own role. `node99` and role `other` are removed again on the way out |
| 8.5 | `task demo:negative:revoked-token` | Hardware binding does not outlive revocation; a revoked token is dead immediately |
| 9 | `task demo:agent` | A daemon does the device's half of enrolment and all of login unattended, and still cannot register its own EK |

`task demo` runs all of the above in order.

### The commands

Every Vault command below is printed by the scripts as they run, from the same argv
they execute — there is no separate copy to drift. Bearer tokens are redacted on the
way to the screen; the device's deliberate `VAULT_TOKEN=device-holds-no-token`
placeholder is not, because showing it is the point.

**Parts 4–5, as the operator** (`task config`, the one step that uses the root token):

```bash
vault auth enable -path=tpm tpm
vault write auth/tpm/config default_cert_ttl=24h

vault kv put secret/devices/node01 message='hello from vault, attested by TPM key'

vault policy write device-read - <<'EOF'
path "secret/data/devices/*" {
  capabilities = ["read"]
}
EOF

vault write identity/tpmgroup name=devices metadata=domain=devices.lab.local
group_id="$(vault read -field=id identity/tpmgroup/name/devices)"

# The role trusts the group, never individual TPM IDs — see Trust model above.
vault write auth/tpm/role/devices \
  tpmgroup_ids="${group_id}" \
  display_name=tpm-devices \
  token_policies=device-read \
  token_ttl=15m \
  token_max_ttl=1h

vault policy write enrol-orchestrator - <<'EOF'
path "identity/tpm" {
  capabilities = ["update"]
}
path "identity/tpmgroup/name/devices" {
  capabilities = ["read", "update"]
}
EOF

vault token create -policy=enrol-orchestrator -no-default-policy -ttl=24h \
  -display-name=enrol-orchestrator
```

**Part 6, as the device — no token** (`task enrol`, steps 1 and 3):

```bash
vault tpm ek -tpm-device-path="${TPM_SOCK}" -format=json

vault tpm attest \
  -role-name=devices \
  -mount-path=auth/tpm \
  -tpm-device-path="${TPM_SOCK}" \
  -tpm-state-dir=~/lab/tpm/node01 \
  -cert-subject-CN=node01.devices.lab.local
```

**Part 6.2, as the orchestrator — scoped token, not root:**

```bash
vault write identity/tpm name=node01 tpm_ek_public_key=@ek.pub \
  metadata=domain=devices.lab.local

# A group write replaces the member list, so it is read-modify-write.
vault read -format=json identity/tpmgroup/name/devices
vault write identity/tpmgroup/name/devices member_tpm_ids="${existing},${tpm_id}"
```

**Part 7, as the device — no token:**

```bash
vault login -method=tpm -no-store -format=json \
  -tpm-state-dir=~/lab/tpm/node01 \
  -tpm-device-path="${TPM_SOCK}" \
  role_name=devices
```

`-no-store` keeps the device token out of `~/.vault-token`, where it would otherwise
replace the dev root token the lab shell relies on.

> **On the rejection messages.** 8.2 is specific: `no TPM found for EK public key`.
> 8.3 and 8.4 both return `authentication failed` from `auth/tpm/login` — Vault does not
> say whether the chain or the role binding failed, so the two cases are distinguished
> by what you changed, not by the error text. 8.1 never reaches Vault at all: the message
> is the TPM's, `Load() failed: … integrity check failed`. Worth saying out loud when
> presenting.

### Observations from building this

Everything below was established by running Vault Enterprise 2.2.0 on Ubuntu 24.04
arm64, not by reading documentation. Several of these shaped the scripts.

| Expectation | Reality |
|---|---|
| Attestation needs a Vault token, so a bootstrap credential is still required | **It does not.** `gentpmcert/begin` and `finish` are unauthenticated: no token or a bogus token both get a `400` for a malformed body, never a `403`. A `403 permission denied` from `begin` means something else: an EK that is registered but not trusted by the role. The device side of enrolment therefore holds no credential at all |
| The Vault CLI needs a real `/dev/tpm*` device | It accepts a unix socket in `-tpm-device-path`, and swtpm can serve one (`--server type=unixio`). tpm2-tools reach the same socket via `TPM2TOOLS_TCTI=swtpm:path=…`, which also needs the `.ctrl` socket beside it. One socket per TPM serves everything, with no TCP ports. The `device:` TCTI cannot open a socket, so the swtpm TCTI is the one to use |
| A raw socket behaves like `/dev/tpmrm0` | Not quite. `/dev/tpmrm0` is a kernel resource manager that frees transient objects when a client disconnects; over a raw socket nothing does. Vault 2.2.0 frees its own handles — four `vault login -method=tpm` calls in a row leave all three swtpm transient slots free, and `vault tpm attest` cleans up too — but a client killed mid-call can still leave a key loaded, and the fourth load then fails with `out of memory for object contexts`. The scripts run `tpm2_flushcontext -t` before every TPM-touching Vault call (`flush_tpm_contexts` in `common.sh`) as insurance; on real hardware the resource manager makes this unnecessary |
| Re-attesting is harmless | Vault rate-limits attestation per EK — documented as one request every ten seconds — so a second `begin` too soon returns `400 failed to store challenge state: rate limit exceeded for this EK`. `task enrol` therefore keeps a certificate that is still good for an hour, and every script that attests retries after a 12-second wait |
| `vault login` is side-effect free | Without `-no-store` it writes the new token to `~/.vault-token`, replacing the dev root token the lab shell relies on. Every login in the lab passes `-no-store` |
| Disabling a TPM record cuts the device off | It does. `disabled=true` on `identity/tpm/name/node01` refuses a fresh attestation (`403 permission denied`) and a login (`authentication failed`); `disabled=false` restores both. It is the reversible lever beside removing the TPM from the group, deleting the record, and revoking tokens |
| Enabling a second mount is enough to attest against it | The mount refuses attestation until `auth/<mount>/config` has been written at least once (`TPM auth backend not configured: write to auth/<mount>/config first`), even though every field has a default. 8.3 writes the config explicitly |
| The key blobs are TSS2 PEM files | They are JSON handles (go-attestation's serialisation): `Public`, `KeyBlob`, `Name`, and the AK's `CreateAttestation`/`CreateSignature`. `Public` is a bare `TPMT_PUBLIC`, so `tpm2_print -t TPM2B_PUBLIC` needs a two-byte length prefix first; with it, the application key shows `fixedtpm|fixedparent|sensitivedataorigin|userwithauth|sign`. `KeyBlob` is 126 bytes of ciphertext. `client-key.json`'s `public_key_sha256` equals the SHA-256 of the certificate's SubjectPublicKeyInfo |
| Group membership is additive | A write to `identity/tpmgroup/name/<group>` with `member_tpm_ids` **replaces** the list. The orchestrator does a read-modify-write |
| The certificate's common name is a checked identity | It is not. `vault tpm attest -cert-subject-CN=…` puts whatever the device says into the subject, and `auth/tpm/login` checks only the CA and the TPM ID against the role. A second TPM in the `devices` group could attest as `node01.devices.lab.local`. The TPM ID is the identity and the CN is a label |
| A cached certificate survives `task config` | `task config` re-enables the mount after a Vault restart, which creates a new internal CA, so a certificate on disk from the old CA looks valid and fails at login. `30_vault_config.sh` deletes `client.crt`/`ca_chain.pem` under `~/lab/tpm/*/` whenever it enables a fresh mount, so `task config && task enrol` re-attests |
| The TPM ID is an opaque registry key | It is `sha256-` plus the SHA-256 of the EK public key's DER. `task enrol` recomputes it with `openssl` and they match |
| Any Vault edition will do | It will not. `vault auth enable tpm` is Enterprise only, and `task config` refuses to run against a binary whose version string lacks `+ent` |
| The TPM package name is stable | It is release-specific. On 24.04 it is `libtss2-tcti-swtpm0t64` — the `t64` transition. `task provision` resolves it dynamically |
| A permission error on the TPM state dir is a file-ownership problem | It is AppArmor. The directory can be owned correctly and still be denied; keeping state under `~/lab` satisfies the shipped profile |

One thing was *not* tested: whether the Enterprise dev server starts without a licence.
The licence was always present (`EnvironmentFile=/etc/vault-dev.env` in the unit; `sys/license/status`
reports it autoloaded), so the lab treats it as required.

## Vault Agent (Part 9)

Parts 6 and 7 are an operator typing commands. Part 9 hands both to a daemon and
changes nothing about the trust model.

![Vault Agent](diagrams/agent.png)

The configuration has two halves, and the split is the whole of it — one block gets
and keeps the certificate, the other uses it:

```hcl
# Attests on first run, persists the blobs, and schedules its own renewal
# inside the certificate's lifetime.
tpm_cert "node01" {
  role_name  = "devices"
  mount_path = "auth/tpm"

  tpm         { device_path = "/home/ubuntu/lab/tpmstate/device/swtpm.sock" }
  destination { path        = "/home/ubuntu/lab/tpm/agent" }
  renew       { min_validity_percentage = 50 }
}

# Uses that certificate to log in, and writes the token to a sink.
auto_auth {
  method {
    type       = "tpm"
    mount_path = "auth/tpm"
    config     = { tpm_cert = "node01" }
  }
  sink {
    type   = "file"
    config = { path = "/home/ubuntu/lab/agent/token" }
  }
}

template {
  source      = "/home/ubuntu/lab/agent/message.tpl"
  destination = "/home/ubuntu/lab/agent/message.txt"
  perms       = "0640"
}
```

The same thing as a sequence. `Operator` is `80_agent.sh`, holding the root token for
the gate and for nothing else; the two agent participants are the two halves of the
configuration above; and the agent holds no Vault token until it has earned one.

```mermaid
sequenceDiagram
    actor Op as Operator
    participant Sys as systemd
    participant Cert as tpm_cert — tpmattest manager
    participant Auth as auto_auth — auth handler
    participant TPM as TPM
    participant V as Vault

    Note over Cert,Auth: vault-agent.service, installed disabled

    Note over Op,V: the gate — the agent is not started until this passes
    Op->>V: read identity/tpm/name/node01
    V-->>Op: the endorsement key is registered
    Op->>V: read identity/tpmgroup/name/devices
    V-->>Op: member_tpm_ids includes this TPM
    Op->>TPM: flush transient handles
    Op->>Sys: systemctl start vault-agent
    Note right of Sys: never enable — dev-mode Vault forgets the mount on restart

    Note over Cert,V: the certificate half — once, then on the renewal timer
    Cert->>Cert: load persisted material from ~/lab/tpm/agent
    Note right of Cert: absent on a fresh lab, so acquire it
    Cert->>TPM: create a fresh AK and application key
    TPM-->>Cert: public areas and the AK's certification of the key
    Cert->>V: gentpmcert/begin + finish, with no Vault token
    V-->>Cert: client.crt from the mount's internal CA
    Cert->>Cert: persist client.crt, ca_chain.pem, app.blob, ak.blob
    Cert->>Cert: schedule renewal inside the certificate's lifetime

    Note over Auth,V: the login half — and again whenever the token needs replacing
    Cert-->>Auth: the certificate it keeps
    Auth->>V: TLS handshake to auth/tpm/login, presenting client.crt
    Auth->>TPM: sign the handshake transcript with the application key
    TPM-->>Auth: the signature — the key itself never leaves
    V-->>Auth: client token — default and device-read, tpm_id naming this TPM
    Auth->>Auth: write the token to ~/lab/agent/token
    Auth->>V: read secret/data/devices/node01
    V-->>Auth: the secret
    Auth->>Auth: render it to ~/lab/agent/message.txt

    Note over Op,Sys: on the way out, from a trap armed before the start
    Op->>Sys: systemctl stop vault-agent
    Note right of Op: it holds the device TPM, and swtpm has three transient slots
```

`task demo:agent` writes that configuration, starts the unit, watches it work and stops
it again. What comes out is a token indistinguishable from Part 7's — `display_name
tpm-tpm-devices`, the `device-read` policy, and `tpm_id` metadata naming the same
endorsement key `task enrol` recorded — together with a file on disk holding the KV
secret, put there by nobody.

**What it does, and what it cannot.** The agent performs the device's half of Part 6 and
all of Part 7: it attests, receives a certificate, logs in over mTLS with a key that
cannot leave the TPM, renews the token, and re-attests before the certificate expires.
What it cannot do is register its own endorsement key. Admitting a TPM to the group the
role trusts still needs the orchestrator's scoped token, out of band and once per
device. Automation replaces the device, never the party that decides what to trust.

**The unit is installed disabled** — the only unit in the lab that is. Vault dev mode is
in memory, so a reboot brings back a Vault with no tpm auth mount, no CA and no
`identity/tpm` registry. An enabled agent would start ahead of `task config && task
enrol`, fail, and retry on a backoff indefinitely. `swtpm@*` and `vault-dev` are enabled
because they hold state; the agent consumes state that does not survive. `80_agent.sh`
therefore starts it by hand, and only after checking that the EK is registered and in
the group — a check no file on disk can stand in for, because the registry is in memory
while `~/lab/tpm/node01/tpm_id` is not.

**It gets its own destination directory**, `~/lab/tpm/agent/`, rather than the device's.
The agent attests, so pointing it at `~/lab/tpm/node01/` would reissue over the material
Parts 7 and 8 depend on. It is stopped on the way out for the same reason the scripts
flush transient contexts: it holds the device TPM, and swtpm has three slots.

**Its certificate and its token expire on different clocks, and only one of them is
the agent's own business.** `renew { min_validity_percentage = 50 }` inside the
`tpm_cert` block covers the *certificate* — a 24-hour object the agent reissues for
itself by attesting again. The *token* is bounded by the role: `token_ttl=15m`,
`token_max_ttl=1h`, no period. So roughly every twenty minutes the lifetime watcher
stops being able to extend the lease and hands back to the auth handler, which logs in
again with the certificate it already holds. That is an mTLS call to `auth/tpm/login`
and not a fresh attestation, so Vault's per-EK rate limit never enters it. It is also
the right shape: the device re-proves possession of the key rather than holding a
credential that renews for ever. A `token_period` would remove the re-authentication
entirely and with it most of the point of putting the key in a TPM.

**`task agent:soak` is the regression test for that re-authentication.** It lowers the
role to 1m/3m tokens, runs the agent through three authentications in about four
minutes, reports the free TPM slots before and after, and restores the TTLs from a
trap. On Vault 2.2.0 every login frees its own TPM handles, so the agent
re-authenticates past `token_max_ttl` indefinitely with all three swtpm slots free.

### Observations from the agent

Everything here was established by running the agent from Vault Enterprise 2.2.0:

| Expectation | Reality |
|---|---|
| The auto-auth method is configured like the CLI, with a role, a state directory and a device path | It is not. The method takes a *reference* to a named `tpm_cert` block — `config = { tpm_cert = "node01" }` — and that block is a whole subsystem of its own, with `tpm`, `destination` and `renew` sub-blocks |
| `role_name` goes where the other auth methods put it | It belongs in the `tpm_cert` block. Repeating it in the method's `config` map is accepted without a word; the lab keeps it in one place |
| An unusable block fails validation | An empty `tpm_cert {}` block **segfaults** the agent — `nil pointer dereference` in `configureTPMAutoAuth`, not a config error |
| A misnamed key is rejected | Unknown keys in these blocks are dropped without a word. A `csr` block with a misspelled field is ignored and the certificate's common name falls back to the hostname — which is only harmless here because nothing checks the common name anyway. Any other silent drop costs a debugging session |
| The agent reuses its persisted certificate on restart | Not over swtpm. On start it validates what is in `destination.path`, and the validation needs more than swtpm's three transient slots — even with all three free beforehand: `failed to load persisted TPM certificate material, will reissue: error="persisted material failed validation: failed to load persisted app key: cannot load signing key: Load() failed: warning code 0x2 : out of memory for object contexts"`, then `starting initial acquisition after load failure`. It attests afresh on every start. Harmless here — `min_backoff = 10s` covers the per-EK rate limit and it then authenticates normally — and expected not to happen on `/dev/tpmrm0`, where the kernel virtualises the slots (untested) |
| `min_validity_percentage = 50` renews at half the certificate's life | Observed renewal for a 24-hour certificate was scheduled 18-20 hours out, not 12, and the figure moved between runs — jittered rather than a plain percentage. Do not build anything on the exact number |
| A token that reaches `token_max_ttl` is re-authenticated transparently | It is. The auth handler logs `lifetime watcher done channel triggered, re-authenticating` and logs in again with the certificate it holds; `task agent:soak` saw three authentications and two re-authentications with all three swtpm slots free before and after, and stopping the agent leaves them free too |

A sibling feature ships beside this one in the same release — `pki_external_ca`, which
orders certificates from an external ACME CA with a TPM-held key. It is not used here.

## Vault Agent API proxies (Parts 10-11)

Part 9's agent writes its token to a sink, which a workload must still read and present.
Parts 10 and 11 remove that step: the agent's `api_proxy` forwards ordinary Vault
requests and **forces** its own token onto each one (`use_auto_auth_token = "force"`),
replacing whatever the caller sent — no token, a stale one, or root.

The `tpm_cert` and `auto_auth` halves are exactly Part 9's. What changes is the listener,
and who may reach it.

![One application, one TPM-backed Vault identity](diagrams/single-app-walkthrough.png)

### Part 10: one workload on localhost

`vault-proxy-single` runs as the lab user, attests into `~/lab/tpm/proxy/` as role
`payments-app`, and listens on `http://127.0.0.1:8100`. The workload sets `VAULT_ADDR`
to that URL and reads `secret/payments/app` holding only the `device-holds-no-token`
placeholder. Sending the dev root token through the proxy for `secret/analytics/app` is
still denied: the agent replaced it with its `payments-read` token.

This is **token automation, not isolation**. Any process on the host that can reach a
loopback TCP port gets `payments-app`'s privileges.

### Part 11: one agent per application

The TPM cannot tell applications apart. `payments-app` and `analytics-app` both trust the
`devices` group, because it is one machine with one EK; anything that can drive this TPM
can attest for either role. So the boundary between applications comes from the OS:

| Layer | Payments | Analytics |
|---|---|---|
| Unix user | `payments` (system, `nologin`) | `analytics` |
| Agent | `vault-proxy@payments`, role `payments-app` fixed in `/etc/vault-proxy/payments.hcl` | `vault-proxy@analytics`, role `analytics-app` |
| Listener | `/run/vault-proxy/payments.sock`, `payments:payments 0600` | `/run/vault-proxy/analytics.sock`, `analytics:analytics 0600` |
| Policy | `payments-read` — `secret/data/payments/*` | `analytics-read` — `secret/data/analytics/*` |
| Attest directory | `~/lab/tpm/app-payments/`, root 0700 | `~/lab/tpm/app-analytics/`, root 0700 |

![Per-application proxies sharing one TPM](diagrams/proxy-boundary.png)

The agents run as **root**, a deliberate exception to "lab artefacts belong to the lab
user", for two reasons. Only root can hand a listening socket to another uid
(`socket_user`). And an agent running as the application's own user would give that user
the TPM and its key blobs — and with them a login as any role the group is trusted for.
As root, neither application can open the TPM socket or read the agents' state, which is
the sixth of Part 11's checks:

| # | As | Request | Result |
|---|---|---|---|
| 1 | `payments` | own socket, own secret | `payments settlement batch` |
| 2 | `payments` | own socket, analytics secret | `permission denied` (policy) |
| 3 | `payments` | as 2, with `VAULT_TOKEN=root` | `permission denied` — the agent forced its token |
| 4 | `analytics` | payments socket | `dial unix …: connect: permission denied` (socket mode) |
| 5 | `analytics` | own socket, own secret | `analytics risk model` |
| 6 | each | the TPM socket; its agent's attest directory | both refused |

Both parts keep Part 9's conventions: units installed **disabled** and started by their
script, attest directories of their own (one level under `~/lab/tpm/`, so `task config`
clears their certificates with everyone else's when a fresh mount brings a new CA), and an
`EXIT` trap that stops them and flushes the TPM. Each waits 12 seconds before starting an
agent: an agent attests the moment it starts, and an agent refused by the per-EK rate
limit schedules its own retry about 45 seconds out.

### Observations from the proxies

| Expectation | Reality |
|---|---|
| `vault proxy` is the daemon for an API proxy | In 2.2.0 it has no `tpm` auto-auth method — `unknown auto-auth method type tpm`. `vault agent` with an `api_proxy` stanza gives the same listener |
| `use_auto_auth_token = "force"` is needed to ignore a caller's token | It is: with `true` the agent only fills in a missing token, and a caller's root token would pass straight through |
| Two agents can share one swtpm | They can. Started one at a time, both stayed up and served every Part 11 request, across re-runs and after `task reset`. Concurrent first starts were not tried: the lab avoids them rather than relying on three transient slots being enough |

## Lab layout inside the VM

All lab state lives inside the VM, owned by the `ubuntu` user, under `~/lab`:

| Path | Contents |
|---|---|
| `~/lab/env.sh` | The TPM and Vault environment (`TPM_DEVICE_PATH`, `TPM2TOOLS_TCTI`, `ATTACKER_TPM_DEVICE_PATH`, `VAULT_ADDR`, `VAULT_CACERT`, `VAULT_TOKEN`). Every scripted command sources this, so an interactive `task shell` session sees exactly the same environment |
| `/etc/vault-dev.env` | `VAULT_LICENSE=…`, root:root 0600, loaded by the `vault-dev` unit's `EnvironmentFile`. The one file outside `~/lab`: systemd reads it as root before dropping to `ubuntu`, so the lab user cannot read the licence |
| `~/lab/state/` | Lab state: `config.json` (the Parts 4-5 sentinel), `orchestrator.token` (0600 — the scoped credential `task enrol` uses to register the device) and `login.json` (0600 — the last device token) |
| `~/lab/tpmstate/<instance>/` | Software TPM state and its socket, one directory per swtpm instance. The storage seed lives here — this is what makes the key handles machine-bound |
| `~/lab/vault-tls/` | The dev server's own TLS material: `vault-ca.pem`, `vault-cert.pem`, `vault-key.pem` |
| `~/lab/agent/` | The Part 9 agent's own files: `agent.hcl`, the template source, and — only while it runs — the token sink and the rendered secret |
| `~/lab/proxy/` | The Part 10 proxy's `proxy.hcl` |
| `/etc/vault-proxy/<app>.hcl`, `/run/vault-proxy/<app>.sock` | Part 11: each application's agent config (root 0600) and its listener (`<app>:<app>` 0600, only while the agent runs) |
| `~/lab/tpm/<device>/` | What `vault tpm attest` wrote: `client.crt`, `ca_chain.pem`, `app.blob`, `ak.blob`, `client-key.json`, plus `ek.pub` and `tpm_id` from step 6.1. The Part 8 tests keep their own directories beside it (`stolen`, `unenrolled`, `rogue`, `attacker`), one per test so none of them inherits another's certificate, as do the agents: `agent` (Part 9), `proxy` (Part 10), and the root-owned `app-payments` and `app-analytics` (Part 11) |

Seven systemd units run the daemons, three of them enabled:

| Unit | Role |
|---|---|
| `swtpm@device` | The device's software TPM on `~/lab/tpmstate/device/swtpm.sock` |
| `swtpm@attacker` | A second, independently seeded TPM on `~/lab/tpmstate/attacker/swtpm.sock`, used only by the Part 8 tests |
| `vault-dev` | `/usr/bin/vault server -dev -dev-tls` on https://127.0.0.1:8200, licensed from `EnvironmentFile=/etc/vault-dev.env` |
| `vault-agent` | The Part 9 agent. **Installed disabled** and started only by `task demo:agent`, which stops it again on the way out — see Vault Agent above |
| `vault-proxy-single` | The Part 10 proxy on `127.0.0.1:8100`, as the lab user. Disabled; started and stopped by `task demo:proxy` |
| `vault-proxy@payments`, `vault-proxy@analytics` | The Part 11 per-application agents, as root. Disabled; started and stopped by `task demo:multi-app` |

Running them as units rather than `nohup` plus PID files is deliberate:
readiness becomes `systemctl is-active` instead of a blind `sleep`, restarts are ordinary
`systemctl restart`, and logs come from `journalctl` rather than files nobody rotates.
The attacker TPM gets its own socket rather than displacing the device TPM, so the
stolen-key test never requires stopping and restarting the real one.

## Running it

| Task | What happens | What to expect |
|---|---|---|
| `task deps` | Checks host tooling and that `VAULT_LICENSE` is non-empty, without printing it | Required tools listed as ok; warnings for anything missing |
| `task init` | Installs pre-commit hooks, seeds `.env` from the template | One-time, host only. `.env` can override `VM_NAME`, `DEVICE_NAME`, `DOMAIN`, `VAULT_LICENSE` and `VAULT_VERSION` |
| `task launch` | Creates the Multipass VM | No-op if `tpm-lab` already exists |
| `task provision` | Adds HashiCorp's apt repository, installs and holds `vault-enterprise` at `VAULT_VERSION`, pushes the licence (skipped when the installed copy already matches), installs swtpm and tpm2-tools | Slowest step on first run; near-instant afterwards |
| `task tpm` | Installs and starts both swtpm units on their sockets | Both units active; each TPM answers `tpm2_getrandom`, and its EK ID is printed |
| `task vault` | Starts the Vault dev server unit with the licence | `vault status` shows `Sealed false`, `Version 2.2.0+ent` |
| `task config` | Enables tpm auth and configures its CA (clearing any certificates from a previous CA), writes the KV secret and the `device-read` policy, creates the `devices` group and role, writes the `enrol-orchestrator` policy and mints its token | Re-runnable; this is the step to repeat after a Vault restart. Uses the root token, correctly |
| `task enrol` | Reads the EK, registers it and admits it to the group as the orchestrator, attests as the device with no token, verifies the certificate's SAN | A certificate naming the TPM ID and role; re-runs skip attestation while the certificate is fresh |
| `task all` | All of the above in order | Ends with "Lab ready" |
| `task demo:prepare` (`provision-demo`) | `launch`, `provision`, `tpm` and `vault`, then stops | For a live demo that configures and enrols by hand from Part 4; `task config enrol` picks up from there |
| `task demo:nonexportable` | Shows the blob structure, the failed `openssl` load, the `fixedtpm` attributes and the matching public key | The talking point that lands hardest |
| `task demo:login` | The mTLS login | A client token with policies `default` and `device-read`, and metadata naming the TPM |
| `task demo:privilege` | Read then write with the device token | Read succeeds, write is denied |
| `task demo:negative` | All five negative tests in order | Each prints its expected and actual outcome for the operator to judge |
| `task demo:agent` | Part 9: writes the agent config and unit, starts it, and stops it again | A token matching Part 7's and a rendered secret, both produced with no operator. The unit stays disabled |
| `task demo:proxy` | Part 10: the localhost proxy, a tokenless read through it, and a root token it ignores | `payments settlement batch`, then `permission denied`. The unit stays disabled |
| `task demo:multi-app` | Part 11: users, configs and agents per application, then the six boundary checks | Each application reads only its own secret, through only its own socket. Both units stay disabled |
| `task demo` | The complete narrated run | Pauses between parts; a few minutes with `PAUSE=0` |
| `task shell` | Interactive shell in the VM | `source ~/lab/env.sh` to work by hand |
| `task logs`, `task logs:tpm`, `task logs:vault`, `task logs:agent`, `task logs:proxy` | Journals for the lab units | |
| `task tpm:flush` | Flushes transient objects and sessions on both TPMs and prints the free slots | Recovery after an interrupted run: a client killed mid-call can leave a key loaded, and swtpm has three slots. The scripts flush for themselves |
| `task reset` | Clears lab state and both TPMs' seeds, keeps the VM, the Vault package and the licence | Rebuild with `task tpm vault config enrol` |
| `task clean` / `task rebuild` | Destroy the VM / destroy and rebuild | |
| `task lint` | pre-commit: shellcheck, gitleaks | Must pass before committing |
| `task docs:diagram` | Re-renders the PNGs from the `.dot` and `.svg` sources | Needs graphviz and librsvg on the host |

### Pacing the demo

`task demo` stops between each part and waits, so there is room to talk over what just
happened before the next thing scrolls past:

```
────────────────────────────────────────────────────────────
next: Part 9 — Vault Agent: the same login, unattended
  ⏎ continue · q quit
```

`q` stops the run and prints the task to resume with, so a session can be picked up
where it was left. `PAUSE=0 task demo` restores the uninterrupted run, and `PAUSE=0` in
`.env` makes that permanent. The prompt is host-side (`scripts/host/pause.sh`) and reads
`/dev/tty` directly: with no terminal — a pipe, CI — it is skipped rather than blocking.

Pauses sit between the demo tasks, not inside them. Running one part on its own
(`task demo:login`) never prompts.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `task provision` stops at a precondition about `VAULT_LICENSE` | `VAULT_LICENSE` is unset or empty | Paste the licence text into `.env` as `VAULT_LICENSE=…`, on one line |
| `vault-dev` will not start | Port 8200 already held, the TLS directory is unwritable, or the licence in `/etc/vault-dev.env` is bad | `journalctl -u vault-dev -n 50` |
| `authentication failed` at login right after `task config`, with a certificate that looks valid | The certificate was issued by the mount's previous CA | `task enrol` — `task config` has already cleared the stale certificate, so enrol re-attests |
| `task config` dies with "not an Enterprise build" | The `vault` on `PATH` is not the Enterprise package — the OSS `vault` apt package, or a stray binary ahead of `/usr/bin` | `vault version` and `which -a vault`; remove the stray (`sudo apt remove vault`) and re-run `task provision` |
| `tpm2_getrandom` hangs or errors | The device TPM is not running, or the TCTI variables are not set | `systemctl is-active swtpm@device`; `journalctl -u swtpm@device -n 50`; in an interactive shell, `source ~/lab/env.sh` |
| `swtpm@device` fails with `Could not open lockfile: Permission denied` | AppArmor, not file ownership. Ubuntu's `usr.bin.swtpm` profile allows state only under `owner @{HOME}/**` and `owner /var/lib/swtpm/**` | The lab keeps state in `~/lab/tpmstate`, which the profile already permits. If you move `TPM_STATE_ROOT` elsewhere, expect this. Confirm with `sudo dmesg \| grep -i apparmor` |
| `Failed to connect to …/swtpm.sock.ctrl` from tpm2-tools | The swtpm TCTI needs the control socket beside the data socket | Both are created by the unit; check `ls ~/lab/tpmstate/device/` and restart `swtpm@device` |
| `out of memory for object contexts` from a login or attest | A transient handle left loaded by an interrupted client — there is no resource manager over a raw socket | `task tpm:flush` (the scripts flush before each call anyway); see the observations above. The same message in `task logs:agent` at agent start-up is expected and harmless — see the agent observations |
| `rate limit exceeded for this EK` | A second attestation within ~10s of the last | Wait and retry; `task enrol` and the Part 8 scripts already do. In `task logs:proxy` it is followed by the agent's own retry ~45s later |
| An application's request through its socket hangs or is refused at `dial unix` | The agent is not running (the units are disabled and stopped on the way out), or the caller is not the socket's owner | `sudo systemctl start vault-proxy@<app>`; run the client as `<app>` |
| `no TPM found for EK public key` at attestation | The EK is not in `identity/tpm` | Run `task enrol` (or, after a Vault restart, `task config && task enrol`) |
| `permission denied` (403) at `gentpmcert/begin` | The EK is registered but the role does not trust it — not in the group, or the role names another group | `vault read auth/tpm/role/devices`; `vault read identity/tpmgroup/name/devices` |
| `authentication failed` at login | The certificate was issued by another mount's CA, or names a TPM the role does not trust | Compare the certificate's SAN (`openssl x509 -ext subjectAltName`) with the role and group |
| Every `vault` command as `ubuntu` suddenly acts as the device | `~/.vault-token` was overwritten by a login run without `-no-store` | `printf root > ~/.vault-token` (env.sh's `VAULT_TOKEN=root` normally shadows the file anyway) |
| Every Vault path 404s or permission-denies at once | The Vault dev server restarted and its in-memory state is gone | `task config && task enrol` |
| The stolen-key test appears to *succeed* | The client is still pointed at the device TPM | Check which socket the test used; both `swtpm@device` and `swtpm@attacker` should be active |
| Multipass commands hang on the host | The VM is stopped or suspended | `multipass info tpm-lab`; `task start` |

Because Vault dev mode is entirely in-memory, "all the configuration vanished" is the
single most common failure, and `task config && task enrol` is always the answer. Nothing
needs rebuilding from scratch for that.

## From lab to production

| Lab | Production |
|---|---|
| `swtpm` on a unix socket, with `tpm2_flushcontext` before each call | Hardware or firmware TPM via `/dev/tpmrm0` — the kernel resource manager makes the flushing unnecessary, and nothing else changes |
| `vault-enterprise` pinned from apt in a throwaway VM, licence text in `.env`, pushed as a root-only `EnvironmentFile` | Vault Enterprise deployed by your config management, licence via `VAULT_LICENSE` or autoloading |
| `vault server -dev -dev-tls` | HA cluster with Raft storage, a real server certificate, and auto-unseal |
| One tpm auth mount with its internal CA and one role | Per-fleet roles bound to per-fleet TPM groups, each with its own policies and token bounds; `token_bound_cidrs` where the network allows |
| Root token for operator work — `task config` only. Registration uses the scoped `enrol-orchestrator` token, and the device never holds any | Scoped admin policies throughout; the root token generated only for break-glass and revoked afterwards |
| The orchestrator's token written to a file on the same box, minted fresh on every `task config` | The provisioning system authenticates as its own workload identity, with short-lived credentials it renews rather than a token at rest |
| EK public keys read from the live TPM and registered one at a time | EK public keys (or EK certificates) collected from the manufacturer or at imaging time and pre-registered with `vault tpm enroll -ekpem=…`, before the device ever boots |
| 24-hour certificates, refreshed by re-running `task enrol` | The agent's own renewal timer, well inside the certificate lifetime — which Part 9 demonstrates |
| A single KV secret | Per-device paths templated on the token's `tpm_id` metadata or entity alias, so devices cannot read each other's secrets |
| No boot-state gating | Keys sealed to PCR policy, so a tampered boot chain loses access |
| Audit device optional | Audit devices mandatory, shipped off-host, with per-device entity aliases for attribution |

## Stretch goals not automated

Extensions that are documented but deliberately not scripted, because each one needs
judgement or code rather than another idempotent step:

- **Revocation before expiry.** Remove a TPM ID from the `devices` group, or delete its
  `identity/tpm` record, and watch the next login fail while the certificate is still
  valid. Then restore it. Worth demonstrating live — and so is the `disabled` flag,
  which blocks attestation and login alike and is undone with `disabled=false`.
- **Identity and audit inspection.** Enable a file audit device, log in, and follow the
  token to its entity. Each TPM produces its own entity alias, which is what gives
  per-device attribution in the audit log.
- **Renewal by hand.** Run `vault tpm reattest` against a state directory whose
  certificate is near expiry and show that the subject and role come from the existing
  certificate. Part 9 covers the automated path; this is the manual one.
- **PCR binding.** Bind key use to measured boot state so that "this machine" becomes
  "this machine, booted the way we expect". The Vault CLI creates the application key
  with its own template, so this needs either an upstream option or a custom client.
- **A fleet of devices.** Everything here is one device and one role. Per-fleet roles
  bound to per-fleet groups, and EK public keys pre-registered at imaging time rather
  than read from a live TPM, are the shape of the real thing — and neither fits in a
  single-VM lab.
