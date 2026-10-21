PREFIX ?= $(HOME)/.local
space-arrange: main.swift
	swiftc -O -o $@ main.swift
install: space-arrange
	install -m 755 space-arrange $(PREFIX)/bin/space-arrange
.PHONY: install
