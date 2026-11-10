-- ProcessLocalScriptFunction(Context, Stack, RESULT_DECL): loads Stack.Node (+0x10)
-- and Stack.Code (+0x20), then compares the opcode with EX_Return (4).
-- Brickadia Linux dedicated server, verified on Release-EA3-CL-16507.
function Register()
    return "55 41 57 41 56 41 55 41 54 53 48 83 EC ?? 48 89 D3 49 89 F6 4C 8B 66 10 48 8B 46 20 80 38 04"
end

function OnMatchFound(MatchAddress)
    return MatchAddress
end
