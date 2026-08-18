// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <string>

namespace horndis {

std::string buildDiagnosticReport(const std::string& version);
bool writeDiagnosticReport(const std::string& path,
                           const std::string& version,
                           std::string& error);

// Exposed for tests: the sanitizer applied to every command output, log copy,
// and report body before it can leave the machine.
std::string redactDiagnosticText(std::string text);

} // namespace horndis
