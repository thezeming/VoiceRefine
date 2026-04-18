#!/bin/bash
# One-time setup: create a self-signed code-signing identity and trust it for
# code-signing in the user's login keychain. Idempotent — safe to rerun.
#
# Why: ad-hoc (`codesign --sign -`) recomputes cdhash from binary bytes, so
# every source change breaks the TCC designated requirement, silently
# invalidating Accessibility / Microphone / Automation grants. A stable
# identity-signed build keeps the DR stable (identifier + certificate CN), so
# grants survive across rebuilds.
#
# Scope: user's login trust settings only. No admin/system trust modification.

set -e

IDENTITY="${1:-VoiceRefine Dev}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "\"$IDENTITY\""; then
    echo "Code-signing identity '$IDENTITY' already exists and is valid. Nothing to do."
    exit 0
fi

echo "Creating self-signed code-signing identity '$IDENTITY'..."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

openssl req -x509 -newkey rsa:2048 -days 3650 -sha256 -nodes \
    -keyout "$tmp/vr.key" -out "$tmp/vr.crt" \
    -subj "/CN=$IDENTITY" \
    -addext "extendedKeyUsage=codeSigning" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "basicConstraints=critical,CA:FALSE" \
    >/dev/null 2>&1

# PKCS12 with a throwaway password — the key is user-local, not secret.
openssl pkcs12 -export \
    -out "$tmp/vr.p12" -inkey "$tmp/vr.key" -in "$tmp/vr.crt" \
    -name "$IDENTITY" -passout pass:hushdev \
    >/dev/null 2>&1

security import "$tmp/vr.p12" \
    -k "$KEYCHAIN" -P hushdev -A -T /usr/bin/codesign \
    >/dev/null

security add-trusted-cert -r trustRoot -p codeSign "$tmp/vr.crt"

echo "---valid code-signing identities:"
security find-identity -v -p codesigning
