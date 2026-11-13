-- BR.math: Vectors, quaternions, rotators and angles in plain Lua, for code
-- that runs often (a tick, every player): no call into the engine. The
-- conventions are Unreal's, so results match KismetMathLibrary:
--
-- - Units are Unreal units, X forward, Y right, Z up (left-handed).
-- - A rotator is { Pitch, Yaw, Roll } in degrees, as the game's FRotator.
-- - Euler angles are a vector (Roll, Pitch, Yaw) in degrees, as FQuat::Euler.
-- - q1 * q2 is "q2, then q1", as FQuat's operator*.
--
-- Every constructor takes numbers, an array { x, y, z }, a table with X/Y/Z
-- fields (what the game hands Lua) or a value of the same type, so values from
-- BR (arrays) and from the game (X/Y/Z tables) both work. :ue() gives the
-- table a game function takes, :array() the array BR functions take.
local M = {}

local sqrt, sin, cos, acos, asin, atan, abs = math.sqrt, math.sin, math.cos, math.acos, math.asin, math.atan, math.abs
local D2R, R2D = math.pi / 180, 180 / math.pi

-- tolerances as Unreal's (UE_SMALL_NUMBER, UE_KINDA_SMALL_NUMBER)
local SMALL = 1e-8
local KINDA_SMALL = 1e-4

-- Angles ------------------------------------------------------------------------

M.D2R, M.R2D = D2R, R2D

function M.rad(deg) return deg * D2R end
function M.deg(rad) return rad * R2D end

--- An angle in degrees as (-180, 180], as FRotator::NormalizeAxis.
function M.normalize_angle(a)
    a = a % 360
    if a > 180 then a = a - 360 end
    return a
end

--- An angle in degrees as [0, 360), as FRotator::ClampAxis.
function M.clamp_angle(a) return a % 360 end

--- The shortest turn from angle a to angle b, in degrees, (-180, 180].
function M.delta_angle(a, b) return M.normalize_angle(b - a) end

--- From angle a towards angle b the short way, by t (0..1).
function M.lerp_angle(a, b, t) return M.normalize_angle(a + M.delta_angle(a, b) * t) end

function M.lerp(a, b, t) return a + (b - a) * t end

function M.clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

-- Vectors -----------------------------------------------------------------------

local Vec = {}
Vec.__index = Vec
M.Vec = Vec

local function vec_of(x, y, z)
    return setmetatable({ x = x, y = y, z = z }, Vec)
end

local function is_vec(v) return getmetatable(v) == Vec end

--- A vector from numbers (x, y, z; missing ones are 0), an array { x, y, z },
--- a table with X/Y/Z, or a vector (copied).
function M.vec(x, y, z)
    if type(x) == "table" then
        local t = x
        if is_vec(t) then return vec_of(t.x, t.y, t.z) end
        if t.X ~= nil then return vec_of(t.X, t.Y or 0, t.Z or 0) end
        return vec_of(t[1] or 0, t[2] or 0, t[3] or 0)
    end
    if x ~= nil and type(x) ~= "number" then error("BR.math.vec takes numbers or a table", 2) end
    return vec_of(x or 0, y or 0, z or 0)
end

local function V(v)
    if is_vec(v) then return v end
    return M.vec(v)
end

M.ZERO = vec_of(0, 0, 0)
M.FORWARD = vec_of(1, 0, 0)
M.RIGHT = vec_of(0, 1, 0)
M.UP = vec_of(0, 0, 1)

-- a number on either side scales; two vectors work per component
function Vec.__add(a, b) a, b = V(a), V(b) return vec_of(a.x + b.x, a.y + b.y, a.z + b.z) end
function Vec.__sub(a, b) a, b = V(a), V(b) return vec_of(a.x - b.x, a.y - b.y, a.z - b.z) end
function Vec.__unm(a) return vec_of(-a.x, -a.y, -a.z) end
function Vec.__mul(a, b)
    if type(a) == "number" then return vec_of(a * b.x, a * b.y, a * b.z) end
    if type(b) == "number" then return vec_of(a.x * b, a.y * b, a.z * b) end
    a, b = V(a), V(b)
    return vec_of(a.x * b.x, a.y * b.y, a.z * b.z)
end
function Vec.__div(a, b)
    if type(b) == "number" then return vec_of(a.x / b, a.y / b, a.z / b) end
    a, b = V(a), V(b)
    return vec_of(a.x / b.x, a.y / b.y, a.z / b.z)
end
function Vec.__eq(a, b) return a.x == b.x and a.y == b.y and a.z == b.z end
function Vec.__tostring(a) return string.format("vec(%g, %g, %g)", a.x, a.y, a.z) end

function Vec:dot(b) b = V(b) return self.x * b.x + self.y * b.y + self.z * b.z end
function Vec:cross(b)
    b = V(b)
    return vec_of(self.y * b.z - self.z * b.y, self.z * b.x - self.x * b.z, self.x * b.y - self.y * b.x)
end
function Vec:length_squared() return self.x * self.x + self.y * self.y + self.z * self.z end
function Vec:length() return sqrt(self:length_squared()) end
function Vec:length_2d() return sqrt(self.x * self.x + self.y * self.y) end
function Vec:distance(b) return (V(b) - self):length() end
function Vec:distance_squared(b) return (V(b) - self):length_squared() end

--- The unit vector, or the zero vector when this one is (nearly) zero, as
--- FVector::GetSafeNormal.
function Vec:normalized()
    local l2 = self:length_squared()
    if l2 < SMALL then return vec_of(0, 0, 0) end
    local inv = 1 / sqrt(l2)
    return vec_of(self.x * inv, self.y * inv, self.z * inv)
end

function Vec:is_zero(tolerance)
    tolerance = tolerance or KINDA_SMALL
    return abs(self.x) <= tolerance and abs(self.y) <= tolerance and abs(self.z) <= tolerance
end

function Vec:near(b, tolerance)
    b = V(b)
    tolerance = tolerance or KINDA_SMALL
    return abs(self.x - b.x) <= tolerance and abs(self.y - b.y) <= tolerance and abs(self.z - b.z) <= tolerance
end

function Vec:lerp(b, t) b = V(b) return vec_of(self.x + (b.x - self.x) * t, self.y + (b.y - self.y) * t, self.z + (b.z - self.z) * t) end

--- The angle to another vector, in degrees (0..180).
function Vec:angle_to(b)
    local d = self:length() * V(b):length()
    if d < SMALL then return 0 end
    return acos(M.clamp(self:dot(b) / d, -1, 1)) * R2D
end

--- This vector with the part along `normal` removed: its shadow on the plane.
function Vec:project_on_plane(normal)
    local n = V(normal):normalized()
    return self - n * self:dot(n)
end

--- This vector's part along `dir`.
function Vec:project_on(dir)
    local d = V(dir)
    local l2 = d:length_squared()
    if l2 < SMALL then return vec_of(0, 0, 0) end
    return d * (self:dot(d) / l2)
end

--- Bounced off a surface with this normal.
function Vec:reflect(normal)
    local n = V(normal):normalized()
    return self - n * (2 * self:dot(n))
end

--- The rotator facing along this vector (roll 0), as FVector::Rotation.
function Vec:rotator()
    return M.rot(atan(self.z, sqrt(self.x * self.x + self.y * self.y)) * R2D, atan(self.y, self.x) * R2D, 0)
end

--- The quaternion facing along this vector (roll 0).
function Vec:quat() return self:rotator():quat() end

function Vec:ue() return { X = self.x, Y = self.y, Z = self.z } end
function Vec:array() return { self.x, self.y, self.z } end
function Vec:unpack() return self.x, self.y, self.z end

-- Quaternions -------------------------------------------------------------------

local Quat = {}
Quat.__index = Quat
M.Quat = Quat

local function quat_of(x, y, z, w)
    return setmetatable({ x = x, y = y, z = z, w = w }, Quat)
end

local function is_quat(q) return getmetatable(q) == Quat end

--- A quaternion from numbers (x, y, z, w), an array { x, y, z, w }, a table with
--- X/Y/Z/W, or a quaternion (copied). No arguments: the identity.
function M.quat(x, y, z, w)
    if x == nil then return quat_of(0, 0, 0, 1) end
    if type(x) == "table" then
        local t = x
        if is_quat(t) then return quat_of(t.x, t.y, t.z, t.w) end
        if getmetatable(t) == M.Rot then return t:quat() end
        if t.W ~= nil then return quat_of(t.X, t.Y, t.Z, t.W) end
        return quat_of(t[1], t[2], t[3], t[4])
    end
    return quat_of(x, y, z, w)
end

local function Q(q)
    if is_quat(q) then return q end
    return M.quat(q)
end

M.IDENTITY = quat_of(0, 0, 0, 1)

--- The rotation of `angle` degrees about `axis` (made unit length).
function M.quat_axis_angle(axis, angle)
    local a = V(axis):normalized()
    local h = angle * D2R / 2
    local s = sin(h)
    return quat_of(a.x * s, a.y * s, a.z * s, cos(h))
end

--- From Euler angles in degrees: roll about X, pitch about Y, yaw about Z, or a
--- vector (Roll, Pitch, Yaw), as FQuat::MakeFromEuler.
function M.quat_euler(roll, pitch, yaw)
    if type(roll) == "table" then
        local e = V(roll)
        roll, pitch, yaw = e.x, e.y, e.z
    end
    return M.rot(pitch, yaw, roll):quat()
end

--- The shortest rotation taking direction a onto direction b, as
--- FQuat::FindBetweenVectors.
function M.quat_between(a, b)
    a, b = V(a), V(b)
    local norm = sqrt(a:length_squared() * b:length_squared())
    local w = norm + a:dot(b)
    local q
    if w >= 1e-6 * norm then
        local c = a:cross(b)
        q = quat_of(c.x, c.y, c.z, w)
    elseif abs(a.x) > abs(a.z) then
        -- opposite directions: half a turn about any axis perpendicular to a
        q = quat_of(-a.y, a.x, 0, 0)
    else
        q = quat_of(0, -a.z, a.y, 0)
    end
    return q:normalized()
end

--- The rotation facing along `forward`, with its up as close to `up` (default
--- world up) as that allows, as KismetMathLibrary's MakeRotFromXZ.
function M.quat_look(forward, up)
    local x = V(forward):normalized()
    if x:is_zero() then return quat_of(0, 0, 0, 1) end
    local zin = up and V(up):normalized() or M.UP
    local y = zin:cross(x):normalized()
    if y:is_zero() then
        -- looking straight along `up`: any roll will do
        return x:quat()
    end
    local z = x:cross(y)
    return M.quat_from_axes(x, y, z)
end

--- The rotation whose forward, right and up are these unit vectors (a rotation
--- matrix's columns), as FQuat's matrix constructor.
function M.quat_from_axes(x, y, z)
    x, y, z = V(x), V(y), V(z)
    -- the matrix's rows are the axes: M[i][j] = axis_i[j]
    local m00, m01, m02 = x.x, x.y, x.z
    local m10, m11, m12 = y.x, y.y, y.z
    local m20, m21, m22 = z.x, z.y, z.z
    local tr = m00 + m11 + m22
    local q
    if tr > 0 then
        local inv = 0.5 / sqrt(tr + 1)
        q = quat_of((m12 - m21) * inv, (m20 - m02) * inv, (m01 - m10) * inv, 0.25 / inv)
    elseif m00 > m11 and m00 > m22 then
        local s = 2 * sqrt(1 + m00 - m11 - m22)
        q = quat_of(0.25 * s, (m01 + m10) / s, (m02 + m20) / s, (m12 - m21) / s)
    elseif m11 > m22 then
        local s = 2 * sqrt(1 + m11 - m00 - m22)
        q = quat_of((m01 + m10) / s, 0.25 * s, (m12 + m21) / s, (m20 - m02) / s)
    else
        local s = 2 * sqrt(1 + m22 - m00 - m11)
        q = quat_of((m02 + m20) / s, (m12 + m21) / s, 0.25 * s, (m01 - m10) / s)
    end
    return q:normalized()
end

-- q1 * q2: q2's rotation, then q1's; q * v rotates the vector
function Quat.__mul(a, b)
    if is_vec(b) then return a:rotate(b) end
    a, b = Q(a), Q(b)
    return quat_of(
        a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
        a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
        a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
        a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z)
end
function Quat.__unm(a) return quat_of(-a.x, -a.y, -a.z, -a.w) end
function Quat.__eq(a, b) return a.x == b.x and a.y == b.y and a.z == b.z and a.w == b.w end
function Quat.__tostring(a) return string.format("quat(%g, %g, %g, %g)", a.x, a.y, a.z, a.w) end

function Quat:dot(b) b = Q(b) return self.x * b.x + self.y * b.y + self.z * b.z + self.w * b.w end
function Quat:length() return sqrt(self:dot(self)) end

--- Unit length; the identity when this one is (nearly) zero.
function Quat:normalized()
    local l2 = self:dot(self)
    if l2 < SMALL then return quat_of(0, 0, 0, 1) end
    local inv = 1 / sqrt(l2)
    return quat_of(self.x * inv, self.y * inv, self.z * inv, self.w * inv)
end

--- The opposite rotation (of a unit quaternion).
function Quat:inverse() return quat_of(-self.x, -self.y, -self.z, self.w) end

--- A vector turned by this rotation.
function Quat:rotate(v)
    v = V(v)
    -- v + 2w(q x v) + 2q x (q x v), in the form FQuat::RotateVector uses
    local qv = vec_of(self.x, self.y, self.z)
    local t = qv:cross(v) * 2
    return v + t * self.w + qv:cross(t)
end

--- A vector turned back by this rotation.
function Quat:unrotate(v) return self:inverse():rotate(v) end

function Quat:forward() return self:rotate(M.FORWARD) end
function Quat:right() return self:rotate(M.RIGHT) end
function Quat:up() return self:rotate(M.UP) end

--- The rotation angle in degrees (0..360).
function Quat:angle() return 2 * acos(M.clamp(self.w, -1, 1)) * R2D end

--- The rotation axis (unit), or X when there is (nearly) no rotation.
function Quat:axis()
    local s = sqrt(math.max(1 - self.w * self.w, 0))
    if s >= KINDA_SMALL then return vec_of(self.x / s, self.y / s, self.z / s) end
    return vec_of(1, 0, 0)
end

--- The axis and the angle in degrees.
function Quat:axis_angle() return self:axis(), self:angle() end

--- The angle in degrees between two rotations (0..180), as FQuat::AngularDistance.
function Quat:angle_to(b)
    local d = self:dot(b)
    return acos(M.clamp(2 * d * d - 1, -1, 1)) * R2D
end

--- From this rotation towards b the short way, by t (0..1), as FQuat::Slerp.
function Quat:slerp(b, t)
    b = Q(b)
    local c = self:dot(b)
    local sign = 1
    if c < 0 then c, sign = -c, -1 end
    local s1, s2
    if c < 0.9999 then
        local omega = acos(c)
        local inv = 1 / sin(omega)
        s1, s2 = sin((1 - t) * omega) * inv, sin(t * omega) * inv
    else
        -- nearly the same rotation: a straight blend is as good and stays finite
        s1, s2 = 1 - t, t
    end
    s2 = s2 * sign
    return quat_of(s1 * self.x + s2 * b.x, s1 * self.y + s2 * b.y, s1 * self.z + s2 * b.z, s1 * self.w + s2 * b.w):normalized()
end

--- As a rotator, as FQuat::Rotator.
function Quat:rotator()
    local x, y, z, w = self.x, self.y, self.z, self.w
    local singularity = z * x - w * y
    local yaw_y, yaw_x = 2 * (w * z + x * y), 1 - 2 * (y * y + z * z)
    -- Unreal's threshold, where pitch is taken as straight up or down
    local THRESHOLD = 0.4999995
    local yaw = atan(yaw_y, yaw_x) * R2D
    if singularity < -THRESHOLD then
        return M.rot(-90, yaw, M.normalize_angle(-yaw - 2 * atan(x, w) * R2D))
    elseif singularity > THRESHOLD then
        return M.rot(90, yaw, M.normalize_angle(yaw - 2 * atan(x, w) * R2D))
    end
    return M.rot(asin(2 * singularity) * R2D, yaw, atan(-2 * (w * x + y * z), 1 - 2 * (x * x + y * y)) * R2D)
end

--- Euler angles in degrees, vec(Roll, Pitch, Yaw), as FQuat::Euler.
function Quat:euler() return self:rotator():euler() end

function Quat:ue() return { X = self.x, Y = self.y, Z = self.z, W = self.w } end
function Quat:array() return { self.x, self.y, self.z, self.w } end
function Quat:unpack() return self.x, self.y, self.z, self.w end

-- Rotators ----------------------------------------------------------------------

local Rot = {}
Rot.__index = Rot
M.Rot = Rot

--- A rotator from degrees (pitch, yaw, roll), a table with Pitch/Yaw/Roll, or
--- an array { pitch, yaw, roll }.
function M.rot(pitch, yaw, roll)
    if type(pitch) == "table" then
        local t = pitch
        if t.Pitch ~= nil or t.Yaw ~= nil or t.Roll ~= nil then
            pitch, yaw, roll = t.Pitch, t.Yaw, t.Roll
        else
            pitch, yaw, roll = t[1], t[2], t[3]
        end
    end
    return setmetatable({ Pitch = pitch or 0, Yaw = yaw or 0, Roll = roll or 0 }, Rot)
end

function Rot.__add(a, b) b = M.rot(b) return M.rot(a.Pitch + b.Pitch, a.Yaw + b.Yaw, a.Roll + b.Roll) end
function Rot.__sub(a, b) b = M.rot(b) return M.rot(a.Pitch - b.Pitch, a.Yaw - b.Yaw, a.Roll - b.Roll) end
function Rot.__mul(a, b)
    if type(a) == "number" then a, b = b, a end
    return M.rot(a.Pitch * b, a.Yaw * b, a.Roll * b)
end
function Rot.__unm(a) return M.rot(-a.Pitch, -a.Yaw, -a.Roll) end
function Rot.__tostring(a) return string.format("rot(P=%g, Y=%g, R=%g)", a.Pitch, a.Yaw, a.Roll) end

--- As a quaternion, as FRotator::Quaternion.
function Rot:quat()
    local h = D2R / 2
    local sp, cp = sin(self.Pitch * h), cos(self.Pitch * h)
    local sy, cy = sin(self.Yaw * h), cos(self.Yaw * h)
    local sr, cr = sin(self.Roll * h), cos(self.Roll * h)
    return quat_of(
        cr * sp * sy - sr * cp * cy,
        -cr * sp * cy - sr * cp * sy,
        cr * cp * sy - sr * sp * cy,
        cr * cp * cy + sr * sp * sy)
end

--- The direction it faces (unit), as FRotator::Vector.
function Rot:forward()
    local p, y = self.Pitch * D2R, self.Yaw * D2R
    local cp = cos(p)
    return vec_of(cp * cos(y), cp * sin(y), sin(p))
end
function Rot:right() return self:quat():right() end
function Rot:up() return self:quat():up() end

--- Each angle as (-180, 180].
function Rot:normalized()
    return M.rot(M.normalize_angle(self.Pitch), M.normalize_angle(self.Yaw), M.normalize_angle(self.Roll))
end

--- The angle in degrees between two rotations (0..180).
function Rot:angle_to(b) return self:quat():angle_to(M.rot(b):quat()) end

--- From this rotation towards b the short way, by t (0..1).
function Rot:slerp(b, t) return self:quat():slerp(M.rot(b):quat(), t):rotator() end

--- A vector turned by this rotation.
function Rot:rotate(v) return self:quat():rotate(v) end
function Rot:unrotate(v) return self:quat():unrotate(v) end

--- Euler angles in degrees, vec(Roll, Pitch, Yaw), as FRotator::Euler.
function Rot:euler() return vec_of(self.Roll, self.Pitch, self.Yaw) end

function Rot:ue() return { Pitch = self.Pitch, Yaw = self.Yaw, Roll = self.Roll } end
function Rot:array() return { self.Pitch, self.Yaw, self.Roll } end
function Rot:unpack() return self.Pitch, self.Yaw, self.Roll end

-- Transforms --------------------------------------------------------------------

--- A transform table for game functions (an FTransform): location (any vector
--- form), rotation (a quaternion or rotator, default none) and scale (a number
--- or vector, default 1).
function M.transform(location, rotation, scale)
    local q = rotation and (getmetatable(rotation) == Rot and rotation:quat() or Q(rotation)) or M.IDENTITY
    local s = type(scale) == "number" and vec_of(scale, scale, scale) or (scale and V(scale) or vec_of(1, 1, 1))
    return { Translation = V(location or M.ZERO):ue(), Rotation = q:ue(), Scale3D = s:ue() }
end

return M
