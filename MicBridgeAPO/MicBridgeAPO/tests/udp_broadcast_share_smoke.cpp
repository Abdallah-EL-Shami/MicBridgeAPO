#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>

#include <cstdio>
#include <cstring>

static bool SetBoolOption(SOCKET s, int option, BOOL value) {
    return setsockopt(s, SOL_SOCKET, option,
                      reinterpret_cast<const char*>(&value), sizeof(value)) == 0;
}

static SOCKET CreateReceiver(u_short requestedPort, u_short& port, bool enableReuse) {
    SOCKET s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (s == INVALID_SOCKET) return INVALID_SOCKET;

    // ReaStream and MicBridge are independent receivers on UDP/58710.
    // The bridge sends local broadcast packets; both receivers must get a copy.
    if (enableReuse && !SetBoolOption(s, SO_REUSEADDR, TRUE)) {
        closesocket(s);
        return INVALID_SOCKET;
    }

    DWORD timeoutMs = 1500;
    if (setsockopt(s, SOL_SOCKET, SO_RCVTIMEO,
                   reinterpret_cast<const char*>(&timeoutMs), sizeof(timeoutMs)) != 0) {
        closesocket(s);
        return INVALID_SOCKET;
    }

    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons(requestedPort);
    if (bind(s, reinterpret_cast<const sockaddr*>(&addr), sizeof(addr)) != 0) {
        closesocket(s);
        return INVALID_SOCKET;
    }

    int len = sizeof(addr);
    if (getsockname(s, reinterpret_cast<sockaddr*>(&addr), &len) != 0) {
        closesocket(s);
        return INVALID_SOCKET;
    }
    port = ntohs(addr.sin_port);
    return s;
}

static bool ReceiveExpected(SOCKET s, const char* expected, size_t expectedSize) {
    char buffer[64]{};
    sockaddr_in from{};
    int fromLen = sizeof(from);
    const int n = recvfrom(s, buffer, sizeof(buffer), 0,
                           reinterpret_cast<sockaddr*>(&from), &fromLen);
    if (n == SOCKET_ERROR) {
        std::printf("recvfrom failed: %d\n", WSAGetLastError());
        return false;
    }
    if (from.sin_addr.s_addr != htonl(INADDR_LOOPBACK)) {
        std::printf("unexpected sender address\n");
        return false;
    }
    return static_cast<size_t>(n) == expectedSize &&
           std::memcmp(buffer, expected, expectedSize) == 0;
}

int main() {
    WSADATA wsa{};
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) {
        std::puts("FAIL: WSAStartup");
        return 1;
    }

    u_short port = 0, secondPort = 0;
    // Model ReaStream as the first receiver with default socket options;
    // MicBridge is the second receiver and explicitly requests SO_REUSEADDR.
    SOCKET first = CreateReceiver(0, port, false);
    SOCKET second = CreateReceiver(port, secondPort, true);
    SOCKET sender = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (first == INVALID_SOCKET || second == INVALID_SOCKET || sender == INVALID_SOCKET ||
        port == 0 || secondPort != port) {
        std::printf("FAIL: shared UDP bind (first=%d second=%d sender=%d ports=%u/%u error=%d)\n",
                    (int)first, (int)second, (int)sender, port, secondPort, WSAGetLastError());
        if (first != INVALID_SOCKET) closesocket(first);
        if (second != INVALID_SOCKET) closesocket(second);
        if (sender != INVALID_SOCKET) closesocket(sender);
        WSACleanup();
        return 1;
    }

    if (!SetBoolOption(sender, SO_BROADCAST, TRUE)) {
        std::printf("FAIL: SO_BROADCAST %d\n", WSAGetLastError());
        closesocket(first); closesocket(second); closesocket(sender); WSACleanup();
        return 1;
    }

    sockaddr_in destination{};
    destination.sin_family = AF_INET;
    destination.sin_port = htons(port);
    if (inet_pton(AF_INET, "127.255.255.255", &destination.sin_addr) != 1) {
        std::puts("FAIL: inet_pton");
        closesocket(first); closesocket(second); closesocket(sender); WSACleanup();
        return 1;
    }

    static const char payload[] = "MicBridge-ReaStream-broadcast-probe";
    const int sent = sendto(sender, payload, sizeof(payload), 0,
                            reinterpret_cast<const sockaddr*>(&destination), sizeof(destination));
    const bool firstReceived = sent == sizeof(payload) &&
        ReceiveExpected(first, payload, sizeof(payload));
    const bool secondReceived = sent == sizeof(payload) &&
        ReceiveExpected(second, payload, sizeof(payload));

    closesocket(first);
    closesocket(second);
    closesocket(sender);
    WSACleanup();

    if (!firstReceived || !secondReceived) {
        std::printf("FAIL: broadcast fan-out first=%d second=%d sent=%d\n",
                    firstReceived ? 1 : 0, secondReceived ? 1 : 0, sent);
        return 1;
    }
    std::puts("PASS: MicBridge SO_REUSEADDR receiver shared a port with a default UDP receiver and both got the broadcast");
    return 0;
}
