// Package kmip is a step KMS driver that keeps CA signing keys inside a KMIP
// server (reference server: Cosmian KMS) and asks the server to sign.
//
// Importing the package for its side effects registers the "kmip" KMS type in
// go.step.sm/crypto's registry, so that ca.json can say:
//
//	"kms": {"type": "kmip", "uri": "kmip:addr=kms.example.lan:5696;..."},
//	"key": "kmip:id=<private key UID>;pub=/etc/step-ca/certs/intermediate_ca.crt"
//
// Status: milestone M0. Only the registration exists and every operation
// returns apiv1.NotImplementedError; the driver proper is milestone M1 (see
// docs/DESIGN.md). Registering early lets the wrapper binaries and the build
// pipeline be proven end to end before any KMIP code exists.
package kmip

import (
	"context"
	"crypto"

	"go.step.sm/crypto/kms/apiv1"
)

// Scheme is the URI scheme handled by this driver.
const Scheme = "kmip"

// Type is the KMS type to use in the "type" property of the kms object in ca.json.
const Type apiv1.Type = Scheme

func init() {
	apiv1.Register(Type, func(ctx context.Context, opts apiv1.Options) (apiv1.KeyManager, error) {
		km, err := New(ctx, opts)
		if err != nil {
			return nil, err
		}
		return km, nil
	})
}

// KMS implements apiv1.KeyManager on top of a KMIP server.
type KMS struct{}

var _ apiv1.KeyManager = (*KMS)(nil)

var errNotImplemented = apiv1.NotImplementedError{
	Message: "kmip: the driver is not implemented yet (milestone M1, see docs/DESIGN.md)",
}

// New creates the driver from the "uri" of the kms object in ca.json.
func New(_ context.Context, _ apiv1.Options) (*KMS, error) {
	return nil, errNotImplemented
}

// GetPublicKey implements apiv1.KeyManager.
func (*KMS) GetPublicKey(*apiv1.GetPublicKeyRequest) (crypto.PublicKey, error) {
	return nil, errNotImplemented
}

// CreateKey implements apiv1.KeyManager.
func (*KMS) CreateKey(*apiv1.CreateKeyRequest) (*apiv1.CreateKeyResponse, error) {
	return nil, errNotImplemented
}

// CreateSigner implements apiv1.KeyManager.
func (*KMS) CreateSigner(*apiv1.CreateSignerRequest) (crypto.Signer, error) {
	return nil, errNotImplemented
}

// Close implements apiv1.KeyManager.
func (*KMS) Close() error { return nil }
