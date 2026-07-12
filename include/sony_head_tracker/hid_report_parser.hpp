// hid_report_parser.hpp
// A self-contained HID *report descriptor* parser. On Windows this job was done
// by HidD_GetPreparsedData + HidP_GetValueCaps; Linux hidraw hands us only the
// raw descriptor bytes (via ioctl HIDIOCGRDESC), so we walk the item stream
// ourselves and additionally compute each field's bit offset within its report,
// the one piece of information the Windows parser never exposed.
//
// Pure and hardware-free: feed it descriptor bytes, get back a field map that the
// existing decode helpers in hid_descriptor.hpp consume unchanged.
#pragma once

#include "sony_head_tracker/device.hpp"

#include <cstdint>
#include <map>
#include <span>
#include <utility>
#include <vector>

namespace sony {

enum class ReportKind { input, output, feature };

// One decoded main-item field, with the descriptor metadata already folded into a
// DescriptorField plus the report-relative bit offset the decode path needs.
struct ParsedField {
    DescriptorField field;      // usage, reportId, reportCount, bitSize, ranges, unitExponent…
    unsigned bitOffset{};       // bits from the start of the report *payload* (after the report-ID byte)
    ReportKind kind{ReportKind::input};
    bool isArray{};             // Main item was Array rather than Variable
    bool isConstant{};          // padding / constant field
    // For array (NAry selector) fields: the ordered list of selectable usages.
    // The value written selects one by index (field.logicalMin + index). Used to
    // resolve HID-sensor selectors such as Reporting State / Power State.
    std::vector<std::uint16_t> arrayUsages;
};

struct ParsedDescriptor {
    bool usesReportIds{};
    std::uint16_t topUsagePage{};   // application collection usage page
    std::uint16_t topUsage{};       // application collection usage
    std::vector<ParsedField> fields;
    // Total payload length in bytes per (kind, reportId), excluding the report-ID
    // byte itself. Index a report buffer accordingly.
    std::map<std::pair<ReportKind, std::uint8_t>, unsigned> reportPayloadBytes;

    // Byte length to allocate for a report buffer of this kind+id, including the
    // leading report-ID byte when the descriptor uses report IDs.
    [[nodiscard]] unsigned reportBufferBytes(ReportKind kind, std::uint8_t reportId) const;
};

ParsedDescriptor parseReportDescriptor(std::span<const std::uint8_t> descriptor);

} // namespace sony
