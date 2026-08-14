// SPDX-License-Identifier: GPL-3.0-or-later
#include "DeviceAliases.hpp"

#include <cassert>
#include <iostream>

int main() {
    horndis::DeviceAliasRegistry aliases;
    assert(aliases.aliasFor("opaque-phone-a") == 1);
    assert(aliases.aliasFor("opaque-phone-a") == 1);
    assert(aliases.aliasFor("opaque-phone-b") == 2);
    assert(aliases.aliasFor("opaque-phone-a") == 1);
    assert(aliases.aliasFor("opaque-phone-c") == 3);
    assert(aliases.aliasFor("opaque-phone-b") == 2);
    std::cout << "Device alias stability tests passed\n";
    return 0;
}
