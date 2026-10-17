#!/usr/bin/env bash
# P4 关着 = main 的跨版本对照（不在 PR Checks 里跑；本地有 swiftc 就能跑，macOS / Linux 都行）：
# 同一个只用 main 已有接口的整条链模拟（取帧分析 → 归一化 → 平滑 → 频率跟随 → 相位锁 → 子拍脉动 → 出口，含 P1 / P2 / P3 三组），
# 分别和 BASE（默认 origin/main）的 VisualSync.swift、当前工作区的 VisualSync.swift 编译，输出必须逐字节相同。
# 用法：Tests/P4OffCompare/run.sh [BASE]
set -euo pipefail
cd "$(dirname "$0")/../.."
BASE="${1:-origin/main}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
git show "$BASE:BlueCrystalIOS/VisualSync.swift" > "$TMP/VisualSync.base.swift"
PURE="BlueCrystalIOS/Protocol.swift BlueCrystalIOS/Models.swift BlueCrystalIOS/SafetyLedger.swift BlueCrystalIOS/AIProgram.swift"
SWIFTC="${SWIFTC:-swiftc}"
if command -v xcrun >/dev/null 2>&1; then SWIFTC="xcrun swiftc"; fi
$SWIFTC -O -swift-version 5 $PURE "$TMP/VisualSync.base.swift" Tests/P4OffCompare/LinuxShim.swift Tests/P4OffCompare/main.swift -o "$TMP/base"
$SWIFTC -O -swift-version 5 $PURE BlueCrystalIOS/VisualSync.swift Tests/P4OffCompare/LinuxShim.swift Tests/P4OffCompare/main.swift -o "$TMP/head"
"$TMP/base" > "$TMP/base.txt"
"$TMP/head" > "$TMP/head.txt"
if cmp -s "$TMP/base.txt" "$TMP/head.txt"; then
  echo "P4OffCompare: identical ($(wc -l < "$TMP/base.txt") lines, sha256 $(sha256sum "$TMP/base.txt" 2>/dev/null | cut -c1-16 || shasum -a 256 "$TMP/base.txt" | cut -c1-16)) vs $BASE"
else
  echo "P4OffCompare: DIFFERENT vs $BASE"
  diff "$TMP/base.txt" "$TMP/head.txt" | head -n 20
  exit 1
fi
