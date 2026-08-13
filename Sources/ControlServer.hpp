// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <string>
#include <vector>

namespace horndis {

enum class ControlCommand {
    connect,
    disconnect,
    observe,
};

class ControlServer {
public:
    ControlServer();
    ~ControlServer();

    ControlServer(const ControlServer&) = delete;
    ControlServer& operator=(const ControlServer&) = delete;

    bool start(std::string& error);
    std::vector<ControlCommand> pollCommands();
    void close();

private:
    int socket_ = -1;
};

} // namespace horndis
