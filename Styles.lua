--[[
    Solar Tracker -- the look.

    One display, drawn in one style: a notched bar. The ten alternatives and
    the style picker were deleted on 2026-08-24 at Deniz's instruction ("focus
    on the notched bar, delete everything else") -- the same call as v2.0's,
    which threw away five art styles as over-designed. The backup taken before
    the deletion is SolarTracker_backup_20260824_191858_pre_notched_only, in
    Interface\AddOns and zipped in Documents.

    Two facts are drawn and nothing else: how much of the resource is banked
    out of its cap, and how much of Battle Cleric is left. Both are the same
    bar shape, stacked, so the second reads as another track of the same
    widget rather than as a separate display. The resource bar is cut into
    segments because the resource is counted in whole points; the duration bar
    is smooth because time is not, and that is also what tells them apart at a
    glance without a second colour. In its last seconds the duration bar
    flashes from within, and the client's own spell-proc glow lights up around
    it -- see the note in Display.lua.

    Drawing is WHITE8X8 tinted with SetVertexColor only -- no art files, so
    nothing here can be broken by a launcher repair.

    The style provides:
        label   text for the tooltip
        Layout(ctx, max)         builds the textures and sizes the anchor.
                                 Called only when the cap changes.
        Paint(ctx, state, col)   colours what Layout built. Called whenever the
                                 count changes -- NOT for the duration, which
                                 moves every frame and is driven straight from
                                 Display.lua's UpdateProcBar.

    ctx.Tex(layer) hands out textures from a shared pool, ctx.Finish() hides
    whatever is left over, and ctx.p is a scratch table the style keeps its own
    references in between the two calls.
]]

local ST = SolarTracker

local WHITE = "Interface\\Buttons\\WHITE8X8"

ST.styles = {}
ST.styleOrder = {}

local function Register(key, def)
    def.key = key
    ST.styles[key] = def
    table.insert(ST.styleOrder, key)
end

--------------------------------------------------------------------
-- The texture pool
--------------------------------------------------------------------

function ST.NewContext(anchor, text)
    local pools = { BACKGROUND = {}, ARTWORK = {}, OVERLAY = {} }
    local used = { BACKGROUND = 0, ARTWORK = 0, OVERLAY = 0 }

    local ctx = { anchor = anchor, text = text, p = {} }

    -- The font the number is drawn in, so a style that wants a bigger numeral
    -- can ask for one and every other style can put it back.
    local baseFont, baseSize, baseFlags
    if text.GetFont then
        local ok, path, size, flags = pcall(text.GetFont, text)
        if ok and path then baseFont, baseSize, baseFlags = path, size, flags end
    end

    function ctx.Begin()
        used.BACKGROUND, used.ARTWORK, used.OVERLAY = 0, 0, 0
        ctx.p = {}
    end

    function ctx.Tex(layer)
        used[layer] = used[layer] + 1
        local list = pools[layer]
        local tex = list[used[layer]]
        if not tex then
            tex = anchor:CreateTexture(nil, layer)
            list[used[layer]] = tex
        end
        -- Handed back blank every time, not just when new. A pooled texture
        -- that once drew a sparkle keeps that art and its ADD blending, and
        -- the pool index a given rectangle lands on moves when the cap
        -- changes -- so without this reset a Dawn (8 wide) then Solar (20
        -- wide) relayout drew notch cuts as stars.
        tex:SetTexture(WHITE)
        tex:SetBlendMode("BLEND")
        tex:SetTexCoord(0, 1, 0, 1)
        tex:SetVertexColor(1, 1, 1, 1)
        tex:ClearAllPoints()
        tex:Show()
        return tex
    end

    function ctx.Finish()
        for layer, list in pairs(pools) do
            for i = used[layer] + 1, table.getn(list) do
                list[i]:Hide()
            end
        end
    end

    -- Places a texture by its bottom-left corner inside the anchor.
    function ctx.At(tex, x, y, w, h)
        tex:SetWidth(w)
        tex:SetHeight(h)
        tex:SetPoint("BOTTOMLEFT", anchor, "BOTTOMLEFT", x, y)
        return tex
    end

    function ctx.Text(point, relPoint, x, y, size)
        text:ClearAllPoints()
        text:SetPoint(point, anchor, relPoint, x, y)
        if baseFont and text.SetFont then
            pcall(text.SetFont, text, baseFont, size or baseSize, baseFlags)
        end
    end

    return ctx
end

--------------------------------------------------------------------
-- Small shared helpers
--------------------------------------------------------------------

local function Tint(tex, colour, alpha)
    tex:SetVertexColor(colour[1], colour[2], colour[3], alpha or 1)
end

-- A dark ground one pixel proud of the thing it sits under, which is what
-- gives an edge without drawing a border.
local function Ground(ctx, x, y, w, h)
    local tex = ctx.At(ctx.Tex("BACKGROUND"), x - 1, y - 1, w + 2, h + 2)
    tex:SetVertexColor(0, 0, 0, 0.85)
    return tex
end

local function Fraction(count, max)
    if max <= 0 then return 0 end
    local pct = count / max
    if pct < 0 then return 0 end
    if pct > 1 then return 1 end
    return pct
end

--------------------------------------------------------------------
-- The display: a notched bar, with the Battle Cleric bar under it
--------------------------------------------------------------------

local NOTCH_W, NOTCH_H = 130, 9

-- The duration bar is the same width and the same thickness as the resource
-- bar and sits directly beneath it. Two pixels apart is no visible gap once
-- each has its one-pixel ground, which is what makes them read as one widget
-- with two tracks.
local DURATION_H = NOTCH_H
local DURATION_GAP = 2

-- How far in from the bar's top and bottom the bright core of the glow sits.
local GLOW_CORE_INSET = 3

-- The notch cuts, and what they fade to at the cap.
local CUT_ALPHA = 0.9
local CUT_ALPHA_MAX = 0.15



ST.NOTCH_WIDTH, ST.NOTCH_HEIGHT = NOTCH_W, NOTCH_H

-- Display.lua walks the pixel glow around the duration bar and needs its
-- rectangle in anchor space. The row sits at the bottom, so its origin is 0.
ST.DURATION_HEIGHT = DURATION_H
ST.DURATION_ROW_MIDDLE = DURATION_H / 2

Register("notched", {
    label = "Notched bar",

    Layout = function(ctx, max)
        local rowY = DURATION_H + DURATION_GAP

        ctx.anchor:SetWidth(NOTCH_W)
        ctx.anchor:SetHeight(rowY + NOTCH_H + 15)

        -- Resource, on top.
        Ground(ctx, 0, rowY, NOTCH_W, NOTCH_H)
        ctx.p.track = ctx.At(ctx.Tex("ARTWORK"), 0, rowY, NOTCH_W, NOTCH_H)
        ctx.p.fill = ctx.At(ctx.Tex("ARTWORK"), 0, rowY, 1, NOTCH_H)

        -- The cuts go on top of both, so the bar reads as segments however
        -- full it is.
        local step = NOTCH_W / max
        ctx.p.cuts = {}
        for i = 1, max - 1 do
            local cut = ctx.At(ctx.Tex("OVERLAY"), i * step, rowY, 1, NOTCH_H)
            cut:SetVertexColor(0, 0, 0, 0.9)
            table.insert(ctx.p.cuts, cut)
        end

        -- Battle Cleric, underneath. No cuts: it is a continuous timer.
        -- Hidden until the buff is actually up -- an empty second track
        -- sitting there permanently is noise.
        --
        -- The glow is laid over the fill and given exactly the fill's
        -- rectangle every frame, so it brightens the bar from the inside and
        -- cannot reach past the bar's own width -- no outer glow art, nothing
        -- spilling over the edge.
        ctx.p.duration = {
            ground = Ground(ctx, 0, 0, NOTCH_W, DURATION_H),
            track = ctx.At(ctx.Tex("ARTWORK"), 0, 0, NOTCH_W, DURATION_H),
            fill = ctx.At(ctx.Tex("ARTWORK"), 0, 0, 1, DURATION_H),
            glow = ctx.At(ctx.Tex("OVERLAY"), 0, 0, 1, DURATION_H),
            -- A hotter, thinner band down the middle of the same rectangle.
            -- A flat wash of light only tints the bar; the bright core is what
            -- makes it read as shining rather than as a paler colour.
            glowCore = ctx.At(ctx.Tex("OVERLAY"), 0, GLOW_CORE_INSET, 1,
                DURATION_H - GLOW_CORE_INSET * 2),
            width = NOTCH_W,
        }
        for _, layer in ipairs({ ctx.p.duration.glow, ctx.p.duration.glowCore }) do
            layer:SetBlendMode("ADD")
            layer:Hide()
        end


        ctx.Text("BOTTOM", "TOP", 0, 0)
    end,

    Paint = function(ctx, state, col)
        Tint(ctx.p.track, col.empty, 0.85)
        local width = NOTCH_W * Fraction(state.count, state.max)
        if width < 1 then
            ctx.p.fill:Hide()
        else
            ctx.p.fill:Show()
            ctx.p.fill:SetWidth(width)
            Tint(ctx.p.fill, col.fill, 1)
        end

        -- At the cap the notches all but disappear, so the bar stops reading as
        -- twenty separate points and becomes one solid lit bar. That is what
        -- marks maximum now: the fill is the same bright gold at every count,
        -- so a dimmer colour can no longer be the difference.
        local cutAlpha = state.atMax and CUT_ALPHA_MAX or CUT_ALPHA
        for _, cut in ipairs(ctx.p.cuts or {}) do
            cut:SetVertexColor(0, 0, 0, cutAlpha)
        end

        -- The empty duration track has to be re-tinted after a relayout hands
        -- out fresh textures. Its fill is not painted here: that colour moves
        -- with the time left, so UpdateProcBar owns it and sets it every frame.
        Tint(ctx.p.duration.track, col.empty, 0.85)
    end,
})

ST.DEFAULT_STYLE = "notched"

function ST.GetStyle(key)
    return ST.styles[key] or ST.styles[ST.DEFAULT_STYLE]
end
