-- =======================================================================
-- BEHOLDER HELPERS - the whole Beholder set, mage and eyes, in one file
--   Defs: the mage in AnteNPCs/GK_Mage.lua, the six eyes in AnteNPCs/GK_MageEye.lua.
--   Decode: AnNotes/AnteNPCs/Beholder.md, [[anteup2-beholder-eyes]]
--
-- Two bases (Gatekeeper_Mage and Gatekeeper_MageEye) but one fight, so the machinery lives
-- together rather than split down the base axis.
--
-- MUST-KNOWS
--   OwningMage is the pause button. Native CanFireLaser returns false while it points at a living
--   mage, so a welded eye never fires a beam of its own and never re-lights one behind us. It also
--   takes the eye down with the mage.
--
--   StationaryTarget is the eye's pose. The AnimBP opens the panels and pitches at whatever actor
--   it holds, and closes level when it is empty. It replicates, so the tell reaches every machine.
--   The wind-up is: set it, fire, clear it. NPCEnraged looks like a second telegraph and is not -
--   the pawn's own loop fights us for it and the eyes end up strobing.
--
--   The eyes have no AI controller. It is destroyed at mutation, because it copies the mage's
--   combat target onto the eye and writes it into StationaryTarget, i.e. straight into our pose.
--   A welded eye has nothing left to decide anyway.
--
--   One tick drives the whole roster, on the mage. Per-eye chains desync
--   ([[anteup2-workqueue-drain-starvation]]) and the eyes idle between shots.
--
--   Eyes are welded subactors (AttachSubactor opts.Rider): the attachment replicates, movement is
--   pinned, and the subactor book reaps them when the carrier dies or streams out. Their scale
--   comes from the attach, never def.BodyScale.
--
--   Blanking a beam is authority-only and that is enough. A client draws to the replicated
--   LaserEnd, which the server computes from its own LaserMaxDistance, so a 1cm reach reaches
--   every machine.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local STATE = require("AnteCore.State")
local SETTINGS = require("Settings")
local ENUMS = require("AnteData.Enums")
local ASSETS = require("AnteCore.AssetManager")
local Utils = require("AnteUtils.Utils")
local AVU = require("AnteUtils.AVUtils")
local AVM = require("AnteUtils.AVMath")
local UEHelpers = require("UEHelpers")
local Lasers = require("AnteUtils.Lasers")
local PROJ = require("AnteCore.Projectile")
local VariantTag = require("AnteVariants.VariantTag")

local LogDebug = Utils.LogDebug
local LogBad = Utils.LogBad

local BH = {}

-- Read at USE time, never cached: the flag is a world-load property and a def is shared.
local function byMode(t) return STATE.HardModeNoMercy and t.Hard or t.Normal end

local EYE_CLASS = ENUMS.NpcClasses["Gatekeeper_MageEye"]


-- =======================================================================
-- KNOBS
-- =======================================================================

-- The beat the whole set runs on, and the band it will shoot in.
local BEHOLDER = {
    WindupMs   = { Normal = 1500, Hard = 1000 },   -- panels open, then the shot leaves
    Beat       = 20,    -- ticks between activations (2s)
    Eyes       = 3,     -- welded eyes, both difficulties
    MaxNoSkip  = 2,     -- never-passing attacks the set may hold, hand attack included
    HoldOpenMs = 600,   -- how long the drone stays open after the shot
    RepairAfterMs = 3000,   -- how long a requested eye may take to arrive before it counts as lost
    RepairTries   = 3,      -- top-up attempts per Beholder, so a slot that can never weld stops trying
    RangeMin   = 200,
    RangeMax   = 6000,
    EyeScale   = 0.25,
    MaxSummons = 1,     -- live Rose minions per Beholder
    GlowIdle   = 1,
    GlowFire   = 60,
}

local PRUNE_TICKS = 300   -- roughly 30s between roster sweeps

-- [HARD] The mage's own cast. Its fireball has an empty ammo row and spawns nothing, so the
-- montage is all that survives of the native attack - and that becomes the telegraph for a fourth
-- eye attack thrown from the casting hand. ReleaseMs is where the fireball would have left, at the
-- apex of the arm coming forward.
local HAND = { Socket = "l_hand", ReleaseMs = 700 }

-- Where the eyes ride, in root space: X ahead, Y right, Z up.
local EYE_SLOTS = {
    { Bone = "root", Location = FVector(50, -40, 180) },   -- left shoulder
    { Bone = "root", Location = FVector(50, 40, 180) },    -- right shoulder
    { Bone = "root", Location = FVector(50, 0, 210) },     -- above the head
}

-- Per-colour tuning. Damage is the payload that colour lands, at each difficulty. How a shot
-- LOOKS (scale, trail) is on its flight row in AnteCore/ProjectileRows PR.LOOKS.
local BEHOLDER_EYES = {
    -- The sweep runs across the mark rather than toward it, entering off one flank and leaving by
    -- the other. Its crawl speed is solved at fire time from SweepMs, so a point-blank sweep and a
    -- 60m one take the same beat; a fixed cm/s would make one instant and the other unwatchable.
    Crimson = {
        Damage     = { Normal = 120, Hard = 170 },   -- the whole sweep, once per victim
        StartAhead = 350,   -- where the line begins, out in front of the eye
        Overshoot  = 900,   -- how far past the mark it runs on
        SweepMs    = 1100,
        StepMs     = 100,   -- WorkQueue drain granularity; cannot go finer
        HoldMs     = 650,   -- the beam sits on its entry point first: the "here it comes" beat
        Radius     = 90,    -- beam thickness for the swept hit test
        Reach      = 20000, -- MaxDistance while it fires, blanked back to 1 after
        TraceSec   = 0.05,  -- 20Hz, so the drawn beam keeps up with the aim
        MinSpeed   = 400,
        MaxSpeed   = 6000,
    },

    Azure = {
        Damage  = { Normal = 100, Hard = 100 },   -- electricity, on the disc's impact
        Speed   = { Normal = 400, Hard = 500 },
        Life    = { Normal = 5,   Hard = 7   },
        Homing  = 550,   -- turn authority is accel over speed; 550 at 500 leaves a juke a chance
        -- Launched at the chest, not the capsule centre. Fired from a shoulder ~2m up, a disc aimed
        -- straight at the centre DIVES, and at this speed and turn rate it undershoots into the floor
        -- at the target's feet. Homing still pulls it to the centre; this only flattens the approach.
        AimLift = 45,
        StunSec = 1.5,
    },

    -- The flask falls under full gravity, so where the shot is AIMED is the whole arc: the mark is
    -- lifted until the throw comes down on it, which lands it on the target out to about 20m (all
    -- the reach the flask rows' own speed buys). How much lift the ROOM allows is the real limit -
    -- an unbounded solve aims through the ceiling and the flask breaks over the mage's own head -
    -- so the headroom above the eye is probed per shot and a low roof takes LowLift, which lands
    -- short rather than overhead.
    Verdant = {
        Damage  = { Normal = 100, Hard = 150 },   -- acid, the flask's own area blast
        Speed   = 1500,   -- the flask rows' own InitialSpeed/MaxSpeed, so the solve and the flight agree
        MaxLift = 1200, LowLift = 200,
        MinThrow  = 600,  -- never aim a blast nearer than this: the mage stands in its own acid
        RoofSlack = 60,   -- clearance the probe wants past the apex, for the flask's own radius
    },

    Amber = {
        Damage = { Normal = 50, Hard = 75 },   -- direct fire; the burn patch lands on top
        Speed  = 1800,
    },

    -- The seeker rides the Exor quill's own numbers. The row already ships gravity 0, homing accel
    -- 800 and a 7000 cap, so only the damage type, the trail and the target are ours.
    Violet = {
        Damage = { Normal = 75, Hard = 100 },   -- psychic, on the seeker's impact
        Speed  = 1200, MaxSpeed = 7000, Homing = 800,
    },

    Rose = {
        DrawChance = 0.5,  -- sits out of half the draws: a summoner on most Beholders was too many
        Minion    = "Gatekeeper Peccary",
        Radius    = 700,   -- how far out from the mage a summon looks for floor
        MinRadius = 300,
    },
}

-- The mage's own shell, written as both the attach colour and the flare colour: the component's
-- per-frame loop rewrites ForceFieldColor and leaves Base and Outline alone.
local SHIELD_FLARE = FVector(0.7, 0.15, 1)

-- The Mystagogue's six body slots, addressed by index because slots 3-5 share one material name.
-- Only 0-2 carry an emissive. A tint multiplies the baked texture, so it shades the stock red robes
-- but can never turn them blue. To repaint rather than shade, add the swap to the slot and the
-- material to BH.BEHOLDER_ASSETS (TintSlot resolves it with the non-loading GetIfValid, so an
-- unpreloaded path silently no-ops):
--     [0] = { Material = ENUMS.Components.M_MYST_HEAD_ORANGE, Color = FVector(1, 0.9, 0.9) },
local MYST_SLOTS = {
    [0] = { Color = FVector(0.5, 0.35, 4),          -- head
            EmissiveColor = FVector(6, 0.6, 0), Emissive = 40 },   -- eye
    [1] = { Color = FVector(2, 0.15, 12),          -- torso + dual guard
            EmissiveColor = FVector(1.2, 0.05, 3), Emissive = 25 },   -- arm band
    [2] = { Color = FVector(1.5, 0.2, 1.5),          -- legs
            EmissiveColor = FVector(4, 4, 0), Emissive = 25 },   -- belt pouch
    [3] = { Color = FVector(4, 0.1, 8) },        -- cape, back
    [4] = { Color = FVector(0.1, 0, 1) },        -- cloth, front left
    [5] = { Color = FVector(0.1, 0, 1) },        -- cloth, front right
}
-- local MYST_SLOTS = {
--     [0] = { Color = FVector(0.4, 0.30, 2),          -- head
--             EmissiveColor = FVector(4, 0.5, 0), Emissive = 40 },   -- eye
--     [1] = { Color = FVector(4, 0.1, 8),          -- torso + dual guard
--             EmissiveColor = FVector(1.2, 0.05, 3), Emissive = 25 },   -- arm band
--     [2] = { Color = FVector(0.45, 0.25, 0.55),          -- legs
--             EmissiveColor = FVector(4, 4, 0), Emissive = 25 },   -- belt pouch
--     [3] = { Color = FVector(0.30, 0.16, 0.42) },        -- cape, back
--     [4] = { Color = FVector(0.1, 0, 1) },        -- cloth, front left
--     [5] = { Color = FVector(0.1, 0, 1) },        -- cloth, front right
-- }

-- =======================================================================
-- SHARED
-- =======================================================================

-- [AUTHORITY] Every Beholder's roster, keyed by mage fullname: its eyes and its live summons.
-- An eye's record is also its ability state (phase, deadline, committed mark), so the roster is
-- the only table a dead eye has to be pruned out of.
local behState = {}

local IDLE, WARMUP, FIRING = 0, 1, 2

-- [RENDERER] The last glow tag written per eye. Material params do not replicate, so this is a
-- local nicety layered over the wind-up, which does.
local glowState = {}

-- Both poses come off one clip: the drone's clips are transitions, so each holds an open
-- extreme and a closed one, and taking both from the same clip means they cannot disagree
-- about which end is which. Open plays forward as the wind-up tell. Closed freezes on frame 0,
-- after the shot has gone, where a frozen pose cannot drift or be re-triggered. OpenAtEnd is the
-- one dial to flip if an asset change ever inverts the clip.
local POSE = { Clip = ENUMS.Anims.MAGEEYE_CLOSE, OpenAtEnd = true }

-- Returns true once the pose is on the mesh. `quiet` is for a caller that simply retries.
local function playPose(eye, open, quiet)
    local mesh = Utils.GetValidMesh(eye)
    local seq = ASSETS.GetIfValid(POSE.Clip)
    if not mesh or IsNotValid(seq) then
        if not quiet then LogBad("Beholder eye - pose clip not resident: " .. tostring(POSE.Clip)) end
        return false
    end

    return (pcall(function()
        mesh:PlayAnimation(seq, false)   -- also switches the mesh to single-node mode
        if open ~= POSE.OpenAtEnd then
            mesh:Stop()
            mesh:SetPosition(0, false)
        end
    end))
end


-- The pose each eye was last put into, as "closed" or "open|<target>".
local poseState = {}


local function mageRow(mage)
    local key = AVU.CachedFullName(mage)
    if not key then return nil end
    local st = behState[key]
    if not st then
        st = { Mage = mage, Eyes = {}, Minions = {} }
        behState[key] = st
    end
    st.Mage = mage   -- a stream-back hands us a fresh wrapper for the same name
    return st
end


-- Collect the rows of mages that streamed out rather than died. A death drops its own row; a
-- stream-out leaves a name key nothing will ever look up again, and the stashed wrapper is the
-- only handle left to test.
local function pruneRosters()
    for key, st in pairs(behState) do
        -- Not one whose level is merely away: it comes back, and its eyes with it.
        if Utils.IsActorInvalid(st.Mage) and not Utils.IsLevelAway(st.Mage) then behState[key] = nil end
    end
end


-- Open the eye on a target, or close it. Two halves, because neither covers both ends:
--   the pose is played directly on the mesh, which is what takes the drone off its AnimBP state
--   machine (and off the random hover bob and spring bone in the same graph), but that is local;
--   StationaryTarget is the replicated half, for a remote client still running that machine, and
--   it also drives the pitch the drone aims down.
-- Latched on what we last wrote rather than on a read-back. Nothing else writes this property once
-- the controller is gone, and PlayAnimation restarts the clip every call, so an unlatched re-play
-- is a flicker.
local function setEyePose(eye, target)
    if Utils.IsActorInvalid(eye) then return end

    local key = AVU.CachedFullName(eye)
    local want = target and ("open|" .. tostring(AVU.CachedFullName(target))) or "closed"
    if not key or poseState[key] == want then return end
    poseState[key] = want

    playPose(eye, target ~= nil)

    -- A UObject property cannot be cleared by assigning nil from Lua.
    if target then
        pcall(function() eye.StationaryTarget = target end)
    else
        local ksl = UEHelpers.GetKismetSystemLibrary()
        if IsValid(ksl) then
            pcall(function() ksl:SetObjectPropertyByName(eye, FName("StationaryTarget"), nil) end)
        end
    end
    Utils.MarkReplicatedDirty(eye, "StationaryTarget")
end


-- [PURE CLIENT] The same pose, mirrored off the replicated StationaryTarget.
--   * playPose is what takes a drone off its AnimBP, and the hover bob and spring bone live in
--     that graph. The authority plays it, so a host's eyes sit still - but PlayAnimation does not
--     replicate, and a remote client's copies kept floating around the shoulders.
--   * Latched per eye on what LANDED: a clip that is still loading is retried next pass.
local clientPose = {}

local function mirrorPoseOnClient(eye)
    if Utils.IsAuthority() then return end
    ASSETS.WarmPinned({ POSE.Clip })

    -- A registration is a NEW client copy of the eye (a player came back into its level), with a
    -- fresh mesh on the AnimBP, and the name-keyed latch still says what the OLD copy showed. It
    -- read "closed" while the new mesh sat open, so nothing was ever written: three eyes locked open.
    local k0 = AVU.CachedFullName(eye)
    if k0 then clientPose[k0] = nil end

    local announced = false
    AVU.RegisterOnTickActor(eye, function(actor, ticks)
        if Utils.IsActorInvalid(actor) or actor.IsDead then return "REMOVE" end
        local key = AVU.CachedFullName(actor)
        if not key then return end

        local open = false
        pcall(function() open = IsValid(actor.StationaryTarget) end)
        -- Closed is a held frame, so re-asserting it is invisible; done every few seconds in case
        -- the game hands the mesh back to its AnimBP (open pose replays would flicker, so not those).
        local reassert = not open and ticks % 30 == 0
        if clientPose[key] == open and not reassert then return end
        if not playPose(actor, open, true) then return end
        clientPose[key] = open

        if not announced then
            announced = true
            LogDebug("Beholder eye - client pose mirror live (AnimBP off): " .. tostring(Utils.GetActorName(actor)),
                SETTINGS.DEBUG_NPC_ACTIONS)
        end
    end, "beholderPose")
end


-- A closed eye looks where its carrier looks. Its yaw is otherwise whatever the bone happened to
-- be doing, which reads as three drones staring off in three directions.
local function faceForward(eye, mage)
    if Utils.IsActorInvalid(eye) or Utils.IsActorInvalid(mage) then return end
    pcall(function()
        local want = mage:K2_GetActorRotation().Yaw
        local have = eye:K2_GetActorRotation()
        -- A walking mage swings the neck bone, so this still fires most passes; a standing one
        -- costs nothing.
        if math.abs(AVM.AngleDiff(have.Yaw, want)) < 3 and math.abs(have.Pitch) < 3 then return end
        eye:K2_SetActorRotation(FRotator(0, want, 0), false)
    end)
end


-- [RENDERER] Latched emissive, so a tick can call this freely.
local function eyeGlow(eye, tag, color, intensity)
    if not Utils.HasRenderer() or Utils.IsActorInvalid(eye) or not color then return end
    local key = AVU.CachedFullName(eye)
    if not key or glowState[key] == tag then return end
    glowState[key] = tag
    AVU.TintMesh(eye, { EmissiveColor = color, Emissive = intensity })
end


-- Eyes are immune to each other's payloads and to their own. Three of them lobbing acid, fire and
-- shock around one pair of shoulders would otherwise spend the fight debuffing each other, and a
-- burning eye reads as broken rather than as friendly fire.
BH.EYE_IMMUNE = {
    ENUMS.Debuffs.Ignited,
    ENUMS.Debuffs.IgnitedPlasma,
    ENUMS.Debuffs.IgnitedHoly,
    ENUMS.Debuffs.AcidBurn,
    ENUMS.Debuffs.FlaskCorrosive,
    ENUMS.Debuffs.Zapped,
    ENUMS.Debuffs.Frost,
    ENUMS.Debuffs.Rooted,
    ENUMS.Debuffs.Netted,
}


-- Where a shot leaves from. Normally the drone firing it. The hand attack passes its own muzzle,
-- the casting hand's socket, while still naming the mage as the eye, so the ignore list and the
-- validity guards read the same for both.
local function fireOrigin(rec)
    if rec.From then return rec.From end
    if Utils.IsActorInvalid(rec.Eye) then return nil end
    return rec.Eye:K2_GetActorLocation()
end


-- Every shot leaves a drone bolted to the mage, so the mage and its other eyes are the first
-- things in its path. Owner covers the mage for free; the eyes are neither owner nor instigator,
-- and MoveIgnoreActors is the one lever that reaches both impact doors. AnNotes/AnteNPCs/Beholder.md.
local function ignoreOwnBody(mage)
    local st = behState[AVU.CachedFullName(mage) or ""]
    return function(proj)
        if Utils.IsActorInvalid(proj) then return end
        local col
        pcall(function() col = proj.ProjectileCollision end)
        if IsNotValid(col) then return end

        pcall(function() col:IgnoreActorWhenMoving(mage, true) end)
        for _, rec in ipairs(st and st.Eyes or {}) do
            if Utils.IsActorValid(rec.Eye) then
                pcall(function() col:IgnoreActorWhenMoving(rec.Eye, true) end)
            end
        end
    end
end


-- =======================================================================
-- THE EYE TYPES - one per colour: its appearance, how often it passes, and its attack.
-- Fire(mage, rec) runs with rec.Aim already committed. Assets are that colour's own runtime deps;
-- the mage warms the union of the ones it drew at OnReady.
-- =======================================================================

local EYE_TYPES = {}
BH.EYE_TYPES = EYE_TYPES

-- Every colour, and the subset the mage is guaranteed to draw one of. The never-passing ones fire
-- on every turn they get, so a Beholder always has something happening rather than three sulkers.
local EYE_TYPE_NAMES  = { "Crimson", "Azure", "Verdant", "Amber", "Violet", "Rose" }
local NEVER_PASSING = { "Amber", "Verdant", "Violet" }
local IS_NEVER_PASSING = {}
for _, n in ipairs(NEVER_PASSING) do IS_NEVER_PASSING[n] = true end

-- The Ids live here rather than in the def file: the adoption path below reads a welded eye's
-- colour back off its VariantTag, so both ends need one place to look.
BH.EYE_IDS = { Crimson = 105, Azure = 106, Verdant = 107, Amber = 108, Rose = 115, Violet = 26 }

local EYE_TYPE_BY_ID = {}
for name, id in pairs(BH.EYE_IDS) do EYE_TYPE_BY_ID[id] = name end


-- Crimson: the Deatomizer's ground sweep, off the eye's own LaserComponent.
-- A red core beam with a blue secondary steered to the same point, one damage instance per victim.
local function fireCrimsonEye(mage, rec)
    local tune = BEHOLDER_EYES.Crimson
    local eye = rec.Eye
    if Utils.IsActorInvalid(eye) or not rec.Aim then return end

    local el = eye:K2_GetActorLocation()
    if not el then return end

    -- Committed here and never re-aimed, so the walk out is the dodge window. The line runs
    -- forward along eye to mark, landing in front of the mage and advancing through it.
    local groundZ = rec.Aim.Z - 88   -- a player capsule's half-height: the floor under the mark
    local flat, mark = FVector(el.X, el.Y, 0), FVector(rec.Aim.X, rec.Aim.Y, 0)
    local from = Utils.PointAheadOfVector(flat, mark, -(AVM.DistXY(el, rec.Aim) - tune.StartAhead))
    local to = Utils.PointAheadOfVector(flat, mark, tune.Overshoot)

    local span = AVM.DistXY(from, to)
    local speed = AVM.Clamp(span / (tune.SweepMs / 1000), tune.MinSpeed, tune.MaxSpeed)

    local deps = {}
    for _, a in ipairs(Lasers.BURST_ASSETS) do deps[#deps + 1] = a end

    ASSETS.LoadAsync(deps, function()
        if Utils.IsActorInvalid(eye) or Utils.IsDeadSafe(eye) then return end

        -- BOTH beams are FireBurst components, never the drone's own LaserComponent. That one is
        -- parented to a drone bone, and the pose clips move that bone mid-sweep - the drone opening,
        -- then snapping shut - so its beam swung off sideways between re-aims. It would also draw in
        -- the native Mage Eye cyan, since nothing applies a style to it on the host. A burst beam is
        -- welded where we put it and aimed where we say, which is the Deatomizer's own pattern.
        -- Two calls, because FireBurst takes one style per call and the pair is two colours.
        local aimAt = FVector(from.X, from.Y, groundZ)
        local function burst(color)
            local made = Lasers.FireBurst(eye, "body", {
                Count = 1, AimAt = aimAt,
                Damage = 0, Duration = tune.HoldMs + tune.SweepMs + 200, MaxDistance = tune.Reach,
                TraceInterval = tune.TraceSec,
                Style = { Color = color },
            })
            return made and made[1]
        end
        local core, second = burst(Lasers.COLOR.RED), burst(Lasers.COLOR.BLUE)
        if not Utils.IsComponentValid(core) then return end

        local hit = {}   -- one instance of damage per victim per sweep

        Lasers.SteeredSweep(eye, core, {
            From = aimAt,
            Speed = speed, Radius = tune.Radius, StepMs = tune.StepMs,
            -- The clock is seeded with the hold, so the pause cannot buy the sweep extra time
            -- against its own cap.
            MaxMs = tune.HoldMs + tune.SweepMs + tune.StepMs * 2,
            FirstDelayMs = tune.HoldMs, ElapsedMs = tune.HoldMs,
            Arrive = true,   -- done once the line is fully swept
            Heading = function() return FVector(to.X, to.Y, groundZ) end,

            -- Drag the secondary along the same line.
            OnStep = function(_, pt)
                if not Utils.IsComponentValid(second) then return end
                pcall(function()
                    local o = second:K2_GetComponentLocation()
                    local km = ASSETS.GetIfValid("/Script/Engine.Default__KismetMathLibrary")
                    if km and o then second:K2_SetWorldRotation(km:FindLookAtRotation(o, pt), false, {}, false) end
                end)
            end,

            -- Players only: a sweep that catches NPCs re-enters our own ProcessDamage per victim,
            -- which is the crowd AV.
            Hits = {
                Skip = function(v)
                    local k = Utils.ActorKey(v)
                    return k == nil or hit[k] == true
                end,
            },
            OnHit = function(victim)
                local k = Utils.ActorKey(victim)
                if k then hit[k] = true end
                AVU.PointDamageOffHook(mage, victim, byMode(tune.Damage), ENUMS.DamageType.Laser)
            end,

            -- Put both beams out the moment the sweep ends. FireBurst's scheduled destroy still owns
            -- the components; this only stops them drawing for the gap until it runs.
            OnFinish = function()
                for _, c in ipairs({ core, second }) do
                    if Utils.IsComponentValid(c) then
                        pcall(function()
                            c.LaserActive = false
                            Utils.MarkReplicatedDirty(c, "LaserActive")
                            c:OnRep_LaserActive()
                        end)
                    end
                end
            end,
        })
        -- The numbers behind "the beam was nowhere near me": an eye that sits far from its mage,
        -- or a mark the target has since walked away from, both show here.
        if SETTINGS.DEBUG_NPC_ACTIONS then
            local ml, tl
            pcall(function() ml = mage:K2_GetActorLocation() end)
            if Utils.IsActorValid(rec.Target) then
                pcall(function() tl = rec.Target:K2_GetActorLocation() end)
            end
            LogDebug(string.format("Beholder - crimson sweep: eye %.0f from its mage (dz %.0f), mark %.0f out, "
                .. "target now %.0f from the mark, line %.0f long",
                ml and AVM.DistXY(el, ml) or -1, ml and (el.Z - ml.Z) or 0, AVM.DistXY(el, rec.Aim),
                tl and AVM.DistXY(tl, rec.Aim) or -1, span), SETTINGS.DEBUG_NPC_ACTIONS)
        end
    end)
end

EYE_TYPES.Crimson = {
    Skips = 1,
    AimAtFire = true,   -- see driveEye
    Tint  = { Color = FVector(2.6, 0.04, 0.04), EmissiveColor = FVector(4, 0.03, 0.02) },
    Shell = FVector(2.4, 0.06, 0.05),
    Glow  = FVector(4, 0.03, 0.02),
    -- Open for the WHOLE sweep, not the default beat after the shot: a beam still walking the floor
    -- out of a drone that has already shut reads as broken.
    HoldOpenMs = BEHOLDER_EYES.Crimson.HoldMs + BEHOLDER_EYES.Crimson.SweepMs,
    Fire  = fireCrimsonEye,
    Assets = { ENUMS.DamageType.Laser },
}
for _, a in ipairs(Lasers.BURST_ASSETS) do table.insert(EYE_TYPES.Crimson.Assets, a) end


-- Azure: a slow homing plasma disc that stuns.
-- A mesh, not a trail. DiscPlasma's mesh is class-baked, so it replicates for free and opts.Scale
-- really does size it, where a welded-on Niagara is renderer-local and often ignores scale.
-- Native damage is zero on purpose: the disc's own impact would ignite, and a 0-damage projectile
-- still reaches PROJ's OnHit, so the whole payload is ours.
local function fireAzureEye(mage, rec)
    local tune = BEHOLDER_EYES.Azure
    if Utils.IsActorInvalid(rec.Eye) or not rec.Aim then return end
    local from = fireOrigin(rec)
    if not from then return end

    local target = rec.Target
    local speed = byMode(tune.Speed)

    local launchAt = FVector(rec.Aim.X, rec.Aim.Y, rec.Aim.Z + tune.AimLift)
    PROJ.Queue(from, Utils.Direction(from, launchAt), ENUMS.ProjectileClasses.DiscPlasma, nil, {
        Owner = mage, Instigator = mage,
        Damage = 0,
        Velocity = speed,
        MaxSpeed = speed,        -- homing is added acceleration; without this it ramps away
        GravityScale = 0,
        FlightRow = ENUMS.ProjectileRows.EyeDisc,   -- a client's disc homes off its ROW; the stock one flies straight at 5000
        LifeSpan = byMode(tune.Life),
        Preload = EYE_TYPES.Azure.Assets,
        OnSpawned = ignoreOwnBody(mage),

        -- ApplyHomingSettings runs once in BeginPlay and returns early on a nil HomingTarget, so
        -- the write has to land before FinishSpawning. [[af-projectile-homing]]
        PreFinish = function(proj)
            if Utils.IsActorInvalid(target) then return end
            pcall(function() proj.HomingTarget = target end)
        end,
        PostFinish = function(proj)
            pcall(function()
                local pm = proj.ProjectileMovement
                if IsNotValid(pm) then return end
                pm.bIsHomingProjectile = true
                pm.HomingAccelerationMagnitude = tune.Homing
                pm.MaxSpeed = speed

                -- Home at the chest, not the feet. With UseHomingTargetBoundsCenter set,
                -- ApplyHomingSettings picks the target's mesh, whose origin sits on the floor, and
                -- the disc skims the ground the whole way in. Cleared, it takes the capsule
                -- instead. Re-run it natively: HomingTargetComponent is a TWeakObjectPtr and a
                -- UE4SS write to one fails silently.
                pm.UseHomingTargetBoundsCenter = false
            end)
            pcall(function() proj:ApplyHomingSettings() end)
        end,

        -- Runs inside the impact hook, so everything it does is deferred.
        OnHit = function(_, victim)
            if Utils.IsActorInvalid(victim) then return end
            Utils.QueueWork(function()
                AVU.PointDamageOffHook(mage, victim, byMode(tune.Damage), ENUMS.DamageType.Electric)
                Utils.ApplyBuffLinked(victim, ENUMS.Debuffs.Zapped, tune.StunSec, mage)
            end, 0)
        end,
    })
    LogDebug("Beholder - azure sphere", SETTINGS.DEBUG_NPC_ACTIONS)
end

EYE_TYPES.Azure = {
    Skips = 1,
    Tint  = { Color = FVector(0.04, 0.5, 2.8), EmissiveColor = FVector(0.03, 0.7, 4) },
    Shell = FVector(0.06, 0.5, 2.4),
    Glow  = FVector(0.03, 0.7, 4),
    Fire  = fireAzureEye,
    -- Debuff dependencies, not just the projectile.
    Assets = { ENUMS.ProjectileClasses.DiscPlasma,
               ENUMS.DamageType.Electric, ENUMS.BuffObjects.Stunned, ENUMS.Effects.LIGHTNING_STUN },
}


-- Verdant: a lobbed corrosive flask, undisguised.
-- The flask is already the mechanic, acid blast and corrosion both, so this only has to throw it
-- where it will land and keep its debuff.

local FLASK_GRAVITY = 1   -- every projectile_flask_* row's ProjectileGravityScale

-- The launch direction: solve for the lift that puts the flask on the mark, then check the shot
-- fits under the roof it is thrown beneath. A lob whose apex is inside the ceiling detonates over
-- the mage instead of arriving, and the Beholder's own rooms are the low ones.
local function verdantLaunch(mage, rec, from, tune)
    -- Point blank the flask would land at the mage's own feet, so the mark is pushed out to arm's
    -- length and the blast falls BEHIND whoever closed in. Getting inside the throw is the counter.
    local mark = rec.Aim
    local flat = AVM.DistXY(from, mark)
    if flat < tune.MinThrow then
        local nx, ny = AVM.Normalize2D((mark.X or 0) - (from.X or 0), (mark.Y or 0) - (from.Y or 0))
        mark = FVector(from.X + nx * tune.MinThrow, from.Y + ny * tune.MinThrow, mark.Z)
    end

    local function solve(lift)
        local aim = AVM.BallisticAimPoint(from, mark, tune.Speed, FLASK_GRAVITY, lift)
        local dir = Utils.Direction(from, aim)
        local vz = tune.Speed * (dir.Z or 0)
        local apex = vz > 0 and (vz * vz) / (2 * -ENUMS.Tuning.WORLD_GRAVITY_Z * FLASK_GRAVITY) or 0
        return dir, apex
    end

    local dir, apex = solve(tune.MaxLift)
    if apex > 0 then
        local top = FVector(from.X, from.Y, from.Z + apex + tune.RoofSlack)
        if AVU.IsPathBlocked(mage, from, top, { mage, rec.Eye }) then
            dir = solve(tune.LowLift)
            LogDebug("Beholder - verdant lob flattened, roof inside its " .. math.floor(apex)
                .. "uu apex", SETTINGS.DEBUG_NPC_ACTIONS)
        end
    end
    return dir
end

local function fireVerdantEye(mage, rec)
    local tune = BEHOLDER_EYES.Verdant
    if Utils.IsActorInvalid(rec.Eye) or not rec.Aim then return end
    local from = fireOrigin(rec)
    if not from then return end

    PROJ.Queue(from, verdantLaunch(mage, rec, from, tune),
        ENUMS.ProjectileClasses.FlaskCorrosive, nil, {
        Owner = mage, Instigator = mage,
        Damage = byMode(tune.Damage),
        Velocity = tune.Speed,
        MaxSpeed = tune.Speed,
        FlightRow = ENUMS.ProjectileRows.EyeFlask,   -- the flask's own row is every player's too; this one carries the eye's look
        KeepDebuff = true,   -- the corrosion is the point; PROJ wipes row debuffs by default
        Preload = EYE_TYPES.Verdant.Assets,
        OnSpawned = ignoreOwnBody(mage),

        -- A flask is a player tool, so its row skips ally-faction victims - which on an NPC-thrown
        -- one means every player. Same clear as the Trident's net.
        PreFinish = function(proj)
            pcall(function() proj.BuffsIgnoreAllies = false end)
        end,
    })
    LogDebug("Beholder - verdant flask", SETTINGS.DEBUG_NPC_ACTIONS)
end

EYE_TYPES.Verdant = {
    Skips = 0,
    Tint  = { Color = FVector(0.05, 2.6, 0.08), EmissiveColor = FVector(0.03, 4, 0.05) },
    Shell = FVector(0.08, 2.4, 0.1),
    Glow  = FVector(0.03, 4, 0.05),
    Fire  = fireVerdantEye,
    Assets = { ENUMS.ProjectileClasses.FlaskCorrosive, ENUMS.Effects.WISP_GREEN,
               ENUMS.DamageType.Acid, ENUMS.BuffObjects.AcidBurn, ENUMS.BuffObjects.HPDamage },
}


-- Amber: a flat, fast molotov.
-- Gravity off so it reads as a fired bolt rather than a lob. The burn patch is the native impact.
local function fireAmberEye(mage, rec)
    local tune = BEHOLDER_EYES.Amber
    if Utils.IsActorInvalid(rec.Eye) or not rec.Aim then return end
    local from = fireOrigin(rec)
    if not from then return end

    PROJ.Queue(from, Utils.Direction(from, rec.Aim), ENUMS.ProjectileClasses.Molotov, nil, {
        Owner = mage, Instigator = mage,
        Damage = byMode(tune.Damage),
        Velocity = tune.Speed,
        MaxSpeed = tune.Speed,
        GravityScale = 0,
        FlightRow = ENUMS.ProjectileRows.MolotovFlat,   -- a client's bottle otherwise drops at the molotov's gravity 1
        Preload = EYE_TYPES.Amber.Assets,
        OnSpawned = ignoreOwnBody(mage),
    })
    LogDebug("Beholder - amber bolt", SETTINGS.DEBUG_NPC_ACTIONS)
end

EYE_TYPES.Amber = {
    Skips = 0,
    Tint  = { Color = FVector(3, 1.45, 0.0), EmissiveColor = FVector(4, 1.9, 0.0) },
    Shell = FVector(2.6, 1.3, 0.02),
    Glow  = FVector(4, 1.9, 0.0),
    Fire  = fireAmberEye,
    Assets = { ENUMS.ProjectileClasses.Molotov, ENUMS.Effects.WISP_RED,
               ENUMS.Components.AREA_MOLOTOV_FIRE, ENUMS.DamageType.Fire,
               ENUMS.BuffObjects.Ignited, ENUMS.BuffObjects.HPDamage },
}


-- Rose: the summoner, and the one eye that mostly passes.
-- The minion arrives with its own spawn-in rather than a Gatekeeper portal: it is the Beholder's
-- pet, not a reinforcement called through a door.
local function fireRoseEye(mage, rec)
    local tune = BEHOLDER_EYES.Rose
    if Utils.IsActorInvalid(mage) then return end
    local st = mageRow(mage)
    if not st then return end

    -- Prune first, then claim the slot at request time. The spawn is async, so counting only the
    -- bodies that already exist lets a second cast slip through.
    -- [[anteup2-orchestrator-minion-registry]]
    local live = {}
    for _, m in ipairs(st.Minions) do
        if Utils.IsActorValid(m) and Utils.IsActorAlive(m) then live[#live + 1] = m end
    end
    st.Minions = live
    if (st.Pending or 0) + #live >= BEHOLDER.MaxSummons then return end
    st.Pending = (st.Pending or 0) + 1

    local at = Utils.GetSpawnPoint(mage:K2_GetActorLocation(), tune.Radius, tune.MinRadius)
    if not at then st.Pending = st.Pending - 1; return end

    AVU.SummonVariant(tune.Minion, at, {}, function(npc)
        local row = mageRow(mage)
        if row then row.Pending = math.max(0, (row.Pending or 1) - 1) end
        if Utils.IsActorInvalid(npc) then return end
        if row then row.Minions[#row.Minions + 1] = npc end

        -- A script-spawned NPC is in no spawner group, so nothing else will ever unload it.
        AVU.WatchSummonLifetime(npc, mage, { Label = "Beholder summon" })
    end)
    -- Names the caster and where it stood: several Beholders share an arena, and a minion lands
    -- within tune.Radius of whichever one cast it.
    if SETTINGS.DEBUG_NPC_ACTIONS then
        local id, ml = "?", nil
        pcall(function() id = mage:GetFullName():match("_(%d+)$") or "?"; ml = mage:K2_GetActorLocation() end)
        LogDebug(string.format("Beholder - rose summon (mage #%s at %d,%d,%d)", id:sub(-4),
            ml and math.floor(ml.X) or 0, ml and math.floor(ml.Y) or 0, ml and math.floor(ml.Z) or 0), true)
    end
end

EYE_TYPES.Rose = {
    Skips = { Normal = 5, Hard = 4 },   -- the rarest thing the set does
    RestMs = 5000,                      -- ...and this long again once its passes run out
    Tint  = { Color = FVector(2.4, 0.06, 1.1), EmissiveColor = FVector(4, 0.05, 1.6) },
    Shell = FVector(2.2, 0.1, 1.0),
    Glow  = FVector(4, 0.05, 1.6),
    Fire  = fireRoseEye,
    Assets = { ENUMS.NpcClasses["Peccary"] },
}


-- Violet: a psychic seeker.
-- The Exor quill, wearing the Displacer's teleport charge-up as its trail.
local function fireVioletEye(mage, rec)
    local tune = BEHOLDER_EYES.Violet
    if Utils.IsActorInvalid(rec.Eye) or not rec.Aim then return end
    local from = fireOrigin(rec)
    if not from then return end

    local target = rec.Target

    PROJ.Queue(from, Utils.Direction(from, rec.Aim), ENUMS.ProjectileClasses.ExorSpike, nil, {
        Owner = mage, Instigator = mage,
        Damage = byMode(tune.Damage),
        Velocity = tune.Speed,
        MaxSpeed = tune.MaxSpeed,
        -- Asserting the type also overrides the row's native Sharp_ExorQuill, which would bleed.
        -- Psychic carries no debuff, so there is nothing extra to preload for it.
        DamageTypeClass = ENUMS.DamageType.Psychic,
        FlightRow = ENUMS.ProjectileRows.EyeSeeker,   -- the quill's own row is the Exor's; this one carries the trail
        Preload = EYE_TYPES.Violet.Assets,
        OnSpawned = ignoreOwnBody(mage),

        PreFinish = function(proj)
            if Utils.IsActorInvalid(target) then return end
            pcall(function() proj.HomingTarget = target end)
        end,
        PostFinish = function(proj)
            pcall(function()
                local pm = proj.ProjectileMovement
                if IsNotValid(pm) then return end
                pm.bIsHomingProjectile = true
                pm.HomingAccelerationMagnitude = tune.Homing
                pm.MaxSpeed = tune.MaxSpeed
            end)
        end,
    })
    LogDebug("Beholder - violet seeker", SETTINGS.DEBUG_NPC_ACTIONS)
end

EYE_TYPES.Violet = {
    Skips = 0,
    Tint  = { Color = FVector(1.0, 0.08, 2.6), EmissiveColor = FVector(1.4, 0.04, 4) },
    Shell = FVector(0.8, 0.1, 2.2),
    Glow  = FVector(1.4, 0.04, 4),
    Fire  = fireVioletEye,
    Assets = { ENUMS.ProjectileClasses.ExorSpike, ENUMS.Effects.EXOR_CHARGEUP,
               ENUMS.DamageType.Psychic },
}


-- =======================================================================
-- THE EYE - chassis and appearance. One def per colour, one shape.
-- =======================================================================

-- [AUTHORITY] Everything a welded eye needs to be a weapon platform and nothing else.
--   Invulnerable is the design: the mage is the only killable thing in the set, and the shell in
--   Visuals is how a player is told, so neither half is optional.
--   OwningMage is set later, by the mage's weld.
function BH.EyeChassis(actor, eyeType)
    AVU.SetInvulnerable(actor, true)

    AVU.ClearLoot(actor, true)
    AVU.ClearGibLoot(actor)   -- it force-gibs itself, and ClearLoot alone leaves the salvage

    -- A 1cm beam draws nothing, which is the only reliable way to keep one dark: SetActive(false)
    -- is undone by the pawn's own loop and just flickers. It stays dark for life - even Crimson's
    -- sweep is drawn with burst beams, not this one.
    Lasers.Tune(actor, { Damage = 0, Bounces = 0, MaxDistance = 1 })

    -- Start closed and in single-node mode. That is what takes the drone off its AnimBP state
    -- machine, and with it the random hover bob and spring bone in the same graph, which read as
    -- the eyes never quite sitting still on the shoulders.
    playPose(actor, false)

    -- No controller. A welded eye has nothing to decide - it does not move, does not perceive and
    -- fires only when the mage's beat says so - and its controller actively fights us: it copies
    -- the owning mage's combat target onto the eye, then writes that into StationaryTarget, which
    -- is our open/closed pose. Blinding the pawn cannot help, because the target arrives from the
    -- mage rather than from the eye's own senses.
    -- Deferred, because the possession settles after our mutation runs.
    Utils.QueueWork(function()
        if Utils.IsActorInvalid(actor) then return end
        local gone = false
        pcall(function()
            local c = actor.NPC_Controller
            if IsNotValid(c) then c = actor:GetController() end
            if IsNotValid(c) then return end
            c:UnPossess()
            c:K2_DestroyActor()
            gone = true
        end)
        -- Logged either way: a controller that was never found looks exactly like one that was
        -- destroyed, and everything above assumes it is gone.
        LogDebug("Beholder eye - controller " .. (gone and "destroyed" or "NOT FOUND"),
            SETTINGS.DEBUG_NPC_ACTIONS)
    end, 500)
end


-- [RENDERER] The invulnerability tell, in the eye's own colour. Attached once, but a miss is not
-- latched: AttachShieldShell returns nil until the body mesh has streamed in, so the next pass
-- gets it.
local eyeShellDone = {}

function BH.EyeShell(actor, eyeType)
    if not Utils.HasRenderer() or Utils.IsActorInvalid(actor) then return end
    mirrorPoseOnClient(actor)   -- re-registering replaces its own slot, so a repeat pass is free

    local key = AVU.CachedFullName(actor)
    if not key then return end
    -- The latch holds the shell COMPONENT: a new client copy of the eye (same name) has none, and
    -- the old one died with the old copy. Same for the glow latch.
    if eyeShellDone[key] and Utils.IsComponentValid(eyeShellDone[key]) then return end
    eyeShellDone[key] = nil
    glowState[key] = nil

    -- All three colour params: the shield material blends ForceFieldColor with its own Base and
    -- Outline, so tinting Color alone leaves the stock hue bleeding through.
    local shell = AVU.AttachShieldShell(actor, nil, {
        Color = eyeType.Shell, Base = eyeType.Shell, Outline = eyeType.Shell,
        Glow = 1.5,   -- a whisper of a shield, not a wall
    })
    if shell then eyeShellDone[key] = shell end

    eyeGlow(actor, "idle", eyeType.Glow, BEHOLDER.GlowIdle)
end


-- =======================================================================
-- BEHOLDER MAGE
-- =======================================================================

BH.BEHOLDER_ASSETS = {
    EYE_CLASS,
    AVU.BODYSHIELD_CLASS,
    AVU.SHIELD_SHELL_MAT,
    ENUMS.LaserComponent,
}


-- [AUTHORITY] Remove most of the mage's base abilities, except gravity wave.
-- Give it a hardlight body shield
function BH.BeholderStats(actor)
    -- Lazy require, or the two Helpers files cycle through the def files.
    require("AnteNPCs.GK_MageHelpers").StripMageKit(actor, { GravityWave = true })

    -- The projectile-reflect sweep is Apocalyptic-only, and this bool is its whole gate.
    pcall(function() actor.ApocalypticMage = false end)

    -- No fireball. In hard mode this will instead do a 'fourth' eye attack on its own timer
    AVU.SetProjectileRow(actor, "FireballProjectile", "None")

    -- Add a hardlight shield. No existing shield mechanics are on the Mage class 
    --   - it descends from NPC_Base_ParentBP (unlike other Gatekeepers)
    AVU.AddBodyShield(actor, {
        Max = STATE.HardModeNoMercy and 1000 or 700,
        Regen = 0,
        ShowFX = true,
    })
    
    AVU.SetShieldFlareColor(actor, SHIELD_FLARE)
end


-- [RENDERER] Give the body shield something to draw. A BodyShieldComponent shows itself by
-- un-hiding meshes tagged "bodyshield", and the mage has none of its own, so a runtime shield
-- absorbs hits completely invisibly until a shell is attached. After that the component owns the
-- visibility: hidden at rest, flaring on each hit, and that flare is the tell.
-- Runs after Stats, so the component it registers with already exists.
function BH.BeholderLook(actor)
    if not Utils.HasRenderer() or Utils.IsActorInvalid(actor) then return end

    -- Per-slot, so the cape and the head can disagree. This replaces def.Tint rather than layering
    -- on it: def.Tint sprays every slot and runs first, so the two would only fight.
    local mesh = Utils.GetValidMesh(actor)
    if mesh then
        for idx, opts in pairs(MYST_SLOTS) do AVU.TintSlot(mesh, idx, opts) end
    end

    AVU.AttachShieldShell(actor, nil, {
        Color = SHIELD_FLARE, Base = SHIELD_FLARE, Outline = SHIELD_FLARE, Glow = 4,
    })
end


-- File one eye on the roster. Its record is also its ability state, so this is the only place a
-- phase is seeded.
local function fileEye(st, eye, typeName, slot)
    local eyeType = EYE_TYPES[typeName]
    if not eyeType then return end
    st.Eyes[#st.Eyes + 1] = {
        Eye = eye, EyeType = eyeType, Name = typeName, Slot = slot,
        Phase = IDLE,
        -- Every eye is ready on its first turn; Skips only spaces out the later ones. Starting a
        -- rare eye pre-loaded with passes leaves a fresh Beholder doing nothing for a while.
        Pending = 0,
    }
end


-- How many turns this eye passes between shots.
local function eyeSkips(rec)
    local sk = rec.EyeType.Skips or 0
    return (type(sk) == "table") and byMode(sk) or sk
end


-- Rebuild the roster from eyes that are already bolted on, and say whether any were. OnReady
-- re-runs on every mutation, and welding a second set on top is the obvious failure. The roster
-- cannot answer "did I already do this" - a /reload wipes it while the bodies stay attached - so
-- the bodies are the durable record, and their VariantTag still says which colour each one is.
local function adoptWeldedEyes(mage, st)
    local seen, held = {}, {}
    for _, rec in ipairs(st.Eyes) do
        local k = Utils.IsActorValid(rec.Eye) and AVU.CachedFullName(rec.Eye) or nil
        if k then seen[k] = true end
    end

    local found = false
    for i, a in ipairs(Utils.GetAttachedActors(mage)) do
        local eye = a:get()
        if eye and Utils.IsActorValid(eye) then
            local typeName = EYE_TYPE_BY_ID[VariantTag.Decode(eye) or 0]
            local key = typeName and AVU.CachedFullName(eye) or nil
            if key then
                found = true
                if not seen[key] then fileEye(st, eye, typeName, i) end
                held[typeName] = true
            end
        end
    end

    -- The hand attack has no body to be read back off, so it is re-derived as any never-passing
    -- colour the welded set does not already hold. Without this a /reload leaves a hard-mode
    -- Beholder casting nothing.
    if found and STATE.HardModeNoMercy and not st.Hand then
        for _, name in ipairs(NEVER_PASSING) do
            if not held[name] then st.Hand = EYE_TYPES[name]; break end
        end
    end
    return found
end


-- [AUTHORITY] Pick this Beholder's colours and weld them on. Always distinct: the set only reads
-- if each shoulder is a different threat.
-- Request one eye into one slot. Shared by the draw and the repair, so a topped-up eye is welded
-- exactly the way an original one was.
local function requestEye(mage, typeName, slotIndex)
    local slot = EYE_SLOTS[slotIndex]
    if not slot then return end
    LogDebug("Beholder - requesting " .. typeName .. " eye, slot " .. slotIndex, SETTINGS.DEBUG_NPC_ACTIONS)
    AVU.AttachSubactor(mage, EYE_CLASS, slot.Bone, {
        Location = slot.Location,
        Rotation = slot.Rotation,
        Scale = FVector(BEHOLDER.EyeScale, BEHOLDER.EyeScale, BEHOLDER.EyeScale),
        Rider = true,   -- the live-NPC weld: pinned movement, no lifetime link of its own
        OnConfigured = function(child, parent) BH.EyeWelded(child, parent, typeName, slotIndex) end,
    })
end


-- How many drone bodies are physically attached right now, filed or not. An eye that has welded
-- but not yet finished mutating is still on its way, and the repair must not double it.
local function attachedEyeCount(mage)
    local n = 0
    for _, a in ipairs(Utils.GetAttachedActors(mage)) do
        local eye = a:get()
        if eye and Utils.IsActorValid(eye) then
            local isEye = false
            pcall(function() isEye = eye:GetClass():GetFName():ToString() == "NPC_MageEye_C" end)
            if isEye then n = n + 1 end
        end
    end
    return n
end


function BH.BeholderReady(actor)
    local st = mageRow(actor)
    if not st then return end

    if adoptWeldedEyes(actor, st) then
        LogDebug("Beholder - adopted " .. #st.Eyes .. " welded eye(s)", SETTINGS.DEBUG_NPC_ACTIONS)
        return
    end

    -- The draw has two rules. The set always holds at least one never-passing attack, or it can
    -- roll all skippers and spend the fight standing there; and it never holds more than
    -- BEHOLDER.MaxNoSkip of them, which is the cap that keeps it from being a wall of ordnance.
    -- The hard-mode hand attack counts as one, so that mode draws its hand colour first and the
    -- eyes fill in underneath.
    local hard = STATE.HardModeNoMercy

    local pool = {}
    for _, name in ipairs(EYE_TYPE_NAMES) do
        local chance = (BEHOLDER_EYES[name] or {}).DrawChance
        if not chance or math.random() < chance then pool[#pool + 1] = name end
    end
    for i = #pool, 2, -1 do
        local j = math.random(i)
        pool[i], pool[j] = pool[j], pool[i]
    end

    local function takeAlways()
        for i, name in ipairs(pool) do
            if IS_NEVER_PASSING[name] then return table.remove(pool, i) end
        end
    end

    local hand, noSkip = nil, 0
    if hard then
        hand = takeAlways()
        st.Hand = hand and EYE_TYPES[hand] or nil
        noSkip = hand and 1 or 0
    end

    local picks = {}
    if noSkip == 0 then
        local first = takeAlways()
        if first then picks[1] = first; noSkip = 1 end
    end
    for _, name in ipairs(pool) do
        if #picks >= BEHOLDER.Eyes then break end
        if not (IS_NEVER_PASSING[name] and noSkip >= BEHOLDER.MaxNoSkip) then
            picks[#picks + 1] = name
            if IS_NEVER_PASSING[name] then noSkip = noSkip + 1 end
        end
    end

    -- Warm the union of what the drawn colours will fire, hand attack included. These fire seconds
    -- to minutes after mutation, so they are pinned rather than merely preloaded, and so are the
    -- pose clips the eyes replay on every shot.
    local deps = { ENUMS.Anims.MAGEEYE_CLOSE, ENUMS.Anims.MAGEEYE_OPEN }
    for _, name in ipairs(picks) do
        for _, a in ipairs(EYE_TYPES[name].Assets or {}) do deps[#deps + 1] = a end
    end
    if hand then
        for _, a in ipairs(EYE_TYPES[hand].Assets or {}) do deps[#deps + 1] = a end
    end
    ASSETS.WarmPinned(deps)

    LogDebug("Beholder - eyes " .. table.concat(picks, "/") .. (hand and (" + hand " .. hand) or ""),
        SETTINGS.DEBUG_NPC_ACTIONS)

    -- What was drawn, by slot, so the repair can put a lost eye back as the SAME colour in the SAME
    -- place rather than rolling a new one.
    st.Picks, st.WeldAt, st.Repairs = picks, Utils.NowMs(), 0

    for i = 1, #picks do requestEye(actor, picks[i], i) end
end


-- [AUTHORITY] Put back any drawn eye that never arrived.
--   An attach is deferred, and AttachSubactor's deferred half has several silent early-outs (the
--   carrier, its mesh, the class or the world unreadable at that moment), so an eye can simply fail
--   to exist - which is how a Beholder came out with one eye, or none. Nothing downstream counted.
--   Wall-clock grace (Utils.NowMs), never passes: the drain is newest-first, so passes lie.
local function repairEyes(mage, st)
    local picks = st.Picks
    if not picks or #st.Eyes >= #picks then return end
    if (st.Repairs or 0) >= BEHOLDER.RepairTries then return end
    if Utils.NowMs() - (st.WeldAt or 0) < BEHOLDER.RepairAfterMs then return end

    -- Anything physically attached but not yet filed is still arriving; wait for it.
    if attachedEyeCount(mage) > #st.Eyes then return end

    local held = {}
    for _, rec in ipairs(st.Eyes) do held[rec.Name] = true end

    st.Repairs = (st.Repairs or 0) + 1
    st.WeldAt = Utils.NowMs()
    for i, typeName in ipairs(picks) do
        if not held[typeName] then
            LogBad(string.format("Beholder - %s eye (slot %d) never arrived; re-requesting (try %d of %d)",
                typeName, i, st.Repairs, BEHOLDER.RepairTries))
            requestEye(mage, typeName, i)
        end
    end
end


-- Move a settled eye off its bone and onto the mage's capsule. Bone space is the only frame where
-- "over that shoulder" is expressible, so that is where the eyes are placed - but bones animate,
-- and an eye welded to one bobs with every breath and walk cycle. KeepWorld on location and
-- rotation carries the tuned placement across the reparent untouched; scale stays relative, so it
-- still rides AttachmentReplication for joiners.
-- Deferred so the sample lands on a settled pose rather than the spawn frame.
--   * Driven from the mage's TICK, not a one-shot timer. A timer that lands while the level is
--     away (a player teleporting out seconds after the spawn) reads both bodies invalid and
--     simply never happens - and the tick is what parks and resumes with the level.
--   * Where it lands becomes the eye's SEAT (AVA.SetWeldSeat): a welded character is pushed off
--     its offset whenever the game re-enables it, and an attachment keeps wherever it ends up -
--     which is how a returning player found all three eyes trailing behind the mage.
local SETTLE_TICKS = 15
local SEAT_MAX = 300   -- a sample further out than this from the capsule is not a shoulder

local function settleEye(mage, rec, now)
    if rec.Settled then return end
    rec.SettleAt = rec.SettleAt or (now + SETTLE_TICKS)
    if now < rec.SettleAt then return end
    rec.Settled = true

    pcall(function()
        local cap = mage.CapsuleComponent
        if IsNotValid(cap) then return end
        -- EAttachmentRule: 0 KeepRelative, 1 KeepWorld, 2 SnapToTarget.
        rec.Eye:K2_AttachToComponent(cap, FName(""), 1, 1, 0, true)

        local rel = rec.Eye.RootComponent.RelativeLocation
        if rel.X * rel.X + rel.Y * rel.Y + rel.Z * rel.Z <= SEAT_MAX * SEAT_MAX then
            AVU.SetWeldSeat(rec.Eye, rel)
        else
            LogBad(string.format("Beholder - %s eye settled %d,%d,%d from the capsule; not held to that",
                tostring(rec.Name), math.floor(rel.X), math.floor(rel.Y), math.floor(rel.Z)))
        end
    end)
end


-- [AttachSubactor.OnConfigured, off-hook] Turn the raw eye into its colour and file it.
function BH.EyeWelded(eye, mage, typeName, slot)
    if Utils.IsActorInvalid(eye) or Utils.IsActorInvalid(mage) then
        Utils.LogBad(string.format("Beholder - %s eye (slot %s) arrived but reads invalid (eye=%s, mage=%s)",
            tostring(typeName), tostring(slot), tostring(Utils.IsActorValid(eye)), tostring(Utils.IsActorValid(mage))))
        return
    end

    -- Lazy require, or a top-level one cycles.
    require("AnteVariants.NpcManager").MutateActor("Beholder " .. typeName .. " Eye", eye, {})

    -- The pause button. Native CanFireLaser bails while this points at a living mage, so the pawn's
    -- own laser loop never fires and never re-lights the beam behind us. It also binds the eye's
    -- OwningMageDeath, which takes the eye down with the mage.
    pcall(function() eye.OwningMage = mage end)

    -- The eye ships on the Gatekeeper team already, but a mage whose faction was overridden would
    -- otherwise be wearing two enemies on its shoulders.
    local fac
    pcall(function() fac = mage.Faction end)
    if fac ~= nil then AVU.SetFaction(eye, fac) end

    local st = mageRow(mage)
    if st then fileEye(st, eye, typeName, slot) end
    LogDebug("Beholder - welded " .. typeName .. " eye, slot " .. tostring(slot), SETTINGS.DEBUG_NPC_ACTIONS)
end


-- [AUTHORITY] Run one eye's wind-up and fire cycle. The mark is the mage's target: an eye pinned
-- to a shoulder has no perception of its own worth trusting.
local function driveEye(mage, rec, now)
    local eye = rec.Eye
    if Utils.IsActorInvalid(eye) then return end

    if rec.Phase == WARMUP then
        -- Held open and aimed at the target, but fired at the mark committed to when the wind-up
        -- began, so the panels opening is a real dodge window and not a delay spent tracking.
        setEyePose(eye, rec.Target)
        if now < rec.Until then return end

        -- AimAtFire: the mark is taken NOW instead. The sweep's own hold and crawl are its dodge
        -- window; on top of a whole wind-up it swept ground the target had left seconds ago.
        if rec.EyeType.AimAtFire and Utils.IsActorValid(rec.Target) then
            pcall(function()
                local tl = rec.Target:K2_GetActorLocation()
                if tl then rec.Aim = FVector(tl.X, tl.Y, tl.Z) end
            end)
        end

        -- Fire while still open, and hold it. Shutting on the same frame the shot leaves means the
        -- drone is never seen open at the moment it matters.
        pcall(rec.EyeType.Fire, mage, rec)
        rec.Phase = FIRING
        rec.Until = now + math.ceil((rec.EyeType.HoldOpenMs or BEHOLDER.HoldOpenMs) / 100)
        return
    end

    if rec.Phase == FIRING then
        if now < rec.Until then return end
        rec.Phase = IDLE
        setEyePose(eye, nil)
        eyeGlow(eye, "idle", rec.EyeType.Glow, BEHOLDER.GlowIdle)
        return
    end

    -- Idle: shut, level, and looking where the mage looks. The closed frame is re-asserted every
    -- few seconds past the latch (invisible: it is a held frame) for a mesh the game handed back
    -- to its AnimBP while the level was away.
    setEyePose(eye, nil)
    if now % 30 == 0 then playPose(eye, false, true) end
    faceForward(eye, mage)
end


-- Open this eye's wind-up. The mark is captured here and never re-acquired.
local function startWindup(rec, target, now)
    local eye = rec.Eye
    local tl = target:K2_GetActorLocation()
    if not tl then return false end

    rec.Phase = WARMUP
    rec.Target = target
    rec.Aim = FVector(tl.X, tl.Y, tl.Z)
    rec.Until = now + math.ceil(byMode(BEHOLDER.WindupMs) / 100)

    setEyePose(eye, target)
    eyeGlow(eye, "fire", rec.EyeType.Glow, BEHOLDER.GlowFire)
    return true
end


-- [AUTHORITY] The beat: one activation per Beat ticks, rotating through the eyes. The eye whose
-- turn it is either fires or passes, and a pass hands the same beat straight to the next one, so
-- the set always does something and a rare eye spaces itself out without leaving a silent gap.
-- Pending is that eye's passes left; firing resets it to its Skips value.
local function runBeat(mage, st, target, now)
    if not target then return end

    local n = #st.Eyes
    if n == 0 then return end

    if st.Beat and now - st.Beat < BEHOLDER.Beat then return end

    -- Measured from the mage: the eyes ride its shoulders, so a per-eye band would only ever
    -- disagree with itself by a few centimetres.
    local ml, tl = mage:K2_GetActorLocation(), target:K2_GetActorLocation()
    if not ml or not tl then return end
    local dsq = Utils.DistSq(ml, tl)
    -- Out of band is not a consumed beat; the set simply has nothing to shoot at yet.
    if dsq < BEHOLDER.RangeMin * BEHOLDER.RangeMin or dsq > BEHOLDER.RangeMax * BEHOLDER.RangeMax then return end

    st.Ptr = st.Ptr or 1

    -- At most one lap. The draw guarantees a never-passing eye, but a roster reduced to skippers
    -- would otherwise spin.
    for _ = 1, n do
        local rec = st.Eyes[((st.Ptr - 1) % n) + 1]
        st.Ptr = (st.Ptr % n) + 1

        if rec.Phase ~= IDLE or Utils.IsActorInvalid(rec.Eye) then
            -- Still busy with its last shot: this turn's pass, without touching Pending.
        elseif (rec.Pending or 0) > 0 then
            rec.Pending = rec.Pending - 1
            if rec.Pending == 0 and rec.EyeType.RestMs then
                rec.RestUntil = now + math.ceil(rec.EyeType.RestMs / 100)
            end
            LogDebug("Beholder - " .. rec.Name .. " passes (" .. rec.Pending .. " left)",
                SETTINGS.DEBUG_NPC_ACTIONS)
        elseif rec.RestUntil and now < rec.RestUntil
               and rec.RestUntil - now <= math.ceil(rec.EyeType.RestMs / 100) then
            -- Resting: a pass that spends no count. (A stamp further out than one rest is from
            -- another world's clock, and is ignored.)
        elseif startWindup(rec, target, now) then
            rec.Pending = eyeSkips(rec)
            st.Beat = now
            return
        end
    end

    -- A whole lap of passes still costs the beat, or every eye would decrement again next tick.
    st.Beat = now
end


-- [AUTHORITY] The whole set's clock. One tick item loops the roster.
function BH.BeholderTick(actor, ticks)
    -- No cleanup here: a gone actor has no readable name, so its row cannot be found by key.
    -- pruneRosters is what collects it.
    if Utils.IsActorInvalid(actor) then return "REMOVE" end
    if not Utils.IsAuthority() then return end
    if ticks % 2 ~= 0 then return end   -- nothing here needs 10Hz
    if ticks % PRUNE_TICKS == 0 then pruneRosters() end
    if Utils.IsDeadSafe(actor) then return end

    local st = mageRow(actor)
    if not st then return end

    -- Before the no-eyes return below: a Beholder that lost every eye has the most to repair.
    if ticks % 20 == 0 then repairEyes(actor, st) end
    if #st.Eyes == 0 then return end

    local target = AVU.GetCurrentTarget(actor)
    local now = STATE.FAST_TICK

    -- The walk doubles as the roster's dead-eye purge. Every eye runs its own cycle here; only the
    -- decision to start one belongs to the beat below.
    local live = {}
    for _, rec in ipairs(st.Eyes) do
        if Utils.IsActorValid(rec.Eye) then
            live[#live + 1] = rec
            settleEye(actor, rec, now)
            driveEye(actor, rec, now)
        end
    end
    st.Eyes = live

    runBeat(actor, st, target, now)
end


-- [AUTHORITY, OnRangedAttack] [HARD] The mage's own cast: a fourth eye attack out of the casting
-- hand, leaving at the apex of the arm coming forward from the socket the dead fireball used.
-- Its colour is drawn at OnReady from the never-passing three and is never one the eyes hold, so
-- the hand always adds an attack the set does not already have.
function BH.BeholderCast(actor)
    if not Utils.IsAuthority() or Utils.IsActorInvalid(actor) then return end

    local st = mageRow(actor)
    if not st or not st.Hand then return end

    local target = AVU.GetCurrentTarget(actor)
    if Utils.IsActorInvalid(target) then return end

    Utils.QueueWork(function()
        if Utils.IsActorInvalid(actor) or Utils.IsDeadSafe(actor) then return end
        if Utils.IsActorInvalid(target) then return end

        local tl = target:K2_GetActorLocation()
        local mesh = Utils.GetValidMesh(actor)
        if not tl or not mesh then return end

        local from
        pcall(function() from = mesh:GetSocketLocation(FName(HAND.Socket)) end)
        if not from then return end

        -- Eye is the mage, so the shared guards and the ignore list read it as the firing body.
        -- From is what moves the muzzle out to the hand.
        pcall(st.Hand.Fire, actor, {
            Eye = actor, From = from, Target = target,
            Aim = FVector(tl.X, tl.Y, tl.Z),
        })
        LogDebug("Beholder - hand cast", SETTINGS.DEBUG_NPC_ACTIONS)
    end, HAND.ReleaseMs)
end


-- [AUTHORITY] Send the pets home when the fight ends. A summon with nothing to fight is a body the
-- game will never unload on its own.
function BH.BeholderExitCombat(actor)
    local st = mageRow(actor)
    if not st then return end
    for _, m in ipairs(st.Minions) do
        if Utils.IsActorValid(m) then pcall(function() m:K2_DestroyActor() end) end
    end
    st.Minions = {}
    st.Pending = 0
end


-- [AUTHORITY] Drop everything this Beholder owns. The eyes go with it either way, reaped by the
-- subactor book and by the native OwningMage death; this is the bookkeeping half.
function BH.BeholderDeath(actor)
    BH.BeholderExitCombat(actor)

    local st = mageRow(actor)
    if st then
        for _, rec in ipairs(st.Eyes) do
            local key = Utils.IsActorValid(rec.Eye) and AVU.CachedFullName(rec.Eye) or nil
            if key then
                eyeShellDone[key] = nil
                glowState[key] = nil
                poseState[key] = nil
            end
        end
    end

    local mkey = AVU.CachedFullName(actor)
    if mkey then behState[mkey] = nil end
end


return BH
