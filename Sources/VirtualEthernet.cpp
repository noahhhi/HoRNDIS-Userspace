// SPDX-License-Identifier: GPL-3.0-or-later
#include "VirtualEthernet.hpp"

#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <net/bpf.h>
#include <net/if.h>
#include <poll.h>
#include <spawn.h>
#include <SystemConfiguration/SystemConfiguration.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <cctype>
#include <iostream>
#include <sstream>

extern char** environ;

namespace horndis {
namespace {

bool runCommand(const char* executable,
                const std::vector<std::string>& arguments,
                bool allowFailure,
                std::string& error) {
    std::vector<char*> argv;
    argv.reserve(arguments.size() + 2);
    argv.push_back(const_cast<char*>(executable));
    for (const auto& argument : arguments) {
        argv.push_back(const_cast<char*>(argument.c_str()));
    }
    argv.push_back(nullptr);

    pid_t child = 0;
    const int spawnResult = posix_spawn(&child, executable, nullptr, nullptr, argv.data(), environ);
    if (spawnResult != 0) {
        error = std::string("cannot run ") + executable + ": " + std::strerror(spawnResult);
        return false;
    }
    int status = 0;
    while (waitpid(child, &status, 0) < 0) {
        if (errno != EINTR) {
            error = std::string("cannot wait for ") + executable + ": " + std::strerror(errno);
            return false;
        }
    }
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        if (allowFailure) {
            return true;
        }
        std::ostringstream stream;
        stream << executable << " exited with status "
               << (WIFEXITED(status) ? WEXITSTATUS(status) : -1);
        error = stream.str();
        return false;
    }
    return true;
}

bool configureInterface(const std::string& interface,
                        const std::vector<std::string>& arguments,
                        std::string& error) {
    std::vector<std::string> command{interface};
    command.insert(command.end(), arguments.begin(), arguments.end());
    return runCommand("/sbin/ifconfig", command, false, error);
}

std::string systemConfigurationError() {
    const char* description = SCErrorString(SCError());
    return description != nullptr ? description : "unknown SystemConfiguration error";
}

bool configurePersistentDHCP(const std::string& interfaceName, std::string& error) {
    SCPreferencesRef preferences = SCPreferencesCreate(
        kCFAllocatorDefault, CFSTR("HoRNDIS Userspace"), CFSTR("io.github.noahhhi.horndis"));
    if (preferences == nullptr) {
        error = "cannot open network preferences: " + systemConfigurationError();
        return false;
    }
    if (!SCPreferencesLock(preferences, true)) {
        error = "cannot lock network preferences: " + systemConfigurationError();
        CFRelease(preferences);
        return false;
    }

    bool success = false;
    SCNetworkServiceRef service = nullptr;
    CFArrayRef services = SCNetworkServiceCopyAll(preferences);
    if (services != nullptr) {
        const CFIndex count = CFArrayGetCount(services);
        for (CFIndex index = 0; index < count; ++index) {
            const auto candidate = static_cast<SCNetworkServiceRef>(
                const_cast<void*>(CFArrayGetValueAtIndex(services, index)));
            SCNetworkInterfaceRef candidateInterface = SCNetworkServiceGetInterface(candidate);
            CFStringRef bsdName = candidateInterface != nullptr
                                      ? SCNetworkInterfaceGetBSDName(candidateInterface)
                                      : nullptr;
            if (bsdName != nullptr) {
                char buffer[IFNAMSIZ]{};
                if (CFStringGetCString(bsdName, buffer, sizeof(buffer), kCFStringEncodingUTF8) &&
                    interfaceName == buffer) {
                    service = candidate;
                    CFRetain(service);
                    break;
                }
            }
        }
        CFRelease(services);
    }

    bool created = false;
    if (service == nullptr) {
        SCNetworkInterfaceRef selectedInterface = nullptr;
        CFArrayRef interfaces = SCNetworkInterfaceCopyAll();
        if (interfaces != nullptr) {
            const CFIndex count = CFArrayGetCount(interfaces);
            for (CFIndex index = 0; index < count; ++index) {
                const auto candidate = static_cast<SCNetworkInterfaceRef>(
                    const_cast<void*>(CFArrayGetValueAtIndex(interfaces, index)));
                CFStringRef bsdName = SCNetworkInterfaceGetBSDName(candidate);
                char buffer[IFNAMSIZ]{};
                if (bsdName != nullptr &&
                    CFStringGetCString(bsdName, buffer, sizeof(buffer), kCFStringEncodingUTF8) &&
                    interfaceName == buffer) {
                    selectedInterface = candidate;
                    break;
                }
            }
            if (selectedInterface != nullptr) {
                service = SCNetworkServiceCreate(preferences, selectedInterface);
            }
            CFRelease(interfaces);
        }
        if (service == nullptr) {
            error = "cannot create a network service for " + interfaceName + ": " +
                    systemConfigurationError();
            goto cleanup;
        }
        created = true;
        if (!SCNetworkServiceEstablishDefaultConfiguration(service)) {
            error = "cannot initialize the network service: " + systemConfigurationError();
            goto cleanup;
        }
        const std::string displayName = "HoRNDIS USB (" + interfaceName + ")";
        CFStringRef name = CFStringCreateWithCString(
            kCFAllocatorDefault, displayName.c_str(), kCFStringEncodingUTF8);
        if (name != nullptr) {
            (void)SCNetworkServiceSetName(service, name);
            CFRelease(name);
        }
        SCNetworkSetRef currentSet = SCNetworkSetCopyCurrent(preferences);
        if (currentSet == nullptr || !SCNetworkSetAddService(currentSet, service)) {
            error = "cannot add the HoRNDIS service to the current network set: " +
                    systemConfigurationError();
            if (currentSet != nullptr) {
                CFRelease(currentSet);
            }
            goto cleanup;
        }
        CFRelease(currentSet);
    }

    {
        SCNetworkProtocolRef ipv4 = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeIPv4);
        if (ipv4 == nullptr) {
            if (!SCNetworkServiceAddProtocolType(service, kSCNetworkProtocolTypeIPv4)) {
                error = "cannot add IPv4 to the HoRNDIS network service: " +
                        systemConfigurationError();
                goto cleanup;
            }
            ipv4 = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeIPv4);
        }
        if (ipv4 == nullptr) {
            error = "cannot access the HoRNDIS IPv4 configuration";
            goto cleanup;
        }
        const void* keys[] = {kSCPropNetIPv4ConfigMethod};
        const void* values[] = {kSCValNetIPv4ConfigMethodDHCP};
        CFDictionaryRef configuration = CFDictionaryCreate(kCFAllocatorDefault,
                                                            keys,
                                                            values,
                                                            1,
                                                            &kCFTypeDictionaryKeyCallBacks,
                                                            &kCFTypeDictionaryValueCallBacks);
        const bool configured = configuration != nullptr &&
                                SCNetworkProtocolSetConfiguration(ipv4, configuration);
        if (configuration != nullptr) {
            CFRelease(configuration);
        }
        CFRelease(ipv4);
        if (!configured || !SCNetworkServiceSetEnabled(service, true)) {
            error = "cannot enable DHCP for the HoRNDIS network service: " +
                    systemConfigurationError();
            goto cleanup;
        }
    }

    if (!SCPreferencesCommitChanges(preferences) || !SCPreferencesApplyChanges(preferences)) {
        error = "cannot save the HoRNDIS network service: " + systemConfigurationError();
        goto cleanup;
    }
    success = true;

cleanup:
    if (!success && created && service != nullptr) {
        (void)SCNetworkServiceRemove(service);
    }
    if (service != nullptr) {
        CFRelease(service);
    }
    SCPreferencesUnlock(preferences);
    CFRelease(preferences);
    return success;
}

bool isSafeFethName(const std::string& name) {
    if (!name.starts_with("feth") || name.size() <= 4 || name.size() >= IFNAMSIZ) {
        return false;
    }
    for (size_t index = 4; index < name.size(); ++index) {
        if (!std::isdigit(static_cast<unsigned char>(name[index]))) {
            return false;
        }
    }
    return true;
}

} // namespace

VirtualEthernet::VirtualEthernet() = default;

VirtualEthernet::~VirtualEthernet() {
    close();
}

bool VirtualEthernet::createInterface(const std::string& interface,
                                      bool& created,
                                      std::string& error) {
    created = false;
    if (if_nametoindex(interface.c_str()) != 0) {
        return true;
    }
    if (!runCommand("/sbin/ifconfig", {interface, "create"}, false, error)) {
        return false;
    }
    created = true;
    return true;
}

bool VirtualEthernet::open(const std::string& hostInterface,
                           const std::string& transportInterface,
                           std::string& error) {
    close();
    if (geteuid() != 0) {
        error = "the Ethernet bridge must run as root (use sudo or a root launch service)";
        return false;
    }
    if (hostInterface == transportInterface || !isSafeFethName(hostInterface) ||
        !isSafeFethName(transportInterface)) {
        error = "virtual Ethernet interface names must be distinct feth<number> names";
        return false;
    }
    bool hostCreated = false;
    bool transportCreated = false;
    if (!createInterface(hostInterface, hostCreated, error) ||
        !createInterface(transportInterface, transportCreated, error)) {
        return false;
    }
    const bool pairAlreadyExists = !hostCreated && !transportCreated;
    if ((!pairAlreadyExists &&
         !runCommand("/sbin/ifconfig",
                     {hostInterface, "peer", transportInterface},
                     false,
                     error)) ||
        !configureInterface(hostInterface, {"mtu", "1500", "up"}, error) ||
        !configureInterface(transportInterface, {"mtu", "1500", "up"}, error)) {
        return false;
    }

    for (int index = 0; index < 256; ++index) {
        const std::string path = "/dev/bpf" + std::to_string(index);
        bpf_ = ::open(path.c_str(), O_RDWR | O_CLOEXEC);
        if (bpf_ >= 0) {
            break;
        }
        if (errno != EBUSY && errno != ENOENT) {
            error = "cannot open " + path + ": " + std::strerror(errno);
            return false;
        }
    }
    if (bpf_ < 0) {
        error = "no free Berkeley Packet Filter device is available";
        return false;
    }

    u_int requestedBufferSize = 1024 * 1024;
    (void)ioctl(bpf_, BIOCSBLEN, &requestedBufferSize);

    ifreq request{};
    std::strncpy(request.ifr_name, transportInterface.c_str(), sizeof(request.ifr_name) - 1);
    if (ioctl(bpf_, BIOCSETIF, &request) < 0) {
        error = "cannot bind BPF to " + transportInterface + ": " + std::strerror(errno);
        close();
        return false;
    }

    u_int enabled = 1;
    if (ioctl(bpf_, BIOCIMMEDIATE, &enabled) < 0 || ioctl(bpf_, BIOCSHDRCMPLT, &enabled) < 0) {
        error = "cannot configure BPF Ethernet mode: " + std::string(std::strerror(errno));
        close();
        return false;
    }
    u_int disabled = 0;
    if (ioctl(bpf_, BIOCSSEESENT, &disabled) < 0) {
        error = "cannot suppress BPF loopback packets: " + std::string(std::strerror(errno));
        close();
        return false;
    }

    u_int actualBufferSize = 0;
    if (ioctl(bpf_, BIOCGBLEN, &actualBufferSize) < 0 || actualBufferSize == 0) {
        error = "cannot query the BPF buffer size: " + std::string(std::strerror(errno));
        close();
        return false;
    }
    readBuffer_.resize(actualBufferSize);
    readOffset_ = readBuffer_.size();
    bpfBufferSize_ = actualBufferSize;
    hostInterface_ = hostInterface;
    transportInterface_ = transportInterface;

    std::string persistentError;
    if (!configurePersistentDHCP(hostInterface, persistentError)) {
        std::cerr << "horndis: SystemConfiguration could not register " << hostInterface
                  << " (" << persistentError << "); using the macOS DHCP compatibility path\n";
        if (!runCommand("/usr/sbin/ipconfig", {"set", hostInterface, "DHCP"}, false, error)) {
            close();
            return false;
        }
    }
    return true;
}

bool VirtualEthernet::adoptDescriptor(int descriptor,
                                      const std::string& hostInterface,
                                      const std::string& transportInterface,
                                      std::string& error) {
    close();
    if (descriptor < 0 || !isSafeFethName(hostInterface) ||
        !isSafeFethName(transportInterface) || hostInterface == transportInterface) {
        error = "cannot adopt an invalid Ethernet bridge descriptor";
        return false;
    }
    if (fcntl(descriptor, F_GETFD) < 0 || fcntl(descriptor, F_SETFD, FD_CLOEXEC) != 0) {
        error = "cannot secure the inherited BPF descriptor: " + std::string(std::strerror(errno));
        return false;
    }
    bpf_ = descriptor;
    u_int actualBufferSize = 0;
    if (ioctl(bpf_, BIOCGBLEN, &actualBufferSize) < 0 || actualBufferSize == 0) {
        error = "cannot query the inherited BPF buffer size: " +
                std::string(std::strerror(errno));
        close();
        return false;
    }
    bpfBufferSize_ = actualBufferSize;
    readBuffer_.resize(bpfBufferSize_);
    readOffset_ = readBuffer_.size();
    hostInterface_ = hostInterface;
    transportInterface_ = transportInterface;
    return flush(error);
}

bool VirtualEthernet::flush(std::string& error) {
    if (bpf_ < 0) {
        error = "BPF Ethernet bridge is not open";
        return false;
    }
    if (ioctl(bpf_, BIOCFLUSH) < 0) {
        error = "cannot flush the BPF bridge: " + std::string(std::strerror(errno));
        return false;
    }
    readBuffer_.resize(bpfBufferSize_);
    readOffset_ = readBuffer_.size();
    return true;
}

bool VirtualEthernet::readFrame(std::vector<uint8_t>& frame, bool& timedOut, std::string& error) {
    timedOut = false;
    if (bpf_ < 0) {
        error = "BPF Ethernet bridge is not open";
        return false;
    }

    while (true) {
        if (readOffset_ < readBuffer_.size()) {
            const size_t remaining = readBuffer_.size() - readOffset_;
            if (remaining < sizeof(bpf_hdr)) {
                readOffset_ = readBuffer_.size();
                continue;
            }
            const auto* header = reinterpret_cast<const bpf_hdr*>(readBuffer_.data() + readOffset_);
            const size_t rawRecordLength = header->bh_hdrlen + header->bh_caplen;
            if (header->bh_hdrlen == 0 || header->bh_hdrlen > remaining ||
                header->bh_caplen > remaining - header->bh_hdrlen) {
                error = "BPF returned a malformed packet record";
                return false;
            }
            const size_t alignedRecordLength = BPF_WORDALIGN(rawRecordLength);
            const size_t recordLength = std::min(alignedRecordLength, remaining);
            const uint8_t* packet = readBuffer_.data() + readOffset_ + header->bh_hdrlen;
            frame.assign(packet, packet + header->bh_caplen);
            readOffset_ += recordLength;
            return true;
        }

        pollfd descriptor{bpf_, POLLIN, 0};
        const int pollResult = poll(&descriptor, 1, 500);
        if (pollResult == 0) {
            timedOut = true;
            return false;
        }
        if (pollResult < 0) {
            if (errno == EINTR) {
                timedOut = true;
                return false;
            }
            error = "BPF poll failed: " + std::string(std::strerror(errno));
            return false;
        }
        readBuffer_.resize(bpfBufferSize_);
        const ssize_t count = ::read(bpf_, readBuffer_.data(), readBuffer_.size());
        if (count < 0) {
            if (errno == EINTR || errno == EAGAIN) {
                timedOut = true;
                return false;
            }
            error = "BPF read failed: " + std::string(std::strerror(errno));
            return false;
        }
        readBuffer_.resize(static_cast<size_t>(count));
        readOffset_ = 0;
        if (count == 0) {
            timedOut = true;
            return false;
        }
    }
}

bool VirtualEthernet::writeFrame(const std::vector<uint8_t>& frame, std::string& error) {
    if (bpf_ < 0) {
        error = "BPF Ethernet bridge is not open";
        return false;
    }
    const ssize_t count = ::write(bpf_, frame.data(), frame.size());
    if (count < 0) {
        error = "BPF write failed: " + std::string(std::strerror(errno));
        return false;
    }
    if (static_cast<size_t>(count) != frame.size()) {
        error = "BPF only wrote part of an Ethernet frame";
        return false;
    }
    return true;
}

void VirtualEthernet::close() {
    if (bpf_ >= 0) {
        ::close(bpf_);
        bpf_ = -1;
    }
    readBuffer_.clear();
    readOffset_ = 0;
    bpfBufferSize_ = 0;
    hostInterface_.clear();
    transportInterface_.clear();
}

} // namespace horndis
