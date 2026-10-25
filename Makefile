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

.PHONY: all build frontend host run dev clean format

all: build

build: frontend host

# 1. Compile Gleam frontend and bundle to dist/
frontend:
	$(MISE) gleam build --target javascript
	@mkdir -p $(DIST_DIR)
	@cp src/entry.mjs build/dev/javascript/lucy_osko/entry.mjs
	$(MISE) npx --yes esbuild build/dev/javascript/lucy_osko/entry.mjs --bundle --minify --format=iife --outfile=$(DIST_DIR)/app.min.js

# 2. Compile native C webview host
host: $(TARGET)

$(TARGET): $(HOST_DIR)/main.c $(SKRED_LIB)
	@mkdir -p $(BIN_DIR)
	$(CC) $(CFLAGS) $(GTK_CFLAGS) $(SKRED_INC) $(WEBVIEW_INC) \
		$< $(SKRED_LIB) $(GTK_LIBS) -o $@

# Run native desktop application
run: build
	./$(TARGET)

# Run in web browser (uses FFI mock driver for fast frontend iteration)
dev: frontend
	@echo "Starting development web server at http://localhost:8080..."
	python3 -m http.server 8080 -d $(DIST_DIR)

format:
	$(MISE) gleam format

clean:
	rm -rf $(BIN_DIR) $(BUILD_DIR) $(DIST_DIR)/app.min.js
