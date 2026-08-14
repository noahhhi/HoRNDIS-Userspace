// SPDX-License-Identifier: GPL-3.0-or-later
#import "USBTransport.hpp"

#import "RNDISProtocol.hpp"

#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/usb/USB.h>
#import <IOUSBHost/AppleUSBDescriptorParsing.h>
#import <IOUSBHost/IOUSBHost.h>

#include <algorithm>
#include <array>
#include <iomanip>
#include <sstream>
#include <thread>

namespace horndis {
namespace {

struct InterfaceRecord {
    uint32_t locationId = 0;
    uint16_t vendorId = 0;
    uint16_t productId = 0;
    uint8_t number = 0;
    uint8_t interfaceClass = 0;
    uint8_t interfaceSubclass = 0;
    uint8_t interfaceProtocol = 0;
    std::string product;
    std::string serial;
};

mach_port_t ioMainPort() {
    if (@available(macOS 12.0, *)) {
        return kIOMainPortDefault;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return kIOMasterPortDefault;
#pragma clang diagnostic pop
}

uint32_t numberProperty(io_service_t service, CFStringRef key) {
    CFTypeRef value = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0);
    if (value == nullptr) {
        return 0;
    }
    uint32_t result = 0;
    if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        CFNumberGetValue(static_cast<CFNumberRef>(value), kCFNumberSInt32Type, &result);
    }
    CFRelease(value);
    return result;
}

std::string stringProperty(io_service_t service, CFStringRef key) {
    CFTypeRef value = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0);
    if (value == nullptr) {
        return {};
    }
    std::string result;
    if (CFGetTypeID(value) == CFStringGetTypeID()) {
        const auto string = static_cast<CFStringRef>(value);
        const CFIndex size = CFStringGetMaximumSizeForEncoding(CFStringGetLength(string),
                                                               kCFStringEncodingUTF8) + 1;
        std::vector<char> buffer(static_cast<size_t>(size));
        if (CFStringGetCString(string, buffer.data(), size, kCFStringEncodingUTF8)) {
            result = buffer.data();
        }
    }
    CFRelease(value);
    return result;
}

InterfaceRecord describeInterface(io_service_t service) {
    InterfaceRecord record;
    record.locationId = numberProperty(service, CFSTR("locationID"));
    record.vendorId = static_cast<uint16_t>(numberProperty(service, CFSTR("idVendor")));
    record.productId = static_cast<uint16_t>(numberProperty(service, CFSTR("idProduct")));
    record.number = static_cast<uint8_t>(numberProperty(service, CFSTR("bInterfaceNumber")));
    record.interfaceClass = static_cast<uint8_t>(numberProperty(service, CFSTR("bInterfaceClass")));
    record.interfaceSubclass = static_cast<uint8_t>(numberProperty(service, CFSTR("bInterfaceSubClass")));
    record.interfaceProtocol = static_cast<uint8_t>(numberProperty(service, CFSTR("bInterfaceProtocol")));
    record.product = stringProperty(service, CFSTR("USB Product Name"));
    record.serial = stringProperty(service, CFSTR("USB Serial Number"));
    return record;
}

std::vector<InterfaceRecord> enumerateInterfaces() {
    std::vector<InterfaceRecord> records;
    CFMutableDictionaryRef matching = IOServiceMatching("IOUSBHostInterface");
    if (matching == nullptr) {
        return records;
    }
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(ioMainPort(), matching, &iterator) != kIOReturnSuccess) {
        return records;
    }
    io_service_t service = IO_OBJECT_NULL;
    while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        records.push_back(describeInterface(service));
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    return records;
}

bool isRndisControl(const InterfaceRecord& interface) {
    return (interface.interfaceClass == 0xe0 && interface.interfaceSubclass == 0x01 &&
            interface.interfaceProtocol == 0x03) ||
           (interface.interfaceClass == 0x02 && interface.interfaceSubclass == 0x02 &&
            interface.interfaceProtocol == 0xff) ||
           (interface.interfaceClass == 0xef && interface.interfaceSubclass == 0x04 &&
            interface.interfaceProtocol == 0x01);
}

bool isECMControl(const InterfaceRecord& interface) {
    return interface.interfaceClass == 0x02 && interface.interfaceSubclass == 0x06;
}

bool isNCMControl(const InterfaceRecord& interface) {
    return interface.interfaceClass == 0x02 && interface.interfaceSubclass == 0x0d;
}

io_service_t findInterfaceService(const USBDeviceInfo& device, uint8_t interfaceNumber) {
    CFMutableDictionaryRef matching = IOServiceMatching("IOUSBHostInterface");
    if (matching == nullptr) {
        return IO_OBJECT_NULL;
    }
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(ioMainPort(), matching, &iterator) != kIOReturnSuccess) {
        return IO_OBJECT_NULL;
    }
    io_service_t result = IO_OBJECT_NULL;
    io_service_t service = IO_OBJECT_NULL;
    while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        const InterfaceRecord record = describeInterface(service);
        if (record.locationId == device.locationId && record.vendorId == device.vendorId &&
            record.productId == device.productId && record.number == interfaceNumber) {
            result = service;
            break;
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    return result;
}

std::string nsErrorDescription(NSError* error) {
    if (error == nil) {
        return "unknown I/O error";
    }
    const char* description = error.localizedDescription.UTF8String;
    return description != nullptr ? description : "unknown I/O error";
}

bool isTimeout(NSError* error) {
    return error != nil && static_cast<IOReturn>(error.code) == kIOReturnTimeout;
}

} // namespace

struct RNDISUSBTransport::Impl {
    __strong IOUSBHostInterface* control = nil;
    __strong IOUSBHostInterface* data = nil;
    __strong IOUSBHostPipe* bulkIn = nil;
    __strong IOUSBHostPipe* bulkOut = nil;
    __strong NSMutableData* bulkInData = nil;
    __strong NSMutableData* bulkOutData = nil;
    std::vector<uint8_t> bulkOutPacket;
    USBDeviceInfo device;
};

const char* protocolName(USBNetworkProtocol protocol) {
    switch (protocol) {
        case USBNetworkProtocol::RNDIS:
            return "RNDIS";
        case USBNetworkProtocol::CDC_ECM:
            return "CDC-ECM";
        case USBNetworkProtocol::CDC_NCM:
            return "CDC-NCM";
    }
    return "unknown";
}

RNDISUSBTransport::RNDISUSBTransport() : impl_(std::make_unique<Impl>()) {}

RNDISUSBTransport::~RNDISUSBTransport() {
    close();
}

std::vector<USBDeviceInfo> RNDISUSBTransport::scan() {
    const auto interfaces = enumerateInterfaces();
    std::vector<USBDeviceInfo> devices;
    for (const auto& control : interfaces) {
        USBNetworkProtocol protocol;
        bool recognized = true;
        if (isRndisControl(control)) {
            protocol = USBNetworkProtocol::RNDIS;
        } else if (isNCMControl(control)) {
            protocol = USBNetworkProtocol::CDC_NCM;
        } else if (isECMControl(control)) {
            protocol = USBNetworkProtocol::CDC_ECM;
        } else {
            recognized = false;
        }
        if (!recognized) {
            continue;
        }

        const auto data = std::find_if(interfaces.begin(), interfaces.end(), [&](const auto& candidate) {
            return candidate.locationId == control.locationId && candidate.vendorId == control.vendorId &&
                   candidate.productId == control.productId && candidate.interfaceClass == 0x0a;
        });
        if (data == interfaces.end()) {
            continue;
        }

        USBDeviceInfo device;
        device.protocol = protocol;
        device.locationId = control.locationId;
        device.vendorId = control.vendorId;
        device.productId = control.productId;
        device.controlInterfaceNumber = control.number;
        device.dataInterfaceNumber = data->number;
        device.product = control.product;
        device.serial = control.serial;
        device.supported = protocol == USBNetworkProtocol::RNDIS;
        devices.push_back(std::move(device));
    }
    return devices;
}

bool RNDISUSBTransport::open(const USBDeviceInfo& device, std::string& error) {
    close();
    if (device.protocol != USBNetworkProtocol::RNDIS) {
        error = std::string(protocolName(device.protocol)) + " was detected but is not implemented yet";
        return false;
    }

    io_service_t controlService = findInterfaceService(device, device.controlInterfaceNumber);
    if (controlService == IO_OBJECT_NULL) {
        error = "RNDIS control interface disappeared";
        return false;
    }
    io_service_t dataService = findInterfaceService(device, device.dataInterfaceNumber);
    if (dataService == IO_OBJECT_NULL) {
        IOObjectRelease(controlService);
        error = "RNDIS data interface disappeared";
        return false;
    }

    NSError* nsError = nil;
    impl_->control = [[IOUSBHostInterface alloc] initWithIOService:controlService
                                                          options:IOUSBHostObjectInitOptionsNone
                                                            queue:nil
                                                            error:&nsError
                                                  interestHandler:nil];
    IOObjectRelease(controlService);
    if (impl_->control == nil) {
        IOObjectRelease(dataService);
        error = "cannot claim RNDIS control interface: " + nsErrorDescription(nsError);
        return false;
    }

    nsError = nil;
    impl_->data = [[IOUSBHostInterface alloc] initWithIOService:dataService
                                                       options:IOUSBHostObjectInitOptionsNone
                                                         queue:nil
                                                         error:&nsError
                                               interestHandler:nil];
    IOObjectRelease(dataService);
    if (impl_->data == nil) {
        error = "cannot claim RNDIS data interface: " + nsErrorDescription(nsError);
        close();
        return false;
    }

    const IOUSBConfigurationDescriptor* configuration = impl_->data.configurationDescriptor;
    const IOUSBInterfaceDescriptor* interface = impl_->data.interfaceDescriptor;
    const IOUSBEndpointDescriptor* endpoint = nullptr;
    uint8_t inputAddress = 0;
    uint8_t outputAddress = 0;
    while ((endpoint = IOUSBGetNextEndpointDescriptor(
                configuration,
                interface,
                reinterpret_cast<const IOUSBDescriptorHeader*>(endpoint))) != nullptr) {
        if ((endpoint->bmAttributes & 0x03) != kUSBBulk) {
            continue;
        }
        if ((endpoint->bEndpointAddress & 0x80) != 0) {
            inputAddress = endpoint->bEndpointAddress;
        } else {
            outputAddress = endpoint->bEndpointAddress;
        }
    }
    if (inputAddress == 0 || outputAddress == 0) {
        error = "RNDIS data interface has no bulk input/output endpoint pair";
        close();
        return false;
    }

    nsError = nil;
    impl_->bulkIn = [impl_->data copyPipeWithAddress:inputAddress error:&nsError];
    if (impl_->bulkIn == nil) {
        error = "cannot open RNDIS bulk input endpoint: " + nsErrorDescription(nsError);
        close();
        return false;
    }
    nsError = nil;
    impl_->bulkOut = [impl_->data copyPipeWithAddress:outputAddress error:&nsError];
    if (impl_->bulkOut == nil) {
        error = "cannot open RNDIS bulk output endpoint: " + nsErrorDescription(nsError);
        close();
        return false;
    }

    impl_->device = device;
    return true;
}

bool RNDISUSBTransport::exchangeControl(const std::vector<uint8_t>& requestBytes,
                                        std::vector<uint8_t>& response,
                                        std::string& error) {
    if (impl_->control == nil) {
        error = "RNDIS control interface is not open";
        return false;
    }
    NSMutableData* requestData = [NSMutableData dataWithBytes:requestBytes.data()
                                                       length:requestBytes.size()];
    IOUSBDeviceRequest request{};
    request.bmRequestType = 0x21;
    request.bRequest = 0x00;
    request.wValue = 0;
    request.wIndex = impl_->device.controlInterfaceNumber;
    request.wLength = static_cast<uint16_t>(requestBytes.size());
    NSUInteger transferred = 0;
    NSError* nsError = nil;
    if (![impl_->control sendDeviceRequest:request
                                      data:requestData
                          bytesTransferred:&transferred
                         completionTimeout:5.0
                                     error:&nsError]) {
        error = "RNDIS SendEncapsulatedCommand failed: " + nsErrorDescription(nsError);
        return false;
    }
    if (transferred != requestBytes.size()) {
        error = "RNDIS control command was only partially transferred";
        return false;
    }

    for (int attempt = 0; attempt < 20; ++attempt) {
        NSMutableData* responseData = [NSMutableData dataWithLength:4096];
        IOUSBDeviceRequest get{};
        get.bmRequestType = 0xa1;
        get.bRequest = 0x01;
        get.wValue = 0;
        get.wIndex = impl_->device.controlInterfaceNumber;
        get.wLength = 4096;
        transferred = 0;
        nsError = nil;
        if ([impl_->control sendDeviceRequest:get
                                         data:responseData
                             bytesTransferred:&transferred
                            completionTimeout:1.0
                                        error:&nsError] && transferred >= 8) {
            const auto* begin = static_cast<const uint8_t*>(responseData.bytes);
            response.assign(begin, begin + transferred);
            return true;
        }
        if (nsError != nil && !isTimeout(nsError)) {
            error = "RNDIS GetEncapsulatedResponse failed: " + nsErrorDescription(nsError);
            return false;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    error = "timed out waiting for an RNDIS control response";
    return false;
}

bool RNDISUSBTransport::initialize(std::vector<uint8_t>& deviceAddress, std::string& error) {
    std::vector<uint8_t> response;
    const uint32_t initializeId = nextRequestId_++;
    if (!exchangeControl(rndis::makeInitialize(initializeId, 16384), response, error)) {
        return false;
    }
    const auto result = rndis::parseInitializeComplete(response, initializeId, error);
    if (!result.has_value()) {
        return false;
    }
    maxTransferSize_ = std::clamp(result->maxTransferSize, 2048U, 1024U * 1024U);

    const uint32_t queryId = nextRequestId_++;
    response.clear();
    if (!exchangeControl(rndis::makeQuery(queryId, rndis::kOidCurrentAddress), response, error)) {
        return false;
    }
    const auto address = rndis::parseQueryComplete(response, queryId, error);
    if (!address.has_value() || address->size() != 6) {
        if (error.empty()) {
            error = "RNDIS device returned an invalid Ethernet address";
        }
        return false;
    }
    deviceAddress = *address;

    const uint32_t setId = nextRequestId_++;
    const uint32_t filter = rndis::kPacketTypeDirected | rndis::kPacketTypeMulticast |
                            rndis::kPacketTypeAllMulticast | rndis::kPacketTypeBroadcast;
    response.clear();
    if (!exchangeControl(rndis::makeSetPacketFilter(setId, filter), response, error)) {
        return false;
    }
    return rndis::validateSetComplete(response, setId, error);
}

bool RNDISUSBTransport::readEthernetFrame(std::vector<uint8_t>& frame,
                                         bool& timedOut,
                                         std::string& error) {
    @autoreleasepool {
        timedOut = false;
        if (!pendingFrames_.empty()) {
            frame = std::move(pendingFrames_.front());
            pendingFrames_.pop_front();
            return true;
        }
        if (impl_->bulkIn == nil) {
            error = "RNDIS bulk input endpoint is not open";
            return false;
        }

        if (impl_->bulkInData == nil || impl_->bulkInData.length != maxTransferSize_) {
            impl_->bulkInData = [[NSMutableData alloc] initWithLength:maxTransferSize_];
        }
        NSUInteger transferred = 0;
        NSError* nsError = nil;
        if (![impl_->bulkIn sendIORequestWithData:impl_->bulkInData
                                 bytesTransferred:&transferred
                                completionTimeout:1.0
                                            error:&nsError]) {
            if (isTimeout(nsError)) {
                timedOut = true;
                return false;
            }
            error = "RNDIS bulk read failed: " + nsErrorDescription(nsError);
            return false;
        }
        if (transferred == 0) {
            timedOut = true;
            return false;
        }
        const auto* begin = static_cast<const uint8_t*>(impl_->bulkInData.bytes);
        auto frames = rndis::unwrapEthernetFrames(std::span(begin, transferred), error);
        if (frames.empty()) {
            if (error.empty()) {
                timedOut = true;
            }
            return false;
        }
        frame = std::move(frames.front());
        for (size_t index = 1; index < frames.size(); ++index) {
            pendingFrames_.push_back(std::move(frames[index]));
        }
        return true;
    }
}

bool RNDISUSBTransport::writeEthernetFrame(const std::vector<uint8_t>& frame, std::string& error) {
    @autoreleasepool {
        if (impl_->bulkOut == nil) {
            error = "RNDIS bulk output endpoint is not open";
            return false;
        }
        if (!rndis::wrapEthernetFrame(frame, impl_->bulkOutPacket)) {
            error = "Ethernet frame is too large for an RNDIS packet";
            return false;
        }
        if (impl_->bulkOutData == nil) {
            impl_->bulkOutData = [[NSMutableData alloc] initWithCapacity:2048];
        }
        impl_->bulkOutData.length = impl_->bulkOutPacket.size();
        std::copy(impl_->bulkOutPacket.begin(),
                  impl_->bulkOutPacket.end(),
                  static_cast<uint8_t*>(impl_->bulkOutData.mutableBytes));

        NSUInteger transferred = 0;
        NSError* nsError = nil;
        if (![impl_->bulkOut sendIORequestWithData:impl_->bulkOutData
                                  bytesTransferred:&transferred
                                 completionTimeout:5.0
                                             error:&nsError]) {
            error = "RNDIS bulk write failed: " + nsErrorDescription(nsError);
            return false;
        }
        if (transferred != impl_->bulkOutPacket.size()) {
            error = "RNDIS bulk write was only partially transferred";
            return false;
        }
        return true;
    }
}

void RNDISUSBTransport::close() {
    pendingFrames_.clear();
    if (!impl_) {
        return;
    }
    impl_->bulkIn = nil;
    impl_->bulkOut = nil;
    impl_->bulkInData = nil;
    impl_->bulkOutData = nil;
    impl_->bulkOutPacket.clear();
    impl_->bulkOutPacket.shrink_to_fit();
    if (impl_->data != nil) {
        [impl_->data destroy];
        impl_->data = nil;
    }
    if (impl_->control != nil) {
        [impl_->control destroy];
        impl_->control = nil;
    }
}

} // namespace horndis
