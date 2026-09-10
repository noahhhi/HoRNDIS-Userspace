// SPDX-License-Identifier: GPL-3.0-or-later
#include "NetworkService.hpp"
#include <SystemConfiguration/SystemConfiguration.h>
#include <dlfcn.h>
#include <net/if.h>
#include <unistd.h>
#include <cctype>
#include <cstdio>
#include <vector>
#include <set>

namespace horndis {
namespace {
// Apple's configd bridge SPI is not in the public SDK. Resolve it at runtime:
// an unavailable backend must not prevent the existing feth path from working.
struct BridgeAPI {
    SCNetworkInterfaceRef (*create)(SCPreferencesRef) =
        reinterpret_cast<decltype(create)>(dlsym(RTLD_DEFAULT, "SCBridgeInterfaceCreate"));
    CFArrayRef (*copyAll)(SCPreferencesRef) =
        reinterpret_cast<decltype(copyAll)>(dlsym(RTLD_DEFAULT, "SCBridgeInterfaceCopyAll"));
    Boolean (*remove)(SCNetworkInterfaceRef) =
        reinterpret_cast<decltype(remove)>(dlsym(RTLD_DEFAULT, "SCBridgeInterfaceRemove"));
    CFDictionaryRef (*options)(SCNetworkInterfaceRef) =
        reinterpret_cast<decltype(options)>(dlsym(RTLD_DEFAULT, "SCBridgeInterfaceGetOptions"));
    Boolean (*setOptions)(SCNetworkInterfaceRef, CFDictionaryRef) =
        reinterpret_cast<decltype(setOptions)>(dlsym(RTLD_DEFAULT, "SCBridgeInterfaceSetOptions"));
    explicit operator bool() const { return create && copyAll && remove && options && setOptions; }
};
constexpr auto kOwner = "io.github.noahhhi.horndis.network-v1";
std::string stringValue(CFStringRef value) {
    char buffer[256]{};
    if (!value || CFGetTypeID(value) != CFStringGetTypeID() ||
        !CFStringGetCString(value, buffer, sizeof(buffer), kCFStringEncodingUTF8)) return {};
    return buffer;
}
bool owned(CFDictionaryRef options) {
    return options && CFGetTypeID(options) == CFDictionaryGetTypeID() &&
        stringValue(static_cast<CFStringRef>(CFDictionaryGetValue(options, CFSTR("HoRNDISOwner")))) == kOwner;
}
// Refuse to attach to or delete a bridge with any existing member, including
// members missing from the stored bridge configuration.
bool emptyBridge(const std::string& name) {
    if (!isBridgeName(name)) return false;
    if (!if_nametoindex(name.c_str())) return true;
    const std::string command = "/sbin/ifconfig " + name;
    FILE* output = popen(command.c_str(), "r");
    if (!output) return false;
    bool empty = true;
    char line[1024];
    while (fgets(line, sizeof(line), output)) {
        if (std::string(line).find("member:") != std::string::npos) empty = false;
    }
    return pclose(output) == 0 && empty;
}
bool safeMemberApply(SCPreferencesRef prefs) {
    auto runtime = if_nameindex();
    if (!runtime) return false;
    bool safe = true;
    for (auto entry = runtime; entry->if_index; ++entry) {
        const std::string name = entry->if_name;
        if (!isBridgeName(name) || name.size() > 8) continue;
        auto path = CFStringCreateWithFormat(nullptr, nullptr,
            CFSTR("/VirtualNetworkInterfaces/Bridge/%s"), name.c_str());
        if (!SCPreferencesPathGetValue(prefs, path)) safe = false;
        CFRelease(path);
    }
    if_freenameindex(runtime);
    return safe;
}
bool configure(bool removing, std::string& name, std::string& error) {
    error.clear();
    BridgeAPI api;
    if (geteuid() != 0 || !api) {
        error = "network service configuration requires root and the macOS bridge API";
        return false;
    }
    auto prefs = SCPreferencesCreate(nullptr, CFSTR("HoRNDIS Userspace"), nullptr);
    if (!prefs) { error = "cannot open system network preferences"; return false; }
    if (!SCPreferencesLock(prefs, true)) {
        CFRelease(prefs); error = "cannot lock system network preferences"; return false;
    }
    SCNetworkInterfaceRef bridge = nullptr;
    SCNetworkServiceRef service = nullptr;
    SCNetworkSetRef set = nullptr;
    bool ok = false;
    bool changed = false;
    // All changes before commit are confined to this locked preferences session.
    auto bridges = api.copyAll(prefs);
    std::set<std::string> configuredNames;
    if (bridges) {
        for (CFIndex i = 0; i < CFArrayGetCount(bridges); ++i) {
            auto candidate = static_cast<SCNetworkInterfaceRef>(CFArrayGetValueAtIndex(bridges, i));
            configuredNames.insert(stringValue(SCNetworkInterfaceGetBSDName(candidate)));
            if (owned(api.options(candidate))) {
                if (bridge) { error = "multiple owned network bridges; refusing ambiguous cleanup"; break; }
                bridge = candidate; CFRetain(bridge);
            }
        }
        CFRelease(bridges);
    }
    // configd reconciles ALL bridges numbered below 100 when preferences are
    // applied. Do not trigger that reconciliation if another program has a
    // runtime-only bridge there: configd could otherwise destroy that bridge.
    auto runtime = (removing && !bridge) ? nullptr : if_nameindex();
    if (!runtime && !(removing && !bridge)) error = "cannot enumerate runtime network interfaces";
    else if (runtime) {
        for (auto entry = runtime; entry->if_index; ++entry) {
            const std::string runtimeName = entry->if_name;
            if (isBridgeName(runtimeName) && runtimeName.size() <= 8 &&
                !configuredNames.contains(runtimeName)) {
                error = "unmanaged runtime bridge exists; refusing global bridge reconciliation";
            }
        }
        if_freenameindex(runtime);
    }
    do {
        if (!error.empty()) break;
        if (bridge) {
            name = stringValue(SCNetworkInterfaceGetBSDName(bridge));
            if (!emptyBridge(name)) { error = "owned bridge has existing members; leaving it unchanged"; break; }
            auto id = static_cast<CFStringRef>(CFDictionaryGetValue(api.options(bridge), CFSTR("HoRNDISServiceID")));
            if (!id || stringValue(id).empty()) { error = "owned bridge has no service identity"; break; }
            service = SCNetworkServiceCopy(prefs, id);
            if (service) {
                auto interface = SCNetworkServiceGetInterface(service);
                if (!interface || stringValue(SCNetworkInterfaceGetBSDName(interface)) != name) {
                    error = "network service identity changed; leaving it unchanged"; break;
                }
            }
        } else if (removing) { ok = true; break; }
        if (removing) {
            if ((service && !SCNetworkServiceRemove(service)) || !api.remove(bridge)) break;
            changed = true;
        } else {
            if (!bridge) {
                // SPI checks preferences, not runtime occupancy. Reserve skipped
                // candidates only in memory, never commit or destroy those names.
                std::vector<SCNetworkInterfaceRef> skipped;
                for (int attempt = 0; attempt < 100; ++attempt) {
                    auto candidate = api.create(prefs);
                    if (!candidate) break;
                    auto candidateName = stringValue(SCNetworkInterfaceGetBSDName(candidate));
                    if (isBridgeName(candidateName) && !if_nametoindex(candidateName.c_str())) {
                        bridge = candidate; name = candidateName; break;
                    }
                    skipped.push_back(candidate);
                }
                for (auto candidate : skipped) { api.remove(candidate); CFRelease(candidate); }
                if (!bridge) break;
                changed = true;
            }
            if (!service) {
                service = SCNetworkServiceCreate(prefs, bridge);
                if (!service || !SCNetworkServiceEstablishDefaultConfiguration(service) ||
                    !SCNetworkServiceSetName(service, CFSTR("HoRNDIS USB"))) break;
                const void* keys[] = {CFSTR("HoRNDISOwner"), CFSTR("HoRNDISServiceID")};
                const void* values[] = {CFSTR("io.github.noahhhi.horndis.network-v1"), SCNetworkServiceGetServiceID(service)};
                auto options = CFDictionaryCreate(nullptr, keys, values, 2,
                    &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
                bool marked = api.setOptions(bridge, options);
                CFRelease(options);
                if (!marked) break;
                changed = true;
            }
            set = SCNetworkSetCopyCurrent(prefs);
            if (!set) break;
            auto services = SCNetworkSetCopyServices(set);
            bool included = services && CFArrayContainsValue(services, CFRangeMake(0, CFArrayGetCount(services)), service);
            if (services) CFRelease(services);
            if (!included) {
                if (!SCNetworkSetAddService(set, service)) break;
                changed = true;
            }
        }
        if (changed && !SCPreferencesCommitChanges(prefs)) break;
        // Apply on reuse too, including recovery from a previous apply failure.
        if (!SCPreferencesApplyChanges(prefs)) break;
        ok = true;
    } while (false);
    if (!ok && error.empty()) error = std::string("cannot configure HoRNDIS network service: ") + SCErrorString(SCError());
    if (set) CFRelease(set);
    if (service) CFRelease(service);
    if (bridge) CFRelease(bridge);
    SCPreferencesUnlock(prefs); CFRelease(prefs);
    return ok;
}
}
bool isBridgeName(const std::string& name) {
    if (!name.starts_with("bridge") || name.size() <= 6 || name.size() >= IFNAMSIZ) return false;
    for (size_t i = 6; i < name.size(); ++i) if (!std::isdigit(static_cast<unsigned char>(name[i]))) return false;
    return true;
}
bool ensureNetworkService(std::string& bridgeName, std::string& error) { return configure(false, bridgeName, error); }
bool setNetworkServiceMember(const std::string& bridgeName, const std::string& member,
                             bool attached, std::string& error) {
    if (geteuid() != 0 || !isBridgeName(bridgeName) || !member.starts_with("feth") ||
        member.size() <= 4 || member.size() >= IFNAMSIZ ||
        member.find_first_not_of("0123456789", 4) != std::string::npos) {
        error = "invalid owned network member"; return false;
    }
    auto prefs = SCPreferencesCreate(nullptr, CFSTR("HoRNDIS Userspace"), nullptr);
    if (!prefs) { error = "cannot open network preferences"; return false; }
    if (!SCPreferencesLock(prefs, true)) { CFRelease(prefs); error = "cannot lock network preferences"; return false; }
    auto path = CFStringCreateWithFormat(nullptr, nullptr, CFSTR("/VirtualNetworkInterfaces/Bridge/%s"), bridgeName.c_str());
    auto name = CFStringCreateWithCString(nullptr, member.c_str(), kCFStringEncodingUTF8);
    auto configuration = SCPreferencesPathGetValue(prefs, path);
    bool ok = false;
    do {
        if (!configuration || !owned(static_cast<CFDictionaryRef>(CFDictionaryGetValue(configuration, CFSTR("Options"))))) break;
        auto current = static_cast<CFArrayRef>(CFDictionaryGetValue(configuration, CFSTR("Interfaces")));
        if (!current || CFGetTypeID(current) != CFArrayGetTypeID()) break;
        const auto count = CFArrayGetCount(current);
        // Never replace someone else's configured members, even on our bridge.
        if (count > 1 || (count == 1 && !CFEqual(CFArrayGetValueAtIndex(current, 0), name))) break;
        if (count == (attached ? 1 : 0)) { ok = true; break; }
        if (!safeMemberApply(prefs) || (attached && !if_nametoindex(member.c_str()))) break;
        auto updated = CFDictionaryCreateMutableCopy(nullptr, 0, configuration);
        const void* values[] = {name};
        auto members = CFArrayCreate(nullptr, values, attached ? 1 : 0, &kCFTypeArrayCallBacks);
        // feth is representable by configd but is not offered by the bridge
        // member picker. Store its real BSD name in Apple's bridge schema;
        // runtime attachment remains an exclusively owned ifconfig operation.
        // Network Settings derives bridge status from this membership list.
        CFDictionarySetValue(updated, CFSTR("Interfaces"), members);
        ok = SCPreferencesPathSetValue(prefs, path, updated) &&
             SCPreferencesCommitChanges(prefs) && SCPreferencesApplyChanges(prefs);
        CFRelease(members); CFRelease(updated);
    } while (false);
    CFRelease(name); CFRelease(path); SCPreferencesUnlock(prefs); CFRelease(prefs);
    if (!ok) error = "cannot update owned bridge membership";
    return ok;
}
bool refreshNetworkService(const std::string& bridgeName, std::string& error) {
    if (geteuid() != 0 || !isBridgeName(bridgeName)) {
        error = "invalid network service refresh"; return false;
    }
    auto interfaces = SCNetworkInterfaceCopyAll();
    bool refreshed = false;
    if (interfaces) {
        for (CFIndex i = 0; i < CFArrayGetCount(interfaces); ++i) {
            auto interface = static_cast<SCNetworkInterfaceRef>(CFArrayGetValueAtIndex(interfaces, i));
            if (stringValue(SCNetworkInterfaceGetBSDName(interface)) == bridgeName) {
                refreshed = SCNetworkInterfaceForceConfigurationRefresh(interface); break;
            }
        }
        CFRelease(interfaces);
    }
    if (!refreshed) error = "cannot refresh the registered network service";
    return refreshed;
}
bool removeNetworkService(std::string& error) { std::string name; return configure(true, name, error); }
}
