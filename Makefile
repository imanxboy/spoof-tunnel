CC      ?= gcc
CFLAGS  ?= -O2 -mtune=generic
SRC      = src/spoof_tunnel_v6.c
BIN      = bin/spoof-tunnel
PREFIX  ?= /usr/local

.PHONY: all build install install-config clean

all: build

build: $(BIN)

$(BIN): $(SRC)
	mkdir -p bin
	$(CC) $(CFLAGS) -pthread -Wall -Wextra -Werror -o $(BIN) $(SRC)
	sha256sum $(BIN)

install: build
	@[ "$$(id -u)" = "0" ] || { echo "Run as root: sudo make install"; exit 1; }
	bash install.sh

install-config:
	@[ "$$(id -u)" = "0" ] || { echo "Run as root: sudo make install-config"; exit 1; }
	bash install.sh --config-only

clean:
	rm -f $(BIN)

# Build a release tarball (used by CI — not needed for normal use)
RELEASE_TAG ?= $(shell git describe --tags 2>/dev/null || echo dev)
release: build
	mkdir -p dist
	tar czf dist/spoof-tunnel-$(RELEASE_TAG).tar.gz \
	    --exclude=dist \
	    --exclude=.git \
	    --exclude='config-*.yaml' \
	    --exclude='*.bak' \
	    --exclude='GITHUB_AUDIT*.md' \
	    --exclude='PUBLISH_READINESS*.md' \
	    .
	sha256sum dist/spoof-tunnel-$(RELEASE_TAG).tar.gz
