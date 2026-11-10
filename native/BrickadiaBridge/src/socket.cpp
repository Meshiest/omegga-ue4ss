#include "socket.hpp"

#include <cerrno>
#include <cstring>

#include <fcntl.h>
#include <poll.h>
#include <sys/eventfd.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

namespace omegga_bridge
{
    namespace
    {
        // a client that never reads must not grow the server's memory without bound
        constexpr size_t MAX_PENDING_OUT = 64 * 1024 * 1024;
        constexpr size_t MAX_LINE = 16 * 1024 * 1024;

        auto errno_text() -> std::string
        {
            return std::strerror(errno);
        }

        auto set_nonblocking(int fd) -> void
        {
            fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
        }

        auto same_user(int fd) -> bool
        {
            ucred cred{};
            socklen_t len = sizeof(cred);
            return getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cred, &len) == 0 && cred.uid == getuid();
        }
    } // namespace

    SocketServer::SocketServer(Log log) : m_log(std::move(log))
    {
    }

    SocketServer::~SocketServer()
    {
        stop();
    }

    auto SocketServer::start(const std::string& path) -> bool
    {
        sockaddr_un addr{};
        addr.sun_family = AF_UNIX;
        // bound under a temporary name, made owner-only, then renamed into place,
        // so there is no moment where another user could connect to it
        auto tmp = path + ".tmp-" + std::to_string(getpid());
        if (tmp.size() >= sizeof(addr.sun_path))
        {
            m_log("socket path too long (" + std::to_string(tmp.size()) + " bytes, limit " +
                  std::to_string(sizeof(addr.sun_path) - 1) + "): " + tmp);
            return false;
        }
        std::memcpy(addr.sun_path, tmp.c_str(), tmp.size() + 1);

        m_listen = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
        if (m_listen < 0)
        {
            m_log("socket: " + errno_text());
            return false;
        }
        unlink(tmp.c_str());
        if (bind(m_listen, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0 || chmod(tmp.c_str(), 0600) != 0 ||
            listen(m_listen, 8) != 0 || rename(tmp.c_str(), path.c_str()) != 0)
        {
            m_log("listen on " + path + ": " + errno_text());
            unlink(tmp.c_str());
            close(m_listen);
            m_listen = -1;
            return false;
        }
        set_nonblocking(m_listen);
        m_wake = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
        m_path = path;
        m_running = true;
        m_thread = std::thread([this] { run(); });
        return true;
    }

    auto SocketServer::stop() -> void
    {
        if (!m_running) return;
        {
            std::lock_guard lock{m_mutex};
            m_running = false;
        }
        wake();
        m_thread.join();
        for (auto& [id, client] : m_clients) close(client.fd);
        m_clients.clear();
        close(m_listen);
        close(m_wake);
        unlink(m_path.c_str());
    }

    auto SocketServer::wake() -> void
    {
        uint64_t one = 1;
        [[maybe_unused]] auto n = write(m_wake, &one, sizeof(one));
    }

    auto SocketServer::send(uint32_t conn, std::string line) -> void
    {
        line.push_back('\n');
        {
            std::lock_guard lock{m_mutex};
            for (auto& [id, client] : m_clients)
            {
                if (conn != 0 && id != conn) continue;
                if (client.out.size() + line.size() > MAX_PENDING_OUT) continue;
                client.out += line;
            }
        }
        wake();
    }

    auto SocketServer::take() -> std::vector<Inbound>
    {
        std::lock_guard lock{m_mutex};
        std::vector<Inbound> out;
        out.swap(m_inbox);
        return out;
    }

    // false when the client should be dropped
    auto SocketServer::read_client(uint32_t id, Client& client) -> bool
    {
        char buf[65536];
        for (;;)
        {
            auto n = recv(client.fd, buf, sizeof(buf), 0);
            if (n == 0) return false;
            if (n < 0) return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR;
            client.in.append(buf, static_cast<size_t>(n));
            size_t start = 0;
            for (auto nl = client.in.find('\n'); nl != std::string::npos; nl = client.in.find('\n', start))
            {
                std::string_view line{client.in.data() + start, nl - start};
                start = nl + 1;
                auto tab = line.find('\t');
                if (tab == std::string_view::npos) continue;
                m_inbox.push_back({id, std::string{line.substr(0, tab)}, std::string{line.substr(tab + 1)}});
            }
            client.in.erase(0, start);
            if (client.in.size() > MAX_LINE) return false;
        }
    }

    auto SocketServer::run() -> void
    {
        std::vector<pollfd> fds;
        std::vector<uint32_t> ids;
        for (;;)
        {
            fds.clear();
            ids.clear();
            fds.push_back({m_wake, POLLIN, 0});
            fds.push_back({m_listen, POLLIN, 0});
            {
                std::lock_guard lock{m_mutex};
                if (!m_running) return;
                for (auto& [id, client] : m_clients)
                {
                    fds.push_back({client.fd, static_cast<short>(POLLIN | (client.out.empty() ? 0 : POLLOUT)), 0});
                    ids.push_back(id);
                }
            }
            if (poll(fds.data(), fds.size(), -1) < 0 && errno != EINTR)
            {
                m_log("poll: " + errno_text());
                return;
            }
            if (fds[0].revents & POLLIN)
            {
                uint64_t drained;
                [[maybe_unused]] auto n = read(m_wake, &drained, sizeof(drained));
            }
            if (fds[1].revents & POLLIN)
            {
                for (int fd; (fd = accept4(m_listen, nullptr, nullptr, SOCK_NONBLOCK | SOCK_CLOEXEC)) >= 0;)
                {
                    if (!same_user(fd))
                    {
                        close(fd);
                        continue;
                    }
                    std::lock_guard lock{m_mutex};
                    auto id = m_next_id++;
                    m_clients.emplace(id, Client{fd, {}, {}});
                    // every listener hears about it, so mods can announce their handlers
                    m_inbox.push_back({id, "*", "{\"t\":\"connected\",\"conn\":" + std::to_string(id) + "}"});
                }
            }
            std::lock_guard lock{m_mutex};
            for (size_t i = 0; i < ids.size(); ++i)
            {
                auto it = m_clients.find(ids[i]);
                if (it == m_clients.end()) continue;
                auto& client = it->second;
                auto revents = fds[i + 2].revents;
                bool keep = !(revents & (POLLERR | POLLNVAL));
                if (keep && (revents & (POLLIN | POLLHUP))) keep = read_client(it->first, client);
                if (keep && !client.out.empty() && (revents & POLLOUT))
                {
                    auto n = ::send(client.fd, client.out.data(), client.out.size(), MSG_NOSIGNAL);
                    if (n > 0) client.out.erase(0, static_cast<size_t>(n));
                    else if (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) keep = false;
                }
                if (!keep)
                {
                    close(client.fd);
                    m_inbox.push_back({it->first, "*", "{\"t\":\"disconnected\",\"conn\":" + std::to_string(it->first) + "}"});
                    m_clients.erase(it);
                }
            }
        }
    }
} // namespace omegga_bridge
