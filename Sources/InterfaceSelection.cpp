// SPDX-License-Identifier: GPL-3.0-or-later
#include "InterfaceSelection.hpp"

namespace horndis {

std::vector<EthernetInterfacePair> automaticInterfaceCandidates() {
    std::vector<EthernetInterfacePair> candidates;
    candidates.reserve(50);
    for (int hostUnit = 99; hostUnit >= 1; hostUnit -= 2) {
        candidates.push_back({"feth" + std::to_string(hostUnit),
                              "feth" + std::to_string(hostUnit - 1)});
    }
    return candidates;
}

std::optional<EthernetInterfacePair> selectAutomaticInterfacePair(
    const std::set<std::string>& occupiedInterfaces) {
    for (const auto& candidate : automaticInterfaceCandidates()) {
        if (!occupiedInterfaces.contains(candidate.host) &&
            !occupiedInterfaces.contains(candidate.transport)) {
            return candidate;
        }
    }
    return std::nullopt;
}

} // namespace horndis
