// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <cstddef>
#include <map>
#include <string>

namespace horndis {

// Maps an opaque, in-memory-only device key to a first-seen diagnostic alias.
// The key is never exposed or persisted by this type.
class DeviceAliasRegistry {
public:
    size_t aliasFor(const std::string& opaqueKey) {
        const auto [alias, inserted] = aliases_.emplace(opaqueKey, nextAlias_);
        if (inserted) {
            ++nextAlias_;
        }
        return alias->second;
    }

private:
    std::map<std::string, size_t> aliases_;
    size_t nextAlias_ = 1;
};

} // namespace horndis
