.PHONY: build test bundle install run clean

# Prefer a real Apple Development identity over ad-hoc signing. The Keychain
# "Always Allow" grant is bound to the code signature's designated requirement:
# ad-hoc signing (`-`) mints a new identity every build, so macOS re-prompts
# for Keychain access after each rebuild. A stable dev identity signs the same
# way every time, so the grant survives rebuilds and you're only prompted once.
CODESIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F '"' '/Apple Development/{print $$2; exit}')

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
	IDENT="$(CODESIGN_IDENTITY)"; [ -n "$$IDENT" ] || IDENT="-"; \
	codesign --force --sign "$$IDENT" --identifier com.gordonbeeming.ClaudeBar $(APP_BUNDLE)

install: bundle
	pkill -x ClaudeBar || true
	ditto $(APP_BUNDLE) ~/Applications/ClaudeBar.app
	@echo "Launch with: open ~/Applications/ClaudeBar.app"

run:
	swift run

clean:
	rm -rf .build dist
