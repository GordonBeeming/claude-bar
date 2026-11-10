.PHONY: build test bundle install run clean

# Prefer a real Apple Development identity over ad-hoc signing. The Keychain
# "Always Allow" grant is bound to the code signature's designated requirement:
# ad-hoc signing (`-`) mints a new identity every build, so macOS re-prompts
# for Keychain access after each rebuild. A stable dev identity signs the same
# way every time, so the grant survives rebuilds and you're only prompted once.
CODESIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F '"' '/Apple Development/{print $$2; exit}')

BUILD ?= 1
# CI passes VERSION (and BUILD) for a release. Without it this is a local build: the version is
# the last tag, and the display string says so and names the commit, so a dev build can't pass
# for a release.
ifeq ($(origin VERSION),undefined)
VERSION := $(or $(shell git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//'),0.0)
DISPLAY_VERSION := $(VERSION)-dev ($(or $(shell git rev-parse --short HEAD 2>/dev/null),unknown))
else
DISPLAY_VERSION := $(VERSION) ($(BUILD))
endif
CODESIGN_OPTS ?=

# Install over the Homebrew cask's location so a local dev build replaces the
# installed app instead of creating a second copy. A later `brew upgrade`
# cleanly overwrites the dev build with the real signed release.
INSTALL_DIR ?= /Applications

APP_BUNDLE := dist/ClaudeBar.app

build:
	swift build -c release

test:
	swift test

bundle: build
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS $(APP_BUNDLE)/Contents/Resources
	cp .build/release/ClaudeBar $(APP_BUNDLE)/Contents/MacOS/
	cp Packaging/Info.plist $(APP_BUNDLE)/Contents/Info.plist
	cp Packaging/AppIcon.icns $(APP_BUNDLE)/Contents/Resources/
	/usr/libexec/PlistBuddy \
		-c "Set :CFBundleShortVersionString $(VERSION)" \
		-c "Set :CFBundleVersion $(VERSION).$(BUILD)" \
		-c "Add :GBDisplayVersion string $(DISPLAY_VERSION)" \
		$(APP_BUNDLE)/Contents/Info.plist
	IDENT="$(CODESIGN_IDENTITY)"; [ -n "$$IDENT" ] || IDENT="-"; \
	codesign --force --sign "$$IDENT" --identifier com.gordonbeeming.ClaudeBar $(CODESIGN_OPTS) $(APP_BUNDLE)

install: bundle
	pkill -x ClaudeBar || true
	ditto $(APP_BUNDLE) $(INSTALL_DIR)/ClaudeBar.app
	rm -rf dist
	@echo "Launch with: open $(INSTALL_DIR)/ClaudeBar.app"

run:
	swift run

clean:
	rm -rf .build dist
