// hid_report_parser.cpp
// See hid_report_parser.hpp. Implements a HID report-descriptor item walker per
// the USB HID 1.11 spec, tracking global/local item state, Push/Pop, and a
// running per-report bit offset so each field knows where it lives in the report.
#include "sony_head_tracker/hid_report_parser.hpp"

#include "sony_head_tracker/hid_descriptor.hpp"  // hidSigned, decodeHidUnitExponent

#include <array>
#include <cstdint>
#include <vector>

namespace sony {

namespace {

// Item prefix: bits[1:0]=size code, bits[3:2]=type, bits[7:4]=tag.
enum class ItemType { main = 0, global = 1, local = 2, reserved = 3 };

unsigned sizeFromCode(std::uint8_t code) { return code == 3 ? 4u : code; }

// Little-endian fetch of `bytes` data bytes as an unsigned value.
std::uint32_t fetchUnsigned(std::span<const std::uint8_t> d, std::size_t at, unsigned bytes) {
    std::uint32_t v = 0;
    for (unsigned i = 0; i < bytes; ++i) v |= static_cast<std::uint32_t>(d[at + i]) << (8 * i);
    return v;
}

// Global item state; persists across main items and is saved/restored by Push/Pop.
struct GlobalState {
    std::uint16_t usagePage{};
    std::int32_t logicalMin{};
    std::int32_t logicalMax{};
    std::int32_t physicalMin{};
    std::int32_t physicalMax{};
    std::int8_t unitExponent{};
    std::uint32_t unit{};
    std::uint16_t reportSize{};   // bits per field
    std::uint16_t reportCount{};
    std::uint8_t reportId{};
};

// A local Usage entry; the high word, when present, overrides the global page
// (HID "extended" usage). Stored as the raw 32-bit item value + its byte width.
struct UsageEntry {
    std::uint32_t value{};
    bool extended{};   // 4-byte usage carrying its own page in the high word
};

std::pair<std::uint16_t, std::uint16_t> resolveUsage(const UsageEntry& e, std::uint16_t page) {
    if (e.extended) return {static_cast<std::uint16_t>(e.value >> 16), static_cast<std::uint16_t>(e.value & 0xFFFF)};
    return {page, static_cast<std::uint16_t>(e.value & 0xFFFF)};
}

DescriptorField makeField(const GlobalState& g, std::uint16_t page, std::uint16_t usage,
                          std::uint16_t count, bool feature) {
    DescriptorField f;
    f.usagePage = page;
    f.usage = usage;
    f.reportId = g.reportId;
    f.reportCount = count;
    f.bitSize = g.reportSize;
    f.logicalMin = g.logicalMin;
    f.logicalMax = g.logicalMax;
    f.physicalMin = g.physicalMin;
    f.physicalMax = g.physicalMax;
    f.unitExponent = g.unitExponent;
    f.unit = g.unit;
    f.feature = feature;
    return f;
}

} // namespace

unsigned ParsedDescriptor::reportBufferBytes(ReportKind kind, std::uint8_t reportId) const {
    const auto it = reportPayloadBytes.find({kind, reportId});
    const unsigned payload = it == reportPayloadBytes.end() ? 0u : it->second;
    return payload + (usesReportIds ? 1u : 0u);
}

ParsedDescriptor parseReportDescriptor(std::span<const std::uint8_t> d) {
    ParsedDescriptor out;

    GlobalState global;
    std::vector<GlobalState> globalStack;

    // Local item state (reset after every main item).
    std::vector<UsageEntry> usages;
    bool haveUsageMin = false, haveUsageMax = false;
    UsageEntry usageMin{}, usageMax{};

    // Running bit offset per (kind, reportId).
    std::map<std::pair<ReportKind, std::uint8_t>, unsigned> offset;
    int collectionDepth = 0;
    bool capturedTop = false;

    auto emitMainItem = [&](ReportKind kind, std::uint32_t flags) {
        const bool isConstant = flags & 0x01;
        const bool isVariable = flags & 0x02;
        const std::uint16_t count = global.reportCount;
        const std::uint16_t size = global.reportSize;
        const unsigned totalBits = static_cast<unsigned>(count) * size;
        const bool feature = kind == ReportKind::feature;
        const auto key = std::make_pair(kind, global.reportId);
        unsigned& base = offset[key];

        if (isConstant || (!isVariable && usages.empty() && !haveUsageMin)) {
            // Padding / constant, or an array with no usages; occupies space only.
            ParsedField pf;
            pf.field = makeField(global, global.usagePage, 0, count, feature);
            pf.bitOffset = base;
            pf.kind = kind;
            pf.isArray = !isVariable;
            pf.isConstant = true;
            out.fields.push_back(pf);
            base += totalBits;
        } else if (!isVariable) {
            // Array (NAry) field: `count` indices of `size` bits selecting from a
            // list of usages. Keep the descriptor's logical range as the value
            // range and record every selectable usage so selectors (Reporting
            // State, Power State, …) can be resolved by index later.
            ParsedField pf;
            pf.field = makeField(global, global.usagePage, 0, count, feature);
            if (haveUsageMin) {
                const auto lo = resolveUsage(usageMin, global.usagePage);
                const std::uint16_t hi = haveUsageMax ? resolveUsage(usageMax, global.usagePage).second : lo.second;
                pf.field.usagePage = lo.first;
                for (std::uint32_t u = lo.second; u <= hi; ++u) pf.arrayUsages.push_back(static_cast<std::uint16_t>(u));
            } else {
                for (const auto& e : usages) { const auto r = resolveUsage(e, global.usagePage); pf.field.usagePage = r.first; pf.arrayUsages.push_back(r.second); }
            }
            pf.field.usage = pf.arrayUsages.empty() ? 0 : pf.arrayUsages.front();
            pf.bitOffset = base;
            pf.kind = kind;
            pf.isArray = true;
            out.fields.push_back(pf);
            base += totalBits;
        } else {
            // Variable field(s): each of `count` instances gets a usage. Collapse
            // consecutive equal usages into one field (matching how Windows value
            // caps group a value array), so e.g. Usage(Rotation)+Count(3) becomes a
            // single field with reportCount 3.
            auto usageAt = [&](unsigned i) -> std::pair<std::uint16_t, std::uint16_t> {
                if (haveUsageMin) {
                    const auto base2 = resolveUsage(usageMin, global.usagePage);
                    std::uint16_t maxUsage = haveUsageMax ? resolveUsage(usageMax, global.usagePage).second : base2.second;
                    std::uint16_t u = static_cast<std::uint16_t>(base2.second + i);
                    if (u > maxUsage) u = maxUsage;
                    return {base2.first, u};
                }
                if (usages.empty()) return {global.usagePage, 0};
                const unsigned idx = i < usages.size() ? i : usages.size() - 1;  // extras reuse last
                return resolveUsage(usages[idx], global.usagePage);
            };
            unsigned i = 0;
            while (i < count) {
                const auto [page, usage] = usageAt(i);
                unsigned run = 1;
                while (i + run < count && usageAt(i + run) == std::make_pair(page, usage)) ++run;
                ParsedField pf;
                pf.field = makeField(global, page, usage, static_cast<std::uint16_t>(run), feature);
                pf.bitOffset = base + i * size;
                pf.kind = kind;
                pf.isArray = false;
                out.fields.push_back(pf);
                i += run;
            }
            base += totalBits;
        }

        auto& payload = out.reportPayloadBytes[key];
        payload = std::max(payload, (base + 7) / 8);
    };

    std::size_t i = 0;
    while (i < d.size()) {
        const std::uint8_t prefix = d[i];
        if (prefix == 0xFE) { // long item: 1 len byte + 1 tag byte + data; skip entirely
            if (i + 1 >= d.size()) break;
            const unsigned dataSize = d[i + 1];
            i += 3 + dataSize;
            continue;
        }
        const unsigned dataBytes = sizeFromCode(prefix & 0x03);
        const auto type = static_cast<ItemType>((prefix >> 2) & 0x03);
        const std::uint8_t tag = (prefix >> 4) & 0x0F;
        if (i + 1 + dataBytes > d.size()) break;  // truncated
        const std::size_t dataAt = i + 1;
        const std::uint32_t uval = dataBytes ? fetchUnsigned(d, dataAt, dataBytes) : 0;
        const std::int64_t sval = dataBytes ? hidSigned(uval, dataBytes) : 0;

        switch (type) {
        case ItemType::main:
            switch (tag) {
            case 0x8: emitMainItem(ReportKind::input, uval); break;   // Input
            case 0x9: emitMainItem(ReportKind::output, uval); break;  // Output
            case 0xB: emitMainItem(ReportKind::feature, uval); break; // Feature
            case 0xA:  // Collection
                if (!capturedTop && collectionDepth == 0) {
                    out.topUsagePage = global.usagePage;
                    out.topUsage = usages.empty() ? 0 : resolveUsage(usages.front(), global.usagePage).second;
                    capturedTop = true;
                }
                ++collectionDepth;
                break;
            case 0xC: if (collectionDepth > 0) --collectionDepth; break;  // End Collection
            default: break;
            }
            // Locals reset after every main item.
            usages.clear(); haveUsageMin = haveUsageMax = false;
            break;

        case ItemType::global:
            switch (tag) {
            case 0x0: global.usagePage = static_cast<std::uint16_t>(uval); break;
            case 0x1: global.logicalMin = static_cast<std::int32_t>(sval); break;
            case 0x2: global.logicalMax = static_cast<std::int32_t>(global.logicalMin < 0 ? sval : static_cast<std::int64_t>(uval)); break;
            case 0x3: global.physicalMin = static_cast<std::int32_t>(sval); break;
            case 0x4: global.physicalMax = static_cast<std::int32_t>(global.physicalMin < 0 ? sval : static_cast<std::int64_t>(uval)); break;
            case 0x5: global.unitExponent = decodeHidUnitExponent(uval); break;
            case 0x6: global.unit = uval; break;
            case 0x7: global.reportSize = static_cast<std::uint16_t>(uval); break;
            case 0x8: global.reportId = static_cast<std::uint8_t>(uval); out.usesReportIds = true; break;
            case 0x9: global.reportCount = static_cast<std::uint16_t>(uval); break;
            case 0xA: globalStack.push_back(global); break;  // Push
            case 0xB: if (!globalStack.empty()) { global = globalStack.back(); globalStack.pop_back(); } break;  // Pop
            default: break;
            }
            break;

        case ItemType::local:
            switch (tag) {
            case 0x0: usages.push_back({uval, dataBytes == 4}); break;   // Usage
            case 0x1: usageMin = {uval, dataBytes == 4}; haveUsageMin = true; break;  // Usage Minimum
            case 0x2: usageMax = {uval, dataBytes == 4}; haveUsageMax = true; break;  // Usage Maximum
            default: break;  // Designator/String/Delimiter: ignored
            }
            break;

        case ItemType::reserved: break;
        }
        i = dataAt + dataBytes;
    }

    return out;
}

} // namespace sony
