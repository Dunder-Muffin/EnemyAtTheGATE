-- =======================================================================
-- HardMode (AUTHORITY) - SETTINGS.MODULES.HARDMODE difficulty toggles.
-- All levers are server-side. Clients need nothing.
--
-- Flags:
--   1. NoAvail    Enemies resist stuns, explosives, base defenses. 8 levers: TypeScale,
--                 Projectiles, Deployables, melee cap, sneak cap, Stuns, Sustain, item rows.
--   2. NoEnd      Respawn cooldowns shortened (native days halved, floor 2; groups and placed).
--   3. NoRetreat  Personal teleporter disabled.
--   4. NoMercy    Harder variants: gates SpawnerData Hard entries, def.HardMode stat blocks and
--                 every variant's own hard-mode branch, plus one weakness stagger per NPC per
--                 window. /auhard and /aunormal flip it live.
--   5. NoReprieve Reserved in SETTINGS. Not wired.
--
-- Full lever-by-lever decode: AnNotes/Modules/HardMode.md.
--
-- Flags are read at WORLD LOAD. Hooks latch for the session. Each hook re-checks
-- the flag at fire time. Turning a flag OFF then /reload goes quiet immediately.
-- Turning a flag ON still needs a relaunch.
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local SETTINGS = require("Settings")
local STATE = require("AnteCore.State")
local Utils = require("AnteUtils.Utils")
local ASSETS = require("AnteCore.AssetManager")
local ENUMS = require("AnteData.Enums")
local SCHEMA = require("AnteData.Schema")
local IM = require("ModuleItems.ItemMods")   -- its weapon tweaks' stun windows ride our hooks; it never requires us

local Log = Utils.Log
local LogBad = Utils.LogBad

local HM = {}

-- All tuning lives in ONE table (the 200-local rule).
-- Damage values are ABSOLUTE. Re-applies must be idempotent. Never prop*k (CLAUDE.md 3).
-- Scales are multipliers applied once per hit in CombatHooks. They are clamped there
-- to >= 1. Never a silent immunity.
local CFG = {

    -- 1. Victim-side scale vs NPCs (STATE.HardModeTypeScale), by DamageType class name.
    TypeScale = {
        -- Flask Megaton: 600 dmg, AoE outer 700, falloff 1.0. A unique class, so this
        -- key nerfs NPCs only.
        DamageType_Explosive_AntiqueShotgun_C = 0.4,

        -- Plain laser damage type. Covers heavy laser (15 per 0.1s tick), energy pistols (normal
        -- mode), laser turret bursts (30/0.2s), laser grenade beams, and puzzle emitters.
        -- Also covers the MageEye_Ally pet's ranged row - a small accepted friendly-fire cost.
        DamageType_Laser_C = 0.75,

        -- Laser guns in OVERDRIVE deal Laser_Gib damage (x3). This is the mode that
        -- matters - without this key the heavy laser's real damage mode escapes the nerf.
        DamageType_Laser_Gib_C = 0.75,

        -- Laser katana. See the VERIFY note in AnNotes/Modules/HardMode.md.
        DamageType_Laser_Gib_Katana_C = 0.5,

        -- Chopinator blades vs non-pests (30/0.5s tick). Vs pests it deals DeathFan
        -- instakill instead, which a multiplier cannot touch. Left alone by design.
        DamageType_SharpFan_C = 0.5,

        -- No Electric key. The tesla coil and the shock trap ARE meant to be nerfed, but
        -- they deal plain Electric_C and Electric_ShockTrap_C, which the player's own
        -- electric weapons also deal - the stun baton, the Tech Sceptre's 25-point bonus,
        -- the Lightning Spear's 30-point chain. A type key cannot tell them apart, and
        -- halving a player's electric melee is not what this lever is for. Both
        -- deployables carry their own damage property instead - see Deployables below.
    },

    -- 2. Explosive-projectile damage caps, keyed by exact class name. A bare number caps
    --    DamageFromWeapon (the blast itself); a table names some other property. Values are
    --    absolute and only ever LOWER what the projectile arrived with - native value in the
    --    trailing comment. A blast's minimum damage follows (the parent uses DamageFromWeapon/2),
    --    and the full number only lands inside AoE_InnerRadius.
    ProjectileDamage = {
        Projectile_Mugnade_C = 125,        -- 350
        Projectile_Grenade_Frag_C = 175,   -- 400
        Projectile_Grenade_Laser_C = 40,   -- 60/beam-tick; its beams are also Laser_C, so
                                           -- NPCs effectively see 40 * 0.75 = 30

        -- 12x75 shards with a small explosion
        Projectile_Electron_Grenade_C = { Prop = "DamagePerProjectile", Value = 30 },  -- 75

        -- ROCKETS. All three extend the frag grenade, so the hook below already sees them. Their
        -- damage is the LAUNCHER row's 1150 (the ammo row only picks the projectile class), so
        -- both keys are a real cut from the same starting number.
        Projectile_Rocket_Standard_C = 500,     -- 1150
        Projectile_Rocket_Penetrator_C = 750,   -- 1150, and it lands as a single point hit: its
                                                -- row turns AreaOfEffectDamage off, so this one
                                                -- has to be aimed and stays the better shot.
        -- No cluster key. It replaces the damage event with its 8 submunitions and never blasts,
        -- and those ARE Projectile_Grenade_Frag_C at 150 each - which the frag key above would
        -- RAISE to 175. The cap-only write is what leaves them at 150.
    },

    -- 3. Deployable damage properties, keyed by exact class name.
    --    Comp is an optional component holding the property. Value is absolute.
    --    A Value stacks with any TypeScale key on what it deals, so it is chosen for the
    --    intended NET result: the turrets' 20 * Laser 0.75 = 15, the wanted half.
    --    Unlike TypeScale these apply to every victim, so a coil or trap also does half
    --    to a player who walks into it. Accepted: they are base defenses, and this is the
    --    only lever that separates them from a player's own electric weapons.
    Deployables = {
        Deployed_Turret_Laser_C = { Comp = "LaserComponent", Prop = "LaserDamage", Value = 20 },    -- 30
        BenchUpgrade_BenchTurret_C = { Comp = "LaserComponent", Prop = "LaserDamage", Value = 20 }, -- 30
        Deployed_TeslaCoil_C = { Prop = "BaseCoilDamage", Value = 50 },        -- 100
        Deployed_ShockTrap_C = { Prop = "TrapInitialDamage", Value = 15 },     -- 30, on the
            -- FloorTrap parent. Its 4s Debuff_ShockTrap is a BuffObject_Stunned_C, so
            -- lever 5 already halves the hold that is most of what the trap is for.
    },

    -- 4. Charged-melee multiplier cap vs NPC victims. Normal swings are 1.0, untouched.
    MeleeMultCap = 1.5,

    -- 4b. Sneak-attack multiplier cap. The Sneak skill's perks double damage against an unaware
    --     target - "Sneak Attack" (level 2) on a 25% roll, doubled to 50% at night by "Night
    --     Worker", and "Office Assassin" (level 15) unconditionally, standing or crouched. It
    --     applies to MELEE AND RANGED alike, and the pipeline's headshot x2 lands on top of it,
    --     so a level-15 player one-shots a 350 HP boss head with a 130-damage bow. This caps the
    --     bonus without touching the headshot or the perk's other uses.
    StealthMultCap = 1.5,

    -- 5. Stun/freeze duration multiplier on NPCs. Examples: slushie 5s, shock trap 4s,
    --    zap 1-2s, blizzard flask 8s. Players keep full durations.
    StunDurationMult = 0.5,

    -- 6. Player-sustain buff rows. In-place DT_BuffsDebuffs edits. The row struct is
    --    NATIVE (FBuffDebuff), so plain float writes are safe. The ITEM tables are
    --    UserDefinedStructs and stay untouched - they only name these rows, and their
    --    own HealthChange is 0. Needs the UE4SS 954+ row API.
    BuffRowEdits = {
        -- Berserker Tincture: the ONLY source of the Buff.Berserker tag. Two readers
        -- use that tag to floor head HP at 1 and suppress death, so the duration IS
        -- the invulnerability window. (+20% dmg/speed ride the same row.)
        Buff_Tincture_Berserker = { DefaultDuration = 15.0 },  -- 60

        -- Restorative Tincture: the same 3hp/tick buff object as the syringe. Tick
        -- RATE is their only difference (0.2s vs 0.5s), so rate is the surgical field.
        -- 1/3s -> ~9 hp/s (was 15). Still 1.5x a syringe.
        Buff_Tincture_Healing = { BuffTickRate = 0.33 },     -- 0.2

        -- Carrot cake slice: 30hp x 6 ticks (0.5s rate, 3.1s duration) = 180 total.
        -- The 30 lives on a CDO shared by 6 rows, so duration (= tick count) is the
        -- surgical lever. 4 ticks = 120 total, matching the requested 20/tick.
        Buff_RapidHealthRegen_T2 = { DefaultDuration = 2.1 },  -- 3.1
    },

    -- 7. Weapon damage on the item row (WeaponData.DamagePerHit, ItemTable_Global). Re-read from
    --    the row on every shot, so an edit is live for a weapon already in a backpack, and it is
    --    also what the tooltip prints. Absolute values; native in the trailing comment.
    --    Unlike TypeScale this hits PLAYERS too, but only as a victim of the same weapon.
    --    ModuleElemental writes this same field on ITS rows. A row must never be named in both:
    --    they run at different points in InitMod, so the winner would be decided by call order.
    ItemDamage = {
        -- The magbows. Both fire DamageType_Sharp_RebarBolt, so a TypeScale key would also catch
        -- the plain crossbows that share it - and the row is what separates the tiers anyway.
        -- Picked out because, unlike the sniper rifles they rival, their ammo is cheap.
        crossbow_science   = 90,    -- 120
        crossbow_magbow_U1 = 130,   -- 170
    },

    -- NoMercy: at most one weakness forced-stagger per NPC per window, any source. ItemMods'
    -- ElectroThrower_LongThrow reuses it for that gun's hits when NoMercy is off.
    WeakStaggerWindowMs = 3000,
}

-- Hook / class paths. Grenade and player paths are duplicated from CombatHooks and
-- main.lua on purpose. A require for just two strings would be heavier coupling than
-- the copy.
local GRENADE_PARENT_CLASS = "/Game/Blueprints/Projectiles/Projectile_Grenade_ParentBP.Projectile_Grenade_ParentBP_C"
local GRENADE_BEGINPLAY_HOOK = GRENADE_PARENT_CLASS .. ":ReceiveBeginPlay"
local PLAYER_CLASS = "/Game/Blueprints/Characters/Abiotic_PlayerCharacter.Abiotic_PlayerCharacter_C"
local MELEE_RPC_HOOK = PLAYER_CLASS .. ":Request_MeleeAttackDamage"
local STEALTH_HOOK   = PLAYER_CLASS .. ":CheckForStealthAttackBonusDamage"
local SWING_MULT_HOOK = PLAYER_CLASS .. ":Get Instant Kill Damage"
local STUN_APPLY_HOOK = ENUMS.BuffObjects.Stunned .. ":Server_OnBuffApply"
local DEPLOYABLE_PATHS = {
    "/Game/Blueprints/DeployedObjects/Misc/Deployed_Turret_Laser.Deployed_Turret_Laser_C",
    "/Game/Blueprints/DeployedObjects/Furniture/BenchUpgrades/BenchUpgrade_BenchTurret.BenchUpgrade_BenchTurret_C",
    "/Game/Blueprints/DeployedObjects/Furniture/Deployed_TeslaCoil.Deployed_TeslaCoil_C",
    "/Game/Blueprints/DeployedObjects/Furniture/Deployed_ShockTrap.Deployed_ShockTrap_C",
}
local BUFF_DT_PATH = "/Game/Blueprints/DataTables/BuffsDebuffs/DT_BuffsDebuffs.DT_BuffsDebuffs"
local ITEM_DT_PATH = "/Game/Blueprints/Items/ItemTable_Global.ItemTable_Global"

-- Duplicated from ModuleElemental for the same reason as the hook paths above.
local DAMAGE_PATH = SCHEMA.Item.WeaponData .. "." .. SCHEMA.Weapon.DamagePerHit
local TELEPORTER_CLASS = "/Game/Blueprints/Items/MiscPickups/Item_Teleporter_ParentBP.Item_Teleporter_ParentBP_C"
local TELEPORTER_COST_OFF = 999   -- max battery is 100; anything above it = never usable

local armed = {}    -- once-per-session latches. Hooks and NotifyOnNewObject can't unregister.
local logged = {}   -- one-line self-reports. Each lever logs once, so a dead lever
                    -- is diagnosable from silence (the petSpecial pattern).


-- Is a hard-mode flag on? Reads SETTINGS live. Nil-safe for an older SETTINGS.lua.
function HM.On(flag)
    local hm = SETTINGS.MODULES and SETTINGS.MODULES.HARDMODE
    return (hm and hm[flag]) == true
end


-- [DEBUG] Flip NoMercy live - the /auhard and /aunormal chat commands, for A/B-ing a variant's
-- normal vs hard behaviour without relaunching.
--   * NoMercy is the ONE flag that can switch mid-session: it arms no hooks and edits no buff
--     rows, it is only ever READ, and every reader checks STATE.HardModeNoMercy at fire time.
--     The other four latch work at world load and would need Register to re-run.
--   * Ability TIMING changes on the next beat. STATS do not: def.HardMode is merged once, at
--     mutation, so already-mutated bodies keep what they were built with - respawn to see those.
--   * Not persisted. SETTINGS.lua still decides what the next launch starts as.
function HM.SetNoMercy(on)
    local hm = SETTINGS.MODULES and SETTINGS.MODULES.HARDMODE
    if hm then hm.NoMercy = on and true or false end
    STATE.HardModeNoMercy = on and true or nil
    Log("HardMode - NoMercy " .. (on and "ON (hard)" or "OFF (normal)")
        .. " [debug switch; respawn NPCs for the stat half]")
end


-- =======================================================================
-- NoAvail levers
-- =======================================================================

-- 2. Grenade-family BeginPlay: rewrite the damage property for the classes in CFG.
--    POST hook - the value is consumed at Detonate, well after BeginPlay.
--    Mugnade, frag, megaton flask, laser grenade and electron grenade all extend
--    Projectile_Grenade_ParentBP (flasks via Projectile_Flask_Parent). Only the
--    laser grenade overrides ReceiveBeginPlay, and it Super-calls it, so one hook
--    covers them all.
local function onGrenadeSpawn(self)
    if not STATE.ModEnabled or not HM.On("NoAvail") then return end
    local proj = self:get()
    if Utils.IsActorInvalid(proj) then return end

    local ok, cname = pcall(function() return proj:GetClass():GetFName():ToString() end)
    local spec = ok and cname and CFG.ProjectileDamage[cname]
    if not spec then return end

    -- PLAYER throws only - this lever is about what a player's explosives do to NPCs, so a
    -- Grunt's barrage keeps the damage its def authored.
    -- WasThrown cannot make that call: the native throw path sets it on the deferred spawn,
    -- so it already reads true here for a player's grenade as well as for a PROJ.Queue lob.
    local thrower
    pcall(function() thrower = proj.Instigator end)
    if not Utils.IsPlayer(thrower) then
        local npcKey = "proj.npc." .. cname
        if not logged[npcKey] then
            logged[npcKey] = true
            Log("HardMode - NoAvail: " .. cname .. " thrown by a non-player - left at native damage")
        end
        return
    end

    local prop = (type(spec) == "table" and spec.Prop) or "DamageFromWeapon"
    local want = (type(spec) == "table" and spec.Value) or spec

    -- A CAP, not a rewrite: the spawner has already written the real number by now (every native
    -- path sets it on the deferred spawn), and some of it is a nerf of its own - a cluster
    -- rocket's frags arrive at 150, well under the 175 the frag key asks for. Lowering only means
    -- this lever can never hand a weapon damage back.
    local have
    pcall(function() have = proj[prop] end)
    if type(have) ~= "number" or have <= want then return end

    local okSet = pcall(function() proj[prop] = want end)
    if okSet and not logged[cname] then
        logged[cname] = true
        Log(("HardMode - NoAvail: %s.%s %d -> %d"):format(cname, prop, have, want))
    end
end

-- Resolve the struck actor from the melee RPC's FHitResult param. Two strategies:
-- first the param:get() struct through AFUtils' GetActorFromHitResult, then the raw
-- param (some UE4SS builds forward struct field access on it directly).
-- Returns nil if nothing valid resolved.
local function meleeHitVictim(Hit)
    local victim
    pcall(function() victim = GetActorFromHitResult(Hit:get()) end)   -- AFUtils global
    if victim and Utils.IsActorValid(victim) then return victim end
    victim = nil
    pcall(function() victim = GetActorFromHitResult(Hit) end)
    if victim and Utils.IsActorValid(victim) then return victim end
    return nil
end

-- 4. Charged-melee cap vs NPC victims, at the SOURCE. `Get Instant Kill Damage(mult, sharp,
--    HitActor)` returns the multiplier the swing hands to Request_MeleeAttackDamage, so it runs
--    where the swing runs (the host, or the swinging client) and before any damage exists.
--   * A local call, so the callback fires after the body - and a value the callback RETURNS
--     overwrites the function's result (UE4SS script_hook). That is the whole lever.
--   * Skips anything at or under the cap, and the InstaKill perk's 350x. The perk's 1% roll happens
--     inside the body, out of sight, so a CHARGED swing that rolled it is capped too; an uncharged
--     swing keeps the perk.
local function onSwingMult(self, OriginalDamage, _sharp, HitActor)
    if not STATE.ModEnabled or not HM.On("NoAvail") then return nil end

    local mult = OriginalDamage and OriginalDamage:get()
    if type(mult) ~= "number" or mult <= CFG.MeleeMultCap or mult >= 100 then return nil end

    local victim = HitActor and HitActor:get()
    if IsNotValid(victim) then return nil end
    local isNpc = false
    pcall(function() isNpc = IsValid(victim.NPCData) end)
    if not isNpc then return nil end   -- players / props / deployables keep full charge damage

    if not logged.meleeCap then
        logged.meleeCap = true
        Log(("HardMode - NoAvail: charged melee %.2fx -> %sx vs NPC"):format(mult, CFG.MeleeMultCap))
    end
    return CFG.MeleeMultCap
end

-- The callback's return value is the lever, so it can't sit behind a bare pcall (which eats it).
local function swingMultHook(...)
    local ok, v = pcall(onSwingMult, ...)
    if ok then return v end
end

-- 4 (backstop). The same cap on the RPC itself, for a swing whose machine did not cap it (its own
--    settings lack NoAvail). It only takes where the RPC is dispatched ahead of its body - a
--    dedicated server receiving it; on a host the local call runs the body first and this is
--    too late. So its line means the SOURCE cap missed, and says so.
local function onMeleeRpc(self, Hit, Unarmed, DamageMultiplier, ForceDurabilityLoss, Offhand)
    if not STATE.ModEnabled or not HM.On("NoAvail") then return end

    local mult = DamageMultiplier and DamageMultiplier:get()

    -- Stage trace (DEBUG_NPC_ACTIONS): fires per swing, names what arrived. If this
    -- line never prints, the hook isn't firing and the RPC path itself is wrong.
    if SETTINGS.DEBUG_NPC_ACTIONS then
        local windup = "?"
        pcall(function() windup = tostring(ForceDurabilityLoss:get()) end)
        Utils.LogDebug(("HardMode - melee RPC: mult=%s windup=%s")
            :format(tostring(mult), windup), true)
    end

    if type(mult) ~= "number" or mult <= CFG.MeleeMultCap then return end
    if mult >= 100 then return end   -- the InstaKill perk's 350x sentinel - a perk, not a charge

    local victim = meleeHitVictim(Hit)
    if not victim then
        -- A charged swing we could not victim-check. Logged once, loudly - an
        -- unresolved victim must never fail silently.
        if not logged.meleeMiss then
            logged.meleeMiss = true
            LogBad(("HardMode - charged swing (%.2fx) but FHitResult victim UNRESOLVED - cap not applied"):format(mult))
        end
        return
    end

    -- The hit handle resolves to the struck COMPONENT, not the actor.
    -- Map the component to its owning actor before the NPC test.
    local isNpc = false
    pcall(function() isNpc = IsValid(victim.NPCData) end)
    if not isNpc then
        pcall(function()
            local owner = victim:GetOwner()
            if owner and IsValid(owner.NPCData) then
                victim = owner
                isNpc = true
            end
        end)
    end
    if SETTINGS.DEBUG_NPC_ACTIONS then
        local cname = "?"
        pcall(function() cname = victim:GetClass():GetFName():ToString() end)
        Utils.LogDebug(("HardMode - charged swing victim %s npc=%s"):format(cname, tostring(isNpc)), true)
    end
    if not isNpc then return end   -- players / props / deployables keep full charge damage

    local okSet = pcall(function() DamageMultiplier:set(CFG.MeleeMultCap) end)
    if not logged.meleeRpcUncapped then
        logged.meleeRpcUncapped = true
        LogBad(("HardMode - NoAvail: a charged swing reached the melee RPC at %.2fx (source cap missed);"
            .. " rewritten to %sx%s"):format(mult, CFG.MeleeMultCap, okSet and "" or "  *** SET FAILED ***"))
    end
end

-- 4b. Sneak-attack cap. CheckForStealthAttackBonusDamage is a LOCAL call, so the input is
--     already spent by the time we see it - the OUT param is the seam (CLAUDE.md hook facts).
--     Clamps DOWNWARD only, which is what makes it safe on both callback slots: a PRE call sees
--     whatever was in the out slot before the body ran and can only ever leave it alone.
--     Covers melee and ranged, since both damage paths call this one function.
local function onStealthBonus(self, BaseDamage, HitTarget, ReceivedBonus, TotalDamage)
    if not STATE.ModEnabled or not HM.On("NoAvail") then return end

    local base = BaseDamage and BaseDamage:get()
    local total = TotalDamage and TotalDamage:get()
    if type(base) ~= "number" or type(total) ~= "number" or base <= 0 then return end

    local cap = base * CFG.StealthMultCap
    if total <= cap then return end

    local okSet = pcall(function() TotalDamage:set(cap) end)
    -- Per hit when debugging: a capped sneak (1.5x) and a headshot (2x, applied later) look alike.
    Utils.LogDebug(("HardMode - sneak hit %.0f -> %.0f"):format(total, cap), SETTINGS.DEBUG_NPC_ACTIONS)
    if not logged.stealthCap then
        logged.stealthCap = true
        Log(("HardMode - NoAvail: sneak bonus %.0f -> %.0f (%.2fx cap on a %.0f base)%s")
            :format(total, cap, CFG.StealthMultCap, base, okSet and "" or "  *** SET FAILED ***"))
    end
end


-- One-line-per-outcome self report. This lever fails silently - the NPC just keeps
-- its vanilla duration and nothing complains. Every exit now names itself once, so
-- "no line at all" means the hook never fired.
local function stunNote(key, msg)
    if logged[key] then return end
    logged[key] = true
    Log("HardMode - stun: " .. msg)
end

-- 5. Stun/freeze duration on NPCs. BuffObject_Stunned_C or a subclass Super-calls
--    this UFunction, so one hook covers the whole family. No cold-load - the call
--    touches no assets.
--
--    Both callback slots get this body on purpose. A post-only registration shipped
--    silently dead (see AnNotes/Modules/HardMode.md). The write is absolute: BuffDuration *
--    StunDurationMult, with BuffDuration itself untouched. So double-firing pre+post
--    is free. Never make this a read-multiply of remaining time (CLAUDE.md 3) - that
--    would compound to a quarter duration.
--
--    ItemMods' LongThrow zap window is decided here too, in the same single write: a
--    second hook on this UFunction would race this one's absolute write, and whichever
--    ran last would win.
local function onStunApply(self, Character, phase)
    if not STATE.ModEnabled then return end
    local noAvail = HM.On("NoAvail")
    local zapWindow = IM.LongThrowOn()
    if not noAvail and not zapWindow then return end

    local buff = self:get()
    if not buff or not IsValid(buff) then return end

    local cname = "?"
    pcall(function() cname = buff:GetClass():GetFName():ToString() end)

    local char = Character and Character:get()
    if Utils.IsActorInvalid(char) then
        stunNote("stun.nochar." .. cname, cname .. " fired with no valid victim")
        return
    end

    local isNpc = false
    pcall(function() isNpc = IsValid(char.NPCData) end)
    if not isNpc then
        -- Not a fault: players keep full durations on purpose. Said once so a player-side
        -- freeze can't be mistaken for the lever being broken.
        stunNote("stun.player", cname .. " on a PLAYER - left at full duration by design")
        return
    end

    local dur
    pcall(function() dur = buff.BuffDuration end)
    if type(dur) ~= "number" or dur <= 0 then
        stunNote("stun.nodur." .. cname,
            cname .. " BuffDuration reads " .. tostring(dur) .. " at apply - nothing to retime")
        return
    end

    local cut = zapWindow and IM.ZapCut(buff, char)
    local newDur = cut or (noAvail and dur * CFG.StunDurationMult) or dur
    if newDur == dur then return end   -- LongThrow alone, zap let through: native duration

    -- Out-param UFunction. The second arg MUST be a table, or UE4SS errors and the
    -- pcall eats it silently (CLAUDE.md 3).
    local okSet = pcall(function() buff:Server_UpdateRemainingTime(newDur, {}) end)

    -- Keyed by CLASS and CALLBACK SLOT. The class half confirms the freeze family
    -- lands too - a shared latch would let the first net eat the only log line. The
    -- slot half records which of pre/post this build actually delivers, so the next
    -- similar lever can be written knowing the answer instead of guessing it.
    local logKey = "stun." .. (cut and "zapcut." or "") .. cname .. "." .. tostring(phase)
    if not logged[logKey] then
        logged[logKey] = true
        if cut then
            Log(("ItemMods - ElectroThrower_LongThrow: zap inside the window refused %.1fs -> %.2fs [%s]%s")
                :format(dur, newDur, tostring(phase), okSet and "" or "  *** CALL FAILED ***"))
        else
            Log(("HardMode - NoAvail: NPC stun %s %.1fs -> %.1fs [%s]%s")
                :format(cname, dur, newDur, tostring(phase), okSet and "" or "  *** CALL FAILED ***"))
        end
    end
end

-- NoMercy's weakness window, and LongThrow's for its own hits. A weakness proc (14% per hit on a
-- weak body) is a FORCED stagger: it skips the stamina pool, RecentlyStaggered and StaggerCooldown,
-- and the engine re-derives the flag on every hit with no cooldown of its own - Tarasque, Snowman
-- and the Shadow boss are the only classes that opt out. One proc per victim per window keeps its
-- stagger; the rest keep their x1.15 and lose the stagger. CombatHooks calls this on weak hits
-- only, through STATE.WeaknessStaggerGate.
local weakStaggerAt = {}   -- ActorKey -> NowMs of the last proc let through

local function weaknessGate(victim, attacker, damageType)
    local generic = STATE.HardModeNoMercy
    if not generic and not IM.IsLongThrowHit(attacker, damageType) then return false end

    local key = Utils.ActorKey(victim)
    if not key then return false end
    local now = Utils.NowMs()
    local last = weakStaggerAt[key]
    if last and now - last < CFG.WeakStaggerWindowMs then
        local logKey = generic and "weak.nomercy" or "weak.longthrow"
        if not logged[logKey] then
            logged[logKey] = true
            Log(("%s: weakness stagger dropped on %s (one per %ds)")
                :format(generic and "HardMode - NoMercy" or "ItemMods - ElectroThrower_LongThrow",
                    tostring(Utils.GetActorName(victim)), CFG.WeakStaggerWindowMs / 1000))
        end
        return true
    end

    for k, t in pairs(weakStaggerAt) do
        if now - t >= CFG.WeakStaggerWindowMs then weakStaggerAt[k] = nil end
    end
    weakStaggerAt[key] = now
    return false
end

-- 3. Deployable damage writes - absolute, idempotent, safe to re-run on the same actor.
local function tuneDeployable(actor)
    if Utils.IsActorInvalid(actor) then return end
    local ok, cname = pcall(function() return actor:GetClass():GetFName():ToString() end)
    local spec = ok and cname and CFG.Deployables[cname]
    if not spec then return end   -- exact-class match: Deployed_Turret_Laser_AUTO (world-placed) stays native

    local okSet = pcall(function()
        local target = spec.Comp and actor[spec.Comp] or actor
        target[spec.Prop] = spec.Value
    end)
    if okSet and not logged[cname] then
        logged[cname] = true
        Log("HardMode - NoAvail: " .. cname .. "." .. spec.Prop .. " -> " .. spec.Value)
    end
end

-- 6. Sustain buff-row edits. REGISTER-TIME ONLY - GetDataTable with load=true can
--    block, so never call this from a hook or a drain. dt:FindRow takes a STRING
--    row name, not an FName (an FName arg is a native AV, see TraderUtils). It
--    returns a LIVE, mutable row. Writes are plain floats on a native struct, so
--    they are idempotent. The DT asset can reload across worlds, so this
--    re-applies every world.
local function applyBuffRowEdits()
    local dt = ASSETS.GetDataTable(BUFF_DT_PATH, true)
    if not dt then
        if not logged.buffDt then
            logged.buffDt = true
            LogBad("HardMode - DT_BuffsDebuffs row API unavailable (UE4SS older than 954?) - sustain nerfs OFF")
        end
        return
    end
    for rowName, fields in pairs(CFG.BuffRowEdits) do
        local row
        pcall(function() row = dt:FindRow(rowName) end)
        if row then
            for field, value in pairs(fields) do
                local was
                pcall(function() was = row[field] end)
                local okSet = pcall(function() row[field] = value end)
                local logKey = rowName .. "." .. field
                if okSet and not logged[logKey] then
                    logged[logKey] = true
                    Log(("HardMode - NoAvail: %s.%s %s -> %s")
                        :format(rowName, field, tostring(was), tostring(value)))
                elseif not okSet then
                    LogBad("HardMode - buff row write FAILED: " .. rowName .. "." .. field)
                end
            end
        else
            LogBad("HardMode - buff row not found: " .. tostring(rowName))
        end
    end
end

-- 7. Weapon item-row damage. Same register-time rules as the buff rows above: GetDataTable
--    can block, and the writes are absolute so re-applying every world is free. Every copy of
--    the row (ASSETS.SetItemRowScalars): an item made through a parent table never reads the
--    composite's copy.
local function applyItemRowEdits()
    if not ASSETS.GetDataTable(ITEM_DT_PATH, true) then
        if not logged.itemDt then
            logged.itemDt = true
            LogBad("HardMode - no DataTable row API on this UE4SS build - weapon nerfs OFF")
        end
        return
    end

    for rowName, value in pairs(CFG.ItemDamage) do
        local tables, was, missed = ASSETS.SetItemRowScalars(rowName, { [DAMAGE_PATH] = value })
        local key = "item." .. rowName
        if missed then
            if not logged["bad." .. key] then
                logged["bad." .. key] = true
                LogBad("HardMode - " .. rowName .. " write FAILED on" .. missed)
            end
        elseif #tables == 0 then
            LogBad("HardMode - item row not found: " .. tostring(rowName))
        elseif not logged[key] then
            logged[key] = true
            Log(("HardMode - NoAvail: %s DamagePerHit %s -> %s (%s)")
                :format(rowName, tostring(was[DAMAGE_PATH]), tostring(value), table.concat(tables, ", ")))
        end
    end
end


-- Per-world sweep for deployables already standing when we arm (save-restored, or
-- placed before InitMod). One FindAllOf per class per world load, not a repeating scan.
local function sweepDeployables()
    for cname in pairs(CFG.Deployables) do
        local ok, found = pcall(FindAllOf, cname)
        if ok and found then
            for _, actor in ipairs(found) do tuneDeployable(actor) end
        end
    end
end

-- Construction watcher for deployables placed after the sweep. Registers once per
-- session - NotifyOnNewObject can't be unregistered. The callback only does
-- QueueWork (pure Lua). The actual write runs later on the clean game-tick drain,
-- after the component tree exists. tuneDeployable re-validates the wrapper there.
local function armDeployableNotify()
    for _, path in ipairs(DEPLOYABLE_PATHS) do
        pcall(NotifyOnNewObject, path, function(obj)
            if not HM.On("NoAvail") then return end
            Utils.QueueWork(function() tuneDeployable(obj) end, 250)
        end)
    end
end


-- =======================================================================
-- NoRetreat - disable the Personal Teleporter (see AnNotes/Modules/HardMode.md). Instance writes only.
-- =======================================================================
local function disableTeleporterItem(item)
    if Utils.IsActorInvalid(item) then return end
    local okSet = pcall(function() item.CostPerUse = TELEPORTER_COST_OFF end)
    if okSet and not logged.teleporter then
        logged.teleporter = true
        Log("HardMode - NoRetreat: PersonalTeleporter CostPerUse -> " .. TELEPORTER_COST_OFF)
    end
end

local function sweepTeleporters()
    local ok, found = pcall(FindAllOf, "Item_Teleporter_ParentBP_C")
    if ok and found then
        for _, item in ipairs(found) do disableTeleporterItem(item) end
    end
end


-- =======================================================================
-- Register - arm the enabled toggles. AUTHORITY-only, called every world load
-- (main.lua InitMod). Hooks latch once per session. Per-world state re-applies
-- every call: the STATE flags, the TypeScale table, the sweeps.
-- =======================================================================
function HM.Register()
    if not Utils.IsAuthority() then return end

    -- World-load flags the engine layer reads (SpawnerHooks / EventUtils / SpawnerData).
    -- Set FIRST: main.lua calls us before SpawnerHooks.ApplySpawnOverrides, so the init
    -- scan already sees them. Early-config spawners processed pre-InitMod are re-covered
    -- by that scan. SD.Resolve's cache epoch folds the NoMercy flag in for the same race.
    STATE.HardModeNoEnd = HM.On("NoEnd") or nil
    STATE.HardModeNoMercy = HM.On("NoMercy") or nil
    if STATE.HardModeNoEnd then Log("HardMode - NoEnd armed (shorter respawn cooldowns)") end
    if STATE.HardModeNoMercy then Log("HardMode - NoMercy armed (SpawnerData Hard entries live)") end

    -- Always published: NoMercy flips live (/auhard) and the gate re-reads it per hit.
    STATE.WeaknessStaggerGate = weaknessGate

    -- NoRetreat: kill already-held teleporters now. The construction notify catches
    -- every later equip - a held item is an ACTOR, spawned fresh per equip.
    if HM.On("NoRetreat") then
        sweepTeleporters()
        if not armed.NoRetreat then
            armed.NoRetreat = true
            pcall(NotifyOnNewObject, TELEPORTER_CLASS, function(obj)
                if not HM.On("NoRetreat") then return end
                Utils.QueueWork(function() disableTeleporterItem(obj) end, 100)
            end)
        end
        Log("HardMode - NoRetreat armed (personal teleporter disabled)")
    end

    if HM.On("NoAvail") then
        STATE.HardModeTypeScale = CFG.TypeScale   -- per world; CombatHooks reads it per hit
        sweepDeployables()
        applyBuffRowEdits()
        applyItemRowEdits()

        if not armed.NoAvail then
            armed.NoAvail = true
            armDeployableNotify()

            -- Each RegisterHook target is async-loaded FIRST. A RegisterHook on an
            -- unloaded class THROWS. An un-guarded pcall would swallow it, and the
            -- latch above would never retry. Same recipe as ItemMods / the DefBot
            -- suppressor.
            -- BOTH slots, same body - the stun-lever lesson, which this hook shipped without.
            -- It was POST-only and never fired once: measured 2026-09-05, a mugnade still doing
            -- its native ~350 with not even the non-player bail line in the log. The write is
            -- absolute, and PRE is early enough either way (the throw path sets DamageFromWeapon
            -- on the DEFERRED spawn, so it is already in place before BeginPlay runs at all).
            ASSETS.LoadAsync({ GRENADE_PARENT_CLASS }, function()
                ASSETS.WarmPinned({ GRENADE_PARENT_CLASS })   -- a class that unloads takes its hook with it
                local ok, err = pcall(RegisterHook, GRENADE_BEGINPLAY_HOOK,
                    function(self) pcall(onGrenadeSpawn, self) end,
                    function(self) pcall(onGrenadeSpawn, self) end)
                if ok then Log("HardMode - grenade-damage hook registered (pre+post)")
                else LogBad("HardMode - grenade-damage hook FAILED: " .. tostring(err)) end
            end)

            ASSETS.LoadAsync({ PLAYER_CLASS }, function()
                ASSETS.WarmPinned({ PLAYER_CLASS })   -- a class that unloads takes its hook with it
                -- Both slots: the returned cap is absolute, so whichever slot runs after the body
                -- makes it stick and the other is overwritten by the body.
                local okM, errM = pcall(RegisterHook, SWING_MULT_HOOK, swingMultHook, swingMultHook)
                if okM then Log("HardMode - charged-melee cap registered (swing multiplier, pre+post)")
                else LogBad("HardMode - charged-melee cap FAILED: " .. tostring(errM)) end

                local ok, err = pcall(RegisterHook, MELEE_RPC_HOOK,
                    function(...) pcall(onMeleeRpc, ...) end)
                if not ok then LogBad("HardMode - charged-melee RPC backstop FAILED: " .. tostring(err)) end

                -- Both slots: the clamp only ever lowers, so the slot that does not carry the
                -- computed value simply finds nothing to do.
                local okS, errS = pcall(RegisterHook, STEALTH_HOOK,
                    function(...) pcall(onStealthBonus, ...) end,
                    function(...) pcall(onStealthBonus, ...) end)
                if okS then Log("HardMode - sneak-bonus cap registered (pre+post)")
                else LogBad("HardMode - sneak-bonus cap FAILED: " .. tostring(errS)) end
            end)
        end
        Log("HardMode - NoAvail armed")
    else
        STATE.HardModeTypeScale = nil
    end

    -- BOTH slots, same body - the registerPetSpecialAttackHook precedent. A POST-only
    -- registration here registered cleanly but never fired once. The write is absolute,
    -- so arming both costs nothing. Armed for NoAvail's stun halving or LongThrow's zap
    -- window; the body re-checks both at fire time.
    if (HM.On("NoAvail") or IM.LongThrowOn()) and not armed.Stun then
        armed.Stun = true
        ASSETS.LoadAsync({ ENUMS.BuffObjects.Stunned }, function()
            ASSETS.WarmPinned({ ENUMS.BuffObjects.Stunned })   -- a class that unloads takes its hook with it
            local ok, err = pcall(RegisterHook, STUN_APPLY_HOOK,
                function(self, char) pcall(onStunApply, self, char, "pre") end,
                function(self, char) pcall(onStunApply, self, char, "post") end)
            if ok then Log("HardMode - stun-duration hook registered (pre+post)")
            else LogBad("HardMode - stun-duration hook FAILED: " .. tostring(err)) end
        end)
    end
end

return HM
