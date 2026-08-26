"""Offline harness for SolarTracker.

Stubs the 3.3.5 API, loads the real Core.lua and Display.lua, and checks the
three things that matter: Solar Power stacks light the row, Dawn switches the
row to its charges and counts them down, and the client's CoAResourceOrb is
suppressed while the display is on and given back when it is off.

Run:  py test_solar.py        (needs `pip install lupa`; import lupa.lua51 --
      plain `from lupa import LuaRuntime` is Lua 5.5 and has no loadstring)
"""
import os

from lupa.lua51 import LuaRuntime

ADDON = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

lua = LuaRuntime(unpack_returned_tuples=True)

lua.execute(r"""
TEST = { auras = {}, combat = false, target = false, time = 1000, prints = {} }

local function widgetBase(obj)
    obj.points = {}
    obj.shown = true
    obj.alpha = 1
    obj.mouse = true
    obj.width, obj.height = 0, 0
    function obj:SetPoint(...) table.insert(self.points, {...}) end
    function obj:SetAllPoints(rel)
        self.points = {}
        self.allPoints = rel
    end
    function obj:ClearAllPoints() self.points = {} end
    function obj:GetPoint() return self.points[1] and unpack(self.points[1]) end
    function obj:SetWidth(v) self.width = v end
    function obj:SetHeight(v) self.height = v end
    function obj:GetWidth() return self.width end
    function obj:GetHeight() return self.height end
    function obj:Show() self.shown = true end
    function obj:Hide() self.shown = false end
    function obj:IsShown() return self.shown end
    function obj:SetAlpha(v) self.alpha = v end
    function obj:GetAlpha() return self.alpha end
    function obj:EnableMouse(v) self.mouse = v end
    function obj:GetName() return self.name end
    function obj:GetParent() return self.parent end
    return obj
end

TEXTURES = {}
FONTSTRINGS = {}

local function newTexture(parent, layer)
    local tex = widgetBase({ parent = parent, layer = layer, kind = "texture" })
    table.insert(TEXTURES, tex)
    function tex:SetTexture(path) self.texture = path end
    function tex:SetVertexColor(r, g, b, a) self.colour = { r, g, b, a or 1 } end
    function tex:SetTexCoord(...) end
    function tex:SetBlendMode(mode) end
    return tex
end

local function newFontString(parent)
    local fs = widgetBase({ parent = parent, kind = "fontstring" })
    table.insert(FONTSTRINGS, fs)
    function fs:SetFont(...) end
    function fs:SetText(t) self.text = t end
    function fs:GetText() return self.text end
    function fs:SetTextColor(r, g, b) self.colour = { r, g, b } end
    return fs
end

FRAMES = {}

function CreateFrame(frameType, name, parent, template)
    local frame = widgetBase({ name = name, parent = parent, scripts = {}, events = {} })
    frame.CreateTexture = function(self, n, layer) return newTexture(self, layer) end
    frame.CreateFontString = function(self, n, layer) return newFontString(self) end
    frame.SetScript = function(self, event, fn) self.scripts[event] = fn end
    frame.GetScript = function(self, event) return self.scripts[event] end
    frame.RegisterEvent = function(self, event) self.events[event] = true end
    frame.SetMovable = function() end
    frame.RegisterForDrag = function() end
    frame.SetClampedToScreen = function() end
    frame.SetFrameStrata = function(self, strata) self.strata = strata end
    frame.SetScale = function(self, v) self.scale = v end
    frame.StartMoving = function() end
    frame.StopMovingOrSizing = function() end
    if template == "ActionBarButtonSpellActivationAlert" then
        TEST_MakeGlowTemplate(frame)
        frame.shown = false
    end
    table.insert(FRAMES, frame)
    if name then _G[name] = frame end
    return frame
end

UIParent = CreateFrame("Frame", "UIParent")
-- The client's own Solar Power orb, the frame the addon has to suppress.
CoAResourceOrb = CreateFrame("Button", "CoAResourceOrb")

DEFAULT_CHAT_FRAME = { AddMessage = function(self, msg) table.insert(TEST.prints, msg) end }

function GetTime() return TEST.time end
function UnitAffectingCombat() return TEST.combat end
function UnitExists() return TEST.target and true or false end
function UnitCanAttack() return false end
function UnitIsDead() return false end
function IsControlKeyDown() return false end
function GetMouseFocus() return nil end
function CloseDropDownMenus() end
function UIDropDownMenu_CreateInfo() return {} end
function UIDropDownMenu_AddButton() end
function UIDropDownMenu_Initialize() end
function ToggleDropDownMenu() end
function GetSpellMaxStack(id) return id == 500149 and 20 or 0 end
C_CharacterAdvancement = { GetTalentRankByID = function(id) return 3 end }
GameTooltip = { SetOwner = function() end, AddLine = function() end,
                Show = function() end, Hide = function() end }
SlashCmdList = {}
function LibStub() return nil end

-- lupa gives Python a new wrapper object on every access, so object identity
-- has to be decided in Lua rather than with `is` on the Python side. Both
-- harnesses use these.
function TEST_IsChildOf(obj, parent)
    return obj ~= nil and obj.parent == parent
end

function TEST_ChildFrameOf(parent)
    for _, frame in ipairs(FRAMES) do
        if frame.parent == parent then return frame end
    end
    return nil
end

-- The client's spell-proc glow. Real on this client (ActionButton.lua plus the
-- ActionBarButtonSpellActivationAlert template in ActionBarFrame.xml); here it
-- only has to record that the addon asked for it and on which frame.
-- The client's spell-proc glow template. The addon builds its own frame from
-- it rather than calling ActionButton_ShowOverlayGlow, so what has to be stubbed
-- is the template's pieces and their animation groups.
--
-- ActionButton_ShowOverlayGlow is deliberately NOT defined here: if the addon
-- ever goes back to the shared-pool route, these tests will not quietly pass.
GLOW = { plays = 0 }

function TEST_MakeGlowTemplate(frame)
    local pieces = { "spark", "innerGlow", "innerGlowOver", "outerGlow", "outerGlowOver", "ants" }
    for _, key in ipairs(pieces) do
        local piece = { playing = false }
        function piece:SetWidth(v) self.width = v end
        function piece:SetHeight(v) self.height = v end
        piece.animIn = {}
        function piece.animIn:Play()
            piece.playing = true
            GLOW.plays = GLOW.plays + 1
        end
        function piece.animIn:Stop() piece.playing = false end
        function piece.animIn:IsPlaying() return piece.playing end
        frame[key] = piece
    end
    return frame
end

function UnitAura(unit, index, filter)
    local list = TEST.auras[filter or "HELPFUL"]
    if not list then return nil end
    local aura = list[index]
    if not aura then return nil end
    return aura.name, nil, nil, aura.count, nil, aura.duration, aura.expiration,
        nil, nil, nil, aura.spellId
end
""")

for name in ("Core.lua", "Styles.lua", "Display.lua"):
    source = open(os.path.join(ADDON, name), encoding="utf-8").read()
    lua.eval("function(src, chunkname) return loadstring(src, chunkname) end")(source, name)()

G = lua.globals()
ST = G.SolarTracker


def set_auras(solar=None, dawn=None, proc=None):
    """Solar Power is a buff, Dawn is a debuff -- as the client's own code reads them.

    proc is (seconds left, full duration) for Battle Cleric, which is a timer
    rather than a stack count.
    """
    helpful, harmful = [], []
    if solar:
        helpful.append({"name": "Solar Power", "count": solar, "spellId": 500149})
    if dawn:
        harmful.append({"name": "Dawn", "count": dawn, "spellId": 804584})
    if proc:
        left, duration = proc
        helpful.append({"name": "Battle Cleric", "count": 1, "spellId": 562316,
                        "duration": duration, "expiration": G.TEST.time + left})
    G.TEST.auras = lua.table_from({
        "HELPFUL": lua.table_from([lua.table_from(a) for a in helpful]),
        "HARMFUL": lua.table_from([lua.table_from(a) for a in harmful]),
    })


driver = None
for frame in list(G.FRAMES.values()):
    if frame.scripts and frame.scripts["OnEvent"]:
        driver = frame
driver.scripts["OnEvent"](driver, "ADDON_LOADED", "SolarTracker")

anchor = G.SolarTrackerAnchor
slash = G.SlashCmdList["SOLARTRACKER"]
failures = []


def tick():
    driver.scripts["OnEvent"](driver, "UNIT_AURA", "player")
    driver.scripts["OnUpdate"](driver, 0.3)


def bars():
    """(resource fraction, duration fraction) read off the drawn rectangles.

    The notched bar draws, per track, a dark ground, a full-width empty track
    and a fill whose width is the fraction. The two tracks are told apart by
    height offset: the resource bar sits above the duration bar, so the
    resource fill is the one with the larger y.
    """
    fills = []
    for texture in list(G.TEXTURES.values()):
        if texture.layer != "ARTWORK" or texture.colour is None:
            continue
        if not texture.shown or not G.TEST_IsChildOf(texture, anchor):
            continue
        point = texture.points[1]
        if point is None:
            continue
        spec = list(point.values())
        y = spec[4]
        fills.append((y, texture.width))

    if not fills:
        return None, None

    width = max(w for _, w in fills)          # the full-width empty tracks
    rows = {}
    for y, w in fills:
        rows.setdefault(y, []).append(w)

    def fraction(y):
        if y not in rows:
            return None
        # An empty bar hides its fill entirely, leaving only the empty track,
        # so a row with one rectangle on it is a bar at zero.
        if len(rows[y]) < 2:
            return 0.0
        # the narrower of the two rectangles on this row is the fill
        return min(rows[y]) / float(width)

    ys = sorted(rows)
    if len(ys) == 1:
        # only the resource track is up; the duration bar is hidden
        return fraction(ys[0]), None
    return fraction(ys[-1]), fraction(ys[0])


def duration_fill_colour():
    """The duration bar's fill colour, as (r, g, b).

    On the lower row the empty track is the dark EMPTY grey and the fill is the
    ramp, which is always bright red-ish, so they are told apart by red.
    """
    lowest, found = None, None
    for texture in list(G.TEXTURES.values()):
        if texture.layer != "ARTWORK" or texture.colour is None:
            continue
        if not texture.shown or not G.TEST_IsChildOf(texture, anchor):
            continue
        point = texture.points[1]
        if point is None:
            continue
        y = list(point.values())[4]
        colour = list(texture.colour.values())
        if lowest is None or y < lowest:
            lowest, found = y, None
        if y == lowest and colour[0] > 0.5:
            found = tuple(colour[:3])
    return found


def resource_fill_colour():
    """The resource bar's fill colour, as (r, g, b).

    The upper row holds a dark empty track and the fill; the fill is the bright
    one, so they are told apart by green -- EMPTY is 0.18 there and every fill
    colour the addon uses is well above 0.5.
    """
    highest, found = None, None
    for texture in list(G.TEXTURES.values()):
        if texture.layer != "ARTWORK" or texture.colour is None:
            continue
        if not texture.shown or not G.TEST_IsChildOf(texture, anchor):
            continue
        point = texture.points[1]
        if point is None:
            continue
        y = list(point.values())[4]
        colour = list(texture.colour.values())
        if highest is None or y > highest:
            highest, found = y, None
        if y == highest and colour[1] > 0.5:
            found = tuple(colour[:3])
    return found


def cut_alphas():
    """The alpha of every notch cut on the resource row."""
    rows = []
    for texture in list(G.TEXTURES.values()):
        if texture.layer != "OVERLAY" or not texture.shown:
            continue
        if not G.TEST_IsChildOf(texture, anchor) or texture.points[1] is None:
            continue
        y = list(texture.points[1].values())[4]
        rows.append((y, texture))
    if not rows:
        return []
    top = max(y for y, _ in rows)
    out = []
    for y, texture in rows:
        if y != top:
            continue
        colour = list(texture.colour.values()) if texture.colour else None
        if colour and len(colour) > 3:
            out.append(colour[3])
    return out


def glow():
    """The duration bar's glow layers, as a list of (width, alpha).

    They are the OVERLAY textures on the lower row -- the resource bar's notch
    cuts are on the upper one. Empty list means the glow is off.
    """
    lowest = None
    for texture in list(G.TEXTURES.values()):
        if texture.layer != "ARTWORK" or texture.colour is None:
            continue
        if not G.TEST_IsChildOf(texture, anchor) or texture.points[1] is None:
            continue
        y = list(texture.points[1].values())[4]
        if lowest is None or y < lowest:
            lowest = y

    out = []
    for texture in list(G.TEXTURES.values()):
        if texture.layer != "OVERLAY" or not texture.shown:
            continue
        if not G.TEST_IsChildOf(texture, anchor) or texture.points[1] is None:
            continue
        y = list(texture.points[1].values())[4]
        # the core band is inset from the bottom of the same row
        if y != lowest and y != lowest + 3:
            continue
        colour = list(texture.colour.values()) if texture.colour else None
        alpha = colour[3] if colour and len(colour) > 3 else None
        out.append((texture.width, alpha))
    return out


def glow_on():
    """Whether the glow overlay is showing."""
    overlay = ST.glowOverlay
    return overlay is not None and bool(overlay.shown)


def glow_plays():
    """How many animation groups have been started since the counter was reset."""
    return int(G.GLOW.plays)


def resource():
    return bars()[0]


def duration():
    return bars()[1]


def label():
    """The number above the bar."""
    for fontstring in list(G.FONTSTRINGS.values()):
        if not G.TEST_IsChildOf(fontstring, anchor):
            continue
        if fontstring.text is not None:
            return fontstring.text
    return None


# Solar Power: the bar fills to the stacks out of the cap.
for count in (0, 1, 7, 19, 20):
    set_auras(solar=count)
    tick()
    want = count / 20.0
    got = resource()
    if got is None or abs(got - want) > 0.02:
        failures.append("solar %d: filled %s, expected %.2f" % (count, got, want))
    if label() != str(count):
        failures.append("solar %d: label %r" % (count, label()))

# Every banked point is drawn at the same full brightness -- the bar used to be
# a dimmer amber below the cap, which read as unlit while stacks were climbing.
# The cap is marked by the notches fading instead.
lit = []
for count in (1, 5, 13, 19, 20):
    set_auras(solar=count)
    tick()
    colour = resource_fill_colour()
    if colour is None:
        failures.append("no resource fill colour at %d stacks" % count)
        break
    lit.append((count, colour))

if len(lit) == 5:
    at_max = lit[-1][1]
    for count, colour in lit:
        if colour != at_max:
            failures.append("%d stacks is drawn %s, dimmer than the %s at the cap"
                            % (count, colour, at_max))
        if not (colour[1] > 0.9 and colour[2] > 0.6):
            failures.append("%d stacks is not the pale gold: %s" % (count, colour))

set_auras(solar=19)
tick()
below = cut_alphas()
set_auras(solar=20)
tick()
at_cap = cut_alphas()
if not below or not at_cap:
    failures.append("no notch cuts drawn on the resource row")
else:
    if len(below) != 19 or len(at_cap) != 19:
        failures.append("expected 19 notch cuts, read %d below the cap and %d at it"
                        % (len(below), len(at_cap)))
    if max(below) < 0.8:
        failures.append("the notches are already faint below the cap: %s" % max(below))
    if max(at_cap) > 0.3:
        failures.append("the notches did not fade at the cap: %s" % max(at_cap))

# Dawn: the row becomes the charges (5 base + rank 3 = 8) and counts them down.
if int(ST.GetDawnMax(0)) != 8:
    failures.append("Dawn maximum read %s, expected 8" % ST.GetDawnMax(0))

for charges in (8, 5, 1):
    set_auras(solar=0, dawn=charges)
    tick()
    want = charges / 8.0
    got = resource()
    if got is None or abs(got - want) > 0.02:
        failures.append("dawn %d: filled %s, expected %.2f" % (charges, got, want))
    if label() != "Dawn %d" % charges:
        failures.append("dawn %d: label %r" % (charges, label()))

# Battle Cleric: a second bar of the same shape directly under the resource
# one, draining against its own duration.
G.TEST.combat = True
set_auras(solar=5)
tick()
if duration() is not None:
    failures.append("duration bar drawn while Battle Cleric is not up")

for left, full, want in ((20, 20, 1.0), (15, 20, 0.75), (5, 20, 0.25)):
    set_auras(solar=5, proc=(left, full))
    tick()
    got = duration()
    if got is None:
        failures.append("duration bar missing with %ss of Battle Cleric left" % left)
    elif abs(got - want) > 0.02:
        failures.append("Battle Cleric %s/%ss filled %.3f, expected %.3f"
                        % (left, full, got, want))
    if abs((resource() or 0) - 5 / 20.0) > 0.02:
        failures.append("the resource bar moved while the duration bar was up: %s"
                        % resource())
    if label() != "5":
        failures.append("the count changed while the duration bar was up: %r" % label())

# The fill darkens on the way down: gold while it is fresh, red at the end,
# and never the same colour at two very different times.
seen = []
for left in (20, 14, 8, 4, 1):
    set_auras(solar=5, proc=(left, 20))
    tick()
    colour = duration_fill_colour()
    if colour is None:
        failures.append("no duration fill colour at %ss left" % left)
        break
    seen.append(colour)

if len(seen) == 5:
    full, empty = seen[0], seen[-1]
    if not (full[1] > 0.9 and full[2] > 0.6):
        failures.append("a fresh Battle Cleric bar is not the pale gold: %s" % (full,))
    if not (empty[1] < 0.35 and empty[2] < 0.3):
        failures.append("an almost-gone Battle Cleric bar is not red: %s" % (empty,))
    greens = [c[1] for c in seen]
    if greens != sorted(greens, reverse=True):
        failures.append("the fill did not darken steadily on the way down: %s" % greens)

# The last four seconds: the bar flashes and the client's proc glow comes up
# around it.
set_auras(solar=5, proc=(6, 20))
tick()
if glow():
    failures.append("the bar glowed with 6s left, which is outside the last four")
if glow_on():
    failures.append("the proc glow was up with 6s left, outside the last four")

# Sampled across a full flash rather than at four arbitrary moments: a flash is
# supposed to have a dark phase, so what matters is that it reaches full
# brightness and swings hard, not that it never dips.
# Counted from here, so this is one Battle Cleric coming up and staying up --
# the glow legitimately starts again for each new buff.
G.GLOW.plays = 0

peaks, layer_counts, positions = [], [], []
for step in range(24):
    G.TEST.time = 1000 + step * 0.05
    set_auras(solar=5, proc=(3, 20))
    tick()

    layers = glow()
    if not layers:
        failures.append("no glow with 3s left")
        break
    layer_counts.append(len(layers))

    fill_width = (duration() or 0) * 130
    for width, alpha in layers:
        if abs(width - fill_width) > 1:
            failures.append("a glow layer is %s wide, the fill is %s -- it must not exceed it"
                            % (width, fill_width))
        if alpha is None or alpha > 1.0 or alpha < 0:
            failures.append("glow alpha %s is not a usable alpha" % alpha)
    peaks.append(max(a for _, a in layers if a is not None))

    if not glow_on():
        failures.append("the proc glow is not up with 3s left")
        break

if peaks:
    if max(peaks) < 0.95:
        failures.append("the glow only reaches %.2f -- it never really shines" % max(peaks))
    if max(peaks) - min(peaks) < 0.4:
        failures.append("the glow swings only %.2f -- that is a pulse, not a flash"
                        % (max(peaks) - min(peaks)))

if layer_counts and min(layer_counts) < 2:
    failures.append("the glow is drawing %s layer(s); the bright core is missing"
                    % min(layer_counts))

# The glow is the client's own and animates itself, so it must be asked for
# once and then left alone: a Show on every frame restarts its animation, and
# it would never get past the first frames of the flare.
# Six animation groups, played once between them: the glow brings its own
# animation, so re-playing it every frame restarts the flare and it never gets
# past its first frames.
if glow_plays() != 6:
    failures.append("the glow animations were started %d times across one buff;"
                    " six is one flare, more means it is being restarted"
                    % glow_plays())

# It hangs off its own host frame, which is bigger than the bar -- that is what
# puts the glow around the bar rather than on it.
host = G.SolarTrackerGlowHost
if host is None:
    failures.append("no glow host frame was built")
else:
    if host.width <= 130 or host.height <= 9:
        failures.append("the glow host is %sx%s, not bigger than the 130x9 bar"
                        % (host.width, host.height))
    # The client's glow paints its spark and ants across the whole host, so in
    # front of the display it lights the bar end to end and hides how much time
    # is left. It has to sit in a lower strata than the bar.
    STRATA_ORDER = ["BACKGROUND", "LOW", "MEDIUM", "HIGH", "DIALOG", "FULLSCREEN"]
    host_strata = str(host.strata) if host.strata is not None else None
    bar_strata = str(anchor.strata) if anchor.strata is not None else None
    if host_strata is None or bar_strata is None:
        failures.append("glow host strata %r, bar strata %r -- both must be set"
                        % (host_strata, bar_strata))
    elif STRATA_ORDER.index(host_strata) >= STRATA_ORDER.index(bar_strata):
        failures.append("the glow host is in %s and the bar in %s -- the glow would"
                        " cover the bar and hide the time left"
                        % (host_strata, bar_strata))

G.TEST.time = 1000
set_auras(solar=5, proc=(3, 20))
tick()
set_auras(solar=5)
tick()
if glow():
    failures.append("the glow stayed up after Battle Cleric fell off")
if glow_on():
    failures.append("the proc glow stayed up after Battle Cleric fell off")

# Reported 2026-08-25: the glow shows up some times and not others. Cause was
# the addon remembering "the glow is on" while the glow had been torn down
# behind its back. The state is read from the frame now, so anything that hides
# it must be recovered from on the next frame.
G.TEST.combat = True
set_auras(solar=5, proc=(3, 20))
tick()
if not glow_on():
    failures.append("no glow to begin the teardown test with")

if ST.glowOverlay is None:
    failures.append("no glow overlay was built at all")
else:
    # Anything that hides it behind the addon's back.
    ST.glowOverlay.Hide(ST.glowOverlay)
    if glow_on():
        failures.append("the teardown stub did not clear the glow")

tick()
if not glow_on():
    failures.append("the glow did not come back after the client tore it down"
                    " -- this is the bug from 2026-08-25")
G.TEST.combat = False
set_auras(solar=5)
tick()

# Runs out: the second track goes away rather than sitting there empty.
set_auras(solar=5, proc=(0, 20))
tick()
if duration() is not None:
    failures.append("duration bar still up after Battle Cleric expired")

# A permanent aura reports no expiry -- there is nothing to count down.
G.TEST.auras = lua.table_from({
    "HELPFUL": lua.table_from([lua.table_from(
        {"name": "Battle Cleric", "count": 1, "spellId": 562316,
         "duration": 0, "expiration": 0})]),
    "HARMFUL": lua.table_from([]),
})
tick()
if duration() is not None:
    failures.append("duration bar drawn for an aura with no duration")

set_auras(solar=5)
tick()
G.TEST.combat = False

# Nothing escapes the anchor. test_styles.py used to guarantee this across the
# eleven styles; with one style left, it lives here.
G.TEST.combat = True
set_auras(solar=13, proc=(9, 20))
tick()
for texture in list(G.TEXTURES.values()):
    if not texture.shown or not G.TEST_IsChildOf(texture, anchor):
        continue
    point = texture.points[1]
    if point is None:
        continue
    spec = list(point.values())
    x, y = spec[3], spec[4]
    if x < -1 or y < -1 or x + texture.width > anchor.width + 1             or y + texture.height > anchor.height + 1:
        failures.append("rectangle (%s,%s %sx%s) escapes the %sx%s anchor"
                        % (x, y, texture.width, texture.height,
                           anchor.width, anchor.height))
G.TEST.combat = False

# Visibility: in combat, or with any target picked, and nothing otherwise.
G.TEST.combat = False
G.TEST.target = False
set_auras(solar=12)
tick()
if anchor.IsShown(anchor):
    failures.append("visible while idle with no target")
G.TEST.target = True
tick()
if not anchor.IsShown(anchor):
    failures.append("hidden while a target was picked")
G.TEST.target = False
G.TEST.combat = True
tick()
if not anchor.IsShown(anchor):
    failures.append("hidden while in combat")
G.TEST.combat = False
tick()
if anchor.IsShown(anchor):
    failures.append("still visible after combat ended with no target")

# Back to Solar Power afterwards, at the full 20-wide row.
set_auras(solar=4)
tick()
got = resource()
if got is None or abs(got - 4 / 20.0) > 0.02:
    failures.append("bar did not return to the solar cap after Dawn: %s" % got)

# The client's orb: suppressed while on, handed back when off.
if G.CoAResourceOrb.alpha != 0:
    failures.append("client orb still visible while the display is on")
slash("off")
if G.CoAResourceOrb.alpha != 1:
    failures.append("client orb not restored when the display was switched off")
slash("on")
tick()
if G.CoAResourceOrb.alpha != 0:
    failures.append("client orb not re-hidden when the display came back")
slash("orb")
if G.CoAResourceOrb.alpha != 1:
    failures.append("/solar orb did not give the orb back")
slash("orb")
tick()

# Test values drive the display with no aura present at all.
set_auras()
slash("test dawn 3")
tick()
if abs((resource() or 0) - 3 / 8.0) > 0.02 or label() != "Dawn 3":
    failures.append("/solar test dawn 3 showed %s %r" % (resource(), label()))
slash("test 11")
tick()
if abs((resource() or 0) - 11 / 20.0) > 0.02 or label() != "11":
    failures.append("/solar test 11 showed %s %r" % (resource(), label()))
slash("test proc 12")
tick()
if duration() is None:
    failures.append("/solar test proc 12 did not put the duration bar up")
slash("test off")
tick()
if duration() is not None:
    failures.append("/solar test off left the duration bar up")

print("db.max:", ST.db.max, " Dawn charges at full:", ST.GetDawnMax(0))
print("anchor:", anchor.width, "x", anchor.height)
if failures:
    print()
    print("FAILURES:")
    for line in failures:
        print("  " + line)
else:
    print()
    print("solar stacks, Dawn charges, the Battle Cleric bar and the orb suppression all behave")
