APP    := Wakey.app
BIN    := $(APP)/Contents/MacOS/Wakey
PLIST  := Resources/Info.plist
ICON   := Resources/AppIcon.icns
SRC    := $(wildcard Sources/Wakey/*.swift)
MODCACHE := .cache/modules

# A stable signing identity keeps the Accessibility grant (TV media keys and macro keys) across
# rebuilds. Fall back to ad-hoc on machines without an Apple Development certificate; in that case
# macOS ties the grant to the binary and it has to be re-enabled after every rebuild.
SIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null \
	| sed -n 's/.*"\(.*\)"/\1/p' \
	| grep -E '^(Apple Development|Developer ID Application):' \
	| head -1)
SIGN_ARG := $(if $(SIGN_IDENTITY),"$(SIGN_IDENTITY)",-)

# Note: we drive swiftc directly rather than `swift build`. SwiftPM's build system
# needs to write outside the workspace (and uses sandbox-exec), which is blocked in
# sandboxed environments. Package.swift is kept for opening the project in Xcode.
.PHONY: app install run clean status icon

# There is deliberately no compile-only target: every build also refreshes the installed copy.
app: $(BIN) $(APP)/Contents/Resources/AppIcon.icns
	@rm -rf /Applications/$(APP)
	@cp -R $(APP) /Applications/
	@echo "built and installed $(APP) — /Applications/$(APP) is current"

$(BIN): $(SRC) $(PLIST) Makefile
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources $(MODCACHE)
	swiftc -O -parse-as-library -target $(shell uname -m)-apple-macos14.0 \
		-module-cache-path $(MODCACHE) \
		-o $(BIN) $(SRC)
	cp $(PLIST) $(APP)/Contents/Info.plist
	codesign --force --sign $(SIGN_ARG) --identifier nl.sortedbits.wakey $(APP)

$(APP)/Contents/Resources/AppIcon.icns: $(ICON)
	mkdir -p $(APP)/Contents/Resources
	cp $(ICON) $@

icon: $(ICON)

# iconutil's atomic write is rejected inside this workspace, so stage via a temp file.
$(ICON): tools/make-icon.swift
	swift tools/make-icon.swift Resources
	@staging=$$(mktemp -d)/AppIcon.icns; \
	iconutil -c icns Resources/AppIcon.iconset -o "$$staging" && cp "$$staging" $(ICON)

install: app

run: app
	open /Applications/$(APP)

status: app
	$(BIN) --status

selftest: app
	$(BIN) --selftest

clean:
	rm -rf $(APP) .cache Resources/AppIcon.iconset
