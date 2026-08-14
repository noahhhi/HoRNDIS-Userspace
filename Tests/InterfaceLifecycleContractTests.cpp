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

void require(const std::string& source, const std::string& fragment) {
    assert(source.find(fragment) != std::string::npos);
}

} // namespace

int main(int argc, char* argv[]) {
    assert(argc == 4);
    const std::string ethernetSource = readFile(argv[1]);
    const std::string mainSource = readFile(argv[2]);
    const std::string statusSource = readFile(argv[3]);

    require(ethernetSource, "if_nametoindex(pair.host.c_str()) != 0");
    require(ethernetSource, "if_nametoindex(pair.transport.c_str()) != 0");
    require(ethernetSource, "refusing to use an existing virtual Ethernet interface");
    require(ethernetSource, "ownsInterfaces_ = true");
    require(ethernetSource, "if (ownsInterfaces_ && geteuid() == 0)");
    require(ethernetSource, "{hostInterface_, \"destroy\"}");
    require(ethernetSource, "{transportInterface_, \"destroy\"}");
    require(mainSource,
            "HORNDIS_HOST_INTERFACE and HORNDIS_TRANSPORT_INTERFACE must be set together");
    require(mainSource, "const std::string hostInterface = ethernet.hostInterface()");
    require(mainSource, "const std::string transportInterface = ethernet.transportInterface()");
    assert(statusSource.find("ipv4Address(for: \"feth99\")") == std::string::npos);

    std::cout << "Interface lifecycle source contract passed\n";
    return 0;
}
