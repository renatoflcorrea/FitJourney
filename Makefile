SCHEME    = FitJourney
DEST      = generic/platform=iOS Simulator
TEST_DEST ?= platform=iOS Simulator,name=iPhone 17 Pro

.PHONY: project build test clean

project:
	xcodegen generate --quiet

build: project
	xcodebuild -project FitJourney.xcodeproj -scheme $(SCHEME) -destination '$(DEST)' CODE_SIGNING_ALLOWED=NO -quiet build

test: project
	xcodebuild -project FitJourney.xcodeproj -scheme $(SCHEME) -destination '$(TEST_DEST)' CODE_SIGNING_ALLOWED=NO -quiet test

clean:
	rm -rf FitJourney.xcodeproj build
