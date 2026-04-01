# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Ian Spray

.PHONY: build clean text

build: $(BINARY)

$(BINARY): main.go
	go build -o $(BINARY) .

clean:
	rm -f $(BINARY)

test:
	go test -v ./...

