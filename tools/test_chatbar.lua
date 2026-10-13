--[[---------------------------------------------------------------------------
    Offline harness for ChatBar.lua.

    Builds a mock of the parts of the WoW API the addon touches, loads the
    addon into that sandbox under Lua 5.1 (the version the game runs), then
    drives it: login, every slash command, a click/hover/drag on every button,
    and each state change the addon listens for.

    Any method the addon calls that the mock does not define raises an error,
    so a typo in a widget call fails the run instead of passing silently.
-----------------------------------------------------------------------------]]

local ADDON_FILE = ...
local failures, checks = {}, 0

local function check(ok, what)
    checks = checks + 1
    if not ok then failures[#failures + 1] = what end
    return ok
end

-- ---------------------------------------------------------------------------
-- Mock widgets
-- ---------------------------------------------------------------------------
local env = {}

local function newRegion(kind)
    local r = {
        kind = kind, points = {}, shown = true,
        SetPoint = function(self, point, rel, relPoint, x, y)
            if type(rel) == "string" then rel, relPoint, x, y = nil, point, rel, relPoint end
            self.points[point] = { rel = rel, relPoint = relPoint, x = x, y = y }
        end,
        ClearAllPoints = function(self) self.points = {} end,
        SetAllPoints = function(self) self.points.ALL = true end,
        Show = function(self) self.shown = true end,
        Hide = function(self) self.shown = false end,
        IsShown = function(self) return self.shown end,
        SetAlpha = function(self, a) self.alpha = a end,
        GetAlpha = function(self) return self.alpha or 1 end,
    }
    if kind == "Texture" then
        r.SetTexture = function(self, path) self.texture = path; return true end
        r.GetTexture = function(self) return self.texture end
        r.SetBlendMode = function(self, mode) self.blend = mode end
        r.SetVertexColor = function(self, cr, cg, cb)
            check(type(cr) == "number" and type(cg) == "number" and type(cb) == "number",
                  "SetVertexColor got a non-number")
            self.color = { cr, cg, cb }
        end
    elseif kind == "FontString" then
        r.SetFont = function(self, path, size, flags)
            check(type(path) == "string" and path ~= "", "SetFont path")
            check(type(size) == "number" and size > 0, "SetFont size")
            self.font = { path, size, flags }
            return true
        end
        r.SetFontObject = function(self, o) self.fontObject = o end
        r.SetShadowColor = function() end
        r.SetShadowOffset = function() end
        r.SetTextColor = function(self, cr, cg, cb) self.color = { cr, cg, cb } end
        r.SetText = function(self, t) self.text = t end
        r.GetText = function(self) return self.text end
    end
    return r
end

local allFrames = {}

local function newFrame(frameType, name, parent)
    local f
    f = {
        frameType = frameType, name = name, parent = parent,
        points = {}, scripts = {}, events = {}, shown = true,
        width = 0, height = 0, scale = 1, mouse = false,
        regions = {},

        SetFrameStrata = function(self, s) self.strata = s end,
        SetWidth  = function(self, w) self.width = w end,
        SetHeight = function(self, h) self.height = h end,
        GetWidth  = function(self) return self.width end,
        GetHeight = function(self) return self.height end,
        SetMovable = function(self, v) self.movable = v end,
        SetClampedToScreen = function() end,
        RegisterForDrag = function(self, ...) self.drag = { ... } end,
        RegisterForClicks = function() end,
        EnableMouse = function(self, v) self.mouse = v end,
        IsMouseEnabled = function(self) return self.mouse end,

        Show = function(self) self.shown = true end,
        Hide = function(self) self.shown = false end,
        IsShown = function(self) return self.shown end,

        SetScript = function(self, script, fn) self.scripts[script] = fn end,
        GetScript = function(self, script) return self.scripts[script] end,

        RegisterEvent = function(self, e)
            check(type(e) == "string" and e ~= "", "RegisterEvent name")
            if env.KNOWN_EVENTS and not env.KNOWN_EVENTS[e] then
                error("unknown event: " .. e, 2)      -- mirrors modern clients
            end
            self.events[e] = true
        end,
        UnregisterEvent = function(self, e) self.events[e] = nil end,

        SetPoint = function(self, point, rel, relPoint, x, y)
            if type(rel) == "string" then rel, relPoint, x, y = nil, point, rel, relPoint end
            check(type(point) == "string", "SetPoint point")
            self.points[#self.points + 1] =
                { point = point, rel = rel, relPoint = relPoint, x = x, y = y }
        end,
        ClearAllPoints = function(self) self.points = {} end,
        GetPoint = function(self)
            local p = self.points[1]
            if not p then return nil end
            return p.point, p.rel, p.relPoint, p.x, p.y
        end,
        GetLeft   = function(self) return self.simLeft or 100 end,
        GetBottom = function(self) return self.simBottom or 200 end,

        SetScale = function(self, s)
            check(type(s) == "number" and s > 0, "SetScale " .. tostring(s))
            self.scale = s
        end,
        GetScale = function(self) return self.scale end,
        GetEffectiveScale = function(self) return self.scale end,

        StartMoving = function(self) self.isMoving = true end,
        StopMovingOrSizing = function(self) self.isMoving = false end,

        CreateTexture = function(self, n, layer)
            local t = newRegion("Texture"); t.layer = layer
            self.regions[#self.regions + 1] = t
            return t
        end,
        CreateFontString = function(self, n, layer)
            local t = newRegion("FontString"); t.layer = layer
            self.regions[#self.regions + 1] = t
            return t
        end,
        SetHighlightTexture = function(self, path, blend)
            self.highlight = newRegion("Texture")
            self.highlight:SetTexture(path)
            self.highlight.blend = blend
        end,
        GetHighlightTexture = function(self) return self.highlight end,
    }
    if name then env[name] = f end
    allFrames[#allFrames + 1] = f
    return f
end

-- Every event the addon is allowed to register (a modern client errors on
-- anything else).  PARTY_MEMBERS_CHANGED / RAID_ROSTER_UPDATE are deliberately
-- absent so the pcall-wrapped registration gets exercised.
env.KNOWN_EVENTS = {}
for _, e in ipairs({
    "ADDON_LOADED", "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD", "GROUP_ROSTER_UPDATE",
    "PLAYER_GUILD_UPDATE", "CHANNEL_UI_UPDATE", "CHAT_MSG_CHANNEL_NOTICE",
    "UPDATE_CHAT_COLOR", "BN_CONNECTED", "BN_DISCONNECTED",
}) do env.KNOWN_EVENTS[e] = true end

-- ---------------------------------------------------------------------------
-- Mock globals
-- ---------------------------------------------------------------------------
env._G = env
env.CreateFrame = newFrame
for _, k in ipairs({ "type", "pairs", "ipairs", "select", "tonumber", "tostring",
                     "string", "table", "math", "pcall", "error", "setmetatable",
                     "rawget", "unpack", "print", "next", "assert" }) do
    env[k] = _G[k]
end

env.UIParent = newFrame("Frame", "UIParent")
env.ChatFrame1 = newFrame("Frame", "ChatFrame1")

local editBox = newFrame("EditBox", "ChatFrame1EditBox")
editBox.attributes = {}
editBox.SetAttribute = function(self, k, v) self.attributes[k] = v end
editBox.GetAttribute = function(self, k) return self.attributes[k] end
editBox.SetText = function(self, t) self.text = t end
editBox.GetText = function(self) return self.text end
editBox.SetFocus = function(self) self.focused = true end
editBox.SetCursorPosition = function(self, p) self.cursor = p end
editBox.GetNumLetters = function(self) return #(self.text or "") end
editBox.shown = false

local chatLog = {}
env.DEFAULT_CHAT_FRAME = {
    editBox = editBox,
    AddMessage = function(self, msg)
        check(type(msg) == "string", "AddMessage got a non-string")
        chatLog[#chatLog + 1] = msg
    end,
}

env.GameFontNormal = { GetFont = function() return "Fonts\\FRIZQT__.TTF", 12, "" end }
env.STANDARD_TEXT_FONT = "Fonts\\FRIZQT__.TTF"

local tooltipLines = {}
env.GameTooltip = {
    SetOwner = function() end,
    SetText = function(self, t) tooltipLines = { t } end,
    AddLine = function(self, t) tooltipLines[#tooltipLines + 1] = t end,
    Show = function() end,
    Hide = function() end,
}

local timers = {}
env.C_Timer = { After = function(delay, fn) timers[#timers + 1] = fn end }
local function runTimers()
    local pending = timers
    timers = {}
    for _, fn in ipairs(pending) do fn() end
end

env.SlashCmdList = {}
env.GetLocale = function() return "ruRU" end

-- ruRU chat-type names: the gold captions are their first letters.
env.SAY, env.YELL, env.WHISPER, env.EMOTE = "Сказать", "Крик", "Шепот", "Эмоция"
env.PARTY, env.RAID, env.GUILD, env.OFFICER = "Группа", "Рейд", "Гильдия", "Офицерский"
env.INSTANCE_CHAT = "Подземелье"
env.SLASH_SAY1, env.SLASH_YELL1, env.SLASH_WHISPER1 = "/s", "/y", "/w"
env.SLASH_EMOTE1, env.SLASH_PARTY1, env.SLASH_RAID1 = "/e", "/p", "/raid"
env.SLASH_GUILD1, env.SLASH_OFFICER1 = "/g", "/o"
env.SLASH_INSTANCE_CHAT1, env.SLASH_BNWHISPER1 = "/i", "/bnwhisper"

env.ChatTypeInfo = {
    SAY = { r = 1, g = 1, b = 1 }, YELL = { r = 1, g = .25, b = .25 },
    WHISPER = { r = 1, g = .5, b = 1 }, BN_WHISPER = { r = 0, g = 1, b = .96 },
    EMOTE = { r = 1, g = .5, b = .25 }, PARTY = { r = .67, g = .67, b = 1 },
    RAID = { r = 1, g = .5, b = 0 }, GUILD = { r = .25, g = 1, b = .25 },
    OFFICER = { r = .25, g = .75, b = .25 }, CHANNEL = { r = 1, g = .75, b = .75 },
}

-- Mutable world state the probes read.
local world = {
    inGroup = false, inRaid = false, inGuild = false, instanceGroup = false,
    hasTarget = false,
    channels = { { 1, "Общий", false }, { 2, "Торговля", false },
                 { 3, "ОбщийПоискГруппы", false }, { 4, "Т-канал", false } },
}
env.IsInGroup = function(cat)
    if cat then return world.instanceGroup end
    return world.inGroup or world.inRaid
end
env.IsInRaid = function() return world.inRaid end
env.IsInGuild = function() return world.inGuild end
env.LE_PARTY_CATEGORY_INSTANCE = 2
env.BNSendWhisper = function() end
env.UnitExists = function(u) return u == "target" and world.hasTarget end
env.UnitIsPlayer = function() return world.hasTarget end
env.UnitCanAttack = function() return false end
env.GetUnitName = function() return "Ивелноу-Форевер" end
env.UnitName = function() return "Ивелноу" end
env.GetChannelList = function()
    local out = {}
    for _, c in ipairs(world.channels) do
        out[#out + 1] = c[1]; out[#out + 1] = c[2]; out[#out + 1] = c[3]
    end
    return unpack(out)
end

local headerUpdates = 0
env.ChatEdit_ChooseBoxForSend = function() return editBox end
env.ChatEdit_ActivateChat = function(b) b:Show() end
env.ChatEdit_UpdateHeader = function() headerUpdates = headerUpdates + 1 end
env.ChatEdit_ParseText = function() end
env.ChatEdit_GetLastTellTarget = function() return nil end

-- ---------------------------------------------------------------------------
-- Load and drive the addon
-- ---------------------------------------------------------------------------
local source = assert(io.open(ADDON_FILE, "r"))
local code = source:read("*a")
source:close()

local chunk, err = loadstring(code, "@ChatBar.lua")
if not chunk then
    print("SYNTAX ERROR: " .. tostring(err))
    os.exit(1)
end
setfenv(chunk, env)
assert(pcall(chunk, "ChatBar"))

local eventFrame
for _, f in ipairs(allFrames) do
    if f.scripts.OnEvent then eventFrame = f end
end
check(eventFrame ~= nil, "no OnEvent handler was installed")

local function fire(event, ...)
    local ok, e = pcall(eventFrame.scripts.OnEvent, eventFrame, event, ...)
    check(ok, "event " .. event .. " errored: " .. tostring(e))
    runTimers()
end

-- Saved variables start empty, exactly as on a first install.
env.ChatBarDB = nil
fire("ADDON_LOADED", "SomeOtherAddon")
check(env.ChatBarDB == nil, "ADDON_LOADED reacted to a foreign addon")
fire("ADDON_LOADED", "ChatBar")
check(type(env.ChatBarDB) == "table", "ChatBarDB was not created")
fire("PLAYER_LOGIN")

local bar = env.ChatBarFrame
check(bar ~= nil, "ChatBarFrame was not created")
check(bar.shown, "bar is not visible after login")

local function captions()
    local out, i = {}, 1
    while env["ChatBarButton" .. i] do
        local b = env["ChatBarButton" .. i]
        if not b.shown then break end
        local fs
        for _, r in ipairs(b.regions) do if r.kind == "FontString" then fs = r end end
        out[#out + 1] = fs and fs.text or "?"
        i = i + 1
    end
    return table.concat(out, " ")
end

-- The reference screenshot: solo, guildless, four numbered channels.
local expected = "С К Ш Ш Э О Т О Т"
check(captions() == expected,
      "captions were '" .. captions() .. "', expected '" .. expected .. "'")

-- Orb colours must match the chat-type colours.
local b1 = env.ChatBarButton1
local orb
for _, r in ipairs(b1.regions) do if r.kind == "Texture" and r.layer == "ARTWORK" then orb = r end end
check(orb and orb.color and orb.color[1] == 1 and orb.color[2] == 1 and orb.color[3] == 1,
      "the Say orb is not white")

-- Clicking must switch the edit box and focus it.
local function click(index)
    local b = env["ChatBarButton" .. index]
    local ok, e = pcall(b.scripts.OnClick, b)
    check(ok, "click on button " .. index .. " errored: " .. tostring(e))
    return b
end

click(1)
check(editBox.attributes.chatType == "SAY", "Say click did not set chatType=SAY")
check(editBox.focused, "Say click did not focus the edit box")
click(2)
check(editBox.attributes.chatType == "YELL", "Yell click did not set chatType=YELL")
click(5)
check(editBox.attributes.chatType == "EMOTE", "Emote click did not set chatType=EMOTE")

-- Channel clicks must carry the live channel number.
click(7)
check(editBox.attributes.chatType == "CHANNEL", "channel click did not set chatType")
check(editBox.attributes.channelTarget == 2,
      "channel click targeted " .. tostring(editBox.attributes.channelTarget) .. ", expected 2")

-- Whisper with no target falls back to the slash command; with a target it
-- uses the attribute protocol.
editBox.text = nil
click(3)
check(editBox.text == "/w ", "whisper without a target did not fall back to '/w '")
world.hasTarget = true
click(3)
check(editBox.attributes.tellTarget == "Ивелноу-Форевер",
      "whisper with a target did not set tellTarget")
world.hasTarget = false

-- Hover, press, release and drag must all survive.
for index = 1, 9 do
    local b = env["ChatBarButton" .. index]
    for _, script in ipairs({ "OnEnter", "OnMouseDown", "OnMouseUp", "OnLeave",
                              "OnDragStart", "OnDragStop", "OnHide" }) do
        local ok, e = pcall(b.scripts[script], b)
        check(ok, script .. " on button " .. index .. " errored: " .. tostring(e))
    end
end
check(#tooltipLines >= 2, "the tooltip has no body line")

-- Dragging must persist a position.
bar.simLeft, bar.simBottom = 310, 420
pcall(bar.scripts.OnDragStart, bar)
pcall(bar.scripts.OnDragStop, bar)
check(env.ChatBarDB.x == 310 and env.ChatBarDB.y == 420,
      "dragging did not save the position")

-- State changes must add and remove buttons without errors.
world.inGroup = true; fire("GROUP_ROSTER_UPDATE")
check(captions() == "С К Ш Ш Э Г О Т О Т",
      "joining a party gave '" .. captions() .. "'")
world.inRaid = true; fire("GROUP_ROSTER_UPDATE")
check(captions() == "С К Ш Ш Э Г Р О Т О Т",
      "joining a raid gave '" .. captions() .. "'")
world.inGuild = true; fire("PLAYER_GUILD_UPDATE")
check(captions() == "С К Ш Ш Э Г Р Г О О Т О Т",
      "joining a guild gave '" .. captions() .. "'")
world.inGroup, world.inRaid, world.inGuild = false, false, false
fire("GROUP_ROSTER_UPDATE"); fire("PLAYER_GUILD_UPDATE")
check(captions() == expected, "leaving everything did not restore the base row")

-- No channels at all must not break anything.
local savedChannels = world.channels
world.channels = {}
fire("CHANNEL_UI_UPDATE")
check(captions() == "С К Ш Ш Э", "with no channels the row was '" .. captions() .. "'")
click(1)
world.channels = savedChannels
fire("CHANNEL_UI_UPDATE")

-- Old-style GetChannelList returning (id, name) pairs must still parse.
env.GetChannelList = function() return 1, "Общий", 2, "Торговля" end
fire("CHANNEL_UI_UPDATE")
check(captions() == "С К Ш Ш Э О Т", "pair-style channel list gave '" .. captions() .. "'")
env.GetChannelList = function()
    local out = {}
    for _, c in ipairs(world.channels) do
        out[#out + 1] = c[1]; out[#out + 1] = c[2]; out[#out + 1] = c[3]
    end
    return unpack(out)
end
fire("CHANNEL_UI_UPDATE")

-- Slash commands.
local slash = env.SlashCmdList["CHATBAR"]
check(env.SLASH_CHATBAR1 == "/chatbar", "the slash command is not /chatbar")
local function run(args)
    local ok, e = pcall(slash, args)
    check(ok, "'/chatbar " .. args .. "' errored: " .. tostring(e))
end
run("")
run("lock");    check(env.ChatBarDB.locked == true, "lock did not set the flag")
check(bar.mouse == false, "a locked bar still captures the mouse")
pcall(bar.scripts.OnDragStart, bar)
check(bar.isMoving ~= true, "a locked bar still started moving")
run("unlock");  check(env.ChatBarDB.locked == false, "unlock did not clear the flag")
check(bar.mouse == true, "an unlocked bar does not capture the mouse")
run("hide");    check(bar.shown == false, "hide did not hide the bar")
run("show");    check(bar.shown == true, "show did not show the bar")
run("scale 1.5"); check(bar.scale == 1.5, "scale 1.5 was not applied")
run("scale 9");   check(bar.scale == 1.5, "an out-of-range scale was applied anyway")
run("scale");     check(bar.scale == 1.5, "a bare scale query changed the scale")
run("reset")
check(bar.scale == 1, "reset did not restore scale 1")
check(env.ChatBarDB.x ~= nil, "reset did not store a fresh position")
run("nonsense")

-- A reload: fresh frames, saved variables carried over.
local saved = env.ChatBarDB
check(saved.scale == 1 and saved.locked == false, "saved variables look wrong")

-- Clicking with the chat helpers missing must still reach the slash fallback.
env.ChatEdit_UpdateHeader = nil
editBox.text = nil
click(1)
check(editBox.text == "/s ", "without ChatEdit_UpdateHeader the fallback did not fire")

-- ---------------------------------------------------------------------------
print(string.format("%d checks run", checks))
if #failures == 0 then
    print("ALL PASS")
else
    print(#failures .. " FAILURE(S):")
    for _, f in ipairs(failures) do print("  - " .. f) end
    os.exit(1)
end
