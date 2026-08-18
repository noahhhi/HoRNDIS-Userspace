// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
#import <SystemConfiguration/SystemConfiguration.h>

#include "USBTransport.hpp"
#include "VirtualEthernet.hpp"
#include "ServiceManager.hpp"
#include "RuntimeStatus.hpp"
#include "ControlServer.hpp"
#include "DeviceAliases.hpp"
#include "Diagnostics.hpp"
#include "SupervisorChannel.hpp"

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
#include <sys/socket.h>
#include <sys/wait.h>
#include <thread>
#include <unistd.h>
#include <vector>

#ifndef HORNDIS_VERSION
#define HORNDIS_VERSION "development"
#endif

namespace {

std::atomic_bool gRunning{true};
volatile sig_atomic_t gAgentPid = -1;

std::string executablePath(std::string& error);

void handleSignal(int) {
    gRunning.store(false);
    const pid_t agent = static_cast<pid_t>(gAgentPid);
    if (agent > 0) {
        (void)kill(agent, SIGTERM);
    }
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

void publishStatus(horndis::RuntimeStatusPublisher& publisher,
                   const horndis::RuntimeStatus& status,
                   bool force = false) {
    static bool warned = false;
    std::string error;
    if (!publisher.publish(status, error, force) && !warned) {
        logLine(error);
        warned = true;
    }
}

void printUsage() {
    std::cout << "HoRNDIS Userspace " << HORNDIS_VERSION << "\n\n"
              << "Usage:\n"
              << "  horndis install     Install/start networking and the menu app\n"
              << "  horndis uninstall   Remove networking and the menu login item\n"
              << "  horndis start       Open the menu bar app\n"
              << "  horndis stop        Quit the menu bar app; networking stays active\n"
              << "  horndis restart     Restart the menu bar app\n"
              << "  horndis status      Show network and menu app status\n"
              << "  horndis diagnostics [FILE]  Create a privacy-preserving diagnostic report\n"
              << "  horndis probe       List USB network interfaces (no root required)\n"
              << "  horndis usb-test    Claim and initialize the first RNDIS device\n"
              << "  horndis run         Run the RNDIS-to-Ethernet bridge (root required)\n"
              << "  horndis service install|uninstall  Low-level root service control\n"
              << "  horndis help [COMMAND]\n"
              << "  horndis --version   Print the version\n\n"
              << "Environment:\n"
              << "  HORNDIS_HOST_INTERFACE       macOS-facing feth override (set both names)\n"
              << "  HORNDIS_TRANSPORT_INTERFACE  BPF-facing feth override (set both names)\n"
              << "  By default HoRNDIS selects an unused feth pair automatically.\n";
}

int printCommandHelp(const std::string& command) {
    if (command == "install") {
        std::cout << "Usage: horndis install\n\n"
                  << "Installs or upgrades the privileged network service, then starts the "
                     "current user's menu bar app and enables it at login. The fixed network "
                     "installation requests administrator authentication once.\n";
    } else if (command == "uninstall") {
        std::cout << "Usage: horndis uninstall\n\n"
                  << "Stops and removes the current user's menu login item, then removes the "
                     "privileged network service with administrator authentication. Package "
                     "files remain until Homebrew or Installer removes them.\n";
    } else if (command == "start" || command == "stop" || command == "restart") {
        std::cout << "Usage: horndis " << command << "\n\n"
                  << "Controls only the unprivileged menu bar app. The USB networking service "
                     "continues running and reconnecting independently.\n";
    } else if (command == "status") {
        std::cout << "Usage: horndis status\n\n"
                  << "Reports privileged service installation/runtime state and the current "
                     "user's menu app/login-startup state. No administrator access is needed.\n";
    } else if (command == "diagnostics") {
        std::cout << "Usage: horndis diagnostics [FILE]\n\n"
                  << "Collects a privacy-preserving diagnostic report containing macOS, service, USB, "
                     "network, installation-permission, and recent service-log evidence. With "
                     "no FILE, writes the report to standard output. Review the report before "
                     "attaching it to a GitHub bug report. No administrator access is needed.\n";
    } else if (command == "service") {
        std::cout << "Usage: sudo horndis service install|uninstall\n\n"
                  << "Low-level interface for the root LaunchDaemon. Prefer `horndis install` "
                     "and `horndis uninstall` for normal use.\n";
    } else if (command == "probe" || command == "usb-test" || command == "run") {
        printUsage();
    } else {
        std::cerr << "No help topic for: " << command << '\n';
        return 64;
    }
    return 0;
}

int runProcess(const std::vector<std::string>& arguments, bool quiet = false) {
    if (arguments.empty()) {
        return 64;
    }
    std::cout.flush();
    std::cerr.flush();
    const pid_t child = fork();
    if (child == 0) {
        if (quiet) {
            const int descriptor = open("/dev/null", O_WRONLY);
            if (descriptor >= 0) {
                (void)dup2(descriptor, STDOUT_FILENO);
                (void)dup2(descriptor, STDERR_FILENO);
                (void)close(descriptor);
            }
        }
        std::vector<char*> argv;
        argv.reserve(arguments.size() + 1);
        for (const auto& argument : arguments) {
            argv.push_back(const_cast<char*>(argument.c_str()));
        }
        argv.push_back(nullptr);
        execv(argv[0], argv.data());
        _exit(127);
    }
    if (child < 0) {
        std::cerr << "cannot start " << arguments.front() << ": " << std::strerror(errno) << '\n';
        return 1;
    }
    int status = 0;
    while (waitpid(child, &status, 0) < 0) {
        if (errno != EINTR) {
            return 1;
        }
    }
    return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}

std::string menuToolPath() {
    constexpr const char* executable =
        "/Applications/HoRNDIS Status.app/Contents/MacOS/horndis-status";
    if (access(executable, X_OK) == 0) {
        return executable;
    }
    return {};
}

int runMenuCommand(const std::string& action) {
    const std::string executable = menuToolPath();
    if (executable.empty()) {
        std::cerr << "cannot find /Applications/HoRNDIS Status.app; reinstall HoRNDIS\n";
        return 1;
    }
    return runProcess({executable, action});
}

bool requireUserSession() {
    if (geteuid() != 0) {
        return true;
    }
    std::cerr << "run this command as the logged-in user, without sudo; HoRNDIS will request "
                 "administrator authentication only for the network-service step\n";
    return false;
}

int installAll() {
    if (!requireUserSession()) {
        return 64;
    }
    if (menuToolPath().empty()) {
        std::cerr << "cannot find /Applications/HoRNDIS Status.app; reinstall the HoRNDIS "
                     "package before installing its services\n";
        return 1;
    }
    std::string error;
    const std::string executable = executablePath(error);
    if (executable.empty()) {
        std::cerr << error << '\n';
        return 1;
    }
    const int serviceResult = runProcess({"/usr/bin/sudo", executable, "service", "install"});
    if (serviceResult != 0) {
        return serviceResult;
    }
    return runMenuCommand("install");
}

int uninstallAll() {
    if (!requireUserSession()) {
        return 64;
    }
    int menuResult = 0;
    if (!menuToolPath().empty()) {
        menuResult = runMenuCommand("uninstall");
    }
    std::string error;
    const std::string executable = executablePath(error);
    if (executable.empty()) {
        std::cerr << error << '\n';
        return 1;
    }
    const int serviceResult =
        runProcess({"/usr/bin/sudo", executable, "service", "uninstall"});
    return serviceResult != 0 ? serviceResult : menuResult;
}

int printStatus() {
    const bool helperInstalled = access("/Library/PrivilegedHelperTools/io.github.noahhhi.horndis",
                                        X_OK) == 0;
    const bool plistInstalled = access("/Library/LaunchDaemons/io.github.noahhhi.horndis.plist",
                                       R_OK) == 0;
    const bool serviceRunning =
        runProcess({"/bin/launchctl", "print", "system/io.github.noahhhi.horndis"}, true) == 0;
    std::cout << "Network service: "
              << (serviceRunning ? "running" : (helperInstalled && plistInstalled ? "stopped"
                                                                                  : "not installed"))
              << '\n';

    NSData* data = [NSData dataWithContentsOfFile:@"/var/run/horndis/status.json"];
    if (data != nil) {
        NSDictionary* json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSString* state = [json isKindOfClass:[NSDictionary class]] ? json[@"state"] : nil;
        NSString* device = [json isKindOfClass:[NSDictionary class]] ? json[@"device"] : nil;
        NSString* hostInterface =
            [json isKindOfClass:[NSDictionary class]] ? json[@"host_interface"] : nil;
        if ([state isKindOfClass:[NSString class]]) {
            std::cout << "Connection: " << state.UTF8String;
            if ([device isKindOfClass:[NSString class]] && device.length > 0) {
                std::cout << " (" << device.UTF8String << ")";
            }
            std::cout << '\n';
        }
        if ([hostInterface isKindOfClass:[NSString class]] && hostInterface.length > 0) {
            std::cout << "Interface: " << hostInterface.UTF8String << '\n';
        }
    }
    if (menuToolPath().empty()) {
        std::cout << "Menu bar app: not installed\n";
        return 0;
    }
    return runMenuCommand("status");
}

int probe() {
    const auto devices = horndis::RNDISUSBTransport::scan();
    if (devices.empty()) {
        std::cout << "No RNDIS, CDC-ECM, or CDC-NCM USB network interface found.\n";
        return 2;
    }
    for (size_t index = 0; index < devices.size(); ++index) {
        const auto& device = devices[index];
        std::cout << "device " << (index + 1) << ": "
                  << horndis::protocolName(device.protocol) << " "
                  << hexadecimal(device.vendorId, 4) << ":" << hexadecimal(device.productId, 4)
                  << " interfaces=" << static_cast<unsigned>(device.controlInterfaceNumber) << "/"
                  << static_cast<unsigned>(device.dataInterfaceNumber);
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
    std::cout << "Initialized device 1 RNDIS interface.\n";
    return 0;
}

int runAgent(int bpfDescriptor,
             const std::string& hostInterface,
             const std::string& transportInterface,
             int supervisorDescriptor) {
    std::signal(SIGINT, handleSignal);
    std::signal(SIGTERM, handleSignal);
    horndis::VirtualEthernet ethernet;
    std::string error;
    if (!ethernet.adoptDescriptor(bpfDescriptor, hostInterface, transportInterface, error)) {
        logLine(error);
        return 1;
    }
    horndis::RuntimeStatus runtimeStatus;
    horndis::RuntimeStatusPublisher statusPublisher;
    runtimeStatus.state = "waiting";
    runtimeStatus.hostInterface = hostInterface;
    runtimeStatus.detail = "Waiting for Android USB tethering";
    horndis::ControlServer controlServer;
    std::string controlError;
    runtimeStatus.controlAvailable = controlServer.start(controlError);
    if (!runtimeStatus.controlAvailable) {
        logLine(controlError);
    }
    publishStatus(statusPublisher, runtimeStatus);
    logLine("waiting for an Android RNDIS USB tethering interface");
    bool userPaused = false;
    auto observeUntil = std::chrono::steady_clock::time_point{};
    horndis::DeviceAliasRegistry deviceAliases;

    while (gRunning.load()) {
        @autoreleasepool {
            for (const auto command : controlServer.pollCommands()) {
                switch (command) {
                    case horndis::ControlCommand::connect:
                        userPaused = false;
                        break;
                    case horndis::ControlCommand::disconnect:
                        userPaused = true;
                        break;
                    case horndis::ControlCommand::observe:
                        observeUntil = std::chrono::steady_clock::now() +
                            std::chrono::seconds(3);
                        break;
                }
            }
            if (userPaused) {
                runtimeStatus.state = "paused";
                runtimeStatus.device.clear();
                runtimeStatus.deviceAlias.clear();
                runtimeStatus.deviceAddress.clear();
                runtimeStatus.detail = "Connection paused from the menu bar";
                runtimeStatus.receivedBytes = 0;
                runtimeStatus.transmittedBytes = 0;
                runtimeStatus.connectedSince = 0;
                publishStatus(statusPublisher, runtimeStatus);
                while (gRunning.load() && userPaused) {
                    for (const auto command : controlServer.pollCommands()) {
                        if (command == horndis::ControlCommand::connect) {
                            userPaused = false;
                        }
                        if (command == horndis::ControlCommand::disconnect) {
                            userPaused = true;
                        }
                        if (command == horndis::ControlCommand::observe) {
                            observeUntil = std::chrono::steady_clock::now() +
                                std::chrono::seconds(3);
                        }
                    }
                    if (!userPaused) {
                        break;
                    }
                    publishStatus(statusPublisher, runtimeStatus);
                    std::this_thread::sleep_for(std::chrono::milliseconds(200));
                }
                if (!gRunning.load()) {
                    break;
                }
                runtimeStatus.state = "waiting";
                runtimeStatus.detail = "Waiting for Android USB tethering";
                publishStatus(statusPublisher, runtimeStatus);
                if (!ethernet.flush(error)) {
                    logLine(error);
                    return 1;
                }
            }

            const auto devices = horndis::RNDISUSBTransport::scan();
            const auto* device = firstSupported(devices);
            if (device == nullptr) {
                publishStatus(statusPublisher, runtimeStatus);
                std::this_thread::sleep_for(std::chrono::seconds(2));
                continue;
            }
            runtimeStatus.state = "connecting";
            runtimeStatus.device = device->product;
            runtimeStatus.deviceAlias.clear();
            runtimeStatus.deviceAddress.clear();
            runtimeStatus.detail = "Initializing the RNDIS interface";
            runtimeStatus.receivedBytes = 0;
            runtimeStatus.transmittedBytes = 0;
            runtimeStatus.connectedSince = 0;
            publishStatus(statusPublisher, runtimeStatus);

            horndis::RNDISUSBTransport usb;
            error.clear();
            if (!usb.open(*device, error)) {
                logLine(error);
                runtimeStatus.state = "error";
                runtimeStatus.detail = error;
                publishStatus(statusPublisher, runtimeStatus);
                std::this_thread::sleep_for(std::chrono::seconds(2));
                runtimeStatus.state = "waiting";
                runtimeStatus.device.clear();
                runtimeStatus.deviceAlias.clear();
                runtimeStatus.detail = "Waiting for Android USB tethering";
                publishStatus(statusPublisher, runtimeStatus);
                continue;
            }
            std::vector<uint8_t> deviceAddress;
            if (!usb.initialize(deviceAddress, error)) {
                logLine(error);
                runtimeStatus.state = "error";
                runtimeStatus.detail = error;
                publishStatus(statusPublisher, runtimeStatus);
                std::this_thread::sleep_for(std::chrono::seconds(2));
                runtimeStatus.state = "waiting";
                runtimeStatus.device.clear();
                runtimeStatus.deviceAlias.clear();
                runtimeStatus.detail = "Waiting for Android USB tethering";
                publishStatus(statusPublisher, runtimeStatus);
                continue;
            }

            std::string aliasKey;
            if (!device->serial.empty()) {
                aliasKey = "usb:" + device->serial;
            } else if (!deviceAddress.empty()) {
                aliasKey = "rndis:" + formatAddress(deviceAddress);
            } else {
                aliasKey = "fallback:" + std::to_string(device->vendorId) + ":" +
                    std::to_string(device->productId) + ":" +
                    std::to_string(device->locationId);
            }
            const size_t deviceNumber = deviceAliases.aliasFor(aliasKey);
            runtimeStatus.deviceAlias = "device " + std::to_string(deviceNumber);

            error.clear();
            if (!horndis::requestDHCPRefresh(supervisorDescriptor, error)) {
                logLine(error);
                runtimeStatus.state = "error";
                runtimeStatus.detail = error;
                publishStatus(statusPublisher, runtimeStatus);
                usb.close();
                std::this_thread::sleep_for(std::chrono::seconds(2));
                runtimeStatus.state = "waiting";
                runtimeStatus.device.clear();
                runtimeStatus.deviceAlias.clear();
                runtimeStatus.detail = "Waiting for Android USB tethering";
                publishStatus(statusPublisher, runtimeStatus);
                continue;
            }

            logLine("connected device " + std::to_string(deviceNumber) + " to " + hostInterface);

            std::atomic_bool sessionRunning{true};
            std::atomic<uint64_t> receivedBytes{0};
            std::atomic<uint64_t> transmittedBytes{0};
            std::mutex outboundErrorMutex;
            std::string outboundError;
            runtimeStatus.state = "connected";
            runtimeStatus.deviceAddress = formatAddress(deviceAddress);
            runtimeStatus.detail = "USB tethering is active";
            runtimeStatus.connectedSince = unixTimestamp();
            publishStatus(statusPublisher, runtimeStatus);
            auto lastStatusEvaluation = std::chrono::steady_clock::now();
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
                for (const auto command : controlServer.pollCommands()) {
                    if (command == horndis::ControlCommand::connect) {
                        userPaused = false;
                    }
                    if (command == horndis::ControlCommand::disconnect) {
                        userPaused = true;
                    }
                    if (command == horndis::ControlCommand::observe) {
                        const bool wasAlreadyObserved = now < observeUntil;
                        observeUntil = now + std::chrono::seconds(3);
                        if (!wasAlreadyObserved) {
                            // Make the first visible-menu snapshot immediate;
                            // later renewals retain the one-second cadence.
                            lastStatusEvaluation =
                                std::chrono::steady_clock::time_point{};
                        }
                    }
                }
                if (userPaused) {
                    sessionRunning.store(false);
                    break;
                }
                if (now - lastStatusEvaluation >= std::chrono::seconds(1)) {
                    runtimeStatus.receivedBytes =
                        receivedBytes.load(std::memory_order_relaxed);
                    runtimeStatus.transmittedBytes =
                        transmittedBytes.load(std::memory_order_relaxed);
                    publishStatus(statusPublisher, runtimeStatus, now < observeUntil);
                    lastStatusEvaluation = now;
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
                runtimeStatus.deviceAlias.clear();
                runtimeStatus.deviceAddress.clear();
                runtimeStatus.detail = userPaused
                                           ? "Connection paused from the menu bar"
                                           : "Device disconnected; waiting to reconnect";
                runtimeStatus.receivedBytes = 0;
                runtimeStatus.transmittedBytes = 0;
                runtimeStatus.connectedSince = 0;
                publishStatus(statusPublisher, runtimeStatus);
                std::this_thread::sleep_for(std::chrono::seconds(2));
            }
        }
    }
    logLine("stopped");
    runtimeStatus.state = "stopped";
    runtimeStatus.device.clear();
    runtimeStatus.deviceAlias.clear();
    runtimeStatus.deviceAddress.clear();
    runtimeStatus.detail = "HoRNDIS service is stopped";
    runtimeStatus.receivedBytes = 0;
    runtimeStatus.transmittedBytes = 0;
    runtimeStatus.connectedSince = 0;
    publishStatus(statusPublisher, runtimeStatus);
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
                 int& supervisorDescriptor,
                 std::string& error) {
    supervisorDescriptor = -1;
    int channel[2]{-1, -1};
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, channel) != 0) {
        error = "cannot create the root supervisor channel: " +
                std::string(std::strerror(errno));
        return -1;
    }
    const int suppressBrokenPipe = 1;
    if (setsockopt(channel[0], SOL_SOCKET, SO_NOSIGPIPE,
                   &suppressBrokenPipe, sizeof(suppressBrokenPipe)) != 0 ||
        setsockopt(channel[1], SOL_SOCKET, SO_NOSIGPIPE,
                   &suppressBrokenPipe, sizeof(suppressBrokenPipe)) != 0) {
        error = "cannot secure the root supervisor channel: " +
                std::string(std::strerror(errno));
        (void)close(channel[0]);
        (void)close(channel[1]);
        return -1;
    }
    const int supervisorFlags = fcntl(channel[0], F_GETFD);
    if (supervisorFlags < 0 ||
        fcntl(channel[0], F_SETFD, supervisorFlags | FD_CLOEXEC) != 0) {
        error = "cannot protect the root supervisor channel: " +
                std::string(std::strerror(errno));
        (void)close(channel[0]);
        (void)close(channel[1]);
        return -1;
    }
    const int descriptorFlags = fcntl(bpfDescriptor, F_GETFD);
    if (descriptorFlags < 0 ||
        fcntl(bpfDescriptor, F_SETFD, descriptorFlags & ~FD_CLOEXEC) != 0) {
        error = "cannot prepare the BPF capability for the data agent: " +
                std::string(std::strerror(errno));
        (void)close(channel[0]);
        (void)close(channel[1]);
        return -1;
    }

    const std::string descriptor = std::to_string(bpfDescriptor);
    const std::string supervisor = std::to_string(channel[1]);
    const pid_t child = fork();
    if (child == 0) {
        (void)close(channel[0]);
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
              supervisor.c_str(),
              static_cast<char*>(nullptr));
        _exit(127);
    }
    const int savedError = errno;
    (void)close(channel[1]);
    (void)fcntl(bpfDescriptor, F_SETFD, descriptorFlags);
    if (child < 0) {
        (void)close(channel[0]);
        error = "cannot start the unprivileged data agent: " +
                std::string(std::strerror(savedError));
        return -1;
    }
    supervisorDescriptor = channel[0];
    return child;
}

void superviseAgentDHCP(int descriptor, horndis::VirtualEthernet& ethernet) {
    while (gRunning.load()) {
        horndis::SupervisorRequest request{};
        bool closed = false;
        std::string error;
        if (!horndis::receiveSupervisorRequest(descriptor, request, closed, error)) {
            logLine(error);
            break;
        }
        if (closed) {
            break;
        }

        bool success = false;
        switch (request) {
            case horndis::SupervisorRequest::refreshDHCP:
                success = ethernet.refreshDHCP(error);
                if (success) {
                    logLine("refreshed DHCP on " + ethernet.hostInterface() +
                            " for the new USB session");
                } else {
                    logLine("cannot refresh DHCP on " + ethernet.hostInterface() + ": " + error);
                }
                break;
        }

        std::string responseError;
        if (!horndis::sendSupervisorResponse(descriptor, success, responseError)) {
            logLine(responseError);
            break;
        }
    }
}

// Root-published snapshots stay mode 0600, so hand them to the console user;
// otherwise the menu bar app cannot read supervisor states such as "starting",
// "waiting", or an agent-restart error.
void publishSupervisorStatus(horndis::RuntimeStatusPublisher& publisher,
                             const horndis::RuntimeStatus& status,
                             bool force = false) {
    publishStatus(publisher, status, force);
    const auto identity = currentConsoleUser();
    if (identity.has_value()) {
        (void)chown("/var/run/horndis/status.json", identity->user, identity->group);
    }
}

int runBridge() {
    if (geteuid() != 0) {
        std::cerr << "horndis run must execute as root. Use `sudo horndis service install`.\n";
        return 1;
    }
    const char* hostEnvironment = std::getenv("HORNDIS_HOST_INTERFACE");
    const char* transportEnvironment = std::getenv("HORNDIS_TRANSPORT_INTERFACE");
    if ((hostEnvironment == nullptr) != (transportEnvironment == nullptr)) {
        logLine("HORNDIS_HOST_INTERFACE and HORNDIS_TRANSPORT_INTERFACE must be set together");
        return 64;
    }
    const std::string requestedHost = hostEnvironment != nullptr ? hostEnvironment : "";
    const std::string requestedTransport =
        transportEnvironment != nullptr ? transportEnvironment : "";

    std::signal(SIGINT, handleSignal);
    std::signal(SIGTERM, handleSignal);
    horndis::RuntimeStatus supervisorStatus;
    horndis::RuntimeStatusPublisher statusPublisher;
    supervisorStatus.state = "starting";
    supervisorStatus.hostInterface = requestedHost;
    supervisorStatus.detail = "Preparing the privileged network capability";
    publishSupervisorStatus(statusPublisher, supervisorStatus);

    horndis::VirtualEthernet ethernet;
    std::string error;
    if (!ethernet.open(requestedHost, requestedTransport, error)) {
        logLine(error);
        supervisorStatus.state = "error";
        supervisorStatus.detail = error;
        publishSupervisorStatus(statusPublisher, supervisorStatus);
        return 1;
    }
    const std::string hostInterface = ethernet.hostInterface();
    const std::string transportInterface = ethernet.transportInterface();
    supervisorStatus.hostInterface = hostInterface;
    supervisorStatus.detail = "Privileged network capability is ready";
    publishSupervisorStatus(statusPublisher, supervisorStatus, true);
    logLine("selected " + hostInterface + " (macOS) and " + transportInterface +
            " (transport)");
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
            publishSupervisorStatus(statusPublisher, supervisorStatus);
            std::this_thread::sleep_for(std::chrono::seconds(2));
            continue;
        }
        if (!prepareRuntimeDirectory(identity.value(), error)) {
            logLine(error);
            return 1;
        }
        int supervisorDescriptor = -1;
        const pid_t agent = spawnAgent(executable,
                                       ethernet.descriptor(),
                                       hostInterface,
                                       transportInterface,
                                       identity.value(),
                                       supervisorDescriptor,
                                       error);
        if (agent < 0) {
            logLine(error);
            return 1;
        }
        gAgentPid = static_cast<sig_atomic_t>(agent);
        logLine("started unprivileged data agent for user (pid " +
                std::to_string(agent) + ")");

        superviseAgentDHCP(supervisorDescriptor, ethernet);
        (void)close(supervisorDescriptor);

        int childStatus = 0;
        if (!gRunning.load()) {
            (void)kill(agent, SIGTERM);
        }
        pid_t waitResult = -1;
        do {
            waitResult = waitpid(agent, &childStatus, 0);
        } while (waitResult < 0 && errno == EINTR);
        gAgentPid = -1;
        if (waitResult < 0) {
            logLine("cannot wait for the data agent: " + std::string(std::strerror(errno)));
        }
        if (!gRunning.load()) {
            break;
        }
        const int exitStatus = WIFEXITED(childStatus) ? WEXITSTATUS(childStatus) : -1;
        logLine("unprivileged data agent exited with status " + std::to_string(exitStatus) +
                "; restarting");
        supervisorStatus.state = "error";
        supervisorStatus.detail = "The unprivileged data agent exited; restarting";
        publishSupervisorStatus(statusPublisher, supervisorStatus);
        std::this_thread::sleep_for(std::chrono::seconds(2));
    }

    supervisorStatus.state = "stopped";
    supervisorStatus.detail = "HoRNDIS service is stopped";
    publishSupervisorStatus(statusPublisher, supervisorStatus);
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
        if (argc == 6 && std::string(argv[1]) == "agent") {
            char* end = nullptr;
            errno = 0;
            const long descriptor = std::strtol(argv[2], &end, 10);
            if (errno != 0 || end == argv[2] || *end != '\0' || descriptor < 0 ||
                descriptor > INT_MAX) {
                std::cerr << "invalid inherited BPF descriptor\n";
                return 64;
            }
            char* supervisorEnd = nullptr;
            errno = 0;
            const long supervisorDescriptor = std::strtol(argv[5], &supervisorEnd, 10);
            if (errno != 0 || supervisorEnd == argv[5] || *supervisorEnd != '\0' ||
                supervisorDescriptor < 0 || supervisorDescriptor > INT_MAX ||
                supervisorDescriptor == descriptor) {
                std::cerr << "invalid inherited supervisor descriptor\n";
                return 64;
            }
            return runAgent(static_cast<int>(descriptor),
                            argv[3],
                            argv[4],
                            static_cast<int>(supervisorDescriptor));
        }
        if (argc == 3 && std::string(argv[1]) == "service") {
            return manageService(argv[2]);
        }
        if (argc == 3 && std::string(argv[1]) == "help") {
            return printCommandHelp(argv[2]);
        }
        if (argc == 3 && std::string(argv[1]) == "diagnostics") {
            std::string error;
            if (!horndis::writeDiagnosticReport(argv[2], HORNDIS_VERSION, error)) {
                std::cerr << error << '\n';
                return 1;
            }
            std::cout << "Diagnostic report written to " << argv[2] << '\n';
            return 0;
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
        if (command == "install") {
            return installAll();
        }
        if (command == "uninstall") {
            return uninstallAll();
        }
        if (command == "start" || command == "stop" || command == "restart") {
            return runMenuCommand(command);
        }
        if (command == "status") {
            return printStatus();
        }
        if (command == "diagnostics") {
            std::cout << horndis::buildDiagnosticReport(HORNDIS_VERSION);
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
