#!/bin/zsh
# Capturas cruas do relógio (Apple Watch Ultra 3 49mm, 422x514) para a App Store. Só DEBUG: harness `-FJWScene` + `-FJWStore`.
# Uso: scripts/store-watch-screens.sh <udid-do-relógio> <en|pt|all>
# Pré-requisito: xcodebuild -scheme FitJourneyWatch -destination 'platform=watchOS Simulator,name=<seu>' -derivedDataPath build/store-watch build
set -eu
UDID=$1; LANGS=${2:-all}
ROOT=${0:A:h:h}
APP=$ROOT/build/store-watch/Build/Products/Debug-watchsimulator/FitJourneyWatch.app
BUNDLE=br.com.renatocorrea.fitjourney.watchkitapp
OUT=$ROOT/work/store/raw
mkdir -p $OUT
typeset -A SCENES; SCENES=(w1-set series w2-rest rest w3-metrics metrics)
for lang in en pt; do
  [ $LANGS = all -o $LANGS = $lang ] || continue
  if [ $lang = en ]; then locale="(en)"; lcode=en_US; else locale="(pt-BR)"; lcode=pt_BR; fi
  for slug in w1-set w2-rest w3-metrics; do
    xcrun simctl terminate $UDID $BUNDLE 2>/dev/null || true
    xcrun simctl uninstall $UDID $BUNDLE 2>/dev/null || true
    xcrun simctl install $UDID $APP
    xcrun simctl launch $UDID $BUNDLE -FJWStore -FJWScene $SCENES[$slug] -AppleLanguages "$locale" -AppleLocale $lcode >/dev/null
    sleep 5
    xcrun simctl io $UDID screenshot --type=png $OUT/$lang-$slug.png >/dev/null 2>&1
    echo $OUT/$lang-$slug.png
  done
done
