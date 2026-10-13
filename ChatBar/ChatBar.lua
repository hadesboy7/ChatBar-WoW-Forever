--[[---------------------------------------------------------------------------
    ChatBar - a compact row of chat-channel buttons.

    Gold caption above, round coloured orb below, one entry per chat target
    that is actually available to the character right now.  Clicking an orb
    opens the chat edit box already switched to that channel.

    The bar rebuilds itself from the game state, so it never offers a party,
    raid, guild or numbered channel the player is not in.
-----------------------------------------------------------------------------]]

local ADDON_NAME = ...

-- ---------------------------------------------------------------------------
-- Layout.  Every value below was measured from the reference screenshot.
-- ---------------------------------------------------------------------------
local BUTTON_SIZE = 22          -- orb texture footprint / clickable area
local BUTTON_STEP = 26          -- centre-to-centre distance between orbs
local LABEL_SIZE  = 15          -- caption font height
local LABEL_GAP   = 3           -- caption box sits this far above the orb
local BAR_HEIGHT  = BUTTON_SIZE + LABEL_GAP + LABEL_SIZE + 3

local TEXTURE_ORB   = "Interface\\AddOns\\ChatBar\\Textures\\Orb"
local TEXTURE_GLOSS = "Interface\\AddOns\\ChatBar\\Textures\\OrbGloss"

local CAPTION_R, CAPTION_G, CAPTION_B = 1.0, 0.82, 0.0   -- NORMAL_FONT_COLOR

local MIN_SCALE, MAX_SCALE = 0.5, 3.0

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------
local _G = _G
local select, type, pairs, ipairs, pcall = select, type, pairs, ipairs, pcall
local tonumber, tostring = tonumber, tostring
local floor, max = math.floor, math.max
local strbyte, strsub, strlower, strupper =
      string.byte, string.sub, string.lower, string.upper
local unpack = _G.unpack or table.unpack
local strtrim = _G.strtrim or function(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local isRU = (_G.GetLocale and GetLocale() == "ruRU") or false

local function T(ru, en)
    if isRU then return ru end
    return en
end

--- First UTF-8 character of a string.  Cyrillic captions are multi-byte, so a
--- plain strsub(s, 1, 1) would cut a character in half.
local function FirstChar(s)
    if type(s) ~= "string" or s == "" then return "?" end
    local b = strbyte(s, 1)
    local n = 1
    if b >= 0xF0 then n = 4
    elseif b >= 0xE0 then n = 3
    elseif b >= 0xC0 then n = 2 end
    local c = strsub(s, 1, n)
    if n == 1 then c = strupper(c) end
    return c
end

--- First non-empty string among the named globals, else the given default.
local function Global(default, ...)
    for i = 1, select("#", ...) do
        local v = _G[select(i, ...)]
        if type(v) == "string" and v ~= "" then return v end
    end
    return default
end

--- Packs a vararg while preserving embedded nils.
local function Pack(...)
    local t = { n = select("#", ...) }
    for i = 1, t.n do t[i] = select(i, ...) end
    return t
end

--- Looks a FrameXML chat helper up by its classic global name first and by its
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
-- Colours.  ChatTypeInfo is used when present, so the orbs follow whatever the
-- player configured in the chat colour options; the table below is the stock
-- fallback (and the set the reference screenshot was taken with).
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
    BATTLEGROUND  = { 1.00, 0.50, 0.00 },
    GUILD         = { 0.25, 1.00, 0.25 },
    OFFICER       = { 0.25, 0.75, 0.25 },
    CHANNEL       = { 1.00, 0.75, 0.75 },
}

local function ColorFor(key)
    local info = _G.ChatTypeInfo and _G.ChatTypeInfo[key]
    if type(info) == "table" and type(info.r) == "number" then
        return info.r, info.g, info.b
    end
    local c = FALLBACK_COLOR[key]
    if not c then
        -- "CHANNEL7" and friends fall back to the generic channel colour.
        c = FALLBACK_COLOR[(key or ""):gsub("%d+$", "")]
    end
    c = c or FALLBACK_COLOR.SAY
    return c[1], c[2], c[3]
end

-- ---------------------------------------------------------------------------
-- Availability probes.  Each one treats a missing API as "not available"
-- rather than raising an error.
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
-- The fixed chat targets, in the order they appear on the reference panel.
-- `label` names the globals the gold caption is derived from; its first letter
-- is what ends up on screen (ruRU: Сказать -> С, Крик -> К, Шепот -> Ш, ...).
-- ---------------------------------------------------------------------------
local STATIC_ENTRIES = {
    { chatType = "SAY",           slash = { "SLASH_SAY1" },
      label = { "SAY" },                                      fallback = "Say" },
    { chatType = "YELL",          slash = { "SLASH_YELL1" },
      label = { "YELL" },                                     fallback = "Yell" },
    { chatType = "WHISPER",       slash = { "SLASH_WHISPER1", "SLASH_SMART_WHISPER1" },
      label = { "WHISPER" },        needsTarget = true,       fallback = "Whisper" },
    { chatType = "BN_WHISPER",    slash = { "SLASH_BNWHISPER1", "SLASH_WHISPER1" },
      label = { "BN_WHISPER", "BATTLENET_WHISPER", "WHISPER" },
      needsTarget = true,           available = HasBattlenet, fallback = "Whisper" },
    { chatType = "EMOTE",         slash = { "SLASH_EMOTE1" },
      label = { "EMOTE", "CHAT_MSG_EMOTE" },                  fallback = "Emote" },
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

-- ---------------------------------------------------------------------------
-- Chat edit box plumbing
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

local function ActivateEditBox(editBox)
    local activate = ChatFunc("ChatEdit_ActivateChat", "ActivateChat")
    if activate then pcall(activate, editBox) end
    if not editBox:IsShown() then editBox:Show() end
    editBox:SetFocus()
end

--- Best guess at who a whisper should go to, or nil to let the player type it.
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

--- Opens the chat edit box switched to `entry`'s channel.
local function OpenChatFor(entry)
    local editBox = GetEditBox()
    if not editBox then return end

    ActivateEditBox(editBox)

    local updateHeader = ChatFunc("ChatEdit_UpdateHeader", "UpdateHeader")
    local chatType = entry.chatType
    local target

    if entry.needsTarget and chatType == "WHISPER" then
        target = WhisperTarget()
    end

    -- Primary path: the attribute protocol that ChatEdit_SendText reads when
    -- the player presses Enter.  Anything the player already typed is kept.
    if updateHeader and not (entry.needsTarget and not target) then
        editBox:SetAttribute("chatType", chatType)
        if chatType == "CHANNEL" then
            editBox:SetAttribute("channelTarget", entry.channelId)
        elseif target then
            editBox:SetAttribute("tellTarget", target)
        end
        pcall(updateHeader, editBox)
        return
    end

    -- Fallback path: put the slash command in the box.  Used for a whisper
    -- with no obvious recipient (the player types the name), and on any client
    -- where the chat helpers could not be resolved.  Even if the edit box does
    -- not re-parse the text on the spot, it stays a valid command, so pressing
    -- Enter still reaches the right channel.
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
end

-- ---------------------------------------------------------------------------
-- Entry list
-- ---------------------------------------------------------------------------
local function AddChannelEntries(out)
    if type(_G.GetChannelList) ~= "function" then return end
    local ok, list = pcall(function() return Pack(GetChannelList()) end)
    if not ok or type(list) ~= "table" then return end

    -- GetChannelList returns (id, name) pairs on old clients and
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
            local slash
            for _, name in ipairs(def.slash) do
                local value = _G[name]
                if type(value) == "string" and value ~= "" then
                    slash = value
                    break
                end
            end
            entries[#entries + 1] = {
                chatType    = def.chatType,
                colorKey    = def.chatType,
                caption     = FirstChar(title),
                title       = title,
                slashText   = slash,
                needsTarget = def.needsTarget,
            }
        end
    end

    AddChannelEntries(entries)
    return entries
end

-- ---------------------------------------------------------------------------
-- The bar
-- ---------------------------------------------------------------------------
local ChatBar = { buttons = {} }

local bar = CreateFrame("Frame", "ChatBarFrame", UIParent)
bar:SetFrameStrata("MEDIUM")
bar:SetWidth(BUTTON_STEP * 9)
bar:SetHeight(BAR_HEIGHT)
bar:SetMovable(true)
bar:SetClampedToScreen(true)
bar:RegisterForDrag("LeftButton")
bar:Hide()
ChatBar.frame = bar

local captionFont, captionFlags
do
    local source = _G.GameFontNormal
    if source and source.GetFont then
        local path, _, flags = source:GetFont()
        captionFont, captionFlags = path, flags
    end
    captionFont = captionFont or _G.STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
end

--- Re-anchors the bar to UIParent without moving it on screen.  GetLeft and
--- SetPoint offsets share the frame's own coordinate space, so no scale
--- conversion is needed here.
local function NormalizeAnchor()
    local left, bottom = bar:GetLeft(), bar:GetBottom()
    if not left or not bottom then return end
    bar:ClearAllPoints()
    bar:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", left, bottom)
end

local function StartMove()
    if ChatBarDB and ChatBarDB.locked then return end
    bar:StartMoving()
    bar.moving = true
end

local function StopMove()
    if not bar.moving then return end
    bar:StopMovingOrSizing()
    bar.moving = false
    NormalizeAnchor()
    ChatBar:SavePosition()
end

local function SetContentOffset(button, dx, dy)
    button.orb:ClearAllPoints()
    button.orb:SetPoint("TOPLEFT", button, "TOPLEFT", dx, dy)
    button.orb:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", dx, dy)
    button.gloss:ClearAllPoints()
    button.gloss:SetPoint("TOPLEFT", button, "TOPLEFT", dx, dy)
    button.gloss:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", dx, dy)
    button.caption:ClearAllPoints()
    button.caption:SetPoint("BOTTOM", button, "TOP", dx, LABEL_GAP + dy)
end

local function OnButtonEnter(self)
    local entry = self.entry
    if not entry then return end
    self.caption:SetTextColor(1, 1, 1)
    if _G.GameTooltip then
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(entry.title, CAPTION_R, CAPTION_G, CAPTION_B)
        if entry.needsTarget then
            GameTooltip:AddLine(T("Щелчок — написать личное сообщение.",
                                  "Click to start a whisper."), 1, 1, 1, true)
        else
            GameTooltip:AddLine(T("Щелчок — писать в этот канал.",
                                  "Click to type in this channel."), 1, 1, 1, true)
        end
        if not (ChatBarDB and ChatBarDB.locked) then
            GameTooltip:AddLine(T("Перетаскивание — передвинуть панель.",
                                  "Drag to move the bar."), 0.6, 0.6, 0.6, true)
        end
        GameTooltip:Show()
    end
end

local function OnButtonLeave(self)
    self.caption:SetTextColor(CAPTION_R, CAPTION_G, CAPTION_B)
    if _G.GameTooltip then GameTooltip:Hide() end
end

local function OnButtonMouseDown(self)
    SetContentOffset(self, 1, -1)
end

local function OnButtonMouseUp(self)
    SetContentOffset(self, 0, 0)
end

local function OnButtonDragStart(self)
    SetContentOffset(self, 0, 0)
    StartMove()
end

local function OnButtonClick(self)
    if self.entry then OpenChatFor(self.entry) end
end

local function CreateButton(index)
    local button = CreateFrame("Button", "ChatBarButton" .. index, bar)
    button:SetWidth(BUTTON_SIZE)
    button:SetHeight(BUTTON_SIZE)

    button.orb = button:CreateTexture(nil, "ARTWORK")
    button.orb:SetTexture(TEXTURE_ORB)

    button.gloss = button:CreateTexture(nil, "OVERLAY")
    button.gloss:SetTexture(TEXTURE_GLOSS)
    button.gloss:SetBlendMode("ADD")

    button.caption = button:CreateFontString(nil, "OVERLAY")
    if not button.caption:SetFont(captionFont, LABEL_SIZE, captionFlags) then
        button.caption:SetFontObject("GameFontNormal")
    end
    button.caption:SetShadowColor(0, 0, 0, 1)
    button.caption:SetShadowOffset(1, -1)
    button.caption:SetTextColor(CAPTION_R, CAPTION_G, CAPTION_B)

    SetContentOffset(button, 0, 0)

    button:SetHighlightTexture(TEXTURE_ORB, "ADD")
    local highlight = button:GetHighlightTexture()
    if highlight then
        highlight:SetVertexColor(1, 1, 1)
        highlight:SetAlpha(0.3)
    end

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

function ChatBar:Rebuild()
    local entries = BuildEntries()

    for index, entry in ipairs(entries) do
        local button = self.buttons[index]
        if not button then
            button = CreateButton(index)
            self.buttons[index] = button
        end
        button.entry = entry
        button:ClearAllPoints()
        button:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", (index - 1) * BUTTON_STEP, 0)
        button.orb:SetVertexColor(ColorFor(entry.colorKey))
        button.caption:SetText(entry.caption)
        button.caption:SetTextColor(CAPTION_R, CAPTION_G, CAPTION_B)
        SetContentOffset(button, 0, 0)
        button:Show()
    end

    for index = #entries + 1, #self.buttons do
        self.buttons[index].entry = nil
        self.buttons[index]:Hide()
    end

    bar:SetWidth((max(#entries, 1) - 1) * BUTTON_STEP + BUTTON_SIZE)
    bar:SetHeight(BAR_HEIGHT)
end

function ChatBar:SavePosition()
    local point, _, relPoint, x, y = bar:GetPoint()
    if not point or not x or not y then return end
    ChatBarDB.point    = point
    ChatBarDB.relPoint = relPoint
    ChatBarDB.x        = x
    ChatBarDB.y        = y
end

function ChatBar:RestorePosition()
    bar:ClearAllPoints()
    if ChatBarDB.x and ChatBarDB.y then
        bar:SetPoint(ChatBarDB.point or "BOTTOMLEFT", UIParent,
                     ChatBarDB.relPoint or "BOTTOMLEFT", ChatBarDB.x, ChatBarDB.y)
        return
    end
    -- First run: sit just above the default chat frame, as on the reference
    -- screenshot, then store that spot in UIParent coordinates.
    if _G.ChatFrame1 then
        bar:SetPoint("BOTTOMLEFT", _G.ChatFrame1, "TOPLEFT", 0, 30)
    else
        bar:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 35, 340)
    end
    NormalizeAnchor()
    self:SavePosition()
end

function ChatBar:ApplyLock()
    bar:EnableMouse(not ChatBarDB.locked)
end

function ChatBar:ApplyScale(newScale)
    local point, _, relPoint, x, y = bar:GetPoint()
    local old = bar:GetScale()
    bar:SetScale(newScale)
    -- SetPoint offsets live in the frame's own scale, so they have to be
    -- converted for the bar to stay where it looks like it is.
    if point and x and y and old and old > 0 then
        bar:ClearAllPoints()
        bar:SetPoint(point, UIParent, relPoint, x * old / newScale, y * old / newScale)
    end
    ChatBarDB.scale = newScale
    self:SavePosition()
end

function ChatBar:ApplyVisibility()
    if ChatBarDB.hidden then bar:Hide() else bar:Show() end
end

-- ---------------------------------------------------------------------------
-- Deferred rebuild: several events can fire back to back, so coalesce them
-- into a single rebuild instead of running the whole thing per event.
-- ---------------------------------------------------------------------------
local rebuildPending = false
local timerFrame

local function DoRebuild()
    rebuildPending = false
    ChatBar:Rebuild()
end

local function RequestRebuild()
    if rebuildPending then return end
    rebuildPending = true
    if _G.C_Timer and C_Timer.After then
        C_Timer.After(0.2, DoRebuild)
        return
    end
    -- Clients without C_Timer get a one-shot OnUpdate that removes itself.
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
    if frame then frame:AddMessage("|cffffd100ChatBar|r " .. msg) end
end

local function PrintHelp()
    Print(T("доступные команды:", "available commands:"))
    local lines = {
        { "/chatbar",         T("список команд.", "show this list.") },
        { "/chatbar lock",    T("запретить перемещение.", "lock the bar in place.") },
        { "/chatbar unlock",  T("разрешить перемещение.", "allow dragging the bar.") },
        { "/chatbar reset",   T("вернуть положение и масштаб по умолчанию.",
                                "restore the default position and scale.") },
        { "/chatbar scale 1", T("масштаб панели (0.5 - 3).", "bar scale (0.5 - 3).") },
        { "/chatbar hide",    T("скрыть панель.", "hide the bar.") },
        { "/chatbar show",    T("показать панель.", "show the bar.") },
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
        ChatBarDB.locked = true
        ChatBar:ApplyLock()
        Print(T("панель закреплена.", "bar locked."))

    elseif command == "unlock" then
        ChatBarDB.locked = false
        ChatBar:ApplyLock()
        Print(T("панель откреплена, её можно перетаскивать.",
                "bar unlocked, drag it anywhere."))

    elseif command == "reset" then
        ChatBarDB.point, ChatBarDB.relPoint = nil, nil
        ChatBarDB.x, ChatBarDB.y = nil, nil
        ChatBarDB.scale = 1
        bar:SetScale(1)
        ChatBar:RestorePosition()
        Print(T("положение и масштаб сброшены.", "position and scale reset."))

    elseif command == "scale" then
        local value = tonumber(argument)
        if not value then
            Print(T("текущий масштаб: ", "current scale: ") .. tostring(bar:GetScale()))
        elseif value < MIN_SCALE or value > MAX_SCALE then
            Print(T("масштаб должен быть от 0.5 до 3.",
                    "scale must be between 0.5 and 3."))
        else
            ChatBar:ApplyScale(value)
            Print(T("масштаб: ", "scale: ") .. value)
        end

    elseif command == "hide" then
        ChatBarDB.hidden = true
        ChatBar:ApplyVisibility()
        Print(T("панель скрыта. Вернуть: /chatbar show",
                "bar hidden. Use /chatbar show to bring it back."))

    elseif command == "show" then
        ChatBarDB.hidden = false
        ChatBar:ApplyVisibility()
        Print(T("панель показана.", "bar shown."))

    else
        Print(T("неизвестная команда: ", "unknown command: ") .. command)
        PrintHelp()
    end
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------
local DEFAULTS = { scale = 1, locked = false, hidden = false }

local events = CreateFrame("Frame")

local function Register(event)
    pcall(events.RegisterEvent, events, event)
end

events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")

events:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON_NAME then return end
        if type(_G.ChatBarDB) ~= "table" then _G.ChatBarDB = {} end
        for key, value in pairs(DEFAULTS) do
            if ChatBarDB[key] == nil then ChatBarDB[key] = value end
        end
        local scale = tonumber(ChatBarDB.scale)
        if not scale or scale < MIN_SCALE or scale > MAX_SCALE then
            ChatBarDB.scale = 1
        end
        self:UnregisterEvent("ADDON_LOADED")

    elseif event == "PLAYER_LOGIN" then
        bar:SetScale(ChatBarDB.scale or 1)
        ChatBar:RestorePosition()
        ChatBar:ApplyLock()
        ChatBar:Rebuild()
        ChatBar:ApplyVisibility()

        -- Events that can change which chat targets exist.  Registration is
        -- wrapped because an unknown event name is a hard error on current
        -- clients and these names differ between game versions.
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
        RequestRebuild()
    end
end)

bar:SetScript("OnDragStart", StartMove)
bar:SetScript("OnDragStop", StopMove)

SLASH_CHATBAR1 = "/chatbar"
SlashCmdList["CHATBAR"] = HandleSlash

_G.ChatBar = ChatBar
