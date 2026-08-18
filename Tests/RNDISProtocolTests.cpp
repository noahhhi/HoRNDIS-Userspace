// SPDX-License-Identifier: GPL-3.0-or-later
#include "RNDISProtocol.hpp"

#include <cassert>
#include <cstdint>
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
    std::vector<uint8_t> reusablePacket;
    assert(wrapEthernetFrame(oddLengthEthernet, reusablePacket));
    assert(reusablePacket == oddPacket);
    const auto* reusableStorage = reusablePacket.data();
    assert(wrapEthernetFrame(ethernet, reusablePacket));
    assert(reusablePacket == packet);
    assert(reusablePacket.data() == reusableStorage);
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

    // Malformed and hostile inputs: every parser sees device-controlled bytes.
    error.clear();
    std::vector<uint8_t> truncatedHeader(packet.begin(), packet.begin() + 7);
    assert(unwrapEthernetFrames(truncatedHeader, error).empty());
    assert(error.empty()); // shorter than one header: ignored, not an error

    std::vector<uint8_t> paddedTransfer = packet;
    paddedTransfer.insert(paddedTransfer.end(), 8, 0); // zero terminator padding
    error.clear();
    const auto paddedFrames = unwrapEthernetFrames(paddedTransfer, error);
    assert(error.empty());
    assert(paddedFrames.size() == 1 && paddedFrames.front() == ethernet);

    std::vector<uint8_t> wrongType = packet;
    store32(wrongType, 0, kInitializeMessage);
    error.clear();
    assert(unwrapEthernetFrames(wrongType, error).empty());
    assert(!error.empty());

    std::vector<uint8_t> shortLength = packet;
    store32(shortLength, 4, 43); // below the 44-byte packet header
    error.clear();
    assert(unwrapEthernetFrames(shortLength, error).empty());
    assert(!error.empty());

    std::vector<uint8_t> overLength = packet;
    store32(overLength, 4, static_cast<uint32_t>(packet.size()) + 1);
    error.clear();
    assert(unwrapEthernetFrames(overLength, error).empty());
    assert(!error.empty());

    std::vector<uint8_t> badOffset = packet;
    store32(badOffset, 8, static_cast<uint32_t>(packet.size())); // start past the message
    error.clear();
    assert(unwrapEthernetFrames(badOffset, error).empty());
    assert(!error.empty());

    std::vector<uint8_t> badDataLength = packet;
    store32(badDataLength, 12, static_cast<uint32_t>(packet.size())); // spills past the message
    error.clear();
    assert(unwrapEthernetFrames(badDataLength, error).empty());
    assert(!error.empty());

    std::vector<uint8_t> hugeOffset = packet;
    store32(hugeOffset, 8, 0xffffffff); // 8 + offset must not wrap
    error.clear();
    assert(unwrapEthernetFrames(hugeOffset, error).empty());
    assert(!error.empty());

    std::vector<uint8_t> secondFrameCorrupt = packet;
    secondFrameCorrupt.insert(secondFrameCorrupt.end(), packet.begin(), packet.end());
    store32(secondFrameCorrupt, packet.size() + 4, 43);
    error.clear();
    assert(unwrapEthernetFrames(secondFrameCorrupt, error).empty()); // reject whole transfer
    assert(!error.empty());

    auto failedQuery = queryResponse;
    store32(failedQuery, 12, 0xc0000001); // generic RNDIS failure status
    error.clear();
    assert(!parseQueryComplete(failedQuery, 11, error).has_value());
    assert(error.find("status 0xc0000001") != std::string::npos);

    error.clear();
    assert(!parseQueryComplete(queryResponse, 12, error).has_value()); // request ID mismatch
    assert(!error.empty());

    auto wrongCompletionType = queryResponse;
    store32(wrongCompletionType, 0, kSetComplete);
    error.clear();
    assert(!parseQueryComplete(wrongCompletionType, 11, error).has_value());
    assert(!error.empty());

    auto badInformationOffset = queryResponse;
    store32(badInformationOffset, 20, 64); // information range past the message
    error.clear();
    assert(!parseQueryComplete(badInformationOffset, 11, error).has_value());
    assert(!error.empty());

    auto badInformationLength = queryResponse;
    store32(badInformationLength, 16, 32);
    error.clear();
    assert(!parseQueryComplete(badInformationLength, 11, error).has_value());
    assert(!error.empty());

    auto lyingEnvelope = queryResponse;
    store32(lyingEnvelope, 4, static_cast<uint32_t>(queryResponse.size()) + 8);
    error.clear();
    assert(!parseQueryComplete(lyingEnvelope, 11, error).has_value());
    assert(!error.empty());

    error.clear();
    const std::vector<uint8_t> tinyMessage(8, 0);
    assert(!parseCompletion(tinyMessage, error).has_value());
    assert(!error.empty());

    std::vector<uint8_t> initializeComplete(52, 0);
    store32(initializeComplete, 0, kInitializeComplete);
    store32(initializeComplete, 4, 52);
    store32(initializeComplete, 8, 9);
    store32(initializeComplete, 12, kStatusSuccess);
    store32(initializeComplete, 32, 0); // device claims zero packets per transfer
    store32(initializeComplete, 36, 1); // device claims a sub-header transfer size
    error.clear();
    const auto initializeResult = parseInitializeComplete(initializeComplete, 9, error);
    assert(initializeResult.has_value());
    assert(initializeResult->maxPacketsPerTransfer == 1); // clamped
    assert(initializeResult->maxTransferSize == 44);      // clamped

    std::vector<uint8_t> failedSet(16, 0);
    store32(failedSet, 0, kSetComplete);
    store32(failedSet, 4, 16);
    store32(failedSet, 8, 5);
    store32(failedSet, 12, 0xc0000001);
    error.clear();
    assert(!validateSetComplete(failedSet, 5, error));
    assert(!error.empty());

    // Out-of-range accessors must stay inert instead of reading or writing.
    const std::vector<uint8_t> shortBytes{1, 2, 3};
    assert(load32(shortBytes, 0) == 0);
    assert(load32(shortBytes, SIZE_MAX) == 0);
    std::vector<uint8_t> storeTarget{1, 2, 3};
    store32(storeTarget, 0, 0xdeadbeef);
    store32(storeTarget, SIZE_MAX, 0xdeadbeef);
    assert((storeTarget == std::vector<uint8_t>{1, 2, 3}));

    std::cout << "RNDIS protocol tests passed\n";
    return 0;
}
