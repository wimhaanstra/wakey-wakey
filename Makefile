APP    := Wakey.app
BIN    := $(APP)/Contents/MacOS/Wakey
PLIST  := Resources/Info.plist
ICON   := Resources/AppIcon.icns
SRC    := $(wildcard Sources/Wakey/*.swift)
MODCACHE := .cache/modules

# Note: we drive swiftc directly rather than `swift build`. SwiftPM's build system
# needs to write outside the workspace (and uses sandbox-exec), which is blocked in
# sandboxed environments. Package.swift is kept for opening the project in Xcode.
.PHONY: app run clean status icon install

app: $(BIN) $(APP)/Contents/Resources/AppIcon.icns
	@echo "built $(APP) — launch with: open $(APP)"

$(BIN): $(SRC) $(PLIST) Makefile
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources $(MODCACHE)
	swiftc -O -parse-as-library -target $(shell uname -m)-apple-macos14.0 \
		-module-cache-path $(MODCACHE) \
		-o $(BIN) $(SRC)
	cp $(PLIST) $(APP)/Contents/Info.plist
	codesign --force --sign - --identifier nl.sortedbits.wakey $(APP)

$(APP)/Contents/Resources/AppIcon.icns: $(ICON)
	mkdir -p $(APP)/Contents/Resources
	cp $(ICON) $@

icon: $(ICON)

# iconutil's atomic write is rejected inside this workspace, so stage via a temp file.
$(ICON): tools/make-icon.swift
	swift tools/make-icon.swift Resources
	@staging=$$(mktemp -d)/AppIcon.icns; \
	iconutil -c icns Resources/AppIcon.iconset -o "$$staging" && cp "$$staging" $(ICON)

run: app
	open $(APP)

status: app
	$(BIN) --status

selftest: app
	$(BIN) --selftest

install: app
	rm -rf /Applications/$(APP)
	cp -R $(APP) /Applications/
	@echo "installed /Applications/$(APP) — open it from there, then enable 'Start Wakey at login'"

clean:
	rm -rf $(APP) .cache Resources/AppIcon.iconset
