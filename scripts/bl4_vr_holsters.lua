-- Holsters for Borderlands 4 (2026-11-02, from the Outer Worlds 2 profile's holsters.lua). A right grip press that
-- STARTS with the right hand in a zone selects a weapon slot:
--   right hip      -> weapon slot 1  ('1' in the flat game)
--   right shoulder -> weapon slot 2  ('2')
--   left shoulder  -> weapon slot 3  ('3')
--   left hip       -> weapon slot 4  ('4')
--
-- BL4 has no player-side "equip slot" call (MCP 2026-11-02: OakCharacter.SwitchToAIWeapon and
-- ClientSetActiveWeaponEquipSlot change nothing for the player) and the d-pad does not pick slots, so the number keys
-- are pressed through plugins/luakey.dll (the fixed build: event name = one character, data exactly "down" / "up").
-- The game tracks the active input device and spends the first keyboard event after gamepad input on switching device
-- (Stalker 2, stalker2/gesturekeys.lua), so an unbound primer key (F24) is tapped first and the number key follows
-- PRIME_DELAY later, held for KEY_HOLD (verified live: F24, +0.15 s '2' held 0.12 s switched to slot 2). From the
-- primer until just after the key-up the sticks and triggers are zeroed, or any analog input in between flips the
-- device back to the gamepad. If the held weapon did not change, the key is sent once more.
-- luakey uses SendInput, so the key goes to the focused window: BL4 must have focus (it does while playing in VR).
--
-- Zones: boxes around the head in the HMD's yaw-only frame - origin = HMD position, yaw = HMD yaw (pitch / roll
-- ignored, so looking down at a hip does not move the zones). X forward, Y right, Z up, cm. The grip that started a
-- zone action is kept from the game (and from the hand poses / two-handing, which run after this at lower priority)
-- until it is released. A short haptic pulse when the hand enters a zone.
-- Off when the pawn is not the player character (menus, vehicles), while input is disabled and while paused.

local uevrUtils = require('libs/uevr_utils')
local controllers = require('libs/controllers')
local configui = require('libs/configui')

local vr = uevr.params.vr

local BTN_RB = 0x0200 -- XINPUT_GAMEPAD_RIGHT_SHOULDER (the right grip)
local PRIMER_KEY = "0x87" -- VK_F24, unbound in the game
local PRIME_DELAY_MS = 150
local KEY_HOLD_MS = 120
local QUIET_MARGIN_S = 0.05
local OUTCOME_CHECK_MS = 1500

-- id, label, number key, default centre (cm, body frame)
local ZONES = {
    { id = "rhip", label = "Right hip (slot 1)",      key = "1", x = 0.0,   y = 22.0,  z = -65.0 },
    { id = "rsh",  label = "Right shoulder (slot 2)", key = "2", x = -12.0, y = 20.0,  z = -10.0 },
    { id = "lsh",  label = "Left shoulder (slot 3)",  key = "3", x = -12.0, y = -20.0, z = -10.0 },
    { id = "lhip", label = "Left hip (slot 4)",       key = "4", x = 0.0,   y = -22.0, z = -65.0 },
}

local layout = {
    { widgetType = "checkbox", id = "bl4_hz_enabled", label = "Holsters: right grip at hips / shoulders = weapon slots 1-4", initialValue = true },
    { widgetType = "checkbox", id = "bl4_hz_haptic", label = "Haptic pulse when the hand enters a zone", initialValue = true },
    { widgetType = "slider_float", id = "bl4_hz_size", label = "Zone size (cm, half width of each box)", initialValue = 16.0, range = {6.0, 35.0}, speed = 0.5 },
    { widgetType = "text", id = "bl4_hz_status", label = "Right hand: -" },
    { widgetType = "text", label = "Zone centres (cm from the HMD: forward / right / up, body facing)" },
}
for _, z in ipairs(ZONES) do
    table.insert(layout, { widgetType = "drag_float3", id = "bl4_hz_" .. z.id, label = z.label, initialValue = { z.x, z.y, z.z }, range = {-120, 120}, speed = 0.5 })
end
_G.BL4_SECTIONS = _G.BL4_SECTIONS or {}
table.insert(_G.BL4_SECTIONS, { order = 2.7, label = "Holsters", layout = layout })

local function log(text)
    if _G.bl4 ~= nil and _G.bl4.log ~= nil then _G.bl4.log("[holsters] " .. tostring(text)) else print("[holsters] " .. tostring(text)) end
end

local function cfgNum(id, default)
    local v = configui.getValue(id)
    return type(v) == "number" and v or default
end

-- configui drag_float3 values come back as vectors (X/Y/Z) or arrays
local function zoneCentre(z)
    local v = configui.getValue("bl4_hz_" .. z.id)
    if type(v) == "table" or type(v) == "userdata" then
        local ok, x, y, zz = pcall(function() return v.X or v.x or v[1], v.Y or v.y or v[2], v.Z or v.z or v[3] end)
        if ok and type(x) == "number" and type(y) == "number" and type(zz) == "number" then return x, y, zz end
    end
    return z.x, z.y, z.z
end

local function playerCharacter()
    return _G.bl4 ~= nil and _G.bl4.getPlayerCharacter() or nil
end

local function blocked()
    if playerCharacter() == nil then return true end
    if uevrUtils.executeUEVRCallbacksWithPriorityBooleanResult("is_input_disabled") == true then return true end
    local world = uevrUtils.get_world()
    return world ~= nil and Statics ~= nil and Statics:IsGamePaused(world) == true
end

-- the right hand in the zone frame: returns local x, y, z (cm) or nil
local function handLocal()
    local pos = controllers.getControllerLocation(Handed.Right)
    local head = controllers.getControllerLocation(2)
    if pos == nil or head == nil then return nil end
    local headRot = controllers.getControllerRotation(2)
    local yaw = math.rad((headRot and headRot.Yaw) or 0)
    local dx, dy, dz = pos.X - head.X, pos.Y - head.Y, pos.Z - head.Z
    local c, s = math.cos(yaw), math.sin(yaw)
    return dx * c + dy * s, -dx * s + dy * c, dz
end

local function zoneAt(x, y, z)
    local h = cfgNum("bl4_hz_size", 16.0)
    for _, zone in ipairs(ZONES) do
        local cx, cy, cz = zoneCentre(zone)
        if math.abs(x - cx) <= h and math.abs(y - cy) <= h and math.abs(z - cz) <= h then return zone end
    end
    return nil
end

local function haptic(duration, amplitude)
    pcall(function()
        vr.trigger_haptic_vibration(0, duration, 1.0, amplitude, vr.get_right_joystick_source())
    end)
end

local function heldWeaponName()
    local name = "none"
    pcall(function()
        local pawn = playerCharacter()
        local weapon = pawn ~= nil and _G.bl4.getHeldWeapon(pawn) or nil
        if weapon ~= nil then name = weapon:get_full_name() end
    end)
    return name
end

-- ---------------------------------------------------------------------------------------------
-- Key delivery: primer, then the number key, sticks and triggers quiet throughout (see the header)
-- ---------------------------------------------------------------------------------------------
local quietUntil = 0
local keyBusy = false

local function sendEvent(name, data)
    pcall(function() uevr.api:dispatch_custom_event(name, data) end)
end

local function pressKey(key)
    keyBusy = true
    quietUntil = os.clock() + (PRIME_DELAY_MS + KEY_HOLD_MS) / 1000 + QUIET_MARGIN_S
    sendEvent(PRIMER_KEY, "down")
    sendEvent(PRIMER_KEY, "up")
    uevrUtils.setTimeout(PRIME_DELAY_MS, function()
        sendEvent(key, "down")
        uevrUtils.setTimeout(KEY_HOLD_MS, function()
            sendEvent(key, "up")
            keyBusy = false
        end)
    end)
end

local function selectSlot(zone)
    if keyBusy then return end
    local before = heldWeaponName()
    pressKey(zone.key)
    log(zone.label .. " -> key " .. zone.key)
    uevrUtils.setTimeout(OUTCOME_CHECK_MS, function()
        local after = heldWeaponName()
        if after ~= before or keyBusy or blocked() then return end
        log("key " .. zone.key .. " ignored (still " .. after .. "), sending once more")
        pressKey(zone.key)
    end)
end

-- ---------------------------------------------------------------------------------------------
-- Zones on the right grip
-- ---------------------------------------------------------------------------------------------
local current = nil
local gripWasDown = false
local swallowGrip = false
local nextStatusAt = 0

uevrUtils.registerOnPreInputGetStateCallback(function(retval, user_index, state)
    if user_index ~= 0 or state == nil then return end

    if quietUntil ~= 0 then
        if os.clock() < quietUntil then
            local pad = state.Gamepad
            pad.sThumbLX, pad.sThumbLY, pad.sThumbRX, pad.sThumbRY = 0, 0, 0, 0
            pad.bLeftTrigger, pad.bRightTrigger = 0, 0
        else
            quietUntil = 0
        end
    end

    local grip = uevrUtils.isButtonPressed(state, BTN_RB)
    local pressed = grip and not gripWasDown
    gripWasDown = grip
    if swallowGrip and not grip then swallowGrip = false end

    if configui.getValue("bl4_hz_enabled") ~= false and not blocked() then
        local ok, err = pcall(function()
            local x, y, z = handLocal()
            local zone = x ~= nil and zoneAt(x, y, z) or nil
            if zone ~= current then
                current = zone
                if zone ~= nil and configui.getValue("bl4_hz_haptic") ~= false then haptic(0.03, 0.4) end
            end
            if pressed and zone ~= nil then
                swallowGrip = true
                haptic(0.08, 1.0)
                selectSlot(zone)
            end
            if x ~= nil and os.clock() >= nextStatusAt then
                nextStatusAt = os.clock() + 0.2
                configui.setLabel("bl4_hz_status", string.format("Right hand: %.0f / %.0f / %.0f %s", x, y, z, zone and zone.label or "-"))
            end
        end)
        if not ok then log(tostring(err)) end
    elseif current ~= nil then
        current = nil
    end

    if swallowGrip and grip then state.Gamepad.wButtons = state.Gamepad.wButtons & ~BTN_RB end
end, 25) -- before the hand poses (10), two_handed (5) and remap (0)

uevrUtils.registerPreLevelChangeCallback(function(level)
    current, swallowGrip = nil, false
end)
