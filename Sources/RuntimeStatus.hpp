// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <cstdint>
#include <string>

namespace horndis {

struct RuntimeStatus {
    std::string state;
    std::string device;
    std::string deviceAddress;
    std::string hostInterface;
    std::string detail;
    uint64_t receivedBytes = 0;
    uint64_t transmittedBytes = 0;
    uint64_t connectedSince = 0;
    bool controlAvailable = false;
};

bool publishRuntimeStatus(const RuntimeStatus& status, std::string& error);
void removeRuntimeStatus();

} // namespace horndis
