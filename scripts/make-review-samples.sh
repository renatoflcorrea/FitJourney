#!/bin/zsh
# Gera os exemplos empacotados no app (proposta ai-consent-review §4.2) a partir dos PDFs "APP REVIEW SAMPLE".
# Uso: scripts/make-review-samples.sh <pasta com os PDFs>
set -euo pipefail
src=${1:?pasta com os PDFs}
out="$(cd "$(dirname "$0")/.." && pwd)/FitJourney/Resources/Samples"
mkdir -p "$out"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
convert() { # $1 = PDF de origem, $2 = nome final sem extensão
  pdftoppm -f 1 -l 1 -png -scale-to 2048 "$src/$1" "$tmp/$2"
  local png=$(ls "$tmp/$2"*.png | head -1)
  sips -s format jpeg -s formatOptions 80 -m "/System/Library/ColorSync/Profiles/sRGB Profile.icc" "$png" --out "$out/$2.jpg" >/dev/null
}
convert Chest_and_Biceps_Workout.pdf SampleWorkoutChestBiceps
convert Back_and_Triceps_Workout.pdf SampleWorkoutBackTriceps
convert Leg_Workout.pdf SampleWorkoutLegs
convert Shoulder_Workout.pdf SampleWorkoutShoulders
cp "$src/Meal_Plan.pdf" "$out/SampleMealPlan.pdf"
ls -la "$out"
