-- Grapple aiming with the right hand for Borderlands 4 (2026-10-31).
--
-- BL4 picks the grapple target natively (OakPlayerController.GrappleTargetingStrategy: best target inside a cone around
-- the view, GrappleDef cone angles / angle + distance scoring) and OakCharacter.ServerStartGrapple() takes no target -
-- it uses the one last reported with ServerSetBestGrappleable. The view it scores against is the camera manager's
-- cached POV, not the control rotation: with UEVR head aim the POV pitch stayed on the right stick (MCP: POV pitch 52,
-- ControlRotation pitch 14 while targeting a grapple point), so the grapple had to be aimed with the stick.
--
-- The cached POV (PlayerCameraManager.CameraCachePrivate.POV) is what gameplay code reads DURING the world tick; the
-- camera update later in the frame rebuilds it from the game's own rotation before the view is drawn. So after each
-- frame (post engine tick) its rotation is replaced with the right hand's aim: the gun's barrel (Muzzle socket, the
-- axis the reticule and BL4AimFix.dll use) or, with no gun out, the right controller. Next frame's targeting then scores
-- around the hand; the VR view (built from the rebuilt POV) is unaffected. Player character on foot only.

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

local muzzleFName = nil
local function handAimRotation()
	local rot = nil
	pcall(function()
		local pawn = _G.bl4.getPlayerCharacter()
		local weapon = pawn ~= nil and _G.bl4.getHeldWeapon(pawn) or nil
		local mesh = weapon ~= nil and _G.bl4.getFirstPersonWeaponMesh(weapon) or nil
		if alive(mesh) then
			if muzzleFName == nil then muzzleFName = uevrUtils.fname_from_string("Muzzle") end
			if mesh:DoesSocketExist(muzzleFName) then rot = mesh:GetSocketRotation(muzzleFName) end
		end
	end)
	if rot == nil then
		local ctrl = controllers.getController(Handed.Right, true)
		if alive(ctrl) then pcall(function() rot = ctrl:K2_GetComponentRotation() end) end
	end
	return rot
end

local warned = false
uevr.sdk.callbacks.on_post_engine_tick(function(engine, delta)
	if configui.getValue("bl4_grapple_hand_aim") == false or _G.bl4 == nil then return end
	if _G.bl4.getPlayerCharacter() == nil then return end
	local ok, err = pcall(function()
		local rot = handAimRotation()
		if rot == nil then return end
		local pc = uevr.api:get_player_controller(0)
		local pcm = pc ~= nil and pc.PlayerCameraManager or nil
		if pcm == nil then return end
		local povRot = pcm.CameraCachePrivate.POV.Rotation
		povRot.Pitch, povRot.Yaw, povRot.Roll = rot.Pitch, rot.Yaw, 0
	end)
	if not ok and not warned then
		warned = true
		log("POV override failed: " .. tostring(err))
	end
end)

log("loaded")
