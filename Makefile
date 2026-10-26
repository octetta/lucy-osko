CC ?= gcc
CFLAGS ?= -O2 -Wall
MISE ?= mise exec --

HOST_DIR = host
BUILD_DIR = build
DIST_DIR = dist
BIN_DIR = bin

TARGET = $(BIN_DIR)/lucy-osko

SKRED_INC = -I$(HOST_DIR)/vendor/skred/include -I$(HOST_DIR)/vendor/skred/include/skred
WEBVIEW_INC = -I$(HOST_DIR)/vendor/webview
SKRED_LIB = $(HOST_DIR)/vendor/skred/lib/libapi.a

GTK_CFLAGS = $(shell pkg-config --cflags gtk+-3.0 webkit2gtk-4.0)
GTK_LIBS = $(shell pkg-config --libs gtk+-3.0 webkit2gtk-4.0 alsa) -lm -lpthread -ldl

.PHONY: all build frontend desktop host web run dev serve clean format

all: build

build: desktop web

# 1. Compile Gleam frontend and bundle to dist/
frontend:
	$(MISE) gleam build --target javascript
	@mkdir -p $(DIST_DIR)
	@cp src/entry.mjs build/dev/javascript/lucy_osko/entry.mjs
	$(MISE) npx --yes esbuild build/dev/javascript/lucy_osko/entry.mjs --bundle --minify --format=iife --outfile=$(DIST_DIR)/app.min.js

# 2. Compile native C webview host (Desktop target)
desktop: frontend host

host: $(TARGET)

$(TARGET): $(HOST_DIR)/main.c $(SKRED_LIB)
	@mkdir -p $(BIN_DIR)
	$(CC) $(CFLAGS) $(GTK_CFLAGS) $(SKRED_INC) $(WEBVIEW_INC) \
		$< $(SKRED_LIB) $(GTK_LIBS) -o $@

# 3. Web target: Bundle frontend and sync WASM audio engine assets
web: frontend
	@mkdir -p $(DIST_DIR)
	@if [ -d "../pulp/parts/build_wasm" ]; then \
		cp -u ../pulp/parts/build_wasm/skred_api.js $(DIST_DIR)/ 2>/dev/null || true; \
		cp -u ../pulp/parts/build_wasm/skred_api.wasm $(DIST_DIR)/ 2>/dev/null || true; \
	fi
	@echo "Web distribution ready in $(DIST_DIR)/"

# Run native desktop application
run: desktop
	./$(TARGET)

# Run web version locally with COOP/COEP headers (for WebAssembly pthreads & AudioWorklet)
dev: serve

serve: web
	python3 scripts/serve.py 8080 $(DIST_DIR)

format:
	$(MISE) gleam format

clean:
	rm -rf $(BIN_DIR) $(BUILD_DIR) $(DIST_DIR)/app.min.js
