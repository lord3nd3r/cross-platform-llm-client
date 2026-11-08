#import "LlamaClusterWorker.h"
#include "ggml-backend.h"
#include "ggml-rpc.h"
#include <os/proc.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>
#include <mach/mach.h>
#include <atomic>
#include <chrono>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#define LOGI(...) NSLog(@"[LlamaCluster] " __VA_ARGS__)

static std::atomic<bool> g_running{false};
static std::mutex g_error_mutex;
static std::string g_error;  // why the server stopped, if it did
static std::mutex g_peer_mutex;
static std::string g_peer;

// The RPC server reports connections through ggml's logger ("RPC client
// connected: <ip>" / "RPC client disconnected", a PrivateLM patch).
static void clusterLog(ggml_log_level level, const char* text, void*) {
    if (!text) return;
    static const char kConnected[] = "RPC client connected: ";
    if (std::strncmp(text, kConnected, sizeof(kConnected) - 1) == 0) {
        std::string peer(text + sizeof(kConnected) - 1);
        while (!peer.empty() && isspace((unsigned char)peer.back())) peer.pop_back();
        // The pairing gate connects from loopback. Keep the address it recorded.
        if (peer == "127.0.0.1" || peer == "::1" || peer == "0.0.0.0") return;
        std::lock_guard<std::mutex> lock(g_peer_mutex);
        g_peer = peer;
    } else if (std::strncmp(text, "RPC client disconnected", 23) == 0) {
        std::lock_guard<std::mutex> lock(g_peer_mutex);
        if (g_peer == "127.0.0.1" || g_peer == "::1") g_peer.clear();
    }
    if (level >= GGML_LOG_LEVEL_INFO && level != GGML_LOG_LEVEL_CONT) {
        NSLog(@"[ggml] %s", text);
    }
}

// Keeps this device's Wi-Fi radio awake while a master is connected. Phones
// and iPads doze the radio between packets (tens to 200+ ms to wake), and
// every token makes a few round trips to each worker. A device that is
// transmitting stays out of power save, so send the master one tiny UDP
// datagram (discard port 9) every 20 ms: ~50 bytes/s. Measured iPad latency
// from the master: 28 ms average with 111 ms spikes when idle.
static void runRadioKeepAwake(const std::atomic<bool>& running, std::string (*peer)()) {
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) return;
    // Interactive-voice class: iOS's Wi-Fi driver keeps voice traffic out of
    // its deep power save (plain packets didn't: the iPad still dozed).
    int service = NET_SERVICE_TYPE_VO;
    setsockopt(fd, SOL_SOCKET, SO_NET_SERVICE_TYPE, &service, sizeof(service));
    const char byte = 0;
    while (running) {
        const std::string ip = peer();
        if (ip.empty()) {
            std::this_thread::sleep_for(std::chrono::milliseconds(200));
            continue;
        }
        sockaddr_in to = {};
        to.sin_family = AF_INET;
        to.sin_port = htons(9);
        if (inet_pton(AF_INET, ip.c_str(), &to.sin_addr) == 1) {
            sendto(fd, &byte, 1, 0, (const sockaddr*)&to, sizeof(to));
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }
    close(fd);
}

static std::string currentPeer() {
    std::lock_guard<std::mutex> lock(g_peer_mutex);
    return g_peer;
}

static bool pairingHelloMatches(const uint8_t* hello, const uint8_t* token) {
    uint8_t diff = 0;
    static const uint8_t magic[4] = {'P', 'L', 'M', '1'};
    for (int i = 0; i < 4; i++) diff |= hello[i] ^ magic[i];
    for (int i = 0; i < 32; i++) diff |= hello[4 + i] ^ token[i];
    return diff == 0;
}

static void copySocket(int from, int to) {
    char buf[16384];
    while (true) {
        const ssize_t n = recv(from, buf, sizeof(buf), 0);
        if (n <= 0) break;
        ssize_t off = 0;
        while (off < n) {
            const ssize_t w = send(to, buf + off, (size_t)(n - off), 0);
            if (w <= 0) return;
            off += w;
        }
    }
}

static void servePairedClient(int client, int internalPort, std::vector<uint8_t> token) {
    timeval tv{};
    tv.tv_sec = 5;
    setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    uint8_t hello[36];
    size_t got = 0;
    while (got < sizeof(hello)) {
        const ssize_t n = recv(client, hello + got, sizeof(hello) - got, 0);
        if (n <= 0) {
            close(client);
            return;
        }
        got += (size_t)n;
    }
    if (!pairingHelloMatches(hello, token.data())) {
        close(client);
        return;
    }
    // The deadline is for authentication only. Model loading, computation,
    // and time between requests can all leave an authenticated socket idle.
    tv.tv_sec = 0;
    setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    const int rpc = socket(AF_INET, SOCK_STREAM, 0);
    if (rpc < 0) {
        close(client);
        return;
    }
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)internalPort);
    inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr);
    if (connect(rpc, (sockaddr*)&addr, sizeof(addr)) != 0) {
        close(rpc);
        close(client);
        return;
    }
    const char ack[2] = {'O', 'K'};
    if (send(client, ack, 2, 0) != 2) {
        close(rpc);
        close(client);
        return;
    }
    sockaddr_in peer{};
    socklen_t peerLen = sizeof(peer);
    if (getpeername(client, (sockaddr*)&peer, &peerLen) == 0) {
        char ip[INET_ADDRSTRLEN] = {};
        inet_ntop(AF_INET, &peer.sin_addr, ip, sizeof(ip));
        std::lock_guard<std::mutex> lock(g_peer_mutex);
        g_peer = ip;
    }
    std::thread([client, rpc] { copySocket(client, rpc); shutdown(rpc, SHUT_WR); }).detach();
    copySocket(rpc, client);
    close(rpc);
    close(client);
    std::lock_guard<std::mutex> lock(g_peer_mutex);
    g_peer.clear();
}

static void runPairingGate(int publicPort, int internalPort, std::vector<uint8_t> token) {
    const int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return;
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)publicPort);
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(fd, (sockaddr*)&addr, sizeof(addr)) != 0 || listen(fd, 16) != 0) {
        close(fd);
        return;
    }
    while (true) {
        const int client = accept(fd, nullptr, nullptr);
        if (client < 0) continue;
        std::thread([client, internalPort, token] {
            servePairedClient(client, internalPort, token);
        }).detach();
    }
}

@implementation LlamaClusterWorker

+ (nullable NSString*)startOnPort:(int)port
                          threads:(int)threads
                         cacheDir:(NSString*)cacheDir
                            token:(NSData*)token {
    if (g_running) return nil;
    if (token.length != 32) return @"Pairing secret is missing";
    ggml_log_set(clusterLog, nullptr);

    // The GPU (Metal) does the work: on Apple silicon it reads memory far
    // faster than the CPU cores do. CPU only if there's no Metal device.
    ggml_backend_dev_t dev = ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_GPU);
    if (!dev) dev = ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_IGPU);
    if (!dev) dev = ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_CPU);
    if (!dev) return @"No compute device found";

    [[NSFileManager defaultManager] createDirectoryAtPath:cacheDir
                              withIntermediateDirectories:YES attributes:nil error:nil];
    const int internalPort = port + 1;
    std::vector<uint8_t> tokenBytes(32);
    [token getBytes:tokenBytes.data() length:32];
    std::thread([port, internalPort, tokenBytes] {
        runPairingGate(port, internalPort, tokenBytes);
    }).detach();
    std::string endpoint = "127.0.0.1:" + std::to_string(internalPort);
    std::string cache = cacheDir.UTF8String;
    const size_t n_threads = (size_t)std::max(1, threads);
    LOGI(@"Worker on %s using %s, cache %s", endpoint.c_str(), ggml_backend_dev_name(dev), cache.c_str());

    g_running = true;
    std::thread([] { runRadioKeepAwake(g_running, currentPeer); }).detach();
    std::thread([endpoint, cache, n_threads, dev]() mutable {
        ggml_backend_dev_t devices[] = {dev};
        ggml_backend_rpc_start_server(endpoint.c_str(), cache.c_str(), n_threads, 1, devices);
        // Only returns if the server couldn't start (e.g. port in use).
        LOGI(@"Worker server exited");
        {
            std::lock_guard<std::mutex> lock(g_error_mutex);
            g_error = "Worker stopped: couldn't listen on " + endpoint + " (port in use?)";
        }
        g_running = false;
    }).detach();
    return nil;
}

+ (BOOL)isRunning {
    return g_running;
}

+ (nullable NSString*)lastError {
    std::lock_guard<std::mutex> lock(g_error_mutex);
    return g_error.empty() ? nil : [NSString stringWithUTF8String:g_error.c_str()];
}

+ (nullable NSString*)connectedPeer {
    std::lock_guard<std::mutex> lock(g_peer_mutex);
    return g_peer.empty() ? nil : [NSString stringWithUTF8String:g_peer.c_str()];
}

+ (long)availableMemoryMb {
    return (long)(os_proc_available_memory() / (1024 * 1024));
}

+ (long)footprintMb {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) {
        return 0;
    }
    return (long)(info.phys_footprint / (1024 * 1024));
}

+ (double)memoryBandwidthWithThreads:(int)threads {
    const int n = std::max(1, threads);
    const size_t per_thread = (64u << 20) / sizeof(uint64_t) / n;  // 64 MB total
    std::vector<uint64_t> data(per_thread * n, 1);
    std::vector<uint64_t> sums(n, 0);
    const int passes = 4;
    auto run = [&](int t) {
        const uint64_t* p = data.data() + per_thread * t;
        uint64_t a = 0, b = 0, c = 0, d = 0;
        for (int pass = 0; pass < passes; pass++) {
            for (size_t i = 0; i + 4 <= per_thread; i += 4) {
                a += p[i]; b += p[i + 1]; c += p[i + 2]; d += p[i + 3];
            }
        }
        sums[t] = a + b + c + d;
    };
    run(0);  // warm up: page in the buffer
    const auto start = std::chrono::steady_clock::now();
    std::vector<std::thread> pool;
    for (int t = 0; t < n; t++) pool.emplace_back(run, t);
    for (auto& th : pool) th.join();
    const double secs = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
    const double gbps = secs > 0 ? (double)data.size() * sizeof(uint64_t) * passes / secs / 1e9 : 0;
    LOGI(@"Memory bandwidth: %.1f GB/s (%d threads, check %llu)", gbps, n, (unsigned long long)sums[0]);
    return gbps;
}

@end
