CC ?= gcc
CFLAGS ?= -O2 -Wall

# Toolchain runner detection: use mise if available, otherwise direct execution
MISE ?= $(shell command -v mise >/dev/null 2>&1 && echo "mise exec --")

HOST_DIR = host
BUILD_DIR = build
DIST_DIR = dist
BIN_DIR = bin

APP_NAME = LUCY+OSKO
BIN_NAME = lucy-osko

UNAME_S := $(shell uname -s)
HOST_ARCH := $(shell uname -m)

# Skred audio engine version defined in SKRED_VERSION file
SKRED_VERSION ?= $(shell cat SKRED_VERSION 2>/dev/null || echo "0.79.1")

TARGET = $(BIN_DIR)/$(BIN_NAME)

SKRED_INC = -I$(HOST_DIR)/vendor/skred/include -I$(HOST_DIR)/vendor/skred/include/skred
WEBVIEW_INC = -I$(HOST_DIR)/vendor/webview
SKRED_LIB = $(HOST_DIR)/vendor/skred/lib/libapi.a
WASM_ASSETS = $(DIST_DIR)/skred_api.wasm $(DIST_DIR)/skred_api.js

ifeq ($(UNAME_S),Darwin)
HOST_CFLAGS = -ObjC -DWEBVIEW_COCOA=1 -DOBJC_OLD_DISPATCH_PROTOTYPES=1
HOST_LIBS = -framework WebKit -framework CoreFoundation -framework CoreAudio -framework CoreMIDI -lpthread -lm
else
GTK_CFLAGS = $(shell pkg-config --cflags gtk+-3.0 webkit2gtk-4.0 2>/dev/null || pkg-config --cflags gtk+-3.0 webkit2gtk-4.1 2>/dev/null)
GTK_LIBS = $(shell pkg-config --libs gtk+-3.0 webkit2gtk-4.0 alsa 2>/dev/null || pkg-config --libs gtk+-3.0 webkit2gtk-4.1 alsa 2>/dev/null) -lm -lpthread -ldl
HOST_CFLAGS = -DWEBVIEW_GTK=1 $(GTK_CFLAGS)
HOST_LIBS = $(GTK_LIBS)
endif

.PHONY: all build frontend desktop host web fetch-skred linux-package macos-package web-package packages run dev serve clean format

all: build

build: desktop web

# Fetch Skred engine release assets (native static lib, headers, WASM) from GitHub Releases
fetch-skred:
	python3 scripts/fetch_skred.py --version $(SKRED_VERSION)

$(SKRED_LIB) $(WASM_ASSETS):
	python3 scripts/fetch_skred.py --version $(SKRED_VERSION)

# 1. Compile Gleam frontend and bundle to dist/
frontend:
	@if [ -n "$(MISE)" ]; then \
		$(MISE) gleam build --target javascript && \
		mkdir -p $(DIST_DIR) && \
		cp src/entry.mjs build/dev/javascript/lucy_osko/entry.mjs && \
		$(MISE) npx --yes esbuild build/dev/javascript/lucy_osko/entry.mjs --bundle --minify --format=iife --outfile=$(DIST_DIR)/app.min.js; \
	elif command -v gleam >/dev/null 2>&1; then \
		gleam build --target javascript && \
		mkdir -p $(DIST_DIR) && \
		cp src/entry.mjs build/dev/javascript/lucy_osko/entry.mjs && \
		npx --yes esbuild build/dev/javascript/lucy_osko/entry.mjs --bundle --minify --format=iife --outfile=$(DIST_DIR)/app.min.js; \
	elif [ -f "$(DIST_DIR)/app.min.js" ]; then \
		echo "Notice: Using pre-built $(DIST_DIR)/app.min.js (neither mise nor gleam found)"; \
	else \
		echo "Error: Neither mise nor gleam found, and $(DIST_DIR)/app.min.js does not exist." >&2; \
		echo "Please install mise (https://mise.jdx.dev) or gleam." >&2; \
		exit 1; \
	fi

# 2. Compile native C webview host (Desktop target)
desktop: frontend host

host: $(TARGET)

$(TARGET): $(HOST_DIR)/main.c $(SKRED_LIB)
	@mkdir -p $(BIN_DIR)
	$(CC) $(CFLAGS) $(HOST_CFLAGS) $(SKRED_INC) $(WEBVIEW_INC) \
		$< $(SKRED_LIB) $(HOST_LIBS) -o $@

# 3. Web target: Bundle frontend and ensure WASM audio engine assets exist
web: frontend $(WASM_ASSETS)
	@echo "Web distribution ready in $(DIST_DIR)/"

# Packaging targets
linux-package: desktop web
	@mkdir -p $(DIST_DIR)
	@rm -rf $(DIST_DIR)/$(BIN_NAME)-linux-$(HOST_ARCH)
	@mkdir -p $(DIST_DIR)/$(BIN_NAME)-linux-$(HOST_ARCH)
	cp $(TARGET) $(DIST_DIR)/$(BIN_NAME)-linux-$(HOST_ARCH)/
	cp -r $(DIST_DIR)/index.html $(DIST_DIR)/app.min.js $(DIST_DIR)/skred_api.* $(DIST_DIR)/$(BIN_NAME)-linux-$(HOST_ARCH)/
	cp packaging/linux/lucy-osko.desktop $(DIST_DIR)/$(BIN_NAME)-linux-$(HOST_ARCH)/LUCY+OSKO.desktop 2>/dev/null || true
	cp packaging/linux/lucy-osko.desktop $(DIST_DIR)/$(BIN_NAME)-linux-$(HOST_ARCH)/ 2>/dev/null || true
	cp packaging/linux/lucy-osko.png $(DIST_DIR)/$(BIN_NAME)-linux-$(HOST_ARCH)/ 2>/dev/null || true
	cp packaging/linux/run.sh $(DIST_DIR)/$(BIN_NAME)-linux-$(HOST_ARCH)/ 2>/dev/null || true
	cp packaging/linux/install-desktop-menu.sh $(DIST_DIR)/$(BIN_NAME)-linux-$(HOST_ARCH)/ 2>/dev/null || true
	chmod +x $(DIST_DIR)/$(BIN_NAME)-linux-$(HOST_ARCH)/*.desktop $(DIST_DIR)/$(BIN_NAME)-linux-$(HOST_ARCH)/*.sh 2>/dev/null || true
	cp README.md $(DIST_DIR)/$(BIN_NAME)-linux-$(HOST_ARCH)/ 2>/dev/null || true
	cp LICENSE $(DIST_DIR)/$(BIN_NAME)-linux-$(HOST_ARCH)/ 2>/dev/null || true
	tar -C $(DIST_DIR) -czf $(DIST_DIR)/$(BIN_NAME)-linux-$(HOST_ARCH).tar.gz $(BIN_NAME)-linux-$(HOST_ARCH)
	@echo "Created $(DIST_DIR)/$(BIN_NAME)-linux-$(HOST_ARCH).tar.gz"

MACOS_APP = $(BIN_DIR)/$(APP_NAME).app
MACOS_CONTENTS = $(MACOS_APP)/Contents
MACOS_MACOS = $(MACOS_CONTENTS)/MacOS
MACOS_RESOURCES = $(MACOS_CONTENTS)/Resources

macos-package: desktop web
	@rm -rf $(MACOS_APP)
	@mkdir -p $(MACOS_MACOS) $(MACOS_RESOURCES)/dist
	cp packaging/macos/Info.plist $(MACOS_CONTENTS)/Info.plist
	cp $(TARGET) $(MACOS_MACOS)/$(BIN_NAME)
	@if [ -f "packaging/macos/lucy-osko.icns" ]; then \
		cp packaging/macos/lucy-osko.icns $(MACOS_RESOURCES)/; \
	fi
	cp -r $(DIST_DIR)/index.html $(DIST_DIR)/app.min.js $(DIST_DIR)/skred_api.* $(MACOS_RESOURCES)/dist/
	@if command -v xattr >/dev/null 2>&1; then xattr -cr $(MACOS_APP); fi
	@if command -v codesign >/dev/null 2>&1; then \
		codesign --force --deep --sign - --entitlements packaging/macos/entitlements.plist $(MACOS_APP); \
	fi
	@mkdir -p $(DIST_DIR)
	cd $(BIN_DIR) && zip -r -y ../$(DIST_DIR)/$(BIN_NAME)-macos-universal.zip $(APP_NAME).app
	@echo "Created $(DIST_DIR)/$(BIN_NAME)-macos-universal.zip"

web-package: web
	@mkdir -p $(DIST_DIR)
	cd $(DIST_DIR) && zip -q -r $(BIN_NAME)-web.zip index.html app.min.js skred_api.js skred_api.wasm
	@echo "Created $(DIST_DIR)/$(BIN_NAME)-web.zip"

packages:
ifeq ($(UNAME_S),Darwin)
	$(MAKE) macos-package web-package
else
	$(MAKE) linux-package web-package
endif

# Run native desktop application
run: desktop
	./$(TARGET)

# Run web version locally with COOP/COEP headers (for WebAssembly pthreads & AudioWorklet)
dev: serve

serve: web
	python3 scripts/serve.py 8080 $(DIST_DIR)

format:
	@if [ -n "$(MISE)" ]; then \
		$(MISE) gleam format; \
	elif command -v gleam >/dev/null 2>&1; then \
		gleam format; \
	else \
		echo "Error: neither mise nor gleam found" >&2; exit 1; \
	fi

clean:
	rm -rf $(BIN_DIR) $(BUILD_DIR) $(DIST_DIR)/app.min.js $(DIST_DIR)/*.tar.gz $(DIST_DIR)/*.zip $(DIST_DIR)/$(BIN_NAME)-linux-*
