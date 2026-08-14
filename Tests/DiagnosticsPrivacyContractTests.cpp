// SPDX-License-Identifier: GPL-3.0-or-later
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>

namespace {

std::string readFile(const char* path) {
    std::ifstream input(path);
    std::ostringstream contents;
    contents << input.rdbuf();
    return contents.str();
}

void requireContains(const std::string& text,
                     const std::string& fragment,
                     const char* message) {
    if (text.find(fragment) == std::string::npos) {
        std::cerr << message << ": missing `" << fragment << "`\n";
        std::exit(1);
    }
}

void requireAbsent(const std::string& text,
                   const std::string& fragment,
                   const char* message) {
    if (text.find(fragment) != std::string::npos) {
        std::cerr << message << ": found forbidden `" << fragment << "`\n";
        std::exit(1);
    }
}

} // namespace

int main(int argc, char* argv[]) {
    if (argc != 5) {
        std::cerr << "usage: diagnostics-privacy-contract-tests "
                     "<main.mm> <Diagnostics.mm> <bug-form.yml> <config.yml>\n";
        return 64;
    }
    const std::string mainSource = readFile(argv[1]);
    const std::string diagnosticsSource = readFile(argv[2]);
    const std::string bugForm = readFile(argv[3]);
    const std::string issueConfig = readFile(argv[4]);

    requireContains(mainSource, "DeviceAliasRegistry deviceAliases",
                    "device aliases must be stable across reconnects");
    requireContains(mainSource, "connected device \" + std::to_string(deviceNumber)",
                    "service logs must use device aliases");
    requireContains(mainSource, "data agent for user",
                    "service logs must use the user alias");
    requireAbsent(mainSource, "serial=", "USB probe must not print serial numbers");
    requireAbsent(mainSource, "logLine(\"connected \" + device->product",
                  "service logs must not print device names");
    requireAbsent(mainSource, "logLine(\"started unprivileged data agent as uid",
                  "service logs must not print user IDs");

    requireContains(diagnosticsSource, "safeRuntimeSummary",
                    "diagnostics must whitelist runtime fields");
    requireContains(diagnosticsSource, "safeNetworkSummary",
                    "diagnostics must summarize network state without addresses");
    requireContains(diagnosticsSource, "@\"device_alias\", \"Device\"",
                    "diagnostics must use the service's stable device alias");
    requireContains(diagnosticsSource, "USB function \" << (index + 1)",
                    "diagnostics must number anonymous USB functions");
    requireAbsent(diagnosticsSource, "device.product.empty",
                  "diagnostics must not collect device names");
    requireAbsent(diagnosticsSource, "device.serial",
                  "diagnostics must not collect USB serial numbers");
    requireAbsent(diagnosticsSource, "device.locationId",
                  "diagnostics must not collect USB location IDs");
    requireAbsent(diagnosticsSource, "ioreg",
                  "diagnostics must not collect complete IORegistry data");
    requireAbsent(diagnosticsSource, "ipconfig",
                  "diagnostics must not collect DHCP address values");
    requireAbsent(diagnosticsSource, "scutil",
                  "diagnostics must not collect active network addresses");

    requireContains(bugForm, "type: upload",
                    "bug form must use a real file-upload control");
    requireContains(bugForm, "id: diagnostics",
                    "bug form must identify the diagnostic upload");
    requireContains(bugForm, "accept: \".txt,.log,.zip\"",
                    "bug form must restrict diagnostic attachment types");
    requireContains(bugForm, "required: true",
                    "bug form diagnostic upload must be required");
    requireContains(issueConfig, "blank_issues_enabled: false",
                    "blank external issues must be disabled");

    std::cout << "Diagnostics privacy and issue-form contract passed\n";
    return 0;
}
