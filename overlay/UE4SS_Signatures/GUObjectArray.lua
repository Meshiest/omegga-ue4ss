-- &GUObjectArray, from the GC setting GObjectCountDuringLastMarkPhase to
-- ObjObjects.NumElements (+0x8) - (ObjAvailableListEstimateCount + ObjFirstGCIndex).
-- The first operand is NumElements, so the global is 8 bytes before it.
-- Brickadia Linux dedicated server, verified on Release-EA3-CL-16507.
function Register()
    return "8B 05 ?? ?? ?? ?? 8B 0D ?? ?? ?? ?? 03 0D ?? ?? ?? ?? 29 C8 87 05"
end

function OnMatchFound(MatchAddress)
    return MatchAddress + 6 + DerefToInt32(MatchAddress + 2) - 8
end
