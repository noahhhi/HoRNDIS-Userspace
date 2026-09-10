// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <string>

namespace horndis {
// Root-only configuration. The data agent never receives preferences or SPI objects.
bool ensureNetworkService(std::string& bridgeName, std::string& error);
bool removeNetworkService(std::string& error);
bool refreshNetworkService(const std::string& bridgeName, std::string& error);
bool setNetworkServiceMember(const std::string& bridgeName, const std::string& member,
                             bool attached, std::string& error);
bool isBridgeName(const std::string& name);
}
