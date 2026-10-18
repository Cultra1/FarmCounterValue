-- Farm Counter
-- Lightweight profession loot tracker (fishing, gathering, prospecting, disenchanting, ...)
-- with Session + Global History views and optional TradeSkillMaster auction values.
-- Updated for WoW: Midnight (12.1.x)

local addonName = ...
-- Filled in from the git tag by the packager (## Version: @project-version@ in the .toc).
local ADDON_VERSION = (C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(addonName, "Version")) or "dev"
if ADDON_VERSION:find("@", 1, true) then
    ADDON_VERSION = "dev"
end
-- Structure version of FarmCounterDB, for future migrations.
local DB_VERSION = 1

local DEFAULT_PRICE_SOURCE = "DBMarket"
-- Seconds a looked-up TSM price is reused before it is queried again.
local PRICE_CACHE_TTL = 60
-- Seconds after which a missing price is looked up again.
local PRICE_RETRY_TTL = 10
-- Previous sessions kept for the session dropdown.
local MAX_ARCHIVED_SESSIONS = 5
-- Default for the "Auto hide" option (off by default).
local DEFAULT_AUTO_HIDE_MINUTES = 2
-- Seconds without loot after which an auto session is not continued at the next login.
local AUTO_SESSION_IDLE_TIMEOUT = 30 * 60

-- -----------------------------------------------------------------------------
-- Categories
-- -----------------------------------------------------------------------------
-- Display order of the categories in the window.
local CATEGORY_ORDER = {
    "fish", "cooking", "herb", "ore", "leather", "cloth", "gem",
    "enchanting", "elemental", "inscription", "parts", "reagent", "fishing",
}

local CATEGORY_LABELS = {
    fish = "Fish",
    cooking = "Meat & Cooking",
    herb = "Herbs",
    ore = "Ore & Stone",
    leather = "Leather & Hides",
    cloth = "Cloth",
    gem = "Gems & Pearls",
    enchanting = "Enchanting",
    elemental = "Elemental",
    inscription = "Pigments",
    parts = "Parts & Salvage",
    reagent = "Other Reagents",
    fishing = "Fishing (Other)",
}

local ITEM_CLASS_GEM = 3 -- Enum.ItemClass.Gem
local ITEM_CLASS_TRADEGOODS = 7 -- Enum.ItemClass.Tradegoods

-- Enum.ItemTradeGoodsSubclass -> category
local TRADEGOODS_SUBCLASS_CATEGORY = {
    [0] = "reagent", -- Trade Goods (legacy)
    [1] = "parts", -- Parts (salvage)
    [4] = "gem", -- Jewelcrafting
    [5] = "cloth", -- Cloth
    [6] = "leather", -- Leather
    [7] = "ore", -- Metal & Stone
    [8] = "cooking", -- Cooking (raw fish, meat)
    [9] = "herb", -- Herb
    [10] = "elemental", -- Elemental
    [11] = "reagent", -- Other
    [12] = "enchanting", -- Enchanting (dust, essences, shards)
    [16] = "inscription", -- Inscription (pigments)
    [18] = "reagent", -- Optional Reagents
    [19] = "reagent", -- Finishing Reagents
}

-- Special cases the classID/subclassID mapping does not cover.
-- itemID -> category key, or false to never count the item.
local ITEM_CATEGORY_OVERRIDES = {
    [5498] = "gem", -- Small Lustrous Pearl
    [5500] = "gem", -- Iridescent Pearl
    [7971] = "gem", -- Black Pearl
    [13926] = "gem", -- Golden Pearl
}

-- -----------------------------------------------------------------------------
-- SavedVariables
-- -----------------------------------------------------------------------------
FarmCounterDB = FarmCounterDB or {}

local function NewSession(state)
    return {
        state = state or "auto", -- "auto" (resets on zone change), "running", "stopped"
        startTime = time(),
        endTime = nil,
        zone = nil,
        data = {},
        order = {},
    }
end

local function ApplyDefaults()
    FarmCounterDB.version = FarmCounterDB.version or ADDON_VERSION

    FarmCounterDB.settings = FarmCounterDB.settings or {}
    if FarmCounterDB.settings.mode ~= "session" and FarmCounterDB.settings.mode ~= "history" then
        FarmCounterDB.settings.mode = "session"
    end
    -- "hidden" means the user explicitly hid the window. If nil/false, the addon may show the
    -- window automatically when it has data to display.
    if FarmCounterDB.settings.hidden == nil then
        FarmCounterDB.settings.hidden = false
    end
    if FarmCounterDB.settings.playRareSound == nil then
        FarmCounterDB.settings.playRareSound = true
    end
    if FarmCounterDB.settings.playBlueSound == nil then
        FarmCounterDB.settings.playBlueSound = true
    end
    if type(FarmCounterDB.settings.priceSource) ~= "string" or FarmCounterDB.settings.priceSource == "" then
        FarmCounterDB.settings.priceSource = DEFAULT_PRICE_SOURCE
    end
    -- Count everything looted from a fishing cast (junk, treasures, ...).
    if FarmCounterDB.settings.countAllFishingLoot == nil then
        FarmCounterDB.settings.countAllFishingLoot = true
    end
    -- Auto sessions (no /farmcounter start) reset when you loot in a new zone.
    if FarmCounterDB.settings.zoneReset == nil then
        FarmCounterDB.settings.zoneReset = true
    end
    -- Hide the window after a while without counted loot; it comes back with the next counted loot.
    if FarmCounterDB.settings.autoHide == nil then
        FarmCounterDB.settings.autoHide = false
    end
    if type(FarmCounterDB.settings.autoHideMinutes) ~= "number" then
        FarmCounterDB.settings.autoHideMinutes = DEFAULT_AUTO_HIDE_MINUTES
    end
    FarmCounterDB.settings.categories = FarmCounterDB.settings.categories or {}
    -- Store every category explicitly (true/false) so the options checkboxes can bind to it.
    for _, category in ipairs(CATEGORY_ORDER) do
        FarmCounterDB.settings.categories[category] = FarmCounterDB.settings.categories[category] ~= false
    end

    FarmCounterDB.historyData = FarmCounterDB.historyData or {}
    FarmCounterDB.historyOrder = FarmCounterDB.historyOrder or {}
    FarmCounterDB.sessionHistory = FarmCounterDB.sessionHistory or {}

    if type(FarmCounterDB.session) ~= "table"
        or type(FarmCounterDB.session.data) ~= "table"
        or type(FarmCounterDB.session.order) ~= "table" then
        FarmCounterDB.session = NewSession("auto")
    end

    FarmCounterDB.frame = FarmCounterDB.frame or {}
end

local function Print(msg)
    if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
        DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99FarmCounter|r: " .. tostring(msg))
    else
        print("FarmCounter: " .. tostring(msg))
    end
end

-- -----------------------------------------------------------------------------
-- Helpers
-- -----------------------------------------------------------------------------
local function GetCurrentZoneName()
    local zone = nil

    if GetRealZoneText then
        zone = GetRealZoneText()
    end
    if (not zone or zone == "") and GetZoneText then
        zone = GetZoneText()
    end

    if (not zone or zone == "") and C_Map and C_Map.GetBestMapForUnit and C_Map.GetMapInfo then
        local mapID = C_Map.GetBestMapForUnit("player")
        if mapID then
            local info = C_Map.GetMapInfo(mapID)
            if info and info.name then
                zone = info.name
            end
        end
    end

    return (zone and zone ~= "" and zone) or (UNKNOWN or "Unknown")
end

local function GetQualityHexColor(quality)
    quality = tonumber(quality) or 1

    if ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality] then
        local c = ITEM_QUALITY_COLORS[quality]

        if type(c.hex) == "string" and #c.hex >= 6 then
            -- Typically "ffRRGGBB", sometimes "RRGGBB"
            if #c.hex == 8 then
                return c.hex
            end
            if #c.hex == 6 then
                return "ff" .. c.hex
            end
        end

        if c.r and c.g and c.b then
            local r = math.floor((c.r * 255) + 0.5)
            local g = math.floor((c.g * 255) + 0.5)
            local b = math.floor((c.b * 255) + 0.5)
            return string.format("ff%02x%02x%02x", r, g, b)
        end
    end

    -- Fallback: common white
    return "ffffffff"
end

local lastRareSoundTime = 0

local function PlayRareLootSound(maxQuality)
    if not FarmCounterDB.settings or not FarmCounterDB.settings.playRareSound then
        return
    end
    if not PlaySound then
        return
    end
    -- Rare (blue) items can be muted separately; epic and better always alert.
    if maxQuality < 4 and not FarmCounterDB.settings.playBlueSound then
        return
    end

    -- One loot can produce several loot messages; only play one alert for them.
    local now = GetTime()
    if (now - lastRareSoundTime) < 1.5 then
        return
    end
    lastRareSoundTime = now

    if SOUNDKIT then
        if maxQuality >= 4 and SOUNDKIT.UI_EPICLOOT_TOAST then
            PlaySound(SOUNDKIT.UI_EPICLOOT_TOAST, "Master")
            return
        end
        if maxQuality >= 3 and SOUNDKIT.UI_RARELOOT_TOAST then
            PlaySound(SOUNDKIT.UI_RARELOOT_TOAST, "Master")
            return
        end
        if SOUNDKIT.RAID_WARNING then
            PlaySound(SOUNDKIT.RAID_WARNING, "Master")
            return
        end
    end
end

local function FormatMoney(copper)
    copper = math.floor((tonumber(copper) or 0) + 0.5)
    local gold = math.floor(copper / 10000)
    local silver = math.floor((copper % 10000) / 100)
    local rest = copper % 100

    if gold >= 1000 then
        local goldText = BreakUpLargeNumbers and BreakUpLargeNumbers(gold) or tostring(gold)
        return goldText .. "|cffffd700g|r"
    end
    if gold > 0 then
        return string.format("%d|cffffd700g|r %02d|cffc7c7cfs|r", gold, silver)
    end
    if silver > 0 then
        return string.format("%d|cffc7c7cfs|r %02d|cffeda55fc|r", silver, rest)
    end
    return string.format("%d|cffeda55fc|r", rest)
end

local function FormatDuration(seconds)
    seconds = math.max(0, math.floor(tonumber(seconds) or 0))
    return string.format("%d:%02d:%02d", math.floor(seconds / 3600), math.floor((seconds % 3600) / 60), seconds % 60)
end

local function IsCategoryEnabled(category)
    return FarmCounterDB.settings.categories[category] ~= false
end

local function GetItemInfoInstantCompat(item)
    if C_Item and C_Item.GetItemInfoInstant then
        return C_Item.GetItemInfoInstant(item)
    end
    if GetItemInfoInstant then
        return GetItemInfoInstant(item)
    end
end

-- Returns the category key for an item, or nil if it should not be counted.
local function ClassifyItem(itemID, classID, subclassID, isFishing)
    local override = itemID and ITEM_CATEGORY_OVERRIDES[itemID]
    if override ~= nil then
        return override or nil
    end

    local category = nil
    if classID == ITEM_CLASS_GEM then
        category = "gem"
    elseif classID == ITEM_CLASS_TRADEGOODS then
        category = TRADEGOODS_SUBCLASS_CATEGORY[subclassID]
    end

    if category == "cooking" and isFishing then
        category = "fish"
    end
    if not category and isFishing and FarmCounterDB.settings.countAllFishingLoot then
        category = "fishing"
    end

    return category
end

-- itemInfo = { name=..., quality=..., itemID=..., itemString=..., category=..., tier=... }
local function AddCatch(data, order, itemKey, itemInfo, amount)
    if type(itemKey) ~= "string" or itemKey == "" then
        return
    end

    amount = tonumber(amount) or 1
    if amount < 1 then
        amount = 1
    end

    local entry = data[itemKey]
    if not entry then
        entry = { count = 0 }
        data[itemKey] = entry

        -- Fold a name-keyed entry (no itemID) for the same item into the ID-keyed one.
        local legacyKey = itemInfo.name
        local legacy = legacyKey and legacyKey ~= itemKey and data[legacyKey]
        local replacedInOrder = false
        if type(legacy) == "table" and type(legacy.count) == "number"
            and (not legacy.itemID or legacy.itemID == itemInfo.itemID) then
            entry.count = legacy.count
            entry.quality = legacy.quality
            data[legacyKey] = nil
            for i, key in ipairs(order) do
                if key == legacyKey then
                    order[i] = itemKey
                    replacedInOrder = true
                    break
                end
            end
        end

        if not replacedInOrder then
            table.insert(order, itemKey)
        end
    end

    entry.count = (entry.count or 0) + amount
    entry.name = itemInfo.name or entry.name
    entry.itemID = itemInfo.itemID or entry.itemID
    entry.itemString = itemInfo.itemString or entry.itemString
    entry.category = itemInfo.category or entry.category
    entry.tier = itemInfo.tier or entry.tier
    if itemInfo.quality and (not entry.quality or itemInfo.quality > entry.quality) then
        entry.quality = itemInfo.quality
    end
end

local function HasAnyCatches(data, order)
    return (type(order) == "table" and #order > 0)
        or (type(data) == "table" and next(data) ~= nil)
end

-- -----------------------------------------------------------------------------
-- Session data (saved, separate from the global history)
-- -----------------------------------------------------------------------------
local function GetSession()
    return FarmCounterDB.session
end

local function GetSessionDuration(session)
    if not session or not session.startTime then
        return 0
    end
    local isFinished = session.state == "stopped" or session.state == "archived"
    local endTime = (isFinished and session.endTime) or time()
    return endTime - session.startTime
end

-- Archived session currently shown in the window (nil = current session).
local viewedSession = nil

-- Moves a finished session into FarmCounterDB.sessionHistory (newest first, max MAX_ARCHIVED_SESSIONS).
local function ArchiveSession(session)
    if type(session) ~= "table" or not HasAnyCatches(session.data, session.order) then
        return
    end

    session.endTime = session.endTime or time()
    session.state = "archived"

    local archive = FarmCounterDB.sessionHistory
    table.insert(archive, 1, session)
    while #archive > MAX_ARCHIVED_SESSIONS do
        local removed = table.remove(archive)
        if removed == viewedSession then
            viewedSession = nil
        end
    end
end

-- Archives the current session and starts a new one.
local function ReplaceSession(state)
    ArchiveSession(FarmCounterDB.session)
    FarmCounterDB.session = NewSession(state)
    return FarmCounterDB.session
end

local function GetSessionLabel(session)
    local label = date("%d.%m. %H:%M", session.startTime or time())
        .. "  " .. FormatDuration(GetSessionDuration(session))
    if session.zone then
        label = label .. "  " .. session.zone
    end
    return label
end

-- -----------------------------------------------------------------------------
-- Prices (TradeSkillMaster)
-- -----------------------------------------------------------------------------
local priceCache = {}
local reportedPriceErrors = {}
local lastPriceError = nil
local priceSourceValid = nil -- nil = not checked yet

local function IsTSMAvailable()
    return type(TSM_API) == "table" and type(TSM_API.GetCustomPriceValue) == "function"
end

local function ClearPriceCache()
    wipe(priceCache)
    lastPriceError = nil
    priceSourceValid = nil
end

local function ReportPriceError(source, itemString, err)
    lastPriceError = tostring(err)
    local key = tostring(source) .. "|" .. lastPriceError
    if reportedPriceErrors[key] then
        return
    end
    reportedPriceErrors[key] = true
    Print("|cffff5555TSM price error|r (source \"" .. tostring(source) .. "\""
        .. (itemString and (", item " .. tostring(itemString)) or "") .. "): " .. lastPriceError)
end

-- TSM_API.GetCustomPriceValue also returns an error message when an item simply has no price,
-- so the price source itself is validated separately and only real problems are reported.
local function IsPriceSourceValid()
    if priceSourceValid ~= nil then
        return priceSourceValid
    end

    local source = FarmCounterDB.settings.priceSource or DEFAULT_PRICE_SOURCE
    local ok, isValid, err = pcall(TSM_API.IsCustomPriceValid, source)
    if not ok then
        ReportPriceError(source, nil, isValid)
        priceSourceValid = false
    elseif not isValid then
        ReportPriceError(source, nil, err)
        priceSourceValid = false
    else
        priceSourceValid = true
    end
    return priceSourceValid
end

-- Returns the current price of one item in copper, or nil if TSM is not loaded or has no price.
-- itemString is the TSM item string from the loot link; the plain "i:<itemID>" is tried as fallback.
local function QueryPrice(source, itemString)
    local ok, value = pcall(TSM_API.GetCustomPriceValue, source, itemString)
    if not ok then
        -- Thrown by TSM (e.g. invalid item string); a nil value without a throw just means "no price".
        ReportPriceError(source, itemString, value)
        return nil
    end
    return tonumber(value)
end

local function GetItemPrice(itemString, itemID)
    local baseItemString = itemID and ("i:" .. itemID) or nil
    itemString = itemString or baseItemString
    if type(itemString) ~= "string" or not IsTSMAvailable() or not IsPriceSourceValid() then
        return nil
    end

    local now = GetTime()
    local cached = priceCache[itemString]
    if cached and (now - cached.time) < cached.ttl then
        return cached.value
    end

    local source = FarmCounterDB.settings.priceSource or DEFAULT_PRICE_SOURCE
    local value = QueryPrice(source, itemString)
    if not value and baseItemString and baseItemString ~= itemString then
        value = QueryPrice(source, baseItemString)
    end

    -- Missing prices are retried sooner: TSM loads its AuctionDB data only after our first draw.
    priceCache[itemString] = { value = value, time = now, ttl = value and PRICE_CACHE_TTL or PRICE_RETRY_TTL }
    return value
end

local function ToItemStringCompat(itemLinkOrString, itemID)
    if IsTSMAvailable() and type(TSM_API.ToItemString) == "function" and type(itemLinkOrString) == "string" then
        local ok, itemString = pcall(TSM_API.ToItemString, itemLinkOrString)
        if ok and type(itemString) == "string" then
            return itemString
        end
    end
    return itemID and ("i:" .. itemID) or nil
end

-- -----------------------------------------------------------------------------
-- UI
-- -----------------------------------------------------------------------------
local frame = CreateFrame("Frame", "FarmCounterFrame", UIParent, "BackdropTemplate")
frame:SetPoint("CENTER")
frame:SetClampedToScreen(true)
frame:SetMovable(true)
frame:EnableMouse(true)
frame:SetFrameStrata("MEDIUM")
frame:Hide()

frame:SetBackdrop({
    bgFile = "Interface/Tooltips/UI-Tooltip-Background",
    edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
    tile = true,
    tileSize = 16,
    edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
})
frame:SetBackdropColor(0, 0, 0, 0.85)
frame:SetBackdropBorderColor(0.8, 0.8, 0.8, 0.9)

local function RestoreFramePosition()
    local p = FarmCounterDB.frame
    if type(p) ~= "table" then
        return
    end

    local point = p.point
    local relPoint = p.relativePoint
    local x = tonumber(p.x)
    local y = tonumber(p.y)

    if point and relPoint and x and y then
        frame:ClearAllPoints()
        frame:SetPoint(point, UIParent, relPoint, x, y)
    end
end

local function SaveFramePosition()
    local point, _, relPoint, x, y = frame:GetPoint(1)
    FarmCounterDB.frame = FarmCounterDB.frame or {}
    FarmCounterDB.frame.point = point
    FarmCounterDB.frame.relativePoint = relPoint
    FarmCounterDB.frame.x = x
    FarmCounterDB.frame.y = y
end

-- Drag bar (so you can drag by the title area)
local dragBar = CreateFrame("Frame", nil, frame)
dragBar:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
dragBar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
dragBar:SetHeight(24)
dragBar:EnableMouse(true)
dragBar:RegisterForDrag("LeftButton")
dragBar:SetScript("OnDragStart", function() frame:StartMoving() end)
dragBar:SetScript("OnDragStop", function()
    frame:StopMovingOrSizing()
    SaveFramePosition()
end)

local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
title:SetPoint("CENTER", dragBar, "CENTER", 0, 0)
title:SetText("Farm Counter")

-- Close button (top right): same as /farmcounter hide, the window stays hidden until /farmcounter show.
local closeButton = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
closeButton:SetSize(20, 20)
closeButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -2, -2)
closeButton:SetFrameLevel(dragBar:GetFrameLevel() + 2)
closeButton:SetScript("OnClick", function()
    FarmCounterDB.settings.hidden = true
    frame:Hide()
    Print("Window hidden. Use /farmcounter show to show it again; data keeps tracking in the background.")
end)

-- View dropdown (top left): current session, previous sessions, history.
-- Works like the segment selector of a damage meter.
local viewButton = CreateFrame("Button", nil, frame)
viewButton:SetPoint("LEFT", dragBar, "LEFT", 8, 0)
viewButton:SetHeight(18)
viewButton:SetFrameLevel(dragBar:GetFrameLevel() + 2)

local viewButtonText = viewButton:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
viewButtonText:SetPoint("LEFT", viewButton, "LEFT", 0, 0)

local viewButtonArrow = viewButton:CreateTexture(nil, "OVERLAY")
viewButtonArrow:SetSize(12, 12)
viewButtonArrow:SetPoint("LEFT", viewButtonText, "RIGHT", 2, -1)
viewButtonArrow:SetTexture("Interface\\Buttons\\Arrow-Down-Up")

viewButton:SetScript("OnEnter", function()
    viewButtonText:SetTextColor(1, 1, 1)
end)
viewButton:SetScript("OnLeave", function()
    viewButtonText:SetTextColor(1, 0.82, 0)
end)

local function GetViewLabel()
    if (FarmCounterDB.settings.mode or "session") == "history" then
        return "History"
    end
    if viewedSession then
        for i, session in ipairs(FarmCounterDB.sessionHistory) do
            if session == viewedSession then
                return "Previous #" .. i
            end
        end
    end
    return "Current"
end

local function UpdateViewButton()
    viewButtonText:SetText(GetViewLabel())
    viewButton:SetWidth(viewButtonText:GetStringWidth() + 16)
end

-- Layout constants
local LEFT_PAD = 12
local TOP_OFFSET = -32
local ROW_GAP = 4
local FOOTER_GAP = 6
local FOOTER_LINES = 3

local ITEM_COL_X = LEFT_PAD
local ITEM_COL_WIDTH = 160

local CHANCE_COL_X = ITEM_COL_X + ITEM_COL_WIDTH + 12
local CHANCE_COL_WIDTH = 70

local TOTAL_COL_X = CHANCE_COL_X + CHANCE_COL_WIDTH + 12
local TOTAL_COL_WIDTH = 50

local VALUE_COL_X = TOTAL_COL_X + TOTAL_COL_WIDTH + 12
local VALUE_COL_WIDTH = 90

local FRAME_WIDTH = VALUE_COL_X + VALUE_COL_WIDTH + LEFT_PAD

local CATEGORY_COLOR = "ffffd100"
local NO_PRICE_TEXT = "|cff808080--|r"

-- Column Titles
local itemColumnTitle = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
itemColumnTitle:SetPoint("TOPLEFT", frame, "TOPLEFT", ITEM_COL_X, TOP_OFFSET)
itemColumnTitle:SetText("Item")

local chanceColumnTitle = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
chanceColumnTitle:SetPoint("TOPLEFT", frame, "TOPLEFT", CHANCE_COL_X, TOP_OFFSET)
chanceColumnTitle:SetText("Chance")

local totalColumnTitle = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
totalColumnTitle:SetPoint("TOPLEFT", frame, "TOPLEFT", TOTAL_COL_X, TOP_OFFSET)
totalColumnTitle:SetText("Total")

local valueColumnTitle = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
valueColumnTitle:SetPoint("TOPLEFT", frame, "TOPLEFT", VALUE_COL_X, TOP_OFFSET)
valueColumnTitle:SetWidth(VALUE_COL_WIDTH)
valueColumnTitle:SetJustifyH("RIGHT")
valueColumnTitle:SetText("Value")

-- Columns (data)
local itemColumn = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
itemColumn:SetJustifyH("LEFT")
itemColumn:SetJustifyV("TOP")
itemColumn:SetPoint("TOPLEFT", itemColumnTitle, "BOTTOMLEFT", 0, -ROW_GAP)
itemColumn:SetWidth(ITEM_COL_WIDTH)
-- Allow multi-line text; we truncate long names ourselves.
itemColumn:SetWordWrap(true)

local chanceColumn = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
chanceColumn:SetJustifyH("CENTER")
chanceColumn:SetJustifyV("TOP")
chanceColumn:SetPoint("TOPLEFT", chanceColumnTitle, "BOTTOMLEFT", 0, -ROW_GAP)
chanceColumn:SetWidth(CHANCE_COL_WIDTH)
chanceColumn:SetWordWrap(true)

local totalColumn = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
totalColumn:SetJustifyH("RIGHT")
totalColumn:SetJustifyV("TOP")
totalColumn:SetPoint("TOPLEFT", totalColumnTitle, "BOTTOMLEFT", 0, -ROW_GAP)
totalColumn:SetWidth(TOTAL_COL_WIDTH)
totalColumn:SetWordWrap(true)

local valueColumn = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
valueColumn:SetJustifyH("RIGHT")
valueColumn:SetJustifyV("TOP")
valueColumn:SetPoint("TOPLEFT", valueColumnTitle, "BOTTOMLEFT", 0, -ROW_GAP)
valueColumn:SetWidth(VALUE_COL_WIDTH)
valueColumn:SetWordWrap(true)

-- Footer: total value, session status, price source
local footerText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
footerText:SetJustifyH("LEFT")
footerText:SetJustifyV("TOP")
footerText:SetPoint("TOPLEFT", itemColumn, "BOTTOMLEFT", 0, -FOOTER_GAP)
footerText:SetWidth(FRAME_WIDTH - (2 * LEFT_PAD))
footerText:SetWordWrap(false)

local measuringFont = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
measuringFont:Hide()

local MAX_ITEM_NAME_WIDTH = ITEM_COL_WIDTH

local function TruncateText(text, maxWidth)
    if type(text) ~= "string" then
        return ""
    end
    maxWidth = maxWidth or MAX_ITEM_NAME_WIDTH

    measuringFont:SetText(text)
    if measuringFont:GetStringWidth() <= maxWidth then
        return text
    end

    local truncated = text
    while #truncated > 0 do
        truncated = string.sub(truncated, 1, #truncated - 1)
        measuringFont:SetText(truncated .. "...")
        if measuringFont:GetStringWidth() <= maxWidth then
            return truncated .. "..."
        end
    end

    return text
end

local function GetLineHeight()
    -- MeasuringFont uses the same font object; this gives a stable per-row height.
    measuringFont:SetText("A")
    local h = measuringFont:GetStringHeight()
    if not h or h <= 0 then
        return 12
    end
    return h
end

-- Quality tier icons come from the loot link as "|A:<atlas>:17:15::1|a". That is taller than a row
-- and would push the item column out of line with the other columns, so draw them at row height.
local function GetTierMarkup(tier)
    local atlas = type(tier) == "string" and tier:match("|A:([^:|]+)")
    if not atlas then
        return ""
    end
    local size = math.floor(GetLineHeight())
    return string.format(" |A:%s:%d:%d|a", atlas, size, size)
end

local function SetFrameSizeToRows(numRows)
    frame:SetWidth(FRAME_WIDTH)

    local rows = tonumber(numRows) or 1
    if rows < 1 then
        rows = 1
    end

    local lineHeight = GetLineHeight()
    local contentHeight = (rows * lineHeight)
    local footerHeight = FOOTER_LINES * lineHeight

    -- Explicitly set fontstring heights so extra lines aren't clipped.
    itemColumn:SetHeight(contentHeight)
    chanceColumn:SetHeight(contentHeight)
    totalColumn:SetHeight(contentHeight)
    valueColumn:SetHeight(contentHeight)
    footerText:SetHeight(footerHeight)

    local baseHeight =
        24 -- drag bar
        + 8 -- spacing under drag bar/title
        + 12 -- column title height-ish
        + ROW_GAP
        + FOOTER_GAP
        + 12 -- bottom padding

    frame:SetHeight(baseHeight + contentHeight + footerHeight)
end

local function GetActiveData()
    local mode = FarmCounterDB.settings.mode or "session"

    UpdateViewButton()

    if mode == "history" then
        title:SetText("Farm Counter (History)")
        return FarmCounterDB.historyData, FarmCounterDB.historyOrder
    end

    local session = viewedSession or GetSession()
    local zone = session.zone or GetCurrentZoneName()
    title:SetText("Farm Counter (" .. zone .. ")")
    return session.data, session.order
end

-- Name-keyed entries have no itemID. Try once per login to resolve it from the name so they get
-- a price and a proper category; on the next loot of the item AddCatch replaces them anyway.
local legacyResolveTried = {}

local function ResolveLegacyEntry(itemKey, entry)
    entry.name = entry.name or itemKey
    if entry.itemID or legacyResolveTried[itemKey] then
        return
    end
    legacyResolveTried[itemKey] = true

    local itemID, _, _, _, _, classID, subclassID = GetItemInfoInstantCompat(entry.name or itemKey)
    if itemID then
        entry.itemID = itemID
        entry.itemString = "i:" .. itemID
        entry.category = ClassifyItem(itemID, classID, subclassID, true) or entry.category or "fishing"
    end
end

local lastTotalValue = 0
local lastMissingPrices = 0

local function UpdateFooter()
    local mode = FarmCounterDB.settings.mode or "session"
    local session = viewedSession or GetSession()
    local lines = {}

    local valueLine = "Total value: |cffffffff" .. FormatMoney(lastTotalValue) .. "|r"
    if mode == "session" then
        local duration = GetSessionDuration(session)
        if duration >= 60 and lastTotalValue > 0 then
            valueLine = valueLine .. "  (" .. FormatMoney(lastTotalValue / (duration / 3600)) .. "/h)"
        end
    end
    if lastMissingPrices > 0 then
        valueLine = valueLine .. string.format("  |cff808080%d without price|r", lastMissingPrices)
    end
    table.insert(lines, valueLine)

    if mode == "session" then
        local stateText
        if session.state == "running" then
            stateText = "|cff33ff99Running|r"
        elseif session.state == "stopped" then
            stateText = "|cffff5555Stopped|r"
        elseif session.state == "archived" then
            stateText = "|cff808080Previous|r " .. date("%d.%m. %H:%M", session.startTime or time())
        else
            stateText = "Auto"
        end
        table.insert(lines, "Session: " .. stateText .. " " .. FormatDuration(GetSessionDuration(session)))
    else
        table.insert(lines, "History: all sessions")
    end

    local source = FarmCounterDB.settings.priceSource or DEFAULT_PRICE_SOURCE
    if not IsTSMAvailable() then
        table.insert(lines, "|cff808080Prices: TSM not loaded|r")
    elseif lastPriceError then
        table.insert(lines, "|cffff5555Prices: " .. source .. " - error, see chat|r")
    else
        table.insert(lines, "|cff808080Prices: TSM " .. source .. "|r")
    end

    footerText:SetText(table.concat(lines, "\n"))
end

-- Auto hide: time of the last counted loot or explicit show, and whether the window was
-- hidden by the timer (as opposed to the user closing it, which sets settings.hidden).
local lastActivityTime = 0
local autoHidden = false

-- forceShow:
--   true  -> show window even if there are no catches yet (used for /farmcounter show, /farmcounter history, etc)
--   false -> only show automatically when there is data to show and the user has not hidden it
local function UpdateDisplay(forceShow)
    local data, order = GetActiveData()

    -- Group the visible entries by category.
    local groups = {}
    local totalCount = 0
    if type(order) == "table" then
        for _, itemKey in ipairs(order) do
            local entry = data[itemKey]
            if type(entry) == "table" and type(entry.count) == "number" then
                ResolveLegacyEntry(itemKey, entry)
                local category = entry.category or "fishing"
                if IsCategoryEnabled(category) then
                    groups[category] = groups[category] or {}
                    table.insert(groups[category], entry)
                    totalCount = totalCount + entry.count
                end
            end
        end
    end

    local items, chances, totals, values = {}, {}, {}, {}
    local totalValue = 0
    local missingPrices = 0

    for _, category in ipairs(CATEGORY_ORDER) do
        local entries = groups[category]
        if entries then
            -- Category header row; its count/value are filled in after the items.
            table.insert(items, string.format("|c%s%s|r", CATEGORY_COLOR, CATEGORY_LABELS[category] or category))
            table.insert(chances, " ")
            table.insert(totals, "")
            table.insert(values, "")
            local headerIndex = #items

            local categoryCount = 0
            local categoryValue = 0

            for _, entry in ipairs(entries) do
                if not entry.quality and entry.itemID and C_Item and C_Item.GetItemQualityByID then
                    entry.quality = C_Item.GetItemQualityByID(entry.itemID)
                end

                local pct = (totalCount > 0) and ((entry.count / totalCount) * 100) or 0
                local hex = GetQualityHexColor(entry.quality)
                local tierText = GetTierMarkup(entry.tier)
                local displayName = TruncateText("  " .. (entry.name or "?"), MAX_ITEM_NAME_WIDTH - (tierText ~= "" and 16 or 0))

                local price = GetItemPrice(entry.itemString, entry.itemID)
                local valueText
                if price then
                    local value = price * entry.count
                    categoryValue = categoryValue + value
                    valueText = FormatMoney(value)
                else
                    missingPrices = missingPrices + 1
                    valueText = NO_PRICE_TEXT
                end
                categoryCount = categoryCount + entry.count

                table.insert(items, string.format("|c%s%s|r%s", hex, displayName, tierText))
                table.insert(chances, string.format("%.1f%%", pct))
                table.insert(totals, string.format("%d", entry.count))
                table.insert(values, valueText)
            end

            totals[headerIndex] = string.format("|c%s%d|r", CATEGORY_COLOR, categoryCount)
            values[headerIndex] = FormatMoney(categoryValue)
            totalValue = totalValue + categoryValue
        end
    end

    if #items == 0 then
        itemColumn:SetText("No catches yet.")
        chanceColumn:SetText("")
        totalColumn:SetText("")
        valueColumn:SetText("")
    else
        itemColumn:SetText(table.concat(items, "\n"))
        chanceColumn:SetText(table.concat(chances, "\n"))
        totalColumn:SetText(table.concat(totals, "\n"))
        valueColumn:SetText(table.concat(values, "\n"))
    end

    lastTotalValue = totalValue
    lastMissingPrices = missingPrices
    UpdateFooter()

    SetFrameSizeToRows(math.max(1, #items))

    if FarmCounterDB.settings.hidden then
        frame:Hide()
        return
    end

    if forceShow then
        autoHidden = false
        lastActivityTime = GetTime()
        frame:Show()
        return
    end

    -- Auto hidden: stay hidden until the next counted loot (or an explicit show).
    if autoHidden then
        return
    end

    -- Auto-show only when we actually have something to display.
    if HasAnyCatches(data, order) then
        frame:Show()
    end
end

-- Coalesce bursts of loot messages into a single redraw.
local updatePending = false

local function ScheduleUpdate()
    if updatePending then
        return
    end
    updatePending = true
    C_Timer.After(0.2, function()
        updatePending = false
        UpdateDisplay(false)
    end)
end

local function SelectView(mode, session)
    FarmCounterDB.settings.mode = mode
    viewedSession = session
    FarmCounterDB.settings.hidden = false
    UpdateDisplay(true)
end

local function IsViewSelected(mode, session)
    return (FarmCounterDB.settings.mode or "session") == mode and viewedSession == session
end

viewButton:SetScript("OnClick", function(self)
    local archive = FarmCounterDB.sessionHistory

    if MenuUtil and MenuUtil.CreateContextMenu then
        MenuUtil.CreateContextMenu(self, function(_, rootDescription)
            rootDescription:CreateRadio("Current session",
                function() return IsViewSelected("session", nil) end,
                function() SelectView("session", nil) end)

            if #archive > 0 then
                rootDescription:CreateDivider()
                rootDescription:CreateTitle("Previous sessions")
                for _, session in ipairs(archive) do
                    rootDescription:CreateRadio(GetSessionLabel(session),
                        function() return IsViewSelected("session", session) end,
                        function() SelectView("session", session) end)
                end
            end

            rootDescription:CreateDivider()
            rootDescription:CreateRadio("History (all)",
                function() return IsViewSelected("history", nil) end,
                function() SelectView("history", nil) end)
        end)
        return
    end

    -- Fallback without the menu API: cycle Current -> previous sessions -> History.
    if (FarmCounterDB.settings.mode or "session") == "history" then
        SelectView("session", nil)
        return
    end
    local nextIndex = 1
    for i, session in ipairs(archive) do
        if session == viewedSession then
            nextIndex = i + 1
        end
    end
    if archive[nextIndex] then
        SelectView("session", archive[nextIndex])
    else
        SelectView("history", nil)
    end
end)

-- Every time the window appears, the auto hide timer starts over.
frame:HookScript("OnShow", function()
    lastActivityTime = GetTime()
end)

-- While visible: tick the session timer every second, refresh prices when the cache expires.
local sinceTick, sinceRefresh = 0, 0
frame:SetScript("OnUpdate", function(_, elapsed)
    sinceTick = sinceTick + elapsed
    if sinceTick < 1 then
        return
    end
    sinceRefresh = sinceRefresh + sinceTick
    sinceTick = 0

    local settings = FarmCounterDB.settings
    if settings.autoHide then
        if frame:IsMouseOver() then
            -- Don't hide while you are looking at or using the window.
            lastActivityTime = GetTime()
        elseif (GetTime() - lastActivityTime) >= (settings.autoHideMinutes or DEFAULT_AUTO_HIDE_MINUTES) * 60 then
            autoHidden = true
            frame:Hide()
            return
        end
    end

    local refreshInterval = (lastMissingPrices > 0) and PRICE_RETRY_TTL or PRICE_CACHE_TTL
    if sinceRefresh >= refreshInterval then
        sinceRefresh = 0
        UpdateDisplay(false)
    else
        UpdateFooter()
    end
end)

-- -----------------------------------------------------------------------------
-- Loot Processing
-- -----------------------------------------------------------------------------
-- Loot from a fishing cast is flagged on LOOT_OPENED; the matching CHAT_MSG_LOOT lines
-- arrive while the window is open or shortly after it closes.
local fishingLootUntil = 0

local lootPatterns = nil

-- Turns a GlobalStrings format ("You receive loot: %sx%d.") into a Lua match pattern.
local function FormatToPattern(fmt)
    if type(fmt) ~= "string" or fmt == "" then
        return nil
    end
    fmt = fmt:gsub("%%%d%$", "%%") -- positional args ("%1$s") -> plain ("%s")
    local pattern = fmt:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
    pattern = pattern:gsub("%%%%s", "(.+)")
    pattern = pattern:gsub("%%%%d", "(%%d+)")
    return "^" .. pattern .. "$"
end

local function GetLootPatterns()
    if not lootPatterns then
        lootPatterns = {}
        -- Only items you looted yourself. Purchases, mail, crafting ("You create") and pushed
        -- items ("You receive item") use other strings and are intentionally not matched.
        -- The multiple-items pattern must be tried first.
        for _, fmt in ipairs({ LOOT_ITEM_SELF_MULTIPLE, LOOT_ITEM_SELF }) do
            local pattern = FormatToPattern(fmt)
            if pattern then
                table.insert(lootPatterns, pattern)
            end
        end
    end
    return lootPatterns
end

-- Returns itemLink, amount for "you looted" messages, nil otherwise.
local function ParseLootMessage(msg)
    for _, pattern in ipairs(GetLootPatterns()) do
        local first, second = msg:match(pattern)
        if first then
            local link, amount = first, second
            if second and tonumber(first) and not tonumber(second) then
                link, amount = second, first
            end
            return link, tonumber(amount) or 1
        end
    end
    return nil
end

local function ProcessLootMessage(msg)
    if type(msg) ~= "string" then
        return
    end
    -- Midnight: chat payloads can be secret values (e.g. during encounters); leave them alone.
    if issecretvalue and issecretvalue(msg) then
        return
    end

    local link, amount = ParseLootMessage(msg)
    if not link then
        return
    end

    local wowItemString = link:match("|H(item:[^|]+)|h")
    local itemID = wowItemString and tonumber(wowItemString:match("^item:(%d+)"))
    if not itemID then
        return
    end

    local _, _, _, _, _, classID, subclassID = GetItemInfoInstantCompat(wowItemString)
    local isFishing = GetTime() <= fishingLootUntil
    local category = ClassifyItem(itemID, classID, subclassID, isFishing)
    if not category or not IsCategoryEnabled(category) then
        return
    end

    -- Reagent quality tiers are part of the link text as an atlas ("|A:...|a").
    local rawName = link:match("|h%[(.-)%]|h") or ""
    local tier = rawName:match("(|A.-|a)")
    local name = rawName:gsub("%s*|A.-|a", "")
    if name == "" then
        name = (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(itemID)) or ("item:" .. itemID)
    end

    local quality = tonumber(link:match("|cnIQ(%d+):"))
    if not quality and C_Item and C_Item.GetItemQualityByID then
        quality = C_Item.GetItemQualityByID(itemID)
    end

    local itemInfo = {
        name = name,
        quality = quality,
        itemID = itemID,
        itemString = ToItemStringCompat(link, itemID),
        category = category,
        tier = tier,
    }
    local itemKey = "i:" .. itemID

    local session = GetSession()
    local currentZone = GetCurrentZoneName()

    -- Auto sessions reset when you loot in a new zone.
    if session.state == "auto" and FarmCounterDB.settings.zoneReset
        and session.zone and session.zone ~= currentZone then
        ReplaceSession("auto")
        session = FarmCounterDB.session
    end

    if session.state ~= "stopped" then
        session.zone = currentZone
        session.lastLootTime = time()
        AddCatch(session.data, session.order, itemKey, itemInfo, amount)
    end
    AddCatch(FarmCounterDB.historyData, FarmCounterDB.historyOrder, itemKey, itemInfo, amount)

    if type(quality) == "number" and quality >= 3 then
        PlayRareLootSound(quality)
    end

    -- Counted loot brings an auto hidden window back and restarts the auto hide timer.
    autoHidden = false
    lastActivityTime = GetTime()

    ScheduleUpdate()
end

-- -----------------------------------------------------------------------------
-- Options (Game Menu > Options > AddOns > Farm Counter)
-- -----------------------------------------------------------------------------
-- Price sources offered in the dropdown; any other TSM custom price can be set via /farmcounter price.
local PRICE_SOURCE_OPTIONS = {
    { "DBMarket", "AuctionDB - Market Value" },
    { "DBMinBuyout", "AuctionDB - Minimum Buyout" },
    { "DBRecent", "AuctionDB - Recent Value" },
    { "DBHistorical", "AuctionDB - Historical Price" },
    { "DBRegionMarketAvg", "AuctionDB - Region Market Value Average" },
    { "DBRegionSaleAvg", "AuctionDB - Region Sale Average" },
    { "DBRegionHistorical", "AuctionDB - Region Historical Price" },
}

local settingsCategory = nil

local function AddSectionHeader(layout, text)
    if layout and CreateSettingsListSectionHeaderInitializer then
        layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(text))
    end
end

local function AddCheckbox(category, variableTbl, key, name, tooltip, defaultValue, onChanged)
    local setting = Settings.RegisterAddOnSetting(category,
        "FarmCounter_" .. key, -- unique name
        key, -- key in variableTbl
        variableTbl,
        Settings.VarType.Boolean,
        name,
        defaultValue)
    Settings.CreateCheckbox(category, setting, tooltip)
    if onChanged then
        setting:SetValueChangedCallback(onChanged)
    end
    return setting
end

local function CreateSettings()
    if not Settings or not Settings.RegisterVerticalLayoutCategory then
        return
    end

    local settings = FarmCounterDB.settings
    local category, layout = Settings.RegisterVerticalLayoutCategory("Farm Counter")

    local function Redraw()
        UpdateDisplay(false)
    end

    AddSectionHeader(layout, "Sound")
    AddCheckbox(category, settings, "playRareSound", "Play a sound for rare loot",
        "Plays an alert when you loot a rare (blue) or epic (purple) item.", true)
    AddCheckbox(category, settings, "playBlueSound", "Also for rare (blue) items",
        "When disabled, only epic (purple) and better items play a sound.", true)

    AddSectionHeader(layout, "Counting")
    AddCheckbox(category, settings, "countAllFishingLoot", "Count all fishing loot",
        "Also counts junk, treasures and other non-profession items from fishing casts.", true)
    AddCheckbox(category, settings, "zoneReset", "New auto session in a new zone",
        "Sessions without /farmcounter start end when you loot in a different zone. The old session stays available in the session dropdown.", true)

    AddSectionHeader(layout, "Prices")
    local CreateDropdown = Settings.CreateDropdown or Settings.CreateDropDown
    if CreateDropdown and Settings.CreateControlTextContainer then
        local priceSetting = Settings.RegisterAddOnSetting(category,
            "FarmCounter_priceSource",
            "priceSource",
            settings,
            Settings.VarType.String,
            "Price source",
            DEFAULT_PRICE_SOURCE)
        local function GetPriceSourceOptions()
            local container = Settings.CreateControlTextContainer()
            local current = settings.priceSource
            local isListed = false
            for _, option in ipairs(PRICE_SOURCE_OPTIONS) do
                container:Add(option[1], option[2])
                isListed = isListed or option[1] == current
            end
            if current and not isListed then
                container:Add(current, "Custom: " .. current)
            end
            return container:GetData()
        end
        CreateDropdown(category, priceSetting, GetPriceSourceOptions,
            "TradeSkillMaster price used for the values. Other TSM custom prices can be set with /farmcounter price <custom price>.")
        priceSetting:SetValueChangedCallback(function()
            ClearPriceCache()
            Redraw()
        end)
    end

    AddSectionHeader(layout, "Categories")
    for _, key in ipairs(CATEGORY_ORDER) do
        local setting = Settings.RegisterAddOnSetting(category,
            "FarmCounter_Category_" .. key,
            key,
            settings.categories,
            Settings.VarType.Boolean,
            CATEGORY_LABELS[key],
            true)
        Settings.CreateCheckbox(category, setting, "Count and show " .. CATEGORY_LABELS[key] .. ".")
        setting:SetValueChangedCallback(Redraw)
    end

    AddSectionHeader(layout, "Window")
    AddCheckbox(category, settings, "autoHide", "Auto hide",
        "Hides the window when nothing was counted for a while. It shows up again as soon as you loot something that is counted.", false,
        function()
            if not settings.autoHide and autoHidden then
                autoHidden = false
                UpdateDisplay(false)
            end
        end)
    if Settings.CreateSlider and Settings.CreateSliderOptions then
        local delaySetting = Settings.RegisterAddOnSetting(category,
            "FarmCounter_autoHideMinutes",
            "autoHideMinutes",
            settings,
            Settings.VarType.Number,
            "Auto hide after (minutes)",
            DEFAULT_AUTO_HIDE_MINUTES)
        local delayOptions = Settings.CreateSliderOptions(1, 30, 1)
        if MinimalSliderWithSteppersMixin then
            delayOptions:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right)
        end
        Settings.CreateSlider(category, delaySetting, delayOptions,
            "Minutes without counted loot before the window hides (only with \"Auto hide\" enabled). Hovering the window with the mouse restarts the timer.")
    end

    if layout and CreateSettingsButtonInitializer then
        layout:AddInitializer(CreateSettingsButtonInitializer("Window", "Show window", function()
            settings.hidden = false
            UpdateDisplay(true)
        end, "Shows the Farm Counter window again after closing it.", true))
    end

    Settings.RegisterAddOnCategory(category)
    settingsCategory = category
end

local function OpenOptions()
    if settingsCategory and Settings and Settings.OpenToCategory then
        Settings.OpenToCategory(settingsCategory:GetID())
    end
end

-- -----------------------------------------------------------------------------
-- Slash Commands
-- -----------------------------------------------------------------------------
SLASH_FARMCOUNTER1 = "/farmcounter"
SLASH_FARMCOUNTER2 = "/farm"

local function ParseOnOff(arg, current)
    if arg == "" then
        return not current
    elseif arg == "on" then
        return true
    elseif arg == "off" then
        return false
    end
    return nil
end

SlashCmdList.FARMCOUNTER = function(msg)
    -- Should already exist after ADDON_LOADED, but keep this robust in case the user
    -- runs slash commands very early or saved variables were partially wiped.
    if not FarmCounterDB or not FarmCounterDB.settings then
        ApplyDefaults()
    end

    msg = msg or ""
    local input = string.lower(msg):match("^%s*(.-)%s*$")
    local cmd, arg = input:match("^(%S+)%s*(.-)$")
    cmd = cmd or ""
    arg = arg or ""
    -- Case-preserving argument (price sources)
    local rawArg = msg:match("^%s*%S+%s*(.-)%s*$") or ""

    if cmd == "" or cmd == "help" or cmd == "?" then
        Print("--- Farm Counter ---")
        Print("/farmcounter show - Shows the addon window.")
        Print("/farmcounter session - Switch to Session Mode.")
        Print("/farmcounter history - Switch to History Mode (global).")
        Print("/farmcounter start - Starts a new farming session (no zone auto-reset).")
        Print("/farmcounter stop - Ends the current session (history keeps counting).")
        Print("/farmcounter reset - Resets the current session data.")
        Print("/farmcounter view [current|history|1-" .. MAX_ARCHIVED_SESSIONS .. "] - Lists or shows previous sessions (also via the dropdown).")
        Print("/farmcounter price [source|default] - Shows or sets the TSM price source (default: " .. DEFAULT_PRICE_SOURCE .. ").")
        Print("/farmcounter cat [key] [on|off] - Lists or toggles counted categories.")
        Print("/farmcounter fishing [on|off] - Count all fishing loot, incl. junk (default on).")
        Print("/farmcounter zonereset [on|off] - Auto sessions reset in a new zone (default on).")
        Print("/farmcounter sound [on|off] - Toggles sound alerts (or sets explicitly).")
        Print("/farmcounter sound blue [on|off] - Sound for rare (blue) items (epic always plays).")
        Print("/farmcounter options - Opens the options.")
        Print("/farmcounter hide (or /farmcounter exit) - Hides the addon window.")
        return
    end

    if cmd == "show" then
        FarmCounterDB.settings.hidden = false
        UpdateDisplay(true)
        return
    end

    if cmd == "hide" or cmd == "exit" then
        FarmCounterDB.settings.hidden = true
        frame:Hide()
        Print("Hiding window. Data will continue tracking in the background.")
        return
    end

    if cmd == "session" then
        SelectView("session", nil)
        return
    end

    if cmd == "history" then
        SelectView("history", nil)
        return
    end

    if cmd == "view" then
        local archive = FarmCounterDB.sessionHistory
        local index = tonumber(arg)
        if arg == "" then
            Print("Current session: " .. GetSessionLabel(GetSession()))
            for i, session in ipairs(archive) do
                Print(string.format("%d: %s", i, GetSessionLabel(session)))
            end
            return
        end
        if arg == "current" then
            SelectView("session", nil)
        elseif arg == "history" then
            SelectView("history", nil)
        elseif index and archive[index] then
            SelectView("session", archive[index])
        else
            Print("Usage: /farmcounter view [current|history|1-" .. MAX_ARCHIVED_SESSIONS .. "]")
        end
        return
    end

    if cmd == "start" then
        ReplaceSession("running")
        FarmCounterDB.session.zone = GetCurrentZoneName()
        Print("Session started.")
        SelectView("session", nil)
        return
    end

    if cmd == "stop" then
        local session = GetSession()
        if session.state == "stopped" then
            Print("No session running. Use /farmcounter start to start one.")
            return
        end
        session.state = "stopped"
        session.endTime = time()
        Print("Session stopped after " .. FormatDuration(GetSessionDuration(session)) .. ". Loot still counts into History.")
        UpdateDisplay(false)
        return
    end

    if cmd == "reset" then
        local state = GetSession().state
        ReplaceSession(state == "running" and "running" or "auto")
        FarmCounterDB.session.zone = GetCurrentZoneName()
        viewedSession = nil
        Print("Session reset. The previous one is in the session dropdown.")
        if (FarmCounterDB.settings.mode or "session") == "session" then
            FarmCounterDB.settings.hidden = false
            UpdateDisplay(true)
        end
        return
    end

    if cmd == "price" then
        if rawArg == "" then
            Print("Price source: " .. FarmCounterDB.settings.priceSource
                .. (IsTSMAvailable() and "" or " (TSM not loaded)"))
            return
        end

        local source = (arg == "default") and DEFAULT_PRICE_SOURCE or rawArg
        if IsTSMAvailable() and type(TSM_API.IsCustomPriceValid) == "function" then
            local ok, isValid, err = pcall(TSM_API.IsCustomPriceValid, source)
            if not ok then
                Print("|cffff5555TSM error|r while validating \"" .. source .. "\": " .. tostring(isValid))
                return
            end
            if not isValid then
                Print("|cffff5555Invalid price source|r \"" .. source .. "\": " .. tostring(err))
                return
            end
        else
            Print("TSM not loaded - price source saved without validation.")
        end

        FarmCounterDB.settings.priceSource = source
        ClearPriceCache()
        Print("Price source: " .. source)
        UpdateDisplay(false)
        return
    end

    if cmd == "cat" or cmd == "category" then
        local key, state = arg:match("^(%S*)%s*(.-)$")
        if not key or key == "" then
            for _, category in ipairs(CATEGORY_ORDER) do
                Print(string.format("%s (%s): %s", category, CATEGORY_LABELS[category],
                    IsCategoryEnabled(category) and "ON" or "OFF"))
            end
            return
        end
        if not CATEGORY_LABELS[key] then
            Print("Unknown category \"" .. key .. "\". Type /farmcounter cat for a list.")
            return
        end
        local enabled = ParseOnOff(state, IsCategoryEnabled(key))
        if enabled == nil then
            Print("Usage: /farmcounter cat <key> [on|off]")
            return
        end
        FarmCounterDB.settings.categories[key] = enabled
        Print(CATEGORY_LABELS[key] .. ": " .. (enabled and "ON" or "OFF"))
        UpdateDisplay(false)
        return
    end

    if cmd == "fishing" then
        local enabled = ParseOnOff(arg, FarmCounterDB.settings.countAllFishingLoot)
        if enabled == nil then
            Print("Usage: /farmcounter fishing [on|off]")
            return
        end
        FarmCounterDB.settings.countAllFishingLoot = enabled
        Print("Count all fishing loot: " .. (enabled and "ON" or "OFF"))
        return
    end

    if cmd == "zonereset" then
        local enabled = ParseOnOff(arg, FarmCounterDB.settings.zoneReset)
        if enabled == nil then
            Print("Usage: /farmcounter zonereset [on|off]")
            return
        end
        FarmCounterDB.settings.zoneReset = enabled
        Print("Auto session zone reset: " .. (enabled and "ON" or "OFF"))
        return
    end

    if cmd == "sound" then
        local blueArg = arg:match("^blue%s*(.-)$")
        if blueArg then
            local enabled = ParseOnOff(blueArg, FarmCounterDB.settings.playBlueSound)
            if enabled == nil then
                Print("Usage: /farmcounter sound blue [on|off]")
                return
            end
            FarmCounterDB.settings.playBlueSound = enabled
            Print("Sound for rare (blue) items: " .. (enabled and "ON" or "OFF"))
            return
        end

        local enabled = ParseOnOff(arg, FarmCounterDB.settings.playRareSound)
        if enabled == nil then
            Print("Usage: /farmcounter sound [on|off] or /farmcounter sound blue [on|off]")
            return
        end
        FarmCounterDB.settings.playRareSound = enabled

        Print("Sound alerts: " .. (FarmCounterDB.settings.playRareSound and "ON" or "OFF"))
        return
    end

    if cmd == "options" or cmd == "config" then
        OpenOptions()
        return
    end

    Print("Unknown command. Type /farmcounter for help.")
end

-- -----------------------------------------------------------------------------
-- Event Wiring
-- -----------------------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("LOOT_OPENED")
eventFrame:RegisterEvent("LOOT_CLOSED")
eventFrame:RegisterEvent("CHAT_MSG_LOOT")

eventFrame:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        local loadedAddonName = ...
        if loadedAddonName ~= addonName then
            return
        end

        ApplyDefaults()
        FarmCounterDB.dbVersion = DB_VERSION
        FarmCounterDB.version = ADDON_VERSION

        -- Auto sessions survive a /reload but end after 30 minutes without loot; the old one goes
        -- to the session dropdown. Started (/farmcounter start) and stopped sessions always survive.
        local session = FarmCounterDB.session
        if session.state == "auto"
            and (time() - (session.lastLootTime or session.startTime or 0)) > AUTO_SESSION_IDLE_TIMEOUT then
            ReplaceSession("auto")
        end

        RestoreFramePosition()
        CreateSettings()

        -- Do not force-show at login; auto-show only when there is data to display.
        UpdateDisplay(false)
        return
    end

    if event == "PLAYER_LOGIN" then
        -- TSM loads its AuctionDB prices on PLAYER_LOGIN, after our first draw; drop the
        -- empty prices looked up until then and redraw once its data is there.
        C_Timer.After(2, function()
            ClearPriceCache()
            UpdateDisplay(false)
        end)
        return
    end

    if event == "CHAT_MSG_LOOT" then
        local msg = ...
        ProcessLootMessage(msg)
        return
    end

    if event == "LOOT_OPENED" then
        local isFishing = false

        if IsFishingLoot then
            isFishing = IsFishingLoot()
        elseif C_Loot and C_Loot.IsFishingLoot then
            isFishing = C_Loot.IsFishingLoot()
        end

        fishingLootUntil = isFishing and (GetTime() + 10) or 0
        return
    end

    if event == "LOOT_CLOSED" then
        -- Allow late loot messages of a fishing loot window to still count as fishing.
        if fishingLootUntil > 0 then
            fishingLootUntil = math.min(fishingLootUntil, GetTime() + 1)
        end
        return
    end
end)
