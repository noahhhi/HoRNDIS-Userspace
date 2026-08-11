// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <string>

namespace horndis {

bool installLaunchDaemon(std::string& error);
bool uninstallLaunchDaemon(std::string& error);

} // namespace horndis
