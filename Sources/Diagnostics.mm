// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>

#include "Diagnostics.hpp"
#include "USBTransport.hpp"

#include <algorithm>
#include <cerrno>
#include <cctype>
#include <cstring>
#include <fcntl.h>
#include <ifaddrs.h>
#include <iomanip>
#include <net/if.h>
#include <regex>
#include <sstream>
#include <string>
#include <sys/stat.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>
#include <vector>

namespace horndis {
namespace {

constexpr size_t kMaximumCommandBytes = 2 * 1024 * 1024;
constexpr size_t kMaximumLogBytes = 512 * 1024;
constexpr size_t kMaximumLogLines = 1'000;

struct CommandResult {
    int status = 1;
    std::string output;
    bool truncated = false;
};

std::string lowercased(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char character) {
        return static_cast<char>(std::tolower(character));
    });
    return value;
}

std::string redactLine(const std::string& line) {
    const std::string lower = lowercased(line);
    const size_t legacyConnection = lower.find("horndis: connected ");
    if (legacyConnection != std::string::npos) {
        const size_t interface = lower.find(" to feth", legacyConnection);
        return line.substr(0, legacyConnection) + "horndis: connected device 1" +
            (interface == std::string::npos ? "" : line.substr(interface));
    }
    if (lower.find("started unprivileged data agent as uid ") != std::string::npos) {
        static const std::regex uid(R"( as uid [0-9]+)");
        return std::regex_replace(line, uid, " as user");
    }
    const bool sensitiveProperty = lower.find("serial") != std::string::npos ||
        lower.find("manufacturer") != std::string::npos ||
        lower.find("product name") != std::string::npos ||
        lower.find("vendor name") != std::string::npos ||
        lower.find("exclusiveowner") != std::string::npos ||
        lower.find("\"device\"") != std::string::npos;
    if (!sensitiveProperty) {
        return line;
    }
    const size_t equals = line.find('=');
    const size_t colon = line.find(':');
    const size_t separator = equals != std::string::npos ? equals : colon;
    if (separator == std::string::npos) {
        return line;
    }
    return line.substr(0, separator + 1) + " <redacted>";
}

std::string redactIdentifiers(std::string text) {
    static const std::regex homePath(R"(/Users/[^/\s]+)");
    static const std::regex macAddress(R"(\b([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}\b)");
    static const std::regex ipv4Address(R"(\b([0-9]{1,3}\.){3}[0-9]{1,3}\b)");
    static const std::regex expandedIPv6(R"(\b[0-9A-Fa-f]{1,4}(:[0-9A-Fa-f]{0,4}){3,7}\b)");
    static const std::regex compressedIPv6(R"(([0-9A-Fa-f]{0,4}:){1,7}:[0-9A-Fa-f]{0,4})");
    text = std::regex_replace(text, homePath, "/Users/user");
    text = std::regex_replace(text, macAddress, "<redacted-mac>");
    text = std::regex_replace(text, ipv4Address, "<redacted-ip>");
    text = std::regex_replace(text, expandedIPv6, "<redacted-ip>");
    text = std::regex_replace(text, compressedIPv6, "<redacted-ip>");
    return text;
}

std::string redact(std::string text) {
    text = redactIdentifiers(std::move(text));

    std::ostringstream sanitized;
    std::istringstream input(text);
    std::string line;
    while (std::getline(input, line)) {
        sanitized << redactLine(line) << '\n';
    }
    return sanitized.str();
}

CommandResult runCommand(const std::vector<std::string>& arguments) {
    CommandResult result;
    if (arguments.empty()) {
        result.output = "command not specified\n";
        result.status = 64;
        return result;
    }

    int descriptors[2] = {-1, -1};
    if (pipe(descriptors) != 0) {
        result.output = "cannot create output pipe: " + std::string(std::strerror(errno)) + "\n";
        return result;
    }
    const pid_t child = fork();
    if (child == 0) {
        (void)close(descriptors[0]);
        (void)dup2(descriptors[1], STDOUT_FILENO);
        (void)dup2(descriptors[1], STDERR_FILENO);
        (void)close(descriptors[1]);
        std::vector<char*> argv;
        argv.reserve(arguments.size() + 1);
        for (const auto& argument : arguments) {
            argv.push_back(const_cast<char*>(argument.c_str()));
        }
        argv.push_back(nullptr);
        execv(argv[0], argv.data());
        _exit(127);
    }
    (void)close(descriptors[1]);
    if (child < 0) {
        result.output = "cannot start command: " + std::string(std::strerror(errno)) + "\n";
        (void)close(descriptors[0]);
        return result;
    }

    char buffer[16 * 1024];
    while (true) {
        const ssize_t count = read(descriptors[0], buffer, sizeof(buffer));
        if (count > 0) {
            const size_t remaining = result.output.size() < kMaximumCommandBytes
                ? kMaximumCommandBytes - result.output.size()
                : 0;
            const size_t accepted = std::min(remaining, static_cast<size_t>(count));
            result.output.append(buffer, accepted);
            result.truncated = result.truncated || accepted < static_cast<size_t>(count);
            continue;
        }
        if (count < 0 && errno == EINTR) {
            continue;
        }
        break;
    }
    (void)close(descriptors[0]);

    int status = 0;
    while (waitpid(child, &status, 0) < 0) {
        if (errno != EINTR) {
            result.output += "cannot wait for command: " + std::string(std::strerror(errno)) + "\n";
            return result;
        }
    }
    result.status = WIFEXITED(status) ? WEXITSTATUS(status) : 128;
    result.output = redact(result.output);
    return result;
}

std::string commandLabel(const std::vector<std::string>& arguments) {
    std::ostringstream label;
    for (size_t index = 0; index < arguments.size(); ++index) {
        if (index != 0) {
            label << ' ';
        }
        label << arguments[index];
    }
    return label.str();
}

void appendCommand(std::ostringstream& report,
                   const std::string& title,
                   const std::vector<std::string>& arguments) {
    report << "### " << title << "\n$ " << commandLabel(arguments) << '\n';
    const CommandResult result = runCommand(arguments);
    report << (result.output.empty() ? "(no output)\n" : result.output);
    if (result.truncated) {
        report << "[output truncated at " << kMaximumCommandBytes << " bytes]\n";
    }
    report << "[exit status: " << result.status << "]\n\n";
}

std::string readFile(const char* path, size_t maximumBytes, bool tail) {
    const int descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (descriptor < 0) {
        return "cannot read " + std::string(path) + ": " + std::strerror(errno) + "\n";
    }
    struct stat information {};
    if (fstat(descriptor, &information) != 0 || !S_ISREG(information.st_mode)) {
        const std::string message = "not a readable regular file: " + std::string(path) + "\n";
        (void)close(descriptor);
        return message;
    }
    off_t start = 0;
    if (tail && information.st_size > static_cast<off_t>(maximumBytes)) {
        start = information.st_size - static_cast<off_t>(maximumBytes);
        if (lseek(descriptor, start, SEEK_SET) < 0) {
            start = 0;
        }
    }

    std::string contents;
    contents.reserve(std::min(maximumBytes, static_cast<size_t>(std::max<off_t>(0, information.st_size))));
    char buffer[16 * 1024];
    while (contents.size() < maximumBytes) {
        const size_t wanted = std::min(sizeof(buffer), maximumBytes - contents.size());
        const ssize_t count = read(descriptor, buffer, wanted);
        if (count > 0) {
            contents.append(buffer, static_cast<size_t>(count));
            continue;
        }
        if (count < 0 && errno == EINTR) {
            continue;
        }
        break;
    }
    (void)close(descriptor);
    if (start > 0) {
        const size_t newline = contents.find('\n');
        if (newline != std::string::npos) {
            contents.erase(0, newline + 1);
        }
    }
    return redact(contents);
}

std::string lastLines(const std::string& contents, size_t maximumLines) {
    size_t position = contents.size();
    size_t lines = 0;
    while (position > 0 && lines <= maximumLines) {
        --position;
        if (contents[position] == '\n') {
            ++lines;
        }
    }
    return lines > maximumLines ? contents.substr(position + 1) : contents;
}

std::string fileMetadata(const char* path) {
    struct stat information {};
    if (lstat(path, &information) != 0) {
        return std::string(path) + ": unavailable (" + std::strerror(errno) + ")\n";
    }
    std::ostringstream output;
    output << path << ": type=";
    if (S_ISREG(information.st_mode)) {
        output << "file";
    } else if (S_ISLNK(information.st_mode)) {
        output << "symlink";
    } else if (S_ISSOCK(information.st_mode)) {
        output << "socket";
    } else if (S_ISDIR(information.st_mode)) {
        output << "directory";
    } else {
        output << "other";
    }
    output << " uid=" << information.st_uid
           << " gid=" << information.st_gid
           << " mode=" << std::oct << std::setfill('0') << std::setw(4)
           << (information.st_mode & 07777) << std::dec
           << " size=" << information.st_size << '\n';
    return output.str();
}

std::string utcTimestamp() {
    NSDateFormatter* formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'Z'";
    return [[formatter stringFromDate:[NSDate date]] UTF8String];
}

NSDictionary* runtimeStatusObject() {
    NSData* data = [NSData dataWithContentsOfFile:@"/var/run/horndis/status.json"];
    if (data == nil) {
        return nil;
    }
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [object isKindOfClass:[NSDictionary class]] ? object : nil;
}

NSString* hostInterface(NSDictionary* object) {
    NSString* interface = [object isKindOfClass:[NSDictionary class]]
        ? object[@"host_interface"]
        : nil;
    return [interface isKindOfClass:[NSString class]] && interface.length > 0 ? interface : nil;
}

std::string safeRuntimeSummary(NSDictionary* object) {
    if (object == nil) {
        return "Runtime status unavailable.\n";
    }
    const std::vector<std::pair<NSString*, const char*>> fields = {
        {@"schema_version", "Schema version"},
        {@"state", "State"},
        {@"device_alias", "Device"},
        {@"host_interface", "Interface"},
        {@"detail", "Detail"},
        {@"received_bytes", "RX bytes"},
        {@"transmitted_bytes", "TX bytes"},
        {@"connected_since", "Connected since"},
        {@"control_available", "Control available"},
        {@"updated_at", "Status updated"},
        {@"process_id", "Service PID"},
    };
    std::ostringstream output;
    for (const auto& [key, label] : fields) {
        id value = object[key];
        if (value != nil && value != [NSNull null]) {
            output << label << ": " << [[value description] UTF8String] << '\n';
        }
    }
    return redact(output.str());
}

std::string usbSummary() {
    std::ostringstream output;
    const auto devices = RNDISUSBTransport::scan();
    if (devices.empty()) {
        return "No RNDIS, CDC-ECM, or CDC-NCM USB networking function detected.\n";
    }
    for (size_t index = 0; index < devices.size(); ++index) {
        const auto& device = devices[index];
        output << "USB function " << (index + 1) << ": " << protocolName(device.protocol)
               << " vid=0x" << std::hex << std::setfill('0') << std::setw(4) << device.vendorId
               << " pid=0x" << std::setw(4) << device.productId
               << std::dec << " interfaces=" << static_cast<unsigned>(device.controlInterfaceNumber)
               << '/' << static_cast<unsigned>(device.dataInterfaceNumber)
               << (device.supported ? " supported" : " backend-pending") << '\n';
    }
    return redact(output.str());
}

std::string safeNetworkSummary(NSString* interface) {
    if (interface == nil) {
        return "No selected HoRNDIS host interface was present.\n";
    }
    const std::string name = interface.UTF8String;
    const unsigned index = if_nametoindex(name.c_str());
    bool hasIPv4 = false;
    bool hasIPv6 = false;
    unsigned flags = 0;
    ifaddrs* addresses = nullptr;
    if (getifaddrs(&addresses) == 0) {
        for (const ifaddrs* current = addresses; current != nullptr; current = current->ifa_next) {
            if (current->ifa_name == nullptr || name != current->ifa_name) {
                continue;
            }
            flags = current->ifa_flags;
            if (current->ifa_addr != nullptr) {
                hasIPv4 = hasIPv4 || current->ifa_addr->sa_family == AF_INET;
                hasIPv6 = hasIPv6 || current->ifa_addr->sa_family == AF_INET6;
            }
        }
        freeifaddrs(addresses);
    }

    int mtu = -1;
    const int socketDescriptor = socket(AF_INET, SOCK_DGRAM, 0);
    if (socketDescriptor >= 0) {
        ifreq request {};
        (void)strlcpy(request.ifr_name, name.c_str(), sizeof(request.ifr_name));
        if (ioctl(socketDescriptor, SIOCGIFMTU, &request) == 0) {
            mtu = request.ifr_mtu;
        }
        (void)close(socketDescriptor);
    }
    std::ostringstream output;
    output << "Interface: " << name << '\n'
           << "Present: " << (index != 0 ? "yes" : "no") << '\n'
           << "Up: " << ((flags & IFF_UP) != 0 ? "yes" : "no") << '\n'
           << "Running: " << ((flags & IFF_RUNNING) != 0 ? "yes" : "no") << '\n'
           << "MTU: " << (mtu >= 0 ? std::to_string(mtu) : "unavailable") << '\n'
           << "IPv4 configured: " << (hasIPv4 ? "yes" : "no") << '\n'
           << "IPv6 configured: " << (hasIPv6 ? "yes" : "no") << '\n';
    return output.str();
}

bool writeAll(int descriptor, const std::string& contents, std::string& error) {
    size_t offset = 0;
    while (offset < contents.size()) {
        const ssize_t count = write(descriptor, contents.data() + offset, contents.size() - offset);
        if (count < 0) {
            if (errno == EINTR) {
                continue;
            }
            error = "cannot write diagnostic report: " + std::string(std::strerror(errno));
            return false;
        }
        offset += static_cast<size_t>(count);
    }
    return true;
}

} // namespace

std::string buildDiagnosticReport(const std::string& version) {
    std::ostringstream report;
    report << "HoRNDIS Diagnostics Report\n"
           << "Report format: 1\n"
           << "Generated (UTC): " << utcTimestamp() << "\n"
           << "HoRNDIS version: " << version << "\n\n"
           << "Privacy: this report does not include account/full names, host or device names, "
              "USB serial numbers, device location IDs, MAC or IP addresses, home-directory "
              "names, hardware serial numbers, hardware UUIDs, packet contents, or credentials. "
              "Users are labeled `user`; connected devices retain their in-memory `device N` "
              "alias, and anonymous USB functions are numbered independently. "
              "Legacy service-log lines are sanitized before inclusion. Review this file before "
              "sharing it.\n\n";

    report << "## System\n\n";
    appendCommand(report, "macOS version", {"/usr/bin/sw_vers"});
    appendCommand(report, "Machine architecture", {"/usr/bin/uname", "-m"});
    appendCommand(report, "Mac model", {"/usr/sbin/sysctl", "-n", "hw.model"});
    appendCommand(report, "System Integrity Protection", {"/usr/bin/csrutil", "status"});

    NSDictionary* runtime = runtimeStatusObject();
    report << "## HoRNDIS runtime status (safe fields only)\n\n"
           << safeRuntimeSummary(runtime) << '\n';
    appendCommand(report,
                  "LaunchDaemon state",
                  {"/bin/launchctl", "print", "system/io.github.noahhhi.horndis"});

    report << "### Installed/runtime file metadata\n"
           << fileMetadata("/Library/PrivilegedHelperTools/io.github.noahhhi.horndis")
           << fileMetadata("/Library/LaunchDaemons/io.github.noahhhi.horndis.plist")
           << fileMetadata("/var/run/horndis")
           << fileMetadata("/var/run/horndis/status.json")
           << fileMetadata("/var/run/horndis/control.sock")
           << fileMetadata("/var/log/horndis.log") << '\n';

    report << "## USB (non-identifying descriptor fields only)\n\n"
           << "### HoRNDIS USB scan\n"
           << usbSummary() << '\n';
    report << "### Legacy driver installation checks\n"
           << fileMetadata("/Library/Extensions/HoRNDIS.kext")
           << fileMetadata("/System/Library/Extensions/HoRNDIS.kext") << '\n';

    report << "## Network (address values not collected)\n\n"
           << safeNetworkSummary(hostInterface(runtime)) << '\n';

    report << "## Recent service log\n\n"
           << "Source: /var/log/horndis.log (last " << kMaximumLogLines
           << " lines, at most " << kMaximumLogBytes << " bytes)\n\n";
    const std::string serviceLog = readFile("/var/log/horndis.log", kMaximumLogBytes, true);
    report << lastLines(serviceLog, kMaximumLogLines);
    if (serviceLog.empty() || serviceLog.back() != '\n') {
        report << '\n';
    }
    report << "\nEnd of HoRNDIS Diagnostics Report\n";
    return redactIdentifiers(report.str());
}

bool writeDiagnosticReport(const std::string& path,
                           const std::string& version,
                           std::string& error) {
    const int descriptor = open(path.c_str(),
                                O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW,
                                0600);
    if (descriptor < 0) {
        error = "cannot create diagnostic report at " + path + ": " + std::strerror(errno);
        return false;
    }
    struct stat information {};
    if (fstat(descriptor, &information) != 0 || !S_ISREG(information.st_mode) ||
        fchmod(descriptor, 0600) != 0) {
        error = "diagnostic report target is not a secure regular file";
        (void)close(descriptor);
        return false;
    }
    const std::string report = buildDiagnosticReport(version);
    const bool wrote = writeAll(descriptor, report, error);
    const bool synced = wrote && fsync(descriptor) == 0;
    const int closeResult = close(descriptor);
    if (!wrote || !synced || closeResult != 0) {
        if (error.empty()) {
            error = "cannot finish diagnostic report: " + std::string(std::strerror(errno));
        }
        return false;
    }
    return true;
}

} // namespace horndis
