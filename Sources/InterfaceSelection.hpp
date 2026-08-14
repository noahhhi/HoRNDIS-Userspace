// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <optional>
#include <set>
#include <string>
#include <vector>

namespace horndis {

struct EthernetInterfacePair {
    std::string host;
    std::string transport;

    bool operator==(const EthernetInterfacePair&) const = default;
};

std::vector<EthernetInterfacePair> automaticInterfaceCandidates();
std::optional<EthernetInterfacePair> selectAutomaticInterfacePair(
    const std::set<std::string>& occupiedInterfaces);

} // namespace horndis
