// SPDX-License-Identifier: GPL-3.0-or-later
#include "RuntimeStatus.hpp"

#include <cerrno>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <sstream>
#include <sys/stat.h>
#include <unistd.h>

namespace horndis {
namespace {

constexpr const char* kStatusDirectory = "/var/run/horndis";
constexpr const char* kStatusPath = "/var/run/horndis/status.json";

std::string escapeJSON(const std::string& value) {
    std::ostringstream stream;
    stream << std::hex;
    for (const unsigned char character : value) {
        switch (character) {
        case '"':
            stream << "\\\"";
            break;
        case '\\':
            stream << "\\\\";
            break;
        case '\b':
            stream << "\\b";
            break;
        case '\f':
            stream << "\\f";
            break;
        case '\n':
            stream << "\\n";
            break;
        case '\r':
            stream << "\\r";
            break;
        case '\t':
            stream << "\\t";
            break;
        default:
            if (character < 0x20) {
                constexpr char digits[] = "0123456789abcdef";
                stream << "\\u00" << digits[(character >> 4) & 0x0f]
                       << digits[character & 0x0f];
            } else {
                stream << character;
            }
            break;
        }
    }
    return stream.str();
}

uint64_t currentTimestamp() {
    return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::seconds>(
                                     std::chrono::system_clock::now().time_since_epoch())
                                     .count());
}

bool writeAll(int descriptor, const std::string& contents, std::string& error) {
    size_t offset = 0;
    while (offset < contents.size()) {
        const ssize_t count = write(descriptor, contents.data() + offset, contents.size() - offset);
        if (count < 0) {
            if (errno == EINTR) {
                continue;
            }
            error = "cannot write runtime status: " + std::string(std::strerror(errno));
            return false;
        }
        offset += static_cast<size_t>(count);
    }
    return true;
}

std::string serialize(const RuntimeStatus& status) {
    std::ostringstream stream;
    stream << "{\n"
           << "  \"schema_version\": 1,\n"
           << "  \"state\": \"" << escapeJSON(status.state) << "\",\n"
           << "  \"device\": \"" << escapeJSON(status.device) << "\",\n"
           << "  \"device_alias\": \"" << escapeJSON(status.deviceAlias) << "\",\n"
           << "  \"device_address\": \"" << escapeJSON(status.deviceAddress) << "\",\n"
           << "  \"host_interface\": \"" << escapeJSON(status.hostInterface) << "\",\n"
           << "  \"detail\": \"" << escapeJSON(status.detail) << "\",\n"
           << "  \"received_bytes\": " << status.receivedBytes << ",\n"
           << "  \"transmitted_bytes\": " << status.transmittedBytes << ",\n"
           << "  \"connected_since\": " << status.connectedSince << ",\n"
           << "  \"control_available\": "
           << (status.controlAvailable ? "true" : "false") << ",\n"
           << "  \"updated_at\": " << currentTimestamp() << ",\n"
           << "  \"process_id\": " << getpid() << "\n"
           << "}\n";
    return stream.str();
}

} // namespace

std::string serializeRuntimeStatus(const RuntimeStatus& status) {
    return serialize(status);
}

bool hasRuntimeStatusTransition(const RuntimeStatus& previous,
                                const RuntimeStatus& current) {
    return previous.state != current.state ||
           previous.device != current.device ||
           previous.deviceAlias != current.deviceAlias ||
           previous.deviceAddress != current.deviceAddress ||
           previous.hostInterface != current.hostInterface ||
           previous.detail != current.detail ||
           previous.connectedSince != current.connectedSince ||
           previous.controlAvailable != current.controlAvailable;
}

RuntimeStatusPublicationPolicy::RuntimeStatusPublicationPolicy(
    std::chrono::steady_clock::duration periodicInterval)
    : periodicInterval_(periodicInterval) {}

bool RuntimeStatusPublicationPolicy::shouldPublish(
    const RuntimeStatus& status,
    std::chrono::steady_clock::time_point now,
    bool force) const {
    if (force || !lastPublishedStatus_.has_value() ||
        hasRuntimeStatusTransition(lastPublishedStatus_.value(), status)) {
        return true;
    }
    return now - lastPublishedAt_ >= periodicInterval_;
}

void RuntimeStatusPublicationPolicy::didPublish(
    const RuntimeStatus& status,
    std::chrono::steady_clock::time_point now) {
    lastPublishedStatus_ = status;
    lastPublishedAt_ = now;
}

RuntimeStatusPublisher::RuntimeStatusPublisher(
    std::chrono::steady_clock::duration periodicInterval)
    : policy_(periodicInterval) {}

bool RuntimeStatusPublisher::publish(const RuntimeStatus& status,
                                     std::string& error,
                                     bool force) {
    const auto now = std::chrono::steady_clock::now();
    if (!policy_.shouldPublish(status, now, force)) {
        return true;
    }
    if (!publishRuntimeStatus(status, error)) {
        return false;
    }
    policy_.didPublish(status, now);
    return true;
}

bool publishRuntimeStatus(const RuntimeStatus& status, std::string& error) {
    if (mkdir(kStatusDirectory, 0755) != 0 && errno != EEXIST) {
        error = "cannot create runtime status directory: " + std::string(std::strerror(errno));
        return false;
    }

    const std::string temporaryPath =
        std::string(kStatusPath) + ".tmp." + std::to_string(getpid());
    (void)unlink(temporaryPath.c_str());
    const int descriptor = open(temporaryPath.c_str(),
                                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                                0600);
    if (descriptor < 0) {
        error = "cannot create runtime status: " + std::string(std::strerror(errno));
        return false;
    }

    const bool wrote = writeAll(descriptor, serialize(status), error);
    const bool synced = wrote && fsync(descriptor) == 0;
    const int closeResult = close(descriptor);
    if (!wrote || !synced || closeResult != 0 || chmod(temporaryPath.c_str(), 0600) != 0 ||
        rename(temporaryPath.c_str(), kStatusPath) != 0) {
        if (error.empty()) {
            error = "cannot publish runtime status: " + std::string(std::strerror(errno));
        }
        (void)unlink(temporaryPath.c_str());
        return false;
    }
    return true;
}

void removeRuntimeStatus() {
    (void)unlink(kStatusPath);
}

} // namespace horndis
