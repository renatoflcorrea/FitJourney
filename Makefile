SCHEME    = FitJourney
DEST      = generic/platform=iOS Simulator
TEST_DEST ?= platform=iOS Simulator,name=iPhone 17 Pro

.PHONY: project build test clean watch-build watch-test device

project:
	xcodegen generate --quiet

build: project
	xcodebuild -project FitJourney.xcodeproj -scheme $(SCHEME) -destination '$(DEST)' CODE_SIGNING_ALLOWED=NO -quiet build

test: project
	xcodebuild -project FitJourney.xcodeproj -scheme $(SCHEME) -destination '$(TEST_DEST)' CODE_SIGNING_ALLOWED=NO -quiet test

WATCH_TEST_DEST ?= platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)

watch-build: project
	xcodebuild -project FitJourney.xcodeproj -scheme FitJourneyWatch -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO -quiet build

watch-test: project
	xcodebuild -project FitJourney.xcodeproj -scheme FitJourneyWatch -destination '$(WATCH_TEST_DEST)' CODE_SIGNING_ALLOWED=NO -quiet test

clean:
	rm -rf FitJourney.xcodeproj build

# Aparelho real (Team não é versionado): make device TEAM=XXXXXXXXXX [DEVICE_ID=<udid do iPhone>] [WATCH_ID=<udid do relógio>]
TEAM ?=
DEVICE_ID ?=
WATCH_ID ?=
device: project
	@test -n "$(TEAM)" || (echo "Informe TEAM=<Team ID>" && exit 1)
	xcodebuild -project FitJourney.xcodeproj -scheme $(SCHEME) -destination 'generic/platform=iOS' \
	  -configuration Debug DEVELOPMENT_TEAM=$(TEAM) CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates \
	  -derivedDataPath build/device build
	@if [ -n "$(DEVICE_ID)" ]; then \
	  xcrun devicectl device install app --device $(DEVICE_ID) build/device/Build/Products/Debug-iphoneos/FitJourney.app && \
	  xcrun devicectl device process launch --device $(DEVICE_ID) br.com.renatocorrea.fitjourney; \
	  if [ -n "$(WATCH_ID)" ]; then xcrun devicectl device install app --device $(WATCH_ID) build/device/Build/Products/Debug-watchos/FitJourneyWatch.app; fi; \
	else echo "Build pronto em build/device. Para instalar: make device TEAM=$(TEAM) DEVICE_ID=<udid> (xcrun devicectl list devices)"; fi
