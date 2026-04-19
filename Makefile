APP_NAME       := VoiceRefine
BUNDLE         := build/$(APP_NAME).app
CONFIG         := release
ARCH           := arm64
SWIFT          := swift
# Stable self-signed identity — keeps the TCC (Accessibility, Microphone)
# designated-requirement match stable across rebuilds, so dev grants
# survive. See `make setup-signing` for the one-time cert creation.
SIGN_IDENTITY  := VoiceRefine Dev

.PHONY: help build bundle run debug-run clean distclean fmt-check setup-signing

help:
	@echo "VoiceRefine build targets"
	@echo "  make build     — compile (release) via swift build"
	@echo "  make bundle    — build + assemble $(BUNDLE)"
	@echo "  make run       — bundle + open the app"
	@echo "  make debug-run — bundle + launch in foreground with logs"
	@echo "  make setup-signing — one-time: create stable self-signed code-signing identity"
	@echo "  make clean     — remove ./build"
	@echo "  make distclean — remove ./build and ./.build"

build:
	$(SWIFT) build -c $(CONFIG) --arch $(ARCH)

bundle: build
	@rm -rf $(BUNDLE)
	@mkdir -p $(BUNDLE)/Contents/MacOS
	@mkdir -p $(BUNDLE)/Contents/Resources
	@cp -f Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	@cp -f Resources/AppIcon.icns $(BUNDLE)/Contents/Resources/AppIcon.icns
	@printf 'APPL????' > $(BUNDLE)/Contents/PkgInfo
	@BIN_DIR=$$($(SWIFT) build -c $(CONFIG) --arch $(ARCH) --show-bin-path); \
	  cp -f $$BIN_DIR/$(APP_NAME) $(BUNDLE)/Contents/MacOS/$(APP_NAME); \
	  find $$BIN_DIR -maxdepth 1 -name '*.bundle' -exec cp -R {} $(BUNDLE)/Contents/Resources/ \; 2>/dev/null || true
	@codesign --force --sign "$(SIGN_IDENTITY)" $(BUNDLE) >/dev/null || \
	 (echo "codesign failed with identity '$(SIGN_IDENTITY)' — run 'make setup-signing' to create it, or set SIGN_IDENTITY=- for ad-hoc." >&2; exit 1)
	@echo "Bundled $(BUNDLE)"

run: bundle
	@open $(BUNDLE)
	@echo "Opened $(BUNDLE). Check the menu bar for the microphone icon."

debug-run: bundle
	@echo "Launching $(BUNDLE) in foreground (Ctrl-C to quit)..."
	@$(BUNDLE)/Contents/MacOS/$(APP_NAME)

setup-signing:
	@./scripts/setup-signing.sh "$(SIGN_IDENTITY)"

clean:
	@rm -rf build

distclean: clean
	@rm -rf .build
