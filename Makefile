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
CXXFLAGS ?= -std=c++20 -O2 -Wall -Wextra -Iinclude
LDFLAGS  ?= -pthread
BUILD    := build
BIN      := $(BUILD)/sony-head-tracker
GUI_SCRIPT := $(CURDIR)/gui/sony_head_tracker_gui.py
PREFIX   ?= $(HOME)/.local

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

install-gui:
	@mkdir -p $(PREFIX)/bin $(PREFIX)/share/applications $(PREFIX)/share/icons/hicolor/scalable/apps
	@printf '#!/usr/bin/env bash\nexec python3 "%s" "$$@"\n' '$(GUI_SCRIPT)' > $(PREFIX)/bin/sony-head-tracker-gui
	@chmod +x $(PREFIX)/bin/sony-head-tracker-gui
	@printf '#!/usr/bin/env bash\nexec "%s" "$$@"\n' '$(CURDIR)/scripts/recenter.sh' > $(PREFIX)/bin/sony-head-tracker-recenter
	@chmod +x $(PREFIX)/bin/sony-head-tracker-recenter
	@cp gui/io.github.sonyheadtracker.desktop $(PREFIX)/share/applications/
	@cp gui/io.github.sonyheadtracker.svg $(PREFIX)/share/icons/hicolor/scalable/apps/
	@command -v update-desktop-database >/dev/null && update-desktop-database $(PREFIX)/share/applications || true
	@echo "Installed 'Sony Head Tracker' to your app menu."

$(BUILD):
	mkdir -p $(BUILD)

clean:
	rm -rf $(BUILD)

.PHONY: all test gui install-gui clean
