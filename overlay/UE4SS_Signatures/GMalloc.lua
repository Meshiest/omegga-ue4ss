-- &GMalloc, from operator new[] (_Znam): `mov rdi,[rip+GMalloc]; test rdi,rdi; je;
-- jmp [vtable+0x30]` (FMalloc::Malloc is Itanium slot 6). Ends at the `je`: an older
-- build dispatched through `mov rax,[rax+0x30]; jmp rax` instead.
-- Brickadia Linux dedicated server, verified on Release-EA3-CL-16507.
function Register()
    return "48 83 FF 09 0F 93 C0 8D 14 C5 08 00 00 00 48 8B 3D ?? ?? ?? ?? 48 85 FF 74"
end

function OnMatchFound(MatchAddress)
    -- RIP-relative operand of the instruction at +14
    local Insn = MatchAddress + 14
    return Insn + 7 + DerefToInt32(Insn + 3)
end
