--[[---------------------------------------------------------------------------
    ChatOrbs - a compact dock of chat-channel buttons.

    One orb per chat target the character can actually use right now, coloured
    by the chat type. Clicking an orb opens the chat edit box already switched
    to that channel; a marker under the dock shows where you are typing. The
    emote orb opens a list of emotes so they do not have to be typed out.

    The row is built from game state, so it never offers a party, raid, guild
    or numbered channel the player is not in.
-----------------------------------------------------------------------------]]

local ADDON_NAME = ...

-- ---------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------
local ORB_SIZE   = 20           -- orb diameter at rest
local ORB_GROW   = 2            -- extra diameter when hovered
local ORB_STEP   = 26           -- centre-to-centre spacing
local DOCK_INNER = 6            -- padding between the orbs and the dock edge
local DOCK_H     = ORB_SIZE + DOCK_INNER * 2
local HIT_SIZE   = 24           -- clickable area per orb
local GLOW_SIZE  = 34
-- Every size here is even, so that snapping the dock to half a pixel per unit
-- still lands each edge on a whole physical pixel.
local MARKER_W, MARKER_H = 14, 4
local CORNER     = 12           -- nine-slice corner, in screen pixels
local CAPTION_SIZE = 12
local HOVER_TIME = 0.10         -- seconds for the hover transition

local TEX = "Interface\\AddOns\\ChatOrbs\\Textures\\"
-- Paths carry the extension so the client has nothing to guess.
local TEX_ORB, TEX_SHEEN = TEX .. "Orb.blp", TEX .. "OrbSheen.blp"
local TEX_GLOW = TEX .. "Glow.blp"
local TEX_PANEL, TEX_MARKER = TEX .. "Panel.blp", TEX .. "Marker.blp"

-- Nine-slice texture coordinates: 24px corners in a 64px texture.
local SLICE = { 0, 0.375, 0.625, 1 }

local SHEEN_REST, SHEEN_HOVER = 0.20, 0.30
local GLOW_ALPHA = 0.50
local CAPTION_DARKEN = 0.20     -- glyph colour = chat colour * this

local MIN_SCALE, MAX_SCALE = 0.5, 3.0

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
local _G = _G
local select, type, pairs, ipairs, pcall = select, type, pairs, ipairs, pcall
local tonumber, tostring = tonumber, tostring
local floor, max, min = math.floor, math.max, math.min
local strbyte, strchar, strsub = string.byte, string.char, string.sub
local strlower, strupper = string.lower, string.upper
local tinsert = table.insert
local unpack = _G.unpack or table.unpack
local strtrim = _G.strtrim or function(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local isRU = (_G.GetLocale and GetLocale() == "ruRU") or false

local function T(ru, en)
    if isRU then return ru end
    return en
end

--- Byte length of the UTF-8 character starting at `i`.
local function CharLen(s, i)
    local b = strbyte(s, i)
    if not b then return 0 end
    if b >= 0xF0 then return 4 end
    if b >= 0xE0 then return 3 end
    if b >= 0xC0 then return 2 end
    return 1
end

--- Uppercases one character. Lua's strupper does not know Cyrillic, so the
--- two-byte Russian range is mapped by hand.
local function UpperChar(c)
    if #c == 1 then return strupper(c) end
    if #c == 2 then
        local b1, b2 = strbyte(c, 1, 2)
        if b1 == 0xD0 and b2 >= 0xB0 and b2 <= 0xBF then         -- а..п
            return strchar(b1, b2 - 0x20)
        elseif b1 == 0xD1 and b2 >= 0x80 and b2 <= 0x8F then     -- р..я
            return strchar(0xD0, b2 + 0x20)
        elseif b1 == 0xD1 and b2 == 0x91 then                    -- ё
            return strchar(0xD0, 0x81)
        end
    end
    return c
end

local function FirstChar(s)
    if type(s) ~= "string" or s == "" then return "?" end
    return UpperChar(strsub(s, 1, CharLen(s, 1)))
end

local function UpperFirst(s)
    if type(s) ~= "string" or s == "" then return s end
    local n = CharLen(s, 1)
    return UpperChar(strsub(s, 1, n)) .. strsub(s, n + 1)
end

--- First non-empty string among the named globals, else the given default.
local function Global(default, ...)
    for i = 1, select("#", ...) do
        local v = _G[select(i, ...)]
        if type(v) == "string" and v ~= "" then return v end
    end
    return default
end

local function Pack(...)
    local t = { n = select("#", ...) }
    for i = 1, t.n do t[i] = select(i, ...) end
    return t
end

--- Resolves a FrameXML chat helper by its classic global name first and by its
--- ChatFrameUtil name second (the 12.x chat rewrite moved several of them).
local function ChatFunc(globalName, utilName)
    local fn = _G[globalName]
    if type(fn) == "function" then return fn end
    local util = _G.ChatFrameUtil
    if utilName and type(util) == "table" and type(util[utilName]) == "function" then
        return util[utilName]
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Colours
-- ---------------------------------------------------------------------------
local FALLBACK_COLOR = {
    SAY           = { 1.00, 1.00, 1.00 },
    YELL          = { 1.00, 0.25, 0.25 },
    EMOTE         = { 1.00, 0.50, 0.25 },
    WHISPER       = { 1.00, 0.50, 1.00 },
    BN_WHISPER    = { 0.00, 1.00, 0.96 },
    PARTY         = { 0.67, 0.67, 1.00 },
    RAID          = { 1.00, 0.50, 0.00 },
    INSTANCE_CHAT = { 1.00, 0.50, 0.00 },
    GUILD         = { 0.25, 1.00, 0.25 },
    OFFICER       = { 0.25, 0.75, 0.25 },
    CHANNEL       = { 1.00, 0.75, 0.75 },
}

local function ColorFor(key)
    local info = _G.ChatTypeInfo and _G.ChatTypeInfo[key]
    if type(info) == "table" and type(info.r) == "number" then
        return info.r, info.g, info.b
    end
    local c = FALLBACK_COLOR[key] or FALLBACK_COLOR[(key or ""):gsub("%d+$", "")]
    c = c or FALLBACK_COLOR.SAY
    return c[1], c[2], c[3]
end

-- ---------------------------------------------------------------------------
-- Availability probes
-- ---------------------------------------------------------------------------
local function InGroup()
    if _G.IsInGroup then return IsInGroup() and true or false end
    if _G.GetNumPartyMembers then return GetNumPartyMembers() > 0 end
    if _G.GetNumSubgroupMembers then return GetNumSubgroupMembers() > 0 end
    return false
end

local function InRaid()
    if _G.IsInRaid then return IsInRaid() and true or false end
    if _G.GetNumRaidMembers then return GetNumRaidMembers() > 0 end
    return false
end

local function InGuild()
    return (_G.IsInGuild and IsInGuild()) and true or false
end

local function InInstanceGroup()
    if _G.IsInGroup and _G.LE_PARTY_CATEGORY_INSTANCE then
        local ok, res = pcall(IsInGroup, LE_PARTY_CATEGORY_INSTANCE)
        if ok then return res and true or false end
    end
    return false
end

local function HasBattlenet()
    if _G.SLASH_BNWHISPER1 or _G.BNSendWhisper then return true end
    local api = _G.C_BattleNet
    return (type(api) == "table" and api.GetFriendAccountInfo) and true or false
end

-- ---------------------------------------------------------------------------
-- Fixed chat targets. `label` names the globals the caption letter comes from
-- (ruRU: Сказать -> С, Крик -> К, Шепот -> Ш, Эмоция -> Э).
-- ---------------------------------------------------------------------------
local STATIC_ENTRIES = {
    { chatType = "SAY",           slash = { "SLASH_SAY1" },
      label = { "SAY" },                                      fallback = "Say" },
    { chatType = "YELL",          slash = { "SLASH_YELL1" },
      label = { "YELL" },                                     fallback = "Yell" },
    { chatType = "EMOTE",         slash = { "SLASH_EMOTE1" },
      label = { "EMOTE", "CHAT_MSG_EMOTE" }, isEmote = true,  fallback = "Emote" },
    { chatType = "WHISPER",       slash = { "SLASH_WHISPER1", "SLASH_SMART_WHISPER1" },
      label = { "WHISPER" },        needsTarget = true,       fallback = "Whisper" },
    { chatType = "BN_WHISPER",    slash = { "SLASH_BNWHISPER1", "SLASH_WHISPER1" },
      label = { "BN_WHISPER", "BATTLENET_WHISPER", "WHISPER" },
      needsTarget = true,           available = HasBattlenet, fallback = "Whisper" },
    { chatType = "PARTY",         slash = { "SLASH_PARTY1" },
      label = { "PARTY" },          available = InGroup,      fallback = "Party" },
    { chatType = "RAID",          slash = { "SLASH_RAID1" },
      label = { "RAID" },           available = InRaid,       fallback = "Raid" },
    { chatType = "INSTANCE_CHAT", slash = { "SLASH_INSTANCE_CHAT1" },
      label = { "INSTANCE_CHAT" },  available = InInstanceGroup,
      fallback = "Instance" },
    { chatType = "GUILD",         slash = { "SLASH_GUILD1" },
      label = { "GUILD" },          available = InGuild,      fallback = "Guild" },
    { chatType = "OFFICER",       slash = { "SLASH_OFFICER1" },
      label = { "OFFICER" },        available = InGuild,      fallback = "Officer" },
}

-- On the ruRU client some of these globals do not start with the letter
-- players know the channel by: SAY comes out as Р, and the Battle.net whisper
-- as О, which then collides with Офицерский and Общий. The chat edit box
-- itself says "Сказать", so for Russian the captions follow the edit box
-- rather than the global. Every other locale derives them as before.
local RU_LABELS = {
    SAY           = { "С", "Сказать" },
    YELL          = { "К", "Крик" },
    EMOTE         = { "Э", "Эмоция" },
    WHISPER       = { "Ш", "Шепот" },
    BN_WHISPER    = { "Ш", "Шепот Battle.net" },
    PARTY         = { "Г", "Группа" },
    RAID          = { "Р", "Рейд" },
    INSTANCE_CHAT = { "П", "Подземелье" },
    GUILD         = { "Г", "Гильдия" },
    OFFICER       = { "О", "Офицерский" },
}

-- ---------------------------------------------------------------------------
-- Chat edit box
-- ---------------------------------------------------------------------------
local function GetEditBox()
    local choose = ChatFunc("ChatEdit_ChooseBoxForSend", "ChooseBoxForSend")
    if choose then
        local ok, box = pcall(choose, _G.DEFAULT_CHAT_FRAME)
        if ok and box then return box end
    end
    local df = _G.DEFAULT_CHAT_FRAME
    return (df and df.editBox) or _G.ChatFrame1EditBox
end

local function WhisperTarget()
    if _G.UnitExists and UnitExists("target") and UnitIsPlayer("target")
        and (not _G.UnitCanAttack or not UnitCanAttack("player", "target")) then
        local name
        if _G.GetUnitName then name = GetUnitName("target", true) end
        if type(name) ~= "string" or name == "" then
            name = _G.UnitName and UnitName("target")
        end
        if type(name) == "string" and name ~= "" then
            return (name:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
        end
    end
    for _, fname in ipairs({ "ChatEdit_GetLastTellTarget", "ChatEdit_GetLastToldTarget" }) do
        local fn = _G[fname]
        if type(fn) == "function" then
            local ok, last = pcall(fn)
            if ok and type(last) == "string" and last ~= "" then return last end
        end
    end
    return nil
end

local ChatOrbs = { buttons = {} }

local function OpenChatFor(entry)
    local editBox = GetEditBox()
    if not editBox then return end

    local activate = ChatFunc("ChatEdit_ActivateChat", "ActivateChat")
    if activate then pcall(activate, editBox) end
    if not editBox:IsShown() then editBox:Show() end
    editBox:SetFocus()

    local updateHeader = ChatFunc("ChatEdit_UpdateHeader", "UpdateHeader")
    local chatType = entry.chatType
    local target
    if entry.needsTarget and chatType == "WHISPER" then
        target = WhisperTarget()
    end

    -- Primary path: the attribute protocol ChatEdit_SendText reads on Enter.
    -- Whatever the player already typed is left alone.
    if updateHeader and not (entry.needsTarget and not target) then
        editBox:SetAttribute("chatType", chatType)
        if chatType == "CHANNEL" then
            editBox:SetAttribute("channelTarget", entry.channelId)
        elseif target then
            editBox:SetAttribute("tellTarget", target)
        end
        pcall(updateHeader, editBox)
        ChatOrbs:UpdateMarker()
        return
    end

    -- Fallback: put the slash command in the box. Used for a whisper with no
    -- obvious recipient, and on any client where the chat helpers could not be
    -- resolved. The text stays a valid command either way, so pressing Enter
    -- still reaches the right channel.
    local slash = entry.slashText
    if slash then
        editBox:SetText(slash .. " ")
        local parse = ChatFunc("ChatEdit_ParseText", "ParseText")
        if parse then pcall(parse, editBox, 0) end
        if editBox.SetCursorPosition and editBox.GetNumLetters then
            editBox:SetCursorPosition(editBox:GetNumLetters() or 0)
        end
    else
        editBox:SetAttribute("chatType", chatType)
        if chatType == "CHANNEL" then
            editBox:SetAttribute("channelTarget", entry.channelId)
        end
        if updateHeader then pcall(updateHeader, editBox) end
    end
    ChatOrbs:UpdateMarker()
end

-- ---------------------------------------------------------------------------
-- Entry list
-- ---------------------------------------------------------------------------
local function AddChannelEntries(out)
    if type(_G.GetChannelList) ~= "function" then return end
    local ok, list = pcall(function() return Pack(GetChannelList()) end)
    if not ok or type(list) ~= "table" then return end

    -- GetChannelList yields (id, name) pairs on old clients and
    -- (id, name, disabled) triplets on current ones, so scan for every
    -- number-followed-by-string adjacency instead of assuming a stride.
    local seen = {}
    local i = 1
    while i < list.n do
        local id, name = list[i], list[i + 1]
        if type(id) == "number" and type(name) == "string"
            and id == floor(id) and id > 0 and id < 1000
            and name ~= "" and not seen[id] then
            seen[id] = true
            local disabled = list[i + 2]
            if type(disabled) ~= "boolean" then disabled = false end
            if not disabled then
                out[#out + 1] = {
                    key       = "CHANNEL" .. id,
                    chatType  = "CHANNEL",
                    channelId = id,
                    colorKey  = "CHANNEL" .. id,
                    caption   = FirstChar(name),
                    title     = id .. ". " .. name,
                    slashText = "/" .. id,
                }
            end
            i = i + 2
        else
            i = i + 1
        end
    end
end

local function BuildEntries()
    local entries = {}
    for _, def in ipairs(STATIC_ENTRIES) do
        if (not def.available) or def.available() then
            local title = Global(def.fallback, unpack(def.label))
            local caption = FirstChar(title)
            local override = isRU and RU_LABELS[def.chatType]
            if override then
                caption, title = override[1], override[2]
            end
            local slash
            for _, name in ipairs(def.slash) do
                local value = _G[name]
                if type(value) == "string" and value ~= "" then
                    slash = value
                    break
                end
            end
            entries[#entries + 1] = {
                key         = def.chatType,
                chatType    = def.chatType,
                colorKey    = def.chatType,
                caption     = caption,
                title       = title,
                slashText   = slash,
                needsTarget = def.needsTarget,
                isEmote     = def.isEmote,
            }
        end
    end
    AddChannelEntries(entries)
    return entries
end

-- ---------------------------------------------------------------------------
-- Nine-slice panel
-- ---------------------------------------------------------------------------
local function CreatePanel(parent)
    local panel = CreateFrame("Frame", nil, parent)
    panel.pieces = {}
    local cols = { "LEFT", "MID", "RIGHT" }
    local rows = { "TOP", "MID", "BOTTOM" }
    for r = 1, 3 do
        for c = 1, 3 do
            local tex = panel:CreateTexture(nil, "BACKGROUND")
            tex:SetTexCoord(SLICE[c], SLICE[c + 1], SLICE[r], SLICE[r + 1])
            panel.pieces[rows[r] .. cols[c]] = tex
        end
    end
    panel.Layout = function(self)
        local p = self.pieces
        local corner = CORNER
        local function put(tex, point, relPoint, x, y, w, h)
            tex:ClearAllPoints()
            tex:SetPoint(point, self, relPoint, x, y)
            if w then tex:SetWidth(w) end
            if h then tex:SetHeight(h) end
        end
        put(p.TOPLEFT, "TOPLEFT", "TOPLEFT", 0, 0, corner, corner)
        put(p.TOPRIGHT, "TOPRIGHT", "TOPRIGHT", 0, 0, corner, corner)
        put(p.BOTTOMLEFT, "BOTTOMLEFT", "BOTTOMLEFT", 0, 0, corner, corner)
        put(p.BOTTOMRIGHT, "BOTTOMRIGHT", "BOTTOMRIGHT", 0, 0, corner, corner)

        p.TOPMID:ClearAllPoints()
        p.TOPMID:SetPoint("TOPLEFT", p.TOPLEFT, "TOPRIGHT")
        p.TOPMID:SetPoint("BOTTOMRIGHT", p.TOPRIGHT, "BOTTOMLEFT")
        p.BOTTOMMID:ClearAllPoints()
        p.BOTTOMMID:SetPoint("TOPLEFT", p.BOTTOMLEFT, "TOPRIGHT")
        p.BOTTOMMID:SetPoint("BOTTOMRIGHT", p.BOTTOMRIGHT, "BOTTOMLEFT")
        p.MIDLEFT:ClearAllPoints()
        p.MIDLEFT:SetPoint("TOPLEFT", p.TOPLEFT, "BOTTOMLEFT")
        p.MIDLEFT:SetPoint("BOTTOMRIGHT", p.BOTTOMLEFT, "TOPRIGHT")
        p.MIDRIGHT:ClearAllPoints()
        p.MIDRIGHT:SetPoint("TOPLEFT", p.TOPRIGHT, "BOTTOMLEFT")
        p.MIDRIGHT:SetPoint("BOTTOMRIGHT", p.BOTTOMRIGHT, "TOPRIGHT")
        p.MIDMID:ClearAllPoints()
        p.MIDMID:SetPoint("TOPLEFT", p.TOPLEFT, "BOTTOMRIGHT")
        p.MIDMID:SetPoint("BOTTOMRIGHT", p.BOTTOMRIGHT, "TOPLEFT")
    end
    panel.Restyle = function(self, flat)
        for _, tex in pairs(self.pieces) do
            if flat then
                if tex.SetColorTexture then
                    tex:SetColorTexture(0.05, 0.05, 0.06, 0.8)
                else
                    tex:SetTexture(0.05, 0.05, 0.06, 0.8)
                end
                tex:SetTexCoord(0, 1, 0, 1)
            else
                tex:SetTexture(TEX_PANEL)
            end
        end
        if not flat then
            local cols2 = { "LEFT", "MID", "RIGHT" }
            local rows2 = { "TOP", "MID", "BOTTOM" }
            for r = 1, 3 do
                for c = 1, 3 do
                    self.pieces[rows2[r] .. cols2[c]]
                        :SetTexCoord(SLICE[c], SLICE[c + 1], SLICE[r], SLICE[r + 1])
                end
            end
        end
    end
    panel:Layout()
    return panel
end

-- ---------------------------------------------------------------------------
-- Hover transition: one shared OnUpdate that detaches when nothing is moving
-- ---------------------------------------------------------------------------
local tweening, tweenFrame = {}, nil

local function ApplyVisual(button)
    local t = button.hoverAmount or 0
    local size = ORB_SIZE + ORB_GROW * t - (button.pressed and 1.5 or 0)
    local drop = button.pressed and -1 or 0
    button.orb:SetWidth(size); button.orb:SetHeight(size)
    button.sheen:SetWidth(size); button.sheen:SetHeight(size)
    button.orb:SetPoint("CENTER", button, "CENTER", 0, drop)
    button.sheen:SetPoint("CENTER", button, "CENTER", 0, drop)
    button.caption:SetPoint("CENTER", button, "CENTER", 0, drop)
    button.sheen:SetAlpha(SHEEN_REST + (SHEEN_HOVER - SHEEN_REST) * t)
    button.glow:SetAlpha(GLOW_ALPHA * t)
end

local function TweenStep(self, elapsed)
    local step = (elapsed or 0) / HOVER_TIME
    local busy = false
    for button, target in pairs(tweening) do
        local current = button.hoverAmount or 0
        if current < target then
            current = min(target, current + step)
        else
            current = max(target, current - step)
        end
        button.hoverAmount = current
        ApplyVisual(button)
        if current == target then
            tweening[button] = nil
        else
            busy = true
        end
    end
    if not busy then self:SetScript("OnUpdate", nil) end
end

local function SetHover(button, on)
    tweening[button] = on and 1 or 0
    if not tweenFrame then tweenFrame = CreateFrame("Frame") end
    tweenFrame:SetScript("OnUpdate", TweenStep)
end

-- ---------------------------------------------------------------------------
-- Emotes
-- ---------------------------------------------------------------------------
local EMOTE_TOKENS = {
    "HELLO", "BYE", "WAVE", "BOW", "SALUTE", "THANK",
    "APPLAUD", "CHEER", "LAUGH", "SMILE", "DANCE", "FLEX",
    "KISS", "HUG", "SHRUG", "SORRY", "CRY", "ROAR",
    "SLEEP", "YES", "NO",
}

local emoteList

local function BuildEmoteList()
    if emoteList then return emoteList end
    local commands = {}
    for i = 1, 600 do
        local token = _G["EMOTE" .. i .. "_TOKEN"]
        if type(token) == "string" and not commands[token] then
            local cmd = _G["EMOTE" .. i .. "_CMD1"]
            if type(cmd) == "string" and cmd ~= "" then
                commands[token] = cmd
            end
        end
    end
    emoteList = {}
    for _, token in ipairs(EMOTE_TOKENS) do
        local cmd = commands[token]
        local label = cmd and UpperFirst((cmd:gsub("^/", ""))) or UpperFirst(strlower(token))
        emoteList[#emoteList + 1] = { token = token, label = label }
    end
    return emoteList
end

local EMOTE_COLS, EMOTE_CELL_W, EMOTE_CELL_H, EMOTE_PAD = 3, 120, 20, 10
local picker, pickerBlocker

local function HidePicker()
    if picker then picker:Hide() end
end

local function CreatePicker()
    if picker then return picker end
    local list = BuildEmoteList()
    local rows = math.ceil(#list / EMOTE_COLS)

    pickerBlocker = CreateFrame("Button", nil, UIParent)
    pickerBlocker:SetAllPoints(UIParent)
    pickerBlocker:SetFrameStrata("DIALOG")
    pickerBlocker:Hide()
    pickerBlocker:SetScript("OnClick", HidePicker)

    picker = CreateFrame("Frame", "ChatOrbsEmotePicker", UIParent)
    picker:SetFrameStrata("DIALOG")
    picker:SetWidth(EMOTE_COLS * EMOTE_CELL_W + EMOTE_PAD * 2)
    picker:SetHeight(rows * EMOTE_CELL_H + EMOTE_PAD * 2)
    picker:EnableMouse(true)
    picker:Hide()
    picker:SetScript("OnShow", function() pickerBlocker:Show() end)
    picker:SetScript("OnHide", function() pickerBlocker:Hide() end)

    picker.panel = CreatePanel(picker)
    picker.panel:SetAllPoints(picker)
    picker.panel:Restyle(ChatOrbsDB and ChatOrbsDB.flat)

    local font = _G.GameFontNormal
    local fontPath, fontFlags
    if font and font.GetFont then
        local path, _, flags = font:GetFont()
        fontPath, fontFlags = path, flags
    end
    fontPath = fontPath or _G.STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"

    for index, emote in ipairs(list) do
        local col = (index - 1) % EMOTE_COLS
        local row = floor((index - 1) / EMOTE_COLS)
        local cell = CreateFrame("Button", nil, picker)
        cell:SetWidth(EMOTE_CELL_W)
        cell:SetHeight(EMOTE_CELL_H)
        cell:SetPoint("TOPLEFT", picker, "TOPLEFT",
                      EMOTE_PAD + col * EMOTE_CELL_W, -(EMOTE_PAD + row * EMOTE_CELL_H))

        local highlight = cell:CreateTexture(nil, "HIGHLIGHT")
        highlight:SetPoint("TOPLEFT", 2, 0)
        highlight:SetPoint("BOTTOMRIGHT", -2, 0)
        if highlight.SetColorTexture then
            highlight:SetColorTexture(1, 1, 1, 0.12)
        else
            highlight:SetTexture(1, 1, 1, 0.12)
        end

        local text = cell:CreateFontString(nil, "OVERLAY")
        if not text:SetFont(fontPath, 11, fontFlags) then
            text:SetFontObject("GameFontHighlightSmall")
        end
        text:SetPoint("LEFT", cell, "LEFT", 8, 0)
        text:SetWidth(EMOTE_CELL_W - 14)
        text:SetJustifyH("LEFT")
        -- A long localised name is cut off rather than spilling into the
        -- neighbouring column.
        if text.SetWordWrap then pcall(text.SetWordWrap, text, false) end
        text:SetText(emote.label)
        text:SetTextColor(0.88, 0.88, 0.92)

        cell:SetScript("OnEnter", function() text:SetTextColor(1, 0.85, 0.35) end)
        cell:SetScript("OnLeave", function() text:SetTextColor(0.88, 0.88, 0.92) end)
        cell:SetScript("OnClick", function()
            HidePicker()
            if type(_G.DoEmote) == "function" then pcall(DoEmote, emote.token) end
        end)
    end

    if type(_G.UISpecialFrames) == "table" then
        tinsert(UISpecialFrames, "ChatOrbsEmotePicker")
    end
    return picker
end

local function TogglePicker(anchorButton)
    local frame = CreatePicker()
    if frame:IsShown() then
        frame:Hide()
        return
    end
    frame:ClearAllPoints()
    local bottom = anchorButton:GetBottom() or 0
    local screen = UIParent:GetHeight() or 768
    if bottom > screen * 0.5 then
        frame:SetPoint("TOP", anchorButton, "BOTTOM", 0, -8)
    else
        frame:SetPoint("BOTTOM", anchorButton, "TOP", 0, 8)
    end
    pickerBlocker:SetFrameLevel(max(1, frame:GetFrameLevel() - 1))
    frame:Show()
end

-- ---------------------------------------------------------------------------
-- The dock
-- ---------------------------------------------------------------------------
local dock = CreateFrame("Frame", "ChatOrbsFrame", UIParent)
dock:SetFrameStrata("MEDIUM")
dock:SetWidth(ORB_STEP * 9)
dock:SetHeight(DOCK_H)
dock:SetMovable(true)
dock:SetClampedToScreen(true)
dock:RegisterForDrag("LeftButton")
dock:Hide()
ChatOrbs.frame = dock

local dockPanel = CreatePanel(dock)
dockPanel:SetAllPoints(dock)

local marker = dock:CreateTexture(nil, "OVERLAY")
marker:SetWidth(MARKER_W)
marker:SetHeight(MARKER_H)
marker:Hide()

local captionFont, captionFlags
do
    local source = _G.GameFontNormal
    if source and source.GetFont then
        local path, _, flags = source:GetFont()
        captionFont, captionFlags = path, flags
    end
    captionFont = captionFont or _G.STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
end

--- The interface is laid out on a grid 768 units tall, so one unit covers
--- `scale * screenHeight / 768` physical pixels. Unless that number is whole,
--- every edge of every texture lands between two pixels and the whole bar goes
--- soft and ragged. Snapping the dock's own scale to a whole (or half) pixel
--- per unit is what keeps it crisp - the same trick pixel-perfect UI addons
--- apply to UIParent, applied to one frame so the rest of the UI is untouched.
local function SnapScale(desired)
    local probe = _G.GetPhysicalScreenSize
    if type(probe) ~= "function" then return desired end
    local ok, _, screenHeight = pcall(probe)
    if not ok or type(screenHeight) ~= "number" or screenHeight <= 0 then
        return desired
    end
    local parent = UIParent:GetEffectiveScale()
    if type(parent) ~= "number" or parent <= 0 then return desired end

    local unit = 768 / screenHeight         -- effective scale of one pixel
    local steps = floor(desired * parent / unit * 2 + 0.5) / 2
    if steps < 0.5 then steps = 0.5 end
    local snapped = steps * unit / parent
    -- A snap that changes the size wildly would be worse than soft edges.
    if snapped < desired * 0.55 or snapped > desired * 1.8 then return desired end
    return snapped
end

--- Re-anchors the dock to UIParent, rounded so its corner sits on a whole
--- physical pixel. GetLeft and SetPoint offsets share the frame's own
--- coordinate space, so no scale conversion is needed beyond the rounding.
local function NormalizeAnchor()
    local left, bottom = dock:GetLeft(), dock:GetBottom()
    if not left or not bottom then return end
    local effective = dock:GetEffectiveScale()
    if type(effective) == "number" and effective > 0 then
        left = floor(left * effective + 0.5) / effective
        bottom = floor(bottom * effective + 0.5) / effective
    end
    dock:ClearAllPoints()
    dock:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", left, bottom)
end

local function StartMove()
    if ChatOrbsDB and ChatOrbsDB.locked then return end
    dock:StartMoving()
    dock.moving = true
end

local function StopMove()
    if not dock.moving then return end
    dock:StopMovingOrSizing()
    dock.moving = false
    NormalizeAnchor()
    ChatOrbs:SavePosition()
end

local function OnButtonEnter(self)
    local entry = self.entry
    if not entry then return end
    SetHover(self, true)
    if _G.GameTooltip then
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(entry.title, 1, 0.82, 0)
        if entry.isEmote then
            GameTooltip:AddLine(T("Щелчок — список эмоций.",
                                  "Click for the emote list."), 1, 1, 1, true)
            GameTooltip:AddLine(T("Правый щелчок — своя эмоция текстом.",
                                  "Right-click to type a custom emote."), 1, 1, 1, true)
        elseif entry.needsTarget then
            GameTooltip:AddLine(T("Щелчок — написать личное сообщение.",
                                  "Click to start a whisper."), 1, 1, 1, true)
        else
            GameTooltip:AddLine(T("Щелчок — писать в этот канал.",
                                  "Click to type in this channel."), 1, 1, 1, true)
        end
        if not (ChatOrbsDB and ChatOrbsDB.locked) then
            GameTooltip:AddLine(T("Перетаскивание — передвинуть панель.",
                                  "Drag to move the dock."), 0.6, 0.6, 0.6, true)
        end
        GameTooltip:Show()
    end
end

local function OnButtonLeave(self)
    SetHover(self, false)
    if _G.GameTooltip then GameTooltip:Hide() end
end

local function OnButtonMouseDown(self)
    self.pressed = true
    ApplyVisual(self)
end

local function OnButtonMouseUp(self)
    self.pressed = false
    ApplyVisual(self)
end

local function OnButtonDragStart(self)
    self.pressed = false
    ApplyVisual(self)
    StartMove()
end

local function OnButtonClick(self, mouseButton)
    local entry = self.entry
    if not entry then return end
    if entry.isEmote and mouseButton ~= "RightButton" then
        TogglePicker(self)
        return
    end
    HidePicker()
    OpenChatFor(entry)
end

local function StyleButton(button, flat)
    if flat then
        for _, tex in ipairs({ button.orb, button.sheen, button.glow }) do
            if tex.SetColorTexture then
                tex:SetColorTexture(1, 1, 1, 1)
            else
                tex:SetTexture(1, 1, 1, 1)
            end
        end
        button.sheen:Hide()
        button.glow:Hide()
    else
        button.orb:SetTexture(TEX_ORB)
        button.sheen:SetTexture(TEX_SHEEN)
        button.glow:SetTexture(TEX_GLOW)
        button.sheen:Show()
        button.glow:Show()
    end
end

local function CreateButton(index)
    local button = CreateFrame("Button", "ChatOrbsButton" .. index, dock)
    button:SetWidth(HIT_SIZE)
    button:SetHeight(HIT_SIZE)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    button.glow = button:CreateTexture(nil, "BACKGROUND")
    button.glow:SetWidth(GLOW_SIZE)
    button.glow:SetHeight(GLOW_SIZE)
    button.glow:SetPoint("CENTER")
    button.glow:SetBlendMode("ADD")
    button.glow:SetAlpha(0)

    button.orb = button:CreateTexture(nil, "ARTWORK")
    button.sheen = button:CreateTexture(nil, "OVERLAY")
    button.sheen:SetAlpha(SHEEN_REST)

    button.caption = button:CreateFontString(nil, "OVERLAY")
    if not button.caption:SetFont(captionFont, CAPTION_SIZE, captionFlags) then
        button.caption:SetFontObject("GameFontNormal")
    end

    button.hoverAmount = 0
    StyleButton(button, ChatOrbsDB and ChatOrbsDB.flat)
    ApplyVisual(button)

    button:RegisterForDrag("LeftButton")
    button:SetScript("OnDragStart", OnButtonDragStart)
    button:SetScript("OnDragStop", StopMove)
    button:SetScript("OnEnter", OnButtonEnter)
    button:SetScript("OnLeave", OnButtonLeave)
    button:SetScript("OnMouseDown", OnButtonMouseDown)
    button:SetScript("OnMouseUp", OnButtonMouseUp)
    button:SetScript("OnHide", OnButtonMouseUp)
    button:SetScript("OnClick", OnButtonClick)
    return button
end

function ChatOrbs:Rebuild()
    local entries = BuildEntries()
    local flat = ChatOrbsDB and ChatOrbsDB.flat

    for index, entry in ipairs(entries) do
        local button = self.buttons[index]
        if not button then
            button = CreateButton(index)
            self.buttons[index] = button
        end
        button.entry = entry
        button:ClearAllPoints()
        button:SetPoint("CENTER", dock, "BOTTOMLEFT",
                        DOCK_INNER + ORB_SIZE / 2 + (index - 1) * ORB_STEP, DOCK_H / 2)
        local r, g, b = ColorFor(entry.colorKey)
        button.orb:SetVertexColor(r, g, b)
        button.glow:SetVertexColor(r, g, b)
        button.caption:SetText(entry.caption)
        button.caption:SetTextColor(r * CAPTION_DARKEN, g * CAPTION_DARKEN,
                                    b * CAPTION_DARKEN)
        button.hoverAmount = 0
        button.pressed = false
        tweening[button] = nil
        StyleButton(button, flat)
        ApplyVisual(button)
        button:Show()
    end

    for index = #entries + 1, #self.buttons do
        self.buttons[index].entry = nil
        self.buttons[index]:Hide()
    end

    local count = max(#entries, 1)
    dock:SetWidth((count - 1) * ORB_STEP + ORB_SIZE + DOCK_INNER * 2)
    dock:SetHeight(DOCK_H)
    dockPanel:Layout()
    dockPanel:Restyle(flat)
    if marker.SetTexture and not flat then
        marker:SetTexture(TEX_MARKER)
    elseif marker.SetColorTexture then
        marker:SetColorTexture(1, 1, 1, 1)
    end
    self:UpdateMarker()
end

--- Highlights the orb the chat edit box is currently pointed at.
function ChatOrbs:UpdateMarker()
    local editBox = GetEditBox()
    local key
    if editBox and editBox:IsShown() then
        local chatType = editBox:GetAttribute("chatType")
        if chatType == "CHANNEL" then
            key = "CHANNEL" .. tostring(editBox:GetAttribute("channelTarget"))
        elseif type(chatType) == "string" then
            key = chatType
        end
    end
    if key == self.markerKey then return end
    self.markerKey = key

    for _, button in ipairs(self.buttons) do
        if button.entry and button:IsShown() and button.entry.key == key then
            local r, g, b = ColorFor(button.entry.colorKey)
            marker:ClearAllPoints()
            marker:SetPoint("CENTER", button, "CENTER", 0, -(ORB_SIZE / 2 + 3))
            marker:SetVertexColor(r, g, b)
            marker:Show()
            return
        end
    end
    marker:Hide()
end

function ChatOrbs:SavePosition()
    local point, _, relPoint, x, y = dock:GetPoint()
    if not point or not x or not y then return end
    ChatOrbsDB.point, ChatOrbsDB.relPoint = point, relPoint
    ChatOrbsDB.x, ChatOrbsDB.y = x, y
end

function ChatOrbs:RestorePosition()
    dock:ClearAllPoints()
    if ChatOrbsDB.x and ChatOrbsDB.y then
        dock:SetPoint(ChatOrbsDB.point or "BOTTOMLEFT", UIParent,
                      ChatOrbsDB.relPoint or "BOTTOMLEFT", ChatOrbsDB.x, ChatOrbsDB.y)
        return
    end
    if _G.ChatFrame1 then
        dock:SetPoint("BOTTOMLEFT", _G.ChatFrame1, "TOPLEFT", 0, 34)
    else
        dock:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 35, 340)
    end
    NormalizeAnchor()
    self:SavePosition()
end

function ChatOrbs:ApplyLock()
    dock:EnableMouse(not ChatOrbsDB.locked)
end

function ChatOrbs:ApplyScale(newScale)
    local point, _, relPoint, x, y = dock:GetPoint()
    local old = dock:GetScale()
    local applied = SnapScale(newScale)
    dock:SetScale(applied)
    -- SetPoint offsets live in the frame's own scale, so they need converting
    -- for the dock to stay where it looks like it is.
    if point and x and y and old and old > 0 then
        dock:ClearAllPoints()
        dock:SetPoint(point, UIParent, relPoint, x * old / applied, y * old / applied)
    end
    NormalizeAnchor()
    ChatOrbsDB.scale = newScale
    self:SavePosition()
    return applied
end

function ChatOrbs:ApplyVisibility()
    if ChatOrbsDB.hidden then
        HidePicker()
        dock:Hide()
    else
        dock:Show()
    end
end

-- ---------------------------------------------------------------------------
-- Deferred rebuild
-- ---------------------------------------------------------------------------
local rebuildPending, timerFrame = false, nil

local function DoRebuild()
    rebuildPending = false
    ChatOrbs:Rebuild()
end

local function RequestRebuild()
    if rebuildPending then return end
    rebuildPending = true
    if _G.C_Timer and C_Timer.After then
        C_Timer.After(0.2, DoRebuild)
        return
    end
    if not timerFrame then timerFrame = CreateFrame("Frame") end
    timerFrame.elapsed = 0
    timerFrame:SetScript("OnUpdate", function(self, elapsed)
        self.elapsed = self.elapsed + (elapsed or 0)
        if self.elapsed >= 0.2 then
            self:SetScript("OnUpdate", nil)
            DoRebuild()
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Slash commands
-- ---------------------------------------------------------------------------
local function Print(msg)
    local frame = _G.DEFAULT_CHAT_FRAME
    if frame then frame:AddMessage("|cffffd100ChatOrbs|r " .. msg) end
end

local function PrintHelp()
    Print(T("доступные команды:", "available commands:"))
    local lines = {
        { "/chatorbs",         T("список команд.", "show this list.") },
        { "/chatorbs lock",    T("запретить перемещение.", "lock the dock in place.") },
        { "/chatorbs unlock",  T("разрешить перемещение.", "allow dragging the dock.") },
        { "/chatorbs reset",   T("вернуть положение и масштаб по умолчанию.",
                                 "restore the default position and scale.") },
        { "/chatorbs scale 1", T("масштаб панели (0.5 - 3).", "dock scale (0.5 - 3).") },
        { "/chatorbs hide",    T("скрыть панель.", "hide the dock.") },
        { "/chatorbs show",    T("показать панель.", "show the dock.") },
        { "/chatorbs flat",    T("режим без текстур — на случай, если кнопки не видны.",
                                 "texture-free mode, in case the orbs do not render.") },
    }
    for _, line in ipairs(lines) do
        Print("|cff80ff80" .. line[1] .. "|r — " .. line[2])
    end
end

local function HandleSlash(input)
    input = strtrim(strlower(input or ""))
    local command, argument = input:match("^(%S*)%s*(.-)$")

    if command == "" then
        PrintHelp()

    elseif command == "lock" then
        ChatOrbsDB.locked = true
        ChatOrbs:ApplyLock()
        Print(T("панель закреплена.", "dock locked."))

    elseif command == "unlock" then
        ChatOrbsDB.locked = false
        ChatOrbs:ApplyLock()
        Print(T("панель откреплена, её можно перетаскивать.",
                "dock unlocked, drag it anywhere."))

    elseif command == "reset" then
        ChatOrbsDB.point, ChatOrbsDB.relPoint = nil, nil
        ChatOrbsDB.x, ChatOrbsDB.y = nil, nil
        ChatOrbsDB.scale = 1
        dock:SetScale(SnapScale(1))
        ChatOrbs:RestorePosition()
        Print(T("положение и масштаб сброшены.", "position and scale reset."))

    elseif command == "scale" then
        local value = tonumber(argument)
        if not value then
            Print(T("текущий масштаб: ", "current scale: ") .. tostring(dock:GetScale()))
        elseif value < MIN_SCALE or value > MAX_SCALE then
            Print(T("масштаб должен быть от 0.5 до 3.",
                    "scale must be between 0.5 and 3."))
        else
            local applied = ChatOrbs:ApplyScale(value)
            local message = T("масштаб: ", "scale: ") .. value
            if applied and math.abs(applied - value) > 0.01 then
                message = message
                    .. T(" (подогнан до ", " (snapped to ")
                    .. string.format("%.3f", applied)
                    .. T(", чтобы края попадали на целые пиксели)",
                         " so edges land on whole pixels)")
            end
            Print(message)
        end

    elseif command == "hide" then
        ChatOrbsDB.hidden = true
        ChatOrbs:ApplyVisibility()
        Print(T("панель скрыта. Вернуть: /chatorbs show",
                "dock hidden. Use /chatorbs show to bring it back."))

    elseif command == "show" then
        ChatOrbsDB.hidden = false
        ChatOrbs:ApplyVisibility()
        Print(T("панель показана.", "dock shown."))

    elseif command == "flat" then
        ChatOrbsDB.flat = not ChatOrbsDB.flat
        ChatOrbs:Rebuild()
        if picker then picker.panel:Restyle(ChatOrbsDB.flat) end
        if ChatOrbsDB.flat then
            Print(T("режим без текстур включён.", "texture-free mode on."))
        else
            Print(T("режим без текстур выключен.", "texture-free mode off."))
        end

    else
        Print(T("неизвестная команда: ", "unknown command: ") .. command)
        PrintHelp()
    end
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------
local DEFAULTS = { scale = 1, locked = false, hidden = false, flat = false }

local events = CreateFrame("Frame")

local function Register(event)
    pcall(events.RegisterEvent, events, event)
end

local function HookEditBox()
    local editBox = GetEditBox()
    if not editBox or editBox.chatOrbsHooked or not editBox.HookScript then return end
    editBox.chatOrbsHooked = true
    local function refresh() ChatOrbs:UpdateMarker() end
    pcall(editBox.HookScript, editBox, "OnShow", refresh)
    pcall(editBox.HookScript, editBox, "OnHide", refresh)
    pcall(editBox.HookScript, editBox, "OnTextChanged", refresh)
end

events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")

events:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON_NAME then return end
        if type(_G.ChatOrbsDB) ~= "table" then _G.ChatOrbsDB = {} end
        for key, value in pairs(DEFAULTS) do
            if ChatOrbsDB[key] == nil then ChatOrbsDB[key] = value end
        end
        local scale = tonumber(ChatOrbsDB.scale)
        if not scale or scale < MIN_SCALE or scale > MAX_SCALE then
            ChatOrbsDB.scale = 1
        end
        self:UnregisterEvent("ADDON_LOADED")

    elseif event == "PLAYER_LOGIN" then
        dock:SetScale(SnapScale(ChatOrbsDB.scale or 1))
        ChatOrbs:RestorePosition()
        ChatOrbs:ApplyLock()
        ChatOrbs:Rebuild()
        ChatOrbs:ApplyVisibility()
        HookEditBox()

        -- Events that change which chat targets exist. Registration is wrapped
        -- because an unknown event name is a hard error on current clients and
        -- these names differ between game versions.
        Register("PLAYER_ENTERING_WORLD")
        Register("GROUP_ROSTER_UPDATE")
        Register("PARTY_MEMBERS_CHANGED")
        Register("RAID_ROSTER_UPDATE")
        Register("PLAYER_GUILD_UPDATE")
        Register("CHANNEL_UI_UPDATE")
        Register("CHAT_MSG_CHANNEL_NOTICE")
        Register("UPDATE_CHAT_COLOR")
        Register("BN_CONNECTED")
        Register("BN_DISCONNECTED")
        self:UnregisterEvent("PLAYER_LOGIN")

    else
        HookEditBox()
        RequestRebuild()
    end
end)

dock:SetScript("OnDragStart", StartMove)
dock:SetScript("OnDragStop", StopMove)

SLASH_CHATORBS1 = "/chatorbs"
SlashCmdList["CHATORBS"] = HandleSlash

_G.ChatOrbs = ChatOrbs
