--[[
    Solar Tracker -- the display, the events and the slash commands.

    The display is a notched bar with the number above it and a second bar of
    the same shape under it counting down Battle Cleric, darkening from gold to
    red as that runs out, then flashing with the client's own spell-proc glow
    around it for the last four seconds. While Dawn is up the
    resource bar becomes the Dawn charges instead, counting down as they are
    spent, because Solar Power cannot be generated during it and the charges
    are the thing worth watching.

    The ten alternative styles and the picker were deleted on 2026-08-24 -- see
    the note at the top of Styles.lua.

    The client's own orb (CoAResourceOrb) is hidden while the display is on and
    handed straight back when it is off, so there is never a moment with neither.
]]

local ST = SolarTracker
local Print = ST.Print

local db
local anchor
local countText
local driver
local ctx

local layoutKey
local lastSignature

local SOLAR_FILLED = { 1.00, 0.78, 0.26 }
local SOLAR_FULL   = { 1.00, 0.95, 0.66 }
local DAWN_FILLED  = { 1.00, 0.55, 0.14 }
local EMPTY        = { 0.20, 0.18, 0.16 }

-- Battle Cleric's fill, and how it changes on the way down. The bar starts at
-- the palest gold in the palette and darkens through the amber the resource
-- bar uses to a red as it runs out, so the last seconds are readable without
-- looking at a number.
--
-- The first three stops are colours the addon already draws with; only the
-- last is new, and it is the one that has to say "now" rather than "soon".
-- Between stops it is interpolated, not stepped: a bar that changes colour in
-- jumps reads as three states, and this is one thing running out.
local PROC_RAMP = {
    { 1.00, SOLAR_FULL },
    { 0.50, SOLAR_FILLED },
    { 0.20, DAWN_FILLED },
    { 0.00, { 0.95, 0.22, 0.15 } },
}

-- The last seconds get a pulse from inside the bar. It is drawn as an additive
-- layer given exactly the fill's rectangle, so the brightening happens within
-- the bar and can never reach past its width -- no outer glow texture, nothing
-- overhanging the edge.
--
-- This is the one animated thing in the addon, and it is deliberate: a glow
-- that does not move is just a lighter colour, which the ramp already does.
-- Two additive layers: a wash over the whole height and a brighter core band
-- through the middle. Both are given the fill's rectangle, so both stay inside.
--
-- The first attempt (0.05 to 0.40 of a warm tint) was too weak to read as a
-- glow at all -- it looked like the bar had gone slightly paler. What makes a
-- flat rectangle shine is a high floor so it is bright even at the bottom of
-- the pulse, a near-white core, and enough alpha at the peak to wash the fill
-- colour out. All three are needed; raising only the peak just makes it blink.
local PROC_GLOW_SECONDS = 4
local PROC_GLOW_SPEED = 11         -- radians a second: a flash a bit under 2Hz

local PROC_GLOW_COLOUR = { 1.00, 0.90, 0.70 }
local PROC_GLOW_MIN, PROC_GLOW_MAX = 0.20, 1.00

local PROC_CORE_COLOUR = { 1.00, 0.97, 0.88 }
local PROC_CORE_MIN, PROC_CORE_MAX = 0.45, 1.00

-- The glow around the bar is the client's own spell-proc glow -- the same one
-- WeakAuras calls Button Glow, and the same one that lights up an action button
-- when a proc comes up. Not an imitation of it:
--
--   ActionButton_ShowOverlayGlow / _HideOverlayGlow   Interface\FrameXML\ActionButton.lua
--   ActionBarButtonSpellActivationAlert (the template) Interface\FrameXML\ActionBarFrame.xml
--   IconAlert.blp, IconAlertAnts.blp                   Interface\SpellActivationOverlay--
-- All three are in this client (patch-B and patch-A). It brings its own
-- animation: the ants crawl via AnimateTexCoords in the template's OnUpdate and
-- the spark and inner/outer glows have their own animation groups, so nothing
-- here has to drive it frame by frame.
--
-- It sizes itself to 1.4x its host and overhangs it, which is what puts the
-- glow *around* the bar. The host is the bar's rectangle grown a few pixels so
-- there is somewhere for the halo to sit.
local GLOW_HOST_MARGIN = 3

local glowHost, glowOverlay

-- The glow is built from the client's own template but is entirely ours
-- (2026-08-25). It used to go through ActionButton_ShowOverlayGlow, which is
-- the convenient route and the wrong one: that function hands out overlays
-- from a pool the whole UI shares, writes the client's own module locals, and
-- parks a reference on the host as `activationOverlay`. Everything it touches
-- is then touched by this insecure addon, and on this client taint is blamed
-- on whoever executes next, not on whoever caused it -- see the same lesson in
-- RaidFrameDebug, where poking the compact raid container got the client's own
-- bundled addon blocked.
--
-- So: our own frame from the template, never the shared pool. What is copied
-- from ActionButton.lua is only the sizing, which is what makes it look right.
--
-- Deliberately never plays the animOut groups: their OnFinished handlers are
-- ActionButton_OnOverlayGlowSubAnimationFinished, which push the frame into
-- that shared pool. Hiding is enough. `activeAnimations` is left nil for the
-- same reason -- the template's own OnHide only reaches into the pool when it
-- is set.
local GLOW_TEMPLATE = "ActionBarButtonSpellActivationAlert"
local GLOW_PIECES = { "spark", "innerGlow", "innerGlowOver", "outerGlow", "outerGlowOver", "ants" }

local function BuildGlowOverlay()
    if glowOverlay or not glowHost then return glowOverlay end

    local ok, overlay = pcall(CreateFrame, "Frame", nil, glowHost, GLOW_TEMPLATE)
    if not ok or not overlay or not overlay.ants then
        return nil
    end

    -- The same 1.4x overhang ActionButton_ShowOverlayGlow gives a button: it is
    -- what puts the glow around the thing rather than on it.
    local width, height = glowHost:GetWidth(), glowHost:GetHeight()
    overlay:SetPoint("TOPLEFT", glowHost, "TOPLEFT", -width * 0.2, height * 0.2)
    overlay:SetPoint("BOTTOMRIGHT", glowHost, "BOTTOMRIGHT", width * 0.2, -height * 0.2)

    overlay.ants:SetWidth(width * 0.95)
    overlay.ants:SetHeight(height * 0.95)
    overlay.spark:SetWidth(width)
    overlay.spark:SetHeight(height)
    overlay.innerGlow:SetWidth(width / 2)
    overlay.innerGlow:SetHeight(height / 2)
    overlay.innerGlowOver:SetWidth(width / 2)
    overlay.innerGlowOver:SetHeight(height / 2)
    overlay.outerGlow:SetWidth(width * 2)
    overlay.outerGlow:SetHeight(height * 2)
    overlay.outerGlowOver:SetWidth(width * 2)
    overlay.outerGlowOver:SetHeight(height * 2)

    overlay:Hide()
    glowOverlay = overlay
    ST.glowOverlay = overlay
    return overlay
end

local function BlizzardGlowAvailable()
    return glowOverlay ~= nil
end

-- Whether the glow is up, asked of the frame rather than remembered. A cached
-- flag is what made the glow appear only some of the time before (2026-08-25):
-- anything that hides the frame leaves a remembered "it is on" pointing at a
-- glow that is not there, and the next request gets skipped as redundant.
local function GlowIsUp()
    return glowOverlay ~= nil and glowOverlay:IsShown()
end

local function SetBlizzardGlow(on)
    local overlay = glowOverlay
    if not overlay then return end
    if on == GlowIsUp() then return end

    if on then
        overlay:Show()
        for i = 1, table.getn(GLOW_PIECES) do
            local piece = overlay[GLOW_PIECES[i]]
            if piece and piece.animIn then
                pcall(piece.animIn.Play, piece.animIn)
            end
        end
    else
        for i = 1, table.getn(GLOW_PIECES) do
            local piece = overlay[GLOW_PIECES[i]]
            if piece and piece.animIn and piece.animIn:IsPlaying() then
                pcall(piece.animIn.Stop, piece.animIn)
            end
        end
        overlay:Hide()
    end
end

local function GlowWave(now)
    return 0.5 + 0.5 * math.sin(now * PROC_GLOW_SPEED)
end

local function RampColour(fraction)
    local stops = PROC_RAMP
    local last = table.getn(stops)

    if fraction >= stops[1][1] then
        local c = stops[1][2]
        return c[1], c[2], c[3]
    end

    for i = 1, last - 1 do
        local hi, lo = stops[i], stops[i + 1]
        if fraction <= hi[1] and fraction >= lo[1] then
            local span = hi[1] - lo[1]
            local t = (span > 0) and (fraction - lo[1]) / span or 1
            local a, b = lo[2], hi[2]
            return a[1] + (b[1] - a[1]) * t,
                a[2] + (b[2] - a[2]) * t,
                a[3] + (b[3] - a[3]) * t
        end
    end

    local c = stops[last][2]
    return c[1], c[2], c[3]
end

local state = {
    count = 0,
    max = ST.DEFAULT_MAX,
    dawn = false,
    atMax = false,
    procLeft = nil,
    procDuration = nil,
}

--------------------------------------------------------------------
-- Reading
--------------------------------------------------------------------

local function RefreshState()
    -- One pass for both auras: this runs every frame, so it must stay cheap.
    local solarCount, dawnCharges, procLeft, procDuration = ST.ReadResource()

    state.procLeft, state.procDuration = procLeft, procDuration

    if dawnCharges then
        state.dawn = true
        state.count = dawnCharges
        state.max = ST.GetDawnMax(dawnCharges)
        state.atMax = false
    else
        ST.ResetDawnSeen()
        state.dawn = false
        state.count = solarCount or 0

        local cap = ST.GetSolarMax() or db.max
        if state.count > cap then cap = state.count end
        db.max = cap
        state.max = cap
        state.atMax = state.count > 0 and state.count >= cap
    end
end

--------------------------------------------------------------------
-- Drawing
--------------------------------------------------------------------

local colours = { fill = SOLAR_FILLED, empty = EMPTY }

-- Rebuilt only when the style or the cap changes: laying out is the expensive
-- half, colouring is the cheap half that runs while the count moves.
local function Relayout()
    local style = ST.GetStyle(db.style)
    ctx.Begin()
    style.Layout(ctx, state.max)
    ctx.Finish()
    layoutKey = style.key .. ":" .. state.max
    -- Layout builds the duration track fresh and shown; whether it belongs on
    -- screen is UpdateProcBar's call, which runs right after this and hides it
    -- again when the buff is not up.
end

local function Draw()
    local style = ST.GetStyle(db.style)
    if layoutKey ~= (style.key .. ":" .. state.max) then
        Relayout()
    end

    -- Every banked point is drawn at full brightness, not just a capped bar.
    -- SOLAR_FILLED used to be the colour below the cap and SOLAR_FULL only at
    -- 20/20, which read as an unlit bar while climbing -- "dark like a candle
    -- turned out". The cap is now told apart by the notches instead of by a
    -- dimmer fill (see the style's Paint), so nothing is lost by lighting the
    -- climb properly.
    colours.fill = state.dawn and DAWN_FILLED or SOLAR_FULL
    colours.empty = EMPTY

    style.Paint(ctx, state, colours)

    if state.dawn then
        countText:SetText("Dawn " .. state.count)
        countText:SetTextColor(1.00, 0.62, 0.20)
    else
        countText:SetText(tostring(state.count))
        if state.atMax then
            countText:SetTextColor(1.00, 0.95, 0.66)
        else
            countText:SetTextColor(1.00, 0.80, 0.34)
        end
    end
end

--------------------------------------------------------------------
-- Battle Cleric duration bar
--------------------------------------------------------------------

-- The style lays the bar out and colours it; this only moves the fill, which
-- is the one thing that changes every frame.
--
-- Kept out of the signature early-out deliberately: the remaining time changes
-- on every single frame, and routing it through UpdateDisplay would redraw the
-- whole display each one.
local function UpdateProcBar()
    local duration = ctx and ctx.p and ctx.p.duration
    if not duration then return end

    local left, full = state.procLeft, state.procDuration
    if not left or left <= 0 or not full or full <= 0 then
        if duration.fill:IsShown() then
            duration.ground:Hide()
            duration.track:Hide()
            duration.fill:Hide()
            duration.glow:Hide()
            duration.glowCore:Hide()
            SetBlizzardGlow(false)
        end
        return
    end

    if not duration.fill:IsShown() then
        duration.ground:Show()
        duration.track:Show()
        duration.fill:Show()
    end

    local fraction = left / full
    if fraction > 1 then fraction = 1 end
    local filled = duration.width * fraction
    if filled < 1 then filled = 1 end
    duration.fill:SetWidth(filled)
    duration.fill:SetVertexColor(RampColour(fraction))

    if left <= PROC_GLOW_SECONDS then
        -- Same rectangle as the fill, every frame: that is what keeps it inside.
        local wave = GlowWave(GetTime())

        duration.glow:SetWidth(filled)
        duration.glow:SetVertexColor(PROC_GLOW_COLOUR[1], PROC_GLOW_COLOUR[2],
            PROC_GLOW_COLOUR[3], PROC_GLOW_MIN + (PROC_GLOW_MAX - PROC_GLOW_MIN) * wave)

        duration.glowCore:SetWidth(filled)
        duration.glowCore:SetVertexColor(PROC_CORE_COLOUR[1], PROC_CORE_COLOUR[2],
            PROC_CORE_COLOUR[3], PROC_CORE_MIN + (PROC_CORE_MAX - PROC_CORE_MIN) * wave)

        if not duration.glow:IsShown() then
            duration.glow:Show()
            duration.glowCore:Show()
        end

        SetBlizzardGlow(true)
    elseif duration.glow:IsShown() then
        duration.glow:Hide()
        duration.glowCore:Hide()
        SetBlizzardGlow(false)
    end
end

local function Signature()
    return string.format("%s:%d:%d:%s", tostring(db.style),
        state.count, state.max, tostring(state.dawn))
end

--------------------------------------------------------------------
-- Hiding the client's own orb
--------------------------------------------------------------------

local function IsOwnFrame(name)
    if type(name) ~= "string" then return false end
    if name:find("SolarTracker", 1, true) then return true end
    if name:find("^LibDBIcon") then return true end
    return false
end

local function SuppressFrame(name)
    local frame = _G[name]
    if not frame or type(frame) ~= "table" or not frame.SetAlpha then return end
    pcall(function()
        if frame:GetAlpha() > 0 then frame:SetAlpha(0) end
        if frame.EnableMouse then frame:EnableMouse(false) end
    end)
end

local function RestoreFrame(name)
    local frame = _G[name]
    if not frame or type(frame) ~= "table" or not frame.SetAlpha then return end
    pcall(function()
        frame:SetAlpha(1)
        if frame.EnableMouse then frame:EnableMouse(true) end
    end)
end

-- Re-asserted on every tick: the client owns that frame and puts its alpha back
-- whenever it redraws, without ever firing OnShow.
local function EnforceHidden()
    if not db.enabled then return end
    if db.hideClientOrb then
        for _, name in ipairs(ST.CLIENT_FRAMES) do SuppressFrame(name) end
    end
    for name in pairs(db.hidden) do SuppressFrame(name) end
end

local function RestoreAll()
    for _, name in ipairs(ST.CLIENT_FRAMES) do RestoreFrame(name) end
    for name in pairs(db.hidden) do RestoreFrame(name) end
end

local function CatchUnderMouse()
    local focus = GetMouseFocus()
    if not focus then
        Print("nothing under the cursor.")
        return
    end
    local target, hops = focus, 0
    while target and hops < 8 do
        local name = target.GetName and target:GetName()
        if name and IsOwnFrame(name) then
            Print("that is this addon's own frame, refusing to hide it.")
            return
        end
        if name and name ~= "" then
            db.hidden[name] = true
            SuppressFrame(name)
            Print("hiding |cffffff00" .. name .. "|r. |cffffff00/solar unhide|r restores it.")
            return
        end
        target = target.GetParent and target:GetParent()
        hops = hops + 1
    end
    Print("that frame has no name, nothing to hide.")
end

--------------------------------------------------------------------
-- Frame
--------------------------------------------------------------------

local function BuildAnchor()
    anchor = CreateFrame("Frame", "SolarTrackerAnchor", UIParent)
    anchor:SetMovable(true)
    anchor:EnableMouse(true)
    anchor:RegisterForDrag("LeftButton")
    anchor:SetClampedToScreen(true)
    anchor:SetFrameStrata("MEDIUM")

    anchor:SetScript("OnDragStart", function(self)
        if IsControlKeyDown() then
            self:StartMoving()
            self.moving = true
        end
    end)

    anchor:SetScript("OnDragStop", function(self)
        if not self.moving then return end
        self:StopMovingOrSizing()
        self.moving = false
        local point, _, relPoint, x, y = self:GetPoint()
        db.point, db.relPoint, db.x, db.y = point, relPoint, x, y
    end)

    anchor:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Solar Tracker")
        GameTooltip:AddLine("Ctrl + left-drag to move", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    anchor:SetScript("OnLeave", function() GameTooltip:Hide() end)

    countText = anchor:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    countText:SetPoint("BOTTOM", anchor, "TOP", 0, 1)

    ctx = ST.NewContext(anchor, countText)
    ST.context = ctx

    -- What the client's glow attaches to: the duration bar's rectangle with a
    -- margin, so the halo has room around the bar instead of sitting on it.
    glowHost = CreateFrame("Frame", "SolarTrackerGlowHost", anchor)
    glowHost:SetPoint("BOTTOMLEFT", anchor, "BOTTOMLEFT", -GLOW_HOST_MARGIN, -GLOW_HOST_MARGIN)
    glowHost:SetWidth(ST.NOTCH_WIDTH + GLOW_HOST_MARGIN * 2)
    glowHost:SetHeight(ST.DURATION_HEIGHT + GLOW_HOST_MARGIN * 2)

    -- Below the display, not on it (2026-08-25). The client's glow is not only
    -- a halo: ActionButton_OverlayGlowPlayAnimIn sizes its `spark` to the whole
    -- host and its crawling `ants` to 0.95 of it, both centred -- so sitting in
    -- front it lit the bar end to end and the remaining time could not be read
    -- off it at all. In a lower strata the bar's own opaque ground covers the
    -- middle of the glow and only what spills past the edges shows, which is
    -- the halo that was wanted in the first place.
    glowHost:SetFrameStrata("LOW")     -- the anchor is MEDIUM
    ST.glowHost = glowHost

    BuildGlowOverlay()
    if not BlizzardGlowAvailable() then
        Print("|cffff8800no spell-proc glow on this client|r - the countdown bar will still flash, but the glow around it needs the ActionBarButtonSpellActivationAlert template.")
    end
end

local function ApplyPosition()
    anchor:ClearAllPoints()
    anchor:SetPoint(db.point, UIParent, db.relPoint, db.x, db.y)
    anchor:SetScale(db.scale)
end

--------------------------------------------------------------------
-- Visibility
--------------------------------------------------------------------

-- On screen only while it is worth reading: in combat, or with any target
-- picked, friendly or hostile. Holding Ctrl always reveals it, otherwise a
-- hidden frame could never be dragged.
local function ShouldShow()
    if not db.enabled then return false end
    if anchor.moving or IsControlKeyDown() then return true end
    if ST.testCount or ST.testDawn then return true end
    if UnitAffectingCombat("player") then return true end
    if UnitExists("target") then return true end
    return false
end

local function UpdateVisibility()
    if ShouldShow() then
        if not anchor:IsShown() then anchor:Show() end
    else
        if anchor:IsShown() then anchor:Hide() end
    end
end

local function UpdateDisplay(force)
    RefreshState()
    local signature = Signature()
    if signature == lastSignature and not force then return end
    lastSignature = signature
    Draw()
end

--------------------------------------------------------------------
-- Enabling
--------------------------------------------------------------------

local function ApplyEnabled()
    if db.enabled then
        EnforceHidden()
    else
        -- Never leave the character with no Solar Power display at all.
        RestoreAll()
        anchor:Hide()
    end
    UpdateVisibility()
end

local function SetEnabled(enabled, quiet)
    db.enabled = enabled and true or false
    ApplyEnabled()
    if not quiet then
        Print(db.enabled and "display |cff44ff44on|r."
            or "display |cffff4444off|r, the client's orb is back.")
    end
end

--------------------------------------------------------------------
-- Minimap button
--------------------------------------------------------------------

local menuFrame

local function InitializeMenu(self, level)
    if not level then return end

    local info = UIDropDownMenu_CreateInfo()
    info.text = "Solar Tracker"
    info.isTitle = true
    info.notCheckable = true
    UIDropDownMenu_AddButton(info, level)

    info = UIDropDownMenu_CreateInfo()
    info.text = "Show the display"
    info.checked = db.enabled
    info.keepShownOnClick = true
    info.func = function() SetEnabled(not db.enabled, true) end
    UIDropDownMenu_AddButton(info, level)

    info = UIDropDownMenu_CreateInfo()
    info.text = "Hide the client's orb"
    info.checked = db.hideClientOrb
    info.keepShownOnClick = true
    info.func = function()
        db.hideClientOrb = not db.hideClientOrb
        if db.hideClientOrb then
            EnforceHidden()
        else
            for _, name in ipairs(ST.CLIENT_FRAMES) do RestoreFrame(name) end
        end
    end
    UIDropDownMenu_AddButton(info, level)

end

local function ShowMenu()
    if not menuFrame then
        menuFrame = CreateFrame("Frame", "SolarTrackerMenu", UIParent, "UIDropDownMenuTemplate")
    end
    UIDropDownMenu_Initialize(menuFrame, InitializeMenu, "MENU")
    ToggleDropDownMenu(1, nil, menuFrame, "cursor", 0, 0)
end

local function SetupMinimapButton()
    local LDB = LibStub and LibStub("LibDataBroker-1.1", true)
    local LDBIcon = LibStub and LibStub("LibDBIcon-1.0", true)
    if not (LDB and LDBIcon) then
        Print("minimap button unavailable: LibDataBroker/LibDBIcon did not load.")
        return
    end

    local launcher = LDB:NewDataObject(ST.ADDON, {
        type = "launcher",
        text = "Solar Tracker",
        icon = "Interface\\Icons\\Spell_Holy_SurgeOfLight",
        OnClick = function(_, button)
            if button == "RightButton" then
                ShowMenu()
            else
                SetEnabled(not db.enabled, true)
            end
        end,
        OnTooltipShow = function(tooltip)
            tooltip:AddLine("Solar Tracker")
            tooltip:AddLine(db.enabled and "|cff44ff44Display on|r" or "|cffff4444Display off|r")
            tooltip:AddLine(" ")
            tooltip:AddLine("|cffffffffLeft-click|r toggles the display", 0.7, 0.7, 0.7)
            tooltip:AddLine("|cffffffffRight-click|r for options", 0.7, 0.7, 0.7)
        end,
    })

    -- Always visible on purpose, same as Advantage Tracker: toggling LibDBIcon's
    -- show/hide fights DragonUI's minimap button collector and makes it flicker.
    db.minimap.hide = false
    LDBIcon:Register(ST.ADDON, launcher, db.minimap)
end

--------------------------------------------------------------------
-- Events
--------------------------------------------------------------------

driver = CreateFrame("Frame")

local function SafeRegister(event)
    -- This client throws on unknown events, so one bad name must not abort the
    -- rest of the registrations.
    pcall(driver.RegisterEvent, driver, event)
end

driver:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local name = ...
        if name ~= ST.ADDON then return end

        -- Styles.lua is loaded from the toc, and the toc is only read when the
        -- game starts: a /reload after this file was added leaves the styles
        -- missing. Say so once instead of erroring on every frame, and leave
        -- the client's own orb alone so the character still has a display.
        if not (ST.styles and ST.NewContext) then
            Print("|cffff4444Styles.lua did not load|r - close the game fully and start it again. A /reload does not pick up a file that was added to the toc.")
            return
        end

        db = ST.InitDB()
        BuildAnchor()
        ApplyPosition()
        RefreshState()
        Relayout()
        Draw()
        UpdateProcBar()
        ApplyEnabled()
        SetupMinimapButton()
        return
    end

    if not db then return end
    UpdateDisplay()
    UpdateProcBar()
    UpdateVisibility()
end)

SafeRegister("ADDON_LOADED")
SafeRegister("PLAYER_ENTERING_WORLD")
SafeRegister("UNIT_AURA")
SafeRegister("PLAYER_TARGET_CHANGED")
SafeRegister("PLAYER_REGEN_DISABLED")
SafeRegister("PLAYER_REGEN_ENABLED")
SafeRegister("MODIFIER_STATE_CHANGED")

-- Safety net: aura events are not trusted on this client, and the client puts
-- its orb back without firing anything.
--
-- The number itself is re-read every frame -- UNIT_AURA is unreliable here, so
-- polling is what makes it move the instant the server changes the stack, and
-- ST.ReadResource is one aura pass. The two costly jobs, the visibility check
-- and putting the client's orb back down, stay on the old 0.2s tick.
local elapsedSince = 0
driver:SetScript("OnUpdate", function(self, delta)
    if not db then return end

    UpdateDisplay()
    UpdateProcBar()

    elapsedSince = elapsedSince + delta
    if elapsedSince < 0.2 then return end
    elapsedSince = 0
    UpdateVisibility()
    EnforceHidden()
end)

--------------------------------------------------------------------
-- Slash commands
--------------------------------------------------------------------

local function DumpDebug()
    Print("stacking auras on you:")
    local found = 0
    for _, filter in ipairs({ "HELPFUL", "HARMFUL" }) do
        local misses = 0
        for i = 1, 40 do
            local name, _, _, count, _, _, _, _, _, _, spellId = UnitAura("player", i, filter)
            if not name then
                misses = misses + 1
                if misses >= 3 then break end
            else
                misses = 0
            end
            if name and ((count and count > 1) or spellId == ST.SOLAR_SPELL_ID or spellId == ST.DAWN_SPELL_ID) then
                Print(string.format("  %s |cffffff00%s|r  stacks %s  id %s",
                    filter == "HELPFUL" and "buff " or "debuff",
                    name, tostring(count or 0), tostring(spellId or "?")))
                found = found + 1
            end
        end
    end
    if found == 0 then Print("  none.") end

    local _, _, procLeft, procDuration = ST.ReadResource()
    if procLeft then
        Print(string.format("Battle Cleric (%d): |cffffff00%.1fs|r left of %.0fs",
            ST.PROC_SPELL_ID, procLeft, procDuration or 0))
    else
        Print("Battle Cleric (" .. ST.PROC_SPELL_ID .. "): not up, or up with no duration.")
    end

    -- What the display currently believes, next to what it actually drew. If
    -- the bar looks unlit while stacks are climbing, this says in one line
    -- which half is wrong: a count that never arrived, or a count that arrived
    -- and was not painted.
    local fill = ctx and ctx.p and ctx.p.fill
    Print(string.format("state: count %d of %d, dawn %s, atMax %s, layout %s",
        state.count, state.max, tostring(state.dawn), tostring(state.atMax),
        tostring(layoutKey)))
    Print(string.format("drawn: fill %s at %.1fpx, anchor %s, saved cap %s",
        fill and tostring(fill:IsShown()) or "missing",
        fill and fill:GetWidth() or 0,
        anchor and tostring(anchor:IsShown()) or "missing",
        tostring(db and db.max)))

    Print("Solar Power cap from the client: " .. tostring(ST.GetSolarMax() or "unknown"))
    Print("Dawn charges at full: " .. tostring(ST.GetDawnMax(0)))
    Print("CoAResourceOrb exists: " .. tostring(_G["CoAResourceOrb"] ~= nil))
end

SLASH_SOLARTRACKER1 = "/solar"
SLASH_SOLARTRACKER2 = "/solartracker"

SlashCmdList["SOLARTRACKER"] = function(msg)
    local cmd, rest = msg:match("^(%S*)%s*(.-)$")
    cmd = (cmd or ""):lower()

    if cmd == "on" or cmd == "off" or cmd == "toggle" then
        if cmd == "toggle" then
            SetEnabled(not db.enabled)
        else
            SetEnabled(cmd == "on")
        end

    elseif cmd == "orb" then
        db.hideClientOrb = not db.hideClientOrb
        if db.hideClientOrb then
            EnforceHidden()
            Print("the client's own orb is hidden.")
        else
            for _, name in ipairs(ST.CLIENT_FRAMES) do RestoreFrame(name) end
            Print("the client's own orb is visible again.")
        end

    elseif cmd == "test" then
        if rest == "" or rest:lower() == "off" then
            ST.testCount, ST.testDawn = nil, nil
            ST.testProc, ST.testProcDuration = nil, nil
            Print("test values cleared.")
        else
            local which, value = rest:match("^(%a*)%s*(%d*)$")
            if which == "dawn" then
                ST.testCount = nil
                ST.testDawn = tonumber(value) or 3
                Print("pretending Dawn has |cffffff00" .. ST.testDawn .. "|r charges left.")
            elseif which == "proc" then
                ST.testProc = tonumber(value) or 8
                ST.testProcDuration = ST.testProc
                Print("pretending Battle Cleric has |cffffff00" .. ST.testProc .. "|rs left. It will not drain -- it is a still preview.")
            elseif tonumber(rest) then
                ST.testDawn = nil
                ST.testCount = math.max(0, math.floor(tonumber(rest)))
                Print("pretending Solar Power is |cffffff00" .. ST.testCount .. "|r.")
            else
                Print("usage: |cffffff00/solar test 14|r, |cffffff00/solar test dawn 3|r, |cffffff00/solar test off|r")
            end
        end
        UpdateDisplay(true)
        UpdateProcBar()
        UpdateVisibility()

    elseif cmd == "scale" and tonumber(rest) then
        db.scale = math.max(0.3, math.min(3, tonumber(rest)))
        anchor:SetScale(db.scale)
        Print("scale set to " .. db.scale .. ".")

    elseif cmd == "catch" then
        Print("hover the frame you want gone. Reading the cursor in 5 seconds...")
        local timer = CreateFrame("Frame")
        local waited = 0
        timer:SetScript("OnUpdate", function(self, delta)
            waited = waited + delta
            if waited >= 5 then
                self:SetScript("OnUpdate", nil)
                CatchUnderMouse()
            end
        end)

    elseif cmd == "hide" and rest ~= "" then
        db.hidden[rest] = true
        SuppressFrame(rest)
        Print("hiding |cffffff00" .. rest .. "|r.")

    elseif cmd == "unhide" then
        RestoreAll()
        db.hidden = {}
        db.hideClientOrb = false
        Print("everything this addon hid is back, including the client's orb.")

    elseif cmd == "list" then
        if db.hideClientOrb then Print("hidden: |cffffff00CoAResourceOrb|r (the client's own)") end
        for name in pairs(db.hidden) do
            Print("hidden: |cffffff00" .. name .. "|r")
        end

    elseif cmd == "debug" then
        DumpDebug()

    elseif cmd == "reset" then
        db.point, db.relPoint = ST.defaults.point, ST.defaults.relPoint
        db.x, db.y, db.scale = ST.defaults.x, ST.defaults.y, ST.defaults.scale
        ApplyPosition()
        Print("position reset.")

    else
        Print("Solar Power for the Sun Cleric. Shows in combat or with a target; Ctrl + left-drag to move.")
        Print("While Dawn is up the row shows the charges left, not the seconds.")
        Print("|cffffff00/solar toggle|r - show or hide the display")
            Print("|cffffff00/solar orb|r - give the client's own orb back, or take it away")
        Print("A bar under the display counts down Battle Cleric while it is up.")
    Print("|cffffff00/solar test 14|r - preview a value (|cffffff00test dawn 3|r, |cffffff00test proc 8|r, |cffffff00test off|r)")
        Print("|cffffff00/solar scale N|r, |cffffff00/solar reset|r")
        Print("|cffffff00/solar debug|r - what this character's auras and caps actually read")
    end
end
