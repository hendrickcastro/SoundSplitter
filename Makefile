.PHONY: build release run bundle open dmg clean

# Debug build
build:
	swift build

# Optimized build
release:
	swift build -c release

# Package a signed .app bundle
bundle:
	@bash scripts/bundle.sh release

# Build the bundle and launch it
open: bundle
	open .build/SoundSplitter.app

# Build a distributable .dmg
dmg: bundle
	@bash scripts/make-dmg.sh

# Run straight from SPM (no bundle; menu-bar behavior may be limited)
run:
	swift run

clean:
	swift package clean
	rm -rf .build/SoundSplitter.app
