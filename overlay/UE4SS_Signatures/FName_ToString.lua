-- FName::ToString(FString& Out) const. 0x818 frame (FNameEntry name buffer); lazily
-- initialises the name pool, then indexes it by ComparisonIndex >> 16.
-- Brickadia Linux dedicated server, verified on Release-EA3-CL-16507 (1 hit). An older build
-- has two functions with this exact body (ToString and a sibling, likely AppendString);
-- UE4SS takes the first, which is the right one there only if the sibling sorts later.
function Register()
    return "55 41 57 41 56 41 55 41 54 53 48 81 EC ?? 08 00 00 48 89 F3 49 89 ?? 44 8B ?? 80 3D ?? ?? ?? ?? 00 75 ?? 48 8D 3D ?? ?? ?? ?? E8 ?? ?? ?? ?? C6 05 ?? ?? ?? ?? 01 44 89 ?? C1 E8 10"
end

function OnMatchFound(MatchAddress)
    return MatchAddress
end
