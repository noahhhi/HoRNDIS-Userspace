// SPDX-License-Identifier: GPL-3.0-or-later
#include "VirtualEthernet.hpp"
#include "NetworkService.hpp"

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
#include <set>
#include <sstream>
#include <chrono>
#include <thread>

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

bool VirtualEthernet::createPair(const EthernetInterfacePair& pair, std::string& error) {
    if (if_nametoindex(pair.host.c_str()) != 0 ||
        if_nametoindex(pair.transport.c_str()) != 0) {
        error = "refusing to use an existing virtual Ethernet interface (" + pair.host + ", " +
                pair.transport + ")";
        return false;
    }

    if (!runCommand("/sbin/ifconfig", {pair.host, "create"}, false, error)) {
        return false;
    }
    if (!runCommand("/sbin/ifconfig", {pair.transport, "create"}, false, error)) {
        std::string ignored;
        (void)runCommand("/sbin/ifconfig", {pair.host, "destroy"}, true, ignored);
        return false;
    }

    hostInterface_ = pair.host;
    transportInterface_ = pair.transport;
    ownsInterfaces_ = true;
    if (!runCommand("/sbin/ifconfig", {pair.host, "peer", pair.transport}, false, error) ||
        !configureInterface(pair.host, {"mtu", "1500", "up"}, error) ||
        !configureInterface(pair.transport, {"mtu", "1500", "up"}, error)) {
        close();
        return false;
    }
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
    EthernetInterfacePair selected;
    if (hostInterface.empty() && transportInterface.empty()) {
        std::set<std::string> occupied;
        for (const auto& candidate : automaticInterfaceCandidates()) {
            if (if_nametoindex(candidate.host.c_str()) != 0) {
                occupied.insert(candidate.host);
            }
            if (if_nametoindex(candidate.transport.c_str()) != 0) {
                occupied.insert(candidate.transport);
            }
        }
        const auto automatic = selectAutomaticInterfacePair(occupied);
        if (!automatic.has_value()) {
            error = "no free feth interface pair is available";
            return false;
        }
        selected = automatic.value();
    } else {
        if (hostInterface.empty() || transportInterface.empty() ||
            hostInterface == transportInterface || !isSafeFethName(hostInterface) ||
            !isSafeFethName(transportInterface)) {
            error = "virtual Ethernet interface overrides must be two distinct feth<number> names";
            return false;
        }
        selected = {hostInterface, transportInterface};
    }
    if (!createPair(selected, error)) {
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
            close();
            return false;
        }
    }
    if (bpf_ < 0) {
        error = "no free Berkeley Packet Filter device is available";
        close();
        return false;
    }

    u_int requestedBufferSize = 1024 * 1024;
    (void)ioctl(bpf_, BIOCSBLEN, &requestedBufferSize);

    ifreq request{};
    std::strncpy(request.ifr_name, transportInterface_.c_str(), sizeof(request.ifr_name) - 1);
    if (ioctl(bpf_, BIOCSETIF, &request) < 0) {
        error = "cannot bind BPF to " + transportInterface_ + ": " + std::strerror(errno);
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
    std::string persistentError;
    std::string bridge;
    if (ensureNetworkService(bridge, persistentError)) {
        // configd materializes the registered bridge asynchronously.
        for (int retry = 0; retry < 40 && !if_nametoindex(bridge.c_str()); ++retry) {
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
        }
        if (configureInterface(bridge, {"addm", hostInterface_}, persistentError)) {
            memberInterface_ = hostInterface_;
            memberAttached_ = true;
            hostInterface_ = bridge;
        }
    }
    if (memberInterface_.empty()) {
        std::cerr << "horndis: SystemConfiguration could not register " << hostInterface_
                  << " (" << persistentError << "); using the macOS DHCP compatibility path\n";
    }
    if (!suspendNetwork(error)) {
        close();
        return false;
    }
    return true;
}

bool VirtualEthernet::adoptDescriptor(int descriptor,
                                      const std::string& hostInterface,
                                      const std::string& transportInterface,
                                      std::string& error) {
    close();
    if (descriptor < 0 || (!isSafeFethName(hostInterface) && !isBridgeName(hostInterface)) ||
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

bool VirtualEthernet::refreshDHCP(std::string& error) {
    if (geteuid() != 0) {
        error = "DHCP refresh requires the root network supervisor";
        return false;
    }
    if (hostInterface_.empty() || transportInterface_.empty()) {
        error = "the Ethernet bridge is not open";
        return false;
    }
    if (!memberInterface_.empty() && !memberAttached_) {
        if (!setNetworkServiceMember(hostInterface_, memberInterface_, true, error)) return false;
        if (!configureInterface(hostInterface_, {"addm", memberInterface_}, error)) return false;
        memberAttached_ = true;
    }
    if (!memberInterface_.empty() &&
        !configureInterface(memberInterface_, {"mtu", "1500", "up"}, error)) return false;
    if (!configureInterface(hostInterface_, {"mtu", "1500", "up"}, error) ||
        !configureInterface(transportInterface_, {"mtu", "1500", "up"}, error)) {
        return false;
    }
    // ipconfig set creates a temporary DHCP-bridgeN service, hiding the lease
    // from the registered service's UUID and hence from Network Settings.
    if (!memberInterface_.empty()) return refreshNetworkService(hostInterface_, error);
    return runCommand("/usr/sbin/ipconfig", {"set", hostInterface_, "DHCP"}, false, error);
}

bool VirtualEthernet::suspendNetwork(std::string& error) {
    if (geteuid() != 0 || hostInterface_.empty() || transportInterface_.empty()) {
        error = "network suspension requires an open root-owned Ethernet pair";
        return false;
    }
    // Drop carrier as well as the lease so Network Settings does not report a
    // paused/unplugged phone as connected until the DHCP lease expires.
    bool stopped = !memberInterface_.empty() ||
        runCommand("/usr/sbin/ipconfig", {"set", hostInterface_, "NONE"}, false, error);
    if (memberAttached_) {
        stopped = configureInterface(hostInterface_, {"deletem", memberInterface_}, error);
        if (stopped) memberAttached_ = false;
    }
    if (!memberInterface_.empty() && !memberAttached_) {
        stopped = setNetworkServiceMember(hostInterface_, memberInterface_, false, error) && stopped;
    }
    bool lowered = configureInterface(transportInterface_, {"down"}, error);
    if (!memberInterface_.empty()) {
        lowered = configureInterface(memberInterface_, {"down"}, error) && lowered;
    }
    return stopped && lowered;
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
    if (ownsInterfaces_ && geteuid() == 0) {
        std::string ignored;
        if (!hostInterface_.empty()) {
            if (!memberInterface_.empty()) {
                if (memberAttached_) (void)configureInterface(hostInterface_, {"deletem", memberInterface_}, ignored);
                (void)setNetworkServiceMember(hostInterface_, memberInterface_, false, ignored);
                (void)runCommand("/sbin/ifconfig", {memberInterface_, "destroy"}, true, ignored);
            } else {
                (void)runCommand("/usr/sbin/ipconfig", {"set", hostInterface_, "NONE"}, true, ignored);
                (void)runCommand("/sbin/ifconfig", {hostInterface_, "destroy"}, true, ignored);
            }
        }
        if (!transportInterface_.empty()) {
            (void)runCommand(
                "/sbin/ifconfig", {transportInterface_, "destroy"}, true, ignored);
        }
    }
    ownsInterfaces_ = false;
    hostInterface_.clear();
    memberInterface_.clear();
    memberAttached_ = false;
    transportInterface_.clear();
}

} // namespace horndis
