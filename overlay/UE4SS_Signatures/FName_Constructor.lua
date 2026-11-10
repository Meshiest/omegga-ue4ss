-- FNameHelper::MakeDetectNumber(FNameStringView, EFindName), not FName::FName: the
-- constructor from const TCHAR* is inlined everywhere in this build, and every call
-- site passes (chars, Len | bIsWide << 32, FindType) here and takes the FName from rax.
-- Needs `FNameConstructorABI = StringView` in [General] of UE4SS-settings.ini.
-- 0x400 frame, then the empty-name test and the UTF-16 digit scan from the end
-- (`lea rax,[rcx+rcx]`: 2-byte chars; the ANSI twin indexes by byte).
-- Brickadia Linux dedicated server, verified on Release-EA3-CL-16507.
function Register()
    return "41 57 41 56 53 48 81 EC 00 04 00 00 85 F6 0F 84 ?? ?? ?? ?? 48 63 CE 48 8D 04 09"
end

function OnMatchFound(MatchAddress)
    return MatchAddress
end
