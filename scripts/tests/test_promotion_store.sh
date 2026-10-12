#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
mkdir -p "$repo/menubar/.build"
scratch="$(mktemp -d "$repo/menubar/.build/promotion-store-tests.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
# 🔴 源文件显式点名，不许通配：同目录下 50 个 .swift 大量依赖 SwiftUI，
# 独立编译必炸。SecretResolver.swift 只 import Foundation，实测可独立编译。
swiftc "$repo/menubar/Sources/CCPodMenuBar/SecretResolver.swift" \
  "$repo/menubar/Sources/CCPodMenuBar/PromotionRadar.swift" \
  "$repo/scripts/tests/promotion_store.swift" -o "$scratch/check"
"$scratch/check"
