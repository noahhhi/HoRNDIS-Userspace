PREFIX ?= /usr/local
DESTDIR ?=
BUILD_DIR ?= build
VERSION ?= 0.2.2
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
STATUS_APP_ICON := $(STATUS_APP)/Contents/Resources/HoRNDISStatus.icns
STATUS_APP_NETWORK_TOOL := $(STATUS_APP)/Contents/Resources/horndis
STATUS_ICON_GENERATOR := $(BUILD_DIR)/generate-horndis-icon
STATUS_ICONSET := $(BUILD_DIR)/HoRNDISStatus.iconset
STATUS_ICON := $(BUILD_DIR)/HoRNDISStatus.icns
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
	$(SWIFTC) -parse-as-library -O -whole-module-optimization -target $*-apple-macosx11.0 \
		-framework AppKit -framework Foundation -framework SwiftUI $< -o $@

$(STATUS_ICON_GENERATOR): StatusApp/GenerateAppIcon.swift
	@mkdir -p $(@D)
	$(SWIFTC) -O -framework AppKit -framework Foundation $< -o $@

$(STATUS_ICON): $(STATUS_ICON_GENERATOR)
	@mkdir -p "$(STATUS_ICONSET)"
	$(STATUS_ICON_GENERATOR) "$(STATUS_ICONSET)"
	iconutil -c icns -o "$@" "$(STATUS_ICONSET)"

$(STATUS_APP_NETWORK_TOOL): $(TARGET)
	@mkdir -p "$(STATUS_APP)/Contents/Resources"
	install -m 0755 "$<" "$@"

$(STATUS_APP_BINARY): $(STATUS_ARCH_TARGETS) $(STATUS_ICON) $(STATUS_APP_NETWORK_TOOL) StatusApp/Info.plist
	@mkdir -p "$(STATUS_APP)/Contents/MacOS" "$(STATUS_APP)/Contents/Resources"
	install -m 0644 StatusApp/Info.plist "$(STATUS_APP)/Contents/Info.plist"
	install -m 0644 "$(STATUS_ICON)" "$(STATUS_APP_ICON)"
	xcrun lipo -create $(STATUS_ARCH_TARGETS) -output "$@"

$(STATUS_TARGET): $(STATUS_APP_BINARY)
	ln -sfn "HoRNDISStatus.app/Contents/MacOS/horndis-status" "$@"

$(TEST_TARGET): Tests/RNDISProtocolTests.cpp Sources/RNDISProtocol.cpp Sources/RNDISProtocol.hpp
	@mkdir -p $(@D)
	$(CXX) $(CXXFLAGS) Tests/RNDISProtocolTests.cpp Sources/RNDISProtocol.cpp -o $@

test: $(TEST_TARGET) $(STATUS_TARGET)
	$(TEST_TARGET)
	$(STATUS_TARGET) --version
	test -x "$(STATUS_APP_NETWORK_TOOL)"
	cmp -s "$(TARGET)" "$(STATUS_APP_NETWORK_TOOL)"

install: $(TARGET) $(STATUS_TARGET)
	install -d $(DESTDIR)$(PREFIX)/bin
	install -m 0755 $(TARGET) $(DESTDIR)$(PREFIX)/bin/horndis
	install -m 0755 Scripts/horndis-install $(DESTDIR)$(PREFIX)/bin/horndis-install
	cp -R -X "$(STATUS_APP)" "$(DESTDIR)$(PREFIX)/HoRNDISStatus.app"
	ln -sfn "../HoRNDISStatus.app/Contents/MacOS/horndis-status" \
		$(DESTDIR)$(PREFIX)/bin/horndis-status

clean:
	rm -rf $(BUILD_DIR)
