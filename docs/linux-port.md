# Running UE4SS on the Linux server

Upstream UE4SS is Windows-only. This plugin builds tc-imba's Linux port
([RE-UE4SS PR #1342](https://github.com/UE4SS-RE/RE-UE4SS/pull/1342), branch `linux-port` of
`tc-imba/RE-UE4SS`, with `tc-imba/UEPseudo` and `tc-imba/patternsleuth`) at the commits in
`native/patches/*.base`, plus `native/patches/`. `native/build.sh` does it all. The port loads
UE4SS with `LD_PRELOAD` (`run_ue4ss.sh`), headless, and runs Lua and C++ (`.so`) mods. It was
validated on Palworld (UE 5.1); Brickadia is a custom UE 5.8 fork, and UE4SS knows up to 5.7.

## The server binary

- Non-PIE x86-64 ELF at `0x200000`, stripped (no `.symtab`, no `.debug_*`), cross-compiled
  with clang, no RTTI. `.eh_frame_hdr` remains and lists every function.
- `TCHAR` is UTF-16. `.rodata` is a merged-strings section, so a short literal can be the tail
  of a longer one (`u"Engine"` inside `u"GameEngine"`).
- Exports: ISPC kernels, mimalloc, `operator new/delete` (snmalloc behind `FMemory`), a few C
  libraries. The engine itself exports nothing.
- Crash reports: Brickadia's switch
  `-AllowCustomArchivesAndDisableCrashReporterForVersion=CL<changelist>` turns uploads off (checked in the
  crash-report path and in pak signature checks, so it also allows unsigned paks); the value
  must be the running binary's changelist with the `CL` prefix, or it logs "does not match this
  build" and changes nothing.

## What had to change

### FName construction (UEPseudo patch)

There is no callable `FName::FName(const TCHAR*, EFindName)`: the compiler inlined it
everywhere. Callers compute the length and call
`FName FNameHelper::MakeDetectNumber(const TCHAR* chars, uint64 lenAndWide, EFindName)` with
`lenAndWide = charCount | (anyCharAbove0x7F << 32)`, the FName returned in `rax`. The port types
the constructor as `void(FName* this, const TCHAR*, EFindName)`, which would pass the string as
`this`; its verification detour would also drop `rax` for every FName made while hooked.

Patch: `[General] FNameConstructorABI = StringView` makes UEPseudo compute the view, call the
helper and take `rax`, and skips the detour verification. `FName_Constructor.lua` points at the
helper.

### Vtable offsets (RE-UE4SS patch + data)

The port derives Linux slots as "MSVC offset + 8 after the destructor" (Itanium has two
destructor slots). That holds for `UEngine::Tick` (Windows 96 → Linux 97) but not for
`UObject::ProcessEvent` (Windows 79 → Linux 76). Patch: an exact-offset file,
`VTableOffsets.linux.ini` (`Class.Function = 0xOFFSET`, true Itanium offsets), applied after
`VTableLayout.ini`. Only verified slots are listed, and hooks on unverified slots are off in
the settings. See [signatures.md](signatures.md#vtable-offsets).

### FProperty layout (data)

Itanium reuses `FField`'s 4 bytes of tail padding, so `FProperty::ArrayDim`/`ElementSize` are
at `0x2C`/`0x30`, not the Windows `0x30`/`0x34`. With the Windows values every TArray read
`ElementSize` from padding (0) and repeated its first element. The port applies this shift
only for engine <= 5.2; `overlay/MemberVariableLayout.ini` sets it for this build. The rest of
the Windows member layout checked out.

### Allocators (bridge native mod)

The server exports `operator new/delete`, and the executable comes first in symbol lookup.
`libUE4SS.so` links libstdc++ statically with `-Bsymbolic` (libc heap). A C++ mod linked the
usual way binds `new`/`delete` to the game's snmalloc instead, and a string allocated in one
module and freed in the other aborts: "snmalloc heap corruption: Not allocated by snmalloc".
`native/BrickadiaBridge/src/allocator.cpp` defines them over `malloc`, linked `-Bsymbolic`.
Any C++ mod for this server needs the same.

### Build (clang 18)

- glaze needs `std::expected`, which libstdc++ only exposes when `__cpp_concepts >= 202002`;
  clang 18 reports 201907 although it compiles the code. The build defines it.
- `Helpers/Time.cpp` formats a `local_t` time point, which fmt can't with this libstdc++; the
  patch reformats it as a `sys_time`.
- `UE4SS_EXTRA_CPPMODS` (patch) builds out-of-tree C++ mods against the UE4SS target.
- `GenerateLuaTypes()` appended `\\Mods\\shared\\types` to the working directory as a string,
  which on Linux makes one folder named `UE4SS\Mods\shared\types`; the patch joins it as a path.

## UE4SS behaviour to know

- Methods on an invalid UObject dereference null and crash the server (`pcall` doesn't help).
- A UFunction's `TArray` return value arrives as a plain table, and was wrong here (the first
  element repeated); read arrays from properties instead.
- LuaMadeSimple's `get_string` stops at the first NUL, so the native helpers read byte buffers
  with `lua_tolstring`.
- UE4SS's module loader caches modules in `ue4ss_loaded_modules` as well as `package.loaded`.
- Each Lua mod is its own Lua state; `LoopAsync` and `ExecuteInGameThread` callbacks share that
  mod's globals.
- UE4SS builds Lua with `lua_lock`, so threads of one mod's state can run on different OS threads.
  A C++ mod that calls Lua must use a thread from LuaMadeSimple's `Lua::new_thread()`: every
  registered C function looks its caller up in LuaMadeSimple's table of states and raises
  "has no instance inside lua_instances" for a bare `lua_newthread`.
- C++ mods get the game thread through `Hook::RegisterEngineTickPreCallback` (`HookEngineTick = 1`);
  the bridge's socket dispatch runs there.
- The process doesn't exit after the engine shuts down with UE4SS loaded; it has to be killed.
- Console commands registered with UE4SS aren't reachable from the dedicated server's stdin.
