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

devices=$(xcrun simctl list devices)
udid=$(print -r -- "$devices" | awk -v n="$sim" '$0 ~ "^ +"n" \\(" {gsub(/[()]/,"",$2); print $2; exit}')
[[ -n "$udid" ]] || udid=$(xcrun simctl clone "iPhone 18 Pro" "$sim")
sim=$udid
xcrun simctl boot "$sim" 2>/dev/null || true
xcrun simctl bootstatus "$sim" -b >/dev/null
xcrun simctl uninstall "$sim" br.com.renatocorrea.fitjourney 2>/dev/null || true
xcrun simctl status_bar "$sim" override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
xcrun simctl ui "$sim" appearance light
local_storage=$(xcrun simctl get_app_container "$sim" com.apple.DocumentsApp groups | awk '/FileProvider.LocalStorage/ {print $2}')
mkdir -p "$local_storage/File Provider Storage"
cp "$pdfs"/*_Workout.pdf "$local_storage/File Provider Storage/"

xcodegen generate --quiet
xcodebuild -project FitJourney.xcodeproj -scheme FitJourneyUITests -destination "platform=iOS Simulator,id=$sim" \
  -derivedDataPath "$dd" CODE_SIGNING_ALLOWED=NO -quiet build-for-testing

# O Xcode grava a tela de cada teste de UI no .xcresult (um segundo gravador com simctl é interrompido).
results="$dd/review-demo.xcresult"
rm -rf "$results"
set +e
TEST_RUNNER_FJ_OPENCODE_KEY="$(cat "$keyfile")" xcodebuild -project FitJourney.xcodeproj -scheme FitJourneyUITests \
  -destination "platform=iOS Simulator,id=$sim" -derivedDataPath "$dd" CODE_SIGNING_ALLOWED=NO -collect-test-diagnostics never \
  -resultBundlePath "$results" -only-testing:FitJourneyUITests/ReviewDemoUITests/testReviewDemoFlow test-without-building 2>&1 \
  | grep -v -i 'opencode_key' | grep -E 'Test Case|error:|Executed|failed' | tail -20
rc=${pipestatus[1]}
set -e
attachments=$(mktemp -d)
xcrun xcresulttool export attachments --path "$results" --output-path "$attachments" >/dev/null
video=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(next((a['exportedFileName'] for t in d for a in t.get('attachments',[]) if a['exportedFileName'].endswith('.mp4')), ''))" "$attachments/manifest.json")
[[ -n "$video" ]] && cp "$attachments/$video" "$out"
rm -rf "$attachments"
xcrun simctl status_bar "$sim" clear
xcrun simctl shutdown "$sim"
echo "vídeo: $out (teste: $rc)"
exit $rc
