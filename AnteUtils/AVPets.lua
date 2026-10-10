-- =======================================================================
-- AVPets (PT) - the TAMED-PET reads and writes: HP, mesh scale, level, follower buff.
-- Split out of AVUtils, merged back onto AVU: callers still write AVU.ScalePetHealth /
-- ScalePetMesh / GetPetLevel / ...
--
-- MUST-KNOWS
--   * THE PET SYSTEM OWNS FOLLOWER LIMB HP. BuffActor_Follower recomputes both limb maps from
--     DT_Pets on every respawn and level-up, so NPCData / AVU.SetLimbHealth / a BasicStats Hp*
--     key all do NOTHING on a follower. PT.ScalePetHealth writes the MAPS, the one path it
--     doesn't own, and never calls InitalizeHealthValues (that bounces back into its writer).
--   * MULTIPLIERS, never absolutes: pet stats are `base + perLevel*level`, so a flat value would
--     delete level scaling and leave a high-level pet WEAKER than vanilla.
--   * EVERYTHING HERE IS IDEMPOTENT, because it re-applies on every follower event - each writer
--     remembers what it last wrote and skips if the value is still ours (else it COMPOUNDS).
--   * See also ModulePets/PetManager (the poll + re-mutate) and [[af-pet-system]].
-- =======================================================================

---@diagnostic disable: undefined-field, undefined-global

local SETTINGS = require("Settings")
local STATE = require("AnteCore.State")
local Utils = require("AnteUtils.Utils")
local SCHEMA = require("AnteData.Schema")
local LogDebug = Utils.LogDebug

---@class AVU.Pets      -- merged onto AVU in AVUtils; the name is what makes goto-def work
local PT = {}

-- UE4SS hands ForEach/Find results back as wrappers; unwrap defensively (a raw value passes through).
local function unwrap(v)
    if type(v) == "userdata" or type(v) == "table" then
        local ok, got = pcall(function() return v:get() end)
        if ok then return got end
    end
    return v
end


-- =======================================================================
-- IDENTITY - the follower buff actor and what hangs off it
-- =======================================================================

-- The follower/tamed buff actor for `npc`, or nil if it isn't a pet.
--   * `CachedFollowerBuffActor` is a plain field the game writes in SetCharacterNpc - a DIRECT
--     O(1) read, no FindAllOf. The scan below is only a fallback.
--   * NPC_Base DOES have a GetFollowerBuff, but it is an OUT-PARAM function, so calling it from
--     Lua returns the BOOL and the buff arrives as a second return - which made it look absent.

function PT.GetFollowerBuff(npc)
    if Utils.IsActorInvalid(npc) then return nil end

    local buff; pcall(function() buff = npc.CachedFollowerBuffActor end)
    if IsValid(buff) then return buff end

    local key; pcall(function() key = npc:GetFullName() end)
    if not key then return nil end
    for _, b in ipairs(FindAllOf("BuffActor_Tamed_C") or {}) do
        if IsValid(b) then
            local cn; pcall(function() cn = b.CharacterNPC end)
            local cnk; if Utils.IsActorValid(cn) then pcall(function() cnk = cn:GetFullName() end) end
            if cnk == key then return b end
        end
    end
    return nil
end


-- The tamed-pet LEVEL for `npc`, via the cached follower buff. nil if not a pet.

function PT.GetPetLevel(npc)
    local buff = PT.GetFollowerBuff(npc)
    if not buff then return nil end
    local lvl; pcall(function() lvl = buff:CalculateNpcLevel() end)
    return lvl
end


-- True if `pet` is the ACTIVE companion of ANY player (the one in a Companion slot, as opposed to
-- a stored/benched one) - the gate for anything that should only apply to a carried pet.
-- FindAllOf-free (walks the small player list), so it is cheap enough for a throttled pet OnTick.
-- Identity by GetFullName: wrappers differ across hooks, so a raw `==` never matches.

function PT.IsPrimaryCompanion(pet)
    if Utils.IsActorInvalid(pet) then return false end
    local gs = STATE.GameState
    local players = gs and gs.PlayerCharacterInGame
    if not players then return false end

    local petFn; pcall(function() petFn = pet:GetFullName() end)
    if not petFn then return false end

    for i = 1, #players do
        local p = players[i]
        if IsValid(p) then
            local compFn
            pcall(function()
                local c = p.Companion
                if IsValid(c) then compFn = c:GetFullName() end
            end)
            if compFn == petFn then return true end
        end
    end
    return false
end


-- The PLAYER this pet belongs to, or nil.
-- Exact answer first: the player whose Companion slot holds it (same small walk as
-- IsPrimaryCompanion - PlayerCharacterInGame, no FindAllOf).
-- A deployed-but-unslotted pet (dropped in the world, or a second pet out at once) has no link to
-- walk. `opts.NearestFallback` then guesses the nearest live player - opt-in, since a caller that
-- needs the real owner (naming, credit) must not silently get someone else.

function PT.GetPetOwner(pet, opts)
    if Utils.IsActorInvalid(pet) then return nil end
    opts = opts or {}

    local petFn; pcall(function() petFn = pet:GetFullName() end)
    local gs = STATE.GameState
    local players = (petFn and gs) and gs.PlayerCharacterInGame or nil
    if players then
        for i = 1, #players do
            local p = players[i]
            if IsValid(p) then
                local compFn
                pcall(function()
                    local c = p.Companion
                    if IsValid(c) then compFn = c:GetFullName() end
                end)
                if compFn == petFn then return p end
            end
        end
    end

    if not opts.NearestFallback then return nil end

    local loc; pcall(function() loc = pet:K2_GetActorLocation() end)
    if not loc then return nil end
    local best, bestD
    for _, p in ipairs(Utils.LivePlayers()) do
        local pl; pcall(function() pl = p:K2_GetActorLocation() end)
        if pl then
            local d = Utils.DistSq(loc, pl)
            if d and (not bestD or d < bestD) then best, bestD = p, d end
        end
    end
    return best
end


-- =======================================================================
-- PET HEALTH
-- =======================================================================
-- THE LIMB MAPS ARE NOT THE LIVE HEALTH, and this is the trap both writers below are built around:
--   * DefaultMax_LimbHealthMap  IS the max (GetMaxTotalHealth reads it) - writing it is enough.
--   * Current_LimbHealthMap     is only a BP-side MIRROR. The real current HP lives in the native
--     per-limb scalars behind SetLimbHealth/GetLimbHealth, and GetTotalHealth() sums THOSE.
-- So a current-HP change is pushed through SetLimbHealth (no out-params, so it cannot silently
-- no-op the way GetAndSetTotalHealth's push did - CLAUDE.md 3), and the trailing GetOnly PULL is
-- the only thing that refreshes the cached total behind the nameplate.
--   * The map holds the RAW max. GetMaxLimbHealth runs it through the character's stat modifiers,
--     and current health, "full" and the fraction the game saves into the pet's item all live on
--     that effective scale. A current written against the raw value lands short by the modifier,
--     and the item then saves the shortfall - a pet with a +50% max lost a third per pickup.

local petHpWritten = {}   -- ActorKey -> { [limbEnum] = the max WE last wrote }

-- A limb's max as the game sees it (raw map value x stat modifiers), or `fallback` if unreadable.
local function effectiveMax(actor, limb, fallback)
    local v
    pcall(function() v = tonumber(actor:GetMaxLimbHealth(limb)) end)
    if v and v > 0 then return v end
    return fallback
end

local ITEM_DURABILITY_CUR = SCHEMA.Changeable.CurrentItemDurability
local ITEM_DURABILITY_MAX = SCHEMA.Changeable.MaxItemDurability
-- InventorySlotSelected_Struct stays a Blueprint struct on both builds.
local F_COMPANION_INV   = "Inventory_2_B69CD60741EFD551F09ED5AFF44B1E46"
local F_COMPANION_INDEX = "Index_5_6BDC7B3944A5DE0B319F9FA20720872F"
local F_SLOT_CHANGEABLE = SCHEMA.Slot.ChangeableData

-- The pet's TRUE health fraction (0..1) read from its ITEM, or nil (+ WHY, for diagnosis).
-- Fixes "a redeployed pet heals to full": a picked-up pet stores health in its held item, and the
-- game restores the limb maps from it on redeploy. When we run (deferred off the pet system's own
-- writer) that restore hasn't happened yet, so the maps read transiently FULL - and our own push
-- would then bake that false-full value back into the item, permanently skipping the game's restore.
-- Do NOT use buff:GetItemChangeableData() - it returns a hardcoded default struct (always 1.0).
-- Read the same slot the game's own restore reads.
local function petItemFraction(actor)
    local buff = PT.GetFollowerBuff(actor)
    if not buff then return nil, "no buff" end

    local cur, max, why
    pcall(function()
        local target = buff.CompanionInventoryTarget
        if not target then why = "no CompanionInventoryTarget" return end

        local inv = target[F_COMPANION_INV]
        local idx = tonumber(target[F_COMPANION_INDEX])
        if IsNotValid(inv) then why = "no inventory (idx " .. tostring(idx) .. ")" return end
        if not idx or idx < 0 then why = "no item (idx " .. tostring(idx) .. ")" return end

        local slot = inv.CurrentInventory[idx + 1]                 -- BP index is 0-based
        if not slot then why = "empty slot " .. idx return end

        local data = slot[F_SLOT_CHANGEABLE]
        if not data then why = "no ChangeableData" return end

        cur = tonumber(data[ITEM_DURABILITY_CUR])
        max = tonumber(data[ITEM_DURABILITY_MAX])
        if not cur or not max then why = "durability fields nil" end
    end)

    if not cur or not max or max <= 0 or cur <= 0 then
        return nil, (why or string.format("durability %s/%s", tostring(cur), tostring(max)))
    end

    local f = cur / max
    if f > 1 then f = 1 elseif f < 0 then f = 0 end
    return f
end


-- E_BodyLimbs, inlined rather than required: AVPets is loaded early and this is six numbers that
-- have never moved. Mirrors ENUMS.EBodyLimbs - keep the two in step if the enum ever changes.
local LIMB_ENUM = {
    Head = 3, Torso = 4, LeftArm = 5, RightArm = 6, LeftLeg = 7, RightLeg = 8,
}

-- [AUTHORITY] Scale a PET's limb HP - THE only way to change it (see the file header).
--   Anti-compound: remembers the max it wrote per limb; if the map still holds that value, skip
--   (it's our own earlier write). Any other value means the pet system reset it (respawn/level-up)
--   and that becomes the new base.
--   Damage is preserved as a FRACTION, taken from the ITEM when it has one (see petItemFraction).
--   Only limbs already NON-ZERO are touched - a pest is head-only; giving it a torso would change
--   how it dies.
--   `mult` is a NUMBER (every limb) or a PER-LIMB TABLE (`{ Head = 1.79, Torso = 1.16 }`); an
--   unlisted limb keeps the pet system's own value. Still a MULTIPLIER either way - never an
--   absolute, or a levelled pet ends up WEAKER than vanilla.
--   `curves` (def.PetHp) is a PER-LIMB table of level -> HP anchors (`{ Head = { [3] = 350, [20] = 1100 } }`),
--   for a curve a flat multiplier can't draw. It wins over `mult` for the limbs it names. `lvl` is
--   the pet level those anchors are read at (nil = read it here).

-- Piecewise-linear HP between a curve's level anchors, held flat outside them.
local function curveHp(curve, lvl)
    local levels = {}
    for l in pairs(curve) do levels[#levels + 1] = l end
    if #levels == 0 then return nil end
    table.sort(levels)
    if lvl <= levels[1] then return curve[levels[1]] end
    for i = 2, #levels do
        local lo, hi = levels[i - 1], levels[i]
        if lvl <= hi then
            return curve[lo] + (curve[hi] - curve[lo]) * (lvl - lo) / (hi - lo)
        end
    end
    return curve[levels[#levels]]
end

function PT.ScalePetHealth(actor, mult, curves, lvl)
    if Utils.IsActorInvalid(actor) then return end

    -- Normalise every shape to one per-limb map (a multiplier, or a curve table) plus an
    -- every-limb fallback, so the loop below has one case.
    local allMult = (type(mult) == "number" and mult ~= 1) and mult or nil
    local perLimb, any, hasCurve = {}, allMult ~= nil, false
    local function put(src, isCurve)
        for name, m in pairs(src) do
            local limb = LIMB_ENUM[name]
            if not limb then
                Utils.LogBad("ScalePetHealth - unknown limb key '" .. tostring(name) .. "' (typo?)")
            elseif isCurve and type(m) == "table" then
                perLimb[limb] = m; any = true; hasCurve = true
            elseif not isCurve and type(m) == "number" and m ~= 1 then
                perLimb[limb] = m; any = true
            end
        end
    end
    if type(mult) == "table" then put(mult, false) end
    if type(curves) == "table" then put(curves, true) end
    if not any then return end

    if hasCurve then
        lvl = tonumber(lvl) or tonumber(PT.GetPetLevel(actor)) or 1
    end

    local key = Utils.ActorKey(actor)
    if not key then return end

    -- One fraction for all limbs matches the game exactly (its own restore multiplies every limb's
    -- max by the same ratio).
    local itemFrac, noItemWhy = petItemFraction(actor)

    local maxMap, curMap
    local ok = pcall(function()
        maxMap = actor.DefaultMax_LimbHealthMap
        curMap = actor.Current_LimbHealthMap
    end)
    if not ok or maxMap == nil or curMap == nil then return end

    -- Snapshot first: mutating a TMap while iterating it is asking for trouble.
    local limbs = {}
    pcall(function()
        maxMap:ForEach(function(k, v)
            limbs[#limbs + 1] = { k = unwrap(k), max = tonumber(unwrap(v)) or 0 }
        end)
    end)

    local written = petHpWritten[key] or {}
    local changed = false

    for _, limb in ipairs(limbs) do
        local base = limb.max
        local mine = written[limb.k]
        -- The TMap key arrives as the byte enum; tonumber() is what makes it match perLimb's
        -- integer keys (a raw enum wrapper would silently never hit, and the limb would just be
        -- skipped - the exact kind of nothing-happens bug this table shape invites).
        local m = perLimb[tonumber(limb.k) or limb.k] or allMult
        if type(m) == "table" and base > 0 then
            local want = curveHp(m, lvl)
            m = want and want / base or nil
        end
        if m and base > 0 and not (mine and math.abs(mine - base) < 0.01) then
            local newMax = base * m

            local frac = itemFrac
            if not frac then
                -- No item: read the REAL health via GetLimbHealth (the native scalar), falling
                -- back to the mirror only if that fails. Against the effective max, its own scale.
                local cur
                pcall(function() cur = tonumber(actor:GetLimbHealth(limb.k)) end)
                if not cur then
                    pcall(function() cur = tonumber(unwrap(curMap:Find(limb.k))) end)
                end
                local effOld = effectiveMax(actor, limb.k, base)
                frac = (cur or effOld) / effOld
            end
            if frac > 1 then frac = 1 elseif frac < 0 then frac = 0 end

            -- The new raw max first: the effective max read back below is computed from it.
            pcall(function() maxMap:Add(limb.k, newMax) end)
            local newCur = effectiveMax(actor, limb.k, newMax) * frac

            pcall(function() curMap:Add(limb.k, newCur) end)            -- keep the BP mirror in step
            pcall(function() actor:SetLimbHealth(limb.k, newCur) end)   -- the REAL health

            written[limb.k] = newMax
            changed = true
        end
    end

    petHpWritten[key] = written

    if changed then
        -- The GetOnly PULL: the only thing that refreshes the cached total (a TABLE per out-param;
        -- a bare call silently no-ops).
        pcall(function() actor:GetAndSetTotalHealth(true, {}, {}, {}) end)

        LogDebug(string.format("ScalePetHealth - %s x%s (frac %.2f %s) -> hp %s/%s",
            Utils.GetActorName(actor), next(perLimb) and "per-limb" or string.format("%.2f", allMult), itemFrac or 1,
            itemFrac and "from item" or ("NO ITEM: " .. tostring(noItemWhy)),
            tostring(select(2, pcall(function() return actor:GetTotalHealth() end))),
            tostring(select(2, pcall(function() return actor:GetMaxTotalHealth() end)))),
            SETTINGS.DEBUG_NPC_ACTIONS)
    end
end


-- Per-world reset (actor fullnames from a dead world mean nothing).

function PT.ResetPetHealthScale()
    petHpWritten = {}
end


-- [AUTHORITY] Set a pet's CURRENT health to `frac` of its max, per limb - PetManager's bleedout
-- rescue (reviving a pet at 0 HP just re-downs it on the next scratch).
-- The max map is NOT touched: this is a heal, not a rescale, so it composes with def.PetHpMult.

function PT.SetPetHealthFraction(actor, frac)
    if Utils.IsActorInvalid(actor) then return false end
    frac = tonumber(frac) or 1
    if frac > 1 then frac = 1 elseif frac < 0 then frac = 0 end

    local maxMap, curMap
    local ok = pcall(function()
        maxMap = actor.DefaultMax_LimbHealthMap
        curMap = actor.Current_LimbHealthMap
    end)
    if not ok or maxMap == nil then return false end

    local limbs = {}
    pcall(function()
        maxMap:ForEach(function(k, v)
            limbs[#limbs + 1] = { k = unwrap(k), max = tonumber(unwrap(v)) or 0 }
        end)
    end)

    local touched = false
    for _, limb in ipairs(limbs) do
        if limb.max > 0 then                        -- skip limbs a head-only body doesn't use
            local hp = effectiveMax(actor, limb.k, limb.max) * frac
            if curMap ~= nil then pcall(function() curMap:Add(limb.k, hp) end) end
            pcall(function() actor:SetLimbHealth(limb.k, hp) end)
            touched = true
        end
    end
    if touched then pcall(function() actor:GetAndSetTotalHealth(true, {}, {}, {}) end) end
    return touched
end


-- =======================================================================
-- PET MESH SCALE
-- =======================================================================

local function petAxes(v)   -- number | FVector | nil  ->  mx, my, mz (default 1)
    if v == nil then return 1, 1, 1 end
    if type(v) == "number" then return v, v, v end
    return v.X or 1, v.Y or 1, v.Z or 1
end

-- actorKey -> the {x,y,z} we last WROTE to CachedBaseMeshScale (the anti-compound guard). It also
-- makes ScalePetMesh safe to call DIRECTLY at any time, not only right after the native writer -
-- which is what lets PetManager drive it off the re-mutation instead of a post-hook that may not fire.
local petScaleWritten = {}

function PT.ResetPetScaleWritten() petScaleWritten = {} end


-- [ALL ROLES] Shrink (or grow) a PET's mesh while PRESERVING the native level growth.
-- The native writer sets CachedBaseMeshScale = <class default> * a 1.0..1.2 level ramp; we read
-- that back and multiply, so the pet still grows on the ramp but sits at mult x (also sidesteps
-- GetDefaultMeshScale, which is native-only and unreachable from Lua).
--   mult = a NUMBER (uniform), an FVector (per-axis), or { Min=, Max= } LERPED by level 0..20 on
--   top of the native ramp - turns a barely-there native growth into a dramatic small->big.
-- CachedBaseMeshScale is a plain value FVector, so the whole-vector write here is safe (the "never
-- write a struct back" rule is about structs holding asset pointers).

function PT.ScalePetMesh(npc, buff, mult)
    if Utils.IsActorInvalid(npc) or not mult then return end
    local key = Utils.ActorKey(npc)

    local mx, my, mz
    if type(mult) == "table" and (mult.Min ~= nil or mult.Max ~= nil) then
        local lvl = 0
        if IsValid(buff) then pcall(function() lvl = buff.CachedLevel or 0 end) end
        if lvl < 0 then lvl = 0 elseif lvl > 20 then lvl = 20 end
        local t = lvl / 20
        local a1, a2, a3 = petAxes(mult.Min)
        local b1, b2, b3 = petAxes(mult.Max)
        mx = a1 + (b1 - a1) * t
        my = a2 + (b2 - a2) * t
        mz = a3 + (b3 - a3) * t
    else
        mx, my, mz = petAxes(mult)   -- number = uniform flat, FVector = per-axis flat
    end

    pcall(function()
        local s = npc.CachedBaseMeshScale   -- default * levelScalar, unless we already scaled it
        if not s then return end
        local w = key and petScaleWritten[key]
        if w and math.abs(s.X - w[1]) < 0.001 and math.abs(s.Y - w[2]) < 0.001 and math.abs(s.Z - w[3]) < 0.001 then
            return   -- unchanged since our last write = the native hasn't reset it; don't compound
        end
        local nx, ny, nz = s.X * mx, s.Y * my, s.Z * mz
        npc.CachedBaseMeshScale = FVector(nx, ny, nz)
        npc:LocalUpdateMeshSize()   -- re-push (x the Size_Multiply stat) to the mesh
        if key then petScaleWritten[key] = { nx, ny, nz } end
    end)
end


return PT
