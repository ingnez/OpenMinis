#!/bin/bash
# One simulator, serial execution, unchanged assertions and diagnostic collection.
set -euo pipefail
RESULT_BUNDLE="${RESULT_BUNDLE:-ui-tests.xcresult}"
UI_LOG="${UI_LOG:-ui-tests.log}"
DEFAULT_ONLY_TESTING="MinisUITests/MinisSmokeUITests
MinisUITests/ComposerVoiceButtonUITests
MinisUITests/E2EFlowsUITests
MinisUITests/MiscControlsUITests
MinisUITests/ReplyModeUITests
MinisUITests/DeliverablesUITests
MinisUITests/ImageExperienceUITests
MinisUITests/BotToBotUITests
MinisUITests/GroupChatUITests
MinisUITests/Ideas12UITests
MinisUITests/FrogP0UITests
MinisUITests/Frog1850UITests
MinisUITests/Frog1850Chunk2UITests
MinisUITests/Frog1850Chunk3UITests
MinisUITests/BackupUXUITests"
ONLY_SRC="${ONLY_TESTING:-}"
if [ -z "$(printf '%s' "$ONLY_SRC" | tr -d '[:space:]')" ]; then
  ONLY_SRC="$DEFAULT_ONLY_TESTING"
fi
ONLY_SRC="$(printf '%s' "$ONLY_SRC" | tr ',' $'\n')"
ONLY_FLAGS=()
TEST_SELECTORS=()
while IFS= read -r item; do
  item="${item#"${item%%[![:space:]]*}"}"
  item="${item%"${item##*[![:space:]]}"}"
  [ -z "$item" ] && continue
  case "$item" in
    *[!A-Za-z0-9_./-]*) echo "only_testing 条目不合法：$item" >&2; exit 1 ;;
  esac
  ONLY_FLAGS+=("-only-testing:$item")
  TEST_SELECTORS+=("$item")
done <<EOF
$ONLY_SRC
EOF
if [ ${#ONLY_FLAGS[@]} -eq 0 ]; then
  echo "only_testing 解析后为空" >&2
  exit 1
fi
echo "本次 -only-testing：${ONLY_FLAGS[*]}"
echo "模拟器：$DEV"
# Minis 方案里挂着的 MinisTests 只依赖 MinisTestHost、不依赖 Minis（设计上走 MinisUnitTests 方案、先单独编 App，
# 见 scripts/ios-unit-tests.sh），并行编译时扫描不到 Minis 模块就报「Unable to resolve module dependency: 'Minis'」，
# -only-testing 也挡不住它被编译。这里只在运行机上生成一个不含它的方案跑 UI 流程；单元测试在下一步按它自己的方案跑。
python3 - <<'PY'
import re
d = "src/ios/Minis.xcodeproj/xcshareddata/xcschemes/"
s = open(d + "Minis.xcscheme").read()
s2 = re.sub(r"\s*<TestableReference[^>]*>(?:(?!</TestableReference>).)*?BlueprintName = \"MinisTests\"(?:(?!</TestableReference>).)*?</TestableReference>", "", s, flags=re.S)
assert s2 != s and "MinisUITests" in s2
open(d + "MinisE2E.xcscheme", "w").write(s2)
PY
# 主线程卡死取证：模拟器里的 App 是本机进程，CPU 连续 10 秒占满就 sample 一次调用栈（最多 4 份）
mkdir -p hang-samples
( n=0; hot=0; while [ $n -lt 4 ]; do sleep 2
    pid=$(pgrep -f "/CoreSimulator/Devices/$DEV/data/Containers/Bundle/Application/.*/Minis.app/Minis$" | head -1); [ -z "$pid" ] && { hot=0; continue; }
    cpu=$(ps -o %cpu= -p "$pid" | awk '{print int($1)}'); [ "${cpu:-0}" -ge 90 ] && hot=$((hot+1)) || hot=0
    if [ $hot -ge 5 ]; then n=$((n+1)); hot=0; sample "$pid" 3 -file "hang-samples/hang-$n-$(date +%H%M%S).txt" >/dev/null 2>&1 || true; sleep 20; fi
  done ) >/dev/null 2>&1 &
composer_watch_pid=$!
trap 'kill "$composer_watch_pid" 2>/dev/null || true' EXIT
xcodebuild test \
  -project src/ios/Minis.xcodeproj \
  -scheme MinisE2E \
  -configuration Debug \
  -destination "id=$DEV" \
  -derivedDataPath build \
  -clonedSourcePackagesDirPath "$GITHUB_WORKSPACE/build/SourcePackages" \
  -scmProvider system \
  -disableAutomaticPackageResolution \
  -showBuildTimingSummary \
  "${ONLY_FLAGS[@]}" \
  -collect-test-diagnostics never \
  -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 150 \
  -maximum-test-execution-time-allowance 240 \
  -parallel-testing-enabled NO \
  -retry-tests-on-failure -test-iterations 2 \
  -resultBundlePath "$RESULT_BUNDLE" \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM= 2>&1 | tee "$UI_LOG"

python3 scripts/check_ui_coverage.py "$UI_LOG" "${TEST_SELECTORS[@]}"
