# Design: step-ca-kmip

Decision log from the design review of 2026-10-08. Every decision below was an explicit choice
between alternatives; the rationale and the evidence are recorded so that a later reader can tell
what was verified and what was only read in code (section 9).

## 1. Goal

step-ca signs with a key it cannot export. The CA key lives in a KMIP server (Cosmian KMS is the
reference and the only tested server); step-ca sends digests, the server signs.

## 2. Decisions

| # | Decision | Why |
|---|---|---|
| 1 | **Native KMIP driver** registered through `apiv1.Register`, shipped as custom `step-ca` and `step-kms-plugin` builds, no cgo | Cosmian's PKCS#11 library does not work with step's driver today (section 8), needs a cgo build anyway, and has no armv7 build. The registry hook is explicit upstream (`Type.Validate` falls back to registered types) |
| 2 | Standalone public repo `serene-kitfisto-8899/step-ca-kmip`, **Apache-2.0** | All existing step KMS drivers were written by Smallstep staff and `smallstep/certificates` needs a CLA, so upstream-first would block. Everything depended on is Apache-2.0, and attestations (decision 11) need a public repo on GitHub Free/Pro/Team |
| 3 | Generic **`kmip`** KMS type, **binary TTLV over mTLS** (default :5696) via `ovh/kmip-go`; HTTPS-JSON transport possible later | Standards-based and the only shape with an upstream path. Cosmian's own SPIRE fork already drives `Sign(...).DigestedData(...)`, `Locate` and `PublicKeyLink` through it. `ovh/kmip-go` is Apache-2.0 with a tiny dependency tree |
| 4 | **Sign-only runtime.** The step-ca identity needs only `Sign` (plus `Decrypt` for SCEP). The public key is **pinned** (`pub=`), never fetched at runtime. Create/Get/Activate happen under a separate admin/CO identity | Cosmian's Operator role cannot `Get` anything when `crypto_officer_users` is set, so a runtime that needs `Get` fails in the strictest configuration. A pin also lets the driver detect a KMS/certificate key mismatch |
| 5 | v1 scope: X.509 ECDSA (P-256/384/521), RSA signing (PKCS#1 v1.5 + PSS), SSH host/user CA keys, Ed25519, SCEP RSA decrypter | All step-ca consumers of a KMS key (`authority.go`: intermediate signer, SSH host/user signers, SCEP signer + RSA decrypter) |
| 6 | Test **both** Cosmian builds: non-FIPS is the full-scope reference; the FIPS leg covers ECDSA/RSA signing only | Ed25519 is non-FIPS only (Cosmian docs; `signing_cluster_architecture` found that the `-fips` image compiles it out) and RSA PKCS#1 v1.5 decryption, which SCEP needs, is flagged "no longer FIPS approved" in Cosmian's code. The driver does not gate features, it surfaces the server's error |
| 7 | `CreateKey` for ECDSA/RSA, **sensitive and non-extractable by default**; Ed25519 keys are created with `ckms`; no Delete/Search/cert store in v1 | A key created without `--sensitive` can be exported by anyone holding `Get`; enforce the safe default in one place. `ovh/kmip-go` has no Ed25519 enum |
| 8 | **Hybrid failure policy**: startup self-test (dial, then sign and verify against the pin) retried for ~30 s, then exit; runtime pool of 4, 10 s timeout, one retry on transport errors only (never on auth/policy/semantic errors) | `ovh/kmip-go` connections are single-flight (mutex) and redial lazily, so concurrent issuance needs a pool. The step_ca systemd unit has `StartLimitBurst=3` per 30 s: strict fail-fast would hit the start limit, a 30 s retry cannot |
| 9 | **Independent bootstrap CA** (software keys, not backed by this KMS) issues the KMS server cert and step-ca's client cert; the driver re-reads the client cert/key on every handshake | If this step-ca issued its own KMS credentials, a lapsed cert would block signing, which blocks the renewal |
| 10 | Three test layers: fake KMIP server (`ovh/kmip-go/kmipserver`), real Cosmian (both builds, roles on and off), step-ca end to end (X.509, SSH, SCEP) | "Roles on" proves decision 4; end to end proves the integration, not just the parts |
| 11 | **CI-reproducible, attested build**: Go 1.26.1, `CGO_ENABLED=0 -trimpath`, upstream's ldflags. Each run first rebuilds stock step-ca and requires it to equal the official release byte for byte; SHA256SUMS + GitHub build-provenance attestation; Puppet module vendors the result and pins checksums; bot PRs per upstream tag | The Puppet `step_ca` module vendors upstream-verified binaries. A custom build changes the trust anchor, so the pipeline is proven against upstream instead of trusted (section 7) |
| 12 | **One mTLS identity per step-ca instance** (CN=`step-ca-<fqdn>`), per-key `Sign` grants | Cosmian maps the cert CN to the KMS user. Audit lines name the host and one compromised host is cut off by removing one grant |
| 13 | Order: M0 pipeline, M1 ECDSA core, M2 RSA + SSH + FIPS leg, M3 CreateKey + plugin, M4 Ed25519 + SCEP, M5 Puppet + docs (section 10) | Value first; each milestone ends with a green end-to-end test |
| 14 | Port `spire-kmip-plugin`'s conventions into this repo's own `internal/kmip`; no shared module yet | Its `internal/kmip` is a scaffold (the "TLS client" only dials and delegates to an in-memory fake), so there is no wire client to reuse. Extract a shared module when a second consumer actually needs one |

Defaults taken without a separate question (all accepted): keys are addressed by **immutable UID**
(no `@latest` keysets, no Rekey: a new CA key needs a new certificate anyway, so rotation is "new
key, new cert, update config, SIGHUP"); one KMS endpoint (the load balancer does HA); TLS 1.3
minimum, overridable; idle connections recycled before typical LB idle timeouts (the cluster
compose HAProxy uses 60 s); secrets only from files; the existing root, kept offline, signs a new
KMS-backed intermediate (root-in-KMS works but is not the reference flow).

## 3. Architecture

```
 step-ca (wrapper)  --- Sign(uid, DigestedData) --->  KMIP server (Cosmian KMS, socket :5696, mTLS)
   |  kms/kmip driver: pool, pin check, retry            key never leaves; CN -> user; Sign grant
   |  ca.json: "key": "kmip:id=<uid>;pub=intermediate_ca.crt"
 step-kms-plugin (wrapper, admin workstation only)
      CreateKey / GetPublicKey / CreateSigner for provisioning, under an admin/CO identity
```

`kms/kmip` mirrors upstream's layout (`go.step.sm/crypto/kms/<name>`) so it can be proposed upstream
later without restructuring.

Custom binaries needed: `step-ca` and `step-kms-plugin`. **Not** the `step` CLI: it executes
`step-kms-plugin` for every `--kms` operation (`internal/cryptoutil`). The one exception is
`step ca rekey --key kmip:...` without `--kms`, which uses in-process type detection; pass `--kms`.

## 4. Configuration surface (proposed; implemented in M1)

```
kms.uri  kmip:addr=<host:port>;ca=<file>;cert=<file>;key=<file>[;server-name=<n>][;timeout=10s]
              [;pool=4][;startup-retry=30s][;tls-min=1.3]?pin-source=<file with the key passphrase>
key      kmip:id=<UID>[;pub=<PEM SPKI | PEM certificate | OpenSSH public key>]
```

Secrets are never inline: `step-kms-plugin` receives the URI on its command line, which any local
user can read with `ps`. With `pub=` the runtime never calls `Get`; without it the driver falls back
to `Get` (needed by provisioning tools, which run under an admin identity).

## 5. Security model

* Provisioning identity (admin/CO): creates keys (sensitive), grants `Sign` per key and per instance.
* Runtime identity per instance: `Sign` (and `Decrypt` for SCEP) on its keys only. Removing the grant
  is an immediate kill switch that does not wait for certificate expiry.
* The startup self-test signs a random digest and verifies it with the pinned key: it proves the
  permission, the connection and the key match without any `Get`. Go's `x509.CreateCertificate` also
  verifies every signature it obtains, so a later key swap fails closed.
* mTLS trust anchored in an independent bootstrap CA (decision 9).

## 6. Failure semantics

Startup: dial, negotiate, self-test, retry with backoff for ~30 s, then exit non-zero (systemd
restarts after `RestartSec=5`). Runtime: pool of 4 single-flight connections, 10 s per operation,
one retry on transport errors only. Error classes follow `spire-kmip-plugin`: auth, transport,
kmip-semantic, policy, integrity; only transport is retried.

## 7. Build, provenance, deployment

* Pinned toolchain: the `toolchain` line in `go.mod`; `GOTOOLCHAIN` is derived from it everywhere.
* `build/verify-pipeline.sh` proves the pipeline against upstream on every CI run (section 9).
* `internal/genmain` derives each wrapper `main.go` from the pinned upstream one and adds a single
  blank import; a unit test enforces that the change is purely additive and CI fails on drift.
* `build/depdelta.sh` compares the module list in the official binary with the wrapper's.
* The wrappers are separate Go modules. `step-kms-plugin` v0.17.0 requires `go.step.sm/crypto`
  v0.77.2 while `certificates` v0.30.2 uses v0.77.1; one module would bump step-ca's dependency.
* `step-kms-plugin` is built without cgo (the official linux plugin is a cgo build with PKCS#11,
  YubiKey and TPM), so it cannot be byte-compared with upstream; it gets the pinned toolchain,
  reproducibility and dependency checks instead.
* Deployment (M5): the `step_ca` Puppet module vendors `files/step-ca_linux_{amd64,armv7l}/step-ca`
  with sha256 pins and ships `step-ca.service` (hardened, `MemoryDenyWriteExecute=true`; pure Go is
  compatible). `ca.json` is maintained by hand outside the module. Strip when vendoring, as that
  module's documented process does.

## 8. Why not Cosmian's PKCS#11 library (5.28.0)

Tested with `pkcs11-tool` and with step's own `kms/pkcs11` driver (`go.step.sm/crypto` v0.77.1):

* **Public half not found** (reproduced end to end): the provider reports `CKA_ID=<uid>`,
  `CKA_LABEL="Private Key"` for the private key and `<uid>_pk`, `"Public Key"` for the public key.
  step's driver (ThalesGroup/crypto11) pairs the halves by the private key's ID and label, so
  `GetPublicKey` fails with "key ... not found".
* **ECDSA returns ASN.1 DER where PKCS#11 requires raw r||s.** Confirmed with `pkcs11-tool`; also
  predicted by crypto11's `unmarshalBytes`, but not exercised through crypto11 because the lookup
  above fails first. DER lengths of 70 or 72 bytes would be parsed as raw and give invalid
  signatures silently.
* The provider exports the private key from the KMS for non-sensitive keys (KMS server log shows
  `Exported object of type: PrivateKey` during PKCS#11 use).
* `signing_cluster_architecture` records two more gaps: no PKCS#11 v3.0 `C_GetInterface`, and a
  null-template `C_FindObjectsInit` is rejected.
* Release assets exist for linux amd64 and arm64 only, not armv7.

## 9. Evidence log

Verified on 2026-10-08:

* Pipeline proof: Go 1.26.1, `CGO_ENABLED=0`, `-trimpath`, `-ldflags "-w -X main.Version=0.30.2
  -X main.BuildTime=2026-03-23T00:18:00Z"`, built from a git clone of tag v0.30.2, reproduces the
  official release **byte for byte**: linux/amd64 sha256 `53597e5f169ce8251daee828727d140e09e29c839eefc2823fcb662ed644b6da`,
  linux/armv7 `8a56a5b571bb0628cd280e31d29c6ea77886d79e55e99a2c5971dd112fe2efc2`. Release tarballs
  were first checked against upstream's `checksums.txt`.
* Dependency delta: only `github.com/serene-kitfisto-8899/step-ca-kmip` is added; no shared module
  changed version. A negative test (the plugin binary) fails as it should.
* Two builds of one commit are identical (`make repro-check`).
* Proof of concept (a different transport, KMIP JSON-TTLV over HTTPS, not part of this repo): a
  custom step-ca v0.30.2 issued a leaf certificate whose chain verified with `openssl`, with the
  intermediate key held only in Cosmian KMS 5.28.0 (non-FIPS, `--sensitive` P-256 and P-384 keys)
  and the on-disk intermediate key deleted. Exporting that key was refused (`Sensitive: DENIED`).

Read in code or documentation, **not yet run** (to be proven in M1/M2):

* Binary-TTLV `Sign` with `DigestedData` through `ovh/kmip-go` against Cosmian (Cosmian's SPIRE fork
  does this: `pkg/server/plugin/keymanager/kmip/kmip.go`).
* ECDSA P-521, RSA (PKCS#1 v1.5 and PSS on pre-digested input), Ed25519, SSH CA keys and the SCEP
  decrypter on Cosmian (`crate/crypto/src/crypto/{rsa,elliptic_curves}/sign.rs`).
* A Sign-only Operator under `crypto_officer_users` (docs: `configuration/authorization/key_ceremony.md`).
  `ckms access-rights grant` help does not list `sign`, although `KmipOperation::Sign` is grantable
  in the server and its tests.
* FIPS-build behaviour; the CN-to-user mapping on the socket server (`socket_server.rs`).
* The release workflow (`release.yml`) has never run.

Cosmian-side prerequisites: socket server enabled (`socket_server_start`, off by default) with a
clients CA (`clients_ca_cert_file`); the existing cluster compose and the dev server expose HTTPS on
9998 only, so a TTLV listener (and a second HAProxy frontend) must be added.

## 10. Milestones

| M | Content | Done when |
|---|---|---|
| **M0** | Repo, license, pipeline proof, wrapper mains | `make all verify-pipeline repro-check depdelta` green locally and in CI **(this commit)** |
| M1 | Core driver + ECDSA: URI parsing, mTLS with hot reload, pool, pin, startup self-test, `Sign`; port `spire-kmip-plugin` error taxonomy and retry | Fake-server unit tests with failure injection; real non-FIPS Cosmian end to end: a Sign-only Operator identity issues an X.509 leaf |
| M2 | RSA signing, SSH CA keys, FIPS leg, per-instance kill-switch test | Green end-to-end tests on both builds, roles on and off |
| M3 | `CreateKey` (ECDSA/RSA, sensitive default), `step-kms-plugin` build, provisioning runbook (offline root signs the KMS intermediate) | Root and intermediate created and chained via `step` + plugin |
| M4 | Ed25519 and the SCEP decrypter | SCEP enrollment and Ed25519 X.509/SSH verified end to end (non-FIPS) |
| M5 | Puppet vendoring (amd64, armv7l), docs, first release (`vX.Y.Z`, binaries report `<upstream>+kmip.<X.Y.Z>`) | Attestation verifies with `gh attestation verify`; Puppet pins match |
