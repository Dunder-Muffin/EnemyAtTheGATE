-- =======================================================================
-- AVUtils (AVU) - the shared actor-modification helpers every AnteNPC variant uses.
--
-- GROUND RULES (they apply to most of these)
--   * Call only from the game thread (a hook callback or the WorkQueue drain).
--   * Disable a component's collision BEFORE SetStaticMesh - it recreates the physics state and
--     can corrupt Chaos, which crashes much later and is miserable to diagnose.
--   * Re-validate actor/component/mesh between every engine call; any of them can be destroyed
--     under us, and IsValid lies about a freed slot (CLAUDE.md 3).
--
-- WHAT LIVES HERE: stats, factions, loot, immobilisers, animation, abilities, gravity, tick
-- registration, targeting/AI, spatial queries, damage and launches.
--
-- WHAT LIVES ELSEWHERE (all merged onto AVU at the bottom, so callers still write AVU.<fn>):
--   AVAppearance.lua  materials, tint, helmet glass, opacity, robot eye, customization, audio
--   AVSenses.lua      sight / hearing / noise events / Eyesight
--   AVShields.lua     BodyShieldComponent, its bubble, the shield-medic kit
--   AVPets.lua        tamed-pet HP, mesh scale, level, follower buff
--   AVWorldFX.lua     blizzard weather, screen tint, client warp mirror
--   AVInventory.lua   player inventory writes + the safe hotbar refresh
--   AVAttach.lua      attachments & subactors      ClientFX.lua  FX onto every machine
--   Spawning.lua      new actors into the world
-- NOT merged, required under their own names: Lasers.lua (`Lasers`, ULaserComponent beams) and
-- AVMath.lua (`AVM`, pure geometry/ballistics with no engine surface).
--
-- Deep decode and post-mortems for the helpers here: AnNotes/AnteSystems/AVUtils.md.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local UEHelpers = require("UEHelpers")
local STATE = require("AnteCore.State")
local SETTINGS = require("Settings")
local ASSETS = require("AnteCore.AssetManager")
local Utils = require("AnteUtils.Utils")
local VariantSignal = require("AnteVariants.VariantSignal")
local ENUMS = require("AnteData.Enums")
local SCHEMA = require("AnteData.Schema")
local Items = require("AnteData.Items")
local DebugUtils = require("AnDebug.DebugUtils")
local AFUtils = require("AFUtils.AFUtils")
local LogDebug = Utils.LogDebug
local LogBad = Utils.LogBad
local Log = Utils.Log

-- "<lever>:<NPC name>" -> already shouted about. A broken body usually comes in waves, and one
-- line per variant is the useful amount; the name is what you look up in the defs.
local statsFailReported = {}


-- XP per hit
-- Most variants get an XP bonus, Bots don't (their default is lower)
local XP_MULT_DEFAULT = 1.5
local XP_MULT_ROBOT   = 0.5
local XP_MULT_BY_VARIANT = {
    ["Artillery Bot"] = 0.1,   -- BT stripped (see AnteNPCs/RobotDefense) = free sneak bonuses
}
local XP_ROBOT_ROWS = {
    ["Robot_Security"]    = true,
    ["Robot_Containment"] = true,
    ["Robot_Defense"]     = true,
    ["Robot_Corrupt"]     = true,
}

-- THIS `@class` LINE IS WHAT MAKES GOTO-DEFINITION WORK ACROSS THE MERGE at the bottom of the
-- file. The merge is a runtime `pairs()` copy that no language server can follow, so the same
-- relationship is stated statically: each submodule tags its table `---@class AVU.<Name>` and AVU
-- inherits from all of them. Ctrl-click on AVU.PortalSummon then lands on Spawning.lua.
-- Pure annotation, zero runtime effect - and adding a submodule means editing BOTH lists.
---@class AVU : AVU.Spawning, AVU.Attach, AVU.ClientFX, AVU.Appearance, AVU.Senses, AVU.Shields, AVU.Pets, AVU.WorldFX, AVU.Inventory
local AVU = {}


-- =======================================================================
-- ApplyBaseStats - common server-side setup for every variant.
-- AUTHORITY ONLY (touches NPCData / perception).
-- =======================================================================

-- NOTHING in here may raise. It runs FIRST in the STATS step - ahead of the HP/damage knobs and
-- ahead of the VariantTag - and a raised error abandons the rest of that step, which leaves a body
-- carrying the variant's NAME at its base's full strength. `actor.NPCData` also cannot be tested
-- for truthiness: a missing UObject property reads as a TrivialObject placeholder, so the old
-- `if actor.NPCData` passed on an unreadable struct and the write below threw.

function AVU.ApplyBaseStats(actor, opts, variantName)
    opts = opts or {}

    local npcData
    pcall(function() npcData = actor.NPCData end)
    if IsNotValid(npcData) then
        local key = "base:" .. tostring(variantName)
        if not statsFailReported[key] then
            statsFailReported[key] = true
            LogBad("ApplyBaseStats - NPCData unreadable on " .. tostring(variantName)
                .. "; nothing in STATS can land, so the body stays unnamed and vanilla")
        end
        return
    end

    -- Variant name lives in DisplayName. NOTE: does NOT replicate -
    -- each machine rebuilds NPCData locally from the NPC data table.
    if variantName then
        pcall(function() npcData[ENUMS.NpcData.DisplayName] = FText(variantName) end)
    end

    -- Variants give bonus XP. Keyed off the base ROW NAME (not def.Base) so it holds for
    -- AltBases / SpawnAs bodies too; per-variant override wins. See the XP_MULT_* knobs.
    pcall(function()
        npcData[ENUMS.NpcData.HitXpMultiplier] =
            XP_MULT_BY_VARIANT[variantName]
            or (XP_ROBOT_ROWS[Utils.GetActorRowName(actor)] and XP_MULT_ROBOT)
            or XP_MULT_DEFAULT
    end)

    -- NO blanket sense boost here: doubling every variant's sight radius starved the engine's
    -- time-sliced sight sense (13-16s to first perception, with the spot meter itself healthy).
    -- A variant that wants sharper senses sets them EXPLICITLY in its own Stats.

    if opts.Faction then
        pcall(function() actor.Faction = opts.Faction end)
    end
end


-- def.Health key -> NPCData limb-HP field. Setting these + InitalizeHealthValues rebuilds
-- the limb map (see ENUMS.NpcData for the raw fields).
local HP_FIELDS = {
    Head     = ENUMS.NpcData.HpHead,
    Torso    = ENUMS.NpcData.HpTorso,
    LeftArm  = ENUMS.NpcData.HpLeftArm,
    RightArm = ENUMS.NpcData.HpRightArm,
    LeftLeg  = ENUMS.NpcData.HpLeftLeg,
    RightLeg = ENUMS.NpcData.HpRightLeg,
}

-- The same six limbs as E_BodyLimbs values - what the native per-limb health accessors take.
local HP_LIMBS = {
    ENUMS.EBodyLimbs.Head, ENUMS.EBodyLimbs.Torso,
    ENUMS.EBodyLimbs.LeftArm, ENUMS.EBodyLimbs.RightArm,
    ENUMS.EBodyLimbs.LeftLeg, ENUMS.EBodyLimbs.RightLeg,
}

-- Each live limb's health as a fraction of its CURRENT max, or nil. Read before a rebuild moves
-- anything: the NATIVE scalars are the real health, the limb maps a BP-side mirror (the AVPets
-- header has the model). A limb with no pool (a head-only NPC's torso) is skipped, and one that
-- GAINS a pool isn't in the table, so it starts full - which is what a new pool should do.
local function limbFractions(actor)
    local frac
    for i = 1, #HP_LIMBS do
        local limb, cur, max = HP_LIMBS[i]
        pcall(function()
            cur = tonumber(actor:GetLimbHealth(limb))
            max = tonumber(actor:GetMaxLimbHealth(limb))
        end)
        if cur and max and max > 0 then
            frac = frac or {}
            frac[limb] = math.min(1, math.max(0, cur / max))
        end
    end
    return frac
end

-- Re-apply limbFractions to the NEW max, so a rebuild that also moves the pool neither heals nor
-- punishes. An UNHURT limb is re-asserted too: that keeps the native scalar in step with the max
-- just written, so a second rebuild in the same STATS step can't read the stale smaller number as damage.
local function restoreLimbFractions(actor, frac)
    if not frac then return end
    local curMap
    pcall(function() curMap = actor.Current_LimbHealthMap end)
    for limb, f in pairs(frac) do
        local newMax
        pcall(function() newMax = tonumber(actor:GetMaxLimbHealth(limb)) end)
        if newMax and newMax > 0 then
            local newCur = newMax * f
            pcall(function() actor:SetLimbHealth(limb, newCur) end)          -- real health
            if curMap then pcall(function() curMap:Add(limb, newCur) end) end -- BP mirror
        end
    end
    -- The GetOnly PULL is what refreshes the cached total behind the nameplate (a TABLE per
    -- out-param; a bare call silently no-ops).
    pcall(function() actor:GetAndSetTotalHealth(true, {}, {}, {}) end)
end


-- [AUTHORITY] Set a PET's level: applies the native health/damage scaling, and shows on the
-- nameplate. The game bakes level scaling in at spawn and only above level 1, but everything
-- spawns AS level 1 - hence this. Size is NOT scaled with it (see AVU.ScalePetMesh).
--   * InitializeNPCVariables rebuilds health from scratch, a full heal, so every re-mutation of a
--     hurt pet topped it up. Each limb's fraction is carried across, as SetLimbHealth does.
function AVU.SetNpcLevel(actor, level)
    if Utils.IsActorInvalid(actor) then return end
    if not level or level < 2 then return end   -- level 1 = no scaling, nothing to do
    local frac = limbFractions(actor)
    pcall(function()
        actor["NPC Level"] = level
        actor:InitializeNPCVariables()
    end)
    restoreLimbFractions(actor, frac)
end


-- The six NPCData limb-HP fields summed - the numbers InitalizeHealthValues rebuilds the map from.
local function npcDataHpSum(npcData)
    local sum = 0
    for _, field in pairs(HP_FIELDS) do sum = sum + (tonumber(npcData[field]) or 0) end
    return sum
end

-- DefaultMax_LimbHealthMap summed, or nil if it can't be read. This is the map the rebuild writes,
-- and the one to check against: GetTotalHealth() reads Current_LimbHealthMap, which is populated
-- LAZILY - it keeps reporting the row's numbers until a hit actually reaches health, so a body
-- behind a shield can read its base total for minutes after a perfectly good stat write.
local function maxMapSum(actor)
    local sum, ok = 0, false
    pcall(function()
        actor.DefaultMax_LimbHealthMap:ForEach(function(_, v)
            local vv = v; pcall(function() vv = v:get() end)
            sum = sum + (tonumber(vv) or 0)
        end)
        ok = true
    end)
    return ok and sum or nil
end


-- [AUTHORITY] Set per-limb max HP, then rebuild the limb maps.
-- hp = { Head=, Torso=, LeftArm=, RightArm=, LeftLeg=, RightLeg= }.
--   * InitalizeHealthValues(sic), NOT InitializeNPCVariables: the full re-init also resets Faction,
--     so this stays faction-safe and composes with def.Faction.
--   * DAMAGE SURVIVES. The rebuild restores every limb to full, so this used to heal any body it
--     ran on twice - a re-mutated NPC got its whole bar back mid-fight. Each limb's damage is
--     re-applied as a fraction of its NEW max afterwards. A caller that WANTS a heal calls
--     InitalizeHealthValues itself (ModuleStory/PillagerHelpers does).
--   * The HP model and the head-only families: the def.BasicStats section in CLAUDE.md.
--   * VERIFIED, and loudly. This is the number that decides how long a body takes to kill, and
--     every failure path here used to return silently - an un-statted body is indistinguishable
--     from a correct one until you count bullets into it. The check watches the total MOVE rather
--     than matching an absolute, so a world running EnemyHealthMultiplier can't cry wolf.

function AVU.SetLimbHealth(actor, hp)
    if Utils.IsActorInvalid(actor) or type(hp) ~= "table" then return end

    local why, before, after, want = "threw part-way", nil, nil, nil
    pcall(function()
        local npcData = actor.NPCData
        if IsNotValid(npcData) then why = "NPCData invalid"; return end

        local fieldsBefore = npcDataHpSum(npcData)
        before = maxMapSum(actor)

        local frac = limbFractions(actor)

        for key, field in pairs(HP_FIELDS) do
            if hp[key] ~= nil then npcData[field] = hp[key] end
        end
        for key, field in pairs(HP_FIELDS) do   -- a field that didn't take = the write hit a copy
            if hp[key] ~= nil and (tonumber(npcData[field]) or -1) ~= hp[key] then
                why = "NPCData." .. field .. " did not take"; return
            end
        end
        want = npcDataHpSum(npcData)

        actor:InitalizeHealthValues((actor["NPC Level"] or 1) > 1)
        after = maxMapSum(actor)

        restoreLimbFractions(actor, frac)   -- hard mode's bigger head neither heals nor punishes

        -- The rebuild writes the max map off the fields above, so a real change has to move it.
        -- An unreadable map is not evidence of anything, so it stays quiet.
        why = (before and after and want ~= fieldsBefore and after == before)
            and "max limb map unchanged - InitalizeHealthValues did not rebuild" or nil
    end)
    if not why then return end

    local key = "limb:" .. (Utils.GetActorNPCName(actor) or "?")
    if statsFailReported[key] then return end
    statsFailReported[key] = true
    LogBad(("SetLimbHealth FAILED on %s - %s (NPCData sum %s, max map %s -> %s)")
        :format(Utils.GetActorNPCName(actor) or "?", why,
                tostring(want), tostring(before), tostring(after)))
end


-- NPCData damage-type fields (DT_NPCList row struct) the NPC fires/swings with.
local DT_RANGED_FIELD = ENUMS.NpcData.RangedDamageType
local DT_MELEE_FIELD  = ENUMS.NpcData.MeleeDamageType

-- [AUTHORITY] Re-theme an NPC's attacks: swap its RANGED (default) or MELEE damage type to the
-- class at `path` (a bleed-free type to strip a bullet's bleed, an electric/holy one, ...).
-- Async-loads the class first, so it works cold AND stays safe in the STATS step's in-hook drain.
--   isMelee = true swaps the melee type instead of the ranged one.

function AVU.ChangeDamageType(actor, path, isMelee)
    if Utils.IsActorInvalid(actor) or not path then return end
    ASSETS.LoadAsync({ path }, function(results)
        if Utils.IsActorInvalid(actor) then return end
        local cls = results[path]
        if IsNotValid(cls) then LogBad("ChangeDamageType - class not loaded: " .. tostring(path)); return end
        local npcData = actor.NPCData
        if IsNotValid(npcData) then return end
        pcall(function() npcData[isMelee and DT_MELEE_FIELD or DT_RANGED_FIELD] = cls end)
    end)
end


-- The per-region ARMOR fields (Abiotic_Character_ParentBP, the NPC_Base parent). Friendly
-- key -> the real field. NOTE the regions differ from HP: 4 groups, Chest (= the whole
-- torso), Arms (both), Legs (both), Head.
local ARMOR_FIELDS = {
    Head  = "CurrentArmor_Head",
    Chest = "CurrentArmor_Chest",
    Arms  = "CurrentArmor_Arms",
    Legs  = "CurrentArmor_Legs",
}

-- [AUTHORITY] Per-region ARMOR - a % damage reduction the pipeline reads LIVE per hit, so there
-- is no re-init.
--   * armor = { Head=, Chest=, Arms=, Legs= }, any subset; omitted regions keep the base 0.
--   * ~3%/point, linear to ~60% at 20, then diminishing to a 0.95 cap. Tuning: CLAUDE.md.

function AVU.SetArmor(actor, armor)
    if Utils.IsActorInvalid(actor) or type(armor) ~= "table" then return end
    pcall(function()
        for key, field in pairs(ARMOR_FIELDS) do
            if armor[key] ~= nil then actor[field] = armor[key] end
        end
    end)
end


-- [AUTHORITY] UN-IMMUNE an NPC to its DT row's DamageImmunities, with no hook at all.
-- ProcessDamage's immune branch is literally `FinalDamage * ImmuneDamageMultiplier`, a plain
-- per-actor double defaulting to 0 - so 1 makes every "immune" type land at face value and 0.25
-- makes it a heavy resist.
--   * ALL-OR-NOTHING per actor (check the row in FModel's DT_NPCList), so it only replaces the
--     GetResponseToDamageType post-hook when the row's immunity list is a SINGLE entry.
--   * The immune branch returns early, so an un-immuned hit also skips the native weakness/resist
--     steps. Reference: the Outcast in AnteNPCs/Pillager.lua.

function AVU.SetImmuneDamageMultiplier(actor, mult)
    if Utils.IsActorInvalid(actor) then return end
    pcall(function() actor.ImmuneDamageMultiplier = mult or 1 end)
end


-- BasicStats key -> destination. Three buckets, partitioned by AVU.ApplyBasicStats:
--   Hp<Limb>      -> per-limb max HP (routed through SetLimbHealth: needs the
--                    InitalizeHealthValues rebuild; faction-safe).
--   Armor<Region> -> per-region flat reduction (routed through SetArmor; read live).
--   the rest      -> direct NPCData field write (movement / damage / attack knobs).
local BS_HP = {
    HpHead = "Head", HpTorso = "Torso",
    HpLeftArm = "LeftArm", HpRightArm = "RightArm",
    HpLeftLeg = "LeftLeg", HpRightLeg = "RightLeg",
}
local BS_ARMOR = {
    ArmorHead = "Head", ArmorChest = "Chest", ArmorArms = "Arms", ArmorLegs = "Legs",
}
local BS_NPCDATA = {
    WalkSpeed            = ENUMS.NpcData.WalkSpeed,
    SprintSpeed          = ENUMS.NpcData.SprintSpeed,
    MeleeDamage          = ENUMS.NpcData.MeleeDamage,
    MeleeAttackRange     = ENUMS.NpcData.MeleeAttackRange,
    RangedDamage         = ENUMS.NpcData.RangedDamage,
    RangedAttackRange    = ENUMS.NpcData.RangedAttackRange,
    RangedAttackCooldown = ENUMS.NpcData.RangedAttackCooldown,
    HasRangedAttack      = ENUMS.NpcData.HasRangedAttack,
}

-- The BasicStats keys that decide how DANGEROUS a body is - see AVU.ApplySafetyStats. Deliberately
-- EXCLUDES the speeds (they carry the VariantTag fraction, so pre-writing them would forge the
-- "mutation finished" marker) and Armor (a reduction, which can only make an un-mutated body tankier).
local BS_SAFETY = {
    HpHead    = true, HpTorso    = true,
    HpLeftArm = true, HpRightArm = true,
    HpLeftLeg = true, HpRightLeg = true,
    MeleeDamage = true, RangedDamage = true,
}

-- [AUTHORITY] Re-point an NPC's projectile at a different DT_Projectiles row. The native firing
-- path reads the row handle at fire time, so this re-points everything for free - the new
-- projectile spawns, replicates and impacts with no scripted spawn of ours. Property names differ
-- per base: ExorProjectile, FireballProjectile, CrossbowProjectile, ProjectileRow, GrenadeData.
--
-- TWO MODES, AND THE DIFFERENCE MATTERS (CLAUDE.md 3):
--   default  read the handle, set RowName, WRITE THE STRUCT BACK - a bare nested write can land on
--            a COPY of the struct and silently do nothing.
--   inPlace  nested write ONLY. Required when the struct holds a SOFT-OBJECT pointer (the Sow's
--            ProjectileRow, the Captain's GrenadeData): UE4SS mangles those on a writeback.
-- Unsure which? Use inPlace and test - a missed swap is a bug, a mangled soft-ptr is a crash.

function AVU.SetProjectileRow(actor, prop, row, inPlace)
    if Utils.IsActorInvalid(actor) or not prop or not row then return end

    pcall(function()
        if inPlace then
            actor[prop].RowName = FName(row)
            return
        end
        local h = actor[prop]
        h.RowName = FName(row)
        actor[prop] = h
    end)
end


-- =======================================================================
-- SetInvulnerable - make an NPC actually unkillable, which `Invincible` alone DOES NOT DO.
-- That flag is only ever consulted INSIDE the damage pipeline, and two things kill without going
-- anywhere near it:
--   * THE BLACK HOLE GRENADE hard-destroys a character at <200uu. It checks exactly ONE thing
--     first - the actor TAG "blackholeimmune" - and with it re-routes to a huge ApplyPointDamage
--     instead, which Invincible eats. That is how the game protects its own bosses, so we tag too.
--   * THE NUKE VAC has NO defence. Its whitelist is keyed on the victim's SKELETAL MESH and the U2
--     upgrade lists SK_MageEyeDrone by path, so anything built on the Mage Eye is vacuum-able BY
--     DESIGN - counter-play, not a bug (AVU.IsVacuumable answers the question).
-- Also worth knowing, with no helper - just don't: ForceGibNPC writes IsDead on a LIVING NPC with
-- no Invincible check, and the AI Director's EndAssault destroys every still-alive NPC in its list.
-- =======================================================================
AVU.TAG_BLACKHOLE_IMMUNE = "blackholeimmune"

-- The one mesh the Vacuum U2 hard-codes. Anything wearing it can be deleted by that gun.
AVU.VACUUMABLE_MESH = ENUMS.Components.SK_MAGE_EYE_DRONE

function AVU.SetInvulnerable(actor, on)
    if Utils.IsActorInvalid(actor) then return end
    local want = (on ~= false)

    pcall(function() actor.Invincible = want end)
    if not want then return end   -- we never REMOVE the tag; a tag is harmless, and TArray removal
                                  -- from Lua is not a thing we want to rely on

    -- The tag is what closes the black-hole hole. AActor::Tags is a plain TArray<FName>; append once
    -- (table.insert on a TArray is the proven pattern here - see AVU.AddDebuffImmunities).
    pcall(function()
        local tags = actor.Tags
        if IsNotValid(tags) then return end
        for i = 1, #tags do
            if tostring(tags[i]) == AVU.TAG_BLACKHOLE_IMMUNE then return end   -- already tagged
        end
        table.insert(tags, FName(AVU.TAG_BLACKHOLE_IMMUNE))
    end)
end


-- Would the Nuke Vac (Weapon_Gun_Vacuum_U2) delete this actor outright? True iff its skeletal mesh
-- is on the gun's whitelist. Purely informational - there is nothing you can DO about it short of
-- changing the mesh (see SetInvulnerable). Useful for a debug command / a design sanity check.
-- [UNUSED] no live callers.

function AVU.IsVacuumable(actor)
    if Utils.IsActorInvalid(actor) then return false end
    local path
    pcall(function()
        local mesh = Utils.GetValidMesh(actor)
        local sk = mesh and mesh:GetSkeletalMeshAsset()
        if IsValid(sk) then path = Utils.ObjectPath(sk) end
    end)
    return path ~= nil and string.find(tostring(path), "SK_MageEyeDrone", 1, true) ~= nil
end


-- =======================================================================
-- HoldStill - freeze an NPC in place AND stop it turning, so a scripted attack can aim where
-- WE want and have it stay there. One flag does both (details at the writes below).
--   * ALWAYS PAIR THE CALLS - a stuck LockedInPlaceMontage is an NPC that never moves again,
--     so unlock on every exit path, including death.
--   * Misleading neighbours: the pawn's `StationaryMode` is a ROBOT BT lever, and the
--     MageEye's `StationaryTarget` is an AActor* (its laser target). Neither holds position.
-- =======================================================================

function AVU.HoldStill(actor, on)
    if Utils.IsActorInvalid(actor) then return end
    local want = (on ~= false)

    -- The clean lever: IsNPCBusy() (which LockedInPlaceMontage feeds) gates BOTH the BT root's
    -- first child - a Wait, so while busy the tree never reaches its MoveTo branches, which is the
    -- game's own designed stop - and the controller tick's K2_SetFocus re-run every 0.2s, which is
    -- what silently undoes a hand-set rotation. The controller's `Stationary` is belt and braces.
    pcall(function() actor.LockedInPlaceMontage = want end)
    pcall(function()
        local c = actor:GetController()
        if IsValid(c) then c.Stationary = want end
    end)

    -- Cancel whatever move was already in flight, or it coasts to its old destination.
    --   * StopMovement (controller) aborts pathfollowing, but CharacterMovement keeps this frame's
    --     VELOCITY - an NPC caught mid-sprint slides on, and its locomotion state overrides a
    --     just-started LockedInPlace montage (the "drink didn't play while moving" bug).
    --   * StopMovementImmediately zeros velocity+acceleration NOW so the planted montage takes hold.
    if want then
        pcall(function()
            local c = actor:GetController()
            if IsValid(c) then c:StopMovement() end
        end)
        pcall(function()
            local move = actor.CharacterMovement
            if IsValid(move) then move:StopMovementImmediately() end
        end)
    end
end


-- =======================================================================
-- RootInPlace / ReleaseRoot - pin an NPC's POSITION while its behaviour tree keeps ticking, so a
-- scripted windup can plant it but it can still turn, aim and melee. The difference from its
-- sibling IS the point: HoldStill parks the whole BT (the NPC does nothing), this kills only
-- MOVEMENT (it stays put but keeps FIGHTING). Windups, lassos, casts, self-ignite staggers.
--   * WRITE ORDER: StopMovementImmediately BEFORE SetMovementMode(None) - a body caught mid-sprint
--     keeps this frame's velocity and coasts on otherwise.
--   * REFRESHABLE: every call bumps a per-actor token and a delayed restore fires only if its token
--     is still the latest, so a second trigger EXTENDS the root instead of a stale timer un-rooting
--     it mid-windup. ReleaseRoot cancels a pending auto-restore.
--   * The PRIOR mode is captured and restored (never None), so a body rooted while Falling lands
--     back in Falling. opts.RestoreMode overrides; opts.OnRestore runs after movement is back.
--   * ms > 0 auto-restores after it; nil/0 = indefinite, and the caller releases.
-- For a persistent bone-WELD (movement dead + gravity 0 + capsule out of sweeps) that is AVAttach's
-- pinWeldedNpc, not this.
-- =======================================================================
local rootToken = {}   -- ActorKey (fullName) -> latest root token; guards refresh + early release

local function restoreMovement(actor, mode)
    if Utils.IsActorInvalid(actor) then return end
    local m = actor.CharacterMovement
    if IsValid(m) then pcall(function() m:SetMovementMode(mode or 1, 0) end) end   -- 1 = MOVE_Walking
end

function AVU.RootInPlace(actor, ms, opts)
    if Utils.IsActorInvalid(actor) then return false end
    local key = Utils.ActorKey(actor)
    if not key then return false end
    opts = opts or {}

    -- Capture the prior mode BEFORE we override it (unless the caller forces one). Never keep
    -- None as a restore target - that would leave the NPC frozen forever.
    local restoreMode = opts.RestoreMode
    if restoreMode == nil then
        pcall(function()
            local m = actor.CharacterMovement
            if IsValid(m) then restoreMode = tonumber(m.MovementMode) end
        end)
        if not restoreMode or restoreMode == 0 then restoreMode = 1 end
    end

    local move = actor.CharacterMovement
    if IsValid(move) then
        pcall(function() move:StopMovementImmediately() end)   -- zero velocity FIRST (see header)
        pcall(function() move:SetMovementMode(0, 0) end)       -- 0 = MOVE_None (rooted, BT still ticks)
    end

    local token = (rootToken[key] or 0) + 1
    rootToken[key] = token

    if ms and ms > 0 then
        Utils.QueueWork(function()
            if rootToken[key] ~= token then return end   -- a newer root (or ReleaseRoot) owns it now
            rootToken[key] = nil
            restoreMovement(actor, restoreMode)
            if opts.OnRestore then pcall(opts.OnRestore, actor) end
        end, ms)
    end
    return true
end

function AVU.ReleaseRoot(actor, restoreMode)
    if Utils.IsActorInvalid(actor) then return end
    local key = Utils.ActorKey(actor)
    if key then rootToken[key] = nil end   -- cancel any pending auto-restore
    restoreMovement(actor, restoreMode)
end


-- =======================================================================
-- PinInPlace / Unpin - the TURRET pin: this body does not move again until something unpins it.
-- Third of the family - HoldStill parks the BT, RootInPlace kills movement for a timed WINDUP,
-- this kills it INDEFINITELY and keeps killing it. Reach for it when the immobility IS the design.
--
-- IT IS MORE THAN SetMovementMode(None), because almost everything the NPC does puts it back - the
-- native fire path, the stagger path and the AI freeze all restore walking when they finish:
--   1. StopMovementImmediately FIRST, or a body mid-stride coasts on.
--   2. DefaultLandMovementMode = None, so those native restores land back ON the pin. This is the
--      write that makes it hold.
--   3. Deactivate the component, so nothing drives the root between re-asserts.
-- Re-assert on a slow cadence anyway: a pin is cheap scalar writes, and re-asserting is how it
-- survives whatever the BT did in between.
--   * opts.Gravity = false also zeroes GravityScale - for a body welded MID-AIR.
--   * A PIN CLOSES ONE OF THE NPC'S TWO ATTACK DRIVERS and kills its facing; AVU.HoldGround is the
--     version that doesn't.
-- AUTHORITY: movement mode is server-driven and replicates from there.
-- =======================================================================

function AVU.PinInPlace(actor, opts)
    if Utils.IsActorInvalid(actor) then return false end
    opts = opts or {}
    local ok = pcall(function()
        local move = actor.CharacterMovement
        if IsNotValid(move) then return end
        if move.MovementMode ~= 0 then
            move:StopMovementImmediately()
            move:SetMovementMode(0, 0)          -- 0 = MOVE_None
        end
        if move.DefaultLandMovementMode ~= 0 then move.DefaultLandMovementMode = 0 end
        if opts.Gravity == false and move.GravityScale ~= 0 then move.GravityScale = 0 end
        if move:IsActive() then move:Deactivate() end
    end)
    return ok
end

function AVU.Unpin(actor, mode)
    if Utils.IsActorInvalid(actor) then return false end
    return (pcall(function()
        local move = actor.CharacterMovement
        if IsNotValid(move) then return end
        move.DefaultLandMovementMode = mode or 1   -- 1 = MOVE_Walking
        if move.GravityScale == 0 then move.GravityScale = 1 end
        move:Activate(true)
        move:SetMovementMode(mode or 1, 0)
    end))
end


-- =======================================================================
-- HoldGround / ReleaseGround - the SELF-MAINTAINING immobiliser: fights normally, never moves.
-- Fourth of the family and usually the right one. It zeroes the NPCData SPEEDS, which are the
-- source every native restore copies FROM - so a 0 there lands every restore back on 0: no
-- re-assert cadence, and the movement component stays ACTIVE, so turning, knockback, launches and
-- root-motion attacks all keep working (exactly what PinInPlace's Deactivate kills). The game's own
-- precedent is Boss_Tentacle. Goes through SetMoveSpeed, so the VariantTag survives.
--
-- WHAT IT DOES THAT A PIN CANNOT: the movement mode stays Walking, so IsMovingOnGround() stays
-- true - and the AI controller gates BOTH of its own attack checks on that. A PINNED body silently
-- loses one of its two attack drivers; only the BT's own tasks still reach it.
--
-- KNOWN LIMITS (most apply to every immobiliser):
--   * The BT still ISSUES MoveTo orders, so a melee base whose target stays out of reach sits in
--     its chase branch and never swings. Give it reach, or ranged.
--   * IT STOPS FACING ITS TARGET. Combat facing on this whole family IS the movement
--     (bOrientRotationToMovement, no bUseControllerDesiredRotation), so at 0 speed there is none;
--     only the deliberate turns survive. Drive AVU.FaceTarget yourself.
--   * It can still be LAUNCHED or knocked back, so a turret on a ledge needs a leash.
-- HoldGround FAILS OPEN - it refuses to hold rather than stash a {0,0} it never read, because that
-- stash would make ReleaseGround the thing that immobilises the body permanently. Call
-- ReleaseGround on death too: the stash is keyed by a string, which never collects on its own.
-- AUTHORITY.
-- =======================================================================
local heldGround = {}   -- ActorKey -> { walk, sprint } stashed pre-hold NPCData speeds

function AVU.HoldGround(actor)
    if Utils.IsActorInvalid(actor) then return false end
    local key = Utils.ActorKey(actor)
    if not key then return false end

    if not heldGround[key] then   -- a re-hold keeps the ORIGINAL stash, not the zeroed speeds
        local walk, sprint
        pcall(function()
            local nd = actor.NPCData
            if IsValid(nd) then
                walk = math.floor(nd[ENUMS.NpcData.WalkSpeed] or 0)
                sprint = math.floor(nd[ENUMS.NpcData.SprintSpeed] or 0)
            end
        end)
        -- FAIL OPEN, never stash a zero we did not read. A {0,0} stash makes ReleaseGround the
        -- thing that immobilises the body PERMANENTLY - the unrecoverable half of the failure -
        -- whereas refusing the hold just leaves it walking, which is visible and fixable.
        if not walk or not sprint then return false end
        heldGround[key] = { walk = walk, sprint = sprint }
    end

    AVU.SetMoveSpeed(actor, 0, 0)
    pcall(function()   -- zero the in-flight velocity or a mid-sprint body coasts on (family rule)
        local move = actor.CharacterMovement
        if IsValid(move) then move:StopMovementImmediately() end
    end)
    return true
end

function AVU.ReleaseGround(actor)
    if Utils.IsActorInvalid(actor) then return end
    local key = Utils.ActorKey(actor)
    local stash = key and heldGround[key]
    if not stash then return end
    heldGround[key] = nil
    AVU.SetMoveSpeed(actor, stash.walk, stash.sprint)
    -- SetMoveSpeed's live write is the WALK value, and MaxWalkSpeed only picks the sprint one up
    -- on the next LocalUpdateWalkSpeed - which fires on a walk<->sprint toggle or OnRep_CombatState,
    -- neither of which happens to a body already mid-chase. Without this the released NPC crawls
    -- at walk speed for the rest of the fight (the Patriarch's phase 2 read as a 0.5 dilation).
    pcall(function() actor:LocalUpdateWalkSpeed() end)
end


-- =======================================================================
-- SetCanCrouch - kill (or restore) an NPC's ability to CROUCH. AUTHORITY, one-time write.
--
-- WHY: the crouch pose is an ANIM SEQUENCE in the AnimBP's state machine and the grunt family
-- ships NO crouch-LOCOMOTION state, so a crouched NPC that moves foot-slides across the floor. Any
-- variant we give a movement maneuver to shows this the moment BTT_Crouch fires - that task
-- crouches, waits 2-3s and stands up, and never stops movement.
--
-- THE LEVER: `CharacterMovement.NavAgentProps.bCanCrouch`. ACharacter::Crouch() early-outs on it,
-- so the task becomes a silent no-op, and a body ALREADY crouched is force-uncrouched natively on
-- its next movement tick. One bool write per NPC, no poll - which is what makes it usable at high
-- NPC density.
--
-- AUTHORITY-ONLY: bIsCrouched replicates, and clients run OnRep_IsCrouched -> UnCrouch(client),
-- which bypasses CanCrouch entirely. Never mirror it client-side.
-- Pass `on` = true to hand crouching back. Returns true if the flag verifiably reads back - a
-- bitfield write UE4SS drops would otherwise look identical to success (CLAUDE.md 3).
-- =======================================================================

function AVU.SetCanCrouch(actor, on)
    if Utils.IsActorInvalid(actor) then return false end
    local want = (on == true)

    local move = actor.CharacterMovement
    if IsNotValid(move) then return false end

    local ok = false
    pcall(function()
        move.NavAgentProps.bCanCrouch = want
        -- Read back through a FRESH access, not the wrapper we just wrote through - a struct
        -- handed back as a COPY would echo our own value and read as a success either way.
        ok = ((move.NavAgentProps.bCanCrouch and true or false) == want)
    end)

    -- Belt-and-braces for a body caught mid-crouch: the native force-uncrouch above only runs on
    -- the next movement update, and UnCrouch() itself has no CanCrouch() gate, so this is free.
    if not want then pcall(function() actor:UnCrouch(false) end) end

    if not ok then
        Utils.Log("SetCanCrouch - NavAgentProps.bCanCrouch write did not stick on "
                  .. tostring(Utils.GetActorRowName(actor)))
    end
    return ok
end

-- =======================================================================
-- DisableHitReaction - stop a body going limp every time it is hit. EVERY ROLE, one-time write.
--
-- WHY: the character parent's hit reaction simulates physics on everything below HitReactionBone
-- at blend weight 1, adds a RANDOM-direction impulse and blends back over a timeline. On a robot
-- that bone is "Torso", so the head, arms and every socket on them swing loose on each impact -
-- which drags any beam or projectile ORIGIN read off a bone along with them.
--
-- IT IS DRIVEN BY THE IMPACT, NOT BY DAMAGE. The impact-FX multicast fires it before any
-- resistance, immunity or shield test, so no amount of invincibility suppresses it - and being a
-- multicast it runs on every machine, which is why this is written on both roles: the renderer for
-- the look, the server because a weapon hit traces the physics asset (CLAUDE.md 4).
--
-- THE LEVER: the bone name itself. Point it at a bone the physics asset has no body for and every
-- call in the reaction (the two SetAllBodiesBelow*, the AddImpulse, the blend-back) resolves
-- nothing, so the reaction runs and does nothing.
--   NEVER "None": ForEachBodyBelow reads that as EVERY body, i.e. a full ragdoll on the first hit.
-- One-way - the class default is never read back, so there is nothing to hand back.
-- =======================================================================

function AVU.DisableHitReaction(actor)
    if Utils.IsActorInvalid(actor) then return false end
    local ok = false
    pcall(function()
        actor.HitReactionBone = FName("AnteNoHitReact")
        -- Case-folded: an FName's display spelling is whoever registered it first (CLAUDE.md 1).
        local n = actor.HitReactionBone
        ok = n ~= nil and tostring(n:ToString()):lower() == "antenohitreact"
    end)
    if not ok then
        Utils.Log("DisableHitReaction - HitReactionBone write did not stick on "
                  .. tostring(Utils.GetActorRowName(actor)))
    end
    return ok
end



-- =======================================================================
-- SkipAggroAnim - delete an NPC's AGGRO (and STARTLE) reaction, so it goes from noticing you to
-- fighting you immediately. AUTHORITY, one-time write, no tick.
--
-- IT IS A COMBAT KNOB, NOT A COSMETIC ONE. BTT_SetCombatState polls the pawn's AggroDuration and
-- then Delays by it, and that value is the aggro MONTAGE'S OWN play length - while the same path
-- latches LockedInPlaceMontage, which parks the BT root. So a long aggro clip is a hard "stand
-- still and do nothing" window at the start of EVERY fight (the Clericus inherits the SCIENTIST
-- rig, whose clip is a ~2s cower).
--
-- THREE LEVERS, because the one this used to rely on cannot be verified on this build:
--   1. COMBAT ENTRY: every gameplay entry funnels through the controller's BT_SetCombatState,
--      whose SkipAggroAnimation param is the only thing between "state set" and the engage that
--      plays the clip and parks the tree. This marks the actor (STATE.NoAggroAnimActors) and the
--      CombatHooks hook on that function forces the param true for marked pawns. The task then
--      finishes on the spot. Verified native flow, no soft ref involved.
--   2. STARTLE (the out-of-combat spook): natively gated on WasRecentlyStartled, which only a
--      played startle's own cooldown ever clears - so one true is a permanent gate. Plain bool.
--   3. THE CLIP REFS: blank AggroAnimation / StartleAnimation so the fallback arm runs even on an
--      entry that dodges 1. A soft-object property cannot be read back on this UE4SS, so the blank
--      is a typed whole-value write (Utils.BlankSoftRef), trusted by construction and logged once
--      per row. Belt-and-braces, never the load-bearing layer.
--
-- Declarative form: def.NoAggroAnim = true (every difficulty) or def.HardMode.NoAggroAnim = true
-- (hard mode only) - NpcManager STATS calls this for either. Direct calls still work.
--
-- DO NOT push Duration far below the native 0.5. The poll is 0.05s and has NO timeout, so too
-- short a window can be missed and the task would wait forever - hence the clamp.
--   opts.Duration     seconds of "aggroing" to keep (clamped >= 0.3). Omit for the native 0.5.
--   opts.KeepStartle  leave the startle alone (bases whose startle is a short flinch).
-- Returns true if the aggro clip ref write went through (layer 3 only - layers 1 and 2 are
-- unconditional). Full decode: AnNotes/AnteNPCs/OrderClericus.md.
-- =======================================================================
local AGGRO_DURATION_MIN = 0.3

-- Blank ONE soft-ref field through Utils.BlankSoftRef - the only sound write for a soft-object
-- property on this UE4SS (Utils has the why). No read of a soft path has ever come back on this
-- build, so the verdict is whether the write went through, said once per class and field.
local softPathLogged = {}   -- "row:field:ok" -> true

local function blankSoftPath(obj, field, label)
    if not Utils.SoftRefsSafe() then return false end   -- said once, by the gate itself
    local ok = Utils.BlankSoftRef(obj, field)
    local row = tostring(Utils.GetActorRowName(obj))
    local once = row .. ":" .. field .. ":" .. tostring(ok)
    if not softPathLogged[once] then
        softPathLogged[once] = true
        if ok then
            LogDebug(string.format("%s - %s blanked on %s", label, field, row), SETTINGS.DEBUG_NPC_ACTIONS)
        else
            Utils.Log(string.format("%s - %s NOT blanked on %s (no blank donor, or not a soft-object field)",
                label, field, row))
        end
    end
    return ok
end

function AVU.SkipAggroAnim(actor, opts)
    if not Utils.IsAuthority() then return false end
    if Utils.IsActorInvalid(actor) then return false end
    opts = opts or {}

    -- Layer 1: mark the pawn for the BT_SetCombatState hook (CombatHooks). String key, wiped
    -- with the world in Utils.ResetState.
    local key = Utils.ActorKey(actor)
    if key then STATE.NoAggroAnimActors[key] = true end

    -- Layer 2: the startle gate.
    if not opts.KeepStartle then
        pcall(function() actor.WasRecentlyStartled = true end)
    end

    -- Layer 3: the clip refs.
    local ok = blankSoftPath(actor, "AggroAnimation", "SkipAggroAnim")
    if not opts.KeepStartle then
        blankSoftPath(actor, "StartleAnimation", "SkipAggroAnim")
    end

    if opts.Duration then
        local d = opts.Duration
        if d < AGGRO_DURATION_MIN then d = AGGRO_DURATION_MIN end
        pcall(function() actor.FallbackAggroDuration = d end)
    end
    return ok
end


-- Does this def want SkipAggroAnim on the current difficulty? def.NoAggroAnim is every
-- difficulty; def.HardMode.NoAggroAnim only under NoMercy. Read at mutation (NpcManager STATS).
function AVU.NoAggroAnimFor(def)
    if not def then return false end
    if def.NoAggroAnim then return true end
    return (STATE.HardModeNoMercy and def.HardMode and def.HardMode.NoAggroAnim) and true or false
end


-- =======================================================================
-- SkipBackstepAnim - take an NPC's DODGE ROLL away, so it holds its ground instead of lurching.
--
-- THREE systems drive the same roll, and `EvadesProjectiles = false` gates only the first: the
-- projectile evade, the CONTROLLER's damage backstep (it reads no pawn flag), and BTT_PerformDodge
-- nodes in the attack tree that call it outright. All three reach AI_PerformBackstep.
--
-- THE LEVER IS AVU.BlockDodgeDrivers: three plain values, one per driver, authority only. The roll
-- is decided on the server and only then multicast, so closing the drivers there covers every
-- machine - no per-machine write, no soft ref, any UE4SS build.
--
-- TWO BACKSTOPS:
--   * The CombatHooks DetermineDodgeDirection hook re-runs BlockDodgeDrivers on a marked pawn's first
--     roll (the attack tree's nodes do not exist until combat starts, so the tree gate can only be
--     closed from then on), and hands that roll direction 3. Direction 3 has no clip of its own and
--     FALLS BACK TO THE BACK CLIP - so it means "roll backwards", never "don't roll".
--   * The three clip refs are still blanked where a soft write is sound (Utils.SoftRefsSafe). All
--     three or none: the chooser falls back to BackstepAnimation. That one is per machine, which is
--     why Visuals calls this too.
--
-- NOT COVERED: a dodge that is a STEP OF AN ATTACK SEQUENCE (the Interfector's two, a Peccary's
-- extras) has no gate at all. And on an Interfector the STAGGER clips are the same dodge montages,
-- so it still back-flips when staggered - that is AVU.SkipStaggerAnim's family, not this one.
--
-- WHY YOU'D WANT IT: the roll is unaimed and is a blind ~300uu displacement, so in a cluttered or
-- edged arena the NPC dodges into furniture or off a ledge.
-- =======================================================================

-- Attack trees whose ONLY BTD_Chance decorators sit on a dodge node (FModel BT exports; re-check
-- before adding one - zeroing a chance decorator that gates something else would switch that off).
local DODGE_TREES = {
    bt_attack_soldiergatekeeper = true, bt_attack_mage = true, bt_attack_mage_darklens = true,
    bt_attack_peccary = true, bt_attack_peccaryarmored = true, bt_attack_peccarysnow = true,
    bt_attack_symphonist = true, bt_attack_thespian = true, bt_attack_yeti = true,
}

-- [AUTHORITY] Close the three roll drivers with plain values. Idempotent; returns true when the
-- TREE gate was found. That gate is NOT a one-time write: the attack tree's node instances only
-- exist while the pawn is in combat and are rebuilt (at the asset's chance) on every re-entry, so
-- the CombatHooks dodge hook calls this again whenever a marked pawn still manages a roll.
function AVU.BlockDodgeDrivers(actor)
    if not Utils.IsAuthority() or Utils.IsActorInvalid(actor) then return false end

    -- 1. Projectile evade.
    pcall(function() actor.EvadesProjectiles = false end)

    local ctrl
    pcall(function() ctrl = actor:GetController() end)
    if IsNotValid(ctrl) then return false end

    -- 2. The controller's damage backstep: `now - LastBackstepTime >= BackstepCooldown` never holds.
    --    (tonumber: a field the class lacks reads as a placeholder, never nil.)
    pcall(function()
        if tonumber(ctrl.BackstepCooldown) then ctrl.BackstepCooldown = 1e9 end
    end)

    -- 3. The tree's dodge node: its chance decorator is an instance of this pawn's own tree, and a
    --    chance of 0 is an explicit "never" in CalculatePercentageChance.
    local closed, was = 0, nil
    pcall(function()
        local brain = ctrl.BrainComponent
        if IsNotValid(brain) then return end
        local nodes = brain.NodeInstances
        for i = 1, #nodes do
            local node = nodes[i]
            if IsValid(node) and string.lower(node:GetClass():GetFName():ToString()) == "btd_chance_c" then
                local tree = node.TreeAsset
                local treeName = IsValid(tree) and string.lower(tree:GetFName():ToString()) or ""
                local chance = tonumber(node.ChancePercentage)
                if chance and DODGE_TREES[treeName] then
                    if chance > 0 then
                        node.ChancePercentage = 0
                        was = was or chance
                    end
                    closed = closed + 1
                end
            end
        end
    end)

    if was then
        LogDebug(string.format("SkipBackstep - %s: tree dodge chance %.2f -> 0, damage backstep and projectile evade off",
            tostring(Utils.GetActorName(actor)), was), SETTINGS.DEBUG_NPC_ACTIONS)
    end
    return closed > 0
end

function AVU.SkipBackstepAnim(actor)
    if Utils.IsActorInvalid(actor) then return false end

    local marked = false
    if Utils.IsAuthority() then
        local key = Utils.ActorKey(actor)
        if key then
            STATE.NoBackstepActors = STATE.NoBackstepActors or {}   -- /reload keeps the old STATE table
            STATE.NoBackstepActors[key] = true
            AVU.BlockDodgeDrivers(actor)
            marked = true
        end
    end

    local ok = blankSoftPath(actor, "BackstepAnimation", "SkipBackstepAnim")
    blankSoftPath(actor, "BackstepLeftAnimation", "SkipBackstepAnim")
    blankSoftPath(actor, "BackstepRightAnimation", "SkipBackstepAnim")
    return marked or ok
end


-- =======================================================================
-- SkipStaggerAnim - delete an NPC's STAGGER STUMBLE. SkipBackstepAnim's sibling, one field family
-- over, and THE MONTAGE IS THE REACTION: the broadcast checks the anim ref before it latches
-- LockedInPlaceMontage, before its own StopMovementImmediately and before the montage load.
--
-- WHY IT EXISTS - THE FORCED-STAGGER HOLE: CheckForStagger(ForceStagger = true) goes STRAIGHT to
-- the stagger, bypassing the stamina pool, the RecentlyStaggered latch AND StaggerCooldown - every
-- write AVU.SetStaggerImmune makes. And ForceStagger is reachable from the ORDINARY damage path
-- twice: a WEAKNESS hit (so an acid-weak base was force-staggered by every bioball, "immune" or
-- not) and a Stopping Power crit. Blanking the montages is the one lid that covers both, because
-- the anim check runs downstream of every force flag. What is left is a micro-flinch the BT
-- re-plans out of next tick - not a lock, not a stumble.
--
-- ALL FOUR FIELDS or it does nothing, and CALL IT ON BOTH ROLES: the stagger multicast is sent
-- unconditionally, so a server-only blank leaves clients playing a stumble the server never took.
-- =======================================================================

function AVU.SkipStaggerAnim(actor)
    if Utils.IsActorInvalid(actor) then return false end

    local ok = blankSoftPath(actor, "StaggerAnimation", "SkipStaggerAnim")
    blankSoftPath(actor, "StaggerAnimationLeft", "SkipStaggerAnim")
    blankSoftPath(actor, "StaggerAnimationRight", "SkipStaggerAnim")
    blankSoftPath(actor, "StaggerAnimationForward", "SkipStaggerAnim")
    return ok
end


-- =======================================================================
-- ClearWeaknessStagger - THE LID SetStaggerImmune CANNOT CLOSE. Call it from def.OnDamageTaken.
--
-- A WEAKNESS hit force-staggers past every write SetStaggerImmune makes: it skips the stamina pool,
-- the RecentlyStaggered latch AND StaggerCooldown ([[af-weakness-forced-stagger]]) - one guaranteed
-- stagger per hit of a weak type. def.OnDamageTaken's hook point lands exactly between the engine
-- setting the flag and reading it, so one bool clear here is enough; the damage bonus itself still
-- lands, only the reaction is dropped. Call-stack decode: AnNotes/AnteSystems/AVUtils.md.
--
-- STRONGER THAN AVU.SkipStaggerAnim (which only blanks the montage): this stops AI_PerformStagger
-- being reached at all, including subclass Broadcast_PerformStagger overrides - on a PECCARY that
-- is the difference between a montage-free stampede and none at all. Keep SkipStaggerAnim too; it
-- is the renderer-side half.
--
-- NOT COVERED: Server_ForceCriticalHitStagger (Stopping Power crit) never consults this flag, and
-- clearing it also silences the weakness crit-spark FX (same bool). AUTHORITY only.
-- =======================================================================

function AVU.ClearWeaknessStagger(actor)
    if Utils.IsActorInvalid(actor) then return end
    -- Read-first: this runs on every hit taken, and the flag is false for all the non-weak ones.
    pcall(function()
        if actor.RecentlyWeaknessStaggered == true then actor.RecentlyWeaknessStaggered = false end
    end)
end


-- =======================================================================
-- SetStaggerImmune - a body that CANNOT be flinched out of what it is doing. For bosses, where a
-- stagger-lock from two players with fast weapons is the whole fight.
--
-- `StaggerCooldown = 99999` ALONE IS NOT IMMUNITY - it is the half every variant reached for, and
-- it leaves exactly one free stagger, because that field only feeds the delay that CLEARS
-- RecentlyStaggered. The four writes together close every path:
--   1. StaggerCooldown 99999 - once set, RecentlyStaggered never clears again.
--   2. RecentlyStaggered = true NOW - so even the first hit takes that branch.
--   3. Blank the backstep anims - that branch's other exit is a controller backstep, which on a
--      boss reads as "it rolled away from my shotgun" and in an edged arena walks it off a ledge.
--   4. Blank the stagger anims - the ONLY lid on the ForceStagger path, which skips 1-3 entirely
--      (see AVU.SkipStaggerAnim).
-- AUTHORITY IS ENOUGH FOR THE MECHANICS, but a forced hit still MULTICASTS, so put
-- AVU.SkipStaggerAnim in Visuals for the renderer half. AnimBP hit-flinch layers are untouched.
-- =======================================================================

function AVU.SetStaggerImmune(actor)
    if Utils.IsActorInvalid(actor) then return false end

    -- The forced stagger of a WEAKNESS hit walks past every write below, so the CombatHooks damage
    -- hook clears it for marked pawns (what AVU.ClearWeaknessStagger does from a def, for everyone).
    -- Plain bool, authority only, so it holds on any UE4SS build - the clip blanks further down do not.
    if Utils.IsAuthority() then
        local key = Utils.ActorKey(actor)
        if key then
            STATE.StaggerImmuneActors = STATE.StaggerImmuneActors or {}   -- /reload keeps the old STATE table
            STATE.StaggerImmuneActors[key] = true
        end
    end

    pcall(function() actor.StaggerCooldown = 99999 end)
    pcall(function() actor.RecentlyStaggered = true end)
    AVU.SkipBackstepAnim(actor)
    AVU.SkipStaggerAnim(actor)

    local ok = false
    pcall(function() ok = actor.RecentlyStaggered == true end)
    return ok
end


-- [AUTHORITY] Apply a variant's declarative def.DebuffsImmune block. DebuffsImmune is a TArray of
-- row names Server_ApplyBuff consults before it applies anything, so listing a row there is how an
-- NPC becomes immune to it.
--   * `replace` WIPES the base's own immunities first. Most variants ADD, but a few (the Hexed
--     Woodsman) deliberately strip the list so the body is vulnerable to what its kin shrug off.
--   * A variant's Stats() still runs AFTER this, so it can add more conditionally.

function AVU.AddDebuffImmunities(actor, list, replace)
    if Utils.IsActorInvalid(actor) or type(list) ~= "table" then return end

    local immunities = actor.DebuffsImmune
    if IsNotValid(immunities) then return end

    if replace then pcall(function() immunities:Empty() end) end

    for _, debuff in ipairs(list) do
        if debuff then pcall(function() table.insert(immunities, FName(debuff)) end) end
    end
end


-- [ANY] Does `actor` refuse debuff row `row`? DebuffsImmune is a list the APPLIER consults
-- (IsCharacterImmuneToBuffDebuff, called by the weapon / projectile / area-effect paths) - the
-- component's Server_ApplyBuff itself does not, so the mod's own Utils.ApplyBuffLinked lands on an
-- "immune" body unless the caller asks first. Any variant applying a debuff by hand should.
-- Case-folded: an FName's spelling is whoever registered it first ([[af-fname-casing-not-stable]]).

function AVU.IsDebuffImmune(actor, row)
    if Utils.IsActorInvalid(actor) or not row then return false end

    local want = string.lower(tostring(row))
    local immune = false
    pcall(function()
        local list = actor.DebuffsImmune
        if IsNotValid(list) then return end
        for i = 1, #list do
            if string.lower(tostring(list[i])) == want then immune = true return end
        end
    end)
    return immune
end


-- =======================================================================
-- CCImmune - "you cannot take this body's turn away from it", in one call.
-- Crowd control arrives through TWO unrelated systems, which is why every boss that wanted this
-- wrote it in two places and kept shipping it half-done:
--   * DEBUFFS are rows, refused by name (DebuffsImmune).
--   * STAGGER is not a debuff at all - it is a stamina check no row list touches, so it needs
--     AVU.SetStaggerImmune's four writes (whose renderer half is the caller's job).
-- CATEGORIES ARE ALL ON BY DEFAULT, so AVU.CCImmune(actor) is the full boss block; switch one OFF
-- to let it through ({ Bleed = false } = unshakeable but still bleeds). Call from Stats, so it
-- re-applies on every re-mutation.
-- =======================================================================
AVU.CC_LISTS = {
    Bleed  = { ENUMS.Debuffs.Bleeding, ENUMS.Debuffs.SevereBleeding },
    Freeze = { ENUMS.Debuffs.Frost, ENUMS.Debuffs.Frost2, ENUMS.Debuffs.Frost3,
               ENUMS.Debuffs.Frost4, ENUMS.Debuffs.Frost5, ENUMS.Debuffs.SniperRifleIce,
               ENUMS.Debuffs.FlaskBlizzard },
    Shock  = { ENUMS.Debuffs.ShockTrap, ENUMS.Debuffs.Zapped, ENUMS.Debuffs.ZappedPurple },
    Fear   = { ENUMS.Debuffs.Fear },
    -- The hard holds: everything that takes CONTROL away rather than just hurting.
    Hold   = { ENUMS.Debuffs.Netted, ENUMS.Debuffs.NettedCannon, ENUMS.Debuffs.Rooted,
               ENUMS.Debuffs.Stunned, ENUMS.Debuffs.ParryStun, ENUMS.Debuffs.Concussed },
}

local CC_NON_CATEGORY = { Stagger = true, Replace = true }

function AVU.CCImmune(actor, opts)
    if Utils.IsActorInvalid(actor) then return false end
    opts = opts or {}

    -- Typo guard (the ApplyBasicStats rule): every key here is an OPT-OUT, so a misspelled one
    -- silently leaves that category ON - i.e. it fails in the direction you won't notice.
    for key in pairs(opts) do
        if not AVU.CC_LISTS[key] and not CC_NON_CATEGORY[key] then
            LogBad("CCImmune - unknown key: " .. tostring(key))
        end
    end

    local rows = {}
    for name, list in pairs(AVU.CC_LISTS) do
        if opts[name] ~= false then
            for i = 1, #list do rows[#rows + 1] = list[i] end
        end
    end
    if #rows > 0 then AVU.AddDebuffImmunities(actor, rows, opts.Replace) end

    if opts.Stagger ~= false then AVU.SetStaggerImmune(actor) end
    return true
end


-- [AUTHORITY] Apply a variant's declarative def.BasicStats block - the common
-- movement/damage/HP/armor knobs, so a plain-stat variant needs no Stats() function.
--   * HP + armor route to their own appliers (see the BS_* maps); everything else is a direct
--     NPCData write. Unknown keys are logged (typo guard).
--   * A variant's Stats() still runs AFTER this for computed/conditional values, so it can
--     override any field set here.

function AVU.ApplyBasicStats(actor, stats)
    if Utils.IsActorInvalid(actor) or type(stats) ~= "table" then return end

    local hp, armor, direct
    for key, val in pairs(stats) do
        if BS_HP[key] then
            hp = hp or {}; hp[BS_HP[key]] = val
        elseif BS_ARMOR[key] then
            armor = armor or {}; armor[BS_ARMOR[key]] = val
        elseif BS_NPCDATA[key] then
            direct = direct or {}; direct[BS_NPCDATA[key]] = val
        else
            LogBad("BasicStats - unknown key: " .. tostring(key))
        end
    end

    if hp then AVU.SetLimbHealth(actor, hp) end
    if armor then AVU.SetArmor(actor, armor) end
    if direct then
        local npcData = actor.NPCData
        if IsNotValid(npcData) then return end
        for field, val in pairs(direct) do
            pcall(function() npcData[field] = val end)
        end
    end
end


-- [AUTHORITY] NEUTER-FIRST: apply ONLY the safety-critical slice of a def.BasicStats block
-- (per-limb HP + melee/ranged damage - see BS_SAFETY), ahead of the mutation pipeline.
--   * WHY: the pipeline's STATS step can legitimately BAIL (a sublevel that streamed out inside the
--     mutation stagger, a mid-EndPlay actor) and a SAVE-RESTORED body never runs it at all. That is
--     harmless when a variant UPGRADES its base - but SpawnAs inverts it: we force a spawner to emit
--     a LATE-GAME row and tone it down (the Signal Pest IS a real Pest_Volatile), so a bailed STATS
--     leaves a full-strength late-game enemy in an early zone.
--   * Running the danger knobs FIRST makes the worst case an unprettified NPC, not a lethal one.
--   * Safe to double up: the values are ABSOLUTE, so the STATS step re-applying the whole block is
--     a no-op, and nothing here loads an asset - legal in any drain context.

function AVU.ApplySafetyStats(actor, stats)
    if Utils.IsActorInvalid(actor) or type(stats) ~= "table" then return end

    local subset
    for key, val in pairs(stats) do
        if BS_SAFETY[key] then
            subset = subset or {}
            subset[key] = val
        end
    end
    if not subset then return end   -- variant declares no danger knobs; nothing to pre-empt

    AVU.ApplyBasicStats(actor, subset)
end


-- Floor `speed` and re-attach the VariantTag fraction this NPC is currently carrying.
--   * THE helper for any code that writes NPCData.WalkSpeed / SprintSpeed (or live WalkSpeed)
--     DIRECTLY instead of going through AVU.SetMoveSpeed - exactly where the un-tagging bug
--     survives, since the guard in SetMoveSpeed can't see those writes.
--   * Returns a plain floored number if the NPC is untagged or unreadable, so it's always safe
--     to wrap a write in:
--       npcData[ENUMS.NpcData.SprintSpeed] = AVU.TagSpeed(actor, 600 - 300 * opacity)
--   * Flooring is the point: a COMPUTED speed (a lerp, a multiply) lands an arbitrary fraction,
--     which doesn't just clear the tag - it forges a garbage variant Id another variant may own.

function AVU.TagSpeed(actor, speed)
    if not speed then return speed end
    local frac = 0
    pcall(function()
        local nd = actor.NPCData
        if IsValid(nd) then
            local cur = nd[ENUMS.NpcData.WalkSpeed]
            if cur then frac = cur - math.floor(cur) end
        end
    end)
    return math.floor(speed) + frac
end


-- [AUTHORITY] Set an NPC's movement speed live AND persistently.
--
-- Two writes are needed to make a speed change actually STICK on an NPC:
--   1. NPCData.DefaultWalkSpeed / DefaultSprintSpeed - the AUTHORITATIVE source. The server's
--      LocalUpdateWalkSpeed recomputes MaxWalkSpeed from these (SprintSpeed if WantsToSprint, else
--      WalkSpeed) on every walk<->sprint toggle (verified NPC_Base_ParentBP.LocalUpdateWalkSpeed),
--      so a change written ONLY to the live WalkSpeed gets stomped on the next recompute.
--   2. the replicated live `WalkSpeed` (+ dirty + OnRep_WalkSpeed) - applies THIS frame instead of
--      waiting for the next recompute, so the slow/speed-up is immediate (the Marksman/Shade pattern).
--
-- Pass `sprint` = nil to leave DefaultSprintSpeed alone. Passing walk == sprint is the "walk-only"
-- knob: there is no clean sprint-disable flag, so equalising the two makes a sprint no faster than
-- a walk. AUTHORITY.
--
-- PRESERVES THE VARIANTTAG, and callers must not try to do it themselves. The tag IS the FRACTION
-- of these very fields, so a plain integer write here silently UN-TAGS the NPC: clients stop
-- mirroring its visuals and the mod's own "did WE mutate this?" test starts reading false (it was a
-- live bug in the Suppressor Grunt, re-wiped on EVERY burst). We read the fraction off the
-- authoritative NPCData.WalkSpeed, floor the incoming values and put it back - so callers just pass
-- plain integers, and an untagged NPC reads frac 0 and behaves exactly as before.

function AVU.SetMoveSpeed(actor, walk, sprint)
    if Utils.IsActorInvalid(actor) or not walk then return end

    walk = AVU.TagSpeed(actor, walk)
    if sprint ~= nil then sprint = AVU.TagSpeed(actor, sprint) end

    pcall(function()
        local nd = actor.NPCData
        if IsValid(nd) then
            nd[ENUMS.NpcData.WalkSpeed] = walk
            if sprint ~= nil then nd[ENUMS.NpcData.SprintSpeed] = sprint end
        end
    end)
    pcall(function()
        actor.WalkSpeed = walk
        Utils.MarkReplicatedDirty(actor, "WalkSpeed")
        actor:OnRep_WalkSpeed()
    end)
end


-- Set an NPC's FACTION (team) and replicate it. AUTHORITY. Hostility resolves in
-- AbioticFunctionLibrary.GetHostilityTowardsTarget by the OWNER's faction:
--   * 0      -> hostile to everything that ISN'T its own NPC class (lone monster).
--   * 1      -> hostile to EVERYTHING, including its own kind (berserk).
--   * N >= 2 -> hostile only to DIFFERENT factions; friendly to the same number (team).
-- (See E_Factions in AnteData/Enums: 2 = Player/Scientist, 3 = Order, 5 = Anteverse2
-- pests, 6 = Gatekeepers/Robots, 10 = Zombie, ...). NOTE: call AFTER AVU.SetNpcLevel -
-- InitializeNPCVariables resets Faction to the NPCData row default.

function AVU.SetFaction(actor, faction)
    if Utils.IsActorInvalid(actor) or faction == nil then return end
    pcall(function()
        actor.Faction = faction
        Utils.MarkReplicatedDirty(actor, "Faction")
    end)
end


-- Set whether an NPC in invuln to other NPCs (nonplayer)
--   * Abiotic_Character_ParentBP.ProcessDamage bails out entirely when instigator is 
--     a non-player faction AI_Controller-- 
--   * Direct assign often doesn't reliably write, so we also use the Kismet setter

function AVU.SetInvincibleToNPCs(actor, on)
    if Utils.IsActorInvalid(actor) then return end
    local want = on and true or false

    local ksl = UEHelpers.GetKismetSystemLibrary()
    if IsValid(ksl) then
        pcall(function() ksl:SetBoolPropertyByName(actor, FName("InvincibleToNPCs"), want) end)
    end
    pcall(function() actor.InvincibleToNPCs = want end)
end


-- [AUTHORITY] TAUNT: make `actor` a far more attractive TARGET to other NPCs - the game's own
-- Armored Peccary trick. A candidate's score is distance/multiplier, so a big multiplier makes this
-- actor read as "closest". TWO ENGINE CAVEATS: the multiplier is CLAMPED to [0.1, 10], and
-- selection ranks by a discrete PRIORITY TIER first with PLAYERS in a higher one - so this
-- reorders NPC-vs-NPC aggro only and will NOT peel enemies off a player it can see.
-- Use it to make a mob gang up on one NPC. `value` defaults to 400 (the base game's, clamps to 10x).
local statModLib
-- [UNUSED] no live callers; one commented-out call in RobotSecurity.lua.

function AVU.SetTargetPriority(actor, value)
    if Utils.IsActorInvalid(actor) then return end
    if IsNotValid(statModLib) then
        statModLib = StaticFindObject("/Script/AbioticFactor.Default__StatModifierHandleFunctionLibrary")
    end
    if IsNotValid(statModLib) then LogBad("SetTargetPriority - StatModifierHandleFunctionLibrary not found"); return end
    pcall(function()
        local handle = statModLib:MakeStatModifierRowHandle(FName("TargetPriority_Multiply"))
        actor:AddCheatStatModifier(handle, value or 400)
    end)
end


-- [AUTHORITY] Make a variant UN-tameable by the pheromone flask - call from Stats on the ones that
-- shouldn't be tamed.
--   * WHY: taming a bespoke Pest/Peccary variant re-inits the NPC back to the vanilla base pet, so
--     our mesh and behaviour are lost. Do NOT use it on variants that ARE basically the vanilla
--     tameable pet with tweaks (PlayerPets' Electro/Magma/...) - taming those is fine.
--   * HOW: the flask's buffs go through Server_ApplyBuff, which checks DebuffsImmune first, so
--     listing both there makes the flask silently skip this NPC.
--   * CLASS-GATED to Pest/Peccary (the only classes the pheromone acts on), classes re-resolved
--     fresh rather than cached (CLAUDE.md 3).

function AVU.LockTaming(actor)
    if Utils.IsActorInvalid(actor) then return end

    local function isClass(path)
        local cls = ASSETS.GetIfValid(path)
        if IsNotValid(cls) then return false end
        local ok, isa = pcall(function() return actor:IsA(cls) end)
        return ok and isa
    end
    if not (isClass(ENUMS.NpcClasses["Pest"]) or isClass(ENUMS.NpcClasses["Peccary"])) then return end

    local immune = actor.DebuffsImmune
    if IsValid(immune) then
        table.insert(immune, FName(ENUMS.Debuffs.Pheromone))
        table.insert(immune, FName(ENUMS.Debuffs.Passive))
    end
end


-- [AUTHORITY] Stop an NPC dropping its death loot. NPC_Base has two loot paths and this covers
-- both: the NORMAL death drop is gated on HasDroppedLoot (set via the Kismet setter - a plain Lua
-- write doesn't stick), and the GIB kill pays out its salvage UNCONDITIONALLY, so suppressing that
-- means CanBeGibbed = false.
--   * `preserveGib` opts OUT of that second half - which self-gib/explode bases (Symphonist,
--     Crystallisk) NEED, or they leave a corpse that never cleans up. AVU.ClearGibLoot is the third
--     option: gib, but no salvage.
--   * A deliberate OnDeath drop via ItemSpawner is a separate path and is unaffected.

function AVU.ClearLoot(actor, preserveGib)
    if Utils.IsActorInvalid(actor) then return end

    local ksl = UEHelpers.GetKismetSystemLibrary()
    if IsValid(ksl) then
        pcall(function() ksl:SetBoolPropertyByName(actor, FName("HasDroppedLoot"), true) end)
    end
    pcall(function() actor.HasDroppedLoot = true end)

    if preserveGib then return end   -- keep self-gib bases gibbing (else corpse persists)

    local npcData = actor.NPCData
    if IsNotValid(npcData) then return end
    pcall(function()
        local gib = npcData[ENUMS.NpcData.GibInfo]
        gib[ENUMS.NpcGib.CanBeGibbed] = false
        npcData[ENUMS.NpcData.GibInfo] = gib
    end)
end


-- [AUTHORITY] Fully suppress an NPC's death loot before a SCRIPTED kill.
--   * ClearLoot covers the generic path (HasDroppedLoot) + the gib path (CanBeGibbed); this also
--     zeroes the LabRat-style RemainingLootDrops counter (pcall no-ops on classes without the field).
--   * A FREEZE GUARD, not just tidiness: death-time GenerateLootDrop was the reproducible hang
--     ("kill-> Grunt_LabRat") - Server_PerformDeathSequence loops it for ALL RemainingLootDrops
--     and a COLD loot asset blocking-loads inside our WorkQueue drain (CLAUDE.md section 2).
--     Player kills never freeze (not nested in a hook); only scripted in-drain kills do.
--   * preserveGib forwards to ClearLoot: the body still gibs. Pair it with AVU.ClearGibLoot for
--     "gibs, drops nothing at all" - a wave body that must not become a farm.

function AVU.StripLoot(npc, preserveGib)
    AVU.ClearLoot(npc, preserveGib)
    pcall(function() npc.RemainingLootDrops = 0 end)
end


-- =======================================================================
-- PlayIdleSequence - force a raw AnimSequence onto an NPC (the Mage's meditation pose).
-- NOT A MONTAGE: the asset ships as a bare AnimSequence and Montage_Play cannot take one, so the
-- only way to strike the pose is PlayAnimation - which flips the mesh into single-node mode and
-- BYPASSES THE ANIM BLUEPRINT entirely. While it is up there is no locomotion blending, no
-- montages and no hit reactions: fine for a deliberate "sit still and channel" stance and nothing
-- else. Always pair it with something that stops the NPC moving, and always restore
-- (AVU.RestoreAnimBlueprint).
-- RENDERER-LOCAL - the animation mode doesn't replicate, so every machine that draws the NPC calls
-- it for itself (host in Visuals/OnTick, clients via ClientTick).
-- =======================================================================

function AVU.PlayIdleSequence(actor, seqPath, loop)
    if Utils.IsActorInvalid(actor) then return false end
    local mesh = Utils.GetValidMesh(actor)
    if not mesh then return false end

    local seq = ASSETS.GetIfValid(seqPath)
    if IsNotValid(seq) then
        LogBad("PlayIdleSequence - sequence not resident (preload it in def.Assets): " .. tostring(seqPath))
        return false
    end

    local ok = pcall(function() mesh:PlayAnimation(seq, loop ~= false) end)
    return ok
end


-- [RENDERER] Hand the mesh back to its Anim Blueprint (EAnimationMode::AnimationBlueprint = 0).
-- Undoes PlayIdleSequence. Re-initialises the anim instance, so locomotion/montages work again.
-- [UNUSED] no live callers; counterpart of PlayIdleSequence, kept as its undo.

function AVU.RestoreAnimBlueprint(actor)
    if Utils.IsActorInvalid(actor) then return end
    local mesh = Utils.GetValidMesh(actor)
    if not mesh then return end
    -- BOTH args: SetAnimationMode is (EAnimationMode, bForceInitAnimScriptInstance) and the
    -- one-arg form is the silent no-op family (CLAUDE.md §3).
    pcall(function() mesh:SetAnimationMode(0, true) end)
end


-- [AUTHORITY] Stop a GIBBING NPC paying out its gib salvage, WITHOUT stopping it gibbing.
-- ClearLoot is not enough and the reason is easy to miss: TryGibbingNPC pays the salvage
-- UNCONDITIONALLY, and HasDroppedLoot only gates the separate normal-death drop. Blanking the
-- GibSalvage row handle makes that payout resolve to nothing while the shatter still plays.
-- Needed by anything that respawns (the Mage's eyes), where a lootable body is an infinite tap.

function AVU.ClearGibLoot(npc)
    if Utils.IsActorInvalid(npc) then return end

    local npcData = npc.NPCData
    if IsNotValid(npcData) then return end

    pcall(function()
        local gib = npcData[ENUMS.NpcData.GibInfo]
        gib[ENUMS.NpcGib.GibSalvage].RowName = FName("None")
        npcData[ENUMS.NpcData.GibInfo] = gib
    end)
end


-- [AUTHORITY] Make killing this actor grant NO compendium unlock or achievement credit - so a
-- variant can wear a base NPC's SKIN (spawn AS that row to get its body and kit for free) without
-- kills counting toward that species. The death path gates both on a valid row handle, so blanking
-- both RowNames on THIS actor's NPCData copy makes them early-out; real members of the base
-- elsewhere are untouched.
-- In-place SCALAR RowName writes with a read-back check - never write the row-handle struct back
-- whole, it holds a UDataTable pointer (CLAUDE.md 3).

function AVU.BlankKillCredit(actor)
    if Utils.IsActorInvalid(actor) then return end
    local nd = actor.NPCData
    if IsNotValid(nd) then return end

    for _, field in ipairs({
        ENUMS.NpcData.CompendiumKill,
        ENUMS.NpcData.AchievementStat,
    }) do
        local took
        pcall(function()
            nd[field].RowName = FName("None")
            took = nd[field].RowName:ToString()
        end)
        if took ~= "None" then
            LogBad("BlankKillCredit - NPCData." .. field .. " still reads " .. tostring(took))
        end
    end
end


-- [AUTHORITY] KILL (don't destroy) every non-invincible NPC within `radius` of `center`, so the
-- bodies remain - a battlefield, not a vanish.
--   * Sets the replicated IsDead + fires OnRep so it reads as a death on every machine; loot is
--     stripped first (AVU.StripLoot - see its freeze note).
--   * NOTE it clears EVERYTHING in range, hostile or not, so run it BEFORE a scripted wave spawns.
--   * Each OnRep_IsDead runs that NPC's FULL native death chain synchronously, so kills are
--     STAGGERED across drain slots to bound per-frame work.
--   * `label` (optional) names it in the log. Returns the kill count.
local KILL_BATCH        = 4     -- kills per drain slot
local KILL_BATCH_GAP_MS = 100
function AVU.KillNpcsInRadius(center, radius, label)
    local targets = {}
    for _, npc in ipairs(AVU.GetNearbyNpcs(center, radius)) do
        if not npc.Invincible and not npc.IsDead then targets[#targets + 1] = npc end
    end
    local total, i = #targets, 0
    if total == 0 then return 0 end

    local function killBatch()
        local batchEnd = math.min(i + KILL_BATCH, total)
        while i < batchEnd do
            i = i + 1
            local npc = targets[i]
            -- IsActorValid passes a mid-EndPlay actor during a stream-out (the level still reads as
            -- loaded); running OnRep_IsDead on one fires the native death chain on a dying actor.
            local beingDestroyed = false
            pcall(function() beingDestroyed = npc:IsActorBeingDestroyed() end)
            if not beingDestroyed and Utils.IsActorValid(npc) and not npc.IsDead then
                local who = "?"
                pcall(function() who = tostring(Utils.GetActorRowName(npc)) end)
                LogDebug("kill-> " .. who, SETTINGS.DEBUG_STORY)   -- an unmatched kill-> NAMES a hang
                AVU.StripLoot(npc)
                pcall(function()
                    npc.IsDead = true
                    Utils.MarkReplicatedDirty(npc, "IsDead")
                    npc:OnRep_IsDead()
                end)
                LogDebug("kill<- " .. who, SETTINGS.DEBUG_STORY)
            end
        end
        if i < total then
            Utils.QueueWork(killBatch, KILL_BATCH_GAP_MS)
        else
            Log(string.format("%s - killed %d NPCs (corpses kept, loot stripped)",
                label or "KillNpcsInRadius", total))
        end
    end
    killBatch()
    return total
end


-- [AUTHORITY] DESPAWN (destroy outright - no corpse, no loot, no death chain) every NPC within
-- `radius` of `center`. Clear a stage before a set-piece; use KillNpcsInRadius when you want bodies.
--   * The target list is captured ONCE up front, so it can never catch actors spawned after the call.
--   * Destroyed in small batches across drain slots. NPC-class overlap only - never touches players.

function AVU.DestroyNpcsInRadius(center, radius, label)
    local npcs = AVU.GetNearbyNpcs(center, radius)
    local total, i = #npcs, 0
    if total == 0 then return 0 end

    local function batch()
        local stop = math.min(i + KILL_BATCH, total)
        while i < stop do
            i = i + 1
            local n = npcs[i]
            if Utils.IsActorValid(n) then pcall(function() n:K2_DestroyActor() end) end
        end
        if i < total then Utils.QueueWork(batch, KILL_BATCH_GAP_MS) end
    end
    batch()
    Log(string.format("%s - despawned %d NPC(s)", label or "DestroyNpcsInRadius", total))
    return total
end


-- [AUTHORITY] Order a set of NPCs to path toward a world location (the dev "lure" call).
--   * CAVEAT: a raw move ORDER, and a behavior tree will happily override it - a boss BT ignores
--     it outright, and any NPC holding a live combat target chases that instead. NOT a reliable
--     way to walk an NPC somewhere. Fine as a nudge.
--   * To actually move one, give it a REAL hostile target at the destination and let the normal
--     combat chase path it (see the OFFICE FARGARDENS note in ModuleStory/Events).

function AVU.ForceMoveAll(npcs, target)
    local moved = 0
    for _, npc in ipairs(npcs or {}) do
        if Utils.IsActorValid(npc) then
            local c = npc:GetController()
            if IsValid(c) then
                pcall(function()
                    c:MoveToLocation(Utils.FuzzLocation(target, 300), 500, true, true, true, true, nil, true)
                end)
                moved = moved + 1
            end
        end
    end
    LogDebug("ForceMoveAll - moved " .. moved .. " NPCs", SETTINGS.DEBUG_STORY)
    return moved
end


-- [AUTHORITY] Hide a corpse on every machine now, then destroy the actor shortly after - the
-- clean removal for a summon. Call from OnDeath, AFTER any drop; dropped items are separate actors
-- and are unaffected.
--   * The DESTROY is the important half: a plain hide leaves an invisible corpse that piles up,
--     and suppressing loot can skip the game's own corpse fade-out. bHidden replicates (marked
--     dirty here) and K2_DestroyActor replicates, so it is gone on clients too.
--   * Destroys are DE-CLUMPED, not delayed: a multi-kill volley would otherwise drop N render-proxy
--     teardowns into one frame, which is sighting #3 of the D3D12 draw-UAF crash family.
--   * The 1500ms base delay stays - a dead-but-hidden body is still a BT target, so lingering
--     longer would make NPCs shoot at nothing.
local HIDE_DESTROY_DELAY_MS   = 1500
local HIDE_DESTROY_SPACING_MS = 750
local hideDestroyDueMs = 0   -- os.clock()-ms when the LAST scheduled corpse destroy lands (de-clump cursor)

-- `lingerMs` (optional) leaves the death and the corpse on show for that long first - for a body
-- whose dying is worth seeing but whose corpse the game will never clear (a loot-stripped summon).
function AVU.HideOnDeath(actor, lingerMs)
    if Utils.IsActorInvalid(actor) then return end
    if lingerMs and lingerMs > 0 then
        Utils.QueueWork(function()
            if Utils.IsActorValid(actor) then AVU.HideOnDeath(actor) end
        end, lingerMs)
        return
    end
    pcall(function() actor:SetActorHiddenInGame(true) end)
    Utils.MarkReplicatedDirty(actor, "bHidden")

    local nowMs = os.clock() * 1000
    local dueMs = math.max(nowMs + HIDE_DESTROY_DELAY_MS, hideDestroyDueMs + HIDE_DESTROY_SPACING_MS)
    hideDestroyDueMs = dueMs
    Utils.QueueWork(function()
        if Utils.IsActorValid(actor) then pcall(function() actor:K2_DestroyActor() end) end
    end, dueMs - nowMs)
end


-- =======================================================================
-- OnTick registration
-- =======================================================================

-- Run fn(actor, FAST_TICK) every fast tick; return "REMOVE" from fn to stop
-- Per-registration phase so OnTick handlers don't all fire on the same global tick (see
-- TickManager.ProcessOnTickActors). Consecutive registrations get consecutive phases =
-- perfect spread for any `% N`; mod 600 = LCM of the common Ns (5/10/30/50/100/200) so even
-- the slow handlers spread fully.
--   * slot (optional) - one entry per actor per slot: registering again replaces the old one.
--     The variant pipeline uses "def", so a re-mutation (wild -> tamed, save heal) swaps the
--     def tick instead of stacking a second one. Helpers pass no slot and always add.
local onTickPhase = 0

function AVU.RegisterOnTickActor(actor, fn, slot)
    if Utils.IsActorInvalid(actor) then return end

    local key = slot and Utils.ActorKey(actor)
    if key then
        for i = #STATE.OnTickActors, 1, -1 do
            local e = STATE.OnTickActors[i]
            if e.Slot == slot and e.Key == key then table.remove(STATE.OnTickActors, i) end
        end
    end

    local entry = {
        Actor = actor,
        Fn = fn,
        Phase = onTickPhase,
        Slot = key and slot or nil,
        Key = key,
    }
    -- Label the handler by row name + source line (getinfo once per register) - for the
    -- profiler's per-actor cost attribution AND the freeze-trace breadcrumb in TickManager,
    -- which needs entry.Src even when profiling is off.
    local PROF = require("AnDebug.Profiler")
    if PROF.Enabled or SETTINGS.DEBUG_FREEZE_TRACE then
        local row = nil
        pcall(function() row = Utils.GetActorRowName(actor) end)
        entry.Src = (row or "?") .. " " .. PROF.SrcOf(fn)
    end
    table.insert(STATE.OnTickActors, entry)
    onTickPhase = (onTickPhase + 1) % 600
end


-- The reap step shared by AVU.SelfCleanWhenAlone and the RELEASED branch of
-- AVU.WatchSummonLifetime. Returns "REMOVE" once it has destroyed the body.
local function orphanReap(sub, totalTicks, checkTicks, range, label)
    if totalTicks % checkTicks ~= 0 then return end
    local loc = sub:K2_GetActorLocation()
    if not loc or Utils.IsPlayerNearby(loc, range) then return end
    pcall(function() sub:K2_DestroyActor() end)
    LogDebug(label .. " - orphaned and nobody around, self-cleaned", SETTINGS.DEBUG_NPC_ACTIONS)
    return "REMOVE"
end


-- [AUTHORITY] Make a script-spawned NPC clean itself up once no player is near it.
--   * A script-spawned NPC belongs to no spawner group, so the game never unloads it - left alone
--     it stands in an empty level forever, and a repeatable trigger (a signal pest's stalker call,
--     a wave summon) leaks a body per firing.
--   * Use this when the summon has no surviving parent to hang its lifetime off. AVU.WatchSummonLifetime
--     is the right call whenever there IS one, and it runs this same reap on its released branch.
--   * Not interchangeable with WatchSummonLifetime + ReleaseOnParentDeath for a parent that dies
--     instantly (the signal pests): that path has to see the parent dead to latch, and a parent
--     already destroyed by the first check reads as "unloaded" and takes the child with it.
-- opts: OrphanRange (15000 = the game's own NPC unload distance), CheckTicks (50 ~5s), Label.

function AVU.SelfCleanWhenAlone(actor, opts)
    if Utils.IsActorInvalid(actor) then return end
    opts = opts or {}
    local range      = opts.OrphanRange or 15000
    local checkTicks = opts.CheckTicks or 50
    local label      = opts.Label or "summon"

    AVU.RegisterOnTickActor(actor, function(sub, totalTicks)
        if Utils.IsActorInvalid(sub) then return "REMOVE" end
        return orphanReap(sub, totalTicks, checkTicks, range, label)
    end)
end


-- [AUTHORITY] Tie a SCRIPT-SPAWNED summon's lifetime to its summoner.
-- WHY: a script-spawned NPC is in NO spawner group, so the game NEVER unloads it - while its
-- summoner usually DOES unload on stream-out, and the re-streamed copy spawns its own minion. Leave
-- one standing across that cycle and they stack up forever.
--
-- THE SUBTLETY: once the parent's wrapper goes invalid you CANNOT tell "died" from "streamed out".
-- So parentDied is latched from IsDead every tick WHILE THE PARENT IS STILL READABLE, never at
-- teardown. Then:
--   * parent vanished, never seen dead -> unloaded -> DESTROY the child.
--   * parent DIED -> opts.ReleaseOnParentDeath: false (default) = the child dies with it; true =
--     the child is RELEASED, fights on, and owns its own exit (it self-destroys once no player is
--     within OrphanRange, so it can't strand in an empty level).
-- opts: ReleaseOnParentDeath (false), OrphanRange (15000 = the game's own NPC unload distance),
--       CheckTicks (50 = ~5s between orphan checks), Label (log prefix).

function AVU.WatchSummonLifetime(child, parent, opts)
    if Utils.IsActorInvalid(child) then return end
    opts = opts or {}
    local release     = opts.ReleaseOnParentDeath == true
    local orphanRange = opts.OrphanRange or 15000
    local checkTicks  = opts.CheckTicks or 50
    local label       = opts.Label or "summon"

    local parentDied = false
    AVU.RegisterOnTickActor(child, function(sub, totalTicks)
        if Utils.IsActorInvalid(sub) then return "REMOVE" end

        if not parentDied then
            if Utils.IsActorValid(parent) then
                if release then
                    local dead = false
                    pcall(function() dead = parent.IsDead == true end)
                    if dead then parentDied = true end   -- latch NOW, while we still can
                end
                return
            end
            -- Parent gone without a death we saw: it unloaded. The child goes with it.
            pcall(function() sub:K2_DestroyActor() end)
            Utils.LogDebug(label .. " - parent unloaded, removed", SETTINGS.DEBUG_NPC_ACTIONS)
            return "REMOVE"
        end

        -- RELEASED: nothing else will ever clean this up, so it self-cleans once nobody is around.
        -- Same step AVU.SelfCleanWhenAlone runs on its own.
        return orphanReap(sub, totalTicks, checkTicks, orphanRange, label)
    end)
end


-- [AUTHORITY] Strip an Exor's inherited RadioactiveZone child actor.
--   * WHY: the zone damages everything nearby on an FTimerManager TIMER, and that timer re-enters
--     our ProcessDamage hook - which among a crowd of dying pets/summons is the 0x70 teardown crash
--     ([[anteup2-areaeffect-timer-teardown-crash]]). Every Exor variant that doesn't specifically
--     want a radiation aura clears it.
--   * SetChildActorClass(nil) stops it coming back; DestroyChildActor also kills the LIVE zone now,
--     so no damage timer keeps running in the frames before the class change lands.
--   * To RETUNE the aura instead (the Plague Pest), write ChildActor.ZoneRadiationPerTick.

function AVU.ClearRadiationZone(actor)
    if Utils.IsActorInvalid(actor) then return end
    pcall(function()
        local rz = actor.RadiationZone
        if IsValid(rz) then
            rz:SetChildActorClass(nil)
            rz:DestroyChildActor()
        end
    end)
end


-- Flip an NPC's mesh 180 degrees (ROLL) for a CEILING pose, or right it again. Pair it with a
-- gravity flip (AVU.SetCeilingGravity). Rotation ONLY - deliberately no scale write, so a
-- def.BodyScale hitbox survives the flip.
--   * A ROLL, NEVER A NEGATIVE SCALE. A scale SIGN-flip forces UE to RECREATE the scene proxy of
--     every child component, and if that coincides with a child mesh swapping or being freed the
--     render thread rebuilds a proxy over freed memory = access violation. A rotation only updates
--     the existing proxy's transform.
--   * Skips a dead/dying actor - never touch a gibbing mesh.

function AVU.PoseGravFlip(actor, mesh, goUp)
    if Utils.IsActorInvalid(actor) or actor.IsDead then return end
    if not (mesh and IsValid(mesh)) then return end
    pcall(function()
        local r = mesh:GetRelativeRotation()
        mesh:SetRelativeRotation(FRotator(r.Pitch, r.Yaw, goUp and 180.0 or 0.0))
    end)
end


-- Flip an NPC between the CEILING and the floor: gravity direction + strength, the mesh roll, and a
-- LaunchCharacter nudge to force a movement recompute (without it the body can hang mid-air a beat).
--   * Gravity DIRECTION must stay a UNIT vector - it replicates quantized, and a non-unit one spams
--     "ReplicatedGravityDirection NetSerialize failed" every net update. Strength goes in GravityScale.
--   opts: UpScale (2), DownScale (1), Mesh (default the body mesh), Pose = false to skip the roll,
--         NudgeZ (1; 0 skips the nudge - for per-tick re-asserts like the Crystallisk crawl).

function AVU.SetCeilingGravity(actor, goUp, opts)
    if Utils.IsActorInvalid(actor) or actor.IsDead then return end
    local move = actor.CharacterMovement
    if IsNotValid(move) then return end
    opts = opts or {}

    pcall(function()
        if goUp then
            move:SetGravityDirection(FVector(0, 0, 1))
            move.GravityScale = opts.UpScale or 2
        else
            move:SetGravityDirection(FVector(0, 0, -1))
            move.GravityScale = opts.DownScale or 1
        end
    end)

    if opts.Pose ~= false then
        AVU.PoseGravFlip(actor, opts.Mesh or Utils.GetValidMesh(actor), goUp)
    end

    if opts.NudgeZ ~= 0 then
        pcall(function() actor:LaunchCharacter(FVector(0, 0, opts.NudgeZ or 1), false, false) end)
    end
end


-- Restore normal floor gravity (direction down, scale 1). The corpse/cleanup half of
-- SetCeilingGravity: a body must not stick to the ceiling, and a stream-out re-use of the
-- slot must start clean. Deliberately does NOT skip a dead actor - OnDeath is the caller.

function AVU.RestoreGravity(actor)
    if Utils.IsActorInvalid(actor) then return end
    local move = actor.CharacterMovement
    if IsValid(move) then
        pcall(function()
            move:SetGravityDirection(FVector(0, 0, -1))
            move.GravityScale = 1
        end)
    end
end


-- ONE TABLE, not a row of `local CEIL_*`: AVUtils runs close to Lua's hard 200-locals-per-chunk
-- limit, and overflowing fails the WHOLE FILE at an unrelated line ([[anteup2-avutils-local-limit]]).
local CEIL = {
    VerifyTicks  = 25,     -- 2.5s at the 10Hz FAST_TICK - how long it gets to arrive
    RiseCheckTicks = 3,    -- rise sample cadence in flight; bounds the overshoot past MaxRise
    MaxRise      = 2000,   -- 20m: a ceiling higher than this counts as "no ceiling"
    BucketXY     = 600,    -- 6m verdict grid, room-scale
    BucketZ      = 300,    -- 3m, deliberately finer than XY - see the banner
    BadTicks     = 1800,   -- 3 min before a "no ceiling" verdict is retried
    FailCooldown = 150,    -- 15s before a FAILED body probes again, wherever it walked to
    FallGrav     = 2,      -- recovery fall gravity, as a multiple of its normal floor value
    FallMax      = 100,    -- 10s safety cap on the fall watch, so it can't wedge armed

    Bad = {},   -- bucket key -> FAST_TICK of the verdict (TTL only so a freak verdict self-heals)
    -- WEAK-KEYED BY WRAPPER, sound only because they are written AND read from the OnTick path
    -- alone (CLAUDE.md's keying rule). A ProcessDamage-family hook's FRESH wrapper never hits -
    -- which is why the fail cooldown enforces itself here instead of being consulted by callers.
    Pending  = setmetatable({}, { __mode = "k" }),   -- actor -> { At, X, Y, Z } probe in flight
    Falling  = setmetatable({}, { __mode = "k" }),   -- actor -> { Down, By } recovery fall
    Cooldown = setmetatable({}, { __mode = "k" }),   -- actor -> tick when probing may resume
}

-- Per-world reset. Old-world coords mean nothing, and FAST_TICK restarts at 0 - so a surviving
-- verdict would also read as freshly-stamped forever (the BarrierPings clock hazard).

function AVU.ResetCeilingMap()
    CEIL.Bad      = {}
    CEIL.Pending  = setmetatable({}, { __mode = "k" })
    CEIL.Falling  = setmetatable({}, { __mode = "k" })
    CEIL.Cooldown = setmetatable({}, { __mode = "k" })
end

local function ceilKey(x, y, z)
    return math.floor(x / CEIL.BucketXY) .. "," .. math.floor(y / CEIL.BucketXY)
        .. "," .. math.floor(z / CEIL.BucketZ)
end

-- True if this spot has already been PROVEN to have no reachable ceiling. Pure math on a location
-- (no actor, no engine call), so it is safe to call from any hook - including the fresh-wrapper
-- OnDamageTaken path. Check it before every up-flip.

function AVU.CeilingKnownBad(loc)
    if not loc then return false end
    local key = ceilKey(loc.X or 0, loc.Y or 0, loc.Z or 0)
    local at = CEIL.Bad[key]
    if not at then return false end
    if (STATE.FAST_TICK - at) > CEIL.BadTicks then
        CEIL.Bad[key] = nil
        return false
    end
    return true
end

-- [AUTHORITY] Drive the verify machine. Call it FIRST in a clinger's OnTick, ABOVE that handler's
-- own `% N` gate (the deadline is 25 ticks, so a handler gated to 50 would check late).
--   * RETURNS TRUE WHILE IT HAS CUSTODY (recovery fall / fail cooldown) and a caller that can flip
--     gravity MUST bail on true: the blacklist is keyed by the LAUNCH spot, so a body falling from
--     67m reads KnownBad = false the whole way down and would be flung straight back up.
--   * Seeds off "gravity is UP", so every flip path is covered without registering anything, and a
--     PASS re-seeds - which catches a pest that walks OFF the end of a ceiling.
--   * opts.DownScale = THIS BODY'S NORMAL FLOOR GRAVITY, restored after the recovery fall - pass it
--     whenever the variant isn't 1. Plus VerifyTicks / MaxRise / FallGrav / FailCooldown.

function AVU.CeilingVerifyTick(actor, totalTicks, opts)
    if Utils.IsActorInvalid(actor) or actor.IsDead then
        CEIL.Pending[actor] = nil
        CEIL.Falling[actor] = nil
        return
    end
    local move = actor.CharacterMovement
    if IsNotValid(move) then return end
    opts = opts or {}
    local normalDown = opts.DownScale or 1

    -- 1. RECOVERY FALL - restore real floor gravity on landing: GravityScale is also the leap-arc
    --    knob, so leaving it doubled would quietly retune the variant's signature move.
    local f = CEIL.Falling[actor]
    if f then
        local landed = false
        pcall(function() landed = move:IsMovingOnGround() end)
        if landed or totalTicks >= f.By then
            pcall(function() move.GravityScale = f.Down end)
            CEIL.Falling[actor] = nil
        end
        return true   -- custody: the caller must not touch gravity while it is coming down
    end

    -- 2. FAIL COOLDOWN - grounded-only window. Anything that flips it up meanwhile (the on-hit
    --    reversal, which can't see this book) is reversed on the next tick.
    local until_ = CEIL.Cooldown[actor]
    if until_ then
        if totalTicks < until_ then
            local flipped = false
            pcall(function() flipped = move.GravityDirection.Z > 0 end)
            if flipped then AVU.SetCeilingGravity(actor, false, { DownScale = normalDown }) end
            return true   -- custody
        end
        CEIL.Cooldown[actor] = nil
    end

    local up = false
    pcall(function() up = move.GravityDirection.Z > 0 end)
    if not up then
        CEIL.Pending[actor] = nil   -- on the floor (or mid-lunge, which poses up but pulls down)
        return
    end

    local p = CEIL.Pending[actor]
    if p and totalTicks < p.Next then return end   -- between rise samples

    local loc = actor:K2_GetActorLocation()
    if not loc then return end

    if not p then
        CEIL.Pending[actor] = {
            At = totalTicks + (opts.VerifyTicks or CEIL.VerifyTicks),
            Next = totalTicks + CEIL.RiseCheckTicks,
            X = loc.X, Y = loc.Y, Z = loc.Z,
        }
        return
    end

    -- Rise alone decides. A body clinging ABOVE MaxRise (a skybox, a 40m atrium roof) is exactly
    -- the case to reject, so being grounded is not a pass. Sampled mid-flight so a failing climb
    -- is caught at ~MaxRise, not at the deadline ~67m up.
    local rise = loc.Z - p.Z
    if rise <= (opts.MaxRise or CEIL.MaxRise) then
        if totalTicks < p.At then
            p.Next = totalTicks + CEIL.RiseCheckTicks
            return
        end
        CEIL.Pending[actor] = nil   -- clung: done; the next tick re-seeds
        return
    end
    CEIL.Pending[actor] = nil

    -- 3. NEVER ARRIVED. Blacklist the spot it launched from, sit the body out, and drop it.
    CEIL.Bad[ceilKey(p.X, p.Y, p.Z)] = STATE.FAST_TICK
    CEIL.Cooldown[actor] = totalTicks + (opts.FailCooldown or CEIL.FailCooldown)

    -- We put it 67m up, so the drop must not be what kills it. -1 = the engine's own "no fall
    -- damage" sentinel; NPC fall damage is a guaranteed KILL, not chip (see [[af-npc-fall-damage]]).
    -- Inert on Pest/Exor, which already inherit -1 - it is for a future grunt-based clinger (700).
    pcall(function() actor.FallDistanceThreshold = -1 end)

    AVU.SetCeilingGravity(actor, false,
        { DownScale = normalDown * (opts.FallGrav or CEIL.FallGrav) })
    -- Velocity AFTER the flip (the nudge inside SetCeilingGravity would land on top of the zero).
    -- Restored gravity only DECELERATES the ~4000uu/s climb, so without this it coasts ~27m higher.
    pcall(function() move.Velocity = FVector(0, 0, 0) end)
    CEIL.Falling[actor] = { Down = normalDown, By = totalTicks + CEIL.FallMax }

    LogDebug("CeilingVerify - no ceiling above " .. ceilKey(p.X, p.Y, p.Z)
        .. " (rose " .. math.floor(rise) .. "uu) - dropping, grounded for "
        .. ((opts.FailCooldown or CEIL.FailCooldown) / 10) .. "s",
        SETTINGS.DEBUG_NPC_ACTIONS)
end


-- =======================================================================
-- CeilingProbeSpawn - ANSWER THE CEILING QUESTION BEFORE THE FIRST FLIP, not 2.5s into it.
--
-- AVU.CeilingVerifyTick learns "no ceiling here" by TRYING: it flips the body up and measures the
-- rise VerifyTicks later. That is the right machine for a body already clinging, but it is the
-- wrong FIRST answer - a pest whose Stats flips gravity up on an open rooftop climbs ~67m before
-- the deadline and then falls the same distance back. Five seconds of "it floated off", every
-- spawn, in every ceiling-less room.
--
-- So a clinger's Stats asks FIRST, with one upward Visibility trace:
--     if AVU.CeilingProbeSpawn(actor) then  <flip gravity up>  end
--
--   * ONE trace per spawn (~10ms, and the cost is UE4SS marshalling so LENGTH is free - only the
--     CALL COUNT matters). That is affordable exactly here and nowhere else: mutation is already
--     staggered per NPC, unlike the damage-driven flip paths CeilingVerify.md rules a trace out for.
--   * A NEGATIVE VERDICT IS RECORDED IN THE SHARED BLACKLIST, so the whole pack learns the room
--     from one probe and the tick machines (PeriodicGravFlip / ceilingAmbushTick) keep it grounded
--     without re-deriving anything. A positive verdict records nothing - the tick verify still owns
--     the "it walked off the end of the ceiling" case.
--   * Already-known-bad spots answer false with NO trace at all.
--   * FAIL-OPEN: any trace error returns true, so a probe that cannot run leaves the variant
--     behaving exactly as it did before this existed (verify-by-trying).
--   * MaxRise is the SAME question CeilingVerifyTick asks - "is the ceiling close enough to be
--     worth going to" - so the two must stay on one number. Both default to CEIL.MaxRise.
-- opts: MaxRise (CEIL.MaxRise), Channel (ENUMS.Trace.VISIBILITY), StartZ (30, above the capsule centre).
-- =======================================================================

function AVU.CeilingProbeSpawn(actor, opts)
    if Utils.IsActorInvalid(actor) then return false end
    opts = opts or {}

    local loc = actor:K2_GetActorLocation()
    if not loc then return true end   -- unreadable: fail open, let the tick verify decide

    if AVU.CeilingKnownBad(loc) then return false end

    local rise = opts.MaxRise or CEIL.MaxRise
    local from = FVector(loc.X, loc.Y, loc.Z + (opts.StartZ or 30))
    local to   = FVector(loc.X, loc.Y, loc.Z + rise)

    -- IsPathBlocked is itself fail-open (returns false on a trace error), which here would read as
    -- "no ceiling" - the wrong way round. So run the trace ourselves and treat a THROW as a pass.
    local ok, blocked = pcall(AVU.IsPathBlocked, actor, from, to, { actor }, opts.Channel or ENUMS.Trace.VISIBILITY)
    if not ok then return true end
    if blocked then return true end

    -- Nothing overhead within reach. Record the SPOT (not the actor), same buckets the verify
    -- machine uses, so every other clinger here skips its own probe and its own climb.
    AVU.CeilingMarkBad(loc)
    LogDebug("CeilingProbeSpawn - no ceiling within " .. rise .. "uu, staying grounded",
        SETTINGS.DEBUG_NPC_ACTIONS)
    return false
end


-- Record a "no reachable ceiling here" verdict from outside the verify machine (the spawn probe).
-- Same bucket grid and same TTL, so one map serves both.

function AVU.CeilingMarkBad(loc)
    if not loc then return end
    CEIL.Bad[ceilKey(loc.X or 0, loc.Y or 0, loc.Z or 0)] = STATE.FAST_TICK
end


-- [AUTHORITY] The self-cycling ceiling flip - the OnTick machine behind the Antegrav / Anterazor
-- Pests. Every PeriodTicks it toggles the NPC between ceiling and floor, and eases gravity DOWN
-- mid-lunge so a clinger can still land its leap. Return it straight from a variant's OnTick.
--   * Hand-rolled rather than a periodic AVU.SetCeilingGravity because the lunge branch poses
--     CEILING-side while pulling gravity DOWN - a decoupling `goUp` can't express.
--   * Does its own DEEP mesh validity check and returns "REMOVE" once the mesh is gone.
-- opts: PeriodTicks (50 ~5s), UpScale (2.5), DownScale (1.5), LungeScale (0.5),
--       PoseScale (FVector | nil - re-asserts that mesh scale on every flip, for a body that would
--       otherwise be shrunk; leave nil for a rotation-ONLY pose so a def.BodyScale hitbox survives),
--       Verify = false to opt out of the ceiling check. Anything else is forwarded to it.

function AVU.PeriodicGravFlip(actor, totalTicks, opts)
    local mesh = Utils.GetValidMesh(actor)
    if not mesh then return "REMOVE" end

    local movement = actor.CharacterMovement
    if IsNotValid(movement) then return end

    opts = opts or {}
    opts.DownScale = opts.DownScale or 1.5   -- resolved here: CeilingVerifyTick restores this value

    -- ABOVE the period gate (deadline 25 ticks, this wakes every 50). True = it owns the body, so
    -- skip the cycle or a boundary landing mid-fall flings it back up.
    if opts.Verify ~= false and AVU.CeilingVerifyTick(actor, totalTicks, opts) then return end

    if totalTicks % (opts.PeriodTicks or 50) ~= 0 then return end

    -- Re-assert the pose scale (if any) BEFORE the rotation roll, guarded like PoseGravFlip so a
    -- dead/dying mesh is never touched.
    local function pose(goUp)
        if opts.PoseScale and not (Utils.IsActorInvalid(actor) or actor.IsDead) and IsValid(mesh) then
            pcall(function() mesh:SetRelativeScale3D(opts.PoseScale) end)
        end
        AVU.PoseGravFlip(actor, mesh, goUp)
    end

    -- Unit DIRECTION + GravityScale for strength (a non-unit direction fails NetQuantizeNormal
    -- replication - see SetCeilingGravity). Ease gravity during a lunge so it can actually land hits.
    if actor.IsLungingInAir then
        pose(true)
        movement:SetGravityDirection(FVector(0, 0, -1))
        movement.GravityScale = opts.LungeScale or 0.5
        return
    end

    local onFloor = movement.GravityDirection.Z < 0
    if onFloor then
        -- Proven ceiling-less here - stay down.
        if opts.Verify ~= false and AVU.CeilingKnownBad(actor:K2_GetActorLocation()) then return end
        -- flip to the ceiling (strong upward pull)
        pose(true)
        movement:SetGravityDirection(FVector(0, 0, 1))
        movement.GravityScale = opts.UpScale or 2.5
    else
        -- drop back to the floor
        pose(false)
        movement:SetGravityDirection(FVector(0, 0, -1))
        movement.GravityScale = opts.DownScale   -- resolved at the top
    end
    -- Force a movement recompute after the gravity change
    actor:LaunchCharacter(FVector(0, 0, 1), false, false)
end


-- Park a robot's native melee channels (the Robot_* family's Power/Spin/Behind attacks):
-- a huge cooldown + the matching SetXOnCooldown() so the BT can't fire that channel again
-- this life.
--   * Parks only the channels named - per-variant TUNING (SpinAttackRadius, launch power, ...)
--     stays at the call site.
--   * Used when a variant drives its own scripted attack and the native one would double-fire
--     (the Security-bot family's shape).
--   AVU.RobotParkAttacks(actor, { Power = true, Spin = true, Behind = true })

function AVU.RobotParkAttacks(actor, channels)
    if Utils.IsActorInvalid(actor) or not channels then return end
    if channels.Power then
        pcall(function()
            actor.PowerAttackCooldown = 3600
            actor:SetPowerAttackOnCooldown()
        end)
    end
    if channels.Spin then
        pcall(function()
            actor.SpinAttackCooldown = 3600
            actor:SetSpinAttackOnCooldown()
        end)
    end
    if channels.Behind then
        pcall(function()
            actor.BehindAttackCooldown = 3600
            actor:SetBehindAttackOnCooldown()
        end)
    end
end


-- =======================================================================
-- SetBodyScale - TRUE actor scale (the root CAPSULE and everything attached, mesh included). Use it
-- when the HITBOX must scale, not just the look.
--   * Ranged hits trace the capsule, which a mesh-only AVU.SetVisualScale never touches - a mesh
--     scaled up 20% has a head poking outside an unchanged capsule, so headshots miss.
--   * NOT replicated. Apply the SAME value on the SERVER (NpcManager's BODYSCALE step) AND each
--     pure CLIENT (ClientVisuals) so the capsules match; a client-ONLY scale bobs and jitters
--     because it fights a server capsule of a different size.
--   * Lives on a DIFFERENT axis than the game's own mesh sizing, so buff/stat recalcs don't fight
--     it - unlike SetVisualScale, which they overwrite.
--   * CAVEAT: the frost/slushie SizeChanger debuff resets actor scale to 1 on thaw. Re-assert if
--     that matters.
--   * The feet are put back afterwards. A capsule scales about its CENTRE, so a shrunk body is
--     left hovering by the half-height it lost, and an idle NPC has nothing to make it fall until
--     something starts its movement - it hangs in the air until it aggros. AUTHORITY only; a
--     client proxy takes its position from replication anyway.
--   * NOT for an ATTACHED body: a welded passenger's seat is its position, so walking the root
--     down just sinks it into its carrier (the Jotun rider's saddle).
-- scale: number (uniform) | {X=,Y=,Z=} | FVector
-- =======================================================================

function AVU.SetBodyScale(actor, scale)
    if Utils.IsActorInvalid(actor) then return end
    local v
    if type(scale) == "number" then
        v = FVector(scale, scale, scale)
    elseif type(scale) == "table" then
        v = FVector(scale.X or 1, scale.Y or scale.X or 1, scale.Z or scale.X or 1)
    else
        v = scale or FVector(1, 1, 1)   -- already an FVector (userdata)
    end

    local before = AVU.CapsuleHalfHeight(actor, 0)
    pcall(function() actor:SetActorScale3D(v) end)
    if not Utils.IsAuthority() then return end

    -- A welded passenger keeps the seat it was given. The drop is otherwise large: the attach
    -- scale is RELATIVE and this write is WORLD, so a rider on a 1.3x mount loses that 1.3 here
    -- and the compensation walks it a quarter of a capsule down into the carrier.
    local carrier
    pcall(function() carrier = actor:GetAttachParentActor() end)
    if IsValid(carrier) then
        LogDebug(string.format("SetBodyScale - attached body kept its seat (drop skipped: %d)",
            math.floor(before - AVU.CapsuleHalfHeight(actor, 0))), SETTINGS.DEBUG_NPC_ACTIONS)
        return
    end

    local shift = before - AVU.CapsuleHalfHeight(actor, 0)
    if before <= 0 or math.abs(shift) < 1 then return end
    pcall(function()
        local l = actor:K2_GetActorLocation()
        -- Swept, so a shrink settles ON the floor and a grow stops at the ceiling instead of
        -- teleporting into either.
        actor:K2_SetActorLocation(FVector(l.X, l.Y, l.Z - shift), true, {}, false)
    end)
end


-- =======================================================================
-- SetNavRadius - the MOVEMENT footprint, on its own axis. Writes the root capsule's radius as an
-- ABSOLUTE world-space value, whatever def.BodyScale did to the actor. The third member of the
-- size family: SetBodyScale changes EVERYTHING, PadHitbox changes only the HITBOX, this changes
-- only WHERE THE BODY FITS.
--   * WHY: SetBodyScale scales the capsule, the mesh and the mesh's PHYSICS ASSET by one factor,
--     so a bot upscaled to look imposing also walks around inside a wider collision cylinder and
--     wedges in doorways. But a weapon hit never traces the capsule - it traces the physics asset
--     (see PadHitbox's header) - so pulling the capsule back to native costs essentially no
--     hitbox. What you do give back is the capsule's share of body-to-body contact (shoving,
--     melee overlap) and the nav obstacle it punches, both of which is the point.
--   * A NON-UNIFORM BodyScale CANNOT DO THIS. The capsule takes the actor's MINIMUM axis scale
--     (UShapeComponent::GetShapeScale), so {X=1.25, Y=1.25, Z=1.1} is a 1.1x capsule, not 1.25x -
--     thinning XY thins the mesh with it and never thins the capsule alone.
--   * ABSOLUTE, so it is IDEMPOTENT: the actor scale is divided back out of the write, so a
--     re-mutation - or a host running both the authority and the client half - lands on the same
--     number instead of compounding. Must run AFTER the scale is applied, or it divides by 1.
--   * HALF-HEIGHT IS LEFT ALONE - that is what holds the body off the floor, and SetCapsuleRadius
--     only ever raises it (never shrinks it) so a smaller radius can't drop the NPC.
--   * NavAgentProps.AgentRadius is deliberately NOT touched. Path queries pick nav data by agent
--     size and this build ships one navmesh, so a mismatched agent is how you lose pathing
--     entirely. Leaving it alone means the body PATHS like a stock one and now FITS like one too.
--   * NOT REPLICATED (capsule size is not a replicated property). Same both-ends contract as
--     BodyScale: authority applies it (NpcManager NAVRADIUS), each pure client mirrors it
--     (ClientVisuals). Mismatched capsules bob against position replication.
-- =======================================================================

-- Native CollisionCylinder radii, read off the FModel BP exports - the value to hand SetNavRadius
-- when the intent is "walk around like a stock body of this family". Kept in ONE place because
-- four unrelated variant files now need the same number and two literals drift.
--   Robot    60 (half-height 110) - NPC_Robot_ParentBP; Security/Defense/Containment inherit it
--   Peccary  54.49 (half-height 54.49, so it is a SPHERE natively) - NPC_Monster_Peccary;
--            Peccary_Armored inherits it
--   Humanoid 32 (half-height 88, the ACharacter default) - Abiotic_Character_ParentBP, which every
--            NPC_Base_ParentBP descendant inherits unchanged: grunt, Gatekeeper, Order, Exor,
--            DarkLens, Pillager, zombie, narrative human
AVU.NATIVE_NAV_RADIUS = { Robot = 60, Peccary = 54.49, Humanoid = 32 }

function AVU.SetNavRadius(actor, radius)
    if Utils.IsActorInvalid(actor) then return end
    radius = tonumber(radius)
    if not radius or radius <= 0 then return end
    pcall(function()
        local cap = actor.CapsuleComponent
        if Utils.IsComponentInvalid(cap) then return end
        -- The setter takes the UNSCALED radius and the capsule picks the root transform's scale up
        -- on top, so divide that factor back out. Read it rather than re-deriving it from
        -- def.BodyScale - min-axis, and the frost SizeChanger debuff can have moved it since.
        local scaled   = tonumber(cap:GetScaledCapsuleRadius())   or 0
        local unscaled = tonumber(cap:GetUnscaledCapsuleRadius()) or 0
        local s = (scaled > 0 and unscaled > 0) and (scaled / unscaled) or 1
        -- bUpdateOverlaps = FALSE: we run inside the WorkQueue drain (a hook), and an overlap
        -- update there can dispatch BP End-Overlap logic - an AreaEffect leave is a buff REMOVE,
        -- which cold-loads (see [[anteup2-bigbot-turret-and-removebuff]]) = the CLAUDE.md S2
        -- blocking-load-in-hook deadlock. The radius only ever SHRINKS here, so the stale set is
        -- merely too generous, and the NPC's next move sweep refreshes it a frame later anyway.
        cap:SetCapsuleRadius(radius / s, false)
    end)
end


-- =======================================================================
-- PadHitbox - an INVISIBLE hit sphere welded to the body, for an NPC you keep missing because its
-- collision is much smaller than what you can see. The counterpart to SetBodyScale: that changes
-- the SIZE (and takes the hitbox with it), this changes ONLY the hitbox.
--
-- WHY IT IS NEEDED: a weapon hit does not trace the capsule - it traces the skeletal mesh's PHYSICS
-- ASSET, which is authored per mesh and can be far tighter than the silhouette. The Mage Eye is the
-- worst case in the game (a 3.7-radius core sphyl inside a 31x19x19 mesh), and SetBodyScale cannot
-- fix it: it scales the physics bodies and the visual by the SAME factor.
--
--   * radius is in ACTOR-local units, so it scales with def.BodyScale like the capsule does.
--     opts.Offset defaults to the BODY MESH's own RelativeLocation, not the actor origin - that
--     matters, since the eye's mesh sits +54.6 above its capsule and a pad at the origin would hang
--     in the air under the drone.
--   * COLLISION IS COPIED FROM THE BODY MESH, then a few channels are forced to Ignore. Copying
--     keeps us out of the game's nine CUSTOM channel indices (which we must not hardcode); the
--     ignore list stops a big invisible sphere blocking movement, shoving the camera or eating LoS.
--     Both halves copy the game's OWN extra hit volume, the Rook's riot shield.
--   * QUERY-ONLY, never QueryAndPhysics: a Chaos body on a moving actor is the mesh-swap crash
--     family (see this file's GROUND RULES).
--   * A pad hit carries NO bone name, and an unknown bone resolves to TORSO. Free on an eye (whose
--     bones are in no limb list anyway) but it would FLATTEN HEADSHOTS on a humanoid.
--   * APPLY ON EVERY MACHINE - the weapon trace runs on the SHOOTER and a runtime component does
--     not replicate. IDEMPOTENT (it re-tunes the pad it finds by tag), so a host running both the
--     authority and client steps is fine, as is a re-mutation.
-- Returns the component, or nil (mesh not streamed in yet - the caller may retry).
-- =======================================================================

local HITPAD_TAG   = "antehitpad"
local SPHERE_CLASS = "/Script/Engine.SphereComponent"
-- WorldStatic, WorldDynamic, Pawn, Visibility, Camera, Vehicle - the ENGINE channel indices are
-- fixed, unlike the game's custom ones. Same set the Rook's riot shield overrides to Ignore.
local HITPAD_IGNORE = { 0, 1, 2, 3, 4, 6 }

function AVU.PadHitbox(actor, radius, opts)
    if Utils.IsActorInvalid(actor) then return nil end
    radius = tonumber(radius)
    if not radius or radius <= 0 then return nil end
    opts = opts or {}

    local mesh = Utils.GetValidMesh(actor)
    if not mesh then return nil end

    local cls = ASSETS.GetIfValid(SPHERE_CLASS)
    if IsNotValid(cls) then return nil end

    -- Centre on the BODY unless told otherwise (see the header - the eye's mesh is +54.6 up).
    local at = opts.Offset
    if type(at) == "table" then
        at = FVector(at.X or 0, at.Y or 0, at.Z or 0)
    elseif not at then
        pcall(function()
            local rl = mesh.RelativeLocation
            if rl then at = FVector(rl.X, rl.Y, rl.Z) end
        end)
    end
    at = at or FVector(0, 0, 0)

    local pad
    pcall(function()
        local found = actor:GetComponentsByTag(cls, FName(HITPAD_TAG))
        if found and found:GetArrayNum() > 0 then pad = found[1] end
    end)

    if IsNotValid(pad) then
        local ok, err = pcall(function()
            pad = actor:AddComponentByClass(cls, false, FTransform(), false)   -- auto-attaches to root
            if IsNotValid(pad) then error("AddComponentByClass returned nothing") end
            -- A fresh shape component registers on ITS defaults (block-everything, radius 32) -
            -- park it before we size and re-channel it, per this file's collision GROUND RULE.
            pad:SetCollisionEnabled(0)   -- NoCollision
            table.insert(pad.ComponentTags, FName(HITPAD_TAG))
        end)
        -- Re-validate: AddComponentByClass can run BP construction.
        if not ok or Utils.IsActorInvalid(actor) or Utils.IsComponentInvalid(pad) then
            LogBad("PadHitbox - " .. tostring(err or "actor/component gone during the add"))
            return nil
        end
    end

    pcall(function()
        pad:SetComponentTickEnabled(false)
        pad:SetVisibility(false, false)
        pad:SetGenerateOverlapEvents(false)   -- traces only; never feed the game's overlap logic
        pad:SetSphereRadius(radius, false)
        pad:K2_SetRelativeLocationAndRotation(at, FRotator(), false, {}, true)

        -- Behave EXACTLY like the body on every channel, then drop the ones a big invisible sphere
        -- must not own (see the header).
        pad:SetCollisionObjectType(mesh:GetCollisionObjectType())
        for ch = 0, 31 do
            pad:SetCollisionResponseToChannel(ch, mesh:GetCollisionResponseToChannel(ch))
        end
        for _, ch in ipairs(HITPAD_IGNORE) do
            pad:SetCollisionResponseToChannel(ch, 0)   -- ECR_Ignore
        end
        pad:SetCollisionEnabled(1)            -- QueryOnly
    end)

    return pad
end


-- =======================================================================
-- SetTimeDilation - set CustomTimeDilation AND push it over the VariantSignal channel so CLIENTS
-- mirror the timing. Use this, not a raw CustomTimeDilation write, for any post-spawn change.
--   * CTD doesn't replicate; a variant opts in with def.MirrorTimeDilation = true and ClientVisuals
--     applies the signalled value each tick.
--   * CAVEAT: CTD on a client SIMULATED PROXY rubber-bands POSITION while the actor is MOVING (it
--     scales movement too). Clean for stationary/anim-only phases; if a moving phase rubber-bands,
--     mirror an anim-only rate instead.
-- =======================================================================

function AVU.SetTimeDilation(actor, tdi)
    if Utils.IsActorInvalid(actor) then return end
    pcall(function() actor.CustomTimeDilation = tdi end)
    VariantSignal.Set(actor, VariantSignal.TDI, tdi)
end


-- =======================================================================
-- ReloadDilation - retime an NPC's RELOAD, correctly, in one call. [OnReload]
--
-- WHY NOT AVU.ModAnimationSpeed (what every reload used to do):
--   * `Montage_SetPlayRate` is a LOCAL AnimInstance write, and our OnReload dispatch is
--     authority-only. The reload really does end early on the SERVER, but every remote client
--     plays the full-length clip and watches the NPC shoot mid-reload.
--   * It matches BY ASSET PATH, so it silently no-ops on any base whose ReloadMontage differs
--     (e.g. `NPC_Grunt_Guard`/`_Offduty`, which override the grunt's SMG reload with the Captain clip).
-- CustomTimeDilation has neither problem: it names no asset, and def.MirrorTimeDilation pushes it
-- to clients over the VariantSignal channel.
--
-- The caller's def must set `MirrorTimeDilation = true`, or this is server-only again.
-- Mirrored CTD rubber-bands a moving body on client proxies (it scales movement too). A reload is
--   safe because Broadcast_ReloadWeapon sets LockedInPlaceMontage - the NPC is stationary the whole
--   window, PROVIDED nothing else orders it to move. A scripted MoveToLocation pushed into that
--   window drags the body with no locomotion anim to play, i.e. a slide, at the dilated speed - so
--   a variant with its own footwork loop must sit the reload out (AnteNPCs/OrderBreacherHelpers). Don't use this for a montage that moves (dodge roll, leap, charge) - use
--   AVU.PlayMontageReplicated / AVU.DodgeRoll's `Rate` instead, which sends the rate as a multicast
--   parameter so both ends run the same timeline and root motion agrees.
--
-- MULTIPLIES the actor's current dilation rather than replacing it, so a baseline def.TimeDilation
-- (or a boss's per-phase one) survives a reload, and the restore puts back that same baseline.
--
-- THE RESTORE IS THE HARD PART: there is no "reload ended" hook. We poll `LockedInPlaceMontage`,
-- which Broadcast_ReloadWeapon sets true and its own completion clears. Two phases, both needed:
-- our dispatch is a PRE hook, so at call time the flag is still false, and we must wait for it to
-- go true FIRST or the poll restores instantly and does nothing.
--   * Both waits are capped, so a body that dies / streams out / never latches still restores.
--   * Re-entrant calls are refused (one reload at a time), so the stashed baseline can't be
--     overwritten with an already-dilated value.
-- =======================================================================
local reloadDil = {}   -- ActorKey -> baseline CustomTimeDilation while a reload is retimed

local RELOAD_POLL_MS   = 100
local RELOAD_ARM_MS    = 1000    -- max wait for LockedInPlaceMontage to latch true
local RELOAD_MAX_MS    = 8000    -- hard stop: restore even if the flag never clears

function AVU.ReloadDilation(actor, mult)
    if Utils.IsActorInvalid(actor) or not mult or mult <= 0 then return false end
    local key = Utils.ActorKey(actor)
    if not key or reloadDil[key] then return false end   -- already retiming this reload

    local base = 1
    pcall(function() base = tonumber(actor.CustomTimeDilation) or 1 end)
    if base <= 0 then base = 1 end
    reloadDil[key] = base

    AVU.SetTimeDilation(actor, base * mult)

    local function restore()
        if reloadDil[key] == nil then return end
        local b = reloadDil[key]
        reloadDil[key] = nil
        if Utils.IsActorValid(actor) then AVU.SetTimeDilation(actor, b) end
    end

    -- Phase 1: wait for the native body to latch the lock. Phase 2: wait for it to clear.
    local elapsed, armed = 0, false
    local function poll()
        if reloadDil[key] == nil then return end          -- someone already restored
        if Utils.IsActorInvalid(actor) or actor.IsDead then return restore() end

        local locked = false
        pcall(function() locked = actor.LockedInPlaceMontage == true end)

        if locked then
            armed = true
        elseif armed or elapsed >= RELOAD_ARM_MS then
            return restore()                               -- reload finished, or never started
        end

        elapsed = elapsed + RELOAD_POLL_MS
        if elapsed >= RELOAD_MAX_MS then return restore() end
        Utils.QueueWork(poll, RELOAD_POLL_MS)
    end
    Utils.QueueWork(poll, RELOAD_POLL_MS)
    return true
end


-- Drop a dead NPC's reload stash. Called from the shared death path - the book is keyed by a
-- STRING, which never collects on its own.
function AVU.ClearReloadDilation(key)
    if key then reloadDil[key] = nil end
end



-- =======================================================================
-- DisableAbility - park an NPC ability: a huge cooldown on the field PLUS the native
-- SetAbilityOnCooldown, which re-reads that field for its duration - so every later re-cooldown the
-- NPC does for itself is long too.
--
-- WHAT EACH SLOT DOES IS PER-BASE-CLASS, and each AnteNPCs/*.lua opens with an ABILITY MAP for its
-- bases - read that before passing an index. What holds for EVERY NPC:
--   * CombatAbility1/2/3's base bodies are EMPTY stubs. A slot only does something if the NPC's own
--     class overrides it, and most override none - so this is often a harmless no-op.
--   * Slot selection is NOT in the pawn: the BT task carries an Ability enum pin per node. The
--     pawn's own Request_CombatAbility() is hardcoded to slot 1 and can never fire 2 or 3.
--   * Slot 0 (Idle) runs through the CONTROLLER instead, and several NPCs implement it there.
--   * A non-default Cooldown_* value does NOT prove the slot exists (NPC_Mage sets all four and
--     implements none).
--   * Many signature moves are NOT slots at all - the pest leap, the zombie/robot grab, the
--     Symphonist mirage, the Order rifle burst all ride the melee/ranged/damage channels instead.
-- =======================================================================

function AVU.DisableAbility(actor, index)
    if Utils.IsActorInvalid(actor) then return end
    index = index or 1
    local field = (index == 0) and "Cooldown_IdleAbility"
                               or ("Cooldown_CombatAbility" .. index)
    pcall(function() actor[field] = 3600 end)
    pcall(function() actor:SetAbilityOnCooldown(index, false, 3600) end)
end


-- =======================================================================
-- Suppress an NPC's ability to throw grenades
-- =======================================================================

function AVU.DisableGrenades(actor)
    AVU.DisableAbility(actor, 1)
end


-- =======================================================================
-- [AUTHORITY] No downed (DBNO) state: a killing blow kills. Call from Stats.
--   * The character parent's CanEnterDBNO returns the HasDBNOState member, which NPC_Base copies
--     from NPCData at init - both are cleared, so a re-init can't hand it back.
--   * Only the player and NPC_Skink_Basic override CanEnterDBNO, so it holds for any other NPC.
-- =======================================================================

function AVU.NoDBNO(actor)
    if Utils.IsActorInvalid(actor) then return end
    pcall(function() actor.HasDBNOState = false end)
    pcall(function() actor.NPCData[SCHEMA.NPC.HasDBNOState] = false end)
end


-- =======================================================================
-- Suppress an NPC's melee attack by setting melee on cooldown
--   * Each melee attempt clears this, so we need to call this periodically (~150ms)
--   * IT DOES NOTHING ON SOME TREES. MeleeAttack_OnCooldown is read by TryMeleeAttackCheck, and a
--     tree whose melee task is BTT_DoMeleeAttack calls Server_DoMeleeAttack DIRECTLY and never
--     passes that gate (the Flask Rat and the Hive Sow both learned this the expensive way). Check
--     the tree's melee task before reaching for this; where it is dead, the lever is usually a
--     blackboard value the branch's decorator reads.
-- =======================================================================

function AVU.SuppressMelee(actor, durationMs)
    if Utils.IsActorInvalid(actor) then return end
    if not durationMs then
        pcall(function() actor.MeleeAttack_OnCooldown = true end)
        return
    end
    for ms = 0, durationMs, 150 do
        Utils.QueueWork(function()
            if Utils.IsActorValid(actor) then pcall(function() actor.MeleeAttack_OnCooldown = true end) end
        end, ms)
    end
end


-- =======================================================================
-- Animation montage helpers (AUTHORITY-side gameplay nudges). GetAnimInstance()
-- + ASSETS.GetIfValid are not free - use sparingly (a tick gate, an event).
-- =======================================================================

-- Start a montage on the actor (animClassPath = the montage asset path).

function AVU.PlayAnimation(actor, animClassPath, playRate)
    if Utils.IsActorInvalid(actor) then return end
    local mesh = Utils.GetValidMesh(actor)
    if not mesh then return end
    local anim = mesh:GetAnimInstance()
    if IsNotValid(anim) then return end
    local animClass = ASSETS.GetIfValid(animClassPath)
    if IsNotValid(animClass) then return end
    pcall(function() anim:Montage_Play(animClass, playRate or 1, 0, 0, true) end)
end

-- Change a playing montage's rate (e.g. speed up a windup). No-op if not playing.

function AVU.SpeedUpAnimation(actor, animClassPath, rate)
    if Utils.IsActorInvalid(actor) then return end
    local mesh = Utils.GetValidMesh(actor)
    if not mesh then return end
    local anim = mesh:GetAnimInstance()
    if IsNotValid(anim) then return end
    local animClass = ASSETS.GetIfValid(animClassPath)
    if IsNotValid(animClass) then return end
    pcall(function()
        if anim:Montage_IsPlaying(animClass) then anim:Montage_SetPlayRate(animClass, rate) end
    end)
end

-- Change a montage's play-rate, re-applied a few times so it lands once the montage has actually
-- STARTED playing (it usually isn't playing yet on the first frame - e.g. a throw/reload notify
-- fires partway in).
--   * delays = ms offsets to retry at (default {0, 80, 160}).
--   * The grenade/reload spawn happens via an AnimNotify, so scaling the montage makes the whole
--     action snappier without dropping the notify.
-- [UNUSED] no live callers - every reload moved to AVU.ReloadDilation. Kept as
-- API because it is still the ONLY way to retime a montage the GAME started. Two costs to accept
-- before using it: the rate is a LOCAL AnimInstance write (our hooks are authority-only, so clients
-- keep playing the full-length clip), and it matches BY PATH, so it silently no-ops on any base
-- whose montage differs - which is easy to get wrong across AltBases.

function AVU.ModAnimationSpeed(actor, animPath, rate, delays)
    delays = delays or { 0, 80, 160 }
    for _, ms in ipairs(delays) do
        Utils.QueueWork(function() AVU.SpeedUpAnimation(actor, animPath, rate) end, ms)
    end
end

-- SKIP INTO a montage that is already playing: jump it to `seconds` and leave it running there -
-- how you get the part you actually want out of a long flavour montage inside a short window.
--   * RETRIED like ModAnimationSpeed and for the same reason: on the frame a montage starts it
--     usually isn't "playing" yet, and SetPosition on an inactive montage is a silent no-op. The
--     IsPlaying gate means a landed skip and a late retry can't fight.
--   * LOCAL, like every AnimInstance write: the multicast that STARTED the montage reached clients,
--     this correction does not, so a joined client watches the skipped intro. Fine for flavour;
--     never build a gameplay window (a windup, a telegraph) on it.

function AVU.SkipIntoAnimation(actor, animPath, seconds, delays)
    delays = delays or { 0, 80, 160 }
    for _, ms in ipairs(delays) do
        Utils.QueueWork(function()
            if Utils.IsActorInvalid(actor) then return end
            local mesh = Utils.GetValidMesh(actor)
            if not mesh then return end
            local anim = mesh:GetAnimInstance()
            if IsNotValid(anim) then return end
            local animClass = ASSETS.GetIfValid(animPath)
            if IsNotValid(animClass) then return end
            pcall(function()
                if not anim:Montage_IsPlaying(animClass) then return end
                if anim:Montage_GetPosition(animClass) >= seconds then return end   -- already past
                anim:Montage_SetPosition(animClass, seconds)
            end)
        end, ms)
    end
end

-- Break out of the actor's current montage (animClass optional; nil = active one).

function AVU.CancelAnim(actor, animClass)
    if Utils.IsActorInvalid(actor) then return end
    local mesh = Utils.GetValidMesh(actor)
    if not mesh then return end
    local anim = mesh:GetAnimInstance()
    if IsNotValid(anim) then return end
    pcall(function() anim:Montage_Stop(0.1, animClass) end)
end

-- [AUTHORITY] Cut a playing montage short. Only the authority's own AnimInstance stop lands: the
-- multicast counterpart (Broadcast_MontageStop) takes a SOFT montage reference, and Lua cannot
-- build a non-blank one on this UE4SS (see Utils.BlankSoftRef) - so clients watch the clip out.
--   * The local stop still ends the BUSY window here: the montage's OnInterrupted/OnBlendOut is
--     what clears LockedInPlaceMontage.
-- Returns false: nothing was sent. `blendOut` is kept for the callers; the local stop blends at 0.1.

function AVU.StopMontageReplicated(actor, animPath, blendOut)
    if Utils.IsActorInvalid(actor) then return false end
    AVU.CancelAnim(actor, ASSETS.GetIfValid(animPath))
    return false
end

-- [AUTHORITY] Play a montage on ALL machines at a given rate. Unlike AVU.SpeedUpAnimation (whose
-- rate change is SERVER-LOCAL), PlayThirdPersonMontage is a reliable multicast carrying the montage
-- and the PlayRate, so a sped-up anim is visible on clients too.
--   * The montage must be RESIDENT (this is non-loading); returns false if it isn't, so callers can
--     fall back to a native play.
--   * Any AnimNotify baked into the montage STILL fires, so this can REPLACE a native throw call
--     rather than layer on top of one (which would double-fire the notify).

function AVU.PlayMontageReplicated(actor, animPath, rate, lockInPlace)
    if Utils.IsActorInvalid(actor) then return false end
    local anim = ASSETS.GetIfValid(animPath)
    if IsNotValid(anim) then return false end
    -- Pinned on first use: a montage played once is played again, and unpinned it costs a probe per
    -- play and a reload whenever a GC lands between plays (the Chieftain throw, 5x in a server soak).
    if not ASSETS.Pinned[animPath] then ASSETS.PinSoon({ animPath }) end
    local ok = pcall(function()
        -- (LockInPlace, Montage, HideHeldItem, PlayRate, SecondaryUse)
        actor:PlayThirdPersonMontage(lockInPlace ~= false, anim, false, rate or 1, false)
    end)
    return ok
end


-- =======================================================================
-- PortalArrival - "it stepped out of a rift", for ONE body, as a def.OnReady one-liner: the yellow
-- teleporter-pad doorway plus the game's own step-out montage on the arriving NPC.
--
-- IT TAKES TWO CALLS IN TWO PIPELINE STEPS, and both halves matter:
--     Stats   -> AVU.HideForArrival(actor)   the body goes invisible
--     OnReady -> AVU.PortalArrival(actor)    doorway opens; EmergeMs later the body reappears
--                                            mid-montage, with the step-out cue
--   * The hide CANNOT live in OnReady: STATS is the first pipeline step and OnReady the last, and
--     everything between them is long enough to watch the rat stand on the floor for ~0.5s.
--   * REVEALING ON THE MONTAGE'S FRAME hides the other artefact - its first frame lifts the body
--     ~20cm, so a body already on screen visibly POPS upward. Appear already in that pose instead.
--
-- WHY NOT AVU.SpawnPortalFX: that is a one-shot BURST. This doorway LOOPS, and a BroadcastFX
-- multicast can never CLOSE a looping system (CLAUDE.md 4) - so it rides the client-FX channel,
-- whose per-send lifetime is what shuts it.
-- CALL IT FROM OnReady, not Stats: OnReady sits behind the pipeline's entrance gate, which holds
-- until a base's own spawn-in has finished. Fired earlier, the montage is just eaten by it.
-- The montage plays UNLOCKED - `true` would latch LockedInPlaceMontage, which nothing here clears,
-- and on the FlameRat family that latch is the documented wedge.
-- Both halves are best-effort, but *** the montage must be in the variant's def.Assets *** (the
-- authority resolves it non-loading) or the arrival is portal-only.
--
-- opts (all optional):
--   Key       doorway ClientFX key           (default "PORTAL_YELLOW")
--   Seconds   how long the doorway hangs     (default 3)
--   Yaw       doorway facing, degrees        (default: the actor's own)
--   EmergeMs  doorway -> body                (default 400)
--   Anim      montage path                   (default ENUMS.Anims.HASTATRIA_EXIT_PORTAL)
--   Rate      montage play rate              (default 0.5 - authored for a one-off narrative
--                                             entrance, it reads as a hurry at 1.0)
--   SoundKey  step-out cue ClientFX key      (default "PORTAL_YELLOW_EMERGE")
--   NoAnim / NoPortal / NoSound   drop any part      KeepSpawnFX  leave the native spawn-in alone
-- =======================================================================
local ARRIVAL_PORTAL_KEY  = "PORTAL_YELLOW"
local ARRIVAL_SOUND_KEY   = "PORTAL_YELLOW_EMERGE"
local ARRIVAL_PORTAL_SECS = 3
-- Doorway -> body. Roughly the beat that was already there by accident (the Niagara's own ramp),
-- now deliberate. It must stay comfortably under ARRIVAL_PORTAL_SECS or the body emerges from a
-- door that has already closed.
local ARRIVAL_EMERGE_MS = 400
-- Half speed. The montage was authored for a narrative NPC's one-off entrance and reads as a hurry
-- at 1.0. PlayThirdPersonMontage is a multicast carrying the rate, so clients see the same pace
-- (unlike Montage_SetPlayRate, which is server-local).
local ARRIVAL_ANIM_RATE = 0.5
-- Unconditional un-hide backstop. EVERY pipeline step can bail (stepActorGone, when a sublevel
-- streams out mid-mutation), so a READY that never runs would otherwise leave a permanently
-- INVISIBLE but fully alive and hostile NPC. Reveal is idempotent, so this firing after the real
-- reveal costs nothing.
local ARRIVAL_HIDE_BACKSTOP_MS = 4000

-- bHidden REPLICATES once marked dirty, so every machine hides and reveals the same body.

local function setArrivalHidden(actor, hidden)
    if Utils.IsActorInvalid(actor) then return end
    pcall(function()
        actor:SetActorHiddenInGame(hidden)
        Utils.MarkReplicatedDirty(actor, "bHidden")
    end)
end

-- [AUTHORITY] Half one of the pair - CALL FROM def.Stats. See the cadence note above.

function AVU.HideForArrival(actor)
    if not Utils.IsAuthority() or Utils.IsActorInvalid(actor) then return end
    setArrivalHidden(actor, true)
    Utils.QueueWork(function() setArrivalHidden(actor, false) end, ARRIVAL_HIDE_BACKSTOP_MS)
end

function AVU.PortalArrival(actor, opts)
    if not Utils.IsAuthority() or Utils.IsActorInvalid(actor) then return end
    opts = opts or {}

    -- Cut any native spawn-in still running, so the arrival is OUR portal and nothing else. A
    -- post-spawn call can only END it (SkipSpawnFX is read once in BeginPlay), which is all that is
    -- available for a body a GAME spawner put in the world - we never own that spawn call.
    -- Currently a no-op on all three rat bases (NPC_Sapper overrides the Grunt's SpawnFXDuration 3.5
    -- rappel down to 0, NPC_LabRat_Garage inherits 0), so it is insurance, not the mechanism.
    if not opts.KeepSpawnFX then AVU.SkipSpawnFX(actor) end

    local yaw
    pcall(function() yaw = actor:K2_GetActorRotation().Yaw end)
    yaw = opts.Yaw or yaw or 0

    if not opts.NoPortal then
        local key = opts.Key or ARRIVAL_PORTAL_KEY
        local loc
        pcall(function() loc = actor:K2_GetActorLocation() end)
        -- The doorway is a flat plane and vanishes edge-on, so it always gets a yaw (S4/PORTAL_DOOR).
        if loc then
            -- LOUD on a missing registry key. This is the failure a stale registry produces, and a
            -- new ClientFX entry needs a full RESTART - /reload does not re-run Enums. SendClientFX
            -- logs its own "unknown effect key", but not what asked for it.
            if not ENUMS.ClientFXIndex[key] then
                Utils.LogBad("PortalArrival - '" .. tostring(key) .. "' is not in the ClientFX"
                    .. " registry (a new entry needs a full restart, not /reload)")
            else
                -- Logged on the way IN, so an absent line means OnReady never reached us at all -
                -- a different fault from SendClientFX's own "-> N renderer(s)" line not appearing
                -- (which would mean the push itself found nobody).
                -- FLOOR every %d arg: world coords are doubles, and Lua 5.4's string.format
                -- THROWS on a fractional number for %d. Unfloored, this log line would take the
                -- whole arrival down with it (pcall'd by the pipeline -> "Pipeline failed: READY").
                Utils.LogDebug(string.format("PortalArrival - %s at %d,%d,%d yaw %d",
                    key, math.floor(loc.X or 0), math.floor(loc.Y or 0), math.floor(loc.Z or 0),
                    math.floor(yaw)), SETTINGS.DEBUG_CLIENT)
                AVU.SendClientFX(loc, key, opts.Seconds or ARRIVAL_PORTAL_SECS, yaw)
            end
        end
    end

    -- THE EMERGE BEAT - montage, reveal and cue on ONE clock, in that order. Nothing here can
    -- blocking-load (the montage is preloaded and PlayMontageReplicated is non-loading; the cue
    -- resolves on each RENDERER), so it is safe on the WorkQueue drain - S2.
    Utils.QueueWork(function()
        if Utils.IsActorInvalid(actor) then return end

        if not opts.NoAnim then
            -- PlayMontageReplicated no-ops SILENTLY on a non-resident montage (GetIfValid is
            -- non-loading), which is indistinguishable from a montage that played into a slot the
            -- AnimBP doesn't have - so say which one happened.
            local anim = opts.Anim or ENUMS.Anims.HASTATRIA_EXIT_PORTAL
            if not AVU.PlayMontageReplicated(actor, anim, opts.Rate or ARRIVAL_ANIM_RATE, false) then
                Utils.LogBad("PortalArrival - arrival montage not resident (add it to def.Assets): "
                    .. tostring(anim))
            end
        end

        -- AFTER the montage: the body should appear already in the step-out pose (see the header).
        setArrivalHidden(actor, false)

        if not opts.NoSound then
            local loc
            pcall(function() loc = actor:K2_GetActorLocation() end)
            if loc then AVU.SendClientFX(loc, opts.SoundKey or ARRIVAL_SOUND_KEY, 2, 0) end
        end
    end, opts.EmergeMs or ARRIVAL_EMERGE_MS)
end


-- =======================================================================
-- Death-time AreaEffect sweep - the stale-instigator crash killer.
-- Native AreaEffects (molotov patches, spore clouds, holy flasks) run a damage timer that calls
-- ProcessDamage with their INSTIGATOR every tick. If the caster dies and is later destroyed while
-- the patch still burns, the next tick passes a FREED instigator = access violation. AVU.SpawnCloud
-- covers OUR clouds; NATIVE-spawned ones (a molotov burn from a projectile impact) were not.
-- So on every authority death we note the actor and run ONE COALESCED sweep shortly after that
-- destroys the AreaEffects it instigated (destroying the effect cancels its timer). The coalescing
-- is what bounds the cost under mass-death stress: one scan per window, not per death.
-- =======================================================================
local aeDeadPending = {}       -- fullname set of recently-dead/departing casters
local aeSweepQueued = false
local aeLastSweep = 0          -- os.clock() of the last scan (burst throttle)
local AE_SWEEP_DELAY_MS = 400  -- coalesce window; the corpse is still valid this soon after
                               -- death, so the instigator match works
local AE_SWEEP_MIN_GAP_S = 15  -- bounds the FindAllOf cost to one scan per gap; notes carry over
                               -- in aeDeadPending so nothing is lost, and 15s is still half the
                               -- ~30-60s GC window the sweep has to beat. It is also the floor the
                               -- perf rule puts on any FindAllOf cadence - this scan measured 22ms
                               -- in a live fight, the most frequent whole-UObject walk we run, and
                               -- ANY death or stream-out arms it. See AnNotes/AnteSystems/AVUtils.md.

function AVU.NoteDeathForAreaSweep(actor)
    if not Utils.IsAuthority() then return end
    local fn
    pcall(function() fn = actor:GetFullName() end)
    if not fn then return end
    aeDeadPending[fn] = true
    if aeSweepQueued then return end
    aeSweepQueued = true

    -- Coalesce, but never scan more often than the min gap (EndPlay bursts).
    local wait = AE_SWEEP_DELAY_MS
    local gapLeftMs = (AE_SWEEP_MIN_GAP_S - (os.clock() - aeLastSweep)) * 1000
    if gapLeftMs > wait then wait = math.floor(gapLeftMs) end

    Utils.QueueWork(function()
        aeSweepQueued = false
        aeLastSweep = os.clock()
        local dead = aeDeadPending
        aeDeadPending = {}
        local n = 0
        for _, ae in ipairs(FindAllOf("AreaEffectBP_C") or {}) do
            if IsValid(ae) then
                local ifn
                pcall(function()
                    local inst = ae:GetInstigator()
                    if inst and IsValid(inst) then ifn = inst:GetFullName() end
                end)
                if ifn and dead[ifn] then
                    pcall(function() ae:K2_DestroyActor() end)
                    n = n + 1
                end
            end
        end
        if n > 0 then
            Utils.LogDebug("AreaSweep - destroyed " .. n .. " effect(s) of dead casters",
                SETTINGS.DEBUG_NPC_ACTIONS)
        end
    end, wait)
end


-- [AUTHORITY, pathing is server-side] Shrink a large NPC's NAV AGENT so the pathfinder routes it
-- through tight facility geometry (e.g. the Labs vault door) instead of refusing/stalling.
--   * This is the agent the PATHFINDER uses, NOT the collision capsule or the actor scale -
--     the hitbox/visual are unchanged (use BodyScale for those).
--   * Ported from EnemyAtTheGATE (Utils.ShrinkNavAgent), minus its actor-scale tweak (we drive
--     scale via BodyScale, mirrored to clients).

function AVU.ShrinkNavAgent(actor, radius, height)
    if Utils.IsActorInvalid(actor) then return end
    radius = radius or 45
    height = height or 180

    local move = actor.CharacterMovement
    if IsNotValid(move) then return end
    pcall(function()
        move.NavAgentProps.AgentRadius = radius
        move.NavAgentProps.AgentHeight = height
    end)
end


-- =======================================================================
-- PatternTime - the heartbeat for "scripted action every N ticks". Returns the pattern time
-- (0..period-1) on a step boundary, so a def.OnTick can drive an ability table:
--     local t = AVU.PatternTime(actor, totalTicks, 5, 350)
--     if t then dispatch(PATTERN[t]) end
--   * stepTicks = resolution (5 = every 0.5s at the 10Hz tick).
--   * combatOnly (default true): the clock starts when the actor ENTERS combat, so the sequence
--     always begins at t=0 each fight (nil while out of combat, which also resets it).
-- AUTHORITY only - it drives gameplay actions.
-- =======================================================================

function AVU.PatternTime(actor, totalTicks, stepTicks, period, combatOnly)
    if combatOnly == nil then combatOnly = true end
    if totalTicks % stepTicks ~= 0 then return nil end

    if not combatOnly then
        return totalTicks % period
    end

    if Utils.IsActorInvalid(actor) or not actor.CombatState then
        STATE.OnTickCombatStart[actor] = nil
        return nil
    end

    STATE.OnTickCombatStart[actor] = STATE.OnTickCombatStart[actor] or totalTicks
    return (totalTicks - STATE.OnTickCombatStart[actor]) % period
end


-- =======================================================================
-- Generic NPC / behavior helpers (moved out of AnteNPCs so any variant can
-- reuse them).
-- =======================================================================

-- [AUTHORITY] Add `dose` radiation. Radiation is a STAT, not a buff: the native modify clamps to
-- MaxRadiation and then applies the right debuff row itself at its thresholds.
--   * skipResist bypasses hazmat gear's reduction; leave it false so gear still protects.
--   * OFF-HOOK (EIGT, all roles) for the same reason as Utils.AddBuff: the debuff it applies
--     COLD-LOADS its FX/montage, and in-hook that blocking load deadlocks the game thread
--     (CLAUDE.md 2 - intermittent, by whether the asset happened to be resident). The actor is
--     re-resolved BY PATH inside the hop; a wrapper captured across it can be freed.
--   * IT ONLY REALLY BITES PLAYERS. NPCs have CanReceiveRadiation = false and no damage timer, so
--     an NPC's stat rises but never ticks - and the debuff it lands has no expiration, so it sticks
--     forever. Gate callers to players; to actually HURT an NPC, deal Radiation-typed damage.

function AVU.AddRadiation(actor, dose, skipResist)
    if Utils.IsActorInvalid(actor) then return end
    local path = Utils.ObjectPath(actor)
    if not path then return end
    ExecuteInGameThread(function()
        local a = Utils.ResolveByPath(path)
        if IsNotValid(a) then return end
        pcall(function() a:ModifyStat_Radiation(dose, skipResist or false) end)
    end)
end


-- =======================================================================
-- Gameplay-tag container editing - the ONLY reliable UE4SS route.
-- UE4SS cannot write a Lua value back into a live struct, so both "obvious" ways SILENTLY FAIL:
-- replacing the whole container doesn't persist, and AddGameplayTag() rejects the Lua-table arg.
-- What WORKS is editing the container's own GameplayTags ARRAY in place - appending a
-- { TagName = FName } struct at the next index.
--   * This is the ACTOR's own container, which is the one HasTag(GameplayTags, ...) reads in the
--     BPs (the Symphonist fog-despawn check, the NoBleed check, ...). NOT the buff component's
--     aggregate, so a tag added here is invisible to the buff-tag readers - which keeps side
--     effects minimal.
--   * AUTHORITY: server-side gameplay reads it, and it is not marked replicated.
-- See [[af-gameplaytag-container-editing]].
-- =======================================================================

function AVU.AddGameplayTag(actor, tagName)
    if Utils.IsActorInvalid(actor) or not tagName then return false end
    local added = false
    pcall(function()
        local container = actor.GameplayTags
        if not container then return end
        local tags = container.GameplayTags
        if not tags then return end
        local n = tags:GetArrayNum()
        for i = 1, n do                       -- dedup: don't stack the same tag
            local ftag = tags[i]
            if ftag and ftag.TagName and ftag.TagName:ToString() == tagName then
                added = true
                return
            end
        end
        tags[n + 1] = { TagName = FName(tagName) }   -- in-place grow (the working idiom)
        added = true
    end)
    return added
end

-- True if the actor's own GameplayTags container carries `tagName` (in-place read).
-- Read-side twin of AddGameplayTag. The match is case-folded because the compared string comes out
-- of an FName, whose display spelling is set by whoever registered it first (CLAUDE.md 1).

function AVU.HasGameplayTag(actor, tagName)
    if Utils.IsActorInvalid(actor) or not tagName then return false end
    local want = tagName:lower()
    local has = false
    pcall(function()
        local tags = actor.GameplayTags and actor.GameplayTags.GameplayTags
        if not tags then return end
        for i = 1, tags:GetArrayNum() do
            local ftag = tags[i]
            if ftag and ftag.TagName and ftag.TagName:ToString():lower() == want then
                has = true
                return
            end
        end
    end)
    return has
end


-- =======================================================================
-- SetBtCooldownTag - reach into a BEHAVIOR TREE's own cooldown map, per actor.
--
-- WHY YOU WILL NEED THIS: `BTDecorator_TagCooldown` gates a whole branch and `BTTask_SetTagCooldown`
-- stamps it, and BOTH live purely in the BehaviorTreeComponent's runtime CooldownTagsMap. No pawn
-- property touches it - so when a tree makes an attack branch WAIT, this is very often where, and
-- `MeleeAttackPlayRate`, `*_OnCooldown`, `Cooldown_CombatAbility*` and CustomTimeDilation all go
-- nowhere near it. (Live case: the shield soldiers' MOBILE melee ends in
-- `SetTagCooldown(AI.Cooldown.Ability1, 15s)` inside BT_Attack_Soldier_Shield.)
--
-- AI.Cooldown.Ability1 is NOT the pawn's `Cooldown_CombatAbility1` and has
-- nothing to do with `SetAbilityOnCooldown(1)` - same word, two unrelated systems. Writing the pawn
-- field does not touch the tree's map, which is exactly how the Rook's 15s hid for so long.
--
--   * PER ACTOR - the map belongs to the controller's component, so this changes ONE body and
--     never the shared BT asset (whose node duration is a template every user of that tree reads).
--   * `AddCooldownTagDuration(tag, secs, false)` OVERWRITES the end time - the bAdd flag exists
--     because overwrite is the default - so `seconds = 0` means "expired now" and the decorator
--     re-opens on its next evaluation.
--   * The FGameplayTag goes in as `{ TagName = FName(...) }`, the by-value struct shape the tag
--     library already accepts ([[af-gameplaytag-container-editing]]).
-- AUTHORITY: behavior trees only run on the server.
-- =======================================================================

function AVU.SetBtCooldownTag(actor, tagName, seconds)
    if Utils.IsActorInvalid(actor) or not tagName then return false end
    local ok = false
    pcall(function()
        local c = actor.NPC_Controller
        if IsNotValid(c) then c = actor:GetController() end
        if IsNotValid(c) then return end
        local brain = c.BrainComponent
        if IsNotValid(brain) then return end
        brain:AddCooldownTagDuration({ TagName = FName(tagName) }, seconds or 0, false)
        ok = true
    end)
    return ok
end


-- =======================================================================
-- SPATIAL / VECTOR - line-of-sight, character launches, and nearby-actor queries.
-- Event-path math (attacks/abilities), never per-tick. Shared by several variants
-- (Magus beams, Constriction lasso, Trident net, Telepest).
-- =======================================================================

-- True if a WALL blocks the straight path from `fromLoc` to `toLoc` (a Visibility line trace).
--   * `ignore` = actors to skip (default {actor}); pass {actor, target} to also ignore the
--     victim, so only real cover blocks.
--   * FAIL-OPEN: any trace error returns false (not blocked) so an attack never silently
--     disables itself.
--   * `channel` defaults to ENUMS.Trace.VISIBILITY, the game's own sight channel. For a long
--     time this was the literal 3, which is the MELEE sweep channel (see ENUMS.Trace): some cave
--     and wall meshes ignore it, so beams and sight checks went straight through those walls.
--   * Shared by the Magus beams, the Trident net, and the Telepest's spot-picker.

function AVU.IsPathBlocked(actor, fromLoc, toLoc, ignore, channel)
    local blocked = false
    pcall(function()
        local ksl = ASSETS.GetIfValid("/Script/Engine.Default__KismetSystemLibrary")
        if not ksl or not fromLoc or not toLoc then return end
        local col = { R = 0, G = 0, B = 0, A = 0 }
        blocked = ksl:LineTraceSingle(actor, fromLoc, toLoc, channel or ENUMS.Trace.VISIBILITY, false,
            ignore or { actor }, 0, {}, true, col, col, 0.0)
    end)
    return blocked
end

-- Can a body stand at `pt` (a GetSpawnPoint / ProjectToNav result: floor + zClearance) without
-- being inside the level? Two Visibility traces:
--   * UP, from knee to head height over the floor under `pt` - a nav point under sloped or
--     overhanging geometry (cave walls, rock, stair undersides) has solid mesh at body height even
--     though the floor below is walkable. That is how a summon ends up inside a cave wall.
--   * `opts.From` (the summoner's location) -> `pt` at chest height: a spot the summoner cannot
--     see is behind or inside a wall. Leave it nil for a spawn allowed out of the caller's sight.
-- Fail-open like IsPathBlocked, so a trace error never disables a spawn.
function AVU.IsSpawnSpotClear(actor, pt, opts)
    if not pt then return false end
    opts = opts or {}
    local floorZ = pt.Z - (opts.ZClearance or 100)
    local ignore = opts.Ignore or { actor }
    if AVU.IsPathBlocked(actor, FVector(pt.X, pt.Y, floorZ + 45), FVector(pt.X, pt.Y, floorZ + 175), ignore) then
        return false
    end
    local from = opts.From
    if from and AVU.IsPathBlocked(actor, FVector(from.X, from.Y, from.Z + (opts.EyeZ or 80)),
            FVector(pt.X, pt.Y, floorZ + 80), ignore) then
        return false
    end
    return true
end

-- Utils.GetSpawnPoint, re-rolled until IsSpawnSpotClear passes; nil once `tries` run out.
--   * `opts` go to IsSpawnSpotClear (`From` = the summoner's location for the sight leg).
--   * nil means "nowhere clear this call": skip the spawn rather than fall back to a raw point -
--     the raw point is exactly the one that lands a body in the wall.
function AVU.PickClearSpawnPoint(actor, origin, radius, minRadius, tries, opts)
    for _ = 1, tries or 6 do
        local pt = Utils.GetSpawnPoint(origin, radius, minRadius, 8)
        if pt and AVU.IsSpawnSpotClear(actor, pt, opts) then return pt end
    end
    return nil
end

-- Dev-spawn spot `dist` (500) straight ahead of `pawn`'s facing: the navmesh under that mark, in
-- the pawn's sight and clear of walls. A mark in a wall steps back toward the pawn; none of them
-- usable = a random reachable point within `fallbackRadius` (800) of the mark. nil if the pawn is gone.
function AVU.SpawnPointAhead(pawn, dist, fallbackRadius)
    if Utils.IsActorInvalid(pawn) then return nil end
    local ok, loc = pcall(function() return pawn:K2_GetActorLocation() end)
    if not ok or not loc then return nil end
    loc = FVector(loc.X, loc.Y, loc.Z)
    local fwd = Utils.HorizontalForward(pawn) or FVector(1, 0, 0)
    dist = dist or 500

    for _, k in ipairs({ 1.0, 0.7, 0.4 }) do
        local mark = FVector(loc.X + fwd.X * dist * k, loc.Y + fwd.Y * dist * k, loc.Z)
        local pt = Utils.ProjectToNav(mark, 250)
        if pt and AVU.IsSpawnSpotClear(pawn, pt, { From = loc }) then return pt end
    end
    return Utils.GetSpawnPoint(FVector(loc.X + fwd.X * dist, loc.Y + fwd.Y * dist, loc.Z),
        fallbackRadius or 800)
end


-- [AUTHORITY] Fire one "psychic beam" at world point `loc`: the caster's native beam VISUAL (a
-- multicast, so every client draws it) plus radial damage at the point. THE crash-safe NPC beam.
--   * Deliberately NOT FireRanged_HitscanBullet - its renderer-side impact FX blocking-load on
--     first use and, nested in the tick-hook drain, deadlock a renderer. (They no-op on a dedicated
--     server, which is why that was always fine.)
--   * The beam broadcast itself only FindObjects its Niagara, so it can't cold-load and stays
--     inline - the visual lands on the locked point NOW.
--   * THE DAMAGE HOPS OFF-HOOK (EIGT). "ApplyRadialDamage loads nothing" is true of the CALL and
--     misleading about the PIPELINE: it runs every victim's damage chain synchronously, and a
--     victim it KILLS runs its whole death sequence inline, cold-loading death FX and loot. Nested
--     in the drain that is the CLAUDE.md 2 deadlock. Costs one EIGT flush of latency, invisible at
--     beam speed; the caster crosses through Utils.CarryActor.
--   * DAMAGE ALWAYS RESPECTS an eye->point wall trace, because ApplyRadialDamage's own LoS starts at
--     the impact point NEXT TO the victim and never sees a wall between caster and victim.
-- opts: Dmg + Radius (required), EyeZ (80 - trace/beam origin above the root, ~muzzle),
--       Channel (3 = Visibility), Crumb (freeze-trace breadcrumb prefix),
--       AlwaysShow - draw the visual even when blocked (a warmup spray pointing into a wall should
--       still be seen). Damage is gated either way.

function AVU.CastPsychicBeam(actor, target, loc, opts)
    if Utils.IsActorInvalid(actor) or actor.IsDead then return end
    opts = opts or {}
    local crumb = opts.Crumb or "psyBeam"

    -- Breadcrumbs per NATIVE step, not just per call: if this wedges, the freeze trace names
    -- whether the TRACE, the BROADCAST or the RADIAL DAMAGE was the one that blocked.
    STATE.LastWork = crumb .. ":trace"
    STATE.LastWorkDone = false
    local o = actor:K2_GetActorLocation()
    local start = o and FVector(o.X, o.Y, o.Z + (opts.EyeZ or 80))
    local blocked = start and AVU.IsPathBlocked(actor, start, loc, { actor, target }, opts.Channel or ENUMS.Trace.VISIBILITY)

    if opts.AlwaysShow or not blocked then
        STATE.LastWork = crumb .. ":broadcast"
        pcall(function() actor:Broadcast_BeamAttack(loc) end)
    end
    STATE.LastWorkDone = true

    if blocked then return end

    -- Damage off-hook (see header). loc is a Lua-side FVector, plain values.
    local getA = Utils.CarryActor(actor)
    local dmg, radius = opts.Dmg, opts.Radius
    ExecuteInGameThread(function()
        STATE.LastWork = crumb .. ":radial"
        STATE.LastWorkDone = false
        pcall(function()
            local a = getA()
            if not a or a.IsDead then return end
            local gs = ASSETS.GetIfValid("/Script/Engine.Default__GameplayStatics")
            if not gs then return end
            local dmgType = ASSETS.GetIfValid(ENUMS.DamageType.PsychicMonk)  -- nil = untyped this shot (best-effort)
            gs:ApplyRadialDamage(a, dmg, loc, radius, dmgType,
                { a }, a, a.NPC_Controller, false, 0)
        end)
        STATE.LastWorkDone = true
    end)
end


-- [AUTHORITY] Release the soldier BT's ranged task after an OVERRIDE fire (a variant running
-- OverrideSoldierFireLogic = true).
--   * The native burst end does the counter, the flag, the CombatReset broadcast AND the
--     hit/miss verdict - with the override on, NOBODY does, and the BT ranged task waits on
--     CombatReset forever ("fires once then freezes in the aim pose").
--     EndAbility_DoCombatReset(true) is the native release valve.
--   * THE VERDICT IS THE OTHER HALF, and it is why a suppressed shooter reads as a coward.
--     Grunt_FireBurst ends in CheckIfHittingTarget(), the only thing that ever clears the
--     FailedHits counter, and ToggleCombatStateFX slams that counter to 99 on every combat-state
--     flip. So an override-fire body enters every fight already past BT_Attack_Soldier's
--     "FailedHits >= 3 -> take cover, at ANY range" branch and can never earn its way back out.
--     We score the burst a hit, because the game cannot score it at all: these rounds are not
--     hitscans, so a miss verdict is not a judgement, it is an absence of one.
--   * Callers usually QueueWork this a beat after the shot so the pose stays planted through it.
--   * OFF-HOOK (EIGT, the actor through Utils.CarryActor), NOT inline in the drain: the reset runs
--     the controller's DecisionTick, which can SYNCHRONOUSLY start whatever the base picks next -
--     whose first-use montage/FX cold-loads. Nested in the drain that is the CLAUDE.md 2 deadlock,
--     and it wedged exactly there once already.

function AVU.ReleaseSoldierBT(actor)
    if Utils.IsActorInvalid(actor) or actor.IsDead then return end
    local path = Utils.ObjectPath(actor)
    if not path then return end
    local getA = Utils.CarryActor(actor)
    ExecuteInGameThread(function()
        -- Freeze breadcrumb (DEBUG_FREEZE_TRACE watchdog): if the decision path wedges again,
        -- the watchdog names the actor instead of pointing at the caller's queue line.
        STATE.LastWork = "EIGT releaseBT " .. path
        STATE.LastWorkDone = false
        local a = getA()
        if a then
            pcall(function()
                if a.IsDead then return end
                a.PerformingRangedBurst = false
                local c = a:GetController()
                if IsValid(c) then c:IncrementBurstCounter() end
                AVU.SetBlackboardInt(a, "FailedHits", 0)   -- before the reset: it re-runs DecisionTick
                a:EndAbility_DoCombatReset(true)
            end)
        end
        STATE.LastWorkDone = true
    end)
end


-- =======================================================================
-- MeleeReleaseTicks - "how long after a swing STARTS may I fire the release valve myself".
--
-- THE PROBLEM: the melee BT task never calls FinishExecute itself - it waits on the pawn's
-- CombatReset delegate, and the only thing that fires it is a delay sized from the montage's RAW
-- length. MeleeAttackPlayRate only reaches the montage proxy, so a 1.5x swing finishes visually in
-- 2/3 the time and the NPC stands there for the rest: raising the rate ALONE can never raise the
-- attack RATE ([[af-npc-melee-hit-detection]]).
--
-- THE FIX is to fire that same valve (AVU.ReleaseSoldierBT) once the sped-up montage has really
-- ended, and this owns the only fiddly part - the measurement.
--   * Measured ONCE per session per montage, and only the NUMBER is kept; caching the asset is the
--     CLAUDE.md 3 use-after-free family.
--   * Returns nil until the measurement lands (one non-blocking load, safe from a tick drain). nil
--     just means "don't release early yet" - the native delay still ends the swing.
--   * opts.Offset = the base's GetMeleeTimeOffset (subtracted from the native wait, so our window
--     must subtract it too). Flat 0 except NPC_Monster_Peccary's 0.2.
--   * opts.Fallback = length to assume if the measure fails. opts.Pad = ticks of slack (default 2).
-- Drive it from OnTick, NOT a QueueWork inside OnMeleeSwing: that hook hands out a FRESH wrapper
-- and holding one across a ~1s delay is the stale-wrapper case.
-- =======================================================================
local meleeMontageLen = {}      -- montage path -> measured play length (SECONDS, never the asset)
local meleeMontageBusy = {}     -- path -> a measurement is already in flight

function AVU.MeleeReleaseTicks(montagePath, rate, opts)
    if not montagePath then return nil end
    opts = opts or {}

    local len = meleeMontageLen[montagePath]
    if not len then
        if not meleeMontageBusy[montagePath] then
            meleeMontageBusy[montagePath] = true
            ASSETS.LoadAsync({ montagePath }, function(results)
                local m = results and results[montagePath]
                local measured
                if IsValid(m) then pcall(function() measured = m:GetPlayLength() end) end
                if not measured or measured <= 0 then measured = opts.Fallback or 1.2 end
                meleeMontageLen[montagePath] = measured
                LogDebug(string.format("MeleeReleaseTicks - %s measured %.2fs", montagePath, measured),
                    SETTINGS.DEBUG_NPC_ACTIONS)
            end)
        end
        return nil
    end

    local window = len / math.max(0.01, rate or 1) - (opts.Offset or 0)
    return math.max(1, math.ceil(window * 10) + (opts.Pad or 2))
end


-- =======================================================================
-- LAUNCHING A CHARACTER along the line between it and pivotLoc. `towards` pulls toward the pivot
-- instead of shoving away; horiz/up are the impulse legs.
--
-- THERE ARE TWO PRIMITIVES AND THE GAME USES BOTH ON PURPOSE:
--   * SELF-LAUNCH (an NPC leaping or rocket-jumping, or tossing a summon WE spawned) is plain
--     LaunchCharacter with BOTH axes overridden - we want exactly the arc we computed.
--   * KNOCKBACK ONTO SOMEONE ELSE is ScaledLaunchCharacter, which is literally what the game's own
--     LaunchHitTarget does. "Scaled" applies the VICTIM's knockback scaling, and it is the
--     primitive that moves a CLIENT-CONTROLLED PLAYER from the server; bXYOverride = false so the
--     shove ADDS to their motion rather than replacing it.
-- Picking the wrong one is not cosmetic: a plain LaunchCharacter aimed at a remote player silently
-- does nothing on a dedicated server. Shoving someone -> KnockbackFrom.
-- =======================================================================

-- Direction + impulse, shared by both launchers. nil when the two points coincide.

local function launchVector(victim, pivotLoc, horiz, up, towards)
    if Utils.IsActorInvalid(victim) or not pivotLoc then return nil end
    local vl = victim:K2_GetActorLocation()
    if not vl then return nil end
    local dx, dy
    if towards then dx, dy = pivotLoc.X - vl.X, pivotLoc.Y - vl.Y
    else            dx, dy = vl.X - pivotLoc.X, vl.Y - pivotLoc.Y end
    local d = math.sqrt(dx * dx + dy * dy)
    if d < 1 then return nil end
    return FVector(dx / d * horiz, dy / d * horiz, up or 0)
end

-- SELF-LAUNCH / toss a summon. Deterministic arc (both axes overridden). Ignores victim weight.

function AVU.LaunchCharacterFrom(victim, pivotLoc, horiz, up, towards)
    local vel = launchVector(victim, pivotLoc, horiz, up, towards)
    if not vel then return end
    pcall(function() victim:LaunchCharacter(vel, true, true) end)
end

-- KNOCKBACK onto another character - the one that actually reaches a client-controlled player.
--   opts.OverrideXY = true REPLACES the victim's horizontal motion instead of adding to it: for a
--   hard reel/pull a sprinting target shouldn't be able to walk out of (the Constrictor lasso).
--   Falls back to plain LaunchCharacter if ScaledLaunchCharacter isn't resolvable on that pawn.

function AVU.KnockbackFrom(victim, pivotLoc, horiz, up, towards, opts)
    local vel = launchVector(victim, pivotLoc, horiz, up, towards)
    if not vel then return end
    -- The two defaults differ on purpose: a LEG-shaped shove ADDS unless told otherwise.
    AVU.KnockbackVelocity(victim, vel, { OverrideXY = (opts and opts.OverrideXY) == true })
end

-- KNOCKBACK with a COMPUTED velocity vector - the same primitive as KnockbackFrom, for when the
-- arc was solved rather than shaped from legs (an AVM.LobVelocity that lands the victim on a
-- chosen spot in a chosen time: the Magus reel-in). Both axes are overridden by default - a
-- solved arc is only right if it REPLACES the victim's motion; opts.OverrideXY = false adds.

function AVU.KnockbackVelocity(victim, vel, opts)
    if Utils.IsActorInvalid(victim) or not vel then return end
    local overrideXY = not (opts and opts.OverrideXY == false)
    local ok = pcall(function() victim:ScaledLaunchCharacter(vel, overrideXY, true) end)
    if not ok then pcall(function() victim:LaunchCharacter(vel, overrideXY, true) end) end
end

-- Per-actor Jump cooldown, keyed by Utils.ActorKey (+ opts.CooldownKey namespace, so an NPC can run
-- SEVERAL jump behaviours - e.g. a backward LeapBack and a sideways strafe-juke - on independent
-- cooldowns). Plain table, bounded by distinct NPCs seen. key -> FAST_TICK of last hop.
local jumpCd = {}

-- [AUTHORITY] A directional IMPULSE LEAP relative to a nearby threat. Call it every OnTick - it
-- self-cooldowns and optionally range-checks, so the caller just fires it. Cheap by DEFAULT: the
-- threat is the combat target (one read, no scan).
--   opts.Dir          "back" (default, away), "left", "right", or "side"/"random". Left/right are
--                     perpendicular to the threat line; the actor keeps FACING it either way, so a
--                     backward leap reads as recoil and a sidestep keeps the guns on target.
--   opts.TriggerRange only hop when the threat is within this many uu. nil = no range gate (fire on
--                     cadence regardless - what a strafe-juke wants).
--   opts.Distance     horizontal impulse (900 ~ a 5m hop).   opts.Up  vertical impulse (250).
--   opts.Cooldown     FAST_TICKs between hops (50 ~5s). 0 = the caller owns the cadence.
--   opts.CooldownKey  namespace suffix, so several jump behaviours on one actor don't share a cd.
--   opts.Threat       explicit threat actor.   opts.Montage  montage PATH to play on the hop.
-- Returns true if it hopped. A pure impulse (no load), so it is safe in the OnTick drain.

function AVU.Jump(actor, opts)
    if Utils.IsActorInvalid(actor) or not Utils.IsAuthority() then return false end
    opts = opts or {}
    local key = Utils.ActorKey(actor); if not key then return false end
    key = key .. (opts.CooldownKey or "")
    local now = STATE.FAST_TICK
    local cd = opts.Cooldown or 50
    if cd > 0 and (now - (jumpCd[key] or -cd)) < cd then return false end

    local threat = opts.Threat
    if Utils.IsActorInvalid(threat) then threat = actor:GetCurrentCombatTarget() end
    if Utils.IsActorInvalid(threat) then return false end

    local aLoc = actor:K2_GetActorLocation()
    local tLoc = threat:K2_GetActorLocation()
    if not aLoc or not tLoc then return false end
    if opts.TriggerRange and Utils.DistSq(aLoc, tLoc) > opts.TriggerRange * opts.TriggerRange then
        return false
    end

    jumpCd[key] = now
    -- Cancel the in-flight MoveTo FIRST, or the controller keeps driving the pawn and cancels out the
    -- hop ("it runs forward through it"). The launch impulse then carries.
    pcall(function()
        local c = actor:GetController()
        if IsValid(c) then c:StopMovement() end
    end)
    -- Always FACE the threat: a backward leap reads as a real recoil (looking at the enemy), and a
    -- sidestep keeps the guns on target while juking.
    pcall(function() actor:K2_SetActorRotation(Utils.RotatorToTarget(aLoc, tLoc), false) end)
    if opts.Montage then AVU.PlayAnimation(actor, opts.Montage, 1) end

    -- Unit direction toward the threat, then the launch vector per Dir. Left/right are perpendicular
    -- (UE +90deg CCW of forward = (-uy, ux)); back is straight away.
    local dir = opts.Dir or "back"
    if dir == "side" or dir == "random" then dir = (math.random() < 0.5) and "left" or "right" end
    local dx, dy = tLoc.X - aLoc.X, tLoc.Y - aLoc.Y
    local d = math.sqrt(dx * dx + dy * dy)
    if d < 1 then return true end
    local ux, uy = dx / d, dy / d
    local vx, vy
    if dir == "left" then vx, vy = -uy, ux
    elseif dir == "right" then vx, vy = uy, -ux
    else vx, vy = -ux, -uy end   -- back
    local horiz = opts.Distance or 900
    pcall(function()
        actor:LaunchCharacter(FVector(vx * horiz, vy * horiz, opts.Up or 250), true, true)
    end)
    return true
end

-- Back-compat alias: the original AVU.BackJump == AVU.Jump with Dir "back".

function AVU.BackJump(actor, opts)
    opts = opts or {}
    opts.Dir = "back"
    if opts.TriggerRange == nil then opts.TriggerRange = 300 end   -- BackJump always range-gated
    return AVU.Jump(actor, opts)
end

-- [AUTHORITY] A one-shot damage BLAST at `loc` - players always, nearby NPCs opt-in. Built for the
-- safe pattern (CLAUDE.md 6), so call it OFF the ProcessDamage hook.
--   * Every victim is a VALIDATED single-target hit (never ApplyRadialDamage over a crowd), and the
--     damage goes through AVU.PointDamageOffHook - so a blow that KILLS runs the death cascade at
--     the EIGT flush (a hitch), never nested in the drain (the wedge).
--   * NPCs additionally SKIP lethal-range victims (flavour: leave a sliver for the finisher) and
--     spare followers.
--   opts.Radius (500) | Damage (60) | DamageType (class path, PRELOAD it; default Blunt, which is
--     debuff-free so the NPC path can't hit the debuff-preload deadlock) | HitNpcs (false) |
--     Knockback (0 = none, horizontal away from loc) | KnockbackUp (200) |
--     Debuff + DebuffSeconds (PLAYERS only - an NPC->player debuff needs the direct
--       Server_ApplyBuff path, and its BuffObject must be preloaded at fire time) |
--     RequireLoS (false - drop victims behind geometry).

function AVU.BlastDamage(actor, loc, opts)
    if Utils.IsActorInvalid(actor) or not loc or not Utils.IsAuthority() then return end
    opts = opts or {}
    local dmg    = opts.Damage or 60
    local r2     = (opts.Radius or 500) ^ 2
    local dmgTypePath = opts.DamageType or ENUMS.DamageType.Blunt
    if IsNotValid(ASSETS.GetIfValid(dmgTypePath)) then return end   -- never fire untyped (= 0 damage, silently)
    local kb, kbUp = opts.Knockback or 0, opts.KnockbackUp or 200
    local eye = FVector(loc.X, loc.Y, loc.Z + 50)   -- LoS trace origin (off the floor)

    local function hit(v, isPlayer)
        if Utils.IsActorInvalid(v) or Utils.IsDeadSafe(v) then return end
        local ok, vl = pcall(function() return v:K2_GetActorLocation() end)
        if not ok or not vl or Utils.DistSq(loc, vl) > r2 then return end
        if opts.RequireLoS and AVU.IsPathBlocked(actor, eye,
               FVector(vl.X, vl.Y, vl.Z + 40), { actor, v }) then return end
        AVU.PointDamageOffHook(actor, v, dmg, dmgTypePath)
        if isPlayer and opts.Debuff then
            Utils.ApplyBuffLinked(v, opts.Debuff, opts.DebuffSeconds)
        end
        if kb > 0 then AVU.KnockbackFrom(v, loc, kb, kbUp, false) end
    end

    local gsState = STATE.GameState
    local players = gsState and gsState.PlayerCharacterInGame
    if players then for i = 1, #players do hit(players[i], true) end end

    if opts.HitNpcs then
        for _, npc in ipairs(AVU.GetNearbyNpcs(loc, opts.Radius or 500, { ignoreActor = actor }) or {}) do
            local follower = false
            pcall(function() follower = npc:IsFollower() end)
            if not follower and not AVU.LethalRange(npc, dmg) then hit(npc, false) end
        end
    end
end

-- =======================================================================
-- Teleport an NPC
--   * Stops movement and temp turns collision off before moving to destination
--   * opts.FX: optional teleport FX. Default is the Exor Monk (Broadcast_TeleportFX)
--   * opts.NoFX: no FX at all. NOT the same as leaving opts.FX nil - that falls through to
--     Broadcast_TeleportFX, which only EXISTS on the Exor Monk, so on any other body it is a
--     pcall that fails silently. Say what you mean: a hop that is meant to be UNSEEN (the Phase
--     Peccary's vanish) should not depend on a missing UFunction to stay invisible.
--   * opts.OnDone - callback function after teleporting
-- =======================================================================

function AVU.TeleportTo(actor, dest, opts)
    opts = opts or {}
    if Utils.IsActorInvalid(actor) or not dest then if opts.OnDone then opts.OnDone() end; return end
    local origin = actor:K2_GetActorLocation()
    local move = actor.CharacterMovement
    if IsValid(move) then pcall(function() move:StopMovementImmediately() end) end
    pcall(function() actor:SetActorEnableCollision(false) end)
    if opts.FX then
        AVU.SpawnLocalNiagara(origin, opts.FX, { Lifetime = 1500 })
        AVU.SpawnLocalNiagara(dest, opts.FX, { Lifetime = 1500 })
    elseif not opts.NoFX then
        pcall(function() actor:Broadcast_TeleportFX(origin, dest) end)
    end
    pcall(function() actor:K2_SetActorLocation(dest, false, {}, false) end)
    Utils.QueueWork(function()
        if Utils.IsActorValid(actor) then pcall(function() actor:SetActorEnableCollision(true) end) end
        if opts.OnDone then opts.OnDone() end
    end, opts.RestoreMs or 100)
end

-- [AUTHORITY] Blink an NPC to a navigable point near its combat target (via GetSpawnPoint), then
-- TeleportTo it. Shared by the Exor teleporters; other NPCs can reuse it (pass opts.FX for the
-- blink puff).
--   opts: Delay (ms before the hop, scaled by CustomTimeDilation; default 0),
--         RealTime (skip that scaling - see below),
--         Radius/MinRadius/Retries (spawn search; default 1000/300/6),
--         MaxDistSq (reject a wild navmesh result; default 3e6), RestoreMs, FX,
--         OnDone (called on EVERY exit path - use it to clear a one-teleport-at-a-time guard).

function AVU.TeleportNearTarget(actor, opts)
    opts = opts or {}
    local delayMs = opts.Delay or 0
    if not opts.RealTime then delayMs = delayMs * (actor.CustomTimeDilation or 1) end
    delayMs = math.floor(delayMs + 0.4)
    Utils.QueueWork(function()
        local function done() if opts.OnDone then opts.OnDone() end end
        if Utils.IsActorInvalid(actor) or actor.IsDead then return done() end
        local origin = actor:K2_GetActorLocation()
        local target = actor:GetCurrentCombatTarget()
        if Utils.IsActorInvalid(target) then return done() end
        local dest = Utils.GetSpawnPoint(target:K2_GetActorLocation(), opts.Radius or 1000, opts.MinRadius or 300, opts.Retries or 6)
        if not dest or Utils.DistSq(origin, dest) > (opts.MaxDistSq or 3000000) then return done() end
        AVU.TeleportTo(actor, dest, opts)
    end, delayMs)
end

-- Live NPCs within `radius` of `loc` (a sphere overlap on the NPC parent class). AUTHORITY.
-- opts: faction (only this Faction), onlyDamaged (HP < max), ignoreActor, maxZ.
--
-- *** THE OVERLAP IS A TRUE 3D SPHERE, AND "NEARBY" USUALLY MEANS "ON MY FLOOR". *** In a
-- multi-storey interior a 20m sweep reaches the balcony above as readily as the room you stand in,
-- so a sweep that hands out aggro or orders pulls a garrison that was never meant to be in the
-- fight down the stairs. Pass `maxZ` whenever the sweep drives BEHAVIOUR; leave it off for a
-- genuinely volumetric query (a blast, a cloud). Floor separation is ~1000uu, so ~600 is a storey.

function AVU.GetNearbyNpcs(loc, radius, opts)
    opts = opts or {}
    local kismet = UEHelpers.GetKismetSystemLibrary()
    local world = Utils.GetWorld()
    if IsNotValid(kismet) or IsNotValid(world) or not loc then return {} end

    local npcClass = ASSETS.GetIfValid(ENUMS.BASE_PARENT_NPC)
    if not npcClass then return {} end

    local nearby = {}
    pcall(function()
        kismet:SphereOverlapActors(world, loc, radius, {}, npcClass, {}, nearby)
    end)

    local ignoreName = opts.ignoreActor and opts.ignoreActor:GetFullName() or nil
    local results = {}
    for i = 1, #nearby do
        local npc = nearby[i]:get()
        if npc and Utils.IsActorAlive(npc) then
            local keep = true
            if ignoreName and npc:GetFullName() == ignoreName then keep = false end
            if keep and opts.faction ~= nil and npc.Faction ~= opts.faction then keep = false end
            if keep and opts.maxZ then
                local ok, at = pcall(function() return npc:K2_GetActorLocation() end)
                if not ok or not at or math.abs(at.Z - loc.Z) > opts.maxZ then keep = false end
            end
            if keep and opts.onlyDamaged then
                local ok, hp, maxhp = pcall(function()
                    return npc:GetTotalHealth(), npc:GetMaxTotalHealth()
                end)
                if not ok or not hp or hp >= (maxhp or hp) then keep = false end
            end
            if keep then results[#results + 1] = npc end
        end
    end
    return results
end


-- [AUTHORITY] Could raw damage plausibly kill this NPC (head or torso at/under raw)?
-- *** A GAMEPLAY KNOB, NOT A SAFETY GUARD. *** It compares RAW damage against the limb scalars, but
-- the native pipeline applies limb distribution, headshot x2 and resist/weakness AFTER our check -
-- so a "not lethal" verdict can still be a killing blow (proven: a Velites Guard read as safe, died
-- in-drain, and its inline death cascade cold-loaded = the wedge).
-- Use it for FLAVOUR (skip / stun / burn a lethal-range victim so the owner gets the finish); the
-- actual crash guard is dealing the damage through AVU.PointDamageOffHook, ALWAYS.

function AVU.LethalRange(npc, raw)
    if Utils.IsActorInvalid(npc) or not raw or raw <= 0 then return false end
    local head, torso
    pcall(function() head = tonumber(npc:GetLimbHealth(3)) end)
    pcall(function() torso = tonumber(npc:GetLimbHealth(4)) end)
    if head and head > 0 and head <= raw then return true end
    if torso and torso > 0 and torso <= raw then return true end
    -- Unreadable limbs (freed / exotic NPC): play it safe - treat as lethal-range so no blow lands.
    if not head and not torso then return true end
    return false
end

-- [AUTHORITY] ONE single-target point-damage hit, OFF-HOOK (EIGT).
--   * Damage dealt inline in the drain runs the victim's full pipeline synchronously, and a KILLING
--     blow runs the whole death sequence (ragdoll, death FX, native loot) nested in the drain hook -
--     one cold asset there is the CLAUDE.md 2 deadlock. Hopped, a kill's cold loads are a hitch.
--   * Gameplay work, so EIGT is safe on ALL roles (the AddBuff rule).
--   * Both actors cross through Utils.CarryActor: a character as its gated wrapper, anything else (a
--     deployable victim, a projectile causer) as a path re-found inside - a UObject-array walk each.
--   * The DamageType re-resolves inside - have it warm (the common ones are keeper-pinned), since a
--     cold one skips the hit rather than load.
--   * A vanished attacker still deals the (already-committed) hit, just without kill credit.
--   * `notACharacter` for a victim with no IsDead at all (a deployable): the corpse check reads an
--     absent property there, and an unreadable one is taken as dead - which would drop the hit.
--   * The instigator CONTROLLER is what gets the kill credit. It is derived from the attacker's
--     NPC_Controller, so a PLAYER attacker must pass one: that property does not exist on a player
--     and an absent UObject field reads as a placeholder rather than nil (CLAUDE.md 3), which would
--     hand ApplyPointDamage a junk controller. Pass the attacker's OWN controller: the hop re-reads
--     it off the live attacker and only re-finds the passed one by path once the attacker is gone.
local gameplayStatics   -- /Script/ default object: never GCs, so a cached wrapper is safe forever
                        -- (the buffHandleLib precedent). Uncached this was one full UObject-array
                        -- walk PER HIT inside the EIGT - part of the FrostCone 70ms impact hitch.

function AVU.PointDamageOffHook(attacker, victim, dmg, dmgTypePath, notACharacter, instigatorCtrl)
    if Utils.IsActorInvalid(victim) or not dmg or dmg <= 0 or not dmgTypePath then return end
    local vPath = Utils.ObjectPath(victim)   -- the freeze breadcrumb's name
    if not vPath then return end
    local getV, getA = Utils.CarryActor(victim), Utils.CarryActor(attacker)
    local ctrlPath = instigatorCtrl and Utils.ObjectPath(instigatorCtrl) or nil
    ExecuteInGameThread(function()
        STATE.LastWork = "EIGT pointDmg " .. vPath
        STATE.LastWorkDone = false
        pcall(function()
            local v = getV()
            if not v or (not notACharacter and Utils.IsDeadSafe(v)) then return end
            if IsNotValid(gameplayStatics) then
                gameplayStatics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
            end
            local gs = gameplayStatics
            local dt = ASSETS.GetIfValid(dmgTypePath)
            if not gs or IsNotValid(dt) then return end   -- never fire untyped (= silent 0 damage)
            local a = getA()
            local ctrl
            if ctrlPath then
                if a then pcall(function() ctrl = a:GetController() end) end
                if IsNotValid(ctrl) then ctrl = Utils.ResolveByPath(ctrlPath) end
            elseif a then
                pcall(function() ctrl = a.NPC_Controller end)
            end
            -- Straight-down direction: limb distribution needs SOME direction; every caller used this.
            gs:ApplyPointDamage(v, dmg, FVector(0, 0, -1), {}, ctrl, a, dt)
        end)
        STATE.LastWorkDone = true
    end)
end

-- =======================================================================
-- def.DeployableDamage - "this NPC chews through player defenses".
--
-- A declarative map of DEPLOYABLE FAMILY -> multiplier, resolved here and applied by CombatHooks,
-- which hits the deployable AGAIN for (mult - 1) more of the same raw damage - a hit on a
-- deployable cannot be edited, only added to:
--
--     DeployableDamage = { Barricade = 8, Fan = 8 },            -- always
--     HardMode = { DeployableDamage = { Turret = 4 } },         -- HARDMODE.NoMercy only
--
--   * Family names come from ENUMS.DeployedGroups, so two NPCs that both "smash barricades" agree
--     on what a barricade is. An unknown key is ignored (no silent match).
--   * The extra hit runs the deployable's own math, so the number is a clean factor on the
--     durability actually lost whatever that math is - the flat x0.5 the engine gives every
--     AI-instigated hit included. `8` really is 8x what that body did before.
--   * HARD OVERRIDES, it does not merge: a HardMode block REPLACES the base map outright, so a
--     variant that should only smash in hard mode simply omits the base one. Read at FIRE time off
--     the shared registry def (never a per-actor copy - hooks resolve defs by DisplayName, see
--     the hard-mode notes in ModuleNotes.md).
--   * First matching family wins; `pairs` order is arbitrary, so don't write two families that can
--     match the same class with different numbers.
--
-- Returns the multiplier, or nil for "leave the native value alone".
-- =======================================================================

function AVU.DeployableDamageMult(def, className)
    if type(def) ~= "table" or type(className) ~= "string" then return nil end

    local spec = def.DeployableDamage
    if STATE.HardModeNoMercy and def.HardMode and def.HardMode.DeployableDamage then
        spec = def.HardMode.DeployableDamage
    end
    if type(spec) ~= "table" then return nil end

    local lc = className:lower()
    for group, mult in pairs(spec) do
        local prefixes = ENUMS.DeployedGroups[group]
        if prefixes and type(mult) == "number" and mult > 0 then
            for i = 1, #prefixes do
                local p = prefixes[i]
                if lc:sub(1, #p) == p then return mult end
            end
        end
    end
    return nil
end


-- [AUTHORITY] Living NPCs of the SAME faction as `actor`, within `radius` of it - the "who can I
-- support / buff / heal / rally" query.
--   * GetNearbyNpcs already does the work; this just spares every caller from re-reading its own
--     Faction and excluding itself. Extra opts (onlyDamaged, ...) are merged through.
--   * Returns {} if the actor has no readable faction.

function AVU.GetAllies(actor, radius, opts)
    if Utils.IsActorInvalid(actor) then return {} end

    local loc = actor:K2_GetActorLocation()
    if not loc then return {} end

    local fac
    pcall(function() fac = actor.Faction end)
    if fac == nil then return {} end

    local query = { faction = fac, ignoreActor = actor }
    for k, v in pairs(opts or {}) do query[k] = v end
    return AVU.GetNearbyNpcs(loc, radius, query)
end


-- Count/return actors of a given class within `radius` of `loc`. `classPathOrObj`
-- may be an asset path string (resolved fresh) or a live UClass. Returns a plain
-- array of actor wrappers (index with :get()). Used e.g. to avoid re-stacking the
-- Commander's barricade. AUTHORITY.

function AVU.GetNearbyActorsOfClass(loc, radius, classPathOrObj)
    local kismet = UEHelpers.GetKismetSystemLibrary()
    local world = Utils.GetWorld()
    if IsNotValid(kismet) or IsNotValid(world) or not loc then return {} end

    -- A resident class asked for by path is pinned on first use: callers poll (a bench check every
    -- few seconds), and an unpinned class is a probe per call. An unloaded one is not loaded just to
    -- be asked about - it has no instances, and an NPC class is heavy.
    local cls = classPathOrObj
    if type(classPathOrObj) == "string" then
        cls = ASSETS.GetIfPinned(classPathOrObj)
        if not cls then
            cls = ASSETS.GetIfValid(classPathOrObj)   -- a miss is final
            if cls and SETTINGS.CORE.ASSET_KEEPER
                and not require("AnteCore.AssetKeeper").IsUnpinnable(classPathOrObj) then
                ASSETS.PinSoon({ classPathOrObj })
            end
        end
    end
    if IsNotValid(cls) then return {} end

    local nearby = {}
    pcall(function()
        kismet:SphereOverlapActors(world, loc, radius, {}, cls, {}, nearby)
    end)
    return nearby
end


-- Is `loc` a clear place to put a body, or is it INSIDE a player deployable? A sphere overlap alone
-- CANNOT answer that - a floor tile, a wall and a chest are all the same class, and standing ON a
-- floor tile is exactly what we want - so every hit is tested against its OWN box: inside it in XY
-- and BELOW its top face = we'd be standing in the object; at or above that face = on it, fine.
--   * `loc` is the FEET (a navmesh point), not the capsule centre - the Z test only makes sense
--     against the point the body stands on.
--   * Non-loading and drain-safe: the class resolves by path and the bounds read is pure.
--   opts: Probe (overlap radius, 250), Pad (XY slack ~a capsule radius, 60), Lip (how far under the
--         top face still reads as "on it", 40), Class (default anything a player built),
--         Ignore (skipped by full name, since `==` never works on wrappers).

function AVU.SpotClearOfDeployables(loc, opts)
    if not loc then return false end
    opts = opts or {}
    local pad = opts.Pad or 60
    local lip = opts.Lip or 40

    local ignoreName
    if opts.Ignore then pcall(function() ignoreName = opts.Ignore:GetFullName() end) end

    local hits = AVU.GetNearbyActorsOfClass(loc, opts.Probe or 250,
        opts.Class or ENUMS.DeployedObjs.BASE) or {}
    for i = 1, #hits do
        -- Overlap out-param elements can arrive as RemoteUnrealParam; unwrap when they do.
        local a = hits[i]
        local okg, inner = pcall(function() return hits[i]:get() end)
        if okg and inner then a = inner end

        local name
        if ignoreName then pcall(function() name = a:GetFullName() end) end

        if IsValid(a) and (not ignoreName or name ~= ignoreName) then
            local blocked = false
            pcall(function()
                local origin, extent = FVector(), FVector()
                a:GetActorBounds(true, origin, extent, false)
                if math.abs(loc.X - origin.X) <= extent.X + pad
                    and math.abs(loc.Y - origin.Y) <= extent.Y + pad
                    and loc.Z < (origin.Z + extent.Z) - lip then
                    blocked = true
                end
            end)
            if blocked then return false end
        end
    end
    return true
end


-- [AUTHORITY] Drop `count` LIVE frag grenades at `actor`'s feet (the Grenadier's cook-off when
-- downed or hit hard). `instantCount` of them explode on contact; the rest arm a fuse after their
-- first bounce. Off-hooked like the other spawns - a grenade's BeginPlay can blocking-load its FX.
--   opts: Damage (60), SpeedMult (0.3), DropZ (30), Fuzz (50), Fuse (2s), Class, Mesh,
--         Scale (VISUAL size only, and it does NOT replicate),
--         Radius (the REAL blast = AoE outer radius; + InnerRadius / AoEMinDamage),
--         NoBounce (plant it where it lands instead of letting it bounce and roll away).

function AVU.DropGrenades(actor, count, instantCount, opts)
    if Utils.IsActorInvalid(actor) then return end
    opts = opts or {}
    count = count or 1
    instantCount = instantCount or 0

    -- Grenade class + appearance. Default = the military frag (+ its mesh). Pass opts.Class to
    -- drop a different grenade (e.g. the Exor grenade); with a custom Class and no opts.Mesh the
    -- grenade keeps its OWN appearance (e.g. the Exor grenade's meshless red orb).
    local clsPath  = opts.Class or ENUMS.ProjectileClasses.GrenadeFrag
    local meshPath = opts.Mesh
    if not meshPath and not opts.Class then meshPath = ENUMS.Components.SM_GRENADE_FRAG end
    local loc = actor:K2_GetActorLocation()
    if not loc then return end

    local damage   = opts.Damage or 60
    local speedMul = opts.SpeedMult or 0.3
    local dropZ    = opts.DropZ or 30
    local fuzz     = opts.Fuzz or 50
    local fuse     = opts.Fuse or 2   -- seconds until it detonates (FuseAfterFirstBounce; ~fuse from spawn)
    local scale    = opts.Scale       -- uniform actor scale (number); scales the grenade's VISUAL bigger.
                                      -- NOTE: SetActorScale3D doesn't replicate, so remote clients see
                                      -- native size; host/SP renders it. Doesn't change the blast radius.
    -- BLAST RADIUS (the real one). opts.Radius = AoE OUTER radius (uu); nil = keep the grenade's native
    -- blast. opts.InnerRadius = the full-damage core (default 35% of Radius); opts.AoEMinDamage = damage
    -- at the outer edge. Setting Radius force-enables AreaOfEffectDamage.
    local radius   = opts.Radius
    local inner    = opts.InnerRadius
    local aoeMin   = opts.AoEMinDamage

    local toLoad = { clsPath }
    if meshPath then toLoad[#toLoad + 1] = meshPath end
    ASSETS.LoadAsync(toLoad, function(results)
        if IsNotValid(results[clsPath]) then LogBad("DropGrenades - grenade class not loaded"); return end

        -- Pinned, every later drop's load and re-resolve is a table read instead of a UObject walk.
        ASSETS.PinSoon(toLoad)

        local function doDrop()
            if Utils.IsActorInvalid(actor) then return end
            -- Re-resolve by path, never the load callback's wrapper: doDrop runs a drain later
            -- ([[anteup2-stale-class-spawn-av]]).
            local grenadeClass = ASSETS.GetIfValid(clsPath)
            if IsNotValid(grenadeClass) then
                LogBad("DropGrenades - class collected between load and spawn: " .. tostring(clsPath))
                return
            end
            local mesh = meshPath and ASSETS.GetIfValid(meshPath) or nil
            local gs = UEHelpers.GetGameplayStatics()
            local km = UEHelpers.GetKismetMathLibrary()
            local world = Utils.GetWorld()
            if not gs or not km or IsNotValid(world) then return end

            for i = 1, count do
                local spawnLoc = Utils.FuzzLocation(loc, fuzz)
                spawnLoc.Z = spawnLoc.Z + dropZ
                local explodeOnContact = i <= instantCount
                local xform = km:MakeTransform(spawnLoc, FRotator(), FVector(1, 1, 1))

                local ok, err = pcall(function()
                    -- mode 2 = AdjustIfPossibleButAlwaysSpawn
                    local proj = gs:BeginDeferredActorSpawnFromClass(world, grenadeClass, xform, 2, nil, 0)
                    if IsNotValid(proj) then return end
                    -- Fuse config BEFORE FinishSpawning (BeginPlay reads it).
                    pcall(function() proj.FuseStartsImmediately = not explodeOnContact end)
                    pcall(function() proj.FuseAfterFirstBounce = fuse end)
                    pcall(function() proj.FirstBounce = false end)
                    pcall(function() proj.ExplodesOnContact = explodeOnContact end)
                    pcall(function() proj.WasThrown = false end)
                    pcall(function() proj["Simulate Projectile"] = true end)
                    pcall(function() proj.VelocityOverride = FVector(0, 0, -250) end)  -- drop at the feet

                    -- Blast radius. Mutate the ProjectileData struct's SCALAR fields IN PLACE - never
                    -- write the whole struct back: it holds a SOFT ptr (DamageType) that UE4SS mangles
                    -- on a struct copy -> bad damage type / render-thread AV (CLAUDE.md S3). Set before
                    -- FinishSpawning so whatever BeginPlay caches sees our values.
                    if radius then
                        pcall(function()
                            local pd = proj.ProjectileData
                            if not pd then return end
                            local P = SCHEMA.Projectile
                            pd[P.AreaOfEffectDamage] = true
                            pd[P.AoE_OuterRadius] = radius
                            pd[P.AoE_InnerRadius] = inner or (radius * 0.35)
                            if aoeMin then
                                pd[P.AoEMinimumDamage] = aoeMin
                            end
                        end)
                    end

                    -- opts.NoBounce MUST be set on ProjectileData BEFORE FinishSpawning: the
                    -- projectile's BeginPlay COPIES this row onto its movement component, so
                    -- anything written to the component afterwards fights the row rather than
                    -- replacing it (same reason the blast-radius block above writes the row). The
                    -- fuse doesn't depend on a bounce here, so stopping it dead is safe.
                    if opts.NoBounce then
                        pcall(function()
                            local pd = proj.ProjectileData
                            if not pd then return end
                            local P = SCHEMA.Projectile
                            pd[P.ShouldBounce] = false
                            pd[P.Bounciness] = 0          -- row default 0.6
                            pd[P.Friction] = 1            -- row default 0.2
                            pd[P.BounceVelocityStopSimulatingThreshold] = 1000
                        end)
                    end

                    proj = gs:FinishSpawningActor(proj, xform, 2)
                    if IsNotValid(proj) then return end

                    pcall(function() proj:SetOwner(actor) end)
                    pcall(function() proj.DamageFromWeapon = damage end)
                    pcall(function() proj["Base Damage"] = damage end)
                    pcall(function() proj.ProjectileSpeedMultiplier = speedMul end)
                    if scale then pcall(function() proj:SetActorScale3D(FVector(scale, scale, scale)) end) end
                    if IsValid(mesh) and proj.SM_Appearance then
                        pcall(function() proj.SM_Appearance:SetStaticMesh(mesh); proj:SM_Updated() end)
                    end

                    -- (NoBounce is applied on ProjectileData BEFORE FinishSpawning - see above. Writing
                    -- the movement component here instead does NOT work: BeginPlay has already copied
                    -- the row onto it, and the row is what the component keeps using.)
                end)
                if not ok then LogBad("DropGrenades spawn error: " .. tostring(err)) end
            end
        end

        if STATE.Role == "DEDICATED" then ExecuteInGameThread(doDrop) else Utils.QueueWork(doDrop, 0) end
    end)
end


-- [AUTHORITY] An NPC's CURRENT combat target, or nil.
--   * GetCurrentCombatTarget is the primary read, but it can come back nil for a beat right after
--     the combat-state flip (and on a freshly-spawned NPC whose BT hasn't run yet) - so fall back
--     to the AI blackboard's "TargetActor", the key the whole AI stack actually drives
--     (see Abiotic_AI_Controller_ParentBP).
--   * Fully nil-safe: use this instead of a raw GetCurrentCombatTarget wherever a nil read would
--     silently skip your logic.
--   * The pooled move-order bait reads as nil. It is a real combat target until the body finds an
--     enemy, but never one to aim at: a Hive Sow dropped its cloud on the player's move anchor through
--     a wall ([[anteup2-aggrobait-loadasset-crash]]). Every caller asks "who is it fighting", so the
--     check lives here rather than in each aim.
--     Compared by address: this runs on every target read, and the bait is one pooled actor.
local function notBait(t)
    local bait = STATE.AggroBait
    if bait == nil then return t end
    local a, b
    pcall(function() a = t:GetAddress(); b = bait:GetAddress() end)
    if a ~= nil and a == b then return nil end
    return t
end

function AVU.GetCurrentTarget(actor)
    if Utils.IsActorInvalid(actor) then return nil end

    local t
    pcall(function() t = actor:GetCurrentCombatTarget() end)
    if Utils.IsActorValid(t) then return notBait(t) end

    pcall(function()
        local c = actor.NPC_Controller
        if IsNotValid(c) then c = actor:GetController() end
        if IsValid(c) and IsValid(c.Blackboard) then
            local obj = c.Blackboard:GetValueAsObject(FName("TargetActor"))
            if IsValid(obj) then t = obj end
        end
    end)
    return Utils.IsActorValid(t) and notBait(t) or nil
end


-- [AUTHORITY] The RAW blackboard `TargetActor`, whatever it is - including what GetCurrentTarget
-- deliberately hides. THE TWO READS ARE NOT THE SAME QUESTION:
--   * GetCurrentTarget = "who is this NPC FIGHTING" - it prefers the combat target, which is what
--     an attack, an aim or a kite wants.
--   * This = "what is the AI stack pointed at RIGHT NOW". BT_CheckObstruction hard-writes any
--     damageable prop in the way - a deployable, a door, a window - straight into TargetActor, and
--     the combat-target read does NOT report that. A body stuck chewing on a barricade looks
--     perfectly healthy through the other one, which is why the first un-stick never fired.
--
-- VALIDATED WITH PLAIN `IsValid`, NEVER Utils.IsActorValid - and that is the reason this exists as
-- its own read. IsActorValid opens with an `actor.NPCData` read, which a deployable has no field
-- for, so it reports every prop as GONE: wrap this in the usual helper and it returns nil for
-- exactly the targets you asked for.

function AVU.GetBlackboardTarget(actor)
    if Utils.IsActorInvalid(actor) then return nil end
    local t
    pcall(function()
        local c = actor.NPC_Controller
        if IsNotValid(c) then c = actor:GetController() end
        if IsValid(c) and IsValid(c.Blackboard) then
            local obj = c.Blackboard:GetValueAsObject(FName("TargetActor"))
            if IsValid(obj) then t = obj end
        end
    end)
    return t
end


-- [AUTHORITY] True while the NPC's current combat target is on the players' side: a player pawn,
-- or anything on the player faction 2 (a tamed pet - Buff_Follower copies the owner's faction
-- onto it). The gate for "only escalate a fight that is actually against the players" - e.g. the
-- Big Bots' Summon beats, which otherwise re-summon forever off their own faction-5
-- reinforcements locked back onto them. False when there is no target at all.
function AVU.IsNpcTargetingPlayer(npc)
    local target = AVU.GetCurrentTarget(npc)
    if not target then return false end
    if Utils.IsPlayer(target) then return true end
    local faction
    pcall(function() faction = target.Faction end)
    return faction == 2   -- Scientist/Player
end


-- The replicated switch every native target check funnels through (TargetableByNPCs ->
-- CheckCombatTargetValidity): false means "nothing may acquire or hold this", which is what the
-- console invisibility cheat and the end-credits ghost state both write.
-- A variant that picks its own targets bypasses that native gate entirely, so it has to ask here
-- or it keeps shooting an invisible player. Read raw rather than through TargetableByNPCs: that
-- one is an out-param UFunction, and its player override folds in DBNO, which is not our question.
-- Unreadable (an actor without the property) counts as targetable - never blind a bot on a miss.
function AVU.IsTargetableByNPCs(target)
    if Utils.IsActorInvalid(target) then return false end
    local flag
    pcall(function() flag = target.NPC_Targetable end)
    return flag ~= false
end


-- =======================================================================
-- SetBlackboardInt - write one BB_Main integer key on an NPC's controller. AUTHORITY.
--
-- WHY THIS IS A REAL LEVER AND NOT A HACK: the shipped soldier attack tree (BT_Attack_Soldier)
-- decides "fight or take cover" from two blackboard COUNTERS, and neither is exposed as a property:
--   * FailedHits >= 3      -> run BT_FindCombatCoverLocation, at ANY range. BTT_DoRangedAttack
--                            increments it on a miss, and the grunt burst spreads 15/10/3 degrees,
--                            so a normal firefight trips this constantly. This is the single
--                            biggest reason Order soldiers read as "they just hide".
--   * MeleeCounter >= 2    -> inside melee range, stop swinging and go to cover instead.
-- Holding either at 0 on a slow cadence deletes that branch for one NPC without touching the tree
-- asset, which we cannot edit. See AnteNPCs/OrderGruntHelpers (the Centurion).
--
-- Cheap and non-loading (one property read + one BP call), so it is safe on a tick. `key` must be
-- an INT key on BB_Main: SelfActor/TargetActor are objects, FailedHits / MeleeCounter /
-- PotentialCombatTargetCount / PatrolPathIndex are the ints.

function AVU.SetBlackboardInt(actor, key, value)
    if Utils.IsActorInvalid(actor) or not key then return false end
    local ok = false
    pcall(function()
        local c = actor.NPC_Controller
        if IsNotValid(c) then c = actor:GetController() end
        if IsNotValid(c) or IsNotValid(c.Blackboard) then return end
        c.Blackboard:SetValueAsInt(FName(key), value or 0)
        ok = true
    end)
    return ok
end


-- =======================================================================
-- SetBlackboardFloat - the float sibling, and the ONE that BasicStats.MeleeAttackRange needs.
--
-- The controller copies NPCData.RangeToMeleeAttack onto the `RangeToMeleeAttack` blackboard key in
-- BT_InitBlackboardValues, which runs ONCE on possess - before the pipeline has re-statted anything.
-- Every tree reads the KEY, not the property: it is both the "swing now" gate and the acceptance
-- radius of the chase MoveTo. So a variant that only writes the stat moves the sweep and leaves the
-- BT deciding on the vanilla number. Write both.

function AVU.SetBlackboardFloat(actor, key, value)
    if Utils.IsActorInvalid(actor) or not key then return false end
    local ok = false
    pcall(function()
        local c = actor.NPC_Controller
        if IsNotValid(c) then c = actor:GetController() end
        if IsNotValid(c) or IsNotValid(c.Blackboard) then return end
        c.Blackboard:SetValueAsFloat(FName(key), value or 0)
        ok = true
    end)
    return ok
end


-- =======================================================================
-- GetBlackboardBool - read one BB_Main bool key. **Returns nil when it could not be read**, which
-- is not the same answer as false: a caller that acts on "not true" would fire on every NPC whose
-- controller is mid-possess. Compare against `false` explicitly.
--
-- The one worth knowing is `CanSeeTarget`: real line of sight to the target's spottable points,
-- maintained by the BTS_ChooseBestTarget service (~1s) on every attack tree, so reading it costs a
-- property walk and no trace of our own. That makes it the cheap answer to "can this NPC see you
-- right now" - LineOfSightTo is a fresh trace per call. Two things it is NOT:
--   * not an acquisition test - it is only maintained while the NPC HAS a combat target, and
--   * TargetLocked short-circuits the service before it writes, so a locked NPC's value goes stale.

function AVU.GetBlackboardBool(actor, key)
    if Utils.IsActorInvalid(actor) or not key then return nil end
    local v
    pcall(function()
        local c = actor.NPC_Controller
        if IsNotValid(c) then c = actor:GetController() end
        if IsNotValid(c) or IsNotValid(c.Blackboard) then return end
        v = c.Blackboard:GetValueAsBool(FName(key))
    end)
    return v
end


-- =======================================================================
-- CanSeeActor - a fresh line-of-sight trace from an NPC to `target`: the AI controller's native
-- LineOfSightTo (Visibility channel, with its capsule-edge fallbacks). AUTHORITY.
--   * LineOfSightTo is an AController function. Called on the pawn it silently does nothing.
--   * `from` = the viewpoint; nil = the pawn's eyes, which assume an upright body. Pass the body's
--     own location when it isn't (an Exor on the ceiling).
--   * False on any failure, so a gate built on it fails closed.
--   * For the CURRENT target, the blackboard's CanSeeTarget (above) is free but ~1s old, and stale
--     under TargetLocked.
function AVU.CanSeeActor(actor, target, from)
    if Utils.IsActorInvalid(actor) or Utils.IsActorInvalid(target) then return false end
    local sees = false
    pcall(function()
        local c = actor.NPC_Controller
        if IsNotValid(c) then c = actor:GetController() end
        if IsValid(c) then sees = c:LineOfSightTo(target, from or FVector(0, 0, 0), false) == true end
    end)
    return sees
end


-- =======================================================================
-- SetBtStunned - the BT `Stunned` bool, written WITHOUT a stun buff. AUTHORITY.
--
-- This is the one lever that parks an NPC with no FX attached. Every main tree keeps a
-- `Stunned is Set -> BTTask_Wait` branch at HIGH priority with FlowAbortMode Both, so setting the
-- bool ABORTS whatever the NPC is doing and holds it there; clearing it drops straight back into
-- combat on the next evaluation. `BT_SetStunned` is the game's own writer for it
-- (Abiotic_AI_Controller_ParentBP), and it is all `BuffObject_Stunned` does to the AI side - the
-- particle, the overlay material and the `Modifier.Stunned` tag are the BUFF's doing, not the
-- tree's.
--
-- It aborts, so it does not stack with a tree's own post-attack wait - it replaces it. A caller
--   pacing an attack has to budget the whole gap, not the delta (see PestHelpers' RECOVER block).
-- It is a shared bool: a real stun landing on top writes the same key, and its OnBuffRemove will
--   clear it. Don't clear it blind - check AVU.HasGameplayTag(actor, "Modifier.Stunned") first if
--   a real stun could be running.
-- It parks movement too, not just attacks.

function AVU.SetBtStunned(actor, on)
    if Utils.IsActorInvalid(actor) then return false end
    local ok = false
    pcall(function()
        local c = actor.NPC_Controller
        if IsNotValid(c) then c = actor:GetController() end
        if IsNotValid(c) then return end
        c:BT_SetStunned(on == true)
        ok = true
    end)
    return ok
end


-- [AUTHORITY] Break the native PROP FIXATION: if this NPC has locked onto scenery instead of a
-- combatant, forget it and put it back on a player. Returns true if it un-stuck something.
--
-- THE BUG IT FIXES IS THE GAME'S. BT_CheckObstruction writes any damageable furniture into
-- TargetActor + TargetLocked on `CombatState || DeployedByPlayer` - an OR, so a NEUTRAL prop counts
-- and no fight need be underway. In a room dressed with deployables an NPC repeatedly drops the
-- player to go and hit a crate, and the lock is real, so it does not re-select on its own.
--   * A CHARACTER TARGET IS LEFT ALONE. The test is "has CharacterMovement" - present on players and
--     NPCs, absent on props - so a legitimate fight is never interrupted and nothing here needs to
--     know what a deployable class is. ONE property read, deliberately: a name/class test would
--     mean GetFullName, ~9ms in a crowd.
--   * ForgetCurrentTarget clears the lock; without the re-lock it just re-acquires the same crate
--     on the next obstruction check, so the two halves go together.
-- Call on a slow cadence and only while the body is MOBILE - a pinned NPC cannot be obstructed.

function AVU.UnstickFromProp(actor, opts)
    if Utils.IsActorInvalid(actor) then return false end
    opts = opts or {}

    local target = AVU.GetBlackboardTarget(actor)
    if not target then return false end

    local isCharacter = false
    pcall(function() isCharacter = IsValid(target.CharacterMovement) end)
    if isCharacter then return false end

    local controller
    pcall(function()
        controller = actor.NPC_Controller
        if IsNotValid(controller) then controller = actor:GetController() end
    end)
    if IsNotValid(controller) then return false end
    pcall(function() controller:ForgetCurrentTarget() end)

    local onto = opts.Target
    if Utils.IsActorInvalid(onto) then onto = Utils.RandomPlayer() end
    if onto then AVU.LockAggro(actor, onto) end

    LogDebug((opts.Label or "NPC") .. " - unstuck from a prop", SETTINGS.DEBUG_NPC_ACTIONS)
    return true
end


-- Force `npc` to immediately aggro `target` via its AI controller's BT calls
-- (mirrors the Signal Pest lure in Pest.lua). Use for summons, which otherwise
-- mill about - and swat each other - for a few seconds before noticing a player.
-- AUTHORITY only (drives AI). Safe to call repeatedly.
--   * delayMs (optional) - re-validates BOTH actors at fire time and aggros then. A summon
--     usually can't be aggroed the instant it spawns (its controller/BT isn't up yet, and a
--     THROWN one is still mid-air with no clean perception acquire), so the common pattern is
--     "spawn, wait ~1s, then force it onto the summoner's target". Both cross the wait through
--     Utils.CarryActor: a target can be a prop or deployable (a blackboard target), unstamped.

function AVU.ForceAggro(npc, target, delayMs)
    if delayMs and delayMs > 0 then
        local getN, getT = Utils.CarryActor(npc), Utils.CarryActor(target)
        Utils.QueueWork(function()
            local n, t = getN(), getT()
            if n and t then AVU.ForceAggro(n, t) end
        end, delayMs)
        return
    end

    if Utils.IsActorInvalid(npc) or Utils.IsActorInvalid(target) then return end
    local controller = npc:GetController()
    if IsNotValid(controller) then return end
    pcall(function()
        local targetLoc = target:K2_GetActorLocation()
        local success = {}
        controller:BT_SetCombatState(true, false, success)
        controller:BT_SetTargetActor(target)
        controller:UpdateTargetSpottedValue(target, true, true)
        controller:BT_SetLastKnownLocation(targetLoc, true, true)
        controller:BT_SetCanSeeTarget(target)
    end)
end


-- Re-assert cadence for a held AVU.LockAggro. Must beat the 1s BTS_ChooseBestTarget service (see the
-- one-shot note below), so 500ms - anything slower leaves a window to re-select a player each cycle.
local LOCK_HOLD_EVERY_MS = 500

-- [AUTHORITY] "Attack THIS and nothing else" - the game's own recipe (Buff_Command_Attack /
-- BP_SquadManager). Safe to call repeatedly; re-locks onto whatever `target` is.
--   * A BARE LOCK IS A ONE-SHOT - every attack task CLEARS TargetLocked on its completion path, so
--     a fire-and-forget lock lapses the moment the NPC lands one hit. Pass opts.HoldMs for anything
--     that must hold through a fight; the re-assert cadence must beat the 1s ChooseBestTarget
--     service, or each cycle has a window to re-select a player.
--   * opts.HoldMs / HoldEveryMs (500) / DelayMs (defer + re-validate, for a just-spawned NPC whose
--     controller isn't up yet).
--   * The hold self-releases when the target dies; a caller that must outlive that re-picks a live
--     target and re-locks. AVU.UnlockAggro ends one early.
--   * HOSTILITY IS STILL THE GATE - an NPC cannot be locked onto its own faction. NOT AIRTIGHT: a
--     locked NPC still stops to break a door/window in its path (see AVU.UnstickFromProp).
--   * TargetLocked is the ONLY lever that stops an NPC noticing a player mid-errand; neither
--     faction nor LocationOfInterest gates perception.
-- (Unlocked selection is NEAREST hostile, and a player is NOT special - see
--  AVU.SetTargetPriority + [[af-npc-targeting-levers]].)

function AVU.LockAggro(npc, target, opts)
    opts = opts or {}

    -- Both actors cross every wait below (the delay, each hold beat) through Utils.CarryActor - see
    -- ForceAggro. Re-got every beat, so the hold stops within one beat of either leaving play.
    if opts.DelayMs and opts.DelayMs > 0 then
        local rest = { HoldMs = opts.HoldMs, HoldEveryMs = opts.HoldEveryMs }
        local getN, getT = Utils.CarryActor(npc), Utils.CarryActor(target)
        Utils.QueueWork(function()
            local n, t = getN(), getT()
            if n and t then AVU.LockAggro(n, t, rest) end
        end, opts.DelayMs)
        return
    end

    if not AVU.AssertLock(npc, target) then return end

    local holdMs = opts.HoldMs or 0
    if holdMs <= 0 then return end

    -- The re-assert loop (see the one-shot note above for why it's needed). The clearing tasks are
    -- BTT_DoMeleeAttack / BTT_DoRangedAttack / BTT_DoCombatAbility - which is why Buff_Command_Attack
    -- re-runs its whole recipe on every buff tick, and why we do too.
    local every = opts.HoldEveryMs or LOCK_HOLD_EVERY_MS
    local left  = holdMs
    local getN, getT = Utils.CarryActor(npc), Utils.CarryActor(target)
    local function hold()
        left = left - every
        if left <= 0 or not STATE.ModEnabled then return end
        local n, t = getN(), getT()
        if not (n and t) or not AVU.AssertLock(n, t) then return end   -- either gone: the lock is moot
        Utils.QueueWork(hold, every)
    end
    Utils.QueueWork(hold, every)
end


-- [AUTHORITY] One application of the lock recipe (see AVU.LockAggro, which is this plus the re-assert
-- loop). Exposed for callers running their own cadence - e.g. one that re-picks a live target each
-- pass, which a plain HoldMs cannot do. Returns (ok, held): ok = the lock stands (false if the NPC
-- or target is gone/dead); held = it already stood and nothing was written this pass.
--
-- QUIET HOLD: when the lock is already fully in place, only the perception timestamp is refreshed -
-- the blackboard and combat state are left untouched. Re-running the full recipe on a cadence
-- kept restarting the combat-entry branch: a locked Reaper replayed its aggro montage every beat
-- and never reached its move task (stun-locked) - the same family as the AttackMove-on-a-cadence
-- corridor jam in [[af-aggro-anim-is-a-combat-delay]].

function AVU.AssertLock(npc, target)
    if Utils.IsActorInvalid(npc) or Utils.IsActorInvalid(target) then return false end
    if Utils.IsDeadSafe(npc) or Utils.IsDeadSafe(target) then return false end

    local controller = npc:GetController()
    if IsNotValid(controller) then return false end

    local ok, held = false, false
    pcall(function()
        -- Always: perception-map entry with a FRESH timestamp - without it the target isn't
        -- "known" at all and the TargetMemory sweep drops it on its next pass. A map write, not a
        -- blackboard write, so it can't churn decorator observers. It also BAILS if
        -- GetHostilityTowardsTarget is false - that's the faction gate the header warns about.
        controller:AddOrUpdatePotentialTarget(target, true)

        local bb = controller.Blackboard
        if IsValid(bb) then
            local cur = bb:GetValueAsObject(FName("TargetActor"))
            if IsValid(cur) and Utils.ActorKey(cur) == Utils.ActorKey(target)
                and bb:GetValueAsBool(FName("TargetLocked"))
                and bb:GetValueAsBool(FName("CanSeeTarget")) then
                ok, held = true, true
                return
            end
        end

        local success = {}
        controller:BT_SetTargetActor(target)
        controller:BT_SetCombatState(true, true, success)   -- SkipAggroAnimation: no roar, just go

        -- TargetLocked + a VALID TargetActor short-circuits BT_ChooseBestTarget ("locked & valid ->
        -- keep target, no re-selection") and makes SetCurrentCombatTarget refuse any swap -
        -- INCLUDING retaliation (JustTookDamage routes through it), so being shot/bitten by a third
        -- party cannot steal a locked NPC away.
        if IsValid(bb) then
            bb:SetValueAsBool(FName("TargetLocked"), true)
            bb:SetValueAsBool(FName("CanSeeTarget"), true)
        end
        ok = true
    end)
    return ok, held
end


-- [AUTHORITY, call on an OnTick beat ~0.5s] Camo-piercing sight: hold a target LOCK on a cloaked
-- player inside opts.Range. "Cloaked" = carrying Buff_ActiveCamo, the one row both the crystal
-- armor set and the stealth watch ride.
--
-- A held lock, not a one-shot force-spot: BT_ChooseBestTarget re-runs IsTargetInvisible on the
-- CURRENT target and forces CanSeeTarget false on a cloaked one - which on a Reaper walks the
-- tree into BTT_EndReaperHunt's 75% despawn roll (observed live: aggro, then vanish).
-- TargetLocked short-circuits that re-selection BEFORE the camo check and holds CanSeeTarget
-- true. Attack tasks clear the lock on completion, so it self-releases once this stops asserting.
--   * Facing gates ACQUISITION only, and only from idle - an NPC already fighting a DIFFERENT
--     target never has it stolen by a sneak. A held cloaked target is re-asserted from any angle,
--     out to 1.5x the widest radius (hysteresis, so the boundary doesn't flip-flop).
--   * opts.LightRange (off by default): a player with a shining flashlight or headlamp
--     (`Flashlight_On` covers held lights, gun lights and the megalight; `HeadlampOn` the lamp)
--     inside it gives themselves away - a CLOAKED one gets locked with no facing requirement,
--     an un-cloaked one gets a plain force-spot (which is what lets the NPC notice a light
--     BEHIND its back; native perception owns them from there).
--   * Console/debug invisibility (NPC_Targetable=false) is NOT pierced, deliberately: the lock's
--     acquisition path is validity-gated, so the dev cheat works against every variant.
--   * Un-cloaked, un-lit players are untouched - the native <=5m snap band already sees them.
--   * opts: Range (uu, default 500), HalfAngleDeg (facing cone half-angle, default 90),
--     LightRange (uu, nil = off).
--   * Returns the player it asserted a lock on, else nil - a caller can treat nil + a cloaked
--     still-held target as "escaped" and drop it (the Reaper beats do; a matching drop
--     threshold is 1.5x max(Range, LightRange)).

function AVU.PierceCamo(actor, opts)
    if Utils.IsActorInvalid(actor) or Utils.IsDeadSafe(actor) then return nil end
    opts = opts or {}
    local range = opts.Range or 500
    local cosHalf = math.cos(math.rad(opts.HalfAngleDeg or 90))

    local loc, fwd
    pcall(function()
        loc = actor:K2_GetActorLocation()
        fwd = actor:GetActorForwardVector()
    end)
    if not loc or not fwd then return nil end

    local cur = AVU.GetBlackboardTarget(actor)
    -- Deployable fixation writes FURNITURE into TargetActor ([[af-npc-targeting-levers]]) - a
    -- prop is not a fight, so it must not suppress acquisition ("never steals" is about
    -- characters; the lock overwrites the prop cleanly). CharacterMovement is the discriminator.
    if cur then
        local isChar = false
        pcall(function() isChar = IsValid(cur.CharacterMovement) end)
        if not isChar then cur = nil end
    end
    local curKey = cur and Utils.ActorKey(cur) or nil

    local rangeSq = range * range
    local lightSq = opts.LightRange and (opts.LightRange * opts.LightRange) or 0
    local holdSq = math.max(rangeSq, lightSq) * 2.25
    for _, p in ipairs(Utils.LivePlayers()) do
        local at
        pcall(function() at = p:K2_GetActorLocation() end)
        if at then
            local dx, dy, dz = at.X - loc.X, at.Y - loc.Y, at.Z - loc.Z
            local dSq = dx * dx + dy * dy + dz * dz
            local lit = false
            if lightSq > 0 and dSq <= lightSq then
                pcall(function() lit = (p.Flashlight_On or p.HeadlampOn) == true end)
                -- Which gate is failing? lit=false = the pawn bools read dark; cur=true = a held
                -- target is suppressing the branch; no line at all = range/beat.
                LogDebug(string.format("PierceCamo - in light range (lit=%s cur=%s cloaked=%s)",
                    tostring(lit), tostring(curKey ~= nil),
                    tostring(Utils.ActorHasBuff(p, "Buff_ActiveCamo"))), SETTINGS.DEBUG_NPC_ACTIONS)
            end
            if curKey and Utils.ActorKey(p) == curKey then
                -- Maintenance: keep the lock on a held cloaked target (any angle). Quiet when it
                -- already holds (see AssertLock); a re-lock line here on a cadence means
                -- something NATIVE is still dropping the lock between beats - diagnose, don't
                -- tune it away.
                if dSq <= holdSq and Utils.ActorHasBuff(p, "Buff_ActiveCamo") then
                    local ok, heldAlready = AVU.AssertLock(actor, p)
                    if ok and not heldAlready then
                        LogDebug("PierceCamo - re-lock (lock had lapsed)", SETTINGS.DEBUG_NPC_ACTIONS)
                    end
                    return p
                end
            elseif not curKey and dSq > 1 then
                if (dSq <= rangeSq or lit) and Utils.ActorHasBuff(p, "Buff_ActiveCamo") then
                    -- Acquisition: cloaked player in range and in the facing cone - or lit up,
                    -- which needs no facing.
                    local inv = 1 / math.sqrt(dSq)
                    if lit or fwd.X * dx * inv + fwd.Y * dy * inv + fwd.Z * dz * inv >= cosHalf then
                        AVU.AssertLock(actor, p)
                        LogDebug("PierceCamo - cloaked player locked", SETTINGS.DEBUG_NPC_ACTIONS)
                        return p
                    end
                elseif lit then
                    -- Un-cloaked light at close range: a plain force-spot, no lock - enough to
                    -- notice a lamp behind its back; native targeting does the rest.
                    pcall(function()
                        local c = actor.NPC_Controller
                        if IsNotValid(c) then c = actor:GetController() end
                        if IsValid(c) then c:UpdateTargetSpottedValue(p, true, false) end
                    end)
                    LogDebug("PierceCamo - light spotted", SETTINGS.DEBUG_NPC_ACTIONS)
                end
            end
        end
    end
    return nil
end


-- [AUTHORITY] Release an AVU.LockAggro. The NPC keeps its current target but is free to re-select
-- (so it notices players again) - use it when a scripted beat is over and the fight should carry on
-- as normal combat. A lock whose target has died has already released itself.

function AVU.UnlockAggro(npc)
    if Utils.IsActorInvalid(npc) then return end
    pcall(function()
        local c = npc:GetController()
        if IsNotValid(c) or IsNotValid(c.Blackboard) then return end
        c.Blackboard:SetValueAsBool(FName("TargetLocked"), false)
    end)
end


-- [AUTHORITY] Wake an IDLE NPC up to a fight WITHOUT locking it - the game's own squad recipe,
-- verbatim including its guard. Use it for "the war is on, join it" beats; use AVU.LockAggro when
-- the NPC must fight THIS target specifically.
--   * THE NATIVE GUARD IS THE POINT: an NPC already in combat, or already holding a TargetActor, is
--     left untouched (returns false) - so a periodic wake-up beat is idempotent and can never
--     retask a body mid-fight.
--   * The force-spot is the load-bearing call: it seeds the perception entry that satisfies the BT
--     root's target-count gate. A bare combat-state flag on an NPC that has perceived nothing just
--     falls back to idle - the flag is not the gate, the perception entry is.
--   * No TargetLocked write, so the target here is a starting shove, not an order.

function AVU.JoinCombat(npc, target)
    if Utils.IsActorInvalid(npc) or Utils.IsActorInvalid(target) then return false end
    if Utils.IsDeadSafe(npc) or Utils.IsDeadSafe(target) then return false end

    local controller = npc:GetController()
    if IsNotValid(controller) then return false end

    local ok = false
    pcall(function()
        if controller.IsInCombat then return end
        local bb = controller.Blackboard
        if IsValid(bb) and IsValid(bb:GetValueAsObject(FName("TargetActor"))) then return end

        local success = {}
        controller:AddOrUpdatePotentialTarget(target, true)
        controller:BT_SetTargetActor(target)
        controller:BT_SetCombatState(true, true, success)
        ok = true
    end)
    return ok
end


-- [AUTHORITY] How long (seconds) the controller remembers a target it can no longer SEE. Native 9.
--   * Every 5s the controller sweeps its known-target map, and any target older than TargetMemory
--     that also fails a strict line-of-sight check is dropped - AND removed from the perception
--     list entirely. That last part is the sting: it takes the potential-target count to 0, which
--     makes the target-choosing service early-out FOREVER, so the NPC cannot re-acquire until sight
--     re-perceives the enemy at close range. CombatState is never cleared, so it just mills about.
--   * That is why two warring NPC factions drift apart, fall out of combat and then refuse to
--     re-engage until a player walks into the middle of them. Raising this on a scripted set-piece's
--     cast keeps them locked on for the whole fight.
--   * Called from a spawn callback the controller may not be possessed yet, so it retries ONCE
--     off-hook. Returns true if it stuck.

function AVU.SetTargetMemory(npc, seconds, _retry)
    if Utils.IsActorInvalid(npc) or not seconds then return false end

    local c = npc.NPC_Controller
    if IsNotValid(c) then c = npc:GetController() end
    if IsNotValid(c) then
        if not _retry then
            Utils.QueueWork(function() AVU.SetTargetMemory(npc, seconds, true) end, 1000)
        end
        return false
    end

    local ok = false
    pcall(function()
        if c.TargetMemory == nil then return end
        c.TargetMemory = seconds
        ok = true
    end)
    return ok
end


-- [AUTHORITY] TARASQUE / YETI ONLY: set the controller half of the leap-slam cooldown.
--   * The leap-slam (ability slot 2) has TWO independent throttles - the pawn's
--     Cooldown_CombatAbility2 AND the AI controller's own `LeapCooldown` (native 18s, alongside
--     LeapRequiredMinDistance = 300). Lowering only the pawn's cooldown leaves the controller
--     gate in place, so the slam still won't come faster.
--   * Called from the STATS step, the controller may not be possessed yet - if it isn't up,
--     retry ONCE off-hook (_retry guards against looping forever). Returns true if it stuck.

function AVU.SetLeapCooldown(actor, seconds, _retry)
    if Utils.IsActorInvalid(actor) then return false end

    local c = actor.NPC_Controller
    if IsNotValid(c) then c = actor:GetController() end
    if IsNotValid(c) then
        if not _retry then
            Utils.QueueWork(function() AVU.SetLeapCooldown(actor, seconds, true) end, 1000)
        end
        return false
    end

    local ok = false
    pcall(function()
        if c.LeapCooldown == nil then return end   -- not a Tarasque/Yeti controller
        c.LeapCooldown = seconds
        ok = true
    end)
    return ok
end


-- =======================================================================
-- SetNoPatrol - stop an NPC's IDLE PATROL, the aimless wander that drifts a placed NPC off the spot
-- you put it on. Combat is untouched: it still aggros, chases and fights.
--
-- The gate is a "has enough time elapsed since the last patrol" check, so we push the timer out of
-- reach on BOTH sides: PatrolFrequency to the controller's own clamp ceiling (so its setup
-- randomiser, which runs a second after possess, can't undo us), and TimeOfLastIdlePatrol far in
-- the FUTURE, which makes the elapsed check negative. The second half is what survives
-- ClearStuckState - that rewinds the stamp and would otherwise let exactly one wander through each
-- time the NPC unsticks itself off geometry.
--
--   * IT DOES NOT STOP A PATH PATROLLER. An NPC whose spawner handed it an AI_PatrolPath walks a
--     different BT branch that reads neither knob. Stopping that means clearing the controller's
--     patrol path, which we deliberately DON'T - it is a soft-object pointer, and Lua writes mangle
--     those (CLAUDE.md 3). We log the case instead, with COORDS in the same form SpawnerData keys
--     use, so the offending placement is a straight search rather than a mystery.
--   * THE LOG BELOW CANNOT SEE A STAGED PATH. Under the spawner's PatrolOnlyActiveAfterCombat a
--     fresh body only holds PotentialPatrolPath; leaving combat promotes it. So an NPC that logs
--     nothing here and stands still all session can still start patrolling after its first fight,
--     and every later respawn from that spawner starts out patrolling. "/ai patrol" reads the
--     spawner side, which is where that is knowable.
--   * One-way by design, AUTHORITY, and it retries off-hook until the controller is possessed.
-- =======================================================================
local NO_PATROL_FREQ    = 99999   -- the controller's own FClamp ceiling (see above)
local NO_PATROL_STAMP   = 1e12    -- game-seconds; far enough out that elapsed is always negative
local NO_PATROL_RETRIES = 6       -- ~3s of 500ms retries while the controller possesses the pawn
local noPatrolWarned = {}         -- fullname -> true; callers RE-assert on a tick, so warn once each

function AVU.SetNoPatrol(actor, _tries)
    if Utils.IsActorInvalid(actor) then return false end

    local c = actor.NPC_Controller
    if IsNotValid(c) then c = actor:GetController() end
    if IsNotValid(c) then
        _tries = (_tries or 0) + 1
        if _tries <= NO_PATROL_RETRIES then
            Utils.QueueWork(function() AVU.SetNoPatrol(actor, _tries) end, 500)
        end
        return false
    end

    local ok = false
    pcall(function()
        if c.PatrolFrequency == nil then return end   -- not an Abiotic_AI_Controller_ParentBP
        c.PatrolFrequency      = NO_PATROL_FREQ
        c.TimeOfLastIdlePatrol = NO_PATROL_STAMP
        ok = true
    end)

    -- CurrentPatrolPath is the hard-pointer twin of PatrolPathSoftRef (the spawner writes both
    -- together in TrySeekPatrolPath), so it's the safe one to READ for the path-patroller warning.
    -- COORDS ARE THE POINT of this line: "an Exorrior is still wandering" is unactionable, and the
    -- path patroller is by definition the one that walked off. It runs at possess time, so the NPC
    -- is still on its spawn point - the location prints in the SAME "X,Y,Z" form SpawnerData keys
    -- use, so the offending entry is a straight search. The path actor's name is logged too: one
    -- AI_PatrolPath is usually shared by several spawners, so it names the placement, not just the
    -- body.
    pcall(function()
        if not IsValid(c.CurrentPatrolPath) then return end
        local fn = actor:GetFullName()
        if noPatrolWarned[fn] then return end
        noPatrolWarned[fn] = true

        local where = "?"
        pcall(function() where = Utils.PrintRoundedLocation(actor:K2_GetActorLocation()) end)
        local path = "?"
        pcall(function() path = c.CurrentPatrolPath:GetFullName() end)

        LogDebug("SetNoPatrol - " .. tostring(Utils.GetActorRowName(actor))
            .. " at " .. where .. " is on a placed AI_PatrolPath (" .. tostring(path)
            .. "); idle-patrol suppression will not hold it in place",
            SETTINGS.DEBUG_NPC_ACTIONS)
    end)

    return ok
end

-- True once AVU.SetNoPatrol has pinned this NPC. A scripted wander (the Warden Eye) bypasses the
-- native patrol gate, so it has to ask.
function AVU.IsNoPatrol(actor)
    if Utils.IsActorInvalid(actor) then return false end
    local held = false
    pcall(function()
        local c = actor.NPC_Controller
        if IsNotValid(c) then c = actor:GetController() end
        if IsNotValid(c) then return end
        held = (tonumber(c.PatrolFrequency) or 0) >= NO_PATROL_FREQ
    end)
    return held
end


-- [AUTHORITY] Give an NPC a STANDING destination via the native point-of-interest channel - the
-- same one the AI Director uses to march assault NPCs to the base bench.
-- `LocationOfInterest` feeds the controller's move-to-it call, and the shared BT task RE-ARMS it on
-- every investigate reset while the vector is non-zero. So one write is a standing order: combat
-- interrupts the walk, then the NPC resumes on its own. No Lua ticking.
--   * It is the investigate-a-sound branch, so the NPC WALKS and real perception overrides it.
--   * NO auto-clear on arrival - the NPC loiters at the point. Clear it with loc = nil.
--   * The controller's own read is a ONE-SHOT ~2s after possession, so a late write needs the kick -
--     we always call MoveToLocationOfInterest ourselves (a blackboard write, drain-safe).

function AVU.SetPointOfInterest(actor, loc)
    if Utils.IsActorInvalid(actor) then return false end

    local ok = false
    pcall(function()
        local v = actor.LocationOfInterest
        if loc then v.X, v.Y, v.Z = loc.X, loc.Y, loc.Z
        else v.X, v.Y, v.Z = 0, 0, 0 end
        ok = true
    end)
    if not ok then return false end

    if loc then
        pcall(function()
            local c = actor.NPC_Controller
            if IsNotValid(c) then c = actor:GetController() end
            if IsValid(c) then c:MoveToLocationOfInterest() end
        end)
    end
    return true
end


-- [AUTHORITY] Stop an NPC's Behavior Tree via the controller's BrainComponent. Returns true if it
-- stopped a live brain.
--   * HALTS all native BT-driven behaviour - attack SELECTION, movement and targeting - so a variant
--     can fully SCRIPT the actor (turrets, bespoke behaviour) instead of fighting the BT. You can't
--     cancel the BP attack events, and destroying their projectiles is whack-a-mole.
--   * The pawn still takes damage and dies normally (the game itself stops logic on death).
--   * ONE call is PERMANENT: the Abiotic controllers run their tree once at possess and never
--     restart it, so no re-assert is needed - just retry until it returns true (the brain must
--     exist first).
--   * Pair it with your OWN targeting, facing and attack.

function AVU.StopBehaviorTree(actor)
    if Utils.IsActorInvalid(actor) then return false end
    local stopped = false
    pcall(function()
        local c = actor.NPC_Controller
        if IsNotValid(c) then c = actor:GetController() end
        if IsValid(c) and IsValid(c.BrainComponent) then
            c.BrainComponent:StopLogic("AnteUp_Scripted")
            stopped = true
        end
    end)
    return stopped
end


-- [AUTHORITY] Hand a stopped brain back to its own tree. Returns true if a brain was there to
-- restart.
--   * The counterpart to StopBehaviorTree, for a lockdown that is a WINDOW rather than a takeover:
--     a scripted move that can legitimately fail to start needs a way back, or the body stands
--     there forever with no tree and no script (the Mad Rat's kamikaze bail).
--   * RestartLogic re-runs the tree from its root, so blackboard state survives but any in-flight
--     task does not - call it when nothing scripted is still running.

function AVU.StartBehaviorTree(actor)
    if Utils.IsActorInvalid(actor) then return false end
    local started = false
    pcall(function()
        local c = actor.NPC_Controller
        if IsNotValid(c) then c = actor:GetController() end
        if IsValid(c) and IsValid(c.BrainComponent) then
            c.BrainComponent:RestartLogic()
            started = true
        end
    end)
    return started
end


-- [AUTHORITY] SWAP an NPC's Behavior Tree at runtime (the live equivalent of pak-editing a
-- controller's BT).
--   * controller:RunBehaviorTree(newBT) stops the current tree and runs the new one (rebuilding
--     the blackboard from the new BT's default BB asset).
--   * COMPATIBILITY: the new BT's tasks/services/keys must match what this controller + pawn
--     provide - safest within a FAMILY that shares a blackboard (e.g. the robots: BT_Main_Robot /
--     _Containment / _Corrupt / _Defense). Cross-family swaps may no-op or misbehave.
--   * `btPath` is a /Game BehaviorTree path; it's async-loaded then run.

function AVU.RunBehaviorTree(actor, btPath, onDone)
    if Utils.IsActorInvalid(actor) or not btPath then return end
    ASSETS.LoadAsync({ btPath }, function(results)
        if Utils.IsActorInvalid(actor) then return end
        local bt = results and results[btPath]
        if IsNotValid(bt) then LogBad("RunBehaviorTree - BT failed to load: " .. tostring(btPath)); return end
        local ok = false
        pcall(function()
            local c = actor.NPC_Controller
            if IsNotValid(c) then c = actor:GetController() end
            if IsValid(c) then c:RunBehaviorTree(bt); ok = true end
        end)
        if onDone then pcall(onDone, ok) end
    end)
end


-- [AUTHORITY - the multicast reaches clients] Kill an NPC and mark it as dead (All_PerformDeathSequence())
--   * Flipping IsDead will T-pose the body
--   * No-op on invincible or dead npcs
--   * All_ (visual only) rather than Server_PerformDeathSequence so the corpse is NOT
--     faded/despawned - the body stays put (e.g. for a cutscene drop).

function AVU.KillNpc(actor)
    if Utils.IsActorInvalid(actor) then return end
    local dead = false
    pcall(function() dead = actor.IsDead end)
    if dead then return end
    pcall(function() if actor.Invincible then dead = true end end)
    if dead then return end

    pcall(function()
        actor.IsDead = true
        Utils.MarkReplicatedDirty(actor, "IsDead")
        actor:OnRep_IsDead()
    end)
    -- The ragdoll lives here (fall-to-ground + delayed impulse); without it the mesh T-poses.
    pcall(function() actor:All_PerformDeathSequence() end)
end


-- [AUTHORITY] Start this NPC's OWNING-SPAWNER respawn cooldown, exactly as a real kill would.
--   * The native death path only records the cooldown deep inside Server_PerformDeathSequence
--     (-> AIDirectorSubsystem:RefreshCooldownOnOwningSpawner). A plain K2_DestroyActor is a
--     STREAM-OUT to the director, not a kill, so the cooldown never starts and the spawner just
--     re-pops another one straight away (see [[anteup2-spawner-count-streaming]]).
--   * Call this when you REMOVE a spawner NPC yourself but want the game to treat it as
--     defeated - e.g. the Warden Eye vanishing after it breaches.
--   * Must run while the actor is still VALID and still linked to its spawner (BEFORE the destroy).

function AVU.RefreshSpawnerCooldown(actor)
    if not Utils.IsAuthority() or Utils.IsActorInvalid(actor) then return end
    local dir = Utils.GetAIDirector()
    if IsNotValid(dir) then return end

    -- Players near the actor. The native call passes a distance-sorted list (the director uses it to
    -- pace the post-kill respawn); a plain list of live players is enough for our purposes.
    local near = {}
    local gs = STATE.GameState
    local players = gs and gs.PlayerCharacterInGame
    if players then
        for i = 1, #players do
            if IsValid(players[i]) then near[#near + 1] = players[i] end
        end
    end

    pcall(function() dir:RefreshCooldownOnOwningSpawner(actor, actor, near) end)
end


-- Strip a buff/debuff off `actor` now and again over a short window.
--   * The native lunge-stun (Debuff_Zapped) lands a moment AFTER our damage hook fires, so a
--     single immediate strip misses it - re-strip across ~0.5s so the victim only flickers
--     instead of locking up.
--   * Doubles as "debuff resist" (a freeze still lands but is shed fast).
--   * delays defaults to {200, 450} (ms).
--   * Each strip first checks the buff is actually there: a RemoveBuff is a by-path walk, and
--     callers run this on every hit they deal, mostly against a victim that has nothing to shed.

local function stripIfPresent(actor, buffName)
    if Utils.IsActorValid(actor) and Utils.ActorHasBuff(actor, buffName) then
        Utils.RemoveBuff(actor, buffName)
    end
end

function AVU.StripBuffSoon(actor, buffName, delays)
    if not Utils.IsActorValid(actor) then return end
    stripIfPresent(actor, buffName)
    for _, ms in ipairs(delays or { 200, 450 }) do
        Utils.QueueWork(function() stripIfPresent(actor, buffName) end, ms)
    end
end


-- Pest leap velocity is tuned for Apocalyptic (difficulty 3). Every mutated pest variant now
-- LEAPS Apocalyptic on any difficulty - CombatHooks' registerPestApocLeapHook forces the leap's
-- ApocalypticAbilitiesEnabled check true (override launch, 700 hop, 0.2s windup) - so there is no
-- sub-Apocalyptic shortfall left to compensate. Kept as the single lever: if that hook is ever
-- removed, this goes back to `Utils.GetDifficulty() >= 3 and 1 or 1.4`.

function AVU.PestLeapMult()
    return 1
end


-- =======================================================================
-- Some shortcut
-- =======================================================================
-- [UNUSED] no live callers; dev convenience wrapper.

function AVU.DebugActorProps(actor)
    DebugUtils.PrintActorBones(actor)
    DebugUtils.DumpMaterialParams(actor)
    DebugUtils.PrintActorProps(actor)
end


-- Face `target`, or a bare point with AVU.FaceSpot (yaw-only): body rotation + the matching
-- CONTROL rotation, which is what actually STICKS - actor yaw alone is overwritten by the
-- controller next frame.
--   * NPC actor: controller:SetControlRotation (what NPCSpawn does at spawn).
--   * PLAYER actor: Client_ForceControlRotation (the game's client RPC - turns the
--     camera on the owning client; runs locally on host/SP). Same mechanism as the
--     Exor Displacer swap-face.
-- AUTHORITY. pcall'd throughout (cosmetic-grade; no-ops on missing pieces).

function AVU.FaceSpot(actor, loc)
    if Utils.IsActorInvalid(actor) or not loc then return end
    pcall(function()
        local al = actor:K2_GetActorLocation()
        local face = Utils.RotatorToTarget(FVector(al.X, al.Y, 0), FVector(loc.X, loc.Y, 0))
        actor:K2_SetActorRotation(face, false)
        local c = actor:GetController()
        if IsNotValid(c) then return end
        if Utils.IsPlayer(actor) then
            pcall(function() c:Client_ForceControlRotation(face) end)
        else
            c:SetControlRotation(face)
        end
    end)
end

function AVU.FaceTarget(actor, target)
    pcall(function()
        local tl = target:K2_GetActorLocation()
        local al = actor:K2_GetActorLocation()
        local face = Utils.RotatorToTarget(FVector(al.X, al.Y, 0), FVector(tl.X, tl.Y, 0))
        actor:K2_SetActorRotation(face, false)
        local c = actor:GetController()
        if IsNotValid(c) then return end
        if Utils.IsPlayer(actor) then
            pcall(function() c:Client_ForceControlRotation(face) end)
        else
            c:SetControlRotation(face)
        end
    end)
end


-- [AUTHORITY] The NATIVE turn-to-face - the controller's own TurnToFaceDirection timeline, i.e.
-- what BTT_DoCombatAbility does before an ability. Prefer it over AVU.FaceTarget for anything a
-- player watches turn: FaceTarget is an instant rotation write, this eases round over ~a beat.
--   * It reads the controller's own combat target and no-ops without one, so there is nothing to
--     pass and nothing to validate.
--   * Each call RESTARTS the timeline, so calling it on a tick cadence stalls the turn partway.
--     Drive it off a facing-error test, not off the clock.
-- The one thing that needs it: an NPC held by AVU.HoldGround, which loses combat facing entirely.

function AVU.TurnToTarget(actor)
    if Utils.IsActorInvalid(actor) then return end
    pcall(function()
        local c = actor:GetController()
        if IsValid(c) then c:TurnTowardsTarget(true, false) end
    end)
end


-- Dodge-roll montages (GK Chieftain side-rolls - skeleton-correct on any humanoid soldier).
-- EXPOSED so a def's Assets list can preload them (PlayThirdPersonMontage on a cold montage
-- can blocking-load). The GK BACKSTEP montage is a plain stagger and looks bad, so we only
-- use the two SIDE rolls.
AVU.GK_DODGE_ANIMS = {
    ENUMS.Anims.GK_DODGE_LEFT,
    ENUMS.Anims.GK_DODGE_RIGHT,
}

-- Perform a DODGE ROLL: stop movement + a locked-in-place root-motion side-roll montage
-- (replicated). Chance and per-actor cooldown gated. Preload AVU.GK_DODGE_ANIMS in def.Assets.
--   * Meant for OnDamageTaken - which dispatches from the ProcessDamage HOOK, so the montage is
--     deferred one WorkQueue tick (never play a montage inline in a hook: re-entrant blocking load).
--   * KEYED BY ActorKey, NOT the wrapper: OnDamageTaken hands a FRESH wrapper each hit, so a
--     wrapper-keyed cooldown would never match and it would dodge every hit
--     ([[anteup2-actor-wrapper-identity]]).
--   * opts: Chance (0.33), CooldownTicks (50 ~5s), Rate (1), Dir ("left"/"right"/nil = random, to
--     roll toward a chosen side for circling footwork). Chance 1 + CooldownTicks 0 = an
--     unconditional roll on demand. Returns true if a dodge was committed.
--   * opts.Anim names a montage of your own instead of the GK side pair - a back hop, a base's
--     native backstep clip - and keeps everything else (the lock guard, the deferral, the
--     stop-movement). PRELOAD IT: the play is non-loading, so a cold path is a silent no-op.
local dodgeLastTick = {}   -- fullname -> FAST_TICK (plain table; string keys, bounded by NPC count)

--   * REFUSES while a LOCKED montage is already playing. Two bugs in one: two rolls landing in the
--     same beat played a split-second of the first then snapped to the second (a reflex dodge and a
--     scripted roll can genuinely coincide), and a roll started during a RELOAD would interrupt the
--     reload montage - whose completion delegate is what refills the ammo, so the reload would
--     finish instantly. LockedInPlaceMontage is the native flag for both: PlayThirdPersonMontage
--     writes it from its LockInPlace arg, and Broadcast_ReloadWeapon sets it for the whole reload.
function AVU.DodgeRoll(actor, opts)
    opts = opts or {}
    if Utils.IsActorInvalid(actor) or actor.IsDead then return false end
    local busy = false
    pcall(function() busy = actor.LockedInPlaceMontage == true end)
    if busy then return false end
    local key = Utils.ActorKey(actor)
    if not key then return false end
    local now = STATE.FAST_TICK
    local cd = opts.CooldownTicks or 50
    if now - (dodgeLastTick[key] or -cd) < cd then return false end
    if math.random() > (opts.Chance or 0.33) then return false end
    dodgeLastTick[key] = now

    local animPath = opts.Anim
    if not animPath then
        local idx = (opts.Dir == "left" and 1) or (opts.Dir == "right" and 2)
                 or math.random(#AVU.GK_DODGE_ANIMS)
        animPath = AVU.GK_DODGE_ANIMS[idx]
    end
    Utils.QueueWork(function()
        if Utils.IsActorInvalid(actor) or actor.IsDead then return end
        -- Re-check: the deferred tick is a whole frame later, long enough for a reload or another
        -- roll to have claimed the slot in between.
        local locked = false
        pcall(function() locked = actor.LockedInPlaceMontage == true end)
        if locked then return end
        local anim = ASSETS.GetIfValid(animPath)
        if IsNotValid(anim) then return end
        pcall(function()
            local move = actor.CharacterMovement
            if IsValid(move) then move:StopMovementImmediately() end
            -- (LockInPlace, Montage, HideHeldItem, PlayRate, SecondaryUse)
            actor:PlayThirdPersonMontage(true, anim, false, opts.Rate or 1.0, false)
        end)
    end, 0)
    return true
end

-- =======================================================================
-- TELEPORTING A CHARACTER (player OR NPC) - the two halves of a teleswap
-- =======================================================================

-- An actor's capsule half-height, i.e. how far its ORIGIN sits above its feet. Any point that came
-- from the navmesh / the ground is at the FEET, so it must be lifted by this before you drop an
-- actor's origin on it - otherwise it spawns buried to the waist. `fallback` for a missing capsule.

function AVU.CapsuleHalfHeight(actor, fallback)
    local h
    pcall(function()
        local cap = actor.CapsuleComponent
        if IsValid(cap) then h = tonumber(cap:GetScaledCapsuleHalfHeight()) end
    end)
    return h or fallback or 90
end

-- Can this actor be teleswapped at all? Players and NPCs, yes. Anything else (a deployable, a
-- destructible, a vehicle) - NO: those have their own replicated position channels that would fight
-- or ignore a plain actor move, so we leave them alone rather than half-move them.

function AVU.IsSwappable(actor)
    if Utils.IsActorInvalid(actor) then return false end
    if Utils.IsPlayer(actor) then return true end
    return Utils.GetActorRowName(actor) ~= nil      -- has a DT_NPCList row = it's an NPC
end

-- [AUTHORITY] Move an NPC OFF the drain: a short worker-thread wait, then the game thread, with the
-- body re-found through its departed gate. For a move INTO PLAYER SPACE (onto a player's spot, into a
-- base or a zone volume): a move runs every BeginOverlap at the destination synchronously, and in the
-- drain that wedged twice ([[anteup2-npc-teleport-overlap-freeze]]). A short hop in open space can stay inline.
--   opts.Label         names the move in the freeze crumb
--   opts.Stop          cancel its move order first (TeleportCharacter has the why)
--   opts.OnDone(actor) after the move, on the game thread; not called if the body left
local MOVE_HOP_MS = 50

function AVU.MoveNpcOffHook(actor, loc, rot, opts)
    if Utils.IsActorInvalid(actor) or not loc then return end
    opts = opts or {}
    local getA = Utils.CarryActor(actor)
    local x, y, z = loc.X, loc.Y, loc.Z
    local pitch, yaw, roll = 0, 0, 0
    if rot then pitch, yaw, roll = rot.Pitch or 0, rot.Yaw or 0, rot.Roll or 0 end
    local label = opts.Label or "npc move"

    Utils.DelayedGameThread(MOVE_HOP_MS, function()
        local a = getA()
        if not a then return end
        STATE.LastWork = "OFFHOOK " .. label
        STATE.LastWorkDone = false
        if opts.Stop then
            pcall(function()
                local c = a:GetController()
                if IsValid(c) then c:StopMovement() end
            end)
            pcall(function()
                local move = a.CharacterMovement
                if IsValid(move) then move:StopMovementImmediately() end
            end)
        end
        pcall(function()
            a:K2_SetActorLocationAndRotation(FVector(x, y, z), FRotator(pitch, yaw, roll), false, {}, true)
        end)
        STATE.LastWorkDone = true
        if opts.OnDone then pcall(opts.OnDone, a) end
    end)
end


-- Teleport ANY character to `loc` facing `rot`. Both halves go off the drain, for different reasons:
--   * PLAYER - must go through Utils.TeleportPlayer, which hops OFF-HOOK (EIGT). A player teleport
--     engages level-streaming / freeze-jail / loading-screen machinery that COLD-LOADS, and doing
--     that from a hook (the WorkQueue drain is one) FREEZES the game - see CLAUDE.md section 2.
--   * NPC - AVU.MoveNpcOffHook: a swap lands it on another character's spot, which is player space.
--     (K2_TeleportTo would refuse when the destination overlaps geometry; we want the swap to land
--     regardless, same as the Exor's own blink, so it is the unconditional set.)
--   * opts.Inline keeps an NPC's move in the drain, for a hop into open space whose caller needs it
--     landed before its next line (the snow pest faces and re-locks from where it arrives).
-- Returns false for anything that isn't swappable.

function AVU.TeleportCharacter(actor, loc, rot, opts)
    if not AVU.IsSwappable(actor) or not loc then return false end
    rot = rot or FRotator(0, 0, 0)

    if Utils.IsPlayer(actor) then
        Utils.TeleportPlayer(actor, loc, rot)       -- off-hook, fire-and-forget
        return true
    end

    -- CANCEL THE IN-FLIGHT MOVE FIRST (opts.Stop). An NPC yanked mid-path keeps running its old move
    -- order and walks straight back toward where it was going (the same async-MoveToLocation trap that
    -- made the Velites Guard "slide around" - see [[anteup2-velites-reentrancy-crash]]). The BT
    -- re-plans from the new spot.
    if not (opts and opts.Inline) then
        AVU.MoveNpcOffHook(actor, loc, rot, { Label = "character swap", Stop = true })
        return true
    end
    pcall(function()
        local c = actor:GetController()
        if IsValid(c) then c:StopMovement() end
    end)
    pcall(function()
        local move = actor.CharacterMovement
        if IsValid(move) then move:StopMovementImmediately() end
    end)
    pcall(function() actor:K2_SetActorLocationAndRotation(loc, rot, false, {}, true) end)
    return true
end

-- Generic "navigable spot WITH line-of-sight to `target`" picker (the Telepest flank logic,
-- generalised - the Groupe Sniper reposition and Frostpack use it).
--   * Random ring candidates in [MinDist, MaxDist] around the target, STRICTLY projected to navmesh,
--     then eye-to-eye LoS-checked.
--   * STRICT projection on purpose: the first version snapped through a helper whose fallbacks
--     return UNPROJECTED fuzz points - and open air has perfect LoS, so the sniper teleported off
--     cliffs. A candidate that doesn't project, or whose floor is further than MaxZDelta from the
--     target's Z, is simply rejected.
--   * Returns an FVector or nil - NO blind fallback; callers decide.
-- opts: Actor (the mover), MinDist=600, MaxDist=1500, Tries=8, EyeZ=60, SnapRadius=250,
--       ProjExtentZ=500, MaxZDelta=400.

function AVU.FindLosPoint(target, opts)
    opts = opts or {}
    if Utils.IsActorInvalid(target) then return nil end
    local tl
    pcall(function() tl = target:K2_GetActorLocation() end)
    if not tl then return nil end

    local navSys = Utils.GetNavSystem()   -- cached; a raw FindFirstOf here is a per-call UObject walk
    local world = Utils.GetWorld()
    if IsNotValid(navSys) or IsNotValid(world) then return nil end

    local minD = opts.MinDist or 600
    local maxD = opts.MaxDist or 1500
    if maxD < minD then maxD = minD end
    local eyeZ = opts.EyeZ or 60
    local maxZ = opts.MaxZDelta or 400
    local snap = opts.SnapRadius or 250
    local projExt = FVector(snap, snap, opts.ProjExtentZ or 500)
    local ignore = opts.Actor and { opts.Actor, target } or { target }
    local to = FVector(tl.X, tl.Y, tl.Z + eyeZ)

    for _ = 1, (opts.Tries or 8) do
        local ang = math.random() * 2 * math.pi
        local d = minD + math.random() * (maxD - minD)
        local cand = FVector(tl.X + math.cos(ang) * d, tl.Y + math.sin(ang) * d, tl.Z)

        local out = FVector()
        local projected = false
        pcall(function()
            projected = navSys:K2_ProjectPointToNavigation(world, cand, out, nil, nil, projExt)
        end)
        if projected and math.abs(out.Z - tl.Z) <= maxZ then
            -- Re-check MinDist on the PROJECTED point: K2_ProjectPointToNavigation can snap the
            -- ring candidate up to SnapRadius TOWARD the target, so a MinDist ring pick can land
            -- well inside it. Horizontal distance on purpose (Z is already capped by MaxZDelta).
            local dx, dy = out.X - tl.X, out.Y - tl.Y
            if dx * dx + dy * dy >= minD * minD then
                local from = FVector(out.X, out.Y, out.Z + eyeZ)
                if not AVU.IsPathBlocked(opts.Actor or target, from, to, ignore) then
                    return FVector(out.X, out.Y, out.Z)
                end
            end
        end
    end
    return nil
end

-- =======================================================================
-- MoveOrder / KiteFrom - the scripted-maneuver pair. (The third line every maneuver needs,
-- "turn and look at it", is AVU.FaceTarget further down this file.)
-- =======================================================================

-- [AUTHORITY] "Walk there" - the plain AAIController move order, with the argument list that was
-- being copied verbatim to a dozen call sites (accept radius, then usePathfinding / allowPartial /
-- projectGoal / canStrafe / filter / allowPartialPath).
--   * EVERY CALL RESTARTS PATH FOLLOWING, which is what makes a re-issued order at tick rate read
--     as jitter (the Rook lesson) - so throttle the CALLER, don't call this per tick.
--   * A pathfind is not free either; one order per couple of seconds is the house cadence.
--   * `accept` (default 60) is how close counts as arrived. Widen it for a loose "get over there".
-- Returns true if the order went out.

function AVU.MoveOrder(actor, dest, accept)
    if Utils.IsActorInvalid(actor) or not dest then return false end
    local sent = false
    pcall(function()
        local c = actor:GetController()
        if IsNotValid(c) then return end
        c:MoveToLocation(dest, accept or 60, true, true, true, true, nil, true)
        sent = true
    end)
    return sent
end


-- [AUTHORITY] THE KITE: back out to a navmesh point that can still SEE the target, and walk there.
-- The shared shape behind the Signifer's retreat, the Velites Guard's backoff and the DarkLens
-- Phyter's shield-break reposition.
--
-- NAVMESH-ONLY BY DEFAULT, and that is the important half: FindLosPoint is strict precisely because
-- the loose version walked NPCs off cliffs, and these arenas are edged. NO POINT FOUND MEANS
-- CORNERED, and cornered should read as "stand and fight", not a blind run - so the default is to
-- do nothing.
--   * opts.MinDist / MaxDist  the LoS band to land in.
--   * opts.Fallback = n       OPT-IN blind retreat: back straight away from the target by n uu
--                             instead. Only for a fight on flat ground with nothing to fall off.
--   * opts.Accept             move-order acceptance radius (60).   opts.Label  log prefix.
-- Returns true if a move order went out.

function AVU.KiteFrom(actor, target, opts)
    if Utils.IsActorInvalid(actor) or Utils.IsActorInvalid(target) then return false end
    opts = opts or {}

    local dest = AVU.FindLosPoint(target, {
        Actor = actor, MinDist = opts.MinDist, MaxDist = opts.MaxDist,
    })

    if not dest and opts.Fallback then
        local aLoc, tLoc
        pcall(function() aLoc = actor:K2_GetActorLocation() end)
        pcall(function() tLoc = target:K2_GetActorLocation() end)
        if aLoc and tLoc then
            local dir = Utils.Direction(tLoc, aLoc)   -- target -> actor, i.e. straight away
            dest = FVector(aLoc.X + dir.X * opts.Fallback, aLoc.Y + dir.Y * opts.Fallback, aLoc.Z)
        end
    end
    if not dest then return false end

    local sent = AVU.MoveOrder(actor, dest, opts.Accept)
    if sent and opts.Label then
        LogDebug(opts.Label .. " - retreating", SETTINGS.DEBUG_NPC_ACTIONS)
    end
    return sent
end


-- =======================================================================
-- PER-ACTOR BOOKKEEPING - the small gates every variant re-implemented
-- =======================================================================

-- Per-actor cooldown gate. Returns TRUE (and stamps) when the gate is open, FALSE while cooling:
--   if not AVU.CooldownReady(swBoltTick, key, SW_FIRE_CD) then return end
--   * THE FIRST CALL FOR A KEY IS FREE by default. opts.FirstDelay makes a key wait that long
--     before its first fire instead (the "start grace" some variants hand-seeded on aggro).
--   * opts.Now overrides the clock; the default is STATE.FAST_TICK, so `cooldown` is in WQ ticks.
--     The few sites that gate in os.clock MILLISECONDS pass both.
--   * opts.Peek tests WITHOUT stamping - needed by any gate that stamps only after a LATER test
--     passes (a chance roll, an alive cap), or the ability silently fires at half rate.
--   * The table is the CALLER'S and this never prunes it: a string key is never collected, so keep
--     clearing it on death/despawn.

function AVU.CooldownReady(tbl, key, cooldown, opts)
    if not tbl or not key then return false end
    opts = opts or {}

    local now = opts.Now or STATE.FAST_TICK
    local last = tbl[key]
    if last == nil then
        if opts.FirstDelay then
            -- Seed AND PERSIST. The write-back is load-bearing: we return false below, which skips
            -- the stamp, so without it the key stays nil, EVERY call re-seeds to the same value,
            -- `now - last` is pinned at (cooldown - FirstDelay), and the gate NEVER OPENS.
            last = now - cooldown + opts.FirstDelay
            tbl[key] = last
        else
            -- No grace: the first call for a key is free. Returned outright, not seeded as
            -- `now - cooldown` - with a fractional cooldown (a level curve, a difficulty scale) that
            -- seed rounds to just under `cooldown` about half the time, stamps nothing, and refuses
            -- every call for as long as FAST_TICK stays in the same power-of-two range.
            if not opts.Peek then tbl[key] = now end
            return true
        end
    end

    if now - last < cooldown then return false end
    if not opts.Peek then tbl[key] = now end
    return true
end

-- Memoized actor fullname, weak-keyed so a collected actor takes its entry with it.
--   GetFullName costs ~9ms in a crowd (S2's hidden-scan family) and a tick needs a key every run.
--   SAFE ONLY FOR A STABLE WRAPPER - an OnTick/Stats actor, which is the same wrapper each call.
--   A hook that hands back a FRESH wrapper per call (ProcessDamage and friends) would miss the memo
--   every time AND grow the cache; use Utils.ActorKey there instead.
local fullNameCache = setmetatable({}, { __mode = "k" })
function AVU.CachedFullName(actor)
    if Utils.IsActorInvalid(actor) then return nil end
    local k = fullNameCache[actor]
    if k then return k end
    local ok, name = pcall(function() return actor:GetFullName() end)
    if not ok or not name then return nil end
    fullNameCache[actor] = name
    return name
end

-- Write a replicated property the way the native decide-paths do: value, dirty, OnRep.
--   ALL THREE WRITES ARE REQUIRED. The visible change usually lives in OnRep_<Prop> (or the
--   construction script), never in the setter - so the BOOL ALONE IS A NO-OP that flips the flag
--   and leaves the mesh on screen. MarkReplicatedDirty is what pushes it (S4 push-model), and on
--   HOST/SP we must call the OnRep ourselves because OnReps are client receivers.
--   Pass opts.SkipOnRep for the rare property whose OnRep does more than we want.

function AVU.SetReplicatedProp(actor, propName, value, opts)
    if Utils.IsActorInvalid(actor) or not propName then return false end
    opts = opts or {}
    return (pcall(function()
        actor[propName] = value
        Utils.MarkReplicatedDirty(actor, propName)
        if not opts.SkipOnRep then actor["OnRep_" .. propName](actor) end
    end))
end


-- =======================================================================
-- SHARED ATTACK PRIMITIVES
-- =======================================================================

-- Loose ONE projectile row through the NPC's native gun, aimed at `aim` (a plain FVector).
--   "The Chieftain trick": every NPC carries a GrenadeData handle, so we repoint that handle at
--   the row we want, fire, and (optionally) put it back. No per-shot LoadAsync, replicates free.
--   * AUTHORITY ONLY - it spawns.
--   * `restoreRow` re-points the handle afterwards; omit it when the swap is meant to be permanent.
--   * Scheduling is deliberately NOT here - bursts, delays and the post-shot
--     AVU.ReleaseSoldierBT / EndAbility_DoCombatReset valve genuinely differ per NPC.

function AVU.FireProjectileRow(actor, row, dmg, aim, restoreRow)
    if not Utils.IsAuthority() then return false end
    if Utils.IsActorInvalid(actor) or actor.IsDead or actor.IsDBNO then return false end

    if aim then pcall(function() actor.LastRangedAttackLocation = aim end) end
    AVU.SetProjectileRow(actor, "GrenadeData", row, true)
    local fired = pcall(function() actor:FireRanged_Projectile(actor.GrenadeData, dmg) end)
    if restoreRow then AVU.SetProjectileRow(actor, "GrenadeData", restoreRow, true) end
    return fired
end

-- Is this damage one of `typeSet`, and is the victim's retaliation off cooldown?
--   Returns the damage-type NAME on success (handy for the log line), nil otherwise - so an
--   OnDamageTaken retaliation collapses to:
--       local hit = AVU.RetaliateGate(victim, damage, dmgType, RETALIATE_TYPES, lastBurstTick, CD)
--       if not hit then return end
--   `typeSet` keys off DamageTypeDisplayName, so one "Sharp" entry covers all ~25 Sharp_* types
--   (S6). Keys the throttle by Utils.ActorKey: ProcessDamage hands back a FRESH wrapper each hit.

function AVU.RetaliateGate(victim, damage, dmgType, typeSet, tbl, cooldown)
    if Utils.IsActorInvalid(victim) then return nil end
    if not damage or damage <= 0 or IsNotValid(dmgType) then return nil end

    local typeName
    pcall(function() typeName = dmgType.DamageTypeDisplayName:ToString() end)
    if not typeName then return nil end
    typeName = typeName:gsub("'", "")           -- Holy's display name ships WITH quote marks (S6)
    if not typeSet[typeName] then return nil end

    local key = Utils.ActorKey(victim)
    if not key or not AVU.CooldownReady(tbl, key, cooldown) then return nil end
    return typeName
end

-- Apply buffs to every PLAYER within `radius` of `loc`. `buffs` = { {Buff = <path>, Secs = n}, ... }.
--   PLAYERS ONLY, BY DESIGN. An NPC-facing version of this is the S6 teardown crash: an NPC's DoT
--   re-enters our ProcessDamage hook from a timer tick, and in a crowd one caught actor is a freed
--   pointer. A player is not a variant, so its pipeline dispatches nothing and cannot cascade.
--   Uses Utils.ApplyBuffLinked - an NPC->player debuff needs the direct Server_ApplyBuff path.

function AVU.BuffPlayersInRadius(loc, radius, buffs)
    if not loc or not buffs then return 0 end

    local gs = STATE.GameState
    local players = gs and gs.PlayerCharacterInGame
    if not players then return 0 end

    local r2, hit = radius * radius, 0
    for i = 1, #players do
        local p = players[i]
        if IsValid(p) then
            local ok, pl = pcall(function() return p:K2_GetActorLocation() end)
            if ok and pl and Utils.DistSq(loc, pl) <= r2 then
                for _, b in ipairs(buffs) do Utils.ApplyBuffLinked(p, b.Buff, b.Secs) end
                hit = hit + 1
            end
        end
    end
    return hit
end


-- =======================================================================
-- SUBMODULE MERGE - the subsystems split out of this file. Each returns a plain table of helpers;
-- we copy them onto AVU so every caller keeps writing AVU.<fn> and no variant file has to know
-- which file a helper lives in.
--
-- ORDER DOESN'T MATTER, but the require CYCLE does: a submodule that needs AVU back must require
-- it LAZILY, inside the function body (by call time everything is loaded). A top-level
-- `require("AnteUtils.AVUtils")` in one of these WILL deadlock the loader.
--
-- ADDING ONE = TWO EDITS: this list, AND the `---@class AVU : ...` inheritance line at the top.
-- The loop is invisible to the language server; that annotation is the only thing that keeps
-- goto-definition working across the merge.
-- =======================================================================
local SUBMODULES = {
    "AnteUtils.AVAttach",      -- attachments & subactors  (Attach* / ConfigureSubActor / ...)
    "AnteUtils.ClientFX",      -- FX onto every machine    (SendClientFX / BroadcastFX / ...)
    "AnteUtils.Spawning",      -- a new actor in the world (SummonVariant / SpawnCloud / ...)
    "AnteUtils.AVAppearance",  -- how it looks and sounds  (TintSlot / SetHelmet / SetMeshOpacity / ...)
    "AnteUtils.AVSenses",      -- AI perception            (SetSightConfig / ReportNoise / ...)
    "AnteUtils.AVShields",     -- body shields + the bubble(AddBodyShield / SetShieldColor / ...)
    "AnteUtils.AVPets",        -- tamed-pet stats          (ScalePetHealth / GetPetLevel / ...)
    "AnteUtils.AVWorldFX",     -- weather & screen tint    (TriggerBlizzard / SetScreenTint / ...)
    "AnteUtils.AVInventory",   -- player inventory writes  (RefreshHotbar / ChargeNearbyItems)
}
for _, path in ipairs(SUBMODULES) do
    for k, v in pairs(require(path)) do AVU[k] = v end
end

return AVU
