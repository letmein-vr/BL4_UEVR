-- Full-screen effects (repkit heal vignette + edge flames, dash, double jump, glide, speed, swimming, burning, map
-- boundary, phase grapple) only drew in the LEFT eye (xaero 2026-11-09). They are Niagara systems named *ScreenEffect*
-- (/Game/Common/Effects/Systems/ScreenEffects/...). Their emitters are GPU-simulated sprites placed by the Camera data
-- interface (MCP 2026-11-09: RepKit_Base HealingVignette / EdgeFlames). Niagara runs a GPU simulation once per frame
-- with the first view's camera - in VR the left eye - so the sprites are built a few cm in front of the left eye and
-- the right eye looks past them. Lua cannot make a GPU sim follow both eyes (SpritePlane-style view-axis edits change
-- the facing, not the position), so, with option bl4_hide_screen_fx (General, default on), they are not drawn in the
-- main pass. Only the drawing changes: the component lives, simulates and finishes on the game's own schedule.
-- The repkit's three are spawned in the world (owner = the persistent level's WorldSettings), so that actor and the
-- pawn are checked every tick (nothing shows in the left eye for more than a frame); every other Niagara component
-- every SCAN_ALL_S.

local uevrUtils = require('libs/uevr_utils')
local configui = require('libs/configui')

local SCAN_ALL_S = 0.25
local NIAGARA_CLASS = "Class /Script/Niagara.NiagaraComponent"

local OPTION = { widgetType = "checkbox", id = "bl4_hide_screen_fx",
    label = "Hide full-screen effects (repkit heal, dash, burning... BL4 draws them in the left eye only)", initialValue = true }
_G.BL4_SECTIONS = _G.BL4_SECTIONS or {}
local general = nil
for _, section in ipairs(_G.BL4_SECTIONS) do
    if section.label == "General" then general = section end
end
if general ~= nil then table.insert(general.layout, OPTION)
else table.insert(_G.BL4_SECTIONS, { order = 0, label = "General", layout = { OPTION } }) end

local function log(text)
    if _G.bl4 ~= nil and _G.bl4.log ~= nil then _G.bl4.log("[screen fx] " .. tostring(text)) else print("[screen fx] " .. tostring(text)) end
end

local niagaraClass = nil
local assetIsScreenFx = {} -- system asset address -> short name | false
local hidden = {}          -- component address -> component (drawing turned off by us)
local loggedNames = {}     -- system name -> true once logged
local nextScanAll = 0
local wasEnabled = true

local function enabled() return configui.getValue("bl4_hide_screen_fx") ~= false end

-- the component's system, by asset address (robust to component address reuse)
local function screenFxName(c)
    local asset = c.Asset
    if asset == nil then return nil end
    local key = asset:get_address()
    local known = assetIsScreenFx[key]
    if known == nil then
        local full = asset:get_full_name() or ""
        known = full:find("ScreenEffect", 1, true) and (full:match("%.([^%.]+)$") or full) or false
        assetIsScreenFx[key] = known
    end
    return known or nil
end

local function check(list)
    for _, c in ipairs(list or {}) do
        pcall(function()
            local address = c:get_address()
            if hidden[address] ~= nil then return end
            local name = screenFxName(c)
            if name == nil then return end
            c:SetRenderInMainPass(false)
            hidden[address] = c
            if not loggedNames[name] then
                loggedNames[name] = true
                log("hiding " .. name .. " (left-eye-only GPU sprites)")
            end
        end)
    end
end

local function componentsOf(actor)
    if actor == nil then return nil end
    if niagaraClass == nil then niagaraClass = uevrUtils.get_class(NIAGARA_CLASS) end
    if niagaraClass == nil then return nil end
    return actor:K2_GetComponentsByClass(niagaraClass)
end

local function worldSettings()
    local ws = nil
    pcall(function()
        local world = uevrUtils.get_world()
        ws = world ~= nil and world.PersistentLevel ~= nil and world.PersistentLevel.WorldSettings or nil
    end)
    return uevrUtils.getValid(ws)
end

local function restoreAll()
    local count = 0
    for _, c in pairs(hidden) do
        pcall(function()
            if uevrUtils.getValid(c) ~= nil then c:SetRenderInMainPass(true); count = count + 1 end
        end)
    end
    hidden = {}
    if count > 0 then log(string.format("drawing %d screen effect(s) again", count)) end
end

-- forget components that no longer exist (their address may come back as another object)
local function prune()
    for address, c in pairs(hidden) do
        if uevrUtils.getValid(c) == nil then hidden[address] = nil end
    end
end

uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
    local on = enabled()
    if not on then
        if wasEnabled then restoreAll() end
        wasEnabled = false
        return
    end
    wasEnabled = true
    local ok, err = pcall(function()
        check(componentsOf(worldSettings()))
        local pawn = uevr.api:get_local_pawn(0)
        if uevrUtils.getValid(pawn) ~= nil then check(componentsOf(pawn)) end
        local now = os.clock()
        if now >= nextScanAll then
            nextScanAll = now + SCAN_ALL_S
            prune()
            check(uevrUtils.find_all_of(NIAGARA_CLASS, false))
        end
    end)
    if not ok then log("scan failed: " .. tostring(err)) end
end)

uevrUtils.registerPreLevelChangeCallback(function(level)
    hidden = {}
    assetIsScreenFx = {}
end)

log("loaded")
