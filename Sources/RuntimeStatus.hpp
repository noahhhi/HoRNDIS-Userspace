// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <chrono>
#include <cstdint>
#include <optional>
#include <string>

namespace horndis {

struct RuntimeStatus {
    std::string state;
    std::string device;
    std::string deviceAlias;
    std::string deviceAddress;
    std::string hostInterface;
    std::string detail;
    uint64_t receivedBytes = 0;
    uint64_t transmittedBytes = 0;
    uint64_t connectedSince = 0;
    bool controlAvailable = false;
};

// Byte counters do not constitute a state transition, so they may be
// coalesced without delaying device, service, or user-requested changes.
bool hasRuntimeStatusTransition(const RuntimeStatus& previous,
                                const RuntimeStatus& current);

class RuntimeStatusPublicationPolicy {
public:
    explicit RuntimeStatusPublicationPolicy(
        std::chrono::steady_clock::duration periodicInterval =
            std::chrono::seconds(5));

    bool shouldPublish(const RuntimeStatus& status,
                       std::chrono::steady_clock::time_point now,
                       bool force = false) const;
    void didPublish(const RuntimeStatus& status,
                    std::chrono::steady_clock::time_point now);

private:
    std::chrono::steady_clock::duration periodicInterval_;
    std::optional<RuntimeStatus> lastPublishedStatus_;
    std::chrono::steady_clock::time_point lastPublishedAt_{};
};

class RuntimeStatusPublisher {
public:
    explicit RuntimeStatusPublisher(
        std::chrono::steady_clock::duration periodicInterval =
            std::chrono::seconds(5));

    bool publish(const RuntimeStatus& status, std::string& error, bool force = false);

private:
    RuntimeStatusPublicationPolicy policy_;
};

bool publishRuntimeStatus(const RuntimeStatus& status, std::string& error);
void removeRuntimeStatus();

// Exposed for tests: the exact JSON document published to status.json.
// Device-controlled strings (product name, detail) must arrive escaped.
std::string serializeRuntimeStatus(const RuntimeStatus& status);

} // namespace horndis
