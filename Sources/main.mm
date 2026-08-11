// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>

#include "USBTransport.hpp"
#include "VirtualEthernet.hpp"
#include "ServiceManager.hpp"

#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <iomanip>
#include <iostream>
#include <mutex>
#include <sstream>
#include <string>
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

int runBridge() {
    if (geteuid() != 0) {
        std::cerr << "horndis run must execute as root. Use sudo or `sudo brew services start horndis`.\n";
        return 1;
    }
    const char* hostEnvironment = std::getenv("HORNDIS_HOST_INTERFACE");
    const char* transportEnvironment = std::getenv("HORNDIS_TRANSPORT_INTERFACE");
    const std::string hostInterface = hostEnvironment != nullptr ? hostEnvironment : "feth99";
    const std::string transportInterface =
        transportEnvironment != nullptr ? transportEnvironment : "feth98";

    std::signal(SIGINT, handleSignal);
    std::signal(SIGTERM, handleSignal);
    logLine("waiting for an Android RNDIS USB tethering interface");

    while (gRunning.load()) {
        @autoreleasepool {
            const auto devices = horndis::RNDISUSBTransport::scan();
            const auto* device = firstSupported(devices);
            if (device == nullptr) {
                std::this_thread::sleep_for(std::chrono::seconds(2));
                continue;
            }

            horndis::RNDISUSBTransport usb;
            std::string error;
            if (!usb.open(*device, error)) {
                logLine(error);
                std::this_thread::sleep_for(std::chrono::seconds(2));
                continue;
            }
            std::vector<uint8_t> deviceAddress;
            if (!usb.initialize(deviceAddress, error)) {
                logLine(error);
                std::this_thread::sleep_for(std::chrono::seconds(2));
                continue;
            }

            horndis::VirtualEthernet ethernet;
            if (!ethernet.open(hostInterface, transportInterface, error)) {
                logLine(error);
                return 1;
            }
            logLine("connected " + device->product + " (" + formatAddress(deviceAddress) +
                    ") to " + hostInterface);

            std::atomic_bool sessionRunning{true};
            std::mutex outboundErrorMutex;
            std::string outboundError;
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
                }
            });

            while (gRunning.load() && sessionRunning.load()) {
                std::vector<uint8_t> frame;
                bool timedOut = false;
                error.clear();
                if (!usb.readEthernetFrame(frame, timedOut, error)) {
                    if (timedOut) {
                        continue;
                    }
                    logLine(error);
                    break;
                }
                if (!ethernet.writeFrame(frame, error)) {
                    logLine(error);
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
            ethernet.close();
            if (gRunning.load()) {
                logLine("device disconnected; waiting to reconnect");
                std::this_thread::sleep_for(std::chrono::seconds(2));
            }
        }
    }
    logLine("stopped");
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
