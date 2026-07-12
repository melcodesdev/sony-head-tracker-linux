# Linux build for sony-head-tracker.
# The cross-platform CMake build (CMakeLists.txt) is the source of truth used by
# CI and by the macOS/Windows builds; this Makefile is a dependency-free Linux
# convenience that produces build/sony-head-tracker with the same sources as the
# CMake `if(LINUX)` target. See docs/LINUX.md.
#
#   make            build the CLI
#   make test       build + run the Linux test suite
#   make gui        run the GTK GUI against the built CLI
#   make install-gui   add the GUI to your application menu
#   make clean

CXX      ?= g++
# Respect a packager's optimization flags (makepkg/dpkg-buildflags export CXXFLAGS),
# but always append the flags the build cannot go without via `override`.
CXXFLAGS ?= -O2 -Wall -Wextra
override CXXFLAGS += -std=c++20 -Iinclude
override LDFLAGS  += -pthread
BUILD    := build
BIN      := $(BUILD)/sony-head-tracker
GUI_SCRIPT := $(CURDIR)/gui/sony_head_tracker_gui.py
# PREFIX/DESTDIR are for the packaging `install` target (default /usr; AUR and
# distro packages use DESTDIR staging). The dev `install-gui` target always uses
# ~/.local and runs the app straight from this checkout.
PREFIX   ?= /usr
DESTDIR  ?=
LOCAL    := $(HOME)/.local
DATADIR  := $(DESTDIR)$(PREFIX)/share/sony-head-tracker

# Portable core (matches the sony_head_tracker_core CMake library).
CORE := \
	src/math.cpp \
	src/orientation.cpp \
	src/protocol.cpp \
	src/hid_descriptor.cpp \
	src/app_config.cpp \
	src/diagnostics.cpp

# Linux platform layer (matches the if(LINUX) CMake block). The POSIX UDP
# transport is shared with macOS.
PLATFORM := \
	src/linux/hid_backend_linux.cpp \
	src/linux/hid_report_parser.cpp \
	src/linux/logger_linux.cpp \
	src/linux/platform_compat.cpp \
	src/macos/output_udp_posix.cpp

APP_SRC  := $(CORE) $(PLATFORM) src/linux/main_linux.cpp
TEST_SRC := src/hid_descriptor.cpp src/linux/hid_report_parser.cpp \
	tests/test_main.cpp tests/report_parser_tests.cpp
TEST_BIN := $(BUILD)/linux-tests

all: $(BIN)

$(BIN): $(APP_SRC) | $(BUILD)
	$(CXX) $(CXXFLAGS) $(APP_SRC) -o $@ $(LDFLAGS)

$(TEST_BIN): $(TEST_SRC) | $(BUILD)
	$(CXX) $(CXXFLAGS) $(TEST_SRC) -o $@ $(LDFLAGS)

test: $(TEST_BIN)
	./$(TEST_BIN)

gui: $(BIN)
	python3 $(GUI_SCRIPT)

# Dev convenience: add the app to your menu, running straight from this checkout
# (launchers point back here). No root, no udev rule. Use `install` for a real
# system install.
install-gui:
	@mkdir -p $(LOCAL)/bin $(LOCAL)/share/applications $(LOCAL)/share/icons/hicolor/scalable/apps
	@printf '#!/usr/bin/env bash\nexec python3 "%s" "$$@"\n' '$(GUI_SCRIPT)' > $(LOCAL)/bin/sony-head-tracker-gui
	@chmod +x $(LOCAL)/bin/sony-head-tracker-gui
	@printf '#!/usr/bin/env bash\nexec "%s" "$$@"\n' '$(CURDIR)/scripts/recenter.sh' > $(LOCAL)/bin/sony-head-tracker-recenter
	@chmod +x $(LOCAL)/bin/sony-head-tracker-recenter
	@cp gui/io.github.sonyheadtracker.desktop $(LOCAL)/share/applications/
	@cp gui/io.github.sonyheadtracker.svg $(LOCAL)/share/icons/hicolor/scalable/apps/
	@command -v update-desktop-database >/dev/null && update-desktop-database $(LOCAL)/share/applications || true
	@echo "Installed 'Sony Head Tracker' to your app menu (runs from this checkout)."

# Self-contained system install for packagers and manual installs:
#   sudo make install            # to /usr
#   make install DESTDIR=pkg PREFIX=/usr   # staged (AUR, .deb, .rpm)
install: $(BIN)
	install -Dm755 $(BIN) $(DESTDIR)$(PREFIX)/bin/sony-head-tracker
	install -Dm644 gui/sony_head_tracker_gui.py $(DATADIR)/sony_head_tracker_gui.py
	install -Dm755 scripts/recenter.sh $(DATADIR)/scripts/recenter.sh
	install -Dm755 scripts/setup-recenter-shortcut.sh $(DATADIR)/scripts/setup-recenter-shortcut.sh
	install -Dm755 scripts/setup-steam-game.sh $(DATADIR)/scripts/setup-steam-game.sh
	install -Dm755 scripts/install-opentrack.sh $(DATADIR)/scripts/install-opentrack.sh
	install -Dm644 extras/70-sony-head-tracker.rules $(DATADIR)/extras/70-sony-head-tracker.rules
	install -Dm644 extras/70-sony-head-tracker.rules $(DESTDIR)$(PREFIX)/lib/udev/rules.d/70-sony-head-tracker.rules
	install -Dm644 gui/io.github.sonyheadtracker.desktop $(DESTDIR)$(PREFIX)/share/applications/io.github.sonyheadtracker.desktop
	install -Dm644 gui/io.github.sonyheadtracker.svg $(DESTDIR)$(PREFIX)/share/icons/hicolor/scalable/apps/io.github.sonyheadtracker.svg
	printf '#!/bin/sh\nexec python3 "%s/share/sony-head-tracker/sony_head_tracker_gui.py" "$$@"\n' '$(PREFIX)' \
		| install -Dm755 /dev/stdin $(DESTDIR)$(PREFIX)/bin/sony-head-tracker-gui
	printf '#!/bin/sh\nexec "%s/share/sony-head-tracker/scripts/recenter.sh" "$$@"\n' '$(PREFIX)' \
		| install -Dm755 /dev/stdin $(DESTDIR)$(PREFIX)/bin/sony-head-tracker-recenter
	@echo "Installed to $(DESTDIR)$(PREFIX)."

uninstall:
	rm -f $(DESTDIR)$(PREFIX)/bin/sony-head-tracker \
	      $(DESTDIR)$(PREFIX)/bin/sony-head-tracker-gui \
	      $(DESTDIR)$(PREFIX)/bin/sony-head-tracker-recenter \
	      $(DESTDIR)$(PREFIX)/lib/udev/rules.d/70-sony-head-tracker.rules \
	      $(DESTDIR)$(PREFIX)/share/applications/io.github.sonyheadtracker.desktop \
	      $(DESTDIR)$(PREFIX)/share/icons/hicolor/scalable/apps/io.github.sonyheadtracker.svg
	rm -rf $(DATADIR)

$(BUILD):
	mkdir -p $(BUILD)

clean:
	rm -rf $(BUILD)

.PHONY: all test gui install-gui install uninstall clean
