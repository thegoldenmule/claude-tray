APP_NAME      := ClaudeTray
BUILD_DIR     := build
APP_BUNDLE    := $(BUILD_DIR)/$(APP_NAME).app
INSTALL_DIR   := $(HOME)/Applications
INFO_PLIST    := Resources/Info.plist

# First "Apple Development" identity (by SHA-1, so duplicate names aren't ambiguous);
# falls back to ad-hoc signing ("-"). Override: make app SIGN_IDENTITY="Developer ID Application: ..."
ifeq ($(origin SIGN_IDENTITY),undefined)
SIGN_IDENTITY := $(shell security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development/ { print $$2; exit }')
endif
ifeq ($(strip $(SIGN_IDENTITY)),)
override SIGN_IDENTITY := -
endif

.PHONY: build app run install clean dev

build:
	swift build -c release

app: build
	@BIN_DIR="$$(swift build -c release --show-bin-path)"; \
	rm -rf "$(APP_BUNDLE)"; \
	mkdir -p "$(APP_BUNDLE)/Contents/MacOS"; \
	cp "$$BIN_DIR/$(APP_NAME)" "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)"; \
	cp "$(INFO_PLIST)" "$(APP_BUNDLE)/Contents/Info.plist"
	codesign --force --options runtime --timestamp=none -s "$(SIGN_IDENTITY)" "$(APP_BUNDLE)"
	@echo "Built $(APP_BUNDLE) (signed with: $(SIGN_IDENTITY))"

run: app
	pkill -x $(APP_NAME) || true
	open "$(APP_BUNDLE)"

install: app
	mkdir -p "$(INSTALL_DIR)"
	pkill -x $(APP_NAME) || true
	rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	cp -R "$(APP_BUNDLE)" "$(INSTALL_DIR)/$(APP_NAME).app"
	@echo "Installed to $(INSTALL_DIR)/$(APP_NAME).app"

clean:
	rm -rf .build "$(BUILD_DIR)"

dev:
	swift run
