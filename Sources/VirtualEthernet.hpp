// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace horndis {

class VirtualEthernet {
public:
    VirtualEthernet();
    ~VirtualEthernet();
    VirtualEthernet(const VirtualEthernet&) = delete;
    VirtualEthernet& operator=(const VirtualEthernet&) = delete;

    bool open(const std::string& hostInterface,
              const std::string& transportInterface,
              std::string& error);
    bool adoptDescriptor(int descriptor,
                         const std::string& hostInterface,
                         const std::string& transportInterface,
                         std::string& error);
    bool flush(std::string& error);
    bool readFrame(std::vector<uint8_t>& frame, bool& timedOut, std::string& error);
    bool writeFrame(const std::vector<uint8_t>& frame, std::string& error);
    void close();

    const std::string& hostInterface() const { return hostInterface_; }
    const std::string& transportInterface() const { return transportInterface_; }
    int descriptor() const { return bpf_; }

private:
    int bpf_ = -1;
    std::string hostInterface_;
    std::string transportInterface_;
    std::vector<uint8_t> readBuffer_;
    size_t readOffset_ = 0;
    size_t bpfBufferSize_ = 0;

    bool createInterface(const std::string& interface, bool& created, std::string& error);
};

} // namespace horndis
