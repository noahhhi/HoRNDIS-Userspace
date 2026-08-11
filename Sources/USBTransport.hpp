// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <cstdint>
#include <deque>
#include <memory>
#include <string>
#include <vector>

namespace horndis {

enum class USBNetworkProtocol {
    RNDIS,
    CDC_ECM,
    CDC_NCM,
};

struct USBDeviceInfo {
    USBNetworkProtocol protocol = USBNetworkProtocol::RNDIS;
    uint32_t locationId = 0;
    uint16_t vendorId = 0;
    uint16_t productId = 0;
    uint8_t controlInterfaceNumber = 0;
    uint8_t dataInterfaceNumber = 0;
    std::string product;
    std::string serial;
    bool supported = false;
};

class RNDISUSBTransport {
public:
    RNDISUSBTransport();
    ~RNDISUSBTransport();
    RNDISUSBTransport(const RNDISUSBTransport&) = delete;
    RNDISUSBTransport& operator=(const RNDISUSBTransport&) = delete;

    static std::vector<USBDeviceInfo> scan();

    bool open(const USBDeviceInfo& device, std::string& error);
    bool initialize(std::vector<uint8_t>& deviceAddress, std::string& error);
    bool readEthernetFrame(std::vector<uint8_t>& frame, bool& timedOut, std::string& error);
    bool writeEthernetFrame(const std::vector<uint8_t>& frame, std::string& error);
    void close();

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
    uint32_t nextRequestId_ = 1;
    uint32_t maxTransferSize_ = 16384;
    std::deque<std::vector<uint8_t>> pendingFrames_;

    bool exchangeControl(const std::vector<uint8_t>& request,
                         std::vector<uint8_t>& response,
                         std::string& error);
};

const char* protocolName(USBNetworkProtocol protocol);

} // namespace horndis
