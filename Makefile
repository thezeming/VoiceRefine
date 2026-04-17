APP_NAME  := VoiceRefine
BUNDLE    := build/$(APP_NAME).app
CONFIG    := release
ARCH      := arm64
SWIFT     := swift

.PHONY: help build bundle run debug-run clean distclean fmt-check

help:
	@echo "VoiceRefine build targets"
	@echo "  make build     — compile (release) via swift build"
	@echo "  make bundle    — build + assemble $(BUNDLE)"
	@echo "  make run       — bundle + open the app"
	@echo "  make debug-run — bundle + launch in foreground with logs"
	@echo "  make clean     — remove ./build"
	@echo "  make distclean — remove ./build and ./.build"

build:
	$(SWIFT) build -c $(CONFIG) --arch $(ARCH)

bundle: build
	@rm -rf $(BUNDLE)
	@mkdir -p $(BUNDLE)/Contents/MacOS
	@mkdir -p $(BUNDLE)/Contents/Resources
	@cp -f Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	@printf 'APPL????' > $(BUNDLE)/Contents/PkgInfo
	@BIN_DIR=$$($(SWIFT) build -c $(CONFIG) --arch $(ARCH) --show-bin-path); \
	  cp -f $$BIN_DIR/$(APP_NAME) $(BUNDLE)/Contents/MacOS/$(APP_NAME); \
	  find $$BIN_DIR -maxdepth 1 -name '*.bundle' -exec cp -R {} $(BUNDLE)/Contents/Resources/ \; 2>/dev/null || true
	@codesign --force --sign - $(BUNDLE) >/dev/null
	@echo "Bundled $(BUNDLE)"

run: bundle
	@open $(BUNDLE)
	@echo "Opened $(BUNDLE). Check the menu bar for the microphone icon."

debug-run: bundle
	@echo "Launching $(BUNDLE) in foreground (Ctrl-C to quit)..."
	@$(BUNDLE)/Contents/MacOS/$(APP_NAME)

clean:
	@rm -rf build

distclean: clean
	@rm -rf .build
