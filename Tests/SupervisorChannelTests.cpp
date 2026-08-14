// SPDX-License-Identifier: GPL-3.0-or-later
#include "SupervisorChannel.hpp"

#include <cassert>
#include <iostream>
#include <string>
#include <sys/socket.h>
#include <thread>
#include <unistd.h>

namespace {

void testResponse(bool supervisorSuccess) {
    int descriptors[2]{-1, -1};
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, descriptors) == 0);

    bool agentResult = false;
    std::string agentError;
    std::thread agent([&] {
        agentResult = horndis::requestDHCPRefresh(descriptors[1], agentError);
        close(descriptors[1]);
    });

    horndis::SupervisorRequest request{};
    bool closed = false;
    std::string supervisorError;
    assert(horndis::receiveSupervisorRequest(
        descriptors[0], request, closed, supervisorError));
    assert(!closed);
    assert(request == horndis::SupervisorRequest::refreshDHCP);
    assert(horndis::sendSupervisorResponse(
        descriptors[0], supervisorSuccess, supervisorError));
    close(descriptors[0]);
    agent.join();

    assert(agentResult == supervisorSuccess);
    if (supervisorSuccess) {
        assert(agentError.empty());
    } else {
        assert(agentError.find("could not start DHCP") != std::string::npos);
    }
}

} // namespace

int main() {
    testResponse(true);
    testResponse(false);

    int descriptors[2]{-1, -1};
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, descriptors) == 0);
    close(descriptors[1]);
    horndis::SupervisorRequest request{};
    bool closed = false;
    std::string error;
    assert(horndis::receiveSupervisorRequest(descriptors[0], request, closed, error));
    assert(closed);
    assert(error.empty());
    close(descriptors[0]);

    std::cout << "Supervisor channel tests passed\n";
    return 0;
}
