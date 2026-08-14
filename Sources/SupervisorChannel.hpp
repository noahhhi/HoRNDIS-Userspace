// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <cstdint>
#include <string>

namespace horndis {

enum class SupervisorRequest : uint8_t {
    refreshDHCP = 1,
};

bool requestDHCPRefresh(int descriptor, std::string& error);
bool receiveSupervisorRequest(int descriptor,
                              SupervisorRequest& request,
                              bool& closed,
                              std::string& error);
bool sendSupervisorResponse(int descriptor, bool success, std::string& error);

} // namespace horndis
