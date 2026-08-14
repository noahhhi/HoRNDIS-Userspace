// SPDX-License-Identifier: GPL-3.0-or-later
#include <cassert>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>

namespace {

std::string readFile(const char* path) {
    std::ifstream stream(path);
    std::ostringstream contents;
    contents << stream.rdbuf();
    return contents.str();
}

std::string functionBody(const std::string& source,
                         const std::string& function,
                         const std::string& nextFunction) {
    const size_t start = source.find(function);
    assert(start != std::string::npos);
    const size_t end = source.find(nextFunction, start + function.size());
    assert(end != std::string::npos);
    return source.substr(start, end - start);
}

} // namespace

int main(int argc, char* argv[]) {
    assert(argc == 2);
    const std::string source = readFile(argv[1]);
    assert(!source.empty());

    assert(source.find("__strong NSMutableData* bulkInData") != std::string::npos);
    assert(source.find("__strong NSMutableData* bulkOutData") != std::string::npos);
    assert(source.find("std::vector<uint8_t> bulkOutPacket") != std::string::npos);

    const std::string readBody = functionBody(source,
                                               "RNDISUSBTransport::readEthernetFrame",
                                               "RNDISUSBTransport::writeEthernetFrame");
    assert(readBody.find("@autoreleasepool") != std::string::npos);
    assert(readBody.find("impl_->bulkInData") != std::string::npos);
    assert(readBody.find("dataWithLength:maxTransferSize_") == std::string::npos);

    const std::string writeBody = functionBody(source,
                                                "RNDISUSBTransport::writeEthernetFrame",
                                                "RNDISUSBTransport::close");
    assert(writeBody.find("@autoreleasepool") != std::string::npos);
    assert(writeBody.find("impl_->bulkOutData") != std::string::npos);
    assert(writeBody.find("impl_->bulkOutPacket") != std::string::npos);
    assert(writeBody.find("dataWithBytes:") == std::string::npos);

    std::cout << "USB transport memory contract passed\n";
    return 0;
}
