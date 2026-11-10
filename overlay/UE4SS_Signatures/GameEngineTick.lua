-- UGameEngine::Tick(float DeltaSeconds, bool bIdleMode). Spills bIdleMode and this,
-- then tests DeltaSeconds < 0.
-- Brickadia Linux dedicated server, verified on Release-EA3-CL-16507.
function Register()
    return "55 41 57 41 56 41 55 41 54 53 48 81 EC ?? ?? 00 00 89 74 24 ?? 48 89 7C 24 ?? C5 E8 57 D2 C5 F8 2E D0"
end

function OnMatchFound(MatchAddress)
    return MatchAddress
end
