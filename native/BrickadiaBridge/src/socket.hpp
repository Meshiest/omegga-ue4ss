#pragma once
// The omegga transport: a Unix socket the omegga plugin connects to, carrying
// one message per line. Lines from a client are "<target>\t<payload>" and go
// to the Lua listener registered under <target>; lines from Lua go out as they
// are, to one client or to all of them.
//
// Sockets are read and written on a thread of their own, so a slow client never
// blocks the game; listeners are called from dispatch(), which the mod runs on
// the game thread every engine tick.
#include <cstdint>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

namespace omegga_bridge
{
    struct Inbound
    {
        uint32_t conn;
        std::string target;
        std::string payload;
    };

    class SocketServer
    {
      public:
        using Log = std::function<void(const std::string&)>;

        explicit SocketServer(Log log);
        ~SocketServer();

        /**
         * Listen at `path`, replacing a stale socket from an earlier run. The
         * socket is created owner-only (0600) and clients must run as the same
         * user, since whoever can connect can run code in the server.
         */
        auto start(const std::string& path) -> bool;
        auto stop() -> void;

        /** Queue a line for one client, or for every client when `conn` is 0. */
        auto send(uint32_t conn, std::string line) -> void;

        /** Messages received since the last call, oldest first. */
        auto take() -> std::vector<Inbound>;

      private:
        struct Client
        {
            int fd;
            std::string in;
            std::string out;
        };

        auto run() -> void;
        auto wake() -> void;
        auto read_client(uint32_t id, Client& client) -> bool;

        Log m_log;
        std::string m_path;
        int m_listen{-1};
        int m_wake{-1};
        bool m_running{false};
        std::thread m_thread;

        std::mutex m_mutex;
        std::unordered_map<uint32_t, Client> m_clients;
        std::vector<Inbound> m_inbox;
        uint32_t m_next_id{1};
    };
} // namespace omegga_bridge
