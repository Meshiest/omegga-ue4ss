-- UObject::CallFunctionByNameWithArguments(Cmd, Ar, Executor, bForceCallWithNonExec).
-- SysV args land in rdi/rsi/rdx/rcx/r8 and are parked in r15/[rbp-0x80]/r12/r13/r14.
-- Brickadia Linux dedicated server, verified on Release-EA3-CL-16507. Stops before the spill
-- of Cmd (rsi): its frame slot differs between builds ([rbp-0x90] in an older one).
function Register()
    return "55 48 89 E5 41 57 41 56 41 55 41 54 53 48 81 EC ?? ?? 00 00 45 89 C6 49 89 CD 49 89 D4 49 89 FF 48 89"
end

function OnMatchFound(MatchAddress)
    return MatchAddress
end
