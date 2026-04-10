local ADDON_NAME, ns = ...

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------
local MSG_PREFIX    = "FMG"
local MACRO_NAME    = "FMG Focus"
local MACRO_BODY    = "/focus"
local NEGOTIATE_SEC = 2

local MARKERS = {
    { name = "Star",     icon = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_1", rt = "{rt1}" },
    { name = "Circle",   icon = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_2", rt = "{rt2}" },
    { name = "Diamond",  icon = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_3", rt = "{rt3}" },
    { name = "Triangle", icon = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_4", rt = "{rt4}" },
    { name = "Moon",     icon = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_5", rt = "{rt5}" },
    { name = "Square",   icon = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_6", rt = "{rt6}" },
    { name = "Cross",    icon = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_7", rt = "{rt7}" },
    { name = "Skull",    icon = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_8", rt = "{rt8}" },
}

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------
local myIcon       = nil       -- 1-8 or nil
local claims       = {}        -- [playerName] = iconIndex
local inDungeon    = false
local negotiating  = false
local pendingIcon  = nil       -- deferred macro update (combat lockdown)

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------
local function Print(msg)
    print("|cff00ccffFocusMarkerGroup|r: " .. msg)
end

local function IconStr(idx, size)
    return "|T" .. MARKERS[idx].icon .. ":" .. (size or 0) .. "|t"
end

local function MyName()
    return UnitName("player")
end

local function Send(msg)
    if IsInGroup() then
        local channel = IsInRaid() and "RAID" or "PARTY"
        C_ChatInfo.SendAddonMessage(MSG_PREFIX, msg, channel)
    end
end

local function IsInDungeonInstance()
    local inside, iType = IsInInstance()
    return inside and (iType == "party" or iType == "scenario")
end

--------------------------------------------------------------------------------
-- Macro management (protected, must be out of combat)
--------------------------------------------------------------------------------
local function UpdateMacro(iconIndex)
    if InCombatLockdown() then
        pendingIcon = iconIndex
        return true
    end

    local icon = MARKERS[iconIndex].icon
    local idx  = GetMacroIndexByName(MACRO_NAME)

    if idx > 0 then
        EditMacro(idx, MACRO_NAME, icon, MACRO_BODY)
    else
        local numGlobal, numChar = GetNumMacros()
        if numGlobal < MAX_ACCOUNT_MACROS then
            CreateMacro(MACRO_NAME, icon, MACRO_BODY, false)
        elseif numChar < MAX_CHARACTER_MACROS then
            CreateMacro(MACRO_NAME, icon, MACRO_BODY, true)
        else
            Print("No macro slots available — delete one and type |cffffff00/fmg reset|r")
            return false
        end
    end
    return true
end

--------------------------------------------------------------------------------
-- Icon negotiation
--------------------------------------------------------------------------------
local function LowestAvailableIcon()
    local taken = {}
    for player, icon in pairs(claims) do
        if player ~= MyName() then
            taken[icon] = true
        end
    end
    for i = 1, #MARKERS do
        if not taken[i] then return i end
    end
    return nil
end

local function ClaimIcon(iconIndex)
    myIcon = iconIndex
    claims[MyName()] = iconIndex
    Send("CLAIM:" .. iconIndex)

    if UpdateMacro(iconIndex) then
        Print("You are " .. IconStr(iconIndex, 16) .. " " .. MARKERS[iconIndex].name
              .. "  — macro |cfffff569'" .. MACRO_NAME .. "'|r updated.")
    end
end

local function ReleaseIcon()
    if myIcon then Send("RELEASE") end
    myIcon      = nil
    claims      = {}
    negotiating = false
end

local function StartNegotiation()
    if negotiating then return end
    negotiating = true
    claims = {}

    Send("HELLO")

    C_Timer.After(NEGOTIATE_SEC, function()
        negotiating = false
        if not inDungeon then return end

        local icon = LowestAvailableIcon()
        if icon then
            ClaimIcon(icon)
        else
            Print("All 8 marker icons are taken!")
        end
    end)
end

--------------------------------------------------------------------------------
-- Dungeon enter / leave
--------------------------------------------------------------------------------
local function CheckDungeonState()
    local was = inDungeon
    inDungeon  = IsInDungeonInstance()

    if inDungeon then
        if IsInGroup() then
            if not was or not myIcon then
                StartNegotiation()
            end
        elseif not myIcon then
            -- Solo dungeon — just take Star
            myIcon = 1
            claims[MyName()] = 1
            if UpdateMacro(1) then
                Print("Solo — you are " .. IconStr(1, 16) .. " " .. MARKERS[1].name)
            end
        end
    elseif was then
        ReleaseIcon()
    end
end

--------------------------------------------------------------------------------
-- Stale-claim cleanup (group member left)
--------------------------------------------------------------------------------
local function CleanupStaleClaims()
    local members = {}
    members[MyName()] = true

    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            local name = (GetRaidRosterInfo(i))
            if name then members[name] = true end
        end
    elseif IsInGroup() then
        for i = 1, GetNumGroupMembers() - 1 do
            local name = UnitName("party" .. i)
            if name then members[name] = true end
        end
    end

    for player in pairs(claims) do
        if not members[player] then
            claims[player] = nil
        end
    end
end

--------------------------------------------------------------------------------
-- Event frame
--------------------------------------------------------------------------------
local f = CreateFrame("Frame")
C_ChatInfo.RegisterAddonMessagePrefix(MSG_PREFIX)

f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("ZONE_CHANGED_NEW_AREA")
f:RegisterEvent("GROUP_ROSTER_UPDATE")
f:RegisterEvent("CHAT_MSG_ADDON")
f:RegisterEvent("PLAYER_REGEN_ENABLED")

f:SetScript("OnEvent", function(self, event, ...)

    ------------------------------------------------------------------ boot
    if event == "PLAYER_LOGIN" then
        Print("Loaded — enter a dungeon to get your focus marker.")

    ------------------------------------------------------------------ zone
    elseif event == "PLAYER_ENTERING_WORLD"
        or event == "ZONE_CHANGED_NEW_AREA" then
        C_Timer.After(1, CheckDungeonState)

    ------------------------------------------------------------------ group
    elseif event == "GROUP_ROSTER_UPDATE" then
        CleanupStaleClaims()

        if inDungeon and IsInGroup() then
            if not myIcon then
                StartNegotiation()
            else
                Send("CLAIM:" .. myIcon)      -- announce to newcomers
            end
        elseif not IsInGroup() then
            if not inDungeon then ReleaseIcon() end
            -- still in dungeon solo → keep current icon
        end

    ------------------------------------------------------------------ comms
    elseif event == "CHAT_MSG_ADDON" then
        local prefix, msg, _, sender = ...
        if prefix ~= MSG_PREFIX then return end

        local who = Ambiguate(sender, "short")
        if who == MyName() then return end

        -- HELLO — someone joined, send our claim
        if msg == "HELLO" then
            if myIcon then Send("CLAIM:" .. myIcon) end
            return
        end

        -- CLAIM:N
        local claimed = msg:match("^CLAIM:(%d+)$")
        if claimed then
            local icon = tonumber(claimed)
            if not icon or icon < 1 or icon > #MARKERS then return end

            if myIcon and icon == myIcon then
                -- conflict: alphabetically-first name wins
                if who < MyName() then
                    claims[who] = icon
                    myIcon = nil
                    Print(who .. " has priority for " .. MARKERS[icon].name .. " — reassigning…")
                    local next = LowestAvailableIcon()
                    if next then ClaimIcon(next) end
                else
                    Send("CLAIM:" .. myIcon)   -- re-assert
                end
            else
                claims[who] = icon
            end
            return
        end

        -- RELEASE
        if msg == "RELEASE" then
            claims[who] = nil
        end

    ------------------------------------------------------------------ combat end
    elseif event == "PLAYER_REGEN_ENABLED" then
        if pendingIcon then
            local icon = pendingIcon
            pendingIcon = nil
            UpdateMacro(icon)
            Print("Combat over — macro updated: " .. IconStr(icon, 16) .. " " .. MARKERS[icon].name)
        end
    end
end)

--------------------------------------------------------------------------------
-- Slash commands:  /fmg  or  /focusmarkergroup
--------------------------------------------------------------------------------
SLASH_FMG1 = "/fmg"
SLASH_FMG2 = "/focusmarkergroup"

SlashCmdList["FMG"] = function(input)
    local cmd = strtrim(input):lower()

    if cmd == "" or cmd == "status" then
        if not myIcon then
            Print("No marker assigned. Enter a dungeon with your group.")
            return
        end
        Print("Your marker: " .. IconStr(myIcon, 16) .. " " .. MARKERS[myIcon].name)

        -- sorted list of all assignments
        local sorted = {}
        for player, icon in pairs(claims) do
            sorted[#sorted + 1] = { player = player, icon = icon }
        end
        table.sort(sorted, function(a, b) return a.icon < b.icon end)

        if #sorted > 1 then
            Print("Party assignments:")
            for _, entry in ipairs(sorted) do
                Print("  " .. IconStr(entry.icon, 14) .. " " .. MARKERS[entry.icon].name
                      .. " — " .. entry.player)
            end
        end

    elseif cmd == "reset" or cmd == "retry" then
        if inDungeon and IsInGroup() then
            ReleaseIcon()
            StartNegotiation()
            Print("Re-negotiating…")
        elseif inDungeon then
            myIcon = nil
            claims = {}
            CheckDungeonState()
        else
            Print("You must be in a dungeon to reassign markers.")
        end

    else
        Print("Usage: |cfffff569/fmg|r [status | reset]")
    end
end
