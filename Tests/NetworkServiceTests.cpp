// SPDX-License-Identifier: GPL-3.0-or-later
#include "NetworkService.hpp"
#include "VirtualEthernet.hpp"
#include <cassert>
#include <iostream>
#include <net/if.h>
#include <unistd.h>
#include <SystemConfiguration/SystemConfiguration.h>

static CFIndex configuredMemberCount(const std::string& bridge, const std::string& expected = "") {
    auto prefs = SCPreferencesCreate(nullptr, CFSTR("HoRNDIS membership test"), nullptr);
    assert(prefs);
    auto path = CFStringCreateWithFormat(nullptr, nullptr,
        CFSTR("/VirtualNetworkInterfaces/Bridge/%s"), bridge.c_str());
    auto config = SCPreferencesPathGetValue(prefs, path);
    assert(config);
    auto members = static_cast<CFArrayRef>(CFDictionaryGetValue(config, CFSTR("Interfaces")));
    assert(members && CFGetTypeID(members) == CFArrayGetTypeID());
    auto count = CFArrayGetCount(members);
    if (!expected.empty()) {
        assert(count == 1);
        char actual[IFNAMSIZ]{};
        assert(CFStringGetCString(static_cast<CFStringRef>(CFArrayGetValueAtIndex(members, 0)),
                                 actual, sizeof(actual), kCFStringEncodingUTF8));
        assert(expected == actual);
    }
    CFRelease(path); CFRelease(prefs);
    return count;
}

int main(int argc, char* argv[]) {
    assert(horndis::isBridgeName("bridge1"));
    assert(!horndis::isBridgeName("bridge"));
    assert(!horndis::isBridgeName("bridge1;true"));
    assert(!horndis::isBridgeName("feth99"));
    std::string name, error;
    if (argc == 3 && std::string(argv[1]) == "--inspect-connected") {
        assert(horndis::isBridgeName(argv[2]));
        assert(configuredMemberCount(argv[2]) == 1);
        std::cout << "Installed bridge has one registered forwarding member\n";
        return 0;
    }
    if (geteuid() != 0) {
        assert(!horndis::ensureNetworkService(name, error));
        std::cout << "Network service unprivileged and name validation tests passed\n";
        return 0;
    }
    // Explicit opt-in only, on a development host with no owned network service.
    if (argc != 2 || std::string(argv[1]) != "--isolated-root-lifecycle") return 2;
    horndis::VirtualEthernet ethernet;
    assert(ethernet.open("", "", error));
    name = ethernet.hostInterface();
    assert(horndis::isBridgeName(name));
    const auto transport = ethernet.transportInterface();
    assert(if_nametoindex(name.c_str()));
    assert(configuredMemberCount(name) == 0);
    assert(ethernet.refreshDHCP(error));
    assert(configuredMemberCount(name) == 1);
    std::string occupiedName, occupiedError;
    assert(!horndis::ensureNetworkService(occupiedName, occupiedError));
    assert(occupiedError.find("existing members") != std::string::npos);
    assert(ethernet.suspendNetwork(error));
    assert(configuredMemberCount(name) == 0);
    assert(ethernet.refreshDHCP(error));
    assert(ethernet.suspendNetwork(error));
    ethernet.close();
    assert(configuredMemberCount(name) == 0);
    assert(!if_nametoindex(transport.c_str()));
    error.clear();
    std::string reused;
    assert(horndis::ensureNetworkService(reused, error));
    assert(reused == name);
    // A subsequent pair change must replace the actual configured member,
    // while preserving the same bridge/service and leaving no stale member.
    assert(ethernet.open("feth83", "feth82", error));
    assert(ethernet.hostInterface() == name);
    assert(ethernet.refreshDHCP(error));
    assert(configuredMemberCount(name, "feth83") == 1);
    ethernet.close();
    assert(configuredMemberCount(name) == 0);
    assert(horndis::removeNetworkService(error));
    assert(horndis::removeNetworkService(error));
    std::cout << "Network service create, carrier lifecycle, occupied refusal, reuse and removal passed\n";
}
