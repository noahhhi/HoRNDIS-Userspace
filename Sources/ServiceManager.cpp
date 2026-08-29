// SPDX-License-Identifier: GPL-3.0-or-later
#include "ServiceManager.hpp"
#include "RuntimeStatus.hpp"

#include <copyfile.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <spawn.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#include <cerrno>
#include <chrono>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

extern char** environ;

namespace horndis {
namespace {

constexpr const char* kLabel = "io.github.noahhhi.horndis";
constexpr const char* kHelperDirectory = "/Library/PrivilegedHelperTools";
constexpr const char* kHelper = "/Library/PrivilegedHelperTools/io.github.noahhhi.horndis";
constexpr const char* kPlist = "/Library/LaunchDaemons/io.github.noahhhi.horndis.plist";

bool requireRoot(std::string& error) {
    if (geteuid() == 0) {
        return true;
    }
    error = "service installation requires root; run the command with sudo";
    return false;
}

bool runLaunchctl(const std::vector<std::string>& arguments,
                  bool allowFailure,
                  std::string& error,
                  bool quiet = false) {
    std::vector<char*> argv{const_cast<char*>("/bin/launchctl")};
    for (const auto& argument : arguments) {
        argv.push_back(const_cast<char*>(argument.c_str()));
    }
    argv.push_back(nullptr);
    pid_t child = 0;
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_t* actionsPointer = nullptr;
    if (quiet) {
        const int initResult = posix_spawn_file_actions_init(&actions);
        if (initResult != 0) {
            error = "cannot configure launchctl output";
            return false;
        }
        const int stdoutResult = posix_spawn_file_actions_addopen(&actions,
                                                                  STDOUT_FILENO,
                                                                  "/dev/null",
                                                                  O_WRONLY,
                                                                  0);
        const int stderrResult = posix_spawn_file_actions_addopen(&actions,
                                                                  STDERR_FILENO,
                                                                  "/dev/null",
                                                                  O_WRONLY,
                                                                  0);
        if (stdoutResult != 0 || stderrResult != 0) {
            posix_spawn_file_actions_destroy(&actions);
            error = "cannot configure launchctl output";
            return false;
        }
        actionsPointer = &actions;
    }
    const int spawnResult = posix_spawn(&child,
                                        "/bin/launchctl",
                                        actionsPointer,
                                        nullptr,
                                        argv.data(),
                                        environ);
    if (actionsPointer != nullptr) {
        posix_spawn_file_actions_destroy(&actions);
    }
    if (spawnResult != 0) {
        error = "cannot run launchctl: " + std::string(std::strerror(spawnResult));
        return false;
    }
    int status = 0;
    while (waitpid(child, &status, 0) < 0) {
        if (errno != EINTR) {
            error = "cannot wait for launchctl: " + std::string(std::strerror(errno));
            return false;
        }
    }
    if ((!WIFEXITED(status) || WEXITSTATUS(status) != 0) && !allowFailure) {
        error = "launchctl failed with status " +
                std::to_string(WIFEXITED(status) ? WEXITSTATUS(status) : -1);
        return false;
    }
    return true;
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

bool writeAll(int descriptor, const std::string& contents, std::string& error) {
    size_t offset = 0;
    while (offset < contents.size()) {
        const ssize_t count = write(descriptor, contents.data() + offset, contents.size() - offset);
        if (count < 0) {
            if (errno == EINTR) {
                continue;
            }
            error = "cannot write launch daemon configuration: " + std::string(std::strerror(errno));
            return false;
        }
        offset += static_cast<size_t>(count);
    }
    return true;
}

bool ensureHelperDirectory(std::string& error) {
    if (mkdir(kHelperDirectory, 01755) == 0) {
        if (chown(kHelperDirectory, 0, 0) != 0) {
            error = "cannot set privileged helper directory ownership: " +
                    std::string(std::strerror(errno));
            return false;
        }
        if (chmod(kHelperDirectory, 01755) != 0) {
            error = "cannot set privileged helper directory permissions: " +
                    std::string(std::strerror(errno));
            return false;
        }
        return true;
    }
    if (errno != EEXIST) {
        error = "cannot create the privileged helper directory: " +
                std::string(std::strerror(errno));
        return false;
    }

    struct stat metadata {};
    if (lstat(kHelperDirectory, &metadata) != 0) {
        error = "cannot inspect the privileged helper directory: " +
                std::string(std::strerror(errno));
        return false;
    }
    if (!S_ISDIR(metadata.st_mode)) {
        error = "the privileged helper directory path is not a directory";
        return false;
    }
    return true;
}

std::string plistContents() {
    return std::string("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n") +
           "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" "
           "\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
           "<plist version=\"1.0\">\n"
           "<dict>\n"
           "  <key>Label</key><string>" + kLabel + "</string>\n"
           "  <key>ProgramArguments</key>\n"
           "  <array><string>" + kHelper + "</string><string>run</string></array>\n"
           "  <key>RunAtLoad</key><true/>\n"
           "  <key>KeepAlive</key><true/>\n"
           "  <key>ThrottleInterval</key><integer>5</integer>\n"
           "  <key>ProcessType</key><string>Interactive</string>\n"
           "  <key>StandardOutPath</key><string>/var/log/horndis.log</string>\n"
           "  <key>StandardErrorPath</key><string>/var/log/horndis.log</string>\n"
           "</dict>\n"
           "</plist>\n";
}

} // namespace

bool installLaunchDaemon(std::string& error) {
    if (!requireRoot(error)) {
        return false;
    }
    const std::string source = executablePath(error);
    if (source.empty()) {
        return false;
    }
    if (!ensureHelperDirectory(error)) {
        return false;
    }

    std::string ignored;
    (void)runLaunchctl({"bootout", std::string("system/") + kLabel}, true, ignored, true);

    const std::string temporaryHelper = std::string(kHelper) + ".tmp." + std::to_string(getpid());
    if (copyfile(source.c_str(), temporaryHelper.c_str(), nullptr, COPYFILE_DATA) != 0) {
        error = "cannot copy the privileged helper: " + std::string(std::strerror(errno));
        return false;
    }
    if (chmod(temporaryHelper.c_str(), 0755) != 0 || chown(temporaryHelper.c_str(), 0, 0) != 0 ||
        rename(temporaryHelper.c_str(), kHelper) != 0) {
        error = "cannot install the privileged helper: " + std::string(std::strerror(errno));
        unlink(temporaryHelper.c_str());
        return false;
    }

    const std::string temporaryPlist = std::string(kPlist) + ".tmp." + std::to_string(getpid());
    const int descriptor = open(temporaryPlist.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0644);
    if (descriptor < 0) {
        error = "cannot create the launch daemon configuration: " + std::string(std::strerror(errno));
        return false;
    }
    const bool wrote = writeAll(descriptor, plistContents(), error);
    const int closeResult = close(descriptor);
    if (!wrote || closeResult != 0 || chmod(temporaryPlist.c_str(), 0644) != 0 ||
        chown(temporaryPlist.c_str(), 0, 0) != 0 || rename(temporaryPlist.c_str(), kPlist) != 0) {
        if (error.empty()) {
            error = "cannot install the launch daemon configuration: " +
                    std::string(std::strerror(errno));
        }
        unlink(temporaryPlist.c_str());
        return false;
    }

    bool bootstrapped = false;
    std::string bootstrapError;
    for (int attempt = 0; attempt < 80; ++attempt) {
        bootstrapError.clear();
        if (runLaunchctl({"bootstrap", "system", kPlist}, false, bootstrapError, true)) {
            bootstrapped = true;
            break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(250));
    }
    if (!bootstrapped) {
        error = bootstrapError;
        return false;
    }
    return runLaunchctl({"kickstart", "-k", std::string("system/") + kLabel}, false, error);
}

bool uninstallLaunchDaemon(std::string& error) {
    if (!requireRoot(error)) {
        return false;
    }
    std::string ignored;
    (void)runLaunchctl({"bootout", std::string("system/") + kLabel}, true, ignored, true);
    if (unlink(kPlist) != 0 && errno != ENOENT) {
        error = "cannot remove the launch daemon configuration: " +
                std::string(std::strerror(errno));
        return false;
    }
    if (unlink(kHelper) != 0 && errno != ENOENT) {
        error = "cannot remove the privileged helper: " + std::string(std::strerror(errno));
        return false;
    }
    removeRuntimeStatus();
    return true;
}

} // namespace horndis
