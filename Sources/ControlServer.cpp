// SPDX-License-Identifier: GPL-3.0-or-later
#include "ControlServer.hpp"

#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#include <SystemConfiguration/SystemConfiguration.h>

namespace horndis {
namespace {

constexpr const char* kRuntimeDirectory = "/var/run/horndis";
constexpr const char* kControlPath = "/var/run/horndis/control.sock";

bool isConsoleUser(int descriptor) {
    uid_t peerUser = 0;
    gid_t peerGroup = 0;
    if (getpeereid(descriptor, &peerUser, &peerGroup) != 0) {
        return false;
    }
    if (peerUser == 0) {
        return true;
    }
    uid_t consoleUser = 0;
    gid_t consoleGroup = 0;
    CFStringRef userName = SCDynamicStoreCopyConsoleUser(nullptr, &consoleUser, &consoleGroup);
    if (userName != nullptr) {
        CFRelease(userName);
    }
    return peerUser == consoleUser;
}

} // namespace

ControlServer::ControlServer() = default;

ControlServer::~ControlServer() {
    close();
}

bool ControlServer::start(std::string& error) {
    close();
    if (mkdir(kRuntimeDirectory, 0755) != 0 && errno != EEXIST) {
        error = "cannot create control socket directory: " + std::string(std::strerror(errno));
        return false;
    }
    socket_ = socket(AF_UNIX, SOCK_STREAM, 0);
    if (socket_ < 0) {
        error = "cannot create control socket: " + std::string(std::strerror(errno));
        return false;
    }
    if (fcntl(socket_, F_SETFL, O_NONBLOCK) != 0 || fcntl(socket_, F_SETFD, FD_CLOEXEC) != 0) {
        error = "cannot configure control socket: " + std::string(std::strerror(errno));
        close();
        return false;
    }

    sockaddr_un address{};
    address.sun_family = AF_UNIX;
    address.sun_len = sizeof(address);
    static_assert(sizeof(kControlPath) <= sizeof(address.sun_path));
    std::strncpy(address.sun_path, kControlPath, sizeof(address.sun_path) - 1);
    (void)unlink(kControlPath);
    if (bind(socket_, reinterpret_cast<const sockaddr*>(&address), sizeof(address)) != 0 ||
        chmod(kControlPath, 0600) != 0 || listen(socket_, 4) != 0) {
        error = "cannot publish control socket: " + std::string(std::strerror(errno));
        close();
        return false;
    }
    return true;
}

std::vector<ControlCommand> ControlServer::pollCommands() {
    std::vector<ControlCommand> commands;
    if (socket_ < 0) {
        return commands;
    }

    // Drain a bounded batch so a visible menu's observation renewals cannot
    // fill the listen queue or delay a later connect/disconnect command. The
    // bound prevents a client from monopolizing the USB forwarding loop.
    constexpr size_t kMaximumBatchSize = 16;
    for (size_t index = 0; index < kMaximumBatchSize; ++index) {
        const int client = accept(socket_, nullptr, nullptr);
        if (client < 0) {
            break;
        }
        if (!isConsoleUser(client)) {
            (void)::close(client);
            continue;
        }

        char buffer[32]{};
        const ssize_t count = read(client, buffer, sizeof(buffer) - 1);
        (void)::close(client);
        if (count <= 0) {
            continue;
        }
        const std::string command(buffer, static_cast<size_t>(count));
        if (command.starts_with("connect")) {
            commands.push_back(ControlCommand::connect);
        } else if (command.starts_with("disconnect")) {
            commands.push_back(ControlCommand::disconnect);
        } else if (command.starts_with("observe")) {
            commands.push_back(ControlCommand::observe);
        }
    }
    return commands;
}

void ControlServer::close() {
    if (socket_ >= 0) {
        (void)::close(socket_);
        socket_ = -1;
    }
    (void)unlink(kControlPath);
}

} // namespace horndis
