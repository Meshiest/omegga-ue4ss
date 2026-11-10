-- GNatives, the opcode table ProcessLocalScriptFunction's loop calls through:
-- `lea r13,[rip+GNatives]` right after the EX_Return test.
-- Brickadia Linux dedicated server, verified on Release-EA3-CL-16507.
function Register()
    return "48 8B 46 20 80 38 04 74 ?? 4C 8D 2D ?? ?? ?? ??"
end

function OnMatchFound(MatchAddress)
    -- RIP-relative operand of the instruction at +9
    local Insn = MatchAddress + 9
    return Insn + 7 + DerefToInt32(Insn + 3)
end
