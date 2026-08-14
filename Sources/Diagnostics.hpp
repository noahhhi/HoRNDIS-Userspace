// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <string>

namespace horndis {

std::string buildDiagnosticReport(const std::string& version);
bool writeDiagnosticReport(const std::string& path,
                           const std::string& version,
                           std::string& error);

} // namespace horndis
