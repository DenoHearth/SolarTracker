--[[
    Solar Tracker -- Core

    Reads the Sun Cleric resource and hands the numbers to the display.

    What the client itself does, from its own FrameXML (patch-B.MPQ,
    Interface\FrameXML\Ascension_CoAResources\ClassResources.lua, the SUNCLERIC
    branch) -- everything here follows it rather than guessing:

      * Solar Power is the *buff* 500149, read as a stack count, capped at
        GetSpellMaxStack(500149) (20).
      * Dawn is the *debuff* 804584, and it is also a stack count: it starts at
        5 + the rank of talent 29182 and ticks down as the charges are spent.
        No Solar Power can be generated while it is up.
      * The frame that draws all of this is the global CoAResourceOrb.

    Settings are per character.
]]

local ADDON = "SolarTracker"

SolarTracker = SolarTracker or {}
local ST = SolarTracker

ST.ADDON = ADDON
ST.VERSION = "3.5"

ST.SOLAR_SPELL_ID = 500149
ST.SOLAR_AURA_NAME = "Solar Power"
ST.DAWN_SPELL_ID = 804584
ST.DAWN_AURA_NAME = "Dawn"
ST.DAWN_TALENT_ID = 29182          -- adds to the base 5 Dawn charges
ST.DAWN_BASE_CHARGES = 5

-- Battle Cleric, the proc buff, id confirmed by Deniz and by the client's own
-- spell data (db.ascension.gg lists 562316 as the Proc; 285307 is the Paragon
-- ability that grants it and 562327 is its internal cooldown -- neither of
-- those is the aura that lands on the player). Unlike Solar Power and Dawn
-- this one is a timer, not a stack count, so what the display wants from it is
-- the remaining time against its full duration.
ST.PROC_SPELL_ID = 562316
ST.PROC_AURA_NAME = "Battle Cleric"

ST.DEFAULT_MAX = 20

-- The client's own Solar Power orb. Hidden while this addon is showing, the
-- same way Advantage Tracker suppresses the default Advantage frame, and given
-- back the moment the display is switched off.
ST.CLIENT_FRAMES = { "CoAResourceOrb" }

ST.defaults = {
    point = "CENTER",
    relPoint = "CENTER",
    x = 0,
    y = -170,
    scale = 1.0,
    max = ST.DEFAULT_MAX,
    style = "notched",
    enabled = true,
    hideClientOrb = true,
    hidden = {},              -- [frameName] = true, extra frames hidden by hand
}

function ST.Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cffffc040Solar|r: " .. msg)
end

--------------------------------------------------------------------
-- Reading the resource
--------------------------------------------------------------------

ST.testCount = nil
ST.testDawn = nil
ST.testProc = nil          -- seconds left, for previewing the duration bar
ST.testProcDuration = nil

-- How many empty aura slots in a row end a scan. Stopping at the first one is
-- what the client's own AuraUtil does (Interface\FrameXML\Util\AuraUtil.lua in
-- patch-B), and it is not safe here: one empty slot in the middle of the list
-- would hide everything after it, which is how the bar could sit dark while
-- stacks were plainly being banked.
local AURA_SCAN_GAP = 3

-- Stacks of one aura on the player, matched by id first and name second, or nil
-- when it is not up at all. Both filters are scanned: Solar Power is a buff and
-- Dawn is a debuff, and a core change either way should not blind the display.

local function ScanAura(spellId, auraName)
    for _, filter in ipairs({ "HELPFUL", "HARMFUL" }) do
        local misses = 0
        for i = 1, 40 do
            local name, _, _, count, _, _, _, _, _, _, id = UnitAura("player", i, filter)
            if not name then
                misses = misses + 1
                if misses >= AURA_SCAN_GAP then break end
            else
                misses = 0
                if id == spellId or name == auraName then
                    return (count and count > 0) and count or 1
                end
            end
        end
    end
    return nil
end

function ST.GetSolarPower()
    if ST.testCount then return ST.testCount end
    return ScanAura(ST.SOLAR_SPELL_ID, ST.SOLAR_AURA_NAME) or 0
end

-- Charges of Dawn left, or nil when Dawn is not up.
function ST.GetDawnCharges()
    if ST.testDawn then return ST.testDawn end
    return ScanAura(ST.DAWN_SPELL_ID, ST.DAWN_AURA_NAME)
end

-- Both auras from a single pass over the player's auras, so the display can be
-- polled every frame without paying for four separate scans. Returns the Solar
-- Power stack count (0 when it is not up) and the Dawn charges (nil when Dawn
-- is not up), exactly like the two readers above.
function ST.ReadResource()
    if ST.testCount or ST.testDawn or ST.testProc then
        return ST.testCount or 0, ST.testDawn, ST.testProc,
            ST.testProcDuration or ST.testProc
    end

    local solar, dawn, procLeft, procDuration
    local now = GetTime()

    for _, filter in ipairs({ "HELPFUL", "HARMFUL" }) do
        local misses = 0
        for i = 1, 40 do
            local name, _, _, count, _, duration, expirationTime, _, _, _, id =
                UnitAura("player", i, filter)
            if not name then
                -- An empty slot is not the end of the list here -- see
                -- AURA_SCAN_GAP above.
                misses = misses + 1
                if misses >= AURA_SCAN_GAP then break end
            else
                misses = 0
                local stacks = (count and count > 0) and count or 1
                if id == ST.SOLAR_SPELL_ID or name == ST.SOLAR_AURA_NAME then
                    solar = stacks
                elseif id == ST.DAWN_SPELL_ID or name == ST.DAWN_AURA_NAME then
                    dawn = stacks
                elseif id == ST.PROC_SPELL_ID or name == ST.PROC_AURA_NAME then
                    -- A permanent aura reports expirationTime 0; there is no
                    -- time to draw for one, so it is left alone rather than
                    -- shown full.
                    if duration and duration > 0 and expirationTime and expirationTime > 0 then
                        local left = expirationTime - now
                        if left > 0 then
                            procLeft, procDuration = left, duration
                        end
                    end
                end
            end
        end
    end

    return solar or 0, dawn, procLeft, procDuration
end

-- How many charges Dawn starts with: 5 plus the rank of talent 29182, exactly
-- as ClassResources.lua works it out. Both of those are client APIs that may
-- not answer, so the number is only trusted when it comes back sane; otherwise
-- the highest count seen during this Dawn stands in.
local dawnSeen = 0

function ST.GetDawnMax(current)
    local best
    if C_CharacterAdvancement and C_CharacterAdvancement.GetTalentRankByID then
        local ok, rank = pcall(C_CharacterAdvancement.GetTalentRankByID, ST.DAWN_TALENT_ID)
        if ok and type(rank) == "number" then
            best = ST.DAWN_BASE_CHARGES + rank
        end
    end

    current = current or 0
    if current > dawnSeen then dawnSeen = current end
    if not best or best < dawnSeen then best = dawnSeen end
    return math.max(1, best or ST.DAWN_BASE_CHARGES)
end

function ST.ResetDawnSeen()
    dawnSeen = 0
end

-- The Solar Power cap, from the client's own spell data where it answers. The
-- answer never changes within a session, so it is kept once found: this is read
-- on every frame now and the client call is not free.
local solarMax

function ST.GetSolarMax()
    if solarMax then return solarMax end
    if type(GetSpellMaxStack) == "function" then
        local ok, value = pcall(GetSpellMaxStack, ST.SOLAR_SPELL_ID)
        if ok and type(value) == "number" and value > 0 then
            solarMax = value
            return solarMax
        end
    end
    return nil
end

--------------------------------------------------------------------
-- Saved variables
--------------------------------------------------------------------

function ST.InitDB()
    SolarTrackerCharDB = SolarTrackerCharDB or {}
    local db = SolarTrackerCharDB

    for key, value in pairs(ST.defaults) do
        if db[key] == nil then
            if type(value) == "table" then
                db[key] = {}
            else
                db[key] = value
            end
        end
    end

    -- A style saved by an older build that no longer exists falls back to the
    -- default rather than leaving the display blank.
    if not (ST.styles and ST.styles[db.style]) then
        db.style = ST.DEFAULT_STYLE or "segments"
    end

    -- Dead key from an earlier version: the option to stay visible out of
    -- combat with Solar Power banked.
    db.showOutOfCombat = nil

    db.minimap = db.minimap or { hide = false }
    ST.db = db
    return db
end
