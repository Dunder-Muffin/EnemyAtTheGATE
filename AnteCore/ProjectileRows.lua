-- =======================================================================
-- ProjectileRows - CUSTOM DT_Projectiles rows, added at runtime with UDataTable:AddRow.
-- The projectile counterpart of ModuleItems/CustomItems, and the same recipe.
--
-- WHY: the native gun (NPC_Base FireRanged_Projectile) builds a shot ENTIRELY off its row - speed,
-- gravity, AoE, bounce, mesh, damage type - and takes only the damage as an argument. A variant
-- that wants "the native shot, different numbers" therefore had to abandon the native path and
-- script its own projectile through PROJ.Queue, paying a spawn in our drain plus an off-hook hop
-- per shot. A cloned row with the numbers changed keeps it native: the engine spawns it from a
-- latent load (outside our hooks), deals its damage on impact, and replicates it.
--
-- SECOND USE - FLIGHT ROWS: a shot that has to stay scripted (PROJ.Queue) still needs its gravity,
-- homing and bounce in a row, because a remote client simulates its own copy of the projectile
-- from the replicated row handle and never sees what the server wrote onto the live movement
-- component. PROJ.Queue's opts.FlightRow repoints the shot at one of these. AnNotes/AnteSystems/Projectile.md.
--
-- THE RULES (all inherited from the item-row work, [[af-custom-items-and-spawners]]):
--   * CLONE, never build from scratch: AddRow(new, FindRow(donor)) is an engine struct copy, so
--     the donor's four soft refs (class, damage type, meshes) arrive intact. They are NEVER
--     written afterwards - pick a donor that already carries the ones you want. A per-field soft
--     copy used to live here and killed a dedicated server inside Apply: soft-object access is
--     only sound on a proven UE4SS build (Utils.SoftRefsSafe), and no row needed it that badly.
--   * Every row is announced BEFORE its native work, so a crash in here names its row.
--   * Scalars are written in place under the running game build's field names (PR.F, from
--     SCHEMA.Projectile). A name for the wrong build reads and writes nothing without complaint - so
--     every write is READ BACK, and a row that fails its readback is not marked ready (callers
--     fall back to their scripted shot).
--   * The projectile row struct has no FText field, the one type Lua cannot write.
--   * Re-applied every world, on EVERY ROLE: a client builds the projectile's ProjectileData
--     from the same row handle, so it needs the row too.
--   * Row name = identity. Nothing saves a projectile, so renaming one is free.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local ASSETS = require("AnteCore.AssetManager")
local ENUMS = require("AnteData.Enums")
local SCHEMA = require("AnteData.Schema")
local SETTINGS = require("Settings")
local STATE = require("AnteCore.State")
local Utils = require("AnteUtils.Utils")
local UEHelpers = require("UEHelpers")
local LogBad = Utils.LogBad
local LogDebug = Utils.LogDebug

local PR = {}

local DT_PROJECTILES = "/Game/Blueprints/DataTables/DT_Projectiles.DT_Projectiles"

-- Projectile row fields, spelled for the running game build (SCHEMA.Projectile).
local P = SCHEMA.Projectile
PR.F = {
    InitialSpeed    = P.InitialSpeed,
    MaxSpeed        = P.MaxSpeed,
    GravityScale    = P.ProjectileGravityScale,
    CollisionRadius = P.CollisionRadius,
    ShouldBounce    = P.ShouldBounce,
    NumberOfBounce  = P.NumberOfBounce,
    Bounciness      = P.Bounciness,
    IsHoming        = P.IsHomingProjectile,
    HomingAccel     = P.HomingAccelerationMagnitude,
    AreaOfEffect    = P.AreaOfEffectDamage,
    AoEMinDamage    = P.AoEMinimumDamage,
    AoEInner        = P.AoE_InnerRadius,
    AoEOuter        = P.AoE_OuterRadius,
    DamageFalloff   = P.DamageFalloff,
    CanHarmDeployables = P.CanHarmDeployables,
    Glint           = P.GlintProjectile,   -- each renderer's BeginPlay lights the parent's ProjectileGlint off it
    -- The four soft refs (DamageType, OptionalProjectileClass, the two meshes) are deliberately
    -- absent: a key listed here can be written, and those must not be.
}

-- [row name] = { CloneFrom = donor row, Scalars = { <PR.F key> = value }, IgnoreShooter = class? }
--   IgnoreShooter = the projectile CLASS the row flies: its shots never hit the NPC that fired them
--   (SHOOTER IGNORE, below).
PR.ROWS = {
    -- Big Bot turret disc: the plasma disc at the pace the scripted shot flew (the row ships 5000).
    [ENUMS.ProjectileRows.BotDisc] = {
        CloneFrom = ENUMS.ProjectileRows.DiscPlasma,
        Scalars = { InitialSpeed = 2000, MaxSpeed = 2000 },
    },
    -- ...and its post-overheat parting shot, at half that.
    [ENUMS.ProjectileRows.BotDiscSlow] = {
        CloneFrom = ENUMS.ProjectileRows.DiscPlasma,
        Scalars = { InitialSpeed = 1000, MaxSpeed = 1000 },
    },
    -- Antefire Exor primary: the plasma bolt at the pace its scripted shot flew. Keeps the donor's
    -- Fire_Plasma_Accuracy - a Fire_Plasma subclass that differs only in the player skill it credits.
    [ENUMS.ProjectileRows.AntefirePlasma] = {
        CloneFrom = ENUMS.ProjectileRows.PlasmaBall,
        Scalars = { InitialSpeed = 1800, MaxSpeed = 1800 },
    },
    -- DarkLens Patriarch burst disc.
    [ENUMS.ProjectileRows.PatriarchDisc] = {
        CloneFrom = ENUMS.ProjectileRows.DiscPlasma,
        Scalars = { InitialSpeed = 1500, MaxSpeed = 1500 },
    },
    -- Warrior Witch jet fireball: slow and flat, down the kick line.
    [ENUMS.ProjectileRows.WitchJetFireball] = {
        CloneFrom = ENUMS.ProjectileRows.MageFireball,
        Scalars = { InitialSpeed = 1300, MaxSpeed = 1300, GravityScale = 0 },
    },

    -- FLIGHT ROWS (opts.FlightRow). Each donor is the row its class ALREADY flies when spawned
    -- directly, so nothing changes but the scalars listed. Speed is per shot (VelocityOverride +
    -- the speed multiplier), so a row only pins it where homing needs the cap to equal the pace.
    -- DarkLens Magus volley, Antefire Exor plasma mortar: the arc solve assumes full gravity.
    [ENUMS.ProjectileRows.FireballLob] = {
        CloneFrom = ENUMS.ProjectileRows.MageFireball,
        Scalars = { GravityScale = 1 },
    },
    -- Beholder Azure eye. HomingAccel mirrors BEHOLDER_EYES.Azure.Homing; hard mode's 500 rides
    -- the multiplier.
    [ENUMS.ProjectileRows.EyeDisc] = {
        CloneFrom = ENUMS.ProjectileRows.DiscPlasma,
        Scalars = { InitialSpeed = 400, MaxSpeed = 400, IsHoming = true, HomingAccel = 550 },
    },
    -- Beholder Amber eye: a molotov fired flat.
    [ENUMS.ProjectileRows.MolotovFlat] = {
        CloneFrom = ENUMS.ProjectileRows.Molotov,
        Scalars = { GravityScale = 0 },
    },
    -- Exor reload seeker. Mirrors SEEKER_QUILL.Speed / .Homing (ExorHelpers).
    [ENUMS.ProjectileRows.SeekerQuill] = {
        CloneFrom = ENUMS.ProjectileRows.QuillSpear,
        Scalars = { InitialSpeed = 600, MaxSpeed = 600, HomingAccel = 800 },
    },
    -- Exor Dislocator's gun: the purple spear, slower and dodgeable. The donor's 20000 homing turns
    -- ~10 rad/s at its own pace - undodgeable - and a slower shot turns tighter still (turn rate =
    -- accel / speed), so the homing has to come down with the speed. 600 at 1000 is ~34 deg/s,
    -- about the base Exor quill's turn at launch. Initial = Max keeps it from speeding up in flight.
    -- IgnoreShooter: it blinks forward mid-burst, into a clip of spears slower than itself.
    [ENUMS.ProjectileRows.DislocatorSpear] = {
        CloneFrom = ENUMS.ProjectileRows.QuillSpear,
        Scalars = { InitialSpeed = 1000, MaxSpeed = 1000, HomingAccel = 600, CollisionRadius = 5 },
        IgnoreShooter = ENUMS.ProjectileClasses.QuillSpear,
    },
    -- Gatekeeper Mage hardlight bolt (the Abjurer's axe): the donor throws it into the floor.
    [ENUMS.ProjectileRows.HardlightBolt] = {
        CloneFrom = ENUMS.ProjectileRows.HardlightSpear,
        Scalars = { GravityScale = 0 },
    },
    -- Order Captain Trident net.
    [ENUMS.ProjectileRows.NetFlat] = {
        CloneFrom = ENUMS.ProjectileRows.NetAmmo,
        Scalars = { GravityScale = 0 },
    },
    -- Canaan Marksman holy bolt: flat, and with the game's own tracer flare on (the donor ships it off).
    [ENUMS.ProjectileRows.HolyBoltFlat] = {
        CloneFrom = ENUMS.ProjectileRows.HolyFireball,
        Scalars = { GravityScale = 0, Glint = true },
    },
    -- Canaan Lumberjack axe. Mirrors AXE.Gravity (PillagerHelpers) - the aim solve uses it.
    [ENUMS.ProjectileRows.ThrownAxe] = {
        CloneFrom = ENUMS.ProjectileRows.ThrownWeapon,
        Scalars = { GravityScale = 0.25 },
    },
    -- Office Bot supply fan (mirrors THROW_GRAVITY) and its hard-mode direct throw. No bounce:
    -- a supply that skips off the floor reads as a second shot.
    [ENUMS.ProjectileRows.OfficeThrow] = {
        CloneFrom = ENUMS.ProjectileRows.ThrownGenericItem,
        Scalars = { GravityScale = 0.45, ShouldBounce = false },
    },
    [ENUMS.ProjectileRows.OfficeDirect] = {
        CloneFrom = ENUMS.ProjectileRows.ThrownGenericItem,
        Scalars = { GravityScale = 0, ShouldBounce = false },
    },

    -- IDENTITY ROWS: the donor's numbers untouched. They exist so a remote client can recognise
    -- the shot (PR.LOOKS below) where the class's own row is also a player's or a native NPC's.
    [ENUMS.ProjectileRows.EyeFlask]   = { CloneFrom = ENUMS.ProjectileRows.FlaskCorrosive },
    [ENUMS.ProjectileRows.EyeSeeker]  = { CloneFrom = ENUMS.ProjectileRows.ExorSpike },
    [ENUMS.ProjectileRows.FireMortar] = { CloneFrom = ENUMS.ProjectileRows.Molotov },
    [ENUMS.ProjectileRows.LamogiBolt] = { CloneFrom = ENUMS.ProjectileRows.PlasmaBall },
    -- ...and two that change one thing on the way: the ghost bolt is fired with no HomingTarget,
    -- and the Antefire mortar's arc solve assumes full gravity (the fireball row ships 0.1).
    [ENUMS.ProjectileRows.GhostOrb] = {
        CloneFrom = ENUMS.ProjectileRows.ShadowOrb,
        Scalars = { IsHoming = false },
    },
    [ENUMS.ProjectileRows.PlasmaMortar] = {
        CloneFrom = ENUMS.ProjectileRows.MageFireball,
        Scalars = { GravityScale = 1 },
    },
}

-- [row name] = how a shot flying that row LOOKS - the renderer-local half no property carries.
-- One definition for both ends: PROJ.Queue takes these as the defaults for what a caller does
-- not say, and AnteVariants/ClientProjectiles applies them to a remote client's copy.
--   Trail / TrailScale  a Niagara welded on for the flight (path; uniform scale)
--   TrailRot            { pitch, yaw, roll } relative rotation of that trail: a streak authored
--                       along +X lies AHEAD of the shot until it is turned round
--   HideMesh            the row's own mesh hidden, the trail being the look
--   Scale               uniform ACTOR scale (the mesh follows; a Niagara may not, hence TrailScale)
--   MeshRot             { pitch, yaw, roll } relative rotation of SM_Appearance, after the mesh lands
--   Native              the row is fired by a NATIVE gun (AVU.SetProjectileRow), so no PROJ.Queue
--                       dresses it on the server: ClientProjectiles dresses it on a host as well
-- Plain numbers, not FVector/FRotator: a UE4SS struct constructor at module scope depends on load order.
PR.LOOKS = {
    [ENUMS.ProjectileRows.SeekerQuill]   = { Scale = 3 },
    [ENUMS.ProjectileRows.DislocatorSpear] = { Scale = 1.3, Native = true },
    [ENUMS.ProjectileRows.EyeDisc]       = { Scale = 2 },   -- the disc is small at native size for something meant to be seen coming
    [ENUMS.ProjectileRows.MolotovFlat]   = { Scale = 0.7, Trail = ENUMS.Effects.WISP_RED, TrailScale = 0.7 },
    [ENUMS.ProjectileRows.EyeFlask]      = { Scale = 0.7, Trail = ENUMS.Effects.WISP_GREEN, TrailScale = 0.7 },
    [ENUMS.ProjectileRows.EyeSeeker]     = { Trail = ENUMS.Effects.EXOR_CHARGEUP, TrailScale = 0.6 },
    [ENUMS.ProjectileRows.GhostOrb]      = { Scale = 0.7, HideMesh = true, Trail = ENUMS.Effects.EXOR_CHARGEUP_CHA },
    [ENUMS.ProjectileRows.FireMortar]    = { HideMesh = true, Trail = ENUMS.Effects.NIAGARA_FIREBALL },   -- molotov gameplay, fireball look
    [ENUMS.ProjectileRows.PlasmaMortar]  = { HideMesh = true, Trail = ENUMS.Effects.PLASMA_PROJECTILE },
    -- The spear's authored rotation points it UP, not along the flight. If it still reads wrong,
    -- this is the one place to flip (the pitch sign, or roll instead of pitch).
    [ENUMS.ProjectileRows.HardlightBolt] = { Scale = 1.5, MeshRot = { -90, 0, 0 } },
    [ENUMS.ProjectileRows.NetFlat]       = { Scale = 2 },
    [ENUMS.ProjectileRows.ThrownAxe]     = { Scale = 0.7 },
    [ENUMS.ProjectileRows.OfficeThrow]   = { Scale = 1.4 },
    [ENUMS.ProjectileRows.OfficeDirect]  = { Scale = 1.4 },
    [ENUMS.ProjectileRows.LamogiBolt]    = { Scale = 1.5 },
    -- The bolt's body is a pebble. BoltTrail_Holy is a ~2m line on its own +X, which the flight
    -- rotation lays along the path, ahead of the bolt: turned round, x4 is an ~8m streak behind it.
    [ENUMS.ProjectileRows.HolyBoltFlat]  = { Trail = ENUMS.Effects.NIAGARA_BOLTTRAIL_HOLY, TrailScale = 4,
                                             TrailRot = { 0, 180, 0 } },
}

local ready = {}   -- row name -> true once it exists in THIS world with every write read back
local liveNumbers = {}   -- "row|field" -> number (false = unreadable), this world


local function rowValid(row)
    local ok, valid = pcall(function() return row ~= nil and row:IsValid() end)
    return ok and valid == true
end

-- Numbers compare loosely: a double survives the round trip, a float field would not exactly.
local function sameValue(a, b)
    if type(a) == "number" and type(b) == "number" then return math.abs(a - b) < 0.01 end
    return a == b
end

local function buildRow(dt, name, def)
    local row
    pcall(function() row = dt:FindRow(name) end)
    if not rowValid(row) then
        local donor
        pcall(function() donor = dt:FindRow(def.CloneFrom) end)
        if not rowValid(donor) then return false, "donor row '" .. tostring(def.CloneFrom) .. "' not found" end
        if not pcall(function() dt:AddRow(name, donor) end) then return false, "AddRow threw" end
        pcall(function() row = dt:FindRow(name) end)
        if not rowValid(row) then return false, "clone did not read back" end
    end

    if def.SoftCopy then return false, "SoftCopy is not supported (see the file header)" end

    -- Scalars LAST, so they beat the donor. Written every world: a surviving row costs nothing to
    -- re-assert, and a re-made table would otherwise hand back the donor's numbers.
    for key, value in pairs(def.Scalars or {}) do
        local field = PR.F[key]
        if not field then return false, "unknown field key '" .. tostring(key) .. "'" end
        LogDebug("ProjectileRows -   " .. key .. " = " .. tostring(value) .. " ...", SETTINGS.DEBUG_NPC_ACTIONS)
        pcall(function() row[field] = value end)
        local got
        pcall(function() got = row[field] end)
        if not sameValue(got, value) then
            return false, string.format("%s wrote %s, read back %s", key, tostring(value), tostring(got))
        end
    end
    return true
end


local function buildAll(dt)
    if not dt or not dt.AddRow then
        LogBad("ProjectileRows - DT_Projectiles row API unavailable; custom projectile rows skipped")
        return 0
    end

    -- Native layout: nothing else holds DT_Projectiles, so a GC would reload it without our rows.
    if SCHEMA.Native then ASSETS.HoldTable(DT_PROJECTILES) end

    local n = 0
    for name, def in pairs(PR.ROWS) do
        -- BEFORE the native work, and not debug-gated: if the process dies in here, this is the
        -- log's last word and it names the row.
        Utils.Log("ProjectileRows - building '" .. tostring(name) .. "' <- " .. tostring(def.CloneFrom))
        local ok, why = buildRow(dt, name, def)
        if ok then
            ready[name] = true
            n = n + 1
            LogDebug("ProjectileRows - '" .. name .. "' ready (cloned from " .. tostring(def.CloneFrom) .. ")",
                SETTINGS.DEBUG_NPC_ACTIONS)
        else
            LogBad("ProjectileRows - '" .. tostring(name) .. "' FAILED: " .. tostring(why))
        end
    end
    return n
end

-- [ALL ROLES, every world init] Build every row in PR.ROWS. Idempotent.
--   * Through ASSETS.WithDataTable: the native layout loads DT_Projectiles lazily, so it can be
--     cold here and the rows then land a moment later, off-hook. Until then PR.Ready is false and
--     callers take their scripted shot.
function PR.Apply()
    ready = {}
    liveNumbers = {}
    -- The setting is the AUTHORITY's choice. A client builds the rows regardless: a projectile
    -- whose row it cannot find destroys itself in BeginPlay, so the shot would be invisible.
    if SETTINGS.CORE.CUSTOM_PROJECTILE_ROWS == false and Utils.IsAuthority() then
        Utils.Log("ProjectileRows - off (CORE.CUSTOM_PROJECTILE_ROWS): variants keep their scripted shots")
        return
    end
    ASSETS.WithDataTable(DT_PROJECTILES, buildAll)
end

function PR.Ready(name)
    return ready[name] == true
end

function PR.Table()
    return ASSETS.GetDataTable(DT_PROJECTILES)
end

-- One scalar off a LIVE row, native or ours (`key` is a PR.F key). Cached per world: a row's
-- numbers do not change after Apply. FindRow is FName-keyed, so the name's casing is free.
function PR.RowNumber(name, key)
    local field = PR.F[key]
    if not field or not name or name == "" or name == "None" then return nil end
    local slot = name:lower() .. "|" .. key
    local hit = liveNumbers[slot]
    if hit ~= nil then return hit or nil end

    local got
    local dt = PR.Table()
    if dt then
        pcall(function()
            local row = dt:FindRow(name)
            if rowValid(row) then got = tonumber(row[field]) end
        end)
    end
    liveNumbers[slot] = got or false
    return got
end


-- =======================================================================
-- SHOOTER IGNORE (authority) - a row flagged IgnoreShooter never hits the NPC that fired it.
--   * A native gun's shot carries the NPC as INSTIGATOR and no OWNER, so the parent's
--     IgnoreOwnerCollision never runs. The overlap door skips the instigator anyway, but the
--     blocking-hit door (ReceiveHit) reads only MoveIgnoreActors - so a shooter that moves or blinks
--     into its own slow shot takes it. Both doors: the ANTI-SELF-COLLISION block, AnteCore/Projectile.
--   * The instigator goes into the shot's MoveIgnoreActors for its whole flight (the parent's own
--     owner-ignore would lapse after 0.1s).
--   * The notify is on the flagged rows' classes only, and only queues. The queued item re-finds the
--     shot by ADDRESS among that class's live actors (the ClientProjectiles pattern: a projectile has
--     no EndPlay stamp, so its wrapper is never trusted after a wait). One drain late, the shot is
--     only a metre or two out - well short of where a blink lands its shooter.
-- =======================================================================
local shooterIgnoreRows = {}   -- class path -> { lowercased row name = true }

local function liveShotAt(cls, addr)
    local gs, world = UEHelpers.GetGameplayStatics(), Utils.GetWorld()
    if not gs or IsNotValid(world) or IsNotValid(cls) then return nil end
    local out = {}
    if not pcall(function() gs:GetAllActorsOfClass(world, cls, out) end) then return nil end
    for i = 1, #out do
        local a = out[i]
        local okg, inner = pcall(function() return out[i]:get() end)
        if okg and inner then a = inner end
        local aAddr
        pcall(function() aAddr = a:GetAddress() end)
        if aAddr == addr then return a end
    end
    return nil
end

local function ignoreShooter(classPath, proj)
    if not STATE.ModEnabled then return end
    local addr
    pcall(function() addr = proj:GetAddress() end)
    if not addr then return end
    local p = liveShotAt(ASSETS.GetIfPinned(classPath) or ASSETS.GetIfValid(classPath), addr)
    if not p then return end   -- already spent

    local row
    pcall(function() row = p.ProjectileDataRowHandle.RowName:ToString() end)
    local rows = shooterIgnoreRows[classPath]
    if not row or not rows or not rows[row:lower()] then return end

    local inst
    pcall(function() inst = p:GetInstigator() end)
    if not Utils.IsActorValid(inst) then return end
    pcall(function() p.ProjectileCollision:IgnoreActorWhenMoving(inst, true) end)
end

-- [AUTHORITY, every world] Arm SHOOTER IGNORE for every flagged row. The notify is per UE4SS
-- session (it cannot be removed), so each class latches on STATE; its callback reads the row table
-- above, which this rebuilds.
function PR.ArmShooterIgnore()
    if not Utils.IsAuthority() then return end
    shooterIgnoreRows = {}
    for name, def in pairs(PR.ROWS) do
        local cls = def.IgnoreShooter
        if cls and ready[name] then
            shooterIgnoreRows[cls] = shooterIgnoreRows[cls] or {}
            shooterIgnoreRows[cls][name:lower()] = true
        end
    end

    STATE.ShooterIgnoreArmed = STATE.ShooterIgnoreArmed or {}
    for cls in pairs(shooterIgnoreRows) do
        if not STATE.ShooterIgnoreArmed[cls] then
            ASSETS.LoadAsync({ cls }, function()
                if STATE.ShooterIgnoreArmed[cls] then return end
                ASSETS.WarmPinned({ cls })   -- loaded only to hook: pin it, or the notify dies with it
                local ok, err = pcall(NotifyOnNewObject, cls, function(proj)
                    Utils.QueueWork(function() ignoreShooter(cls, proj) end, 0)
                end)
                if ok then
                    STATE.ShooterIgnoreArmed[cls] = true
                    Utils.Log("ProjectileRows - shooter ignore armed on " .. cls)
                else
                    LogBad("ProjectileRows - shooter ignore notify FAILED: " .. tostring(err))
                end
            end)
        end
    end
end


-- [AUTHORITY] Loose one custom row down the NPC's native gun, aimed at `aim` (a plain FVector).
-- Returns false when the row is not ready, so the caller can fall back to its scripted shot.
--   * An EXPLICIT { DataTable, RowName } handle, unlike AVU.FireProjectileRow, which repoints the
--     NPC's own GrenadeData: not every base ships that handle pointed at DT_Projectiles, and a null
--     table makes the native row lookup fail without a word.
--   * Safe in the drain: the native body is a row lookup plus a LATENT class load, and the spawn
--     runs from its OnLoaded, in the engine's own tick. It does not fan out the way
--     Server_DoRangedAttack does.
--   * The native body bails on a stunned, dead or downed shooter. Check IsStunned first if the
--     shot must leave regardless.
function PR.Fire(actor, name, dmg, aim)
    if not Utils.IsAuthority() or not PR.Ready(name) then return false end
    if Utils.IsActorInvalid(actor) or actor.IsDead or actor.IsDBNO then return false end

    -- The table pointer is a legacy handle field only; a native handle is the row name alone.
    local dt = not SCHEMA.Native and ASSETS.GetDataTable(DT_PROJECTILES) or nil
    if not dt and not SCHEMA.Native then return false end

    if aim then pcall(function() actor.LastRangedAttackLocation = aim end) end
    return (pcall(function()
        actor:FireRanged_Projectile(SCHEMA.MakeHandle(name, { DataTable = dt }), dmg)
    end))
end

return PR
