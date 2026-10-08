package main

import (
	"testing"

	"go.step.sm/crypto/kms/apiv1"
)

// The generated main.go must link the driver in; otherwise
// `step-kms-plugin --kms kmip:...` would fail with "unsupported kms type".
func TestKMIPDriverIsLinkedIn(t *testing.T) {
	if _, err := apiv1.TypeOf("kmip:addr=localhost:5696"); err != nil {
		t.Fatalf("kmip KMS type is not registered in this binary: %v", err)
	}
}
