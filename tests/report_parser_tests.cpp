// report_parser_tests.cpp
// Exercises the HID report-descriptor walker against a synthetic descriptor that
// mirrors the Android Head Tracker shape: a rotation vector (3x int16) plus a
// reset counter (uint8), all under report ID 1 on the sensor page.
#include "test_framework.hpp"

#include "sony_head_tracker/hid_report_parser.hpp"
#include "sony_head_tracker/hid_usages.hpp"

#include <cstdint>
#include <vector>

using namespace sony;

namespace {

// Item prefix helpers keep the descriptor readable.
constexpr std::uint8_t kUsagePage16 = 0x06, kUsage8 = 0x09, kUsage16 = 0x0A;
constexpr std::uint8_t kCollection = 0xA1, kEndCollection = 0xC0;
constexpr std::uint8_t kReportId8 = 0x85, kReportSize8 = 0x75, kReportCount8 = 0x95;
constexpr std::uint8_t kLogicalMin8 = 0x15, kLogicalMin16 = 0x16, kLogicalMax16 = 0x26;
constexpr std::uint8_t kInput = 0x81, kFeature = 0xB1;

std::vector<std::uint8_t> sampleDescriptor() {
    return {
        kUsagePage16, 0x20, 0x00,          // Usage Page (Sensor 0x20)
        kUsage8, 0xE1,                     // Usage (0xE1)
        kCollection, 0x01,                 // Collection (Application)
          kReportId8, 0x01,                // Report ID 1
          // Rotation vector: 3 x int16
          kUsage16, 0x44, 0x05,            // Usage (Rotation 0x0544)
          kLogicalMin16, 0x00, 0x80,       // Logical Min -32768
          kLogicalMax16, 0xFF, 0x7F,       // Logical Max 32767
          kReportSize8, 0x10,              // Report Size 16
          kReportCount8, 0x03,             // Report Count 3
          kInput, 0x02,                    // Input (Data,Var,Abs)
          // Reset counter: 1 x uint8
          kUsage16, 0x46, 0x05,            // Usage (ResetCounter 0x0546)
          kLogicalMin8, 0x00,              // Logical Min 0
          kLogicalMax16, 0xFF, 0x00,       // Logical Max 255
          kReportSize8, 0x08,              // Report Size 8
          kReportCount8, 0x01,             // Report Count 1
          kInput, 0x02,                    // Input (Data,Var,Abs)
          // Feature: report interval, 1 x uint16
          kUsage16, 0x0E, 0x03,            // Usage (Report Interval 0x030E)
          kReportSize8, 0x10,              // Report Size 16
          kReportCount8, 0x01,             // Report Count 1
          kFeature, 0x02,                  // Feature (Data,Var,Abs)
        kEndCollection,
    };
}

const ParsedField* findInput(const ParsedDescriptor& d, std::uint16_t usage) {
    for (const auto& f : d.fields)
        if (f.kind == ReportKind::input && f.field.usage == usage) return &f;
    return nullptr;
}

} // namespace

TEST(parser_captures_report_ids_and_top_usage) {
    const auto d = parseReportDescriptor(sampleDescriptor());
    CHECK(d.usesReportIds);
    CHECK(d.topUsagePage == kSensorPage);
    CHECK(d.topUsage == kOtherCustom);
}

TEST(parser_groups_rotation_vector_into_one_field) {
    const auto d = parseReportDescriptor(sampleDescriptor());
    const auto* rot = findInput(d, kRotation);
    CHECK(rot != nullptr);
    if (!rot) return;
    CHECK(rot->field.usagePage == kSensorPage);
    CHECK(rot->field.reportCount == 3);
    CHECK(rot->field.bitSize == 16);
    CHECK(rot->bitOffset == 0);
    CHECK(rot->field.logicalMin == -32768);
    CHECK(rot->field.logicalMax == 32767);
    CHECK(rot->field.reportId == 1);
}

TEST(parser_places_reset_counter_after_rotation) {
    const auto d = parseReportDescriptor(sampleDescriptor());
    const auto* reset = findInput(d, kResetCounter);
    CHECK(reset != nullptr);
    if (!reset) return;
    CHECK(reset->field.bitSize == 8);
    CHECK(reset->bitOffset == 48);   // 3 x 16 bits of rotation precede it
    CHECK(reset->field.reportCount == 1);
}

TEST(parser_computes_report_buffer_length) {
    const auto d = parseReportDescriptor(sampleDescriptor());
    // Input report 1 payload: 48 + 8 = 56 bits = 7 bytes, +1 report-ID byte.
    CHECK(d.reportBufferBytes(ReportKind::input, 1) == 8);
}

TEST(parser_finds_feature_interval_field) {
    const auto d = parseReportDescriptor(sampleDescriptor());
    const ParsedField* interval = nullptr;
    for (const auto& f : d.fields)
        if (f.kind == ReportKind::feature && f.field.usage == kReportInterval) interval = &f;
    CHECK(interval != nullptr);
    if (!interval) return;
    CHECK(interval->bitOffset == 0);      // its own feature report, starts at 0
    CHECK(interval->field.bitSize == 16);
    CHECK(d.reportBufferBytes(ReportKind::feature, 1) == 3);   // 16 bits + report-ID byte
}
