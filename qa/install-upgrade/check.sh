#!/usr/bin/env bash
# Run on a disposable macOS runner with XcodeGen and an available iPad simulator.
set -euo pipefail
root="$(git rev-parse --show-toplevel)"
case "${1:-november}" in
  november) prior=2c35b867879c9d728443bc781ec1fe01cc124666 ;;
  october) prior=04cd082467663023f154cf27a08d18124ea0d09f ;;
  *) echo "Unsupported baseline" >&2; exit 2 ;;
esac
scratch="$(mktemp -d)"
udid="$(xcrun simctl list devices available -j | python3 -c 'import sys,json; print(next(d["udid"] for ds in json.load(sys.stdin)["devices"].values() for d in ds if d.get("isAvailable") and "iPad" in d["name"]))')"
xcrun simctl bootstatus "$udid" -b
if xcrun simctl get_app_container "$udid" com.bossai.app data >/dev/null 2>&1; then
  echo "Select a fresh runner with an empty simulator." >&2
  exit 1
fi
git fetch --no-tags --depth=1 origin "$prior"
git worktree add --detach "$scratch/old" "$prior"
git worktree add --detach "$scratch/candidate" HEAD
run_checks() {
  local checkout="$1" test_name="$2"
  (
    cd "$checkout"
    cp "$root/qa/install-upgrade/InstallUpgradeStoreTests.swift" Tests/BossAIiOSTests/
    cp "$root/qa/install-upgrade/InstallUpgradeLoginTests.swift" Tests/BossAIUITests/
    xcodegen generate
    xcodebuild test -project BossAI.xcodeproj -scheme BossAI \
      -destination "id=$udid" -parallel-testing-enabled NO \
      -derivedDataPath "$checkout/build" -resultBundlePath "$checkout/results.xcresult" \
      "-only-testing:BossAITests/InstallUpgradeStoreTests/$test_name" \
      -only-testing:BossAIUITests/InstallUpgradeLoginTests/testNormalLaunchOpensMemberLogin \
      CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO >"$checkout/test.log" 2>&1 || {
        tail -100 "$checkout/test.log"; exit 1;
      }
    # Require an actual pass for each requested case, including time spent in the app.
    for name in "$test_name" testNormalLaunchOpensMemberLogin; do
      grep -E "Test Case .*${name}.* passed" "$checkout/test.log"
    done
  )
}
run_checks "$scratch/old" testOldReleaseWritesOfflineData
run_checks "$scratch/candidate" testCandidateReadsOldReleaseData
