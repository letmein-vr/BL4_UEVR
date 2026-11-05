-- Grapple aiming with the right hand for Borderlands 4 (2026-10-31).
--
-- BL4 picks the grapple target natively (OakPlayerController.GrappleTargetingStrategy: best target inside a cone around
-- the view, GrappleDef cone angles / angle + distance scoring) and OakCharacter.ServerStartGrapple() takes no target -
-- it uses the one last reported with ServerSetBestGrappleable. The view it scores against is the camera manager's
-- cached POV, not the control rotation: with UEVR head aim the POV pitch stayed on the right stick (MCP: POV pitch 52,
-- ControlRotation pitch 14 while targeting a grapple point), so the grapple had to be aimed with the stick.
--
-- The cached POV (PlayerCameraManager.CameraCachePrivate.POV) is what the targeting reads. Its rotation is replaced with
-- the right hand's aim - the gun's barrel (Muzzle socket, the axis the reticule and BL4AimFix.dll use) or, with no gun
-- out, the right controller - but only for the player controller's tick: this script sends the aim every frame to
-- BL4AimFix.dll (custom event "bl4.grapple_aim"), which writes it at the start of that tick and puts the view back at
-- the end. This script used to write the cache after every frame, which left the hand aim in it for most of the frame;
-- BL4's audio (GbxAudio) places its listener from the same cached view, so the sound turned with the right hand
-- (2026-11-05). Player character on foot only.

local uevrUtils = require('libs/uevr_utils')
local configui = require('libs/configui')
local controllers = require('libs/controllers')

local function log(text)
	pcall(function() uevrUtils.print("[bl4 grapple] " .. tostring(text), LogLevel.Info) end)
end

_G.BL4_SECTIONS = _G.BL4_SECTIONS or {}
table.insert(_G.BL4_SECTIONS, { order = 4, label = "Grapple", layout = {
	{ widgetType = "checkbox", id = "bl4_grapple_hand_aim", label = "Aim the grapple with the right hand (gun / controller)", initialValue = true },
}})

local function alive(obj)
	if obj == nil then return false end
	local ok, r = pcall(function() return obj:get_full_name() ~= nil end)
	return ok and r
end

-- With a gun out the plugin uses the gun's barrel itself (it computes it every frame for the bullet / beam fixes), so
-- nothing is sent per frame then: luakey.dll logs every custom event, and one per frame flooded log.txt (2026-11-05).
local function hasGunOut()
	local has = false
	pcall(function()
		local pawn = _G.bl4.getPlayerCharacter()
		local weapon = pawn ~= nil and _G.bl4.getHeldWeapon(pawn) or nil
		has = alive(weapon ~= nil and _G.bl4.getFirstPersonWeaponMesh(weapon) or nil)
	end)
	return has
end

local function controllerAimRotation()
	local rot = nil
	local ctrl = controllers.getController(Handed.Right, true)
	if alive(ctrl) then pcall(function() rot = ctrl:K2_GetComponentRotation() end) end
	return rot
end

local HEARTBEAT_S = 2.0      -- "bl4.grapple_hand_aim" on/off; the plugin treats > 5 s of silence as off
local CONTROLLER_AIM_S = 0.05 -- 20 Hz while no gun is out (the plugin drops an aim older than 0.25 s)
local nextHeartbeat, nextAim, lastEnabled = 0, 0, nil

local warned = false
uevr.sdk.callbacks.on_post_engine_tick(function(engine, delta)
	if _G.bl4 == nil then return end
	local enabled = configui.getValue("bl4_grapple_hand_aim") ~= false
	local now = os.clock()
	local ok, err = pcall(function()
		if enabled ~= lastEnabled or now >= nextHeartbeat then
			uevr.api:dispatch_custom_event("bl4.grapple_hand_aim", enabled and "1" or "0")
			lastEnabled, nextHeartbeat = enabled, now + HEARTBEAT_S
		end
		if not enabled or _G.bl4.getPlayerCharacter() == nil or hasGunOut() or now < nextAim then return end
		local rot = controllerAimRotation()
		if rot == nil then return end
		uevr.api:dispatch_custom_event("bl4.grapple_aim", string.format("%.4f %.4f", rot.Pitch, rot.Yaw))
		nextAim = now + CONTROLLER_AIM_S
	end)
	if not ok and not warned then
		warned = true
		log("grapple aim send failed: " .. tostring(err))
	end
end)

log("loaded")
