SCHEME    = FitJourney
DEST      = generic/platform=iOS Simulator
TEST_DEST ?= platform=iOS Simulator,name=iPhone 17 Pro

.PHONY: project build test clean watch-build watch-test

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
