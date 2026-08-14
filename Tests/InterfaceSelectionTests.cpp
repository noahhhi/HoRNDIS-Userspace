// SPDX-License-Identifier: GPL-3.0-or-later
#include "InterfaceSelection.hpp"

#include <cassert>
#include <iostream>
#include <set>
#include <string>

int main() {
    const auto preferred = horndis::selectAutomaticInterfacePair({});
    assert(preferred.has_value());
    assert(preferred->host == "feth99");
    assert(preferred->transport == "feth98");

    const auto preferredHostOccupied =
        horndis::selectAutomaticInterfacePair({"feth99"});
    assert(preferredHostOccupied.has_value());
    assert(preferredHostOccupied->host == "feth97");
    assert(preferredHostOccupied->transport == "feth96");

    const auto preferredTransportOccupied =
        horndis::selectAutomaticInterfacePair({"feth98"});
    assert(preferredTransportOccupied.has_value());
    assert(preferredTransportOccupied->host == "feth97");
    assert(preferredTransportOccupied->transport == "feth96");

    std::set<std::string> allOccupied;
    for (const auto& candidate : horndis::automaticInterfaceCandidates()) {
        allOccupied.insert(candidate.host);
        allOccupied.insert(candidate.transport);
    }
    assert(!horndis::selectAutomaticInterfacePair(allOccupied).has_value());

    std::cout << "Interface selection tests passed\n";
    return 0;
}
