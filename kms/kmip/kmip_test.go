package kmip

import (
	"context"
	"errors"
	"testing"

	"go.step.sm/crypto/kms"
	"go.step.sm/crypto/kms/apiv1"
)

func TestTypeIsRegistered(t *testing.T) {
	typ, err := apiv1.TypeOf("kmip:addr=localhost:5696")
	if err != nil {
		t.Fatalf("TypeOf: %v", err)
	}
	if typ != Type {
		t.Fatalf("TypeOf = %q, want %q", typ, Type)
	}
}

func TestNewIsNotImplementedYet(t *testing.T) {
	km, err := kms.New(context.Background(), apiv1.Options{URI: "kmip:addr=localhost:5696"})
	if !errors.Is(err, apiv1.NotImplementedError{}) {
		t.Fatalf("kms.New error = %v, want apiv1.NotImplementedError", err)
	}
	if km != nil {
		t.Fatalf("kms.New returned a non-nil KeyManager alongside an error: %T", km)
	}
}
