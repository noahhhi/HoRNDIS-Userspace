PREFIX ?= /usr/local
DESTDIR ?=
BUILD_DIR ?= build
VERSION ?= 0.1.0
ARCH_FLAGS ?=

CXX := xcrun clang++
CXXFLAGS := -std=c++20 -O2 -g -fobjc-arc -fblocks -Wall -Wextra -Wpedantic \
	-Werror=return-type -mmacosx-version-min=12.0 $(ARCH_FLAGS) -I Sources \
	-DHORNDIS_VERSION=\"$(VERSION)\"
LDFLAGS := $(ARCH_FLAGS) -framework Foundation -framework IOKit -framework IOUSBHost \
	-framework SystemConfiguration

SOURCES := Sources/main.mm Sources/RNDISProtocol.cpp Sources/USBTransport.mm \
	Sources/VirtualEthernet.cpp Sources/ServiceManager.cpp
OBJECTS := $(SOURCES:%=$(BUILD_DIR)/%.o)
TARGET := $(BUILD_DIR)/horndis
TEST_TARGET := $(BUILD_DIR)/rndis-protocol-tests

.PHONY: all clean install test

all: $(TARGET)

$(TARGET): $(OBJECTS)
	@mkdir -p $(@D)
	$(CXX) $(OBJECTS) $(LDFLAGS) -o $@

$(BUILD_DIR)/%.o: %
	@mkdir -p $(@D)
	$(CXX) $(CXXFLAGS) -c $< -o $@

$(TEST_TARGET): Tests/RNDISProtocolTests.cpp Sources/RNDISProtocol.cpp Sources/RNDISProtocol.hpp
	@mkdir -p $(@D)
	$(CXX) $(CXXFLAGS) Tests/RNDISProtocolTests.cpp Sources/RNDISProtocol.cpp -o $@

test: $(TEST_TARGET)
	$(TEST_TARGET)

install: $(TARGET)
	install -d $(DESTDIR)$(PREFIX)/bin
	install -m 0755 $(TARGET) $(DESTDIR)$(PREFIX)/bin/horndis

clean:
	rm -rf $(BUILD_DIR)
