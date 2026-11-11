// BrickadiaBridge native half: registers raw-call helpers into every Lua mod's
// states (UE4SS calls on_lua_start for each Lua mod that starts), and runs the
// socket omegga talks to (socket.hpp).
//
// Brickadia's scripting UFunctions pass opaque structs (BRLuauBuilder,
// BrickHandle, WireValue...) that have no reflected fields, so UE4SS's Lua
// marshalling can't carry them. These helpers call a UFunction with a raw
// parameter buffer instead; Lua builds and reads the bytes with string.pack.
//
//   __fn_layout(path)              -> { size = n, <Param> = { offset, size }, ... }
//   __raw_call(target, path, bytes) -> bytes   (ProcessEvent on a zeroed ParmsSize
//                                              buffer prefilled from `bytes`)
//   __addr(object)                 -> integer address
//   __obj(address)                 -> UObject (nil for 0)
//   __fname(text)                  -> integer FName (ComparisonIndex | Number << 32)
//   __peek(address, length)        -> bytes (debug; unmapped addresses crash)
//   __alloc(bytes)                 -> address of a copy of `bytes`, for params that
//                                     point at memory (TArray data); __free it after
//   __free(address)
//   __game_alloc(bytes)            -> address of a copy of `bytes` in the game's own heap (GMalloc),
//                                     for memory the engine takes over and frees later
//                                     (FString data, shared objects); never __free it
//   __game_free(address)           frees __game_alloc memory, or a buffer an engine
//                                     container owned, with the game's operator delete[]
//   __poke(address, bytes)         writes bytes at an address (unmapped addresses crash)
//   __bridge_listen(name, fn)      fn(conn, payload) gets every line sent to `name`
//                                  (and "*" notices: connected/disconnected), on
//                                  the game thread, at the start of the next tick
//   __bridge_send(conn, line)      send a line to client `conn`, or to all with 0
//   __on_tick(fn)                  fn(deltaSeconds) at the start of every engine tick
//   __component_data(handle)       -> address of a component's data struct, from its
//                                     8-byte BCSComponentHandle, or nil if it is stale
//   __on_call(path, fn)            fn(self, params) before every ProcessEvent of the
//                                  UFunction `path`; params are its raw parameter
//                                  bytes (opaque structs included, unlike RegisterHook)
//
// The buffer is never destructed: params holding heap memory (FString, TArray)
// leak, which is acceptable for a test bridge and avoids double frees when Lua
// copied a pointer out of it. Callers must be on the game thread.
#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

#include <LuaMadeSimple/LuaMadeSimple.hpp>
#include <LuaType/LuaUObject.hpp>
#include <Mod/CppUserModBase.hpp>
#include <Unreal/Core/HAL/UnrealMemory.hpp>
#include <Unreal/CoreUObject/UObject/Class.hpp>
#include <Unreal/FProperty.hpp>
#include <Unreal/UFunction.hpp>
#include <Unreal/UObject.hpp>
#include <Unreal/UObjectGlobals.hpp>
#include <Unreal/Hooks/Hooks.hpp>
#include <DynamicOutput/DynamicOutput.hpp>

#include "socket.hpp"

using namespace RC;
using namespace RC::Unreal;

namespace
{
    auto find_function(std::string_view path) -> UFunction*
    {
        static std::unordered_map<std::string, UFunction*> cache;
        std::string key{path};
        if (auto it = cache.find(key); it != cache.end()) { return it->second; }
        auto* fn = UObjectGlobals::StaticFindObject<UFunction*>(nullptr, nullptr, ensure_str(key));
        cache.emplace(std::move(key), fn);
        return fn;
    }

    // LuaMadeSimple getters pop their argument, so arguments are always read at index 1
    auto lua_fn_layout(const LuaMadeSimple::Lua& lua) -> int
    {
        auto* fn = find_function(lua.get_string());
        if (!fn)
        {
            lua.set_nil();
            return 1;
        }
        auto table = lua.prepare_new_table();
        table.add_pair("size", static_cast<int64_t>(fn->GetParmsSize()));
        for (FProperty* prop : fn->ForEachProperty())
        {
            auto name = to_utf8_string(prop->GetName());
            lua_State* L = lua.get_lua_state();
            lua_pushstring(L, name.c_str());
            lua_createtable(L, 0, 2);
            lua_pushinteger(L, prop->GetOffset_Internal());
            lua_setfield(L, -2, "offset");
            lua_pushinteger(L, static_cast<lua_Integer>(prop->GetElementSize()) * prop->GetArrayDim());
            lua_setfield(L, -2, "size");
            lua_rawset(L, -3);
        }
        table.make_local();
        return 1;
    }

    // LuaMadeSimple's get_string measures with strlen, so a parameter buffer would
    // be cut at its first zero byte. Read the remaining argument with its length.
    auto take_bytes(const LuaMadeSimple::Lua& lua) -> std::string
    {
        lua_State* L = lua.get_lua_state();
        size_t len{};
        const char* data = lua_tolstring(L, 1, &len);
        std::string out{data ? data : "", data ? len : 0};
        lua_remove(L, 1);
        return out;
    }

    auto lua_peek(const LuaMadeSimple::Lua& lua) -> int
    {
        // Debug read of engine memory the caller already holds a pointer to (from a
        // param buffer); an address that isn't mapped crashes the server.
        auto address = static_cast<uintptr_t>(lua.get_integer());
        auto length = static_cast<size_t>(lua.get_integer());
        lua.set_string(reinterpret_cast<const uint8_t*>(address), length);
        return 1;
    }

    // From malloc (this mod's allocator, not the engine's), so only for memory the
    // engine reads during a call and never frees or grows: a TArray passed by const
    // reference, say. The caller frees it.
    auto lua_alloc(const LuaMadeSimple::Lua& lua) -> int
    {
        auto bytes = take_bytes(lua);
        void* mem = std::malloc(std::max<size_t>(bytes.size(), 1));
        std::memcpy(mem, bytes.data(), bytes.size());
        lua.set_integer(static_cast<int64_t>(reinterpret_cast<uintptr_t>(mem)));
        return 1;
    }

    auto lua_free(const LuaMadeSimple::Lua& lua) -> int
    {
        std::free(reinterpret_cast<void*>(static_cast<uintptr_t>(lua.get_integer())));
        return 0;
    }

    // Memory the engine will own (FString data, shared objects, container buffers)
    // must come from its allocator, GMalloc, through UE4SS's FMemory. Looking up
    // the game's operator new[] with dlsym is not enough: RTLD_DEFAULT finds the
    // C++ runtime's copy first, which is plain malloc, and the engine's free
    // aborts on such a block.
    auto lua_game_alloc(const LuaMadeSimple::Lua& lua) -> int
    {
        auto bytes = take_bytes(lua);
        void* mem = FMemory::Malloc(std::max<size_t>(bytes.size(), 1));
        if (!mem) lua.throw_error("__game_alloc: GMalloc returned null");
        std::memcpy(mem, bytes.data(), bytes.size());
        lua.set_integer(static_cast<int64_t>(reinterpret_cast<uintptr_t>(mem)));
        return 1;
    }

    // Frees memory from __game_alloc, or a buffer an engine container owned (a
    // TArray's data being replaced), through GMalloc.
    auto lua_game_free(const LuaMadeSimple::Lua& lua) -> int
    {
        auto address = static_cast<uintptr_t>(lua.get_integer());
        if (address) FMemory::Free(reinterpret_cast<void*>(address));
        return 0;
    }

    // Writes bytes over engine memory the caller already holds a pointer to, for
    // structs with no reflected fields (BRDynamicArray). Like __peek, an address
    // that isn't mapped crashes the server.
    auto lua_poke(const LuaMadeSimple::Lua& lua) -> int
    {
        auto address = static_cast<uintptr_t>(lua.get_integer());
        auto bytes = take_bytes(lua);
        std::memcpy(reinterpret_cast<void*>(address), bytes.data(), bytes.size());
        return 0;
    }

    auto lua_raw_call(const LuaMadeSimple::Lua& lua) -> int
    {
        UObject* target = lua.get_userdata<LuaType::UObject>().get_remote_cpp_object();
        auto* fn = find_function(lua.get_string());
        auto bytes = take_bytes(lua);
        if (!target || !fn)
        {
            lua.throw_error("__raw_call: invalid target or function");
        }
        std::vector<uint8_t> parms(fn->GetParmsSize(), 0);
        std::memcpy(parms.data(), bytes.data(), std::min(bytes.size(), parms.size()));
        target->ProcessEvent(fn, parms.data());
        lua.set_string(parms.data(), parms.size());
        return 1;
    }

    auto lua_addr(const LuaMadeSimple::Lua& lua) -> int
    {
        UObject* obj = lua.get_userdata<LuaType::UObject>().get_remote_cpp_object();
        lua.set_integer(static_cast<int64_t>(reinterpret_cast<uintptr_t>(obj)));
        return 1;
    }

    auto lua_obj(const LuaMadeSimple::Lua& lua) -> int
    {
        // The address came out of a parameter buffer that the engine filled with a
        // UObject*; Lua has no pointer type, so it travelled as an integer.
        auto* obj = reinterpret_cast<UObject*>(static_cast<uintptr_t>(lua.get_integer()));
        LuaType::auto_construct_object(lua, obj);
        return 1;
    }

    auto lua_fname(const LuaMadeSimple::Lua& lua) -> int
    {
        auto text = ensure_str(std::string{lua.get_string()});
        FName name{text.c_str(), FNAME_Add};
        // ComparisonIndex in the low 32 bits, Number in the high, as FName lays out
        lua.set_integer(static_cast<int64_t>(name.GetComparisonIndex().ToUnstableInt()) |
                        (static_cast<int64_t>(name.GetNumber()) << 32));
        return 1;
    }


    std::unique_ptr<omegga_bridge::SocketServer> g_server;

    // A listener's function lives in a Lua thread made for it, the way UE4SS keeps
    // RegisterHook callbacks, so calling it from the game thread doesn't touch the
    // stack of whichever state registered it.
    struct Listener
    {
        lua_State* thread;
        lua_State* main;
        int thread_ref;
        int fn_ref;
        LuaMadeSimple::Lua* lua;
    };
    std::mutex g_listeners_mutex;
    std::map<std::string, Listener> g_listeners;

    auto main_thread(lua_State* L) -> lua_State*
    {
        lua_rawgeti(L, LUA_REGISTRYINDEX, LUA_RIDX_MAINTHREAD);
        auto* main = lua_tothread(L, -1);
        lua_pop(L, 1);
        return main;
    }

    auto release(const Listener& l) -> void
    {
        luaL_unref(l.main, LUA_REGISTRYINDEX, l.fn_ref);
        luaL_unref(l.main, LUA_REGISTRYINDEX, l.thread_ref);
    }

    // the function at stack index `fn_index`, moved into a thread of its own
    auto make_listener(const LuaMadeSimple::Lua& lua, int fn_index) -> Listener
    {
        lua_State* L = lua.get_lua_state();
        // LuaMadeSimple's new_thread, not lua_newthread: every registered C function
        // (UE4SS's API, __bridge_send) looks its caller up in LuaMadeSimple's table
        // of states and errors for a thread it didn't make
        auto& thread_lua = lua.new_thread();
        lua_State* thread = thread_lua.get_lua_state();
        int thread_ref = luaL_ref(L, LUA_REGISTRYINDEX);
        lua_pushvalue(L, fn_index);
        lua_xmove(L, thread, 1);
        int fn_ref = luaL_ref(thread, LUA_REGISTRYINDEX);
        return {thread, main_thread(L), thread_ref, fn_ref, &thread_lua};
    }

    auto lua_bridge_listen(const LuaMadeSimple::Lua& lua) -> int
    {
        lua_State* L = lua.get_lua_state();
        std::string name = luaL_checkstring(L, 1);
        luaL_checktype(L, 2, LUA_TFUNCTION);
        Listener listener = make_listener(lua, 2);
        std::lock_guard lock{g_listeners_mutex};
        if (auto it = g_listeners.find(name); it != g_listeners.end())
        {
            release(it->second);
            it->second = listener;
        }
        else
        {
            g_listeners.emplace(std::move(name), listener);
        }
        lua_settop(L, 0);
        return 0;
    }

    auto lua_bridge_send(const LuaMadeSimple::Lua& lua) -> int
    {
        lua_State* L = lua.get_lua_state();
        auto conn = static_cast<uint32_t>(luaL_checkinteger(L, 1));
        size_t len{};
        const char* data = luaL_checklstring(L, 2, &len);
        if (g_server) g_server->send(conn, std::string{data, len});
        lua_settop(L, 0);
        return 0;
    }

    auto call_listener(const std::string& name, const Listener& l, uint32_t conn, const std::string& payload) -> void
    {
        lua_State* T = l.thread;
        lua_settop(T, 0);
        lua_rawgeti(T, LUA_REGISTRYINDEX, l.fn_ref);
        lua_pushinteger(T, conn);
        lua_pushlstring(T, payload.data(), payload.size());
        if (lua_pcall(T, 2, 0, 0) != LUA_OK)
        {
            Output::send<LogLevel::Error>(STR("[BrickadiaBridge] listener {}: {}\n"), ensure_str(name), ensure_str(std::string{lua_tostring(T, -1)}));
        }
        lua_settop(T, 0);
    }

    std::mutex g_tick_mutex;
    std::vector<Listener> g_tick_listeners;

    auto lua_on_tick(const LuaMadeSimple::Lua& lua) -> int
    {
        lua_State* L = lua.get_lua_state();
        luaL_checktype(L, 1, LUA_TFUNCTION);
        Listener listener = make_listener(lua, 1);
        std::lock_guard lock{g_tick_mutex};
        g_tick_listeners.push_back(listener);
        lua_settop(L, 0);
        return 0;
    }

    auto run_tick_listeners(float delta) -> void
    {
        std::vector<Listener> listeners;
        {
            std::lock_guard lock{g_tick_mutex};
            listeners = g_tick_listeners;
        }
        for (auto& l : listeners)
        {
            lua_State* T = l.thread;
            lua_settop(T, 0);
            lua_rawgeti(T, LUA_REGISTRYINDEX, l.fn_ref);
            lua_pushnumber(T, delta);
            if (lua_pcall(T, 1, 0, 0) != LUA_OK)
            {
                Output::send<LogLevel::Error>(STR("[BrickadiaBridge] __on_tick: {}\n"), ensure_str(std::string{lua_tostring(T, -1)}));
            }
            lua_settop(T, 0);
        }
    }

    // Component storage. A BCSComponentHandle is { uint32 index, uint32 generation };
    // the data lives at base + index * 16 in 64 KB pages, each page's trailer holding
    // its element stride (+0xFFF0) and a reciprocal for dividing by it (+0xFFF8), and
    // a bitmap at storage + 0xC0 marks pages in use. The storage global is found in
    // the code of BRLuauComponentLibrary:GetType, which reads it with
    //   lea rsi, [rip + storage]; mov rdx, [rsi + rdx*8 + 0xC0]
    // so no build-specific address is baked in.
    auto component_storage() -> uint8_t*
    {
        static uint8_t* storage = [] {
            auto* fn = find_function("/Script/Brickadia.BRLuauComponentLibrary:GetType");
            if (!fn) return static_cast<uint8_t*>(nullptr);
            auto* code = reinterpret_cast<const uint8_t*>(fn->GetFunc());
            static constexpr uint8_t load[] = {0x48, 0x8b, 0x94, 0xd6, 0xc0, 0x00, 0x00, 0x00};
            for (size_t i = 0; code && i < 0x400; ++i)
            {
                if (code[i] == 0x48 && code[i + 1] == 0x8d && code[i + 2] == 0x35 && std::memcmp(code + i + 7, load, sizeof(load)) == 0)
                {
                    int32_t disp;
                    std::memcpy(&disp, code + i + 3, 4);
                    return const_cast<uint8_t*>(code + i + 7 + disp);
                }
            }
            return static_cast<uint8_t*>(nullptr);
        }();
        return storage;
    }

    auto component_data(uint32_t index, uint32_t generation) -> uint8_t*
    {
        auto* storage = component_storage();
        if (!storage || !(generation & 1)) return nullptr;
        uint64_t pages;
        std::memcpy(&pages, storage + 0xC0 + (index >> 18) * 8, 8);
        if (!((pages >> ((index >> 12) & 63)) & 1)) return nullptr;
        uint8_t* base;
        std::memcpy(&base, storage, 8);
        uint64_t offset = static_cast<uint64_t>(index) << 4;
        uint32_t slot_generation;
        std::memcpy(&slot_generation, base + offset, 4);
        if (slot_generation != generation) return nullptr;
        uint8_t* page = base + (offset & 0xFFFFF0000ull);
        uint32_t in_page = static_cast<uint32_t>(offset & 0xFFFF);
        uint16_t stride;
        uint32_t reciprocal;
        std::memcpy(&stride, page + 0xFFF0, 2);
        std::memcpy(&reciprocal, page + 0xFFF8, 4);
        uint32_t element = static_cast<uint32_t>((static_cast<uint64_t>(reciprocal) * in_page) >> 32);
        if (element * stride != in_page) return nullptr;
        return base + offset;
    }

    auto lua_component_data(const LuaMadeSimple::Lua& lua) -> int
    {
        auto handle = take_bytes(lua);
        if (handle.size() < 8) lua.throw_error("__component_data: needs an 8-byte BCSComponentHandle");
        uint32_t index, generation;
        std::memcpy(&index, handle.data(), 4);
        std::memcpy(&generation, handle.data() + 4, 4);
        auto* data = component_data(index, generation);
        if (data) lua.set_integer(static_cast<int64_t>(reinterpret_cast<uintptr_t>(data)));
        else lua.set_nil();
        return 1;
    }

    // game thread, every engine tick
    auto dispatch() -> void
    {
        if (!g_server) return;
        for (auto& message : g_server->take())
        {
            std::vector<std::pair<std::string, Listener>> targets;
            {
                // copied out: a listener may register or replace listeners itself
                std::lock_guard lock{g_listeners_mutex};
                if (message.target == "*")
                {
                    targets.assign(g_listeners.begin(), g_listeners.end());
                }
                else if (auto it = g_listeners.find(message.target); it != g_listeners.end())
                {
                    targets.emplace_back(*it);
                }
            }
            if (targets.empty() && message.target != "*")
            {
                // the payload is the client's JSON line, so it embeds as-is
                g_server->send(message.conn, "{\"t\":\"undeliverable\",\"target\":\"" + message.target + "\",\"message\":" + message.payload + "}");
            }
            for (auto& [name, listener] : targets) call_listener(name, listener, message.conn, message.payload);
        }
    }

    std::mutex g_call_hooks_mutex;
    std::unordered_map<UFunction*, std::vector<Listener>> g_call_hooks;
    bool g_call_hook_installed = false;
    // a hook whose body calls the hooked function would otherwise recurse forever
    thread_local bool t_in_call_hook = false;

    auto on_process_event(UObject* context, UFunction* function, void* parms) -> void
    {
        if (t_in_call_hook) return;
        std::vector<Listener> listeners;
        {
            std::lock_guard lock{g_call_hooks_mutex};
            if (g_call_hooks.empty()) return;
            auto it = g_call_hooks.find(function);
            if (it == g_call_hooks.end()) return;
            listeners = it->second;
        }
        t_in_call_hook = true;
        auto size = static_cast<size_t>(function->GetParmsSize());
        for (auto& l : listeners)
        {
            lua_State* T = l.thread;
            lua_settop(T, 0);
            lua_rawgeti(T, LUA_REGISTRYINDEX, l.fn_ref);
            LuaType::auto_construct_object(*l.lua, context);
            lua_pushlstring(T, parms ? static_cast<const char*>(parms) : "", parms ? size : 0);
            if (lua_pcall(T, 2, 0, 0) != LUA_OK)
            {
                Output::send<LogLevel::Error>(STR("[BrickadiaBridge] __on_call {}: {}\n"), function->GetFullName(), ensure_str(std::string{lua_tostring(T, -1)}));
            }
            lua_settop(T, 0);
        }
        t_in_call_hook = false;
    }

    auto lua_on_call(const LuaMadeSimple::Lua& lua) -> int
    {
        lua_State* L = lua.get_lua_state();
        std::string path = luaL_checkstring(L, 1);
        luaL_checktype(L, 2, LUA_TFUNCTION);
        auto* fn = find_function(path);
        if (!fn) luaL_error(L, "__on_call: no UFunction %s", path.c_str());
        Listener listener = make_listener(lua, 2);
        {
            std::lock_guard lock{g_call_hooks_mutex};
            g_call_hooks[fn].push_back(listener);
            if (!g_call_hook_installed)
            {
                g_call_hook_installed = true;
                Hook::RegisterProcessEventPreCallback(
                        [](auto&, UObject* context, UFunction* function, void* parms) { on_process_event(context, function, parms); },
                        {false, true, STR("BrickadiaBridge"), STR("OnCall")});
            }
        }
        lua_settop(L, 0);
        return 0;
    }

    auto register_all(const LuaMadeSimple::Lua& lua) -> void
    {
        lua.register_function("__on_call", lua_on_call);
        lua.register_function("__on_tick", lua_on_tick);
        lua.register_function("__component_data", lua_component_data);
        lua.register_function("__bridge_listen", lua_bridge_listen);
        lua.register_function("__bridge_send", lua_bridge_send);
        lua.register_function("__fname", lua_fname);
        lua.register_function("__peek", lua_peek);
        lua.register_function("__alloc", lua_alloc);
        lua.register_function("__free", lua_free);
        lua.register_function("__game_alloc", lua_game_alloc);
        lua.register_function("__game_free", lua_game_free);
        lua.register_function("__poke", lua_poke);
        lua.register_function("__fn_layout", lua_fn_layout);
        lua.register_function("__raw_call", lua_raw_call);
        lua.register_function("__addr", lua_addr);
        lua.register_function("__obj", lua_obj);
    }

    class BrickadiaBridge final : public CppUserModBase
    {
      public:
        ~BrickadiaBridge() override
        {
            g_server.reset();
        }

        BrickadiaBridge()
        {
            ModName = STR("BrickadiaBridge");
            ModVersion = STR("0.2");
            ModDescription = STR("Raw UFunction calls for the BrickadiaBridge Lua mod");
            ModAuthors = STR("cake");
        }

        auto on_unreal_init() -> void override
        {
            // dispatch() does nothing without a socket; tick listeners run either way
            Hook::RegisterEngineTickPreCallback([](auto&, UEngine*, float delta, bool) { dispatch(); run_tick_listeners(delta); },
                                                {false, false, STR("BrickadiaBridge"), STR("Tick")});
            const char* path = std::getenv("OMEGGA_UE4SS_SOCKET");
            if (!path || !*path)
            {
                Output::send<LogLevel::Warning>(STR("[BrickadiaBridge] OMEGGA_UE4SS_SOCKET is not set; no omegga connection\n"));
                return;
            }
            g_server = std::make_unique<omegga_bridge::SocketServer>([](const std::string& text) {
                Output::send<LogLevel::Error>(STR("[BrickadiaBridge] {}\n"), ensure_str(text));
            });
            if (!g_server->start(path))
            {
                g_server.reset();
                return;
            }
            Output::send(STR("[BrickadiaBridge] listening on {}\n"), ensure_str(std::string{path}));
        }

        // a stopped (or reloaded) mod's Lua state goes away, and so must its listeners
        auto on_lua_stop([[maybe_unused]] StringViewType mod_name,
                         LuaMadeSimple::Lua& lua,
                         [[maybe_unused]] LuaMadeSimple::Lua& main_lua,
                         [[maybe_unused]] LuaMadeSimple::Lua& async_lua,
                         [[maybe_unused]] LuaMadeSimple::Lua* hook_lua) -> void override
        {
            auto* main = main_thread(lua.get_lua_state());
            {
                std::lock_guard lock{g_listeners_mutex};
                std::erase_if(g_listeners, [main](const auto& entry) { return entry.second.main == main; });
            }
            {
                std::lock_guard lock{g_tick_mutex};
                std::erase_if(g_tick_listeners, [main](const Listener& l) { return l.main == main; });
            }
            std::lock_guard lock{g_call_hooks_mutex};
            for (auto& [fn, list] : g_call_hooks)
            {
                std::erase_if(list, [main](const Listener& l) { return l.main == main; });
            }
        }

        // Runs for every Lua mod that starts, so any mod (including ones shipped by
        // other omegga plugins) can use the shared omegga.brickadia helpers
        auto on_lua_start([[maybe_unused]] StringViewType mod_name,
                          LuaMadeSimple::Lua& lua,
                          LuaMadeSimple::Lua& main_lua,
                          LuaMadeSimple::Lua& async_lua,
                          LuaMadeSimple::Lua* hook_lua) -> void override
        {
            // LoopAsync bodies run in async_lua and ExecuteInGameThread callbacks in
            // hook_lua; each needs its own copy of the globals
            register_all(lua);
            register_all(main_lua);
            register_all(async_lua);
            if (hook_lua) { register_all(*hook_lua); }
        }
    };
} // namespace

extern "C" __attribute__((visibility("default"))) CppUserModBase* start_mod()
{
    return new BrickadiaBridge{};
}

extern "C" __attribute__((visibility("default"))) void uninstall_mod(CppUserModBase* mod)
{
    delete mod;
}
