PREFIX ?= /usr/local
DESTDIR ?=
BUILD_DIR ?= build
VERSION ?= 0.2.1
ARCH_FLAGS ?=
STATUS_ARCHS ?= $(shell uname -m)

CXX := xcrun clang++
CXXFLAGS := -std=c++20 -O2 -g -fobjc-arc -fblocks -Wall -Wextra -Wpedantic \
	-Werror=return-type -mmacosx-version-min=11.0 $(ARCH_FLAGS) -I Sources \
	-DHORNDIS_VERSION=\"$(VERSION)\"
LDFLAGS := -mmacosx-version-min=11.0 $(ARCH_FLAGS) -framework Foundation -framework IOKit -framework IOUSBHost \
	-framework SystemConfiguration
SWIFTC := xcrun swiftc

SOURCES := Sources/main.mm Sources/RNDISProtocol.cpp Sources/USBTransport.mm \
	Sources/VirtualEthernet.cpp Sources/ServiceManager.cpp Sources/RuntimeStatus.cpp \
	Sources/ControlServer.cpp
OBJECTS := $(SOURCES:%=$(BUILD_DIR)/%.o)
TARGET := $(BUILD_DIR)/horndis
STATUS_TARGET := $(BUILD_DIR)/horndis-status
STATUS_APP := $(BUILD_DIR)/HoRNDISStatus.app
STATUS_APP_BINARY := $(STATUS_APP)/Contents/MacOS/horndis-status
STATUS_ARCH_TARGETS = $(addprefix $(BUILD_DIR)/horndis-status-,$(STATUS_ARCHS))
TEST_TARGET := $(BUILD_DIR)/rndis-protocol-tests

.PHONY: all clean install test

all: $(TARGET) $(STATUS_TARGET)

$(TARGET): $(OBJECTS)
	@mkdir -p $(@D)
	$(CXX) $(OBJECTS) $(LDFLAGS) -o $@

$(BUILD_DIR)/%.o: %
	@mkdir -p $(@D)
	$(CXX) $(CXXFLAGS) -c $< -o $@

$(BUILD_DIR)/horndis-status-%: StatusApp/HoRNDISStatus.swift
	@mkdir -p $(@D)
	$(SWIFTC) -O -whole-module-optimization -target $*-apple-macosx11.0 \
		-framework AppKit -framework Foundation -framework SwiftUI $< -o $@

$(STATUS_APP_BINARY): $(STATUS_ARCH_TARGETS) StatusApp/Info.plist
	@mkdir -p "$(STATUS_APP)/Contents/MacOS"
	install -m 0644 StatusApp/Info.plist "$(STATUS_APP)/Contents/Info.plist"
	xcrun lipo -create $(STATUS_ARCH_TARGETS) -output "$@"

$(STATUS_TARGET): $(STATUS_APP_BINARY)
	ln -sfn "HoRNDISStatus.app/Contents/MacOS/horndis-status" "$@"

$(TEST_TARGET): Tests/RNDISProtocolTests.cpp Sources/RNDISProtocol.cpp Sources/RNDISProtocol.hpp
	@mkdir -p $(@D)
	$(CXX) $(CXXFLAGS) Tests/RNDISProtocolTests.cpp Sources/RNDISProtocol.cpp -o $@

test: $(TEST_TARGET) $(STATUS_TARGET)
	$(TEST_TARGET)
	$(STATUS_TARGET) --version

install: $(TARGET) $(STATUS_TARGET)
	install -d $(DESTDIR)$(PREFIX)/bin
	install -m 0755 $(TARGET) $(DESTDIR)$(PREFIX)/bin/horndis
	cp -R "$(STATUS_APP)" "$(DESTDIR)$(PREFIX)/HoRNDISStatus.app"
	ln -sfn "../HoRNDISStatus.app/Contents/MacOS/horndis-status" \
		$(DESTDIR)$(PREFIX)/bin/horndis-status

clean:
	rm -rf $(BUILD_DIR)
