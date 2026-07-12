// platform_compat.hpp
// Thin cross-platform shims so the transport/CLI layer builds on both Windows
// (Winsock) and Linux (BSD sockets). Only the handful of primitives the port
// actually needs are covered here.
#pragma once

#include <string>
#include <string_view>

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <winsock2.h>
#include <ws2tcpip.h>
#else
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

namespace sony {
using SOCKET = int;
inline constexpr SOCKET kInvalidSocket = -1;
inline int closesocket(SOCKET s) { return ::close(s); }
} // namespace sony

// Match the Winsock spellings the shared code uses.
#ifndef INVALID_SOCKET
#define INVALID_SOCKET (::sony::kInvalidSocket)
#endif
#endif // _WIN32

namespace sony {

// UTF-8 <-> wide conversion. The codebase carries device names as std::wstring;
// the JSON transport needs UTF-8. On Windows wchar_t is UTF-16, on Linux UTF-32,
// so both directions are implemented per platform in platform_compat.cpp.
std::string wideToUtf8(std::wstring_view text);
std::wstring utf8ToWide(std::string_view text);

} // namespace sony
