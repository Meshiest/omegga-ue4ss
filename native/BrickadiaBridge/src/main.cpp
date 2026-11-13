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
//                                  bytes (opaque structs included, unlike RegisterHook).
//                                  fn returns false to block the call, or bytes to
//                                  write over the parameters
//   __on_call_after(path, fn)      fn(self, params) after every ProcessEvent of the
//                                  UFunction `path` that ran (one an __on_call
//                                  listener blocked doesn't come here); params now
//                                  hold the return value and out parameters. Read only
//   __watchdog(ms) -> previous     the time budget of every callback the bridge runs
//                                  (ticks, hooks, delegates, bridge messages); one
//                                  that runs over is stopped with a Lua error. 0: off
//   __delegate_bind(owner, property, fn) -> id, signature path: fn(params) on every
//                                  broadcast of the owner's multicast delegate `property`
//   __delegate_unbind(id)
//   __voice_route(fn, world, playerstate, frame, position, burst)
//                                  hand one Opus frame to Brickadia's voice routing as
//                                  if `playerstate` had said it (BR.voice finds `fn`)
//   __voice_capture(fn)            start copying every frame the routing function routes
//   __voice_take()                 -> the frames copied since the last call, as
//                                     { talker, frame, position, burst } tables
//   __custom_event_capture()       hook the custom event dispatcher (once) -> a cursor
//   __custom_event_take(cursor)    -> every custom event sent since `cursor` (name, target,
//                                     sender, values, texts), and the next cursor
//   __permission_set(player, tag, state) override a permission for one player: true
//                                  allows, false forbids, nil lets the game decide; the
//                                  tag's children follow it unless they have their own
//   __permission_clear(player)     drop all of a player's overrides
//   __permission_trace(on)         record every permission check the game makes
//   __permission_trace_take()      -> { { player, tag, result }, ... } since the last take
//   __tx_append(self, struct) -> self, address   add an action of UScriptStruct `struct`
//                                  to a Luau transaction's bytes; fill it, then
//   __tx_finish(self, address)
//   __custom_event_post(registry, name, global, scope, target, values) -> receivers
//                                  queue a custom event on its receivers now, as a Send
//                                  Custom Event gate would, without one
//
// The buffer is never destructed: params holding heap memory (FString, TArray)
// leak, which is acceptable for a test bridge and avoids double frees when Lua
// copied a pointer out of it. Callers must be on the game thread.
#include <link.h>

#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <unordered_map>
#include <vector>

#include <LuaMadeSimple/LuaMadeSimple.hpp>
#include <LuaType/LuaUObject.hpp>
#include <Mod/CppUserModBase.hpp>
#include <Unreal/Core/HAL/UnrealMemory.hpp>
#include <Unreal/CoreUObject/UObject/Class.hpp>
#include <Unreal/FProperty.hpp>
#include <Unreal/CoreUObject/UObject/UnrealType.hpp>
#include <Unreal/UFunction.hpp>
#include <Unreal/UObject.hpp>
#include <Unreal/UObjectGlobals.hpp>
#include <Unreal/Hooks/Hooks.hpp>
#include <Unreal/FWeakObjectPtr.hpp>
#include <polyhook2/Detour/x64Detour.hpp>
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

    // Brickadia's voice routing: the function a voice channel calls with every
    // packet a client sends, and a listen server's own encoder with the host's,
    //   route(UWorld*, ABRPlayerState* talker, const TArray<uint8>& opus_frame,
    //         uint64 sample_position, uint32 talk_burst)
    // It checks the talker may use voice chat, then sends the frame down the voice
    // channel of every client in earshot, which plays it from the talker's
    // character. It is not reflected, so its address comes from Lua (BR.voice
    // finds it in the voice channel's ReceivedBunch). It only reads the frame.
    struct ByteArrayView
    {
        const uint8_t* data;
        int32_t num;
        int32_t max;
    };
    using VoiceRouteFn = void (*)(UObject*, UObject*, const ByteArrayView*, uint64_t, uint32_t);
    // a voice packet holds at most this many bytes of Opus frame
    constexpr size_t MAX_VOICE_FRAME = 512;

    auto lua_voice_route(const LuaMadeSimple::Lua& lua) -> int
    {
        auto fn = static_cast<uintptr_t>(lua.get_integer());
        UObject* world = lua.get_userdata<LuaType::UObject>().get_remote_cpp_object();
        UObject* talker = lua.get_userdata<LuaType::UObject>().get_remote_cpp_object();
        auto frame = take_bytes(lua);
        auto position = static_cast<uint64_t>(lua.get_integer());
        auto burst = static_cast<uint32_t>(lua.get_integer());
        if (!fn || !world || !talker) lua.throw_error("__voice_route: no routing function, world or talker");
        if (frame.empty() || frame.size() > MAX_VOICE_FRAME) lua.throw_error("__voice_route: a frame is 1 to 512 bytes");
        ByteArrayView view{reinterpret_cast<const uint8_t*>(frame.data()), static_cast<int32_t>(frame.size()),
                           static_cast<int32_t>(frame.size())};
        // the address is a function in the game binary that Lua located by its
        // call site; Lua has no function pointer type, so it travelled as an integer
        reinterpret_cast<VoiceRouteFn>(fn)(world, talker, &view, position, burst);
        return 0;
    }

    // Voice capture: a detour on the routing function copies every frame it
    // routes (any player's, and BR.voice's own) into a queue that Lua empties
    // with __voice_take each tick. The queue is capped, so frames nobody takes
    // are dropped rather than piling up.
    struct CapturedFrame
    {
        UObject* talker;
        std::string frame;
        uint64_t position;
        uint32_t burst;
    };
    constexpr size_t MAX_CAPTURED = 4096;
    std::mutex g_capture_mutex;
    std::vector<CapturedFrame> g_captured;
    std::unique_ptr<PLH::x64Detour> g_route_detour;
    uint64_t g_route_original{};

    auto route_detour(UObject* world, UObject* talker, const ByteArrayView* frame, uint64_t position, uint32_t burst) -> void
    {
        reinterpret_cast<VoiceRouteFn>(g_route_original)(world, talker, frame, position, burst);
        if (!talker || !frame || frame->num <= 0 || static_cast<size_t>(frame->num) > MAX_VOICE_FRAME) return;
        std::lock_guard lock{g_capture_mutex};
        if (g_captured.size() >= MAX_CAPTURED) return;
        g_captured.push_back({talker, std::string{reinterpret_cast<const char*>(frame->data), static_cast<size_t>(frame->num)}, position, burst});
    }

    // __voice_capture(fn): start copying routed frames (once; later calls no-op)
    auto lua_voice_capture(const LuaMadeSimple::Lua& lua) -> int
    {
        auto fn = static_cast<uint64_t>(lua.get_integer());
        if (g_route_detour)
        {
            lua.set_bool(true);
            return 1;
        }
        if (!fn) lua.throw_error("__voice_capture: no routing function");
        g_route_detour = std::make_unique<PLH::x64Detour>(fn, reinterpret_cast<uint64_t>(&route_detour), &g_route_original);
        if (!g_route_detour->hook())
        {
            g_route_detour.reset();
            lua.throw_error("__voice_capture: hooking the routing function failed");
        }
        lua.set_bool(true);
        return 1;
    }

    // __voice_take() -> { { talker = PlayerState, frame = bytes, position, burst }, ... }
    // in the order they were routed
    auto lua_voice_take(const LuaMadeSimple::Lua& lua) -> int
    {
        std::vector<CapturedFrame> frames;
        {
            std::lock_guard lock{g_capture_mutex};
            frames.swap(g_captured);
        }
        lua_State* L = lua.get_lua_state();
        lua_createtable(L, static_cast<int>(frames.size()), 0);
        for (size_t i = 0; i < frames.size(); ++i)
        {
            lua_createtable(L, 0, 4);
            LuaType::auto_construct_object(lua, frames[i].talker);
            lua_setfield(L, -2, "talker");
            lua_pushlstring(L, frames[i].frame.data(), frames[i].frame.size());
            lua_setfield(L, -2, "frame");
            lua_pushinteger(L, static_cast<lua_Integer>(frames[i].position));
            lua_setfield(L, -2, "position");
            lua_pushinteger(L, frames[i].burst);
            lua_setfield(L, -2, "burst");
            lua_rawseti(L, -2, static_cast<lua_Integer>(i + 1));
        }
        return 1;
    }

    // Custom events. Every Send Custom Event gate ends in one function,
    //   dispatch(UBRRegistry*, FName name, int32 target, const BCSComponentHandle* sender,
    //            TArray<WireValue, TInlineAllocator<8>>* payload)
    // which looks the name up in the registry and queues the payload on each
    // receiver. It is not reflected, so it is found by its opening checks on the
    // registry (the field offsets change between builds, the shape does not):
    //   cmpb $0, X(%rdi); je; cmpl $3, Y(%rdi); je; test %rsi, %rsi; je
    // The caller owns the payload and destroys it after the call.
    constexpr size_t WIRE_VALUE_SIZE = 0x28;
    constexpr size_t WIRE_KIND_OFFSET = 0x20;
    constexpr uint8_t WIRE_KIND_STRING = 7;
    constexpr int32_t EVENT_VALUES = 8;

    struct EventPayload
    {
        uint8_t inline_values[EVENT_VALUES * WIRE_VALUE_SIZE];
        uint8_t* heap_values;
        int32_t num;
        int32_t max;
        int32_t entry_id; // the dispatcher fills it in
        int32_t pad;
    };
    static_assert(sizeof(EventPayload) == 0x158);

    using DispatchFn = void (*)(UObject* registry, uint64_t name, int32_t target, const uint64_t* sender, EventPayload* payload);

    auto executable_code() -> std::pair<const uint8_t*, size_t>
    {
        static std::pair<const uint8_t*, size_t> code = [] {
            std::pair<const uint8_t*, size_t> found{nullptr, 0};
            // the first object dl_iterate_phdr reports is the executable itself
            dl_iterate_phdr(
                    [](dl_phdr_info* info, size_t, void* out) -> int {
                        auto* result = static_cast<std::pair<const uint8_t*, size_t>*>(out);
                        for (int i = 0; i < info->dlpi_phnum; ++i)
                        {
                            const auto& ph = info->dlpi_phdr[i];
                            if (ph.p_type == PT_LOAD && (ph.p_flags & PF_X) && ph.p_memsz > result->second)
                            {
                                *result = {reinterpret_cast<const uint8_t*>(info->dlpi_addr + ph.p_vaddr), ph.p_memsz};
                            }
                        }
                        return 1;
                    },
                    &found);
            return found;
        }();
        return code;
    }

    auto find_dispatcher() -> uintptr_t
    {
        static uintptr_t address = [] {
            auto [code, size] = executable_code();
            // -1 marks a wildcard byte
            static constexpr int16_t pattern[] = {0x80, 0xbf, -1,   -1,   0x00, 0x00, 0x00, 0x0f, 0x84, -1,   -1,   -1, -1,
                                                  0x83, 0xbf, -1,   -1,   0x00, 0x00, 0x03, 0x74, -1,   0x48, 0x85, 0xf6, 0x74};
            constexpr size_t len = std::size(pattern);
            uintptr_t match = 0;
            for (size_t i = 0; code && i + len <= size; ++i)
            {
                if (code[i] != pattern[0]) continue;
                size_t j = 1;
                while (j < len && (pattern[j] < 0 || code[i + j] == pattern[j])) ++j;
                if (j < len) continue;
                // two matches would mean the pattern no longer names one function
                if (match) return uintptr_t{0};
                match = reinterpret_cast<uintptr_t>(code + i);
            }
            if (!match) return uintptr_t{0};
            // the checks follow the prologue; the function starts after the int3
            // padding that ends the previous one
            auto* p = reinterpret_cast<const uint8_t*>(match);
            for (int back = 1; back < 0x40; ++back)
            {
                if (p[-back - 1] == 0xcc && p[-back] == 0x55) return match - back;
            }
            return uintptr_t{0};
        }();
        return address;
    }

    // A WireString value is { object*, controller* } held by a TSharedPtr; the
    // object starts with its TArray<char> text, NUL included.
    auto wirestring_text(const uint8_t* value) -> std::string
    {
        const uint8_t* object;
        std::memcpy(&object, value, 8);
        if (!object) return {};
        const char* data;
        int32_t num;
        std::memcpy(&data, object, 8);
        std::memcpy(&num, object + 8, 4);
        if (!data || num <= 1) return {};
        return std::string{data, static_cast<size_t>(num - 1)};
    }

    // Drops one reference to a WireString, as TSharedPtr's destructor does:
    // the controller's vtable is { DestroyObject, ~dtor, deleting ~dtor }, and the
    // counts are atomic int32s after it.
    auto release_wirestring(const uint8_t* value) -> void
    {
        uint8_t* controller;
        std::memcpy(&controller, value + 8, 8);
        if (!controller) return;
        auto* shared = reinterpret_cast<int32_t*>(controller + 8);
        auto* weak = reinterpret_cast<int32_t*>(controller + 12);
        using Virtual = void (*)(uint8_t*);
        // the controller is a C++ object whose first word is its vtable
        auto* vtable = *reinterpret_cast<Virtual**>(controller);
        if (__atomic_sub_fetch(shared, 1, __ATOMIC_ACQ_REL) != 0) return;
        vtable[0](controller);
        if (__atomic_sub_fetch(weak, 1, __ATOMIC_ACQ_REL) == 0) vtable[2](controller);
    }

    struct CustomEvent
    {
        uint64_t name;
        int32_t target;
        uint64_t sender;
        std::string values;               // EVENT_VALUES raw wire values
        std::string texts[EVENT_VALUES]; // the text of each string value
    };
    // Events go into a ring that every Lua state reads with its own cursor, so
    // two states listening both see each event.
    constexpr size_t MAX_EVENTS = 4096;
    std::mutex g_events_mutex;
    std::vector<CustomEvent> g_events{MAX_EVENTS};
    uint64_t g_events_next{}; // sequence number of the next event recorded
    std::unique_ptr<PLH::x64Detour> g_dispatch_detour;
    uint64_t g_dispatch_original{};

    auto record_event(uint64_t name, int32_t target, uint64_t sender, const EventPayload* payload) -> void
    {
        CustomEvent ev{name, target, sender, std::string(EVENT_VALUES * WIRE_VALUE_SIZE, '\0'), {}};
        const uint8_t* values = payload->heap_values ? payload->heap_values : payload->inline_values;
        int32_t n = std::clamp(payload->num, 0, EVENT_VALUES);
        std::memcpy(ev.values.data(), values, n * WIRE_VALUE_SIZE);
        for (int32_t i = 0; i < n; ++i)
        {
            const uint8_t* v = values + i * WIRE_VALUE_SIZE;
            if (v[WIRE_KIND_OFFSET] == WIRE_KIND_STRING) ev.texts[i] = wirestring_text(v);
        }
        std::lock_guard lock{g_events_mutex};
        g_events[g_events_next % MAX_EVENTS] = std::move(ev);
        ++g_events_next;
    }

    auto dispatch_detour(UObject* registry, uint64_t name, int32_t target, const uint64_t* sender, EventPayload* payload) -> void
    {
        if (payload && sender) record_event(name, target, *sender, payload);
        reinterpret_cast<DispatchFn>(g_dispatch_original)(registry, name, target, sender, payload);
    }

    // __custom_event_capture() -> the sequence number of the next event, the
    // cursor to start __custom_event_take from. Hooks the dispatcher once.
    auto lua_custom_event_capture(const LuaMadeSimple::Lua& lua) -> int
    {
        if (!g_dispatch_detour)
        {
            auto fn = find_dispatcher();
            if (!fn) lua.throw_error("__custom_event_capture: the custom event dispatcher was not found in this build");
            g_dispatch_detour = std::make_unique<PLH::x64Detour>(fn, reinterpret_cast<uint64_t>(&dispatch_detour), &g_dispatch_original);
            if (!g_dispatch_detour->hook())
            {
                g_dispatch_detour.reset();
                lua.throw_error("__custom_event_capture: hooking the dispatcher failed");
            }
        }
        std::lock_guard lock{g_events_mutex};
        lua.set_integer(static_cast<int64_t>(g_events_next));
        return 1;
    }

    // __custom_event_take(cursor) -> events since `cursor`, next cursor. Each event is
    // { name = text, target = int, sender = 8-byte handle, values = bytes, texts = { [i] = text } }.
    // Events older than the ring holds are skipped.
    auto lua_custom_event_take(const LuaMadeSimple::Lua& lua) -> int
    {
        auto cursor = static_cast<uint64_t>(lua.get_integer());
        std::vector<CustomEvent> events;
        uint64_t next;
        {
            std::lock_guard lock{g_events_mutex};
            next = g_events_next;
            if (cursor > next) cursor = next;
            if (next - cursor > MAX_EVENTS) cursor = next - MAX_EVENTS;
            for (uint64_t s = cursor; s < next; ++s) events.push_back(g_events[s % MAX_EVENTS]);
        }
        lua_State* L = lua.get_lua_state();
        lua_createtable(L, static_cast<int>(events.size()), 0);
        for (size_t i = 0; i < events.size(); ++i)
        {
            const auto& ev = events[i];
            lua_createtable(L, 0, 5);
            auto name = to_utf8_string(FName{static_cast<int64_t>(ev.name)}.ToString());
            lua_pushlstring(L, name.data(), name.size());
            lua_setfield(L, -2, "name");
            lua_pushinteger(L, ev.target);
            lua_setfield(L, -2, "target");
            lua_pushlstring(L, reinterpret_cast<const char*>(&ev.sender), 8);
            lua_setfield(L, -2, "sender");
            lua_pushlstring(L, ev.values.data(), ev.values.size());
            lua_setfield(L, -2, "values");
            lua_createtable(L, 0, 0);
            for (int32_t v = 0; v < EVENT_VALUES; ++v)
            {
                if (ev.values[v * WIRE_VALUE_SIZE + WIRE_KIND_OFFSET] != WIRE_KIND_STRING) continue;
                lua_pushlstring(L, ev.texts[v].data(), ev.texts[v].size());
                lua_rawseti(L, -2, v + 1);
            }
            lua_setfield(L, -2, "texts");
            lua_rawseti(L, -2, static_cast<lua_Integer>(i + 1));
        }
        lua_pushinteger(L, static_cast<lua_Integer>(next));
        return 2;
    }

    // What the dispatcher does once it knows its sender, taken from its own code
    // so a sender gate isn't needed. Receivers are kept in the registry by key
    //   { FName name; uint8 bGlobal; int32 scope }    (scope -1 when global, else
    //                                                  the sending brick's owner)
    // in a dense compact map (elements 0..Num-1 are all live, 0x48 bytes each),
    // whose value holds a dense map of target entity id (0 for global) to an
    // array of receiver component handles at +0x30, and an id the payload carries
    // at +0x40. Each receiver handle is resolved and handed the payload by the
    // same two functions the dispatcher calls; their addresses are read from its
    // call sites, which are checked to be calls first.
    struct Dispatcher
    {
        uint32_t ready_offset;    // cmpb $0, X(%rdi): the registry is set up
        uint32_t state_offset;    // cmpl $3, Y(%rdi): 3 is shutting down
        uint32_t receivers_offset; // add $Z, %rdi: the receiver map
        uintptr_t resolve;        // resolve(out, const handle*): out+0x8 component, out+0x18 valid
        uintptr_t receiver_class; // the receiver component type's class
        uintptr_t enqueue;        // enqueue(component, resolved, payload)
    };

    auto call_target(const uint8_t* at) -> uintptr_t
    {
        if (at[0] != 0xe8) return 0;
        int32_t rel;
        std::memcpy(&rel, at + 1, 4);
        return reinterpret_cast<uintptr_t>(at + 5 + rel);
    }

    auto find_dispatcher_parts() -> const Dispatcher*
    {
        static std::optional<Dispatcher> parts = []() -> std::optional<Dispatcher> {
            auto fn = find_dispatcher();
            if (!fn) return std::nullopt;
            auto* p = reinterpret_cast<const uint8_t*>(fn);
            // offsets of the instructions within this build's dispatcher
            if (p[0x12] != 0x80 || p[0x13] != 0xbf || p[0x1f] != 0x83 || p[0x20] != 0xbf) return std::nullopt;
            if (p[0xf9] != 0x48 || p[0xfa] != 0x81 || p[0xfb] != 0xc7) return std::nullopt;
            Dispatcher d{};
            std::memcpy(&d.ready_offset, p + 0x14, 4);
            std::memcpy(&d.state_offset, p + 0x21, 4);
            std::memcpy(&d.receivers_offset, p + 0xfc, 4);
            d.resolve = call_target(p + 0x20b);
            d.receiver_class = call_target(p + 0x223);
            d.enqueue = call_target(p + 0x24e);
            // the sender is resolved by the same function as each receiver
            if (!d.resolve || d.resolve != call_target(p + 0x43) || !d.receiver_class || !d.enqueue) return std::nullopt;
            return d;
        }();
        return parts ? &*parts : nullptr;
    }

    // UObject::IsA as the dispatcher inlines it: the class's struct base chain
    // (at +0x30, depth at +0x38) holds `cls`'s own entry at cls's depth
    auto inline_is_a(const uint8_t* object, const uint8_t* cls) -> bool
    {
        const uint8_t* object_class;
        std::memcpy(&object_class, object + 0x10, 8);
        int32_t depth, object_depth;
        std::memcpy(&depth, cls + 0x38, 4);
        std::memcpy(&object_depth, object_class + 0x38, 4);
        if (depth > object_depth) return false;
        const uint8_t* const* chain;
        std::memcpy(&chain, object_class + 0x30, 8);
        return chain[depth] == cls + 0x30;
    }

    // __custom_event_post(registry, name, global, scope, target, values) -> receivers:
    // queue a custom event on the receivers listening for it, as a Send Custom
    // Event gate would: global (scope -1, target 0), or to entity `target` for
    // receivers built by owner `scope`. `values` are 8 wire values; the payload
    // takes over their WireString references and drops them afterwards. Lua
    // listeners hear it too.
    auto lua_custom_event_post(const LuaMadeSimple::Lua& lua) -> int
    {
        UObject* registry = lua.get_userdata<LuaType::UObject>().get_remote_cpp_object();
        auto name_text = ensure_str(std::string{lua.get_string()});
        bool global = lua.get_bool();
        auto scope = static_cast<int32_t>(lua.get_integer());
        auto target = static_cast<int32_t>(lua.get_integer());
        auto values = take_bytes(lua);
        if (!registry) lua.throw_error("__custom_event_post: no registry");
        if (values.size() != EVENT_VALUES * WIRE_VALUE_SIZE) lua.throw_error("__custom_event_post: needs 8 wire values (320 bytes)");
        const Dispatcher* d = find_dispatcher_parts();
        if (!d) lua.throw_error("__custom_event_post: the custom event dispatcher's layout isn't the one this bridge knows");
        auto* reg = reinterpret_cast<uint8_t*>(registry);
        if (reg[d->ready_offset] == 0) lua.throw_error("__custom_event_post: the registry isn't ready");
        FName name{name_text.c_str(), FNAME_Add};
        uint64_t packed = static_cast<uint64_t>(name.GetComparisonIndex().ToUnstableInt()) | (static_cast<uint64_t>(name.GetNumber()) << 32);
        if (global)
        {
            scope = -1;
            target = 0;
        }
        EventPayload payload{};
        std::memcpy(payload.inline_values, values.data(), values.size());
        payload.num = EVENT_VALUES;
        payload.max = EVENT_VALUES;
        record_event(packed, target, 0, &payload);
        int delivered = 0;
        int32_t state;
        std::memcpy(&state, reg + d->state_offset, 4);
        const uint8_t* map = reg + d->receivers_offset;
        const uint8_t* elements;
        int32_t num;
        std::memcpy(&elements, map, 8);
        std::memcpy(&num, map + 8, 4);
        for (int32_t i = 0; state != 3 && elements && i < num; ++i)
        {
            const uint8_t* e = elements + static_cast<size_t>(i) * 0x48;
            uint64_t key_name;
            int32_t key_scope;
            std::memcpy(&key_name, e, 8);
            std::memcpy(&key_scope, e + 0xc, 4);
            if (key_name != packed || (e[8] != 0) != global || key_scope != scope) continue;
            std::memcpy(&payload.entry_id, e + 0x40, 4);
            const uint8_t* targets;
            int32_t num_targets;
            std::memcpy(&targets, e + 0x30, 8);
            std::memcpy(&num_targets, e + 0x38, 4);
            for (int32_t t = 0; targets && t < num_targets; ++t)
            {
                const uint8_t* entry = targets + static_cast<size_t>(t) * 0x18;
                int32_t key_target;
                std::memcpy(&key_target, entry, 4);
                if (key_target != target) continue;
                const uint64_t* handles;
                int32_t num_handles;
                std::memcpy(&handles, entry + 8, 8);
                std::memcpy(&num_handles, entry + 0x10, 4);
                // copied: a receiver's handler could change the list
                std::vector<uint64_t> list(handles, handles + std::max(num_handles, 0));
                auto* cls = reinterpret_cast<const uint8_t*>(reinterpret_cast<void* (*)(int)>(d->receiver_class)(0));
                for (uint64_t handle : list)
                {
                    alignas(16) uint8_t resolved[0x40]{};
                    reinterpret_cast<void (*)(uint8_t*, const uint64_t*)>(d->resolve)(resolved, &handle);
                    if (!(resolved[0x18] & 1)) continue;
                    const uint8_t* component;
                    std::memcpy(&component, resolved + 8, 8);
                    if (!component || !inline_is_a(component, cls)) continue;
                    reinterpret_cast<void (*)(const uint8_t*, uint8_t*, EventPayload*)>(d->enqueue)(component, resolved, &payload);
                    ++delivered;
                }
                break;
            }
            break;
        }
        for (int32_t i = 0; i < EVENT_VALUES; ++i)
        {
            const uint8_t* v = payload.inline_values + i * WIRE_VALUE_SIZE;
            if (v[WIRE_KIND_OFFSET] == WIRE_KIND_STRING) release_wirestring(v);
        }
        lua.set_integer(delivered);
        return 1;
    }

    // Transactions. BRLuauTransactionLibrary's Record* functions keep their actions
    // in a UBrickTransaction (FBRLuauTransaction's Self+0x20, created on the first
    // record; Self+0x28 is set once executed). Actions are C++ structs with a
    // vtable, built in place in pages of an arena:
    //   transaction +0x40 first page, +0x48 current page, +0x5a locked,
    //               +0x5c page count, +0x60 action count
    //   page (0x7ff0 bytes) +0 next, +8 prev, u16 +0x10 capacity (0x7fd8),
    //               u16 +0x12 bytes used, u16 +0x14 actions, u8 +0x16 an action
    //               needs fixing up; data from +0x18, and a table of u16 offsets
    //               into it growing down from the end of the data
    // There is no record function for every action (an entity changelist has
    // none), so __tx_append places any action struct the way they do.
    constexpr size_t TX_PAGE_SIZE = 0x7ff0;
    constexpr uint16_t TX_PAGE_CAPACITY = 0x7fd8;

    // The game's get-or-create for Self's transaction: the first direct call in
    // RecordSetEntityColor's native code whose target starts with its prologue
    // and its check of Self+0x28.
    auto find_tx_get() -> uintptr_t
    {
        static uintptr_t address = []() -> uintptr_t {
            auto* fn = find_function("/Script/Brickadia.BRLuauTransactionLibrary:RecordSetEntityColor");
            if (!fn) return 0;
            auto* code = reinterpret_cast<const uint8_t*>(fn->GetFuncPtr());
            auto [text, size] = executable_code();
            if (!code || !text) return 0;
            static constexpr uint8_t prologue[] = {0x41, 0x56, 0x53, 0x48, 0x81, 0xec};
            static constexpr uint8_t check[] = {0x80, 0x7f, 0x28, 0x00};
            for (size_t i = 0; i < 0x400; ++i)
            {
                if (code[i] != 0xe8) continue;
                auto target = call_target(code + i);
                if (target < reinterpret_cast<uintptr_t>(text) || target + 16 > reinterpret_cast<uintptr_t>(text) + size) continue;
                auto* q = reinterpret_cast<const uint8_t*>(target);
                if (std::memcmp(q, prologue, sizeof prologue) == 0 && std::memcmp(q + 10, check, sizeof check) == 0) return target;
            }
            return 0;
        }();
        return address;
    }

    auto new_tx_page() -> uint8_t*
    {
        auto* page = static_cast<uint8_t*>(FMemory::Malloc(TX_PAGE_SIZE));
        std::memset(page, 0, 0x18);
        std::memcpy(page + 0x10, &TX_PAGE_CAPACITY, 2);
        return page;
    }

    template <typename T> auto at(uint8_t* base, size_t offset) -> T&
    {
        return *reinterpret_cast<T*>(base + offset);
    }

    // __tx_append(self, struct) -> self, address: a new action of UScriptStruct
    // `struct` (default constructed) at the end of the transaction `self` (an
    // FBRLuauTransaction's bytes); the caller fills its fields, then calls
    // __tx_finish(self, address).
    auto lua_tx_append(const LuaMadeSimple::Lua& lua) -> int
    {
        auto self = take_bytes(lua);
        auto* object = lua.get_userdata<LuaType::UObject>().get_remote_cpp_object();
        if (self.size() < 0x30) lua.throw_error("__tx_append: a transaction is 48 bytes");
        if (self[0x28] != 0) lua.throw_error("__tx_append: the transaction has run");
        auto* script_struct = object ? Cast<UScriptStruct>(object) : nullptr;
        if (!script_struct) lua.throw_error("__tx_append: needs a UScriptStruct");
        auto get = find_tx_get();
        if (!get) lua.throw_error("__tx_append: the game's transaction code isn't the shape this bridge knows");
        auto* tx = reinterpret_cast<uint8_t*>(reinterpret_cast<void* (*)(char*)>(get)(self.data()));
        if (!tx) lua.throw_error("__tx_append: no transaction");
        if (tx[0x5a] == 1) lua.throw_error("__tx_append: the transaction is locked");
        auto size = static_cast<size_t>(script_struct->GetStructureSize());
        if (size == 0 || size + 0x20 > TX_PAGE_CAPACITY) lua.throw_error("__tx_append: the struct doesn't fit a page");
        auto*& current = at<uint8_t*>(tx, 0x48);
        if (!current)
        {
            current = new_tx_page();
            at<uint8_t*>(tx, 0x40) = current;
            ++at<int32_t>(tx, 0x5c);
        }
        uint8_t* slot = nullptr;
        for (int attempt = 0; attempt < 2 && !slot; ++attempt)
        {
            auto* page = current;
            auto capacity = at<uint16_t>(page, 0x10);
            auto used = at<uint16_t>(page, 0x12);
            auto count = at<uint16_t>(page, 0x14);
            auto* data = page + 0x18;
            auto* aligned = reinterpret_cast<uint8_t*>((reinterpret_cast<uintptr_t>(data + used) + 7) & ~uintptr_t{7});
            auto offset = static_cast<size_t>(aligned - data);
            if (offset + size + 2 <= static_cast<size_t>(capacity) - 2u * count)
            {
                ++count;
                at<uint16_t>(page, 0x14) = count;
                auto entry = static_cast<uint16_t>(offset);
                std::memcpy(data + capacity - 2u * count, &entry, 2);
                at<uint16_t>(page, 0x12) = static_cast<uint16_t>(offset + size);
                slot = aligned;
                break;
            }
            auto* next = new_tx_page();
            at<uint8_t*>(page, 0) = next;
            at<uint8_t*>(next, 8) = page;
            current = next;
            ++at<int32_t>(tx, 0x5c);
        }
        if (!slot) lua.throw_error("__tx_append: no room in a fresh page");
        ++at<int32_t>(tx, 0x60);
        std::memset(slot, 0, size);
        script_struct->InitializeStruct(slot);
        lua_pushlstring(lua.get_lua_state(), self.data(), self.size());
        lua.set_integer(static_cast<int64_t>(reinterpret_cast<uintptr_t>(slot)));
        return 2;
    }

    // __tx_finish(self, address): what a record function does once an action's
    // fields are set: the action's fourth virtual says whether it holds
    // references to fix up, which its page then notes.
    auto lua_tx_finish(const LuaMadeSimple::Lua& lua) -> int
    {
        auto self = take_bytes(lua);
        auto address = static_cast<uintptr_t>(lua.get_integer());
        if (self.size() < 0x30) lua.throw_error("__tx_finish: a transaction is 48 bytes");
        uint8_t* tx;
        std::memcpy(&tx, self.data() + 0x20, 8);
        if (!tx || !address) lua.throw_error("__tx_finish: nothing appended");
        using Check = bool (*)(void*);
        auto* vtable = *reinterpret_cast<Check**>(address);
        if (vtable[3](reinterpret_cast<void*>(address))) at<uint8_t>(at<uint8_t*>(tx, 0x48), 0x16) = 1;
        return 0;
    }

    // Permissions. Every check the game makes of a player's permission goes
    // through BRPlayerState::HasPermission(FGameplayTag), which resolves roles,
    // gameplay permission overrides and a character's temporary grants. A detour
    // on it answers first from per-player overrides set from Lua, matching the
    // tag or its nearest parent ("BR.Permission.Building" covers every building
    // tag below it), and otherwise lets the game decide. The function isn't
    // reflected; its UFunction's native thunk reads the parameter and calls it,
    // and the first direct call in that generated thunk is the implementation.
    using HasPermissionFn = bool (*)(UObject* player, uint64_t tag);

    struct PlayerOverrides
    {
        FWeakObjectPtr player;
        std::unordered_map<std::string, bool> tags;
    };
    std::mutex g_perm_mutex;
    std::vector<PlayerOverrides> g_perm_overrides;
    std::unordered_map<uint64_t, std::string> g_tag_names;
    bool g_perm_trace = false;
    struct CheckedPermission
    {
        FWeakObjectPtr player;
        std::string tag;
        bool result;
    };
    constexpr size_t MAX_TRACED = 1024;
    std::vector<CheckedPermission> g_perm_traced;
    std::unique_ptr<PLH::x64Detour> g_perm_detour;
    uint64_t g_perm_original{};

    auto find_has_permission() -> uintptr_t
    {
        auto* fn = find_function("/Script/Brickadia.BRPlayerState:HasPermission");
        if (!fn) return 0;
        auto* code = reinterpret_cast<const uint8_t*>(fn->GetFunc());
        for (size_t i = 0; code && i < 0x200; ++i)
        {
            if (code[i] != 0xe8) continue;
            int32_t rel;
            std::memcpy(&rel, code + i + 1, 4);
            return reinterpret_cast<uintptr_t>(code + i + 5 + rel);
        }
        return 0;
    }

    // a tag's text, cached by its FName: the same few tags are checked constantly
    auto tag_text(uint64_t tag) -> const std::string&
    {
        auto it = g_tag_names.find(tag);
        if (it != g_tag_names.end()) return it->second;
        auto text = to_utf8_string(FName{static_cast<int64_t>(tag)}.ToString());
        return g_tag_names.emplace(tag, std::move(text)).first->second;
    }

    auto has_permission_detour(UObject* player, uint64_t tag) -> bool
    {
        std::optional<bool> decided;
        bool trace;
        std::string text;
        {
            std::lock_guard lock{g_perm_mutex};
            trace = g_perm_trace;
            if (!g_perm_overrides.empty() || trace) text = tag_text(tag);
            for (auto& entry : g_perm_overrides)
            {
                if (entry.player.Get() != player) continue;
                // the tag itself, then each parent, most specific first
                std::string_view key = text;
                while (!decided && !key.empty())
                {
                    if (auto it = entry.tags.find(std::string{key}); it != entry.tags.end()) decided = it->second;
                    auto dot = key.rfind('.');
                    key = dot == std::string_view::npos ? std::string_view{} : key.substr(0, dot);
                }
                break;
            }
        }
        bool result = decided ? *decided : reinterpret_cast<HasPermissionFn>(g_perm_original)(player, tag);
        if (trace)
        {
            std::lock_guard lock{g_perm_mutex};
            if (g_perm_traced.size() < MAX_TRACED) g_perm_traced.push_back({FWeakObjectPtr{player}, text, result});
        }
        return result;
    }

    auto ensure_permission_detour(const LuaMadeSimple::Lua& lua) -> void
    {
        if (g_perm_detour) return;
        auto fn = find_has_permission();
        if (!fn) lua.throw_error("permissions: BRPlayerState::HasPermission was not found in this build");
        g_perm_detour = std::make_unique<PLH::x64Detour>(fn, reinterpret_cast<uint64_t>(&has_permission_detour), &g_perm_original);
        if (!g_perm_detour->hook())
        {
            g_perm_detour.reset();
            lua.throw_error("permissions: hooking HasPermission failed");
        }
    }

    // __permission_set(player, tag, state): state true allows, false forbids, nil
    // clears the override and lets the game decide again
    auto lua_permission_set(const LuaMadeSimple::Lua& lua) -> int
    {
        lua_State* L = lua.get_lua_state();
        UObject* player = lua.get_userdata<LuaType::UObject>().get_remote_cpp_object();
        std::string tag = luaL_checkstring(L, 1);
        bool clear = lua_isnoneornil(L, 2);
        bool state = lua_toboolean(L, 2);
        lua_settop(L, 0);
        if (!player) lua.throw_error("__permission_set: no player");
        ensure_permission_detour(lua);
        std::lock_guard lock{g_perm_mutex};
        // entries for players that are gone go first, so the list can't grow
        std::erase_if(g_perm_overrides, [](PlayerOverrides& e) { return e.player.Get() == nullptr; });
        auto it = std::find_if(g_perm_overrides.begin(), g_perm_overrides.end(), [player](PlayerOverrides& e) { return e.player.Get() == player; });
        if (clear)
        {
            if (it != g_perm_overrides.end())
            {
                it->tags.erase(tag);
                if (it->tags.empty()) g_perm_overrides.erase(it);
            }
            return 0;
        }
        if (it == g_perm_overrides.end()) it = g_perm_overrides.insert(g_perm_overrides.end(), PlayerOverrides{FWeakObjectPtr{player}, {}});
        it->tags[tag] = state;
        return 0;
    }

    // __permission_clear(player): drop every override the player has
    auto lua_permission_clear(const LuaMadeSimple::Lua& lua) -> int
    {
        UObject* player = lua.get_userdata<LuaType::UObject>().get_remote_cpp_object();
        std::lock_guard lock{g_perm_mutex};
        std::erase_if(g_perm_overrides, [player](PlayerOverrides& e) { return e.player.Get() == nullptr || e.player.Get() == player; });
        return 0;
    }

    // __permission_trace(on): start or stop recording checks;
    // __permission_trace_take() -> { { player, tag, result }, ... } since the last take
    auto lua_permission_trace(const LuaMadeSimple::Lua& lua) -> int
    {
        bool on = lua.get_bool();
        ensure_permission_detour(lua);
        std::lock_guard lock{g_perm_mutex};
        g_perm_trace = on;
        if (!on) g_perm_traced.clear();
        return 0;
    }

    auto lua_permission_trace_take(const LuaMadeSimple::Lua& lua) -> int
    {
        std::vector<CheckedPermission> checks;
        {
            std::lock_guard lock{g_perm_mutex};
            checks.swap(g_perm_traced);
        }
        lua_State* L = lua.get_lua_state();
        lua_createtable(L, static_cast<int>(checks.size()), 0);
        int n = 0;
        for (auto& c : checks)
        {
            UObject* player = c.player.Get();
            if (!player) continue;
            lua_createtable(L, 0, 3);
            LuaType::auto_construct_object(lua, player);
            lua_setfield(L, -2, "player");
            lua_pushlstring(L, c.tag.data(), c.tag.size());
            lua_setfield(L, -2, "tag");
            lua_pushboolean(L, c.result);
            lua_setfield(L, -2, "result");
            lua_rawseti(L, -2, ++n);
        }
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


    // The watchdog: a callback that runs longer than its budget (an endless loop
    // in a mod's handler) is stopped with a Lua error, which reaches the mod's
    // error reporting like any other, instead of freezing the game thread. A
    // count hook checks the clock every 10,000 instructions; it can't stop time
    // spent inside one call into the game.
    int g_watchdog_ms = 5000;
    thread_local std::chrono::steady_clock::time_point t_deadline{};

    auto watchdog_hook(lua_State* L, lua_Debug* ar) -> void
    {
        if (std::chrono::steady_clock::now() < t_deadline) return;
        // the rest of this call runs unguarded: the other tick functions sharing
        // it still get their turn
        lua_sethook(L, nullptr, 0, 0);
        // where it was stopped: the function the hook interrupted
        lua_getinfo(L, "Sl", ar);
        luaL_error(L, "%s:%d: the callback ran longer than %d ms and was stopped by the watchdog", ar->short_src, ar->currentline, g_watchdog_ms);
    }

    // lua_pcall with the watchdog's budget; nested calls keep the outer deadline
    auto guarded_pcall(lua_State* T, int nargs, int nresults) -> int
    {
        if (g_watchdog_ms <= 0) return lua_pcall(T, nargs, nresults, 0);
        auto outer = t_deadline;
        t_deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds{g_watchdog_ms};
        lua_sethook(T, watchdog_hook, LUA_MASKCOUNT, 10000);
        int result = lua_pcall(T, nargs, nresults, 0);
        lua_sethook(T, nullptr, 0, 0);
        t_deadline = outer;
        return result;
    }

    // __watchdog(ms) -> the previous budget; 0 turns it off
    // Seconds on a steady clock, for timing Lua code (BR.profile): os.clock is
    // the process's CPU time, summed over every engine thread.
    auto lua_clock(const LuaMadeSimple::Lua& lua) -> int
    {
        const auto now = std::chrono::steady_clock::now().time_since_epoch();
        lua.set_number(std::chrono::duration<double>(now).count());
        return 1;
    }

    auto lua_watchdog(const LuaMadeSimple::Lua& lua) -> int
    {
        lua_State* L = lua.get_lua_state();
        int previous = g_watchdog_ms;
        if (lua_gettop(L) >= 1 && !lua_isnil(L, 1)) g_watchdog_ms = static_cast<int>(luaL_checkinteger(L, 1));
        lua_settop(L, 0);
        lua_pushinteger(L, previous);
        return 1;
    }

    auto call_listener(const std::string& name, const Listener& l, uint32_t conn, const std::string& payload) -> void
    {
        lua_State* T = l.thread;
        lua_settop(T, 0);
        lua_rawgeti(T, LUA_REGISTRYINDEX, l.fn_ref);
        lua_pushinteger(T, conn);
        lua_pushlstring(T, payload.data(), payload.size());
        if (guarded_pcall(T, 2, 0) != LUA_OK)
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
            if (guarded_pcall(T, 1, 0) != LUA_OK)
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

    // A listener returning false blocks the call (the UFunction never runs, which
    // for a client's RPC means the server ignores it); returning a string writes
    // it over the parameters, so later listeners and the function see the change.
    // Returns whether the call was blocked.
    auto on_process_event(UObject* context, UFunction* function, void* parms) -> bool
    {
        if (t_in_call_hook) return false;
        std::vector<Listener> listeners;
        {
            std::lock_guard lock{g_call_hooks_mutex};
            if (g_call_hooks.empty()) return false;
            auto it = g_call_hooks.find(function);
            if (it == g_call_hooks.end()) return false;
            listeners = it->second;
        }
        t_in_call_hook = true;
        bool blocked = false;
        auto size = static_cast<size_t>(function->GetParmsSize());
        for (auto& l : listeners)
        {
            lua_State* T = l.thread;
            lua_settop(T, 0);
            lua_rawgeti(T, LUA_REGISTRYINDEX, l.fn_ref);
            LuaType::auto_construct_object(*l.lua, context);
            lua_pushlstring(T, parms ? static_cast<const char*>(parms) : "", parms ? size : 0);
            if (guarded_pcall(T, 2, 1) != LUA_OK)
            {
                Output::send<LogLevel::Error>(STR("[BrickadiaBridge] __on_call {}: {}\n"), function->GetFullName(), ensure_str(std::string{lua_tostring(T, -1)}));
            }
            else if (lua_isboolean(T, -1) && !lua_toboolean(T, -1))
            {
                blocked = true;
            }
            else if (lua_type(T, -1) == LUA_TSTRING && parms)
            {
                size_t len{};
                const char* bytes = lua_tolstring(T, -1, &len);
                std::memcpy(parms, bytes, std::min(len, size));
            }
            lua_settop(T, 0);
        }
        t_in_call_hook = false;
        return blocked;
    }

    // Delegate bindings. A dynamic multicast delegate (the game mode's
    // OnRoundStart, OnPlayerJoined, ...) calls each bound object's UFunction
    // through ProcessEvent with the delegate's parameters. Lua can't make a
    // UFunction, so each binding gets a dummy object of its own, bound by a
    // function every object has (ExecuteUbergraph). The ProcessEvent hook knows
    // the dummy, hands the parameters to Lua and stops the call, so nothing runs
    // on the dummy itself. Dummies are in the root set, or the garbage
    // collector would take them and the binding would quietly go dead.
    struct DelegateBinding
    {
        int64_t id;
        FWeakObjectPtr owner;
        FMulticastDelegateProperty* property;
        UObject* dummy;
        // SetRootSet doesn't keep the dummy alive on this engine (a world load's
        // garbage collection frees it), so it is only touched through this
        FWeakObjectPtr dummy_alive;
        size_t parms_size;
        Listener listener;
    };
    std::mutex g_delegates_mutex;
    std::unordered_map<UObject*, DelegateBinding> g_delegates;
    int64_t g_next_delegate_id = 1;
    const auto DUMMY_FUNCTION = STR("ExecuteUbergraph");

    // the delegate binding a ProcessEvent is for, if any: call its listener with
    // the parameters; returns whether the call was one of ours
    auto on_delegate_call(UObject* context, void* parms) -> bool
    {
        Listener listener;
        size_t size;
        {
            std::lock_guard lock{g_delegates_mutex};
            if (g_delegates.empty()) return false;
            auto it = g_delegates.find(context);
            if (it == g_delegates.end()) return false;
            // a freed dummy's address can come back as another object
            if (it->second.dummy_alive.Get() != context) return false;
            listener = it->second.listener;
            size = it->second.parms_size;
        }
        lua_State* T = listener.thread;
        lua_settop(T, 0);
        lua_rawgeti(T, LUA_REGISTRYINDEX, listener.fn_ref);
        lua_pushlstring(T, parms ? static_cast<const char*>(parms) : "", parms ? size : 0);
        if (guarded_pcall(T, 1, 0) != LUA_OK)
        {
            Output::send<LogLevel::Error>(STR("[BrickadiaBridge] delegate: {}\n"), ensure_str(std::string{lua_tostring(T, -1)}));
        }
        lua_settop(T, 0);
        return true;
    }

    std::unordered_map<UFunction*, std::vector<Listener>> g_after_hooks;
    bool g_after_hook_installed = false;
    // calls the pre-hook stopped, innermost last: the post callback still comes
    // for them, and after-listeners must not see a call that never ran
    thread_local std::vector<std::pair<UObject*, UFunction*>> t_blocked;

    auto on_process_event_after(UObject* context, UFunction* function, void* parms) -> void
    {
        if (!t_blocked.empty() && t_blocked.back() == std::pair{context, function})
        {
            t_blocked.pop_back();
            return;
        }
        if (t_in_call_hook) return;
        std::vector<Listener> listeners;
        {
            std::lock_guard lock{g_call_hooks_mutex};
            if (g_after_hooks.empty()) return;
            auto it = g_after_hooks.find(function);
            if (it == g_after_hooks.end()) return;
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
            if (guarded_pcall(T, 2, 1) != LUA_OK)
            {
                Output::send<LogLevel::Error>(STR("[BrickadiaBridge] __on_call_after {}: {}\n"), function->GetFullName(), ensure_str(std::string{lua_tostring(T, -1)}));
            }
            else if (parms && lua_type(T, -1) == LUA_TSTRING)
            {
                // the call is over, so what the caller reads next is this buffer:
                // bytes of the same size replace the return value and out
                // parameters (anything the old bytes owned is the listener's to free)
                size_t len = 0;
                const char* bytes = lua_tolstring(T, -1, &len);
                if (len == size) std::memcpy(parms, bytes, size);
            }
            lua_settop(T, 0);
        }
        t_in_call_hook = false;
    }

    auto ensure_process_event_hook() -> void
    {
        if (g_call_hook_installed) return;
        g_call_hook_installed = true;
        // not read-only, so a listener can stop the call
        Hook::RegisterProcessEventPreCallback(
                [](auto& info, UObject* context, UFunction* function, void* parms) {
                    if (on_delegate_call(context, parms) || on_process_event(context, function, parms))
                    {
                        info.PreventOriginalFunctionCall();
                        if (g_after_hook_installed) t_blocked.emplace_back(context, function);
                    }
                },
                {false, false, STR("BrickadiaBridge"), STR("OnCall")});
    }

    auto ensure_after_hook() -> void
    {
        if (g_after_hook_installed) return;
        g_after_hook_installed = true;
        Hook::RegisterProcessEventPostCallback(
                [](auto&, UObject* context, UFunction* function, void* parms) { on_process_event_after(context, function, parms); },
                {false, true, STR("BrickadiaBridge"), STR("AfterCall")});
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
            ensure_process_event_hook();
        }
        lua_settop(L, 0);
        return 0;
    }

    auto lua_on_call_after(const LuaMadeSimple::Lua& lua) -> int
    {
        lua_State* L = lua.get_lua_state();
        std::string path = luaL_checkstring(L, 1);
        luaL_checktype(L, 2, LUA_TFUNCTION);
        auto* fn = find_function(path);
        if (!fn) luaL_error(L, "__on_call_after: no UFunction %s", path.c_str());
        Listener listener = make_listener(lua, 2);
        {
            std::lock_guard lock{g_call_hooks_mutex};
            g_after_hooks[fn].push_back(listener);
            // the pre-hook records the calls it blocks, so it must be there too
            ensure_process_event_hook();
            ensure_after_hook();
        }
        lua_settop(L, 0);
        return 0;
    }

    // __delegate_bind(owner, property, fn) -> id, signature path: fn(params) whenever
    // the owner's multicast delegate `property` is broadcast; `params` are the
    // signature function's parameter bytes (__fn_layout(signature path) has offsets)
    auto lua_delegate_bind(const LuaMadeSimple::Lua& lua) -> int
    {
        UObject* owner = lua.get_userdata<LuaType::UObject>().get_remote_cpp_object();
        lua_State* L = lua.get_lua_state();
        std::string name = luaL_checkstring(L, 1);
        luaL_checktype(L, 2, LUA_TFUNCTION);
        if (!owner) luaL_error(L, "__delegate_bind: no owner");
        FMulticastDelegateProperty* property = nullptr;
        for (FProperty* p : owner->GetClassPrivate()->ForEachPropertyInChain())
        {
            if (to_utf8_string(p->GetName()) != name) continue;
            property = CastField<FMulticastDelegateProperty>(p);
            break;
        }
        if (!property) luaL_error(L, "__delegate_bind: %s has no multicast delegate %s", to_utf8_string(owner->GetClassPrivate()->GetName()).c_str(), name.c_str());
        UFunction* signature = property->GetSignatureFunction().Get();
        auto* dummy_class = UObjectGlobals::StaticFindObject<UClass*>(nullptr, nullptr, STR("/Script/Engine.SceneComponent"));
        if (!signature || !dummy_class) luaL_error(L, "__delegate_bind: no signature or dummy class");
        // an object needs an outer; the class's own package keeps the dummy out of
        // every actor (a component made inside an actor would join its
        // components), and RF_Transient keeps it out of any save
        UObject* package = dummy_class->GetOuterPrivate();
        UObject* dummy = UObjectGlobals::NewObject<UObject>(package, dummy_class, NAME_None, RF_Transient);
        if (!dummy) luaL_error(L, "__delegate_bind: could not make the dummy object");
        dummy->SetRootSet();
        Listener listener = make_listener(lua, 2);
        FScriptDelegate delegate;
        delegate.BindUFunction(dummy, FName{DUMMY_FUNCTION, FNAME_Add});
        property->AddDelegate(delegate, owner);
        int64_t id;
        {
            std::lock_guard lock{g_delegates_mutex};
            id = g_next_delegate_id++;
            g_delegates.emplace(dummy, DelegateBinding{id, FWeakObjectPtr{owner}, property, dummy, FWeakObjectPtr{dummy}, static_cast<size_t>(signature->GetParmsSize()), listener});
            ensure_process_event_hook();
        }
        lua_settop(L, 0);
        lua_pushinteger(L, id);
        auto path = to_utf8_string(signature->GetFullName());
        // GetFullName is "Function /Script/...", __fn_layout wants the path alone
        if (auto space = path.find(' '); space != std::string::npos) path = path.substr(space + 1);
        lua_pushlstring(L, path.data(), path.size());
        return 2;
    }

    // __delegate_unbind(id): remove a binding (a gone owner took it with it)
    auto lua_delegate_unbind(const LuaMadeSimple::Lua& lua) -> int
    {
        auto id = lua.get_integer();
        std::lock_guard lock{g_delegates_mutex};
        for (auto it = g_delegates.begin(); it != g_delegates.end(); ++it)
        {
            if (it->second.id != id) continue;
            UObject* dummy = it->second.dummy_alive.Get();
            if (UObject* owner = it->second.owner.Get(); owner && dummy)
            {
                FScriptDelegate delegate;
                delegate.BindUFunction(dummy, FName{DUMMY_FUNCTION, FNAME_Add});
                it->second.property->RemoveDelegate(delegate, owner);
            }
            if (dummy) dummy->ClearRootSet();
            release(it->second.listener);
            g_delegates.erase(it);
            break;
        }
        return 0;
    }

    auto register_all(const LuaMadeSimple::Lua& lua) -> void
    {
        lua.register_function("__on_call", lua_on_call);
        lua.register_function("__on_call_after", lua_on_call_after);
        lua.register_function("__watchdog", lua_watchdog);
        lua.register_function("__clock", lua_clock);
        lua.register_function("__delegate_bind", lua_delegate_bind);
        lua.register_function("__delegate_unbind", lua_delegate_unbind);
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
        lua.register_function("__voice_route", lua_voice_route);
        lua.register_function("__voice_capture", lua_voice_capture);
        lua.register_function("__voice_take", lua_voice_take);
        lua.register_function("__custom_event_capture", lua_custom_event_capture);
        lua.register_function("__custom_event_take", lua_custom_event_take);
        lua.register_function("__custom_event_post", lua_custom_event_post);
        lua.register_function("__tx_append", lua_tx_append);
        lua.register_function("__tx_finish", lua_tx_finish);
        lua.register_function("__permission_set", lua_permission_set);
        lua.register_function("__permission_clear", lua_permission_clear);
        lua.register_function("__permission_trace", lua_permission_trace);
        lua.register_function("__permission_trace_take", lua_permission_trace_take);
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
            {
                std::lock_guard lock{g_delegates_mutex};
                for (auto it = g_delegates.begin(); it != g_delegates.end();)
                {
                    if (it->second.listener.main != main)
                    {
                        ++it;
                        continue;
                    }
                    UObject* dummy = it->second.dummy_alive.Get();
                    if (UObject* owner = it->second.owner.Get(); owner && dummy)
                    {
                        FScriptDelegate delegate;
                        delegate.BindUFunction(dummy, FName{DUMMY_FUNCTION, FNAME_Add});
                        it->second.property->RemoveDelegate(delegate, owner);
                    }
                    if (dummy) dummy->ClearRootSet();
                    it = g_delegates.erase(it);
                }
            }
            std::lock_guard lock{g_call_hooks_mutex};
            for (auto& [fn, list] : g_call_hooks)
            {
                std::erase_if(list, [main](const Listener& l) { return l.main == main; });
            }
            for (auto& [fn, list] : g_after_hooks)
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
