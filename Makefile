PREFIX ?= /usr/local
DESTDIR ?=
APPDIR ?= /Applications
BUILD_DIR ?= build
VERSION ?= 0.3.7
ARCH_FLAGS ?=
STATUS_ARCHS ?= $(shell uname -m)

CXX := xcrun clang++
CXXFLAGS := -std=c++20 -O2 -g -fobjc-arc -fblocks -Wall -Wextra -Wpedantic \
	-Werror=return-type -mmacosx-version-min=11.0 $(ARCH_FLAGS) -I Sources \
	-DHORNDIS_VERSION=\"$(VERSION)\"
LDFLAGS := -mmacosx-version-min=11.0 $(ARCH_FLAGS) -framework Foundation -framework IOKit -framework IOUSBHost \
	-framework SystemConfiguration
SWIFTC := xcrun swiftc
CODESIGN := codesign

SOURCES := Sources/main.mm Sources/RNDISProtocol.cpp Sources/USBTransport.mm \
	Sources/VirtualEthernet.cpp Sources/ServiceManager.cpp Sources/RuntimeStatus.cpp \
	Sources/ControlServer.cpp Sources/Diagnostics.mm Sources/SupervisorChannel.cpp \
	Sources/InterfaceSelection.cpp
OBJECTS := $(SOURCES:%=$(BUILD_DIR)/%.o)
TARGET := $(BUILD_DIR)/horndis
STATUS_TARGET := $(BUILD_DIR)/horndis-status
STATUS_APP := $(BUILD_DIR)/HoRNDISStatus.app
STATUS_APP_BINARY := $(STATUS_APP)/Contents/MacOS/horndis-status
STATUS_APP_ICON := $(STATUS_APP)/Contents/Resources/HoRNDISStatus.icns
STATUS_APP_NETWORK_TOOL := $(STATUS_APP)/Contents/Resources/horndis
STATUS_APP_UNINSTALLER := $(STATUS_APP)/Contents/Resources/horndis-uninstall
STATUS_LANGUAGES := en zh-Hans zh-Hant ja ko fr de es pt-BR it ru
STATUS_APP_LOCALIZATIONS := $(foreach language,$(STATUS_LANGUAGES),\
	$(STATUS_APP)/Contents/Resources/$(language).lproj/InfoPlist.strings \
	$(STATUS_APP)/Contents/Resources/$(language).lproj/Localizable.strings)
STATUS_ICON_GENERATOR := $(BUILD_DIR)/generate-horndis-icon
STATUS_ICONSET := $(BUILD_DIR)/HoRNDISStatus.iconset
STATUS_ICON := $(BUILD_DIR)/HoRNDISStatus.icns
STATUS_ARCH_TARGETS = $(addprefix $(BUILD_DIR)/horndis-status-,$(STATUS_ARCHS))
TEST_TARGET := $(BUILD_DIR)/rndis-protocol-tests
RUNTIME_STATUS_TEST := $(BUILD_DIR)/runtime-status-tests
SUPERVISOR_CHANNEL_TEST := $(BUILD_DIR)/supervisor-channel-tests
DHCP_RECONNECT_CONTRACT_TEST := $(BUILD_DIR)/dhcp-reconnect-contract-tests
INTERFACE_SELECTION_TEST := $(BUILD_DIR)/interface-selection-tests
INTERFACE_LIFECYCLE_CONTRACT_TEST := $(BUILD_DIR)/interface-lifecycle-contract-tests
DIAGNOSTICS_PRIVACY_CONTRACT_TEST := $(BUILD_DIR)/diagnostics-privacy-contract-tests
DIAGNOSTICS_REDACTION_TEST := $(BUILD_DIR)/diagnostics-redaction-tests
DEVICE_ALIASES_TEST := $(BUILD_DIR)/device-aliases-tests
USB_TRANSPORT_MEMORY_CONTRACT_TEST := $(BUILD_DIR)/usb-transport-memory-contract-tests
APP_LANGUAGE_PROBE := $(BUILD_DIR)/app-language-probe
MENU_UI_CONTRACT_TEST := $(BUILD_DIR)/menu-ui-contract-tests
MANPAGE := Documentation/horndis.1

.PHONY: all clean install test test-ui

all: $(TARGET) $(STATUS_TARGET)

$(TARGET): $(OBJECTS)
	@mkdir -p $(@D)
	$(CXX) $(OBJECTS) $(LDFLAGS) -o $@
	$(CODESIGN) --force --sign - "$@"

$(BUILD_DIR)/%.o: %
	@mkdir -p $(@D)
	$(CXX) $(CXXFLAGS) -c $< -o $@

$(BUILD_DIR)/horndis-status-%: StatusApp/HoRNDISStatus.swift
	@mkdir -p "$(@D)"
	$(SWIFTC) -parse-as-library -O -whole-module-optimization -target $*-apple-macosx11.0 \
		-framework AppKit -framework Foundation $< -o $@

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

$(STATUS_APP_UNINSTALLER): Packaging/horndis-uninstall
	@mkdir -p "$(STATUS_APP)/Contents/Resources"
	install -m 0755 "$<" "$@"

$(STATUS_APP)/Contents/Resources/%.lproj/InfoPlist.strings: StatusApp/%.lproj/InfoPlist.strings
	@mkdir -p "$(@D)"
	install -m 0644 "$<" "$@"

$(STATUS_APP)/Contents/Resources/%.lproj/Localizable.strings: StatusApp/%.lproj/Localizable.strings
	@mkdir -p "$(@D)"
	install -m 0644 "$<" "$@"

$(STATUS_APP_BINARY): $(STATUS_ARCH_TARGETS) $(STATUS_ICON) $(STATUS_APP_NETWORK_TOOL) $(STATUS_APP_UNINSTALLER) $(STATUS_APP_LOCALIZATIONS) StatusApp/Info.plist
	@mkdir -p "$(STATUS_APP)/Contents/MacOS" "$(STATUS_APP)/Contents/Resources"
	install -m 0644 StatusApp/Info.plist "$(STATUS_APP)/Contents/Info.plist"
	install -m 0644 "$(STATUS_ICON)" "$(STATUS_APP_ICON)"
	xcrun lipo -create $(STATUS_ARCH_TARGETS) -output "$@"
	$(CODESIGN) --force --deep --sign - "$(STATUS_APP)"

$(STATUS_TARGET): $(STATUS_APP_BINARY)
	ln -sfn "HoRNDISStatus.app/Contents/MacOS/horndis-status" "$@"

$(TEST_TARGET): Tests/RNDISProtocolTests.cpp Sources/RNDISProtocol.cpp Sources/RNDISProtocol.hpp
	@mkdir -p $(@D)
	$(CXX) $(CXXFLAGS) Tests/RNDISProtocolTests.cpp Sources/RNDISProtocol.cpp -o $@

$(RUNTIME_STATUS_TEST): Tests/RuntimeStatusTests.cpp Sources/RuntimeStatus.cpp Sources/RuntimeStatus.hpp
	@mkdir -p $(@D)
	$(CXX) $(CXXFLAGS) Tests/RuntimeStatusTests.cpp Sources/RuntimeStatus.cpp -o $@

$(SUPERVISOR_CHANNEL_TEST): Tests/SupervisorChannelTests.cpp Sources/SupervisorChannel.cpp Sources/SupervisorChannel.hpp
	@mkdir -p $(@D)
	$(CXX) $(CXXFLAGS) Tests/SupervisorChannelTests.cpp Sources/SupervisorChannel.cpp -o $@

$(DHCP_RECONNECT_CONTRACT_TEST): Tests/DHCPReconnectContractTests.cpp
	@mkdir -p $(@D)
	$(CXX) $(CXXFLAGS) Tests/DHCPReconnectContractTests.cpp -o $@

$(INTERFACE_SELECTION_TEST): Tests/InterfaceSelectionTests.cpp Sources/InterfaceSelection.cpp Sources/InterfaceSelection.hpp
	@mkdir -p $(@D)
	$(CXX) $(CXXFLAGS) Tests/InterfaceSelectionTests.cpp Sources/InterfaceSelection.cpp -o $@

$(INTERFACE_LIFECYCLE_CONTRACT_TEST): Tests/InterfaceLifecycleContractTests.cpp
	@mkdir -p $(@D)
	$(CXX) $(CXXFLAGS) Tests/InterfaceLifecycleContractTests.cpp -o $@

$(DIAGNOSTICS_PRIVACY_CONTRACT_TEST): Tests/DiagnosticsPrivacyContractTests.cpp
	@mkdir -p $(@D)
	$(CXX) $(CXXFLAGS) $< -o $@

$(DIAGNOSTICS_REDACTION_TEST): Tests/DiagnosticsRedactionTests.mm Sources/Diagnostics.mm Sources/USBTransport.mm Sources/RNDISProtocol.cpp Sources/Diagnostics.hpp
	@mkdir -p $(@D)
	$(CXX) $(CXXFLAGS) Tests/DiagnosticsRedactionTests.mm Sources/Diagnostics.mm Sources/USBTransport.mm Sources/RNDISProtocol.cpp $(LDFLAGS) -o $@

$(DEVICE_ALIASES_TEST): Tests/DeviceAliasesTests.cpp Sources/DeviceAliases.hpp
	@mkdir -p $(@D)
	$(CXX) $(CXXFLAGS) $< -o $@

$(USB_TRANSPORT_MEMORY_CONTRACT_TEST): Tests/USBTransportMemoryContractTests.cpp
	@mkdir -p $(@D)
	$(CXX) $(CXXFLAGS) $< -o $@

$(APP_LANGUAGE_PROBE): Tests/AppLanguageProbe.swift
	@mkdir -p $(@D)
	$(SWIFTC) -parse-as-library -target $(shell uname -m)-apple-macosx11.0 \
		-framework Foundation $< -o $@

$(MENU_UI_CONTRACT_TEST): Tests/MenuUIContractTests.swift
	@mkdir -p $(@D)
	$(SWIFTC) -parse-as-library -target $(shell uname -m)-apple-macosx11.0 \
		-framework Foundation $< -o $@

test: $(TEST_TARGET) $(RUNTIME_STATUS_TEST) $(SUPERVISOR_CHANNEL_TEST) $(DHCP_RECONNECT_CONTRACT_TEST) $(INTERFACE_SELECTION_TEST) $(INTERFACE_LIFECYCLE_CONTRACT_TEST) $(DIAGNOSTICS_PRIVACY_CONTRACT_TEST) $(DIAGNOSTICS_REDACTION_TEST) $(DEVICE_ALIASES_TEST) $(USB_TRANSPORT_MEMORY_CONTRACT_TEST) $(STATUS_TARGET) $(APP_LANGUAGE_PROBE) $(MENU_UI_CONTRACT_TEST)
	$(TEST_TARGET)
	$(RUNTIME_STATUS_TEST)
	$(SUPERVISOR_CHANNEL_TEST)
	$(DHCP_RECONNECT_CONTRACT_TEST) Sources/main.mm Sources/VirtualEthernet.cpp
	$(INTERFACE_SELECTION_TEST)
	$(INTERFACE_LIFECYCLE_CONTRACT_TEST) Sources/VirtualEthernet.cpp Sources/main.mm StatusApp/HoRNDISStatus.swift
	$(DIAGNOSTICS_PRIVACY_CONTRACT_TEST) Sources/main.mm Sources/Diagnostics.mm .github/ISSUE_TEMPLATE/bug_report.yml .github/ISSUE_TEMPLATE/config.yml
	$(DIAGNOSTICS_REDACTION_TEST)
	$(DEVICE_ALIASES_TEST)
	$(USB_TRANSPORT_MEMORY_CONTRACT_TEST) Sources/USBTransport.mm
	$(MENU_UI_CONTRACT_TEST) StatusApp/HoRNDISStatus.swift
	$(APP_LANGUAGE_PROBE) "$(STATUS_APP)" StatusApp/HoRNDISStatus.swift
	$(STATUS_APP_BINARY) --version
	test -x "$(STATUS_APP_NETWORK_TOOL)"
	test -x "$(STATUS_APP_UNINSTALLER)"
	cmp -s "$(TARGET)" "$(STATUS_APP_NETWORK_TOOL)"
	$(CODESIGN) --verify --strict --verbose=2 "$(TARGET)"
	$(CODESIGN) --verify --deep --strict --verbose=2 "$(STATUS_APP)"

test-ui: $(MENU_UI_CONTRACT_TEST)
	$(MENU_UI_CONTRACT_TEST) StatusApp/HoRNDISStatus.swift
	@echo "Complete the installed-app checklist in docs/MENU_UI_GUIDELINES.md"

install: $(TARGET) $(STATUS_TARGET) $(MANPAGE)
	install -d $(DESTDIR)$(PREFIX)/bin $(DESTDIR)$(PREFIX)/share/man/man1
	install -m 0755 $(TARGET) $(DESTDIR)$(PREFIX)/bin/horndis
	install -d "$(DESTDIR)$(APPDIR)"
	cp -R -X "$(STATUS_APP)" "$(DESTDIR)$(APPDIR)/HoRNDIS Status.app"
	install -m 0644 Documentation/horndis.1 $(DESTDIR)$(PREFIX)/share/man/man1/horndis.1

clean:
	rm -rf $(BUILD_DIR)
