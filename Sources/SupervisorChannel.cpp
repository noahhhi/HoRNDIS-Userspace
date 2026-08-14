// SPDX-License-Identifier: GPL-3.0-or-later
#include "SupervisorChannel.hpp"

#include <cerrno>
#include <cstring>
#include <unistd.h>

namespace horndis {
namespace {

constexpr uint8_t kSupervisorSuccess = 1;
constexpr uint8_t kSupervisorFailure = 2;

bool writeByte(int descriptor, uint8_t value, std::string& error) {
    ssize_t count = -1;
    do {
        count = ::write(descriptor, &value, sizeof(value));
    } while (count < 0 && errno == EINTR);
    if (count != static_cast<ssize_t>(sizeof(value))) {
        error = "cannot write to the root supervisor channel: " +
                std::string(count < 0 ? std::strerror(errno) : "short write");
        return false;
    }
    return true;
}

bool readByte(int descriptor, uint8_t& value, bool& closed, std::string& error) {
    closed = false;
    ssize_t count = -1;
    do {
        count = ::read(descriptor, &value, sizeof(value));
    } while (count < 0 && errno == EINTR);
    if (count == 0) {
        closed = true;
        return true;
    }
    if (count != static_cast<ssize_t>(sizeof(value))) {
        error = "cannot read from the root supervisor channel: " +
                std::string(count < 0 ? std::strerror(errno) : "short read");
        return false;
    }
    return true;
}

} // namespace

bool requestDHCPRefresh(int descriptor, std::string& error) {
    if (descriptor < 0) {
        error = "the root supervisor DHCP channel is unavailable";
        return false;
    }
    if (!writeByte(descriptor, static_cast<uint8_t>(SupervisorRequest::refreshDHCP), error)) {
        return false;
    }
    uint8_t response = 0;
    bool closed = false;
    if (!readByte(descriptor, response, closed, error)) {
        return false;
    }
    if (closed) {
        error = "the root supervisor closed the DHCP channel";
        return false;
    }
    if (response == kSupervisorSuccess) {
        return true;
    }
    if (response == kSupervisorFailure) {
        error = "the root supervisor could not start DHCP; see /var/log/horndis.log";
        return false;
    }
    error = "the root supervisor returned an invalid DHCP response";
    return false;
}

bool receiveSupervisorRequest(int descriptor,
                              SupervisorRequest& request,
                              bool& closed,
                              std::string& error) {
    uint8_t value = 0;
    if (!readByte(descriptor, value, closed, error) || closed) {
        return error.empty();
    }
    if (value != static_cast<uint8_t>(SupervisorRequest::refreshDHCP)) {
        error = "the data agent sent an invalid supervisor request";
        return false;
    }
    request = SupervisorRequest::refreshDHCP;
    return true;
}

bool sendSupervisorResponse(int descriptor, bool success, std::string& error) {
    return writeByte(descriptor, success ? kSupervisorSuccess : kSupervisorFailure, error);
}

} // namespace horndis
