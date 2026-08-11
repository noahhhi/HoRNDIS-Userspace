// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
#import <SystemConfiguration/SystemConfiguration.h>

#include "USBTransport.hpp"
#include "VirtualEthernet.hpp"
#include "ServiceManager.hpp"
#include "RuntimeStatus.hpp"
#include "ControlServer.hpp"

#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <grp.h>
#include <iomanip>
#include <iostream>
#include <limits.h>
#include <mach-o/dyld.h>
#include <mutex>
#include <optional>
#include <sstream>
#include <string>
#include <sys/stat.h>
#include <sys/wait.h>
#include <thread>
#include <unistd.h>

#ifndef HORNDIS_VERSION
#define HORNDIS_VERSION "development"
#endif

namespace {

std::atomic_bool gRunning{true};

void handleSignal(int) {
    gRunning.store(false);
}

std::string hexadecimal(uint32_t value, int width) {
    std::ostringstream stream;
    stream << "0x" << std::hex << std::setfill('0') << std::setw(width) << value;
    return stream.str();
}

std::string formatAddress(const std::vector<uint8_t>& address) {
    std::ostringstream stream;
    for (size_t index = 0; index < address.size(); ++index) {
        if (index != 0) {
            stream << ':';
        }
        stream << std::hex << std::setfill('0') << std::setw(2)
               << static_cast<unsigned>(address[index]);
    }
    return stream.str();
}

void logLine(const std::string& message) {
    std::cerr << "horndis: " << message << '\n';
}

uint64_t unixTimestamp() {
    return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::seconds>(
                                     std::chrono::system_clock::now().time_since_epoch())
                                     .count());
}

void publishStatus(const horndis::RuntimeStatus& status) {
    static bool warned = false;
    std::string error;
    if (!horndis::publishRuntimeStatus(status, error) && !warned) {
        logLine(error);
        warned = true;
    }
}

void printUsage() {
    std::cout << "HoRNDIS Userspace " << HORNDIS_VERSION << "\n\n"
              << "Usage:\n"
              << "  horndis probe       List USB network interfaces (no root required)\n"
              << "  horndis usb-test    Claim and initialize the first RNDIS device\n"
              << "  horndis run         Run the RNDIS-to-Ethernet bridge (root required)\n"
              << "  horndis service install|uninstall  Manage the root launch service\n"
              << "  horndis --version   Print the version\n\n"
              << "Environment:\n"
              << "  HORNDIS_HOST_INTERFACE       macOS-facing feth interface (default feth99)\n"
              << "  HORNDIS_TRANSPORT_INTERFACE  BPF-facing feth interface (default feth98)\n";
}

int probe() {
    const auto devices = horndis::RNDISUSBTransport::scan();
    if (devices.empty()) {
        std::cout << "No RNDIS, CDC-ECM, or CDC-NCM USB network interface found.\n";
        return 2;
    }
    for (const auto& device : devices) {
        std::cout << horndis::protocolName(device.protocol) << " "
                  << (device.product.empty() ? "USB network device" : device.product) << " "
                  << hexadecimal(device.vendorId, 4) << ":" << hexadecimal(device.productId, 4)
                  << " location=" << hexadecimal(device.locationId, 8)
                  << " interfaces=" << static_cast<unsigned>(device.controlInterfaceNumber) << "/"
                  << static_cast<unsigned>(device.dataInterfaceNumber);
        if (!device.serial.empty()) {
            std::cout << " serial=" << device.serial;
        }
        std::cout << (device.supported ? " [supported]" : " [detected; backend pending]") << '\n';
    }
    return 0;
}

const horndis::USBDeviceInfo* firstSupported(const std::vector<horndis::USBDeviceInfo>& devices) {
    for (const auto& device : devices) {
        if (device.supported) {
            return &device;
        }
    }
    return nullptr;
}

int usbTest() {
    const auto devices = horndis::RNDISUSBTransport::scan();
    const auto* device = firstSupported(devices);
    if (device == nullptr) {
        std::cerr << "No supported RNDIS USB interface found.\n";
        return 2;
    }
    horndis::RNDISUSBTransport transport;
    std::string error;
    if (!transport.open(*device, error)) {
        std::cerr << error << '\n';
        return 1;
    }
    std::vector<uint8_t> address;
    if (!transport.initialize(address, error)) {
        std::cerr << error << '\n';
        return 1;
    }
    std::cout << "Initialized " << device->product << " RNDIS interface; device address "
              << formatAddress(address) << ".\n";
    return 0;
}

int runAgent(int bpfDescriptor,
             const std::string& hostInterface,
             const std::string& transportInterface) {
    std::signal(SIGINT, handleSignal);
    std::signal(SIGTERM, handleSignal);
    horndis::VirtualEthernet ethernet;
    std::string error;
    if (!ethernet.adoptDescriptor(bpfDescriptor, hostInterface, transportInterface, error)) {
        logLine(error);
        return 1;
    }
    horndis::RuntimeStatus runtimeStatus;
    runtimeStatus.state = "waiting";
    runtimeStatus.hostInterface = hostInterface;
    runtimeStatus.detail = "Waiting for Android USB tethering";
    horndis::ControlServer controlServer;
    std::string controlError;
    runtimeStatus.controlAvailable = controlServer.start(controlError);
    if (!runtimeStatus.controlAvailable) {
        logLine(controlError);
    }
    publishStatus(runtimeStatus);
    logLine("waiting for an Android RNDIS USB tethering interface");
    bool userPaused = false;

    while (gRunning.load()) {
        @autoreleasepool {
            if (const auto command = controlServer.pollCommand(); command.has_value()) {
                userPaused = command.value() == horndis::ControlCommand::disconnect;
            }
            if (userPaused) {
                runtimeStatus.state = "paused";
                runtimeStatus.device.clear();
                runtimeStatus.deviceAddress.clear();
                runtimeStatus.detail = "Connection paused from the menu bar";
                runtimeStatus.receivedBytes = 0;
                runtimeStatus.transmittedBytes = 0;
                runtimeStatus.connectedSince = 0;
                publishStatus(runtimeStatus);
                while (gRunning.load() && userPaused) {
                    if (const auto command = controlServer.pollCommand(); command.has_value() &&
                        command.value() == horndis::ControlCommand::connect) {
                        userPaused = false;
                        break;
                    }
                    std::this_thread::sleep_for(std::chrono::milliseconds(200));
                }
                if (!gRunning.load()) {
                    break;
                }
                runtimeStatus.state = "waiting";
                runtimeStatus.detail = "Waiting for Android USB tethering";
                publishStatus(runtimeStatus);
                if (!ethernet.flush(error)) {
                    logLine(error);
                    return 1;
                }
            }

            const auto devices = horndis::RNDISUSBTransport::scan();
            const auto* device = firstSupported(devices);
            if (device == nullptr) {
                std::this_thread::sleep_for(std::chrono::seconds(2));
                continue;
            }

            runtimeStatus.state = "connecting";
            runtimeStatus.device = device->product;
            runtimeStatus.deviceAddress.clear();
            runtimeStatus.detail = "Initializing the RNDIS interface";
            runtimeStatus.receivedBytes = 0;
            runtimeStatus.transmittedBytes = 0;
            runtimeStatus.connectedSince = 0;
            publishStatus(runtimeStatus);

            horndis::RNDISUSBTransport usb;
            error.clear();
            if (!usb.open(*device, error)) {
                logLine(error);
                runtimeStatus.state = "error";
                runtimeStatus.detail = error;
                publishStatus(runtimeStatus);
                std::this_thread::sleep_for(std::chrono::seconds(2));
                runtimeStatus.state = "waiting";
                runtimeStatus.device.clear();
                runtimeStatus.detail = "Waiting for Android USB tethering";
                publishStatus(runtimeStatus);
                continue;
            }
            std::vector<uint8_t> deviceAddress;
            if (!usb.initialize(deviceAddress, error)) {
                logLine(error);
                runtimeStatus.state = "error";
                runtimeStatus.detail = error;
                publishStatus(runtimeStatus);
                std::this_thread::sleep_for(std::chrono::seconds(2));
                runtimeStatus.state = "waiting";
                runtimeStatus.device.clear();
                runtimeStatus.detail = "Waiting for Android USB tethering";
                publishStatus(runtimeStatus);
                continue;
            }

            logLine("connected " + device->product + " (" + formatAddress(deviceAddress) +
                    ") to " + hostInterface);

            std::atomic_bool sessionRunning{true};
            std::atomic<uint64_t> receivedBytes{0};
            std::atomic<uint64_t> transmittedBytes{0};
            std::mutex outboundErrorMutex;
            std::string outboundError;
            runtimeStatus.state = "connected";
            runtimeStatus.deviceAddress = formatAddress(deviceAddress);
            runtimeStatus.detail = "USB tethering is active";
            runtimeStatus.connectedSince = unixTimestamp();
            publishStatus(runtimeStatus);
            auto lastStatusUpdate = std::chrono::steady_clock::now();
            std::thread outbound([&] {
                while (gRunning.load() && sessionRunning.load()) {
                    std::vector<uint8_t> frame;
                    bool timedOut = false;
                    std::string threadError;
                    if (!ethernet.readFrame(frame, timedOut, threadError)) {
                        if (timedOut) {
                            continue;
                        }
                        {
                            std::lock_guard lock(outboundErrorMutex);
                            outboundError = threadError;
                        }
                        sessionRunning.store(false);
                        break;
                    }
                    if (!usb.writeEthernetFrame(frame, threadError)) {
                        {
                            std::lock_guard lock(outboundErrorMutex);
                            outboundError = threadError;
                        }
                        sessionRunning.store(false);
                        break;
                    }
                    transmittedBytes.fetch_add(frame.size(), std::memory_order_relaxed);
                }
            });

            while (gRunning.load() && sessionRunning.load()) {
                std::vector<uint8_t> frame;
                bool timedOut = false;
                error.clear();
                if (!usb.readEthernetFrame(frame, timedOut, error)) {
                    if (!timedOut) {
                        logLine(error);
                        break;
                    }
                } else {
                    if (!ethernet.writeFrame(frame, error)) {
                        logLine(error);
                        break;
                    }
                    receivedBytes.fetch_add(frame.size(), std::memory_order_relaxed);
                }

                const auto now = std::chrono::steady_clock::now();
                if (now - lastStatusUpdate >= std::chrono::seconds(1)) {
                    runtimeStatus.receivedBytes =
                        receivedBytes.load(std::memory_order_relaxed);
                    runtimeStatus.transmittedBytes =
                        transmittedBytes.load(std::memory_order_relaxed);
                    publishStatus(runtimeStatus);
                    lastStatusUpdate = now;
                }
                if (const auto command = controlServer.pollCommand(); command.has_value() &&
                    command.value() == horndis::ControlCommand::disconnect) {
                    userPaused = true;
                    sessionRunning.store(false);
                    break;
                }
            }

            sessionRunning.store(false);
            outbound.join();
            {
                std::lock_guard lock(outboundErrorMutex);
                if (!outboundError.empty()) {
                    logLine(outboundError);
                }
            }
            usb.close();
            if (gRunning.load()) {
                logLine(userPaused ? "connection paused from the menu bar"
                                   : "device disconnected; waiting to reconnect");
                runtimeStatus.state = userPaused ? "paused" : "waiting";
                runtimeStatus.device.clear();
                runtimeStatus.deviceAddress.clear();
                runtimeStatus.detail = userPaused
                                           ? "Connection paused from the menu bar"
                                           : "Device disconnected; waiting to reconnect";
                runtimeStatus.receivedBytes = 0;
                runtimeStatus.transmittedBytes = 0;
                runtimeStatus.connectedSince = 0;
                publishStatus(runtimeStatus);
                std::this_thread::sleep_for(std::chrono::seconds(2));
            }
        }
    }
    logLine("stopped");
    runtimeStatus.state = "stopped";
    runtimeStatus.device.clear();
    runtimeStatus.deviceAddress.clear();
    runtimeStatus.detail = "HoRNDIS service is stopped";
    runtimeStatus.receivedBytes = 0;
    runtimeStatus.transmittedBytes = 0;
    runtimeStatus.connectedSince = 0;
    publishStatus(runtimeStatus);
    return 0;
}

struct ConsoleUser {
    uid_t user = 0;
    gid_t group = 0;
};

std::optional<ConsoleUser> currentConsoleUser() {
    uid_t user = 0;
    gid_t group = 0;
    CFStringRef name = SCDynamicStoreCopyConsoleUser(nullptr, &user, &group);
    if (name == nullptr) {
        return std::nullopt;
    }
    char buffer[256]{};
    const bool converted =
        CFStringGetCString(name, buffer, sizeof(buffer), kCFStringEncodingUTF8);
    CFRelease(name);
    if (!converted || user == 0 || user == static_cast<uid_t>(-1) ||
        std::strcmp(buffer, "loginwindow") == 0 || std::strcmp(buffer, "_mbsetupuser") == 0) {
        return std::nullopt;
    }
    return ConsoleUser{user, group};
}

std::string executablePath(std::string& error) {
    uint32_t size = 0;
    (void)_NSGetExecutablePath(nullptr, &size);
    std::vector<char> buffer(size + 1, 0);
    if (_NSGetExecutablePath(buffer.data(), &size) != 0) {
        error = "cannot determine the horndis executable path";
        return {};
    }
    char resolved[PATH_MAX]{};
    if (realpath(buffer.data(), resolved) == nullptr) {
        error = "cannot resolve the horndis executable path: " + std::string(std::strerror(errno));
        return {};
    }
    return resolved;
}

bool prepareRuntimeDirectory(const ConsoleUser& identity, std::string& error) {
    constexpr const char* directory = "/var/run/horndis";
    if (mkdir(directory, 0755) != 0 && errno != EEXIST) {
        error = "cannot create runtime directory: " + std::string(std::strerror(errno));
        return false;
    }
    (void)unlink("/var/run/horndis/control.sock");
    if (chown(directory, identity.user, identity.group) != 0 || chmod(directory, 0700) != 0) {
        error = "cannot assign the runtime directory to the console user: " +
                std::string(std::strerror(errno));
        return false;
    }
    return true;
}

pid_t spawnAgent(const std::string& executable,
                 int bpfDescriptor,
                 const std::string& hostInterface,
                 const std::string& transportInterface,
                 const ConsoleUser& identity,
                 std::string& error) {
    const int descriptorFlags = fcntl(bpfDescriptor, F_GETFD);
    if (descriptorFlags < 0 ||
        fcntl(bpfDescriptor, F_SETFD, descriptorFlags & ~FD_CLOEXEC) != 0) {
        error = "cannot prepare the BPF capability for the data agent: " +
                std::string(std::strerror(errno));
        return -1;
    }

    const std::string descriptor = std::to_string(bpfDescriptor);
    const pid_t child = fork();
    if (child == 0) {
        const gid_t group = identity.group;
        if (setgroups(1, &group) != 0 || setgid(identity.group) != 0 ||
            setuid(identity.user) != 0) {
            _exit(126);
        }
        execl(executable.c_str(),
              executable.c_str(),
              "agent",
              descriptor.c_str(),
              hostInterface.c_str(),
              transportInterface.c_str(),
              static_cast<char*>(nullptr));
        _exit(127);
    }
    const int savedError = errno;
    (void)fcntl(bpfDescriptor, F_SETFD, descriptorFlags);
    if (child < 0) {
        error = "cannot start the unprivileged data agent: " +
                std::string(std::strerror(savedError));
        return -1;
    }
    return child;
}

int runBridge() {
    if (geteuid() != 0) {
        std::cerr << "horndis run must execute as root. Use `sudo horndis service install`.\n";
        return 1;
    }
    const char* hostEnvironment = std::getenv("HORNDIS_HOST_INTERFACE");
    const char* transportEnvironment = std::getenv("HORNDIS_TRANSPORT_INTERFACE");
    const std::string hostInterface = hostEnvironment != nullptr ? hostEnvironment : "feth99";
    const std::string transportInterface =
        transportEnvironment != nullptr ? transportEnvironment : "feth98";

    std::signal(SIGINT, handleSignal);
    std::signal(SIGTERM, handleSignal);
    horndis::RuntimeStatus supervisorStatus;
    supervisorStatus.state = "starting";
    supervisorStatus.hostInterface = hostInterface;
    supervisorStatus.detail = "Preparing the privileged network capability";
    publishStatus(supervisorStatus);

    horndis::VirtualEthernet ethernet;
    std::string error;
    if (!ethernet.open(hostInterface, transportInterface, error)) {
        logLine(error);
        supervisorStatus.state = "error";
        supervisorStatus.detail = error;
        publishStatus(supervisorStatus);
        return 1;
    }
    const std::string executable = executablePath(error);
    if (executable.empty()) {
        logLine(error);
        return 1;
    }
    logLine("privileged network setup complete; waiting for a console user");

    while (gRunning.load()) {
        const auto identity = currentConsoleUser();
        if (!identity.has_value()) {
            supervisorStatus.state = "waiting";
            supervisorStatus.detail = "Waiting for a macOS console user";
            publishStatus(supervisorStatus);
            std::this_thread::sleep_for(std::chrono::seconds(2));
            continue;
        }
        if (!prepareRuntimeDirectory(identity.value(), error)) {
            logLine(error);
            return 1;
        }
        const pid_t agent = spawnAgent(executable,
                                       ethernet.descriptor(),
                                       hostInterface,
                                       transportInterface,
                                       identity.value(),
                                       error);
        if (agent < 0) {
            logLine(error);
            return 1;
        }
        logLine("started unprivileged data agent as uid " +
                std::to_string(identity->user) + " (pid " + std::to_string(agent) + ")");

        int childStatus = 0;
        while (gRunning.load()) {
            const pid_t result = waitpid(agent, &childStatus, WNOHANG);
            if (result == agent) {
                break;
            }
            if (result < 0 && errno != EINTR) {
                logLine("cannot wait for the data agent: " + std::string(std::strerror(errno)));
                break;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(250));
        }
        if (!gRunning.load()) {
            (void)kill(agent, SIGTERM);
            while (waitpid(agent, &childStatus, 0) < 0 && errno == EINTR) {
            }
            break;
        }
        const int exitStatus = WIFEXITED(childStatus) ? WEXITSTATUS(childStatus) : -1;
        logLine("unprivileged data agent exited with status " + std::to_string(exitStatus) +
                "; restarting");
        supervisorStatus.state = "error";
        supervisorStatus.detail = "The unprivileged data agent exited; restarting";
        publishStatus(supervisorStatus);
        std::this_thread::sleep_for(std::chrono::seconds(2));
    }

    supervisorStatus.state = "stopped";
    supervisorStatus.detail = "HoRNDIS service is stopped";
    publishStatus(supervisorStatus);
    return 0;
}

int manageService(const std::string& action) {
    std::string error;
    bool success = false;
    if (action == "install") {
        success = horndis::installLaunchDaemon(error);
    } else if (action == "uninstall") {
        success = horndis::uninstallLaunchDaemon(error);
    } else {
        std::cerr << "service action must be install or uninstall\n";
        return 64;
    }
    if (!success) {
        std::cerr << error << '\n';
        return 1;
    }
    std::cout << "HoRNDIS launch service "
              << (action == "install" ? "installed and started" : "stopped and removed") << ".\n";
    return 0;
}

} // namespace

int main(int argc, char* argv[]) {
    @autoreleasepool {
        if (argc == 5 && std::string(argv[1]) == "agent") {
            char* end = nullptr;
            errno = 0;
            const long descriptor = std::strtol(argv[2], &end, 10);
            if (errno != 0 || end == argv[2] || *end != '\0' || descriptor < 0 ||
                descriptor > INT_MAX) {
                std::cerr << "invalid inherited BPF descriptor\n";
                return 64;
            }
            return runAgent(static_cast<int>(descriptor), argv[3], argv[4]);
        }
        if (argc == 3 && std::string(argv[1]) == "service") {
            return manageService(argv[2]);
        }
        if (argc != 2) {
            printUsage();
            return argc == 1 ? 0 : 64;
        }
        const std::string command = argv[1];
        if (command == "--version" || command == "version") {
            std::cout << "horndis " << HORNDIS_VERSION << '\n';
            return 0;
        }
        if (command == "--help" || command == "help") {
            printUsage();
            return 0;
        }
        if (command == "probe") {
            return probe();
        }
        if (command == "usb-test") {
            return usbTest();
        }
        if (command == "run") {
            return runBridge();
        }
        printUsage();
        return 64;
    }
}
