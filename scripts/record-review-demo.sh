#!/bin/zsh
# Grava o vídeo da demonstração para a App Review (fluxo de ReviewDemoUITests) num simulador próprio.
# Uso: scripts/record-review-demo.sh <arquivo com a chave do OpenCode Go> <pasta com os PDFs> <saida.mp4> [simulador]
# Os PDFs vão para "No meu iPhone" (app Arquivos) do simulador; o teste os escolhe pelo seletor de documentos.
# A chave só vai para o ambiente do executor de testes; nunca para o repositório, o app empacotado ou logs.
set -euo pipefail
keyfile=${1:?arquivo com a chave}
pdfs=${2:?pasta com os PDFs}
out=${3:?saida.mp4}
sim=${4:-FJ-demo}
root="$(cd "$(dirname "$0")/.." && pwd)"
dd="${TMPDIR:-/tmp}/fj-demo-dd"
cd "$root"

xcrun simctl list devices | grep -q " $sim (" || xcrun simctl clone "iPhone 18 Pro" "$sim" >/dev/null
xcrun simctl boot "$sim" 2>/dev/null || true
xcrun simctl bootstatus "$sim" -b >/dev/null
xcrun simctl uninstall "$sim" br.com.renatocorrea.fitjourney 2>/dev/null || true
xcrun simctl status_bar "$sim" override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
xcrun simctl ui "$sim" appearance light
local_storage=$(xcrun simctl get_app_container "$sim" com.apple.DocumentsApp groups | awk '/FileProvider.LocalStorage/ {print $2}')
mkdir -p "$local_storage/File Provider Storage"
cp "$pdfs"/*_Workout.pdf "$local_storage/File Provider Storage/"

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
