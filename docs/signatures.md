# Signatures and vtable offsets

UE4SS needs the addresses of a few engine functions and globals, and the vtable slots of a
few virtuals. The server binary is stripped, so they come from byte patterns (AOBs) in
`overlay/UE4SS_Signatures/` and exact offsets in `overlay/VTableOffsets.linux.ini`. A game
update can move or reshape any of them, so the plugin checks them against the exact binary on
every start (`src/verify.ts`, `src/vtables.ts`), in about 1.5 s.

## Two independent resolvers per symbol

For each signature file the plugin finds the symbol twice:

1. **AOB**, as UE4SS will: scan `.text`, evaluate `OnMatchFound` for each hit, take the first.
2. **Anchor** (`src/resolvers.ts`), by what the code does rather than its bytes:

| Symbol | Anchor |
|--------|--------|
| CallFunctionByNameWithArguments | the only `mov eax, 0x200 (FUNC_Exec); and eax, [reg+0xB0]` (UFunction::FunctionFlags) |
| ProcessLocalScriptFunction | `mov rax, [rsi+0x20] (Stack.Code); cmp byte [rax], 4 (EX_Return)` near the entry |
| GNatives | the `lea` into the opcode table right after that compare |
| GameEngineTick | the only function referencing `u"causeevent="` |
| StaticConstructObject | the most-called big-frame (`sub rsp, 0x2xx`) target after inlined `u"NewObject with empty name can't..."` checks |
| FName_Constructor | the most-called target of `lea rdi, <UTF-16 literal>; mov esi, len; mov edx, 1; call` |
| FName_ToString | the first 0x8xx-frame function after the FName helper that indexes the name pool by `idx >> 16` |
| GMalloc | the global `operator new[]` (exported `_Znam`) loads: `mov rdi, [rip+GMalloc]` |
| GUObjectArray | the GC's `NumElements - (EstimateCount + FirstGCIndex)`, NumElements at `+8` |
| ConsoleManager | the global null-tested most often (`mov rdi, [rip+X]; test rdi, rdi`): every cvar registration |

Function boundaries come from `.eh_frame_hdr`, which stripping keeps: it lists every function
entry (about 317,000), so "the function containing this anchor" is exact.

An address is **plausible** when a function symbol lands exactly on a function entry and a
global lands in a writable segment.

## Outcomes

| Status | When | What UE4SS gets |
|--------|------|-----------------|
| verified | both agree on a plausible address | the shipped AOB |
| corrected | AOB misses or is implausible, the anchor is plausible | a pinned file: `return 0x<address>` |
| unverified | only the AOB is plausible | the shipped AOB, with a warning |
| conflict | both plausible, different addresses | nothing (treated as unresolved) |
| unresolved | neither | nothing |

A conflict is not "corrected" on purpose: when the two disagree, pinning the wrong one hooks
the wrong function. This caught a real bug: an early FName anchor counted ANSI literals too and
picked the ANSI twin of the helper; the AOB was right.

UE4SS starts only if the required symbols (GUObjectArray, GMalloc, StaticConstructObject,
FName_Constructor, GameEngineTick) are usable. Pinned files work because the binary is
non-PIE: an address is the same on every run of that binary, and the ready marker ties it to
that binary.

## Vtable offsets

UE4SS calls and hooks virtuals by slot. Three are checked in the UGameEngine vtable (the one
holding the verified GameEngineTick):

| Offset | Check |
|--------|-------|
| `UEngine.Tick = 0x308` | slot 97 holds GameEngineTick |
| `UObject.ProcessConsoleExec = 0x278` | slot 79 is a thunk that jumps into CallFunctionByNameWithArguments (its whole body) |
| `UObject.ProcessEvent = 0x260` | slot 76 starts with `mov eax, [rdi+0xC]` and compares it with `GUObjectArray+8`: ProcessEvent validating `this` |

Any failed check disables UE4SS for that start.

## Builds checked

| Build | Signatures | Vtables |
|-------|-----------|---------|
| Release-EA3-CL-16507 | 10 verified | 3 verified |
| Release-EA3-CL-15729 | 10 verified | 3 verified |

## After a game update

```sh
npm run verify -- <steam>/Brickadia/Binaries/Linux/BrickadiaServer-Linux-Shipping
```

- All `verified`: nothing to do.
- `corrected`: it works (pinned at every start), but refresh that AOB so the shipped set stays
  honest. The pinned address is the function entry; take the bytes there, wildcard rel32
  operands and stack offsets that tend to move, and check with `npm run verify` that it's
  unique and agrees.
- `conflict`, `unresolved` or a failed vtable check: UE4SS stays off. Investigate before
  shipping; the research notes describe how each anchor was found.

`GAME_BINARY=<binary> npm test` also runs a drift test that breaks an AOB on purpose and
checks that it gets corrected.
