// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>
#include <string>
#include <vector>

namespace horndis::rndis {

constexpr uint32_t kPacketMessage = 0x00000001;
constexpr uint32_t kInitializeMessage = 0x00000002;
constexpr uint32_t kQueryMessage = 0x00000004;
constexpr uint32_t kSetMessage = 0x00000005;
constexpr uint32_t kKeepaliveMessage = 0x00000008;

constexpr uint32_t kInitializeComplete = 0x80000002;
constexpr uint32_t kQueryComplete = 0x80000004;
constexpr uint32_t kSetComplete = 0x80000005;
constexpr uint32_t kKeepaliveComplete = 0x80000008;

constexpr uint32_t kStatusSuccess = 0x00000000;
constexpr uint32_t kOidCurrentPacketFilter = 0x0001010e;
constexpr uint32_t kOidCurrentAddress = 0x01010102;

constexpr uint32_t kPacketTypeDirected = 0x00000001;
constexpr uint32_t kPacketTypeMulticast = 0x00000002;
constexpr uint32_t kPacketTypeAllMulticast = 0x00000004;
constexpr uint32_t kPacketTypeBroadcast = 0x00000008;

struct InitializeResult {
    uint32_t maxPacketsPerTransfer = 1;
    uint32_t maxTransferSize = 16384;
    uint32_t packetAlignmentFactor = 0;
};

struct Completion {
    uint32_t type = 0;
    uint32_t requestId = 0;
    uint32_t status = 0;
};

uint32_t load32(std::span<const uint8_t> bytes, size_t offset);
void store32(std::vector<uint8_t>& bytes, size_t offset, uint32_t value);

std::vector<uint8_t> makeInitialize(uint32_t requestId, uint32_t maxTransferSize = 16384);
std::vector<uint8_t> makeQuery(uint32_t requestId, uint32_t oid);
std::vector<uint8_t> makeSetPacketFilter(uint32_t requestId, uint32_t filter);
std::vector<uint8_t> makeKeepalive(uint32_t requestId);
bool wrapEthernetFrame(std::span<const uint8_t> frame, std::vector<uint8_t>& message);
std::vector<uint8_t> wrapEthernetFrame(std::span<const uint8_t> frame);

std::optional<Completion> parseCompletion(std::span<const uint8_t> message, std::string& error);
std::optional<InitializeResult> parseInitializeComplete(std::span<const uint8_t> message,
                                                        uint32_t requestId,
                                                        std::string& error);
std::optional<std::vector<uint8_t>> parseQueryComplete(std::span<const uint8_t> message,
                                                       uint32_t requestId,
                                                       std::string& error);
bool validateSetComplete(std::span<const uint8_t> message, uint32_t requestId, std::string& error);
bool validateKeepaliveComplete(std::span<const uint8_t> message, uint32_t requestId, std::string& error);
std::vector<std::vector<uint8_t>> unwrapEthernetFrames(std::span<const uint8_t> transfer,
                                                       std::string& error);

} // namespace horndis::rndis
