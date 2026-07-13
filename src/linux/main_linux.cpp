// main_linux.cpp
// POSIX CLI entry point: probe / dump / bridge, streaming head tracking over UDP
// to OpenTrack. The Windows GUI, one-click repair, and Bluetooth-rebind commands
// are intentionally omitted; on Linux pairing is done with bluetoothctl and the
// tracker appears directly as a /dev/hidraw* node.
#include "sony_head_tracker/hid_backend.hpp"
#include "sony_head_tracker/logger.hpp"
#include "sony_head_tracker/orientation.hpp"
#include "sony_head_tracker/output_udp.hpp"
#include "sony_head_tracker/platform_compat.hpp"
#include "sony_head_tracker/types.hpp"
#include "sony_head_tracker/version.hpp"

#include <fcntl.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <csignal>
#include <mutex>
#include <string>
#include <string_view>
#include <thread>
#include <vector>

namespace {

std::atomic_bool stopRequested{false};
void onSignal(int) { stopRequested = true; }

std::string narrow(std::wstring_view w) { return sony::wideToUtf8(w); }

void printUsage() {
    std::printf(
        "Sony Head Tracker (Linux) %s\n"
        "Streams head tracking from Sony headphones exposing the Android Head Tracker\n"
        "HID sensor, over UDP (OpenTrack + JSON). Pair the headset with bluetoothctl;\n"
        "it then appears as a /dev/hidraw* node.\n\n"
        "Usage:\n"
        "  sony-head-tracker probe                     list HID devices, flag the tracker\n"
        "  sony-head-tracker dump [--seconds N]        hex-dump raw input reports\n"
        "  sony-head-tracker bridge [--port 4242] [--seconds N]\n"
        "                           [--axis-map YXZ] [--invert XZ] [--smoothing 0.18]\n"
        "  sony-head-tracker help | version\n\n"
        "bridge sends six little-endian doubles (x, y, z, yaw, pitch, roll) to UDP\n"
        "127.0.0.1:<port> and a JSON datagram to <port>+1. Loopback only.\n",
        narrow(sony::kVersion).c_str());
}

void printDevice(const sony::DeviceInfo& d) {
    std::printf("HID %s\n  %s\n  usage 0x%04X:0x%04X  VID/PID %04X:%04X  input=%u bytes\n",
                narrow(d.instanceId).c_str(), narrow(d.product).c_str(),
                d.usagePage, d.usage, d.vendorId, d.productId, d.inputReportBytes);
    if (!d.sensorDescription.empty()) std::printf("  description: %s\n", d.sensorDescription.c_str());
    std::printf("  verified Android tracker: %s\n", d.androidHeadTracker ? "yes" : "no");
    if (d.accessDenied) std::printf("  (access denied; need a udev rule or run as root)\n");
}

const sony::DeviceInfo* findTracker(const std::vector<sony::DeviceInfo>& devices) {
    for (const auto& d : devices) if (d.androidHeadTracker) return &d;
    return nullptr;
}

int runProbe(sony::HidBackend& hid) {
    const auto devices = hid.enumerate();
    for (const auto& d : devices) printDevice(d);
    if (const auto* t = findTracker(devices)) {
        const auto name = narrow(t->product.empty() ? t->instanceId : t->product);
        if (t->accessDenied) {
            std::printf("\nDetected Android head tracker on '%s', but no device access yet.\n"
                        "Grant one-time access with the udev rule (then reconnect the headset):\n"
                        "  sudo cp extras/70-sony-head-tracker.rules /etc/udev/rules.d/\n"
                        "  sudo udevadm control --reload-rules && sudo udevadm trigger\n"
                        "or run this command with sudo.\n", name.c_str());
            return 4;
        }
        std::printf("\nVerified Android head tracker on '%s'.\n", name.c_str());
        return 0;
    }
    std::printf("\nNo Android Head Tracker HID sensor was found.\n"
                "Pair the headset over Bluetooth and make sure it is connected to this computer.\n");
    return 2;
}

int runDump(sony::HidBackend& hid, unsigned seconds) {
    const auto devices = hid.enumerate();
    const auto* tracker = findTracker(devices);
    if (!tracker) { std::fprintf(stderr, "No verified head tracker is accessible.\n"); return 2; }
    if (!hid.connect(*tracker, [](const std::vector<std::uint8_t>& b) { std::printf("%s\n", narrow(sony::hexDump(b)).c_str()); }, [](auto) {}))
        return 3;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(seconds);
    while (!stopRequested && (!seconds || std::chrono::steady_clock::now() < deadline))
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    hid.disconnect();
    return 0;
}

int runBridge(sony::HidBackend& hid, int argc, char** argv) {
    std::uint16_t port = 4242;
    unsigned seconds = 0;
    sony::FilterConfig config;
    for (int i = 2; i < argc; ++i) {
        const std::string_view opt = argv[i];
        if (opt == "--port" && i + 1 < argc) {
            const long v = std::strtol(argv[++i], nullptr, 10);
            if (v < 1 || v > 65534) { std::fprintf(stderr, "--port must be 1..65534 (JSON uses port+1)\n"); return 1; }
            port = static_cast<std::uint16_t>(v);
        } else if (opt == "--seconds" && i + 1 < argc) {
            seconds = static_cast<unsigned>(std::strtoul(argv[++i], nullptr, 10));
        } else if (opt == "--smoothing" && i + 1 < argc) {
            config.smoothing = std::clamp(std::strtod(argv[++i], nullptr), 0.01, 1.0);
        } else if (opt == "--invert" && i + 1 < argc) {
            const std::string axes = argv[++i];
            config.axes.sign = {1.0, 1.0, 1.0};
            for (const char a : axes) { if (a == 'x' || a == 'X') config.axes.sign[0] = -1; if (a == 'y' || a == 'Y') config.axes.sign[1] = -1; if (a == 'z' || a == 'Z') config.axes.sign[2] = -1; }
        } else if (opt == "--axis-map" && i + 1 < argc) {
            const std::string map = argv[++i];
            if (map.size() == 3) for (unsigned o = 0; o < 3; ++o) { const char c = static_cast<char>(std::tolower(map[o])); config.axes.source[o] = c == 'x' ? 0 : c == 'y' ? 1 : 2; }
        } else if (opt == "--level") {
            config.levelOutput = true;   // world-frame output: cancels mounting tilt
        }
    }

    sony::UdpOutput udp;
    if (!udp.open("127.0.0.1", port)) { std::fprintf(stderr, "Could not open UDP output\n"); return 4; }
    std::printf("Streaming head-tracking data:\n  OpenTrack doubles -> UDP 127.0.0.1:%u\n  JSON telemetry    -> UDP 127.0.0.1:%u\n(loopback only)\n", port, port + 1);

    const auto devices = hid.enumerate();
    const auto* tracker = findTracker(devices);
    if (!tracker) { std::fprintf(stderr, "No Android Head Tracker was found on any connected headset.\n"); return 3; }

    sony::OrientationFilter filter(config);
    std::mutex filterMutex;               // guards filter between the reader thread and control
    sony::FilterConfig live = config;     // mutable copy updated by live control messages
    const auto& label = tracker->product;
    udp.setDeviceLabel(label);
    if (!label.empty()) std::printf("Tracking headset: %s\n", narrow(label).c_str());

    auto output = [&](sony::MotionSample s) {
        sony::MotionSample out;
        { std::scoped_lock lock(filterMutex); out = filter.process(std::move(s)); }
        udp.send(out);
        std::printf("\rYPR %7.2f %7.2f %7.2f  %5.1f pps   ", out.euler.yaw, out.euler.pitch, out.euler.roll, out.packetsPerSecond);
        std::fflush(stdout);
    };
    if (!hid.connect(*tracker, {}, output)) { std::fprintf(stderr, "Failed to connect to the head tracker.\n"); return 3; }

    // Live control socket (127.0.0.1:port+3): the GUI sends axis/smoothing updates
    // and recenter here so settings apply WITHOUT restarting the stream. Purely
    // additive; if the bind fails we just run without live control.
    int ctrl = ::socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (ctrl >= 0) {
        sockaddr_in ca{};
        ca.sin_family = AF_INET;
        ca.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        ca.sin_port = htons(static_cast<std::uint16_t>(port + 3));
        if (::bind(ctrl, reinterpret_cast<sockaddr*>(&ca), sizeof(ca)) < 0) { ::close(ctrl); ctrl = -1; }
        else { const int fl = ::fcntl(ctrl, F_GETFL, 0); ::fcntl(ctrl, F_SETFL, fl | O_NONBLOCK); }
    }

    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(seconds);
    while (!stopRequested && (!seconds || std::chrono::steady_clock::now() < deadline)) {
        if (!hid.connected()) { std::fprintf(stderr, "\nDisconnected.\n"); break; }
        if (ctrl >= 0) {
            char buf[128];
            ssize_t n;
            while ((n = ::recv(ctrl, buf, sizeof(buf) - 1, 0)) > 0) {
                buf[n] = '\0';
                if (std::strncmp(buf, "RECENTER", 8) == 0) {
                    std::scoped_lock lock(filterMutex);
                    filter.recenter();
                } else if (std::strncmp(buf, "OUT", 3) == 0) {
                    unsigned s0, s1, s2;
                    double g0, g1, g2, sm;
                    if (std::sscanf(buf + 3, "%u %u %u %lf %lf %lf %lf", &s0, &s1, &s2, &g0, &g1, &g2, &sm) == 7) {
                        live.outputSource = {s0 % 3, s1 % 3, s2 % 3};
                        live.outputSign = {g0, g1, g2};
                        live.smoothing = std::clamp(sm, 0.01, 1.0);
                        std::scoped_lock lock(filterMutex);
                        filter.setConfig(live);
                    }
                } else if (std::strncmp(buf, "LEVEL", 5) == 0) {
                    int on = 0;
                    if (std::sscanf(buf + 5, "%d", &on) == 1) {
                        live.levelOutput = (on != 0);
                        std::scoped_lock lock(filterMutex);
                        filter.setConfig(live);
                    }
                }
            }
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
    if (ctrl >= 0) ::close(ctrl);
    hid.disconnect();
    std::printf("\n");
    return 0;
}

} // namespace

int main(int argc, char** argv) {
    std::signal(SIGINT, onSignal);
    std::signal(SIGTERM, onSignal);
    const std::string command = argc > 1 ? argv[1] : "help";

    if (command == "version" || command == "--version" || command == "-v") { std::printf("sony-head-tracker %s\n", narrow(sony::kVersion).c_str()); return 0; }
    if (command == "help" || command == "--help" || command == "-h") { printUsage(); return 0; }

    sony::Logger::instance().setSink([](sony::LogLevel, const std::wstring& line) { std::fprintf(stderr, "%s\n", sony::wideToUtf8(line).c_str()); });

    sony::HidBackend hid;
    if (command == "probe") return runProbe(hid);
    if (command == "dump") {
        unsigned seconds = 0;
        for (int i = 2; i + 1 < argc; ++i) if (std::string_view(argv[i]) == "--seconds") seconds = static_cast<unsigned>(std::strtoul(argv[i + 1], nullptr, 10));
        return runDump(hid, seconds);
    }
    if (command == "bridge") return runBridge(hid, argc, argv);

    std::fprintf(stderr, "Unknown command '%s'.\n\n", command.c_str());
    printUsage();
    return 1;
}
