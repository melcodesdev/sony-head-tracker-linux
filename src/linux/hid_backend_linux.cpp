// hid_backend_linux.cpp
// Linux hidraw implementation of HidBackend. Replaces the Windows SetupAPI +
// HidP_* file: enumerates /dev/hidraw* via ioctl, parses the report descriptor
// ourselves (hid_report_parser), writes the sensor feature reports that start the
// stream, then read()s input reports and decodes them into MotionSamples using
// the shared, unit-tested decode path.
#include "sony_head_tracker/hid_backend.hpp"

#include "sony_head_tracker/hid_descriptor.hpp"
#include "sony_head_tracker/hid_report_parser.hpp"
#include "sony_head_tracker/hid_usages.hpp"
#include "sony_head_tracker/logger.hpp"
#include "sony_head_tracker/platform_compat.hpp"

#include <linux/hidraw.h>
#include <sys/ioctl.h>
#include <fcntl.h>
#include <poll.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <dirent.h>
#include <format>
#include <fstream>
#include <map>
#include <sstream>
#include <string>
#include <vector>

namespace sony {

namespace {

std::wstring toW(const std::string& s) { return utf8ToWide(s); }
std::string errnoText() { return std::strerror(errno); }

// RAII file descriptor.
struct Fd {
    int value{-1};
    Fd() = default;
    explicit Fd(int v) : value(v) {}
    ~Fd() { if (value >= 0) ::close(value); }
    Fd(Fd&& o) noexcept : value(o.value) { o.value = -1; }
    Fd& operator=(Fd&& o) noexcept { if (this != &o) { if (value >= 0) ::close(value); value = o.value; o.value = -1; } return *this; }
    Fd(const Fd&) = delete; Fd& operator=(const Fd&) = delete;
    [[nodiscard]] bool ok() const { return value >= 0; }
};

std::vector<std::string> hidrawNodes() {
    std::vector<std::string> nodes;
    if (DIR* dir = ::opendir("/sys/class/hidraw")) {
        while (dirent* e = ::readdir(dir)) {
            std::string name = e->d_name;
            if (name.rfind("hidraw", 0) == 0) nodes.push_back("/dev/" + name);
        }
        ::closedir(dir);
    }
    std::sort(nodes.begin(), nodes.end());
    return nodes;
}

std::vector<std::uint8_t> readDescriptor(int fd) {
    int size = 0;
    if (::ioctl(fd, HIDIOCGRDESCSIZE, &size) < 0 || size <= 0) return {};
    hidraw_report_descriptor rpt{};
    rpt.size = static_cast<std::uint32_t>(size);
    if (::ioctl(fd, HIDIOCGRDESC, &rpt) < 0) return {};
    return {rpt.value, rpt.value + size};
}

// Extract `bitCount` bits starting at absolute `bitOffset` in `report`, packed
// LSB-first into a fresh buffer whose bit 0 is the field's first bit; the layout
// decodePackedDescriptorValues expects.
std::vector<std::uint8_t> extractBits(const std::vector<std::uint8_t>& report, unsigned bitOffset, unsigned bitCount) {
    std::vector<std::uint8_t> out((bitCount + 7) / 8, 0);
    for (unsigned i = 0; i < bitCount; ++i) {
        const unsigned src = bitOffset + i;
        if (src / 8 >= report.size()) break;
        if ((report[src / 8] >> (src % 8)) & 1u) out[i / 8] |= static_cast<std::uint8_t>(1u << (i % 8));
    }
    return out;
}

std::uint64_t extractRaw(const std::vector<std::uint8_t>& report, unsigned bitOffset, unsigned bitCount) {
    std::uint64_t v = 0;
    for (unsigned i = 0; i < bitCount && i < 64; ++i) {
        const unsigned src = bitOffset + i;
        if (src / 8 >= report.size()) break;
        if ((report[src / 8] >> (src % 8)) & 1u) v |= std::uint64_t{1} << i;
    }
    return v;
}

// Pack `value` LSB-first into `bitCount` bits at absolute `bitOffset` of `report`.
void packBits(std::vector<std::uint8_t>& report, unsigned bitOffset, unsigned bitCount, std::uint64_t value) {
    for (unsigned i = 0; i < bitCount; ++i) {
        const unsigned dst = bitOffset + i;
        if (dst / 8 >= report.size()) break;
        const std::uint8_t bit = (value >> i) & 1u;
        const std::uint8_t mask = static_cast<std::uint8_t>(1u << (dst % 8));
        if (bit) report[dst / 8] |= mask; else report[dst / 8] &= static_cast<std::uint8_t>(~mask);
    }
}

// Reads a feature report by id and returns its bytes (buffer[0] = id on entry).
std::vector<std::uint8_t> getFeature(int fd, std::uint8_t id, unsigned length) {
    std::vector<std::uint8_t> buf(std::max(length, 1u), 0);
    buf[0] = id;
    if (::ioctl(fd, HIDIOCGFEATURE(static_cast<int>(buf.size())), buf.data()) < 0) return {};
    return buf;
}

bool setFeature(int fd, std::vector<std::uint8_t>& buf) {
    return ::ioctl(fd, HIDIOCSFEATURE(static_cast<int>(buf.size())), buf.data()) >= 0;
}

// Scan a device's feature reports for the #AndroidHeadTracker# marker string,
// which the protocol exposes as a sensor-description feature value.
std::string readTrackerMarker(int fd, const ParsedDescriptor& desc) {
    std::map<std::uint8_t, unsigned> featureReports;
    for (const auto& f : desc.fields)
        if (f.kind == ReportKind::feature)
            featureReports[f.field.reportId] = desc.reportBufferBytes(ReportKind::feature, f.field.reportId);
    for (const auto& [id, len] : featureReports) {
        const auto report = getFeature(fd, id, len);
        if (report.empty()) continue;
        const auto it = std::search(report.begin(), report.end(), kMarker.begin(), kMarker.end());
        if (it != report.end()) {
            std::string s(it, report.end());
            while (!s.empty() && (s.back() == '\0' || static_cast<unsigned char>(s.back()) == 0xff)) s.pop_back();
            return s;
        }
    }
    return {};
}

std::string readSysfsText(const std::string& path) {
    std::ifstream f(path);
    if (!f) return {};
    return std::string((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
}

std::vector<std::uint8_t> readSysfsBytes(const std::string& path) {
    std::ifstream f(path, std::ios::binary);
    if (!f) return {};
    return std::vector<std::uint8_t>((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
}

// Fills usage/fields/input-size from a parsed descriptor and returns whether it
// carries the Android Head Tracker signature (custom sensor collection with the
// rotation-vector usage). Shared by the ioctl and sysfs discovery paths.
bool populateFromDescriptor(DeviceInfo& info, const ParsedDescriptor& desc) {
    info.usagePage = desc.topUsagePage;
    info.usage = desc.topUsage;
    std::uint8_t inputReportId = 0;
    bool haveInput = false, hasRotation = false;
    for (const auto& f : desc.fields) {
        if (f.kind == ReportKind::input && !haveInput) { inputReportId = f.field.reportId; haveInput = true; }
        if (f.kind == ReportKind::input && f.field.usagePage == kSensorPage && f.field.usage == kRotation) hasRotation = true;
    }
    info.inputReportBytes = static_cast<std::uint16_t>(desc.reportBufferBytes(ReportKind::input, inputReportId));
    info.fields.clear();
    for (const auto& f : desc.fields) info.fields.push_back(f.field);
    return info.usagePage == kSensorPage && info.usage == kOtherCustom && hasRotation;
}

// Identify a hidraw node from sysfs alone (world-readable), so we can detect and
// name the tracker even when /dev/hidraw* is not yet accessible. Cannot read the
// #AndroidHeadTracker# feature marker (that needs the device), so it relies on the
// descriptor signature instead.
void probeViaSysfs(const std::string& path, DeviceInfo& info) {
    const auto slash = path.rfind('/');
    const std::string node = slash == std::string::npos ? path : path.substr(slash + 1);
    const std::string dir = "/sys/class/hidraw/" + node + "/device/";

    std::istringstream uevent(readSysfsText(dir + "uevent"));
    for (std::string line; std::getline(uevent, line);) {
        if (line.rfind("HID_NAME=", 0) == 0) {
            info.product = toW(line.substr(9));
        } else if (line.rfind("HID_ID=", 0) == 0) {
            unsigned bus = 0, vid = 0, pid = 0;
            if (std::sscanf(line.c_str() + 7, "%x:%x:%x", &bus, &vid, &pid) == 3) {
                info.vendorId = static_cast<std::uint16_t>(vid);
                info.productId = static_cast<std::uint16_t>(pid);
            }
        }
    }
    const auto descBytes = readSysfsBytes(dir + "report_descriptor");
    if (!descBytes.empty()) info.androidHeadTracker = populateFromDescriptor(info, parseReportDescriptor(descBytes));
    info.accessDenied = true;
    if (info.androidHeadTracker)
        Logger::instance().write(LogLevel::info, std::format(L"Detected Sony head tracker '{}' via sysfs (device access needed)", info.product));
}

DeviceInfo probeNode(const std::string& path, bool& accessible) {
    DeviceInfo info;
    info.path = toW(path);
    info.instanceId = toW(path);
    accessible = false;

    int fd = ::open(path.c_str(), O_RDWR);
    if (fd < 0) { fd = ::open(path.c_str(), O_RDONLY); }
    if (fd < 0) {
        // No device access: still identify it from sysfs so the UI can show the
        // headset and prompt for the one-time access grant.
        const int err = errno;
        probeViaSysfs(path, info);
        if (!info.androidHeadTracker)
            Logger::instance().write(LogLevel::warning, std::format(L"Cannot open {}: {}", toW(path), toW(std::strerror(err))));
        return info;
    }
    Fd guard(fd);
    accessible = true;

    hidraw_devinfo di{};
    if (::ioctl(fd, HIDIOCGRAWINFO, &di) >= 0) {
        info.vendorId = static_cast<std::uint16_t>(di.vendor);
        info.productId = static_cast<std::uint16_t>(di.product);
    }
    std::array<char, 256> name{};
    if (::ioctl(fd, HIDIOCGRAWNAME(static_cast<int>(name.size())), name.data()) >= 0) info.product = toW(name.data());

    const auto descBytes = readDescriptor(fd);
    if (descBytes.empty()) return info;
    const auto desc = parseReportDescriptor(descBytes);
    const bool looksLikeTracker = populateFromDescriptor(info, desc);

    if (info.usagePage == kSensorPage && info.usage == kOtherCustom) {
        info.sensorDescription = readTrackerMarker(fd, desc);
        // Verified when the #AndroidHeadTracker# marker reads back; otherwise fall
        // back to the descriptor signature so devices that hide the constant field
        // still register.
        info.androidHeadTracker = info.sensorDescription.starts_with(kMarker) || looksLikeTracker;
        Logger::instance().write(info.androidHeadTracker ? LogLevel::info : LogLevel::warning,
            std::format(L"Sensor HID VID={:04X} PID={:04X} description='{}'", info.vendorId, info.productId,
                toW(info.sensorDescription)));
    }
    return info;
}

} // namespace

struct HidBackend::Context {
    Fd fd;
    ParsedDescriptor desc;
    std::vector<ParsedField> inputFields;   // sensor-page input fields only
    unsigned inputBufferBytes{};
    std::uint8_t inputReportId{};
    bool usesReportIds{};
    RawCallback raw;
    SampleCallback sample;
    std::chrono::steady_clock::time_point rateStart{std::chrono::steady_clock::now()};
    std::uint64_t rateCount{};
    double rate{};
    std::vector<double> valueScratch;
};

HidBackend::HidBackend() = default;
HidBackend::~HidBackend() { disconnect(); }

std::vector<DeviceInfo> HidBackend::enumerate(bool /*presentInterfacesOnly*/) {
    std::vector<DeviceInfo> devices;
    for (const auto& node : hidrawNodes()) {
        bool accessible = false;
        devices.push_back(probeNode(node, accessible));
    }
    Logger::instance().write(LogLevel::info, std::format(L"Scanned {} hidraw node(s)", devices.size()));
    return devices;
}

namespace {

// Build and send the feature reports that make the headset stream: report
// interval (10-20 ms), plus the ACL transport / full-power / all-events
// selectors. Selector encoding is best-effort against the descriptor's usage
// ranges and should be validated against a captured device descriptor.
bool configureFeatures(int fd, const ParsedDescriptor& desc) {
    std::map<std::uint8_t, std::vector<std::uint8_t>> reports;
    auto ensure = [&](std::uint8_t id) -> std::vector<std::uint8_t>& {
        auto& r = reports[id];
        if (r.empty()) {
            const auto existing = getFeature(fd, id, desc.reportBufferBytes(ReportKind::feature, id));
            r = existing.empty() ? std::vector<std::uint8_t>(desc.reportBufferBytes(ReportKind::feature, id), 0) : existing;
            r[0] = id;
        }
        return r;
    };
    const unsigned base = desc.usesReportIds ? 8u : 0u;
    bool wroteInterval = false;

    for (const auto& f : desc.fields) {
        if (f.kind != ReportKind::feature || f.field.usagePage != kSensorPage) continue;
        if (f.field.usage == kReportInterval) {
            const auto low = std::min(f.field.physicalMin, f.field.physicalMax);
            const auto high = std::max(f.field.physicalMin, f.field.physicalMax);
            const double scale = std::pow(10.0, f.field.unitExponent);
            double targetSeconds = std::max(0.010, low * scale);
            if (targetSeconds > 0.020 || high * scale < 0.010) targetSeconds = low * scale;
            const long target = std::clamp<long>(std::lround(scale != 0 ? targetSeconds / scale : low), low, high);
            auto& r = ensure(f.field.reportId);
            packBits(r, base + f.bitOffset, f.field.bitSize, static_cast<std::uint64_t>(target));
            wroteInterval = true;
            Logger::instance().write(LogLevel::info, std::format(L"Encoded report interval {} (report {})", target, f.field.reportId));
        }
    }

    // Selectors: reporting=All Events, power=Full, transport=ACL. Each is an NAry
    // array field whose usage list contains the target; the value written is the
    // target's index in that list (logicalMin + index).
    const std::array<std::uint16_t, 3> selectors{kReportingAllEvents, kPowerFull, kTransportAcl};
    for (const auto want : selectors) {
        for (const auto& f : desc.fields) {
            if (f.kind != ReportKind::feature || f.field.usagePage != kSensorPage || !f.isArray) continue;
            const auto it = std::find(f.arrayUsages.begin(), f.arrayUsages.end(), want);
            if (it == f.arrayUsages.end()) continue;
            const auto index = static_cast<std::uint64_t>(std::distance(f.arrayUsages.begin(), it));
            auto& r = ensure(f.field.reportId);
            packBits(r, base + f.bitOffset, f.field.bitSize, static_cast<std::uint64_t>(f.field.logicalMin) + index);
            Logger::instance().write(LogLevel::info, std::format(L"Encoded selector 0x{:04X} = index {} (report {})", want, index, f.field.reportId));
            break;
        }
    }

    bool anySent = false;
    for (auto& [id, r] : reports) {
        if (setFeature(fd, r)) { anySent = true; Logger::instance().write(LogLevel::info, std::format(L"Feature report {} accepted", id)); }
        else Logger::instance().write(LogLevel::warning, std::format(L"SetFeature report {} failed: {}", id, toW(errnoText())));
    }
    if (!wroteInterval) Logger::instance().write(LogLevel::warning, L"Descriptor exposed no writable report interval");
    return anySent;
}

} // namespace

bool HidBackend::connect(const DeviceInfo& device, RawCallback raw, SampleCallback sample) {
    disconnect();
    auto ctx = std::make_unique<Context>();
    const std::string path = wideToUtf8(device.path);
    ctx->fd = Fd(::open(path.c_str(), O_RDWR));
    if (!ctx->fd.ok()) ctx->fd = Fd(::open(path.c_str(), O_RDONLY));
    if (!ctx->fd.ok()) { Logger::instance().write(LogLevel::error, std::format(L"Head tracker open failed: {}", toW(errnoText()))); return false; }

    const auto descBytes = readDescriptor(ctx->fd.value);
    if (descBytes.empty()) { Logger::instance().write(LogLevel::error, L"Could not read report descriptor"); return false; }
    ctx->desc = parseReportDescriptor(descBytes);
    ctx->usesReportIds = ctx->desc.usesReportIds;

    for (const auto& f : ctx->desc.fields)
        if (f.kind == ReportKind::input && f.field.usagePage == kSensorPage) ctx->inputFields.push_back(f);
    if (ctx->inputFields.empty()) { Logger::instance().write(LogLevel::error, L"Descriptor exposes no sensor-page input fields"); return false; }
    ctx->inputReportId = ctx->inputFields.front().field.reportId;
    // Clamp against a malformed descriptor declaring an absurd report size; real
    // HID input reports are at most a few KB. extractBits is bounds-checked, so
    // this only guards the allocation.
    ctx->inputBufferBytes = std::min<unsigned>(ctx->desc.reportBufferBytes(ReportKind::input, ctx->inputReportId), 8192u);

    if (!configureFeatures(ctx->fd.value, ctx->desc))
        Logger::instance().write(LogLevel::warning, L"No feature reports were accepted; the headset may not start streaming");

    ctx->raw = std::move(raw);
    ctx->sample = std::move(sample);
    context_ = std::move(ctx);
    running_ = true;
    readerStop_.reset();

    reader_ = std::thread([this]() {
        auto* c = context_.get();
        const unsigned base = c->usesReportIds ? 8u : 0u;
        std::vector<std::uint8_t> report(std::max<unsigned>(c->inputBufferBytes, 64));
        pollfd pfd{c->fd.value, POLLIN, 0};
        while (!readerStop_.stopRequested()) {
            const int ready = ::poll(&pfd, 1, 100);
            if (ready <= 0) continue;
            const ssize_t n = ::read(c->fd.value, report.data(), report.size());
            if (n <= 0) { if (errno == EAGAIN || errno == EINTR) continue; Logger::instance().write(LogLevel::error, std::format(L"HID read failed: {}", toW(errnoText()))); break; }
            std::vector<std::uint8_t> packet(report.begin(), report.begin() + n);
            if (c->raw) c->raw(packet);
            if (c->usesReportIds && !packet.empty() && packet[0] != c->inputReportId) continue;

            MotionSample s;
            s.receivedAt = std::chrono::steady_clock::now();
            bool gotRotation = false, gotGyro = false, gotAccel = false;
            Vec3 gyro{}, accel{};
            for (const auto& pf : c->inputFields) {
                const auto& field = pf.field;
                const unsigned abs = base + pf.bitOffset;
                const auto usage = field.usage;
                if (usage == kRotation || usage == kAngularVelocity || usage == kAngularVelocityVector || usage == kAccelerationVector) {
                    const auto packed = extractBits(packet, abs, static_cast<unsigned>(field.reportCount) * field.bitSize);
                    decodePackedDescriptorValuesInto(c->valueScratch, packed, field);
                    if (c->valueScratch.size() < 3) continue;
                    if (usage == kRotation) { s.rotationVector = {c->valueScratch[0], c->valueScratch[1], c->valueScratch[2]}; gotRotation = true; }
                    else if (usage == kAccelerationVector) { accel = {c->valueScratch[0], c->valueScratch[1], c->valueScratch[2]}; gotAccel = true; }
                    else { gyro = {c->valueScratch[0], c->valueScratch[1], c->valueScratch[2]}; gotGyro = true; }
                } else if (usage == kAccelerationX || usage == kAccelerationY || usage == kAccelerationZ) {
                    const auto packed = extractBits(packet, abs, field.bitSize);
                    decodePackedDescriptorValuesInto(c->valueScratch, packed, field);
                    if (!c->valueScratch.empty()) { accel[usage - kAccelerationX] = c->valueScratch[0]; gotAccel = true; }
                } else if (usage == kAngularVelocityX || usage == kAngularVelocityY || usage == kAngularVelocityZ) {
                    const auto packed = extractBits(packet, abs, field.bitSize);
                    decodePackedDescriptorValuesInto(c->valueScratch, packed, field);
                    if (!c->valueScratch.empty()) { gyro[usage - kAngularVelocityX] = c->valueScratch[0]; gotGyro = true; }
                } else if (usage == kResetCounter) {
                    s.resetCounter = static_cast<std::uint8_t>(extractRaw(packet, abs, field.bitSize));
                }
            }
            if (gotGyro) s.angularVelocity = gyro;
            if (gotAccel) s.acceleration = accel;
            ++c->rateCount;
            const auto elapsed = std::chrono::duration<double>(s.receivedAt - c->rateStart).count();
            if (elapsed >= 1.0) { c->rate = c->rateCount / elapsed; c->rateCount = 0; c->rateStart = s.receivedAt; }
            s.packetsPerSecond = c->rate;
            s.receiveLatencyMs = -1.0;
            if (gotRotation && c->sample) c->sample(std::move(s));
        }
        running_ = false;
    });
    Logger::instance().write(LogLevel::info, L"hidraw report reader started");
    return true;
}

void HidBackend::disconnect() {
    running_ = false;
    if (reader_.joinable()) { readerStop_.requestStop(); reader_.join(); }
    context_.reset();
}

std::wstring hexDump(const std::vector<std::uint8_t>& bytes) {
    std::wostringstream out;
    out << std::hex << std::uppercase;
    for (std::size_t i = 0; i < bytes.size(); ++i) {
        if (i) out << L' ';
        out << (bytes[i] < 16 ? L"0" : L"") << static_cast<unsigned>(bytes[i]);
    }
    return out.str();
}

} // namespace sony
