#!/usr/bin/env bash
# Dependency delta between the official step-ca release and our wrapper.
#
# build/verify-pipeline.sh proves that the *toolchain and flags* reproduce the
# official binary. This script covers the other half of the claim "the wrapper
# differs from upstream only by what we add": the set of Go modules linked into
# the binary. It compares the module list embedded in the official linux/amd64
# release (`go version -m`) with the one in dist/step-ca_linux_amd64/step-ca:
#
#   shared module, same version   -> fine
#   module only in the wrapper    -> reported as ADDED (expected: this repo's
#                                    driver module and whatever it needs)
#   shared module, other version  -> FAIL. Our go.mod graph bumped something
#                                    upstream builds with a different version
#                                    (e.g. the driver requires a newer
#                                    go.step.sm/crypto than step-ca does).
#                                    Lower the driver's requirement instead.
#   module only in the official   -> FAIL (something upstream links is missing)
#
# Usage: build/depdelta.sh [path-to-wrapper-binary]   (default: dist/step-ca_linux_amd64/step-ca)
set -euo pipefail

cd "$(dirname "$0")/.."

toolchain=$(sed -n 's/^toolchain //p' wrappers/step-ca/go.mod)
export GOTOOLCHAIN=$toolchain

wrapper=${1:-dist/step-ca_linux_amd64/step-ca}
[ -f "$wrapper" ] || { echo "$wrapper not found; run build/build.sh first" >&2; exit 1; }

tag=$(cd wrappers/step-ca && go list -m -f '{{.Version}}' github.com/smallstep/certificates)
version=${tag#v}
base=https://github.com/smallstep/certificates/releases/download/$tag
tarball=step-ca_linux_${version}_amd64.tar.gz

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
curl -fsSL -o "$work/checksums.txt" "$base/checksums.txt"
curl -fsSL -o "$work/$tarball" "$base/$tarball"
(cd "$work" && grep -E " ${tarball}\$" checksums.txt | sha256sum -c --status -) \
  || { echo "FAIL: $tarball does not match upstream checksums.txt" >&2; exit 1; }
tar xzf "$work/$tarball" -C "$work"
official=$(find "$work" -type f -name step-ca)

mods() { go version -m "$1" | awk -F'\t' '$2 == "dep" { print $3 "\t" $4 }' | LC_ALL=C sort; }
# The official binary is built from smallstep/certificates' own checkout, where
# that module is the main module and is listed as "(devel)"; in our wrapper it
# is a normal dependency at the pinned tag. They are the same source tree, so
# compare them as equal instead of reporting a bogus change.
mods "$official" | sed "s#^github.com/smallstep/certificates\t(devel)\$#github.com/smallstep/certificates\t${tag}#" > "$work/official.mods"
mods "$wrapper" > "$work/wrapper.mods"

awk -F'\t' '
  NR == FNR { off[$1] = $2; next }
  { seen[$1] = 1
    if (!($1 in off)) print "ADDED   " $1 " " $2
    else if (off[$1] != $2) { print "CHANGED " $1 " " off[$1] " -> " $2; bad = 1 } }
  END { for (m in off) if (!(m in seen)) { print "REMOVED " m " " off[m]; bad = 1 }
        exit bad }
' "$work/official.mods" "$work/wrapper.mods" | LC_ALL=C sort \
  && echo "OK: no shared module changed version and none was dropped (official $tag vs $wrapper)"
