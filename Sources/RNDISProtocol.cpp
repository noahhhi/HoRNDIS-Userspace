// SPDX-License-Identifier: GPL-3.0-or-later
#include "RNDISProtocol.hpp"

#include <algorithm>
#include <limits>

namespace horndis::rndis {
namespace {

void append32(std::vector<uint8_t>& bytes, uint32_t value) {
    bytes.push_back(static_cast<uint8_t>(value));
    bytes.push_back(static_cast<uint8_t>(value >> 8));
    bytes.push_back(static_cast<uint8_t>(value >> 16));
    bytes.push_back(static_cast<uint8_t>(value >> 24));
}

bool validateEnvelope(std::span<const uint8_t> message, size_t minimum, std::string& error) {
    if (message.size() < minimum) {
        error = "RNDIS message is shorter than the required header";
        return false;
    }
    const uint32_t length = load32(message, 4);
    if (length < minimum || length > message.size()) {
        error = "RNDIS message length is invalid";
        return false;
    }
    return true;
}

bool validateCompletion(std::span<const uint8_t> message,
                        uint32_t expectedType,
                        uint32_t expectedRequestId,
                        size_t minimum,
                        std::string& error) {
    if (!validateEnvelope(message, minimum, error)) {
        return false;
    }
    if (load32(message, 0) != expectedType) {
        error = "unexpected RNDIS completion type";
        return false;
    }
    if (load32(message, 8) != expectedRequestId) {
        error = "RNDIS completion request ID does not match";
        return false;
    }
    if (load32(message, 12) != kStatusSuccess) {
        error = "RNDIS request failed with status 0x";
        static constexpr char digits[] = "0123456789abcdef";
        const uint32_t status = load32(message, 12);
        for (int shift = 28; shift >= 0; shift -= 4) {
            error.push_back(digits[(status >> shift) & 0xf]);
        }
        return false;
    }
    return true;
}

} // namespace

uint32_t load32(std::span<const uint8_t> bytes, size_t offset) {
    if (offset > bytes.size() || bytes.size() - offset < 4) {
        return 0;
    }
    return static_cast<uint32_t>(bytes[offset]) |
           (static_cast<uint32_t>(bytes[offset + 1]) << 8) |
           (static_cast<uint32_t>(bytes[offset + 2]) << 16) |
           (static_cast<uint32_t>(bytes[offset + 3]) << 24);
}

void store32(std::vector<uint8_t>& bytes, size_t offset, uint32_t value) {
    if (offset > bytes.size() || bytes.size() - offset < 4) {
        return;
    }
    bytes[offset] = static_cast<uint8_t>(value);
    bytes[offset + 1] = static_cast<uint8_t>(value >> 8);
    bytes[offset + 2] = static_cast<uint8_t>(value >> 16);
    bytes[offset + 3] = static_cast<uint8_t>(value >> 24);
}

std::vector<uint8_t> makeInitialize(uint32_t requestId, uint32_t maxTransferSize) {
    std::vector<uint8_t> message;
    message.reserve(24);
    append32(message, kInitializeMessage);
    append32(message, 24);
    append32(message, requestId);
    append32(message, 1);
    append32(message, 0);
    append32(message, maxTransferSize);
    return message;
}

std::vector<uint8_t> makeQuery(uint32_t requestId, uint32_t oid) {
    std::vector<uint8_t> message;
    message.reserve(28);
    append32(message, kQueryMessage);
    append32(message, 28);
    append32(message, requestId);
    append32(message, oid);
    append32(message, 0);
    append32(message, 20);
    append32(message, 0);
    return message;
}

std::vector<uint8_t> makeSetPacketFilter(uint32_t requestId, uint32_t filter) {
    std::vector<uint8_t> message;
    message.reserve(32);
    append32(message, kSetMessage);
    append32(message, 32);
    append32(message, requestId);
    append32(message, kOidCurrentPacketFilter);
    append32(message, 4);
    append32(message, 20);
    append32(message, 0);
    append32(message, filter);
    return message;
}

std::vector<uint8_t> makeKeepalive(uint32_t requestId) {
    std::vector<uint8_t> message;
    message.reserve(12);
    append32(message, kKeepaliveMessage);
    append32(message, 12);
    append32(message, requestId);
    return message;
}

std::vector<uint8_t> wrapEthernetFrame(std::span<const uint8_t> frame) {
    if (frame.size() > std::numeric_limits<uint32_t>::max() - 44) {
        return {};
    }
    std::vector<uint8_t> message(44 + frame.size(), 0);
    store32(message, 0, kPacketMessage);
    store32(message, 4, static_cast<uint32_t>(message.size()));
    store32(message, 8, 36);
    store32(message, 12, static_cast<uint32_t>(frame.size()));
    std::copy(frame.begin(), frame.end(), message.begin() + 44);
    return message;
}

std::optional<Completion> parseCompletion(std::span<const uint8_t> message, std::string& error) {
    if (!validateEnvelope(message, 16, error)) {
        return std::nullopt;
    }
    return Completion{load32(message, 0), load32(message, 8), load32(message, 12)};
}

std::optional<InitializeResult> parseInitializeComplete(std::span<const uint8_t> message,
                                                        uint32_t requestId,
                                                        std::string& error) {
    if (!validateCompletion(message, kInitializeComplete, requestId, 52, error)) {
        return std::nullopt;
    }
    InitializeResult result;
    result.maxPacketsPerTransfer = std::max<uint32_t>(1, load32(message, 32));
    result.maxTransferSize = std::max<uint32_t>(44, load32(message, 36));
    result.packetAlignmentFactor = load32(message, 40);
    return result;
}

std::optional<std::vector<uint8_t>> parseQueryComplete(std::span<const uint8_t> message,
                                                       uint32_t requestId,
                                                       std::string& error) {
    if (!validateCompletion(message, kQueryComplete, requestId, 24, error)) {
        return std::nullopt;
    }
    const uint32_t informationLength = load32(message, 16);
    const uint32_t informationOffset = load32(message, 20);
    const uint64_t start = 8ULL + informationOffset;
    const uint32_t messageLength = load32(message, 4);
    if (start > messageLength || informationLength > messageLength - start) {
        error = "RNDIS query completion data range is invalid";
        return std::nullopt;
    }
    return std::vector<uint8_t>(message.begin() + static_cast<ptrdiff_t>(start),
                                message.begin() + static_cast<ptrdiff_t>(start + informationLength));
}

bool validateSetComplete(std::span<const uint8_t> message, uint32_t requestId, std::string& error) {
    return validateCompletion(message, kSetComplete, requestId, 16, error);
}

bool validateKeepaliveComplete(std::span<const uint8_t> message,
                               uint32_t requestId,
                               std::string& error) {
    return validateCompletion(message, kKeepaliveComplete, requestId, 16, error);
}

std::vector<std::vector<uint8_t>> unwrapEthernetFrames(std::span<const uint8_t> transfer,
                                                       std::string& error) {
    std::vector<std::vector<uint8_t>> frames;
    size_t cursor = 0;
    while (transfer.size() - cursor >= 8) {
        const auto remaining = transfer.subspan(cursor);
        const uint32_t type = load32(remaining, 0);
        const uint32_t messageLength = load32(remaining, 4);
        if (type == 0 && messageLength == 0) {
            break;
        }
        if (type != kPacketMessage || messageLength < 44 || messageLength > remaining.size()) {
            error = "invalid RNDIS packet message in USB transfer";
            return {};
        }
        const uint32_t dataOffset = load32(remaining, 8);
        const uint32_t dataLength = load32(remaining, 12);
        const uint64_t start = 8ULL + dataOffset;
        if (start > messageLength || dataLength > messageLength - start) {
            error = "RNDIS Ethernet payload range is invalid";
            return {};
        }
        frames.emplace_back(remaining.begin() + static_cast<ptrdiff_t>(start),
                            remaining.begin() + static_cast<ptrdiff_t>(start + dataLength));
        cursor += messageLength;
    }
    return frames;
}

} // namespace horndis::rndis
