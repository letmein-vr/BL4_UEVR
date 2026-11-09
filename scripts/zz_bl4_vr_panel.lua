-- Builds the single "Borderlands 4" panel in the UEVR overlay (same pattern as Hellraiser's zz_hellraiser_vr_panel.lua).
--
-- Every BL4 script registers its settings as a section in _G.BL4_SECTIONS ({ order, label, layout }) instead of creating
-- its own panel; this file loads LAST (UEVR loads scripts in case-insensitive name order, hence zz_) and turns the
-- sections into one panel. Widget ids are global in configui, so the owning scripts use configui.getValue / onUpdate /
-- setLabel directly. Values are saved together in data/bl4_config.json (the file the panel used before, so saved
-- settings carry over). configui.getValue returns nil until this panel exists, so readers treat nil as the initial value.

local configui = require('libs/configui')

local PANEL_LABEL = "Borderlands 4"
local SAVE_FILE   = "bl4_config"

local sections = _G.BL4_SECTIONS or {}
table.sort(sections, function(a, b) return (a.order or 99) < (b.order or 99) end)

-- Main panel vs "Dev Config": keyed by section label, true = the whole section is dev; a list = the widget ids that stay
-- in the main section (everything else of that section goes to its node under Dev Config).
-- Menu layout per xaero 2026-11-09: General keeps roomscale, aim method and the X/B swap; PiP Scope and Vehicles are dev.
local DEV_RULES = {
    ["General"]           = { "bl4_roomscale", "bl4_gameplay_aim", "bl4_swap_xb" },
    ["Weapon Spawner"]    = true,
    ["PiP Scope"]         = true,
    ["Vehicles"]          = true,
    ["Hands"]             = { "bl4_hands_mode", "bl4_hands_mode_status" },
    ["Two-Handed Aiming"] = { "bl4_th_enabled", "bl4_th_grab_button" },
    ["Recoil"]            = { "bl4_recoil_enabled", "bl4_recoil_strength_loc", "bl4_recoil_strength_rot", "bl4_recoil_two_handed" },
}

-- sections whose main part is shown without a collapsible header, together at the top of the panel
local FLAT_SECTIONS = {
    ["General"]           = true,
    ["Hands"]             = true,
    ["Two-Handed Aiming"] = true,
    ["Recoil"]            = true,
    ["Grapple"]           = true,
}

-- order of the flat items at the top of the panel (xaero 2026-11-09); items not listed follow in section order
local FLAT_ORDER = {
    "bl4_hands_mode", "bl4_hands_mode_status",
    "bl4_roomscale",
    "bl4_gameplay_aim",
    "bl4_swap_xb",
    "bl4_th_enabled", "bl4_th_grab_button",
    "bl4_grapple_hand_aim",
    "bl4_recoil_enabled", "bl4_recoil_strength_loc", "bl4_recoil_strength_rot",
    "bl4_recoil_two_handed",
}

local function sortFlat(items)
    local rank = {}
    for i, id in ipairs(FLAT_ORDER) do rank[id] = i end
    local keyed = {}
    for i, item in ipairs(items) do
        keyed[i] = { item = item, key = (item.id ~= nil and rank[item.id]) or (#FLAT_ORDER + i) }
    end
    table.sort(keyed, function(a, b) return a.key < b.key end)
    for i, k in ipairs(keyed) do items[i] = k.item end
end

local function splitSection(section)
    local rule = DEV_RULES[section.label]
    local items = section.layout or {}
    if rule == nil then return items, {} end
    if rule == true then return {}, items end
    local keep = {}
    for _, id in ipairs(rule) do keep[id] = true end
    local main, dev = {}, {}
    for _, item in ipairs(items) do
        table.insert((item.id ~= nil and keep[item.id]) and main or dev, item)
    end
    return main, dev
end

local function addNode(target, id, label, items, open)
    table.insert(target, { widgetType = "tree_node", id = id, label = label, initialOpen = open })
    for _, item in ipairs(items) do table.insert(target, item) end
    table.insert(target, { widgetType = "spacing" })
    table.insert(target, { widgetType = "tree_pop" })
end

local layout, devLayout, flatLayout = {}, {}, {}
if #sections == 0 then
    table.insert(layout, { widgetType = "text", label = "No sections registered (scripts/*.lua load order?)" })
end
local mainCount = 0
for i, section in ipairs(sections) do
    local label = section.label or ("Section " .. i)
    local main, dev = splitSection(section)
    if #main > 0 and FLAT_SECTIONS[label] then
        for _, item in ipairs(main) do table.insert(flatLayout, item) end
    elseif #main > 0 then
        mainCount = mainCount + 1
        addNode(layout, "bl4_section_" .. i, label, main, mainCount == 1)
    end
    if #dev > 0 then addNode(devLayout, "bl4_dev_section_" .. i, label, dev, false) end
end
if #flatLayout > 0 then
    sortFlat(flatLayout)
    table.insert(flatLayout, { widgetType = "spacing" })
    for i = #flatLayout, 1, -1 do table.insert(layout, 1, flatLayout[i]) end
end
-- the dev tuning only while _G.BL4_DEV_CONFIG is on (bl4_main.lua sets it; separate from uevrlib developer mode)
if #devLayout > 0 and _G.BL4_DEV_CONFIG == true then
    table.insert(layout, { widgetType = "tree_node", id = "bl4_dev_config", label = "Dev Config", initialOpen = false })
    for _, item in ipairs(devLayout) do table.insert(layout, item) end
    table.insert(layout, { widgetType = "tree_pop" })
end

configui.create({
    {
        panelLabel = PANEL_LABEL,
        saveFile = SAVE_FILE,
        layout = layout,
    }
})

print("[bl4 panel] '" .. PANEL_LABEL .. "' built with " .. #sections .. " sections")
