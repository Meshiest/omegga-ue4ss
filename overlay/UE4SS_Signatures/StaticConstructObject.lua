-- StaticConstructObject_Internal(const FStaticConstructObjectParameters&): reads
-- Class, Outer, SetFlags, Template and the 0x70 flags field off rdi up front.
-- Brickadia Linux dedicated server, verified on Release-EA3-CL-16507.
function Register()
    return "55 41 57 41 56 41 55 41 54 53 48 81 EC ?? 02 00 00 48 89 FB 4C 8B 37 48 8B 77 08 8B 4F 18 4C 8B 6F 28"
end

function OnMatchFound(MatchAddress)
    return MatchAddress
end
