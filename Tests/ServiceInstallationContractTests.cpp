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

} // namespace

int main(int argc, char* argv[]) {
    assert(argc == 2);
    const std::string source = readFile(argv[1]);
    assert(!source.empty());

    assert(source.find("constexpr const char* kHelperDirectory = "
                       "\"/Library/PrivilegedHelperTools\"") != std::string::npos);
    assert(source.find("mkdir(kHelperDirectory, 01755)") != std::string::npos);
    assert(source.find("chmod(kHelperDirectory, 01755)") != std::string::npos);
    assert(source.find("errno != EEXIST") != std::string::npos);
    assert(source.find("lstat(kHelperDirectory, &metadata)") != std::string::npos);
    assert(source.find("S_ISDIR(metadata.st_mode)") != std::string::npos);

    const size_t ensureCall = source.find("if (!ensureHelperDirectory(error))");
    const size_t bootoutCall = source.find("runLaunchctl({\"bootout\"");
    const size_t helperCopy = source.find("copyfile(source.c_str(), temporaryHelper.c_str()");
    assert(ensureCall != std::string::npos);
    assert(bootoutCall != std::string::npos);
    assert(helperCopy != std::string::npos);
    assert(ensureCall < bootoutCall);
    assert(bootoutCall < helperCopy);

    std::cout << "Service installation directory contract passed\n";
    return 0;
}
