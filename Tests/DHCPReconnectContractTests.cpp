// SPDX-License-Identifier: GPL-3.0-or-later
#include <cassert>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>

namespace {

std::string readFile(const char* path) {
    std::ifstream input(path);
    assert(input.good());
    std::ostringstream contents;
    contents << input.rdbuf();
    return contents.str();
}

size_t require(const std::string& source, const std::string& fragment) {
    const size_t position = source.find(fragment);
    assert(position != std::string::npos);
    return position;
}

} // namespace

int main(int argc, char* argv[]) {
    assert(argc == 3);
    const std::string mainSource = readFile(argv[1]);
    const std::string ethernetSource = readFile(argv[2]);

    const size_t initialize = require(mainSource, "if (!usb.initialize(deviceAddress, error))");
    const size_t refresh = require(
        mainSource, "if (!horndis::requestDHCPRefresh(supervisorDescriptor, error))");
    const size_t connected = require(mainSource, "runtimeStatus.state = \"connected\"");
    assert(initialize < refresh);
    assert(refresh < connected);

    require(mainSource, "success = ethernet.refreshDHCP(error)");
    require(mainSource, "superviseAgentDHCP(supervisorDescriptor, ethernet)");

    // The connected session must probe IPv4 liveness and repair a stripped
    // address through the supervisor channel, with a grace period so the
    // probe never races DHCP negotiation or floods refresh requests.
    const size_t probe = require(mainSource, "if (interfaceHasIPv4(hostInterface))");
    assert(connected < probe);
    require(mainSource, "constexpr auto kAddressGracePeriod");
    const size_t repair = require(
        mainSource, "if (!horndis::requestDHCPRefresh(supervisorDescriptor, repairError))");
    assert(probe < repair);
    require(mainSource, "lastDhcpRepair >= kAddressGracePeriod");

    require(ethernetSource,
            "configureInterface(hostInterface_, {\"mtu\", \"1500\", \"up\"}, error)");
    require(ethernetSource,
            "configureInterface(transportInterface_, {\"mtu\", \"1500\", \"up\"}, error)");
    require(ethernetSource,
            "runCommand(\"/usr/sbin/ipconfig\", {\"set\", hostInterface_, \"DHCP\"}");

    std::cout << "DHCP reconnect source contract passed\n";
    return 0;
}
