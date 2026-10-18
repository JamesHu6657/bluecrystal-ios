#!/usr/bin/env bash
# 声画融合关着 = f706431（v1.8.3）逐位相同（PR Checks 里跑；本地有 swiftc 就能跑，macOS / Linux 都行）：
# 同一个只用 f706431 已有接口的整条链模拟（声音模式、画面 P1 / P2 / P3 含撞击声相位校正、P4 前瞻），
# 分别和 BASE 的 VisualSync.swift、当前工作区的 VisualSync.swift 编译，输出必须逐字节相同；
# 当前工作区再加 -D AV_FUSION_ON 编一份（融合部件在旁边跟着跑；F1 起才有内容），输出也必须相同（融合只显示、不改输出）；
# 再加 -D AV_FUSION_ON -D AV_F2_ON 编一份（融合开着、「节奏由声音确认」关着，F2 的接线全走一遍），输出也必须相同；
# 再加 -D AV_F2_CONFIRM 编一份（节奏确认开着、耦合强制不成立 = S1），跟随器这条路输出也必须相同；
# -D AV_F3_ON（F3）：重音 / 震动跟声音的接线走一遍、耦合强制不成立（S1），输出也必须相同；
# -D AV_F4_ON（F4）：互为回落 / 相位飞轮接线走一遍（画面一直有新鲜样本、不在 S2），输出也必须相同。
# 用法：Tests/FusionOffCompare/run.sh [BASE]（默认 f706431；CI 的 checkout 要拿到这个提交：fetch-depth: 0）
set -euo pipefail
cd "$(dirname "$0")/../.."
BASE="${1:-f706431}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
git show "$BASE:BlueCrystalIOS/VisualSync.swift" > "$TMP/VisualSync.base.swift"
PURE="BlueCrystalIOS/Protocol.swift BlueCrystalIOS/Models.swift BlueCrystalIOS/SafetyLedger.swift BlueCrystalIOS/AIProgram.swift"
SWIFTC="${SWIFTC:-swiftc}"
if command -v xcrun >/dev/null 2>&1; then SWIFTC="xcrun swiftc"; fi
HARNESS="Tests/FusionOffCompare/LinuxShim.swift Tests/FusionOffCompare/main.swift"
$SWIFTC -O -swift-version 5 $PURE "$TMP/VisualSync.base.swift" $HARNESS -o "$TMP/base" & P1=$!
$SWIFTC -O -swift-version 5 $PURE BlueCrystalIOS/VisualSync.swift $HARNESS -o "$TMP/head" & P2=$!
$SWIFTC -O -swift-version 5 -D AV_FUSION_ON $PURE BlueCrystalIOS/VisualSync.swift $HARNESS -o "$TMP/fusion" & P3=$!
$SWIFTC -O -swift-version 5 -D AV_FUSION_ON -D AV_F2_ON $PURE BlueCrystalIOS/VisualSync.swift $HARNESS -o "$TMP/f2" & P4=$!
$SWIFTC -O -swift-version 5 -D AV_FUSION_ON -D AV_F2_ON -D AV_F2_CONFIRM $PURE BlueCrystalIOS/VisualSync.swift $HARNESS -o "$TMP/f2s1" & P5=$!
$SWIFTC -O -swift-version 5 -D AV_FUSION_ON -D AV_F2_ON -D AV_F3_ON $PURE BlueCrystalIOS/VisualSync.swift $HARNESS -o "$TMP/f3s1" & P6=$!
$SWIFTC -O -swift-version 5 -D AV_FUSION_ON -D AV_F2_ON -D AV_F3_ON -D AV_F4_ON $PURE BlueCrystalIOS/VisualSync.swift $HARNESS -o "$TMP/f4s1" & P7=$!
wait $P1; wait $P2; wait $P3; wait $P4; wait $P5; wait $P6; wait $P7
"$TMP/base" > "$TMP/base.txt"
"$TMP/head" > "$TMP/head.txt"
"$TMP/fusion" > "$TMP/fusion.txt"
"$TMP/f2" > "$TMP/f2.txt"
"$TMP/f2s1" > "$TMP/f2s1.txt"
"$TMP/f3s1" > "$TMP/f3s1.txt" 2> "$TMP/f3s1.err"
"$TMP/f4s1" > "$TMP/f4s1.txt" 2> "$TMP/f4s1.err"
cat "$TMP/f3s1.err" "$TMP/f4s1.err" >&2
sum() { sha256sum "$1" 2>/dev/null | cut -c1-16 || shasum -a 256 "$1" | cut -c1-16; }
status=0
for v in head fusion f2 f2s1 f3s1 f4s1; do
  if cmp -s "$TMP/base.txt" "$TMP/$v.txt"; then
    echo "FusionOffCompare: $v identical ($(wc -l < "$TMP/base.txt") lines, sha256 $(sum "$TMP/base.txt")) vs $BASE"
  else
    echo "FAIL FusionOffCompare: $v DIFFERENT vs $BASE"
    diff "$TMP/base.txt" "$TMP/$v.txt" | head -n 20 || true
    status=1
  fi
done
# 复审 M5 正对照：同样的输入下，真实 S2 / 画面断开时 F3 / F4 必须真能改东西（不然上面的「逐字节相同」证明不了什么）
for tag in f3 f3b f4; do
  n=$(grep -h "^$tag positive control" "$TMP"/f3s1.err "$TMP"/f4s1.err | awk '{s += $NF} END {print s + 0}')
  if [ "$n" -gt 0 ]; then
    echo "FusionOffCompare: $tag positive control changed $n beats (as expected)"
  else
    echo "FAIL FusionOffCompare: $tag positive control changed nothing"
    status=1
  fi
done
exit $status
