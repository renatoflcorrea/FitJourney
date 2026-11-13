#!/bin/zsh
# Capturas cruas para a ficha da App Store (iPhone 17 Pro Max, 1320x2868). Só DEBUG: usa os ganchos de StoreDemo.
# Uso: scripts/store-screens.sh <udid-do-simulador> <en|pt|all> [slug ...]
#   slugs: 01-today 02-session 03-heart 04-progress 05-diet 06-ai 07-health 08-training
# Pré-requisito: build DEBUG em build/store (xcodebuild ... -derivedDataPath build/store) e simulador ligado.
set -eu
UDID=$1; LANGS=${2:-all}; shift 2 || true
ROOT=${0:A:h:h}
APP=$ROOT/build/store/Build/Products/Debug-iphonesimulator/FitJourney.app
BUNDLE=br.com.renatocorrea.fitjourney
OUT=$ROOT/work/store/raw
mkdir -p $OUT
SLUGS=("$@"); [ ${#SLUGS[@]} -gt 0 ] || SLUGS=(01-today 02-session 03-heart 04-progress 05-diet 06-ai 07-health 08-training)

xcrun simctl status_bar $UDID override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
xcrun simctl ui $UDID appearance light

args_for() {
  case $1 in
    01-today)   echo "" ;;
    02-session) echo "-fj.startTab training -fj.sessionDemo mid" ;;
    03-heart)   echo "-fj.startTab training -fj.demoRoute workout -fj.demoScrollY 470" ;;
    04-progress) echo "-fj.startTab training -fj.demoRoute progress" ;;
    05-diet)    echo "-fj.startTab nutrition -fj.demoScrollY 120" ;;
    06-ai)      echo "-fj.startTab coach -fj.demoRoute chat" ;;
    07-health)  echo "-fj.startTab health" ;;
    08-training) echo "-fj.startTab training" ;;
  esac
}

shot() { # lang slug
  local lang=$1 slug=$2 locale lcode
  if [ $lang = en ]; then locale="(en)"; lcode=en_US; else locale="(pt-BR)"; lcode=pt_BR; fi
  xcrun simctl terminate $UDID $BUNDLE 2>/dev/null || true
  xcrun simctl uninstall $UDID $BUNDLE 2>/dev/null || true
  xcrun simctl install $UDID $APP
  xcrun simctl launch $UDID $BUNDLE -fj.seedDemo YES -AppleLanguages "$locale" -AppleLocale $lcode ${=$(args_for $slug)} >/dev/null
  local wait=11
  sleep $wait
  xcrun simctl io $UDID screenshot --type=png $OUT/$lang-$slug.png >/dev/null
  echo "$OUT/$lang-$slug.png"
}

for lang in en pt; do
  [ $LANGS = all -o $LANGS = $lang ] || continue
  for slug in $SLUGS; do shot $lang $slug; done
done
