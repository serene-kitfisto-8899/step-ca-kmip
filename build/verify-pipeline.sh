#!/usr/bin/env bash
# Pipeline proof: rebuild the *stock* upstream step-ca from its release tag with
# this repository's pinned toolchain and flags, and require the result to be
# byte-for-byte identical to the official release binary.
#
# WHY this exists
#   The wrapper binaries replace the upstream step-ca that used to be vendored
#   (and sha256-pinned) in the Puppet step_ca module. That vendoring was only
#   trustworthy because the binary was Smallstep's own, verified against their
#   published checksums.txt. A custom build changes the trust anchor, so instead
#   of asking anyone to trust *our* toolchain, we prove it on every run: if this
#   pipeline reproduces Smallstep's official binary exactly, then the only thing
#   that can differ in the wrapper is what we deliberately add (one import, see
#   internal/genmain, and the dependency delta, see build/depdelta.sh).
#
# WHAT is compared
#   official release tarball  --(sha256 verified against upstream checksums.txt)-->  step-ca
#   git clone of the release tag --(go build, flags below)-->                        step-ca
#   for linux/amd64 and linux/armv7 (the architectures the Puppet module ships).
#
# Why a git clone and not the module cache
#   -trimpath rewrites file paths inside the binary (they end up in pclntab).
#   Built inside the module's own checkout the prefix is
#   "github.com/smallstep/certificates/..."; built from the module cache it is
#   "github.com/smallstep/certificates@v0.30.2/..." and the bytes differ. The
#   official release is built from the checkout, so we must do the same.
#
# Upstream's flags, taken from .goreleaser.yml at the tag and confirmed with
# `go version -m` on the official binary:
#   CGO_ENABLED=0, -trimpath, -ldflags "-w -X main.Version=<v> -X main.BuildTime=<date>",
#   building ./cmd/step-ca/main.go (so no VCS stamping), with the toolchain the
#   release was built with (go1.26.1 for v0.30.2).
#   BuildTime is the release's start time, read back from `step-ca version`.
#
# Verified result when this was introduced (see docs/DESIGN.md):
#   v0.30.2 linux/amd64 sha256 53597e5f169ce8251daee828727d140e09e29c839eefc2823fcb662ed644b6da
#   v0.30.2 linux/armv7 sha256 8a56a5b571bb0628cd280e31d29c6ea77886d79e55e99a2c5971dd112fe2efc2
#
# Environment overrides: ARCHES="amd64 armv7", BUILD_TIME (needed when the host
# cannot execute the amd64 official binary to read its release date).
set -euo pipefail

cd "$(dirname "$0")/.."

toolchain=$(sed -n 's/^toolchain //p' wrappers/step-ca/go.mod)
[ -n "$toolchain" ] || { echo "no toolchain directive in wrappers/step-ca/go.mod" >&2; exit 1; }
export GOTOOLCHAIN=$toolchain CGO_ENABLED=0

tag=$(cd wrappers/step-ca && go list -m -f '{{.Version}}' github.com/smallstep/certificates)
version=${tag#v}
base=https://github.com/smallstep/certificates/releases/download/$tag
arches=${ARCHES:-"amd64 armv7"}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

echo "toolchain: $(go version)"
echo "upstream:  smallstep/certificates $tag"

curl -fsSL -o "$work/checksums.txt" "$base/checksums.txt"
git -c advice.detachedHead=false clone -q --depth 1 --branch "$tag" https://github.com/smallstep/certificates "$work/src"

fetch_official() { # arch -> path of the extracted official binary
  local arch=$1 tarball="step-ca_linux_${version}_$1.tar.gz"
  curl -fsSL -o "$work/$tarball" "$base/$tarball"
  # The tarball itself must match what Smallstep published, otherwise the
  # comparison below would be against an untrusted reference.
  (cd "$work" && grep -E " ${tarball}\$" checksums.txt | sha256sum -c --status -) \
    || { echo "FAIL: $tarball does not match upstream checksums.txt" >&2; exit 1; }
  mkdir -p "$work/official-$arch"
  tar xzf "$work/$tarball" -C "$work/official-$arch"
  find "$work/official-$arch" -type f -name step-ca
}

declare -A official
for arch in $arches; do official[$arch]=$(fetch_official "$arch"); done

build_time=${BUILD_TIME:-}
if [ -z "$build_time" ]; then
  [ -n "${official[amd64]:-}" ] || { echo "set BUILD_TIME or include amd64 in ARCHES" >&2; exit 1; }
  build_time=$("${official[amd64]}" version | sed -n 's/^Release Date: //p')
fi
[ -n "$build_time" ] || { echo "could not determine the release BuildTime" >&2; exit 1; }
echo "BuildTime: $build_time"

status=0
for arch in $arches; do
  goarch=$arch goarm=
  [ "$arch" = armv7 ] && goarch=arm goarm=7
  out="$work/rebuilt-$arch"
  (cd "$work/src" && GOOS=linux GOARCH=$goarch GOARM=$goarm \
     go build -trimpath -ldflags "-w -X main.Version=$version -X main.BuildTime=$build_time" \
       -o "$out" ./cmd/step-ca/main.go)
  want=$(sha256sum "${official[$arch]}" | cut -d' ' -f1)
  got=$(sha256sum "$out" | cut -d' ' -f1)
  if [ "$want" = "$got" ]; then
    echo "OK   linux/$arch  $got  (byte-for-byte identical to the official release)"
  else
    echo "FAIL linux/$arch  official=$want rebuilt=$got" >&2
    status=1
  fi
done
exit $status
