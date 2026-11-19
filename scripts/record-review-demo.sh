#!/bin/zsh
# Grava o vídeo da demonstração para a App Review (fluxo de ReviewDemoUITests) num simulador próprio.
# Uso: scripts/record-review-demo.sh <arquivo com a chave do OpenCode Go> <saida.mp4> [simulador]
# A chave só vai para o ambiente do executor de testes; nunca para o repositório, o app empacotado ou logs.
set -euo pipefail
keyfile=${1:?arquivo com a chave}
out=${2:?saida.mp4}
sim=${3:-FJ-demo}
root="$(cd "$(dirname "$0")/.." && pwd)"
dd="${TMPDIR:-/tmp}/fj-demo-dd"
cd "$root"

xcrun simctl list devices | grep -q " $sim (" || xcrun simctl clone "iPhone 18 Pro" "$sim" >/dev/null
xcrun simctl boot "$sim" 2>/dev/null || true
xcrun simctl bootstatus "$sim" -b >/dev/null
xcrun simctl uninstall "$sim" br.com.renatocorrea.fitjourney 2>/dev/null || true
xcrun simctl status_bar "$sim" override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
xcrun simctl ui "$sim" appearance light

xcodegen generate --quiet
xcodebuild -project FitJourney.xcodeproj -scheme FitJourneyUITests -destination "platform=iOS Simulator,name=$sim" \
  -derivedDataPath "$dd" CODE_SIGNING_ALLOWED=NO -quiet build-for-testing

xcrun simctl io "$sim" recordVideo --codec h264 --force "$out" &
rec=$!
sleep 2
set +e
TEST_RUNNER_FJ_OPENCODE_KEY="$(cat "$keyfile")" xcodebuild -project FitJourney.xcodeproj -scheme FitJourneyUITests \
  -destination "platform=iOS Simulator,name=$sim" -derivedDataPath "$dd" CODE_SIGNING_ALLOWED=NO \
  -only-testing:FitJourneyUITests/ReviewDemoUITests/testReviewDemoFlow test-without-building 2>&1 | grep -v -i 'opencode_key' | tail -20
status=${pipestatus[1]}
set -e
sleep 1
kill -INT $rec; wait $rec 2>/dev/null || true
xcrun simctl status_bar "$sim" clear
xcrun simctl shutdown "$sim"
echo "vídeo: $out (teste: $status)"
exit $status
