// SPDX-License-Identifier: GPL-3.0-or-later
#include "Diagnostics.hpp"

#include <cassert>
#include <iostream>
#include <string>

int main() {
    using horndis::redactDiagnosticText;

    // Home directories, MAC addresses, and IP addresses must never survive.
    const std::string identifiers = redactDiagnosticText(
        "log at /Users/somebody/Library/Logs\n"
        "ether aa:bb:cc:dd:ee:ff\n"
        "inet 192.168.42.17 netmask 255.255.255.0\n"
        "inet6 fe80::abcd:1234 prefixlen 64\n"
        "inet6 2001:0db8:0000:0000:0000:0000:0000:0001\n");
    assert(identifiers.find("somebody") == std::string::npos);
    assert(identifiers.find("/Users/user/Library/Logs") != std::string::npos);
    assert(identifiers.find("aa:bb:cc:dd:ee:ff") == std::string::npos);
    assert(identifiers.find("<redacted-mac>") != std::string::npos);
    assert(identifiers.find("192.168.42.17") == std::string::npos);
    assert(identifiers.find("fe80::abcd:1234") == std::string::npos);
    assert(identifiers.find("2001:0db8") == std::string::npos);
    assert(identifiers.find("<redacted-ip>") != std::string::npos);

    // Sensitive property lines keep the key but drop the value.
    const std::string properties = redactDiagnosticText(
        "Serial Number = ABC123XYZ\n"
        "Manufacturer: Google Inc.\n"
        "Product Name = Pixel 4 XL\n"
        "USB Vendor Name: Google\n"
        "MTU = 1500\n");
    assert(properties.find("ABC123XYZ") == std::string::npos);
    assert(properties.find("Pixel 4 XL") == std::string::npos);
    assert(properties.find("Google") == std::string::npos);
    assert(properties.find("Serial Number = <redacted>") != std::string::npos);
    assert(properties.find("Manufacturer: <redacted>") != std::string::npos);
    assert(properties.find("MTU = 1500") != std::string::npos); // unrelated lines survive

    // Legacy log lines written by older HoRNDIS versions are sanitized on copy.
    const std::string legacy = redactDiagnosticText(
        "2026-08-18 horndis: connected Pixel 4 XL to feth99\n"
        "2026-08-18 started unprivileged data agent as uid 501 (pid 321)\n");
    assert(legacy.find("Pixel") == std::string::npos);
    assert(legacy.find("connected device 1") != std::string::npos);
    assert(legacy.find(" to feth99") != std::string::npos);
    assert(legacy.find("uid 501") == std::string::npos);
    assert(legacy.find("data agent as user") != std::string::npos);

    std::cout << "Diagnostics redaction tests passed\n";
    return 0;
}
