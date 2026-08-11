// SPDX-License-Identifier: GPL-3.0-or-later
#include "RNDISProtocol.hpp"

#include <cassert>
#include <iostream>

using namespace horndis::rndis;

int main() {
    const auto initialize = makeInitialize(7, 32768);
    assert(initialize.size() == 24);
    assert(load32(initialize, 0) == kInitializeMessage);
    assert(load32(initialize, 8) == 7);
    assert(load32(initialize, 20) == 32768);

    const std::vector<uint8_t> ethernet{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 0x08, 0x00};
    const auto packet = wrapEthernetFrame(ethernet);
    assert(packet.size() == 58);
    assert(load32(packet, 8) == 36);
    assert(load32(packet, 12) == ethernet.size());

    std::string error;
    const auto frames = unwrapEthernetFrames(packet, error);
    assert(error.empty());
    assert(frames.size() == 1);
    assert(frames.front() == ethernet);

    const std::vector<uint8_t> oddLengthEthernet{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 0x08,
                                                  0x00, 0xaa};
    const auto oddPacket = wrapEthernetFrame(oddLengthEthernet);
    std::vector<uint8_t> aggregate = oddPacket;
    aggregate.insert(aggregate.end(), packet.begin(), packet.end());
    error.clear();
    const auto aggregateFrames = unwrapEthernetFrames(aggregate, error);
    assert(error.empty());
    assert(aggregateFrames.size() == 2);
    assert(aggregateFrames[0] == oddLengthEthernet);
    assert(aggregateFrames[1] == ethernet);

    std::vector<uint8_t> queryResponse(30, 0);
    store32(queryResponse, 0, kQueryComplete);
    store32(queryResponse, 4, 30);
    store32(queryResponse, 8, 11);
    store32(queryResponse, 12, kStatusSuccess);
    store32(queryResponse, 16, 6);
    store32(queryResponse, 20, 16);
    queryResponse[24] = 0x02;
    queryResponse[25] = 0xaa;
    queryResponse[26] = 0xbb;
    queryResponse[27] = 0xcc;
    queryResponse[28] = 0xdd;
    queryResponse[29] = 0xee;
    const auto address = parseQueryComplete(queryResponse, 11, error);
    assert(address.has_value());
    assert(address->size() == 6);
    assert((*address)[5] == 0xee);

    std::cout << "RNDIS protocol tests passed\n";
    return 0;
}
