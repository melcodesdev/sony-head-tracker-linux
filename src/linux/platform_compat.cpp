// platform_compat.cpp
// UTF-8 <-> wide conversion. Windows uses the Win32 code-page API; Linux does a
// direct UTF-32<->UTF-8 transform (wchar_t is 32-bit there).
#include "sony_head_tracker/platform_compat.hpp"

#include <cstdint>

namespace sony {

#ifdef _WIN32

std::string wideToUtf8(std::wstring_view text) {
    if (text.empty()) return {};
    const int bytes = WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), nullptr, 0, nullptr, nullptr);
    std::string out(bytes > 0 ? static_cast<std::size_t>(bytes) : 0, '\0');
    if (bytes > 0) WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), out.data(), bytes, nullptr, nullptr);
    return out;
}

std::wstring utf8ToWide(std::string_view text) {
    if (text.empty()) return {};
    const int count = MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), nullptr, 0);
    std::wstring out(count > 0 ? static_cast<std::size_t>(count) : 0, L'\0');
    if (count > 0) MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), out.data(), count);
    return out;
}

#else

std::string wideToUtf8(std::wstring_view text) {
    std::string out;
    out.reserve(text.size());
    for (const wchar_t wc : text) {
        auto cp = static_cast<std::uint32_t>(wc);
        if (cp < 0x80) {
            out.push_back(static_cast<char>(cp));
        } else if (cp < 0x800) {
            out.push_back(static_cast<char>(0xC0 | (cp >> 6)));
            out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
        } else if (cp < 0x10000) {
            out.push_back(static_cast<char>(0xE0 | (cp >> 12)));
            out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
        } else if (cp <= 0x10FFFF) {
            out.push_back(static_cast<char>(0xF0 | (cp >> 18)));
            out.push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
        }
    }
    return out;
}

std::wstring utf8ToWide(std::string_view text) {
    std::wstring out;
    out.reserve(text.size());
    std::size_t i = 0;
    while (i < text.size()) {
        const auto c = static_cast<unsigned char>(text[i]);
        std::uint32_t cp = 0;
        int extra = 0;
        if (c < 0x80)        { cp = c; }
        else if ((c >> 5) == 0x6) { cp = c & 0x1F; extra = 1; }
        else if ((c >> 4) == 0xE) { cp = c & 0x0F; extra = 2; }
        else if ((c >> 3) == 0x1E){ cp = c & 0x07; extra = 3; }
        else { ++i; continue; } // invalid lead byte: skip
        ++i;
        for (int k = 0; k < extra && i < text.size(); ++k, ++i)
            cp = (cp << 6) | (static_cast<unsigned char>(text[i]) & 0x3F);
        out.push_back(static_cast<wchar_t>(cp));
    }
    return out;
}

#endif

} // namespace sony
