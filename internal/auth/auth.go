package auth

import (
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"strings"
)

const sha256Prefix = "sha256$"

// HashPassword hashes a plain text password.
func HashPassword(password string) (string, error) {
	sum := sha256.Sum256([]byte(password))
	return sha256Prefix + hex.EncodeToString(sum[:]), nil
}

// CheckPassword validates plain text password against a stored hash.
func CheckPassword(password, hash string) bool {
	if !strings.HasPrefix(hash, sha256Prefix) {
		return false
	}
	sum := sha256.Sum256([]byte(password))
	expected := sha256Prefix + hex.EncodeToString(sum[:])
	return subtle.ConstantTimeCompare([]byte(expected), []byte(hash)) == 1
}
