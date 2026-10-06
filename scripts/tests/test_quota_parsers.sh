#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
fixtures="$repo/scripts/tests/fixtures/quota"
[ -d "$fixtures" ] || { echo "夹具目录不存在：$fixtures" >&2; exit 2; }
mkdir -p "$repo/menubar/.build"
scratch="$(mktemp -d "$repo/menubar/.build/quota-tests.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
swiftc "$repo/menubar/Sources/CCPodMenuBar/QuotaAdapters.swift" \
  "$repo/menubar/Sources/CCPodMenuBar/ACS3Signer.swift" \
  "$repo/scripts/tests/quota_parsers.swift" -o "$scratch/check"
"$scratch/check" "$fixtures"
