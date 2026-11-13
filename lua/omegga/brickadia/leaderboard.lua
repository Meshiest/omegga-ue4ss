-- BR.leaderboard: Leaderboard values on players and teams.
local I = require("omegga.brickadia.internal")
local BR = I.BR
local leaderboard = {}

-- Leaderboard values are Int64s by name, on a PlayerState or a team.

function leaderboard.get(target, name) return target:GetLeaderboardValue(FName(name)) end

function leaderboard.set(target, name, value) target:SetLeaderboardValue(FName(name), value) end

function leaderboard.add(target, name, delta) target:IncLeaderboardValue(FName(name), delta) end

return leaderboard
