-- &ConsoleManagerSingleton. Every cvar registration does
-- `if (!Singleton) SetupSingleton();` so the pattern hits thousands of times, all
-- resolving to the same global.
-- Brickadia Linux dedicated server, verified on Release-EA3-CL-16507.
function Register()
    return "48 8B 3D ?? ?? ?? ?? 48 85 FF 75 ?? E8 ?? ?? ?? ?? 48 8B 3D ?? ?? ?? ?? 48 85 FF"
end

function OnMatchFound(MatchAddress)
    -- RIP-relative operand of the instruction at +0
    local Insn = MatchAddress + 0
    return Insn + 7 + DerefToInt32(Insn + 3)
end
