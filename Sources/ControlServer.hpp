// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <optional>
#include <string>

namespace horndis {

enum class ControlCommand {
    connect,
    disconnect,
};

class ControlServer {
public:
    ControlServer();
    ~ControlServer();

    ControlServer(const ControlServer&) = delete;
    ControlServer& operator=(const ControlServer&) = delete;

    bool start(std::string& error);
    std::optional<ControlCommand> pollCommand();
    void close();

private:
    int socket_ = -1;
};

} // namespace horndis
