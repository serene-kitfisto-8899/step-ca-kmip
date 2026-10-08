.PHONY: all generate check-generated test verify-pipeline build repro-check depdelta clean

# One toolchain for everything, read from go.mod so that CI, bots and humans
# cannot disagree. It is the toolchain upstream used for the pinned step-ca
# release (see build/verify-pipeline.sh).
export GOTOOLCHAIN := $(shell sed -n 's/^toolchain //p' go.mod)
export CGO_ENABLED := 0

CA_MODULE     := github.com/smallstep/certificates
PLUGIN_MODULE := github.com/smallstep/step-kms-plugin
DRIVER_IMPORT := github.com/serene-kitfisto-8899/step-ca-kmip/kms/kmip
ANCHOR        := go.step.sm/crypto/kms/yubikey

GENMAIN_CA     = go run ./internal/genmain -wrapper wrappers/step-ca -module $(CA_MODULE) -src cmd/step-ca/main.go -anchor $(ANCHOR) -import $(DRIVER_IMPORT)
GENMAIN_PLUGIN = go run ./internal/genmain -wrapper wrappers/step-kms-plugin -module $(PLUGIN_MODULE) -src main.go -anchor $(ANCHOR) -import $(DRIVER_IMPORT)

all: check-generated test build

# Regenerate the wrapper mains after bumping an upstream version in wrappers/*/go.mod.
generate:
	$(GENMAIN_CA)
	$(GENMAIN_PLUGIN)

check-generated:
	$(GENMAIN_CA) -check
	$(GENMAIN_PLUGIN) -check

test:
	go vet ./... && go test ./...
	cd wrappers/step-ca && go vet ./... && go test ./...
	cd wrappers/step-kms-plugin && go vet ./... && go test ./...

# Rebuild stock upstream step-ca and require it to equal the official release.
verify-pipeline:
	build/verify-pipeline.sh

build:
	build/build.sh dist

# Same commit built twice must give the same bytes.
repro-check:
	build/build.sh .repro-a >/dev/null
	build/build.sh .repro-b >/dev/null
	diff -u .repro-a/SHA256SUMS .repro-b/SHA256SUMS && echo "OK: two builds of this commit are byte-for-byte identical"
	rm -rf .repro-a .repro-b

depdelta: build
	build/depdelta.sh

clean:
	rm -rf dist .repro-a .repro-b
