#!/bin/bash
# Host-side AWS CLI signing-key expiry + fingerprint check (cache-independent).
#
# The Dockerfile enforces the AWS CLI signing-key expiry inside a *cacheable*
# RUN layer, so once the key expires a cached rebuild (e.g. GHA build cache)
# could reuse that layer and skip the check. This script runs on the host every
# CI build against the committed key, independent of any Docker layer cache, so
# expiry genuinely "fails loudly" and acts as the key-rotation trigger.
#
# Usage: test/verify-aws-key-expiry.sh [path-to-key]
# Locally, to also force the in-image check, build with --no-cache (or change
# AWSCLI_VERSION) so the AWS install layer re-runs.

set -euo pipefail

KEY="${1:-docker/aws-cli-public.key}"
EXPECTED_FPR="FB5DB77FD5C118B80511ADA8A6310ACC4672475C"

if [ ! -f "$KEY" ]; then
    echo "FAIL: key file not found: $KEY" >&2
    exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export GNUPGHOME="$tmp"

gpg --quiet --import "$KEY"

got_fpr="$(gpg --with-colons --fingerprint | awk -F: '/^fpr:/{print $10; exit}')"
if [ "$got_fpr" != "$EXPECTED_FPR" ]; then
    echo "FAIL: key fingerprint $got_fpr != expected $EXPECTED_FPR" >&2
    exit 1
fi

exp="$(gpg --with-colons --list-keys | awk -F: '/^pub:/{print $7; exit}')"
if [ -z "$exp" ]; then
    echo "FAIL: AWS CLI signing key has no expiry date" >&2
    exit 1
fi

now="$(date +%s)"
if [ "$exp" -le "$now" ]; then
    when="$(date -u -d "@$exp" 2>/dev/null || echo "epoch $exp")"
    echo "FAIL: AWS CLI signing key expired ($when)." >&2
    echo "      Rotate docker/aws-cli-public.key (and the pinned fingerprint) per README." >&2
    exit 1
fi

when="$(date -u -d "@$exp" 2>/dev/null || echo "epoch $exp")"
echo "OK: AWS CLI signing key ($EXPECTED_FPR) valid until $when"
