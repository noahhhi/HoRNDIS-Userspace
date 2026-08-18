// SPDX-License-Identifier: GPL-3.0-or-later
#include "RuntimeStatus.hpp"

#include <cassert>
#include <chrono>
#include <iostream>

using namespace std::chrono_literals;

int main() {
    horndis::RuntimeStatus connected;
    connected.state = "connected";
    connected.device = "Android";
    connected.deviceAddress = "02:00:00:00:00:01";
    connected.hostInterface = "feth99";
    connected.detail = "USB tethering is active";
    connected.receivedBytes = 100;
    connected.transmittedBytes = 200;
    connected.connectedSince = 1234;
    connected.controlAvailable = true;

    auto countersOnly = connected;
    countersOnly.receivedBytes += 1;
    countersOnly.transmittedBytes += 2;
    assert(!horndis::hasRuntimeStatusTransition(connected, countersOnly));

    auto paused = countersOnly;
    paused.state = "paused";
    paused.detail = "Connection paused from the menu bar";
    paused.connectedSince = 0;
    assert(horndis::hasRuntimeStatusTransition(countersOnly, paused));

    auto deviceChanged = connected;
    deviceChanged.deviceAddress = "02:00:00:00:00:02";
    assert(horndis::hasRuntimeStatusTransition(connected, deviceChanged));

    horndis::RuntimeStatusPublicationPolicy policy(5s);
    const auto start = std::chrono::steady_clock::time_point(30s);
    assert(policy.shouldPublish(connected, start));
    policy.didPublish(connected, start);

    assert(!policy.shouldPublish(countersOnly, start + 1s));
    assert(!policy.shouldPublish(countersOnly, start + 4999ms));
    assert(policy.shouldPublish(countersOnly, start + 5s));
    assert(policy.shouldPublish(countersOnly, start + 1s, true));

    // User/device/service transitions bypass the periodic counter cadence.
    assert(policy.shouldPublish(paused, start + 10ms));
    policy.didPublish(paused, start + 10ms);
    assert(!policy.shouldPublish(paused, start + 1s));

    // The published JSON must neutralize device-controlled strings.
    horndis::RuntimeStatus hostile = connected;
    hostile.device = "Pixel\"},\n{\"state\": \"evil";
    hostile.detail = "tab\there\x01\r";
    const std::string json = horndis::serializeRuntimeStatus(hostile);
    assert(json.find("Pixel\\\"},\\n{\\\"state\\\": \\\"evil") != std::string::npos);
    assert(json.find("tab\\there\\u0001\\r") != std::string::npos);
    assert(json.find("Pixel\"") == std::string::npos); // no raw quote survives
    assert(json.find('\x01') == std::string::npos);      // no raw control byte
    assert(json.find("\"schema_version\": 1") != std::string::npos);
    assert(json.find("\"received_bytes\": 100") != std::string::npos);
    assert(json.find("\"control_available\": true") != std::string::npos);
    assert(json.find("\"updated_at\": ") != std::string::npos);
    assert(json.find("\"process_id\": ") != std::string::npos);

    std::cout << "Runtime status publication tests passed\n";
    return 0;
}
