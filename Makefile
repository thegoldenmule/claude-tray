APP_NAME      := ClaudeTray
BUILD_DIR     := build
APP_BUNDLE    := $(BUILD_DIR)/$(APP_NAME).app
INSTALL_DIR   := $(HOME)/Applications
INSTALLED_APP := $(INSTALL_DIR)/$(APP_NAME).app
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

# The installed copy is the only one ever launched, so "Launch at login" always points at it.
# The staged bundle is moved (not copied) so no second copy with our bundle ID lingers in
# build/ for Background Task Management to resolve the login item to.
install: app
	mkdir -p "$(INSTALL_DIR)"
	@pkill -x $(APP_NAME) && echo "Quit running $(APP_NAME)"; \
	for i in $$(seq 50); do pgrep -x $(APP_NAME) >/dev/null || break; sleep 0.1; done
	rm -rf "$(INSTALLED_APP)"
	mv "$(APP_BUNDLE)" "$(INSTALLED_APP)"
	@echo "Installed to $(INSTALLED_APP)"

run: install
	open "$(INSTALLED_APP)"

clean:
	rm -rf .build "$(BUILD_DIR)"

dev:
	swift run
