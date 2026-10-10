-- =======================================================================
-- AVMATH (AVM) - the geometry + ballistics formulas, in one place
--
--   local AVM = require("AnteUtils.AVMath")
--
-- WHY THIS FILE EXISTS: a variant file should read as INTENT ("lob a shell at the target"), not
-- as arithmetic. Every formula below was inlined at 2-6 call sites, each with its own slightly
-- different zero-guard, and each re-explained in a comment block. The derivation now lives here,
-- ONCE, and the call site is one line.
--
-- MUST-KNOWS
--   * PURE. No actors, no hooks, no engine calls beyond FVector - so nothing here can blocking-load
--     or re-enter a hook (S2/S3 don't apply). Safe to call from anywhere, including in-drain.
--   * Callers pass LOCATIONS (FVector), not actors. Resolve + validate the actor first; that keeps
--     the GC/validity rules (S3) where they belong and this file free of them.
--   * EVERY divide is zero-guarded. The house style is a FLOOR (clamp the length to >= 1) rather
--     than an early return, so a degenerate "target is exactly on top of me" never produces NaN and
--     never silently skips the attack. Where a caller genuinely wants to bail instead, the length
--     comes back as a third return value.
--   * UE units: 1 uu = 1 cm, Z is UP, gravity is NEGATIVE (ENUMS.Tuning.WORLD_GRAVITY_Z = -980).
--     Yaw is degrees CCW about +Z, atan(dy, dx).
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local ENUMS = require("AnteData.Enums")

local AVM = {}

local sqrt, cos, sin, tan, atan = math.sqrt, math.cos, math.sin, math.tan, math.atan
local rad, deg, random = math.rad, math.deg, math.random


-- =======================================================================
-- SCALARS
-- =======================================================================

function AVM.Clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

function AVM.Lerp(a, b, t)
    return a + (b - a) * t
end

-- Map v from [inLo, inHi] onto [outLo, outHi], clamped to the output range.
function AVM.Remap(v, inLo, inHi, outLo, outHi)
    if inHi == inLo then return outLo end
    local t = (v - inLo) / (inHi - inLo)
    return AVM.Clamp(outLo + (outHi - outLo) * t, math.min(outLo, outHi), math.max(outLo, outHi))
end

-- 0 -> 1 -> 0 over `period`, peaking at the halfway point. Drives a fade/pulse straight off a
-- tick counter: AVM.TriangleWave(totalTicks, 100).
function AVM.TriangleWave(t, period)
    local phase = t % period
    local half = period * 0.5
    if phase <= half then return phase / half end
    return 1 - (phase - half) / half
end


-- =======================================================================
-- 2D VECTORS (the XY plane - what nearly every NPC decision actually cares about)
-- =======================================================================

-- Unit XY direction + its true length. `len` is floored at 1 so callers can divide freely; the
-- THIRD return is the RAW length, for a caller that wants to bail on "too close".
--   local nx, ny, len = AVM.Normalize2D(tx - ax, ty - ay)
function AVM.Normalize2D(dx, dy)
    local raw = sqrt(dx * dx + dy * dy)
    local len = raw < 1 and 1 or raw
    return dx / len, dy / len, raw
end

-- True (not squared) horizontal distance. Use Utils.DistSqXY when you only need to COMPARE
-- against a radius - this one is for when the magnitude itself feeds a formula.
function AVM.DistXY(a, b)
    local dx, dy = (b.X or 0) - (a.X or 0), (b.Y or 0) - (a.Y or 0)
    return sqrt(dx * dx + dy * dy)
end

-- Rotate a vector's XY by `degrees` about +Z, keeping Z. Fans a volley off one aim direction.
function AVM.RotateYaw(v, degrees)
    local r = rad(degrees)
    local c, s = cos(r), sin(r)
    return FVector((v.X or 0) * c - (v.Y or 0) * s, (v.X or 0) * s + (v.Y or 0) * c, v.Z or 0)
end


-- =======================================================================
-- ANGLES + ARCS
-- =======================================================================

-- Shortest SIGNED difference a - b, folded into [-180, 180].
--   The +540/%360/-180 trick is the branchless fold: adding 540 (= 360 + 180) shifts the range so
--   the modulo lands in [0,360), and subtracting 180 recentres it. Without it, a turn across the
--   +/-180 seam reads as ~359 degrees and the actor spins the long way round.
function AVM.AngleDiff(a, b)
    return ((a - b + 540) % 360) - 180
end

-- Yaw (degrees) that points from `origin` at `target`.
function AVM.YawTo(origin, target)
    return deg(atan((target.Y or 0) - (origin.Y or 0), (target.X or 0) - (origin.X or 0)))
end

-- Unit forward vector of an FRotator - UE's own FRotator::Vector(). Pitch is degrees UP, so a
-- view rotation (a controller's, a camera's) becomes the ray it is looking down.
function AVM.ForwardFromRotator(rot)
    local y, p = rad(rot and rot.Yaw or 0), rad(rot and rot.Pitch or 0)
    local cp = cos(p)
    return FVector(cp * cos(y), cp * sin(y), sin(p))
end

-- Is `targetLoc` inside a frontal cone of +/-halfAngleDeg around `forward` (XY only)?
--   Dot-product test: cos(angle between) >= cos(halfAngle). Comparing COSINES avoids an acos per
--   call, and cos is monotonically DECREASING, so a wider arc is a SMALLER threshold.
--   `pointBlankRadius` (optional) returns true regardless inside that distance - at contact range
--   the bearing is noise, and without it an NPC pressed against its target reads as "behind me".
function AVM.InArc(originLoc, forward, targetLoc, halfAngleDeg, pointBlankRadius)
    local dx = (targetLoc.X or 0) - (originLoc.X or 0)
    local dy = (targetLoc.Y or 0) - (originLoc.Y or 0)
    local len = sqrt(dx * dx + dy * dy)
    if pointBlankRadius and len < pointBlankRadius then return true end
    if len < 1 then return true end
    return ((forward.X or 0) * dx + (forward.Y or 0) * dy) / len >= cos(rad(halfAngleDeg))
end

-- Cosine of the 3D angle between `forward` and the direction originLoc -> targetLoc.
--   1 = dead ahead, 0 = square on, negative = behind. Unlike InArc this RANKS candidates rather
--   than answering yes/no, which is what "which of these am I looking at" needs - and it includes
--   Z, so a target above or below is scored honestly.
function AVM.AimCos(originLoc, forward, targetLoc)
    local dx = (targetLoc.X or 0) - (originLoc.X or 0)
    local dy = (targetLoc.Y or 0) - (originLoc.Y or 0)
    local dz = (targetLoc.Z or 0) - (originLoc.Z or 0)
    local len = sqrt(dx * dx + dy * dy + dz * dz)
    if len < 1 then return 1 end
    return ((forward.X or 0) * dx + (forward.Y or 0) * dy + (forward.Z or 0) * dz) / len
end


-- =======================================================================
-- RAYS + LINES
-- =======================================================================

-- Is `point` within `radius` of the ray (origin, dirUnit), and IN FRONT of the origin?
--   Projects point-origin onto the ray, then measures what's left over (the perpendicular offset).
--   Returns: inFront+inRadius (bool), the along-ray distance, the perpendicular distance.
--   This is the "beam hit" test: backing straight up the beam stays hit, only a SIDESTEP escapes.
function AVM.PointNearRay2D(origin, dirUnit, point, radius)
    local vx = (point.X or 0) - (origin.X or 0)
    local vy = (point.Y or 0) - (origin.Y or 0)
    local along = vx * (dirUnit.X or 0) + vy * (dirUnit.Y or 0)
    local ex = vx - (dirUnit.X or 0) * along
    local ey = vy - (dirUnit.Y or 0) * along
    local offSq = ex * ex + ey * ey
    return (along >= 0 and offSq <= radius * radius), along, sqrt(offSq)
end

-- A point `dist` to one side of the origin->target line, measured from the TARGET.
--   `side` = 1 for the target's left as seen from the origin, -1 for its right. The perpendicular
--   of a unit (x, y) is (-y, x); call twice with +/-1 to get a sweep's entry and exit points.
function AVM.PerpendicularPoint(origin, target, dist, side)
    local nx, ny = AVM.Normalize2D((target.X or 0) - (origin.X or 0), (target.Y or 0) - (origin.Y or 0))
    return FVector((target.X or 0) + (-ny) * side * dist,
                   (target.Y or 0) + (nx) * side * dist,
                   target.Z or 0)
end

-- Point on a ring of `count` evenly-spaced slots around `center`. `index` is 0-based.
--   AVM.RingPoint(loc, OUT, have, MAX_EYES, UP) puts each summon on its own side.
function AVM.RingPoint(center, radius, index, count, upZ)
    local r = rad((360 / (count > 0 and count or 1)) * index)
    return FVector((center.X or 0) + cos(r) * radius,
                   (center.Y or 0) + sin(r) * radius,
                   (center.Z or 0) + (upZ or 0))
end


-- =======================================================================
-- POLYGONS
-- =======================================================================

-- Is (x, y) inside the polygon `pts` (an array of anything with .X/.Y)? XY ONLY - Z is the
-- caller's problem, because the thing this exists for is an ARENA, and an arena is a floor plan
-- with a lot of height over it (see Utils.LocInArea).
--   * CROSSING NUMBER (ray-cast east, count edges crossed; odd = inside). Chosen over the cheaper
--     half-plane test because that one silently requires a CONVEX polygon wound consistently, and
--     an arena traced by standing in its corners is neither guaranteed - a concave nook or a
--     figure-eight winding would read as "inside" over half the map with no error anywhere.
--   * `(a.Y > y) ~= (b.Y > y)` counts each edge from exactly one side, which is what keeps a
--     vertex-grazing ray from being counted twice.
--   * 3 points minimum; fewer has no interior, so it returns false rather than guessing.
function AVM.PointInPoly2D(pts, x, y)
    local n = pts and #pts or 0
    if n < 3 then return false end
    local inside = false
    local j = n
    for i = 1, n do
        local a, b = pts[i], pts[j]
        local ay, by = a.Y or 0, b.Y or 0
        if (ay > y) ~= (by > y) then
            local ax, bx = a.X or 0, b.X or 0
            -- X of the edge where it crosses this Y. The (by - ay) divide cannot be zero: the
            -- test above already proved the two Ys straddle y, so they differ.
            if x < ax + (bx - ax) * (y - ay) / (by - ay) then inside = not inside end
        end
        j = i
    end
    return inside
end


-- =======================================================================
-- BALLISTICS
--
-- Three different solves, for three different questions:
--   * ArcDir/ArcSpeed  - "I want a FIXED launch ANGLE; how fast to throw it?"  (the lob look)
--   * LobVelocity      - "I want a FIXED flight TIME; what velocity vector?"   (the mortar)
--   * BallisticAimPoint - "the SPEED is fixed and all I control is where it's AIMED; where do I
--                        aim so it lands on the target?"                       (the native gun)
-- =======================================================================

-- Aim point that makes a FIXED-SPEED, gravity-affected projectile land on `target`.
--   THE CASE THIS EXISTS FOR: a projectile fired through the game's own NPC gun
--   (FireRanged_Projectile). That path spawns at a mesh socket and points the shot with
--   FindLookAtRotation(socket, LastRangedAttackLocation) at whatever speed the projectile ROW
--   declares - so neither the launch velocity nor the launch angle is ours to set. The ONLY lever
--   is the aim point, and a flat aim means the shot drops the whole way in and only connects at
--   point blank. Lifting the aim point IS the arc.
--   Solving the fixed-speed trajectory for the launch angle:
--       tan(t) = ( v^2 -/+ sqrt( v^4 - g*(g*d^2 + 2*h*v^2) ) ) / (g*d)
--   with the MINUS root = the flat/direct arc (the other root is the high mortar arc, which reads
--   as an artillery shell and takes far too long to arrive). d = horizontal distance, h = height
--   difference, g = gravity magnitude. The lift is then how far that angle rises over d, minus the
--   height the target already sits at.
--   OUT OF RANGE (discriminant < 0): no angle at this speed reaches the target. Fall back to the
--   vertex of the two roots - the maximum-range angle for this speed - so the shot still flies as
--   far as it possibly can instead of collapsing to a flat miss.
--   `maxLift` caps the result (default 1200uu): indoors, an uncapped long-range solve aims at the
--   ceiling and the goo splatters overhead. Clamped low, never negative - this only ever lifts.
function AVM.BallisticAimPoint(origin, target, speed, gravityScale, maxLift)
    local dx = (target.X or 0) - (origin.X or 0)
    local dy = (target.Y or 0) - (origin.Y or 0)
    local h  = (target.Z or 0) - (origin.Z or 0)

    local d = sqrt(dx * dx + dy * dy)
    if d < 1 then d = 1 end                                  -- house zero-guard: floor, never bail

    local g  = -ENUMS.Tuning.WORLD_GRAVITY_Z * (gravityScale or 1)  -- magnitude, so the algebra reads normally
    local v2 = (speed or 0) * (speed or 0)
    if g <= 0 or v2 <= 0 then return target end              -- no gravity / no speed = nothing to lead

    local disc = v2 * v2 - g * (g * d * d + 2 * h * v2)
    local tanT = (disc >= 0) and ((v2 - sqrt(disc)) / (g * d)) or (v2 / (g * d))

    local lift = AVM.Clamp(d * tanT - h, 0, maxLift or 1200)
    return FVector(target.X or 0, target.Y or 0, (target.Z or 0) + lift)
end

-- Unit launch direction for a fixed-angle lob: aim flat at the target, then tilt up by `angleDeg`.
function AVM.ArcDir(origin, target, angleDeg)
    local nx, ny = AVM.Normalize2D((target.X or 0) - (origin.X or 0), (target.Y or 0) - (origin.Y or 0))
    local theta = rad(angleDeg)
    return FVector(nx * cos(theta), ny * cos(theta), sin(theta))
end

-- Launch SPEED that lands a projectile on `target` from `origin` at a fixed `angleDeg`.
--   Solving the constant-acceleration equations for v at a fixed launch angle:
--       v = sqrt( g*d^2 / (2*cos^2(t)*(d*tan(t) - h)) )
--   where d = horizontal distance, h = height difference (target - origin), g = gravity magnitude.
--   UNREACHABLE CASE: the denominator goes <= 0 when the target sits at or above the launch line,
--   i.e. no speed at THIS angle can reach it. Rather than fail, fall back to sqrt(d*g) - the speed
--   that would just reach distance d at 45 degrees - so the shot still travels sensibly.
--   `gravityScale` matches whatever the projectile's own ProjectileGravityScale is set to.
function AVM.ArcSpeed(origin, target, angleDeg, gravityScale, minDist)
    local dx = (target.X or 0) - (origin.X or 0)
    local dy = (target.Y or 0) - (origin.Y or 0)
    local dz = (target.Z or 0) - (origin.Z or 0)

    local d = sqrt(dx * dx + dy * dy)
    local floor = minDist or 50
    if d < floor then d = floor end

    local g = -ENUMS.Tuning.WORLD_GRAVITY_Z * (gravityScale or 1)   -- magnitude, so the algebra reads normally
    local theta = rad(angleDeg)
    local ct = cos(theta)

    local denom = 2 * ct * ct * (d * tan(theta) - dz)
    if denom > 0 then return sqrt(g * d * d / denom) end
    return sqrt(d * g)
end

-- Velocity vector that carries a projectile origin -> target in exactly `flightTime` seconds.
--   Straight constant-acceleration solve: the horizontal legs are just distance/time, and the
--   vertical leg adds back the drop gravity will impose over that time (-0.5*g*t, with g negative,
--   so this ADDS upward speed).
function AVM.LobVelocity(origin, target, flightTime, gravityScale)
    local t = (flightTime and flightTime > 0.01) and flightTime or 0.01
    local g = ENUMS.Tuning.WORLD_GRAVITY_Z * (gravityScale or 1)
    return FVector(((target.X or 0) - (origin.X or 0)) / t,
                   ((target.Y or 0) - (origin.Y or 0)) / t,
                   ((target.Z or 0) - (origin.Z or 0)) / t - 0.5 * g * t)
end

-- Flight time for a mortar, derived from range and clamped.
--   The clamp is the ACTUAL tuning knob: `horizSpeed` only sets how fast time grows with distance,
--   while min/max decide whether a shot reads as a lob or a line drive. A close shot would
--   otherwise resolve to a near-zero time (an unreadable instant snipe).
function AVM.LobFlightTime(origin, target, horizSpeed, minTime, maxTime)
    local t = AVM.DistXY(origin, target) / (horizSpeed > 0 and horizSpeed or 1)
    return AVM.Clamp(t, minTime, maxTime)
end

-- Horizontal launch speed that scales with distance, clamped - so a thrown body flies AT its
-- landing spot instead of always the same fixed hop. `mult` defaults to 1.1 (slight overthrow).
function AVM.TossSpeed(fromLoc, toLoc, minSpeed, maxSpeed, mult)
    return AVM.Clamp(AVM.DistXY(fromLoc, toLoc) * (mult or 1.1), minSpeed, maxSpeed)
end

-- Rescale a velocity to `newSpeed`, keeping its direction. Returns nil for a near-zero vector
-- (nothing sensible to preserve), so callers can skip rather than write a garbage direction.
function AVM.RescaleVelocity(vel, newSpeed)
    if not vel then return nil end
    local mag = sqrt((vel.X or 0) ^ 2 + (vel.Y or 0) ^ 2 + (vel.Z or 0) ^ 2)
    if mag < 1 then return nil end
    local s = newSpeed / mag
    return FVector((vel.X or 0) * s, (vel.Y or 0) * s, (vel.Z or 0) * s)
end

-- Velocity from a unit direction: `speed` along the ground, `upSpeed` bolted on vertically.
-- The plain "throw it that way with some loft" builder.
function AVM.ArcVelocity(dirUnit, speed, upSpeed)
    return FVector((dirUnit.X or 0) * speed, (dirUnit.Y or 0) * speed, upSpeed or 0)
end


-- =======================================================================
-- SCATTER (deliberate inaccuracy - a mirrored volley reads as robotic)
-- =======================================================================

-- Jitter a direction by up to +/-spreadDeg on each axis, re-normalized.
--   Returns nx, ny, nz - or nil if the input was degenerate.
function AVM.ScatterDir(dx, dy, dz, spreadDeg)
    local len = sqrt(dx * dx + dy * dy + dz * dz)
    if len < 1 then return nil end

    local j = rad(spreadDeg)
    dx = dx / len + (random() - 0.5) * j
    dy = dy / len + (random() - 0.5) * j
    dz = dz / len + (random() - 0.5) * j

    len = sqrt(dx * dx + dy * dy + dz * dz)
    if len < 0.001 then return nil end
    return dx / len, dy / len, dz / len
end

-- A random point in a box around `center` - horizontal spread `h`, vertical spread `z`.
-- The cheap "spray near them" aim for an area attack that shouldn't pinpoint.
function AVM.ScatterPoint(center, h, z)
    return FVector((center.X or 0) + random(-h, h),
                   (center.Y or 0) + random(-h, h),
                   (center.Z or 0) + random(-z, z))
end


return AVM
