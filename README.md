# step-ca-kmip

Keep [Smallstep step-ca](https://smallstep.com/docs/step-ca/) signing keys in a KMIP server
([Cosmian KMS](https://github.com/Cosmian/kms) is the reference), so the CA process asks the
server to sign and the private key never leaves it.

step-ca has no KMIP backend, but `go.step.sm/crypto` lets an out-of-tree driver register a new KMS
type. This repository provides that driver (`kms/kmip`) and builds `step-ca` and `step-kms-plugin`
with it linked in. No cgo, no PKCS#11 library.

## Status: milestone M0

Only the build pipeline and the registration of the `kmip` KMS type exist. **The driver does not
sign anything yet** (every operation returns `NotImplementedError`); that is milestone M1. See
[docs/DESIGN.md](docs/DESIGN.md) for the decisions, the milestones and the evidence behind them.

What M0 already gives you, and CI checks on every push:

| Check | Command | Proves |
|---|---|---|
| Pipeline proof | `make verify-pipeline` | Our toolchain and flags rebuild upstream's official `step-ca` release **byte for byte** (linux/amd64 and linux/armv7) |
| Wrapper delta | `make check-generated` | The wrapper `main.go` is upstream's plus exactly one import (generated, never hand-edited) |
| Dependency delta | `make depdelta` | The wrapper links the same module versions as the official binary; only this repo's module is added |
| Reproducibility | `make repro-check` | Building one commit twice gives identical bytes |

## Layout

```
kms/kmip/                  the step KMS driver (M0: registration only)
wrappers/step-ca/          generated main.go + go.mod pinning upstream step-ca
wrappers/step-kms-plugin/  generated main.go + go.mod pinning upstream step-kms-plugin
internal/genmain/          generates the wrapper mains from the pinned upstream versions
build/                     verify-pipeline.sh, build.sh, depdelta.sh
docs/DESIGN.md             decision log, security model, milestones, evidence
```

The two wrappers are separate Go modules on purpose: `step-kms-plugin` requires a newer
`go.step.sm/crypto` than step-ca does, and one shared module would silently bump step-ca's
dependency.

## Build

```sh
make test          # vet + test all three modules
make build         # dist/step-ca_linux_{amd64,armv7l}/step-ca, dist/step-kms-plugin_linux_amd64/
make all           # check-generated + test + build
```

The Go toolchain is the `toolchain` line in `go.mod` (the one upstream used for the pinned step-ca
release); `GOTOOLCHAIN` is derived from it, so any Go >= 1.21 can build.

Bumping upstream: change the version in `wrappers/*/go.mod`, run `go mod tidy` there, then
`make generate verify-pipeline`.

`step-kms-plugin` is built without cgo, so it carries the pure-Go backends plus `kmip` only. Keep the
official plugin for PKCS#11, YubiKey and TPM.

## License

Apache-2.0, see [LICENSE](LICENSE) and [NOTICE](NOTICE).
