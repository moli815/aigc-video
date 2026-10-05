#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
command -v swift >/dev/null || { echo "需要 Swift 工具链" >&2; exit 1; }
command -v xcodebuild >/dev/null || { echo "iOS 测试需要 macOS + Xcode" >&2; exit 1; }
command -v xcodegen >/dev/null || { echo "请先在 Mac 安装 XcodeGen" >&2; exit 1; }
run_dir="TestArtifacts/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$run_dir"
swift test -c release 2>&1 | tee "$run_dir/swift-core.log"
xcodegen generate
sim_id="$(python3 - <<'PY'
import json,subprocess
devices=json.loads(subprocess.check_output(['xcrun','simctl','list','devices','available','--json']))['devices']
candidates=[d for r,ds in devices.items() if 'iOS' in r for d in ds if d['name'].startswith('iPad') and d.get('isAvailable',True)]
if not candidates: raise SystemExit('需要已安装的 iPad 模拟器')
print(candidates[0]['udid'])
PY
)"
xcodebuild -project BossAI.xcodeproj -scheme BossAI -configuration Release \
  -destination "platform=iOS Simulator,id=$sim_id" \
  -resultBundlePath "$run_dir/ios-tests.xcresult" CODE_SIGNING_ALLOWED=NO test \
  2>&1 | tee "$run_dir/ios-tests.log"
echo "结果目录：$run_dir"
