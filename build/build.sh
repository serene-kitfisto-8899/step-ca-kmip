#!/usr/bin/env bash
# Build the wrapper binaries into $1 (default: dist) and write SHA256SUMS.
#
#   dist/step-ca_linux_amd64/step-ca
#   dist/step-ca_linux_armv7l/step-ca          (directory name = Debian/Puppet
#                                               $facts['os']['architecture'], the
#                                               naming the step_ca module expects)
#   dist/step-kms-plugin_linux_amd64/step-kms-plugin
#
# The flags deliberately mirror upstream's release flags, because those are the
# flags build/verify-pipeline.sh proves reproduce the official binary:
#   step-ca          CGO_ENABLED=0 -trimpath -ldflags "-w -X main.Version -X main.BuildTime"
#   step-kms-plugin  CGO_ENABLED=0 -trimpath -ldflags "-s -w -X .../cmd.Version -X .../cmd.ReleaseDate"
#
# Differences from the official artifacts, on purpose:
#   * Version is "<upstream>+kmip.<rev>" so `step-ca version` shows what is running.
#   * BuildTime/ReleaseDate is the commit time, not the wall clock, so that
#     building the same commit twice gives the same bytes (make repro-check).
#   * step-kms-plugin is built without cgo. The official linux plugin is a cgo
#     build (PKCS#11, YubiKey, TPM); this one only carries the pure-Go backends
#     plus kmip. Keep the official plugin for hardware tokens.
#   * Binaries are not stripped here; strip when vendoring, as the Puppet
#     module's documented process does.
set -euo pipefail

cd "$(dirname "$0")/.."
root=$PWD
out=${1:-dist}
case $out in /*) ;; *) out=$root/$out ;; esac

toolchain=$(sed -n 's/^toolchain //p' wrappers/step-ca/go.mod)
[ -n "$toolchain" ] || { echo "no toolchain directive in wrappers/step-ca/go.mod" >&2; exit 1; }
export GOTOOLCHAIN=$toolchain CGO_ENABLED=0

rev=${KMIP_REV:-$(git describe --tags --always --dirty 2>/dev/null || echo dev)}
rev=$(printf '%s' "${rev#v}" | tr -c '0-9A-Za-z.\n-' '-')
build_time=${BUILD_TIME:-$(TZ=UTC git log -1 --format=%cd --date=format:%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo 1970-01-01T00:00:00Z)}

modver() { (cd "wrappers/$1" && go list -m -f '{{.Version}}' "$2" | sed 's/^v//'); }
ca_version=$(modver step-ca github.com/smallstep/certificates)
plugin_version=$(modver step-kms-plugin github.com/smallstep/step-kms-plugin)

build() { # wrapper-dir binary goarch goarm outdir ldflags
  local goarm_env=()
  [ -n "$4" ] && goarm_env=(GOARM="$4")
  mkdir -p "$out/$5"
  (cd "wrappers/$1" && env GOOS=linux GOARCH="$3" "${goarm_env[@]}" \
     go build -trimpath -ldflags "$6" -o "$out/$5/$2" .)
}

ca_ldflags="-w -X main.Version=${ca_version}+kmip.${rev} -X main.BuildTime=${build_time}"
plugin_mod=github.com/smallstep/step-kms-plugin
plugin_ldflags="-s -w -X ${plugin_mod}/cmd.Version=${plugin_version}+kmip.${rev} -X ${plugin_mod}/cmd.ReleaseDate=${build_time}"

rm -rf "$out"
build step-ca step-ca amd64 "" step-ca_linux_amd64 "$ca_ldflags"
build step-ca step-ca arm 7 step-ca_linux_armv7l "$ca_ldflags"
build step-kms-plugin step-kms-plugin amd64 "" step-kms-plugin_linux_amd64 "$plugin_ldflags"

(cd "$out" && find . -type f ! -name SHA256SUMS | LC_ALL=C sort | xargs sha256sum > SHA256SUMS)
echo "toolchain: $(go version)"
echo "rev: $rev  build time: $build_time"
cat "$out/SHA256SUMS"
