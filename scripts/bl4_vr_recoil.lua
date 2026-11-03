-- Weapon kick for Borderlands 4, driven by the game's own animation (2026-10-30).
--
-- BL4 does not animate the kick inside the gun: the first-person gun's WeaponOffset bone stays on the mesh origin while
-- firing. The kick lives in the first-person ARMS: the socket the game hangs the gun on, FirstPersonArms R_Hand_Weapon,
-- jumps back on every shot (MCP 2026-10-30, Maliwan SMG: ~3 cm straight back, ~1.3 deg roll, recovering) - and the VR
-- gun no longer hangs there. The arms keep animating while hidden (pawn.lua hides them by render-pass flags only), so:
--
--   * every frame the socket is read in arms COMPONENT space (immune to the arms component's own view pitch);
--   * while the fire button is held, plus a short tail for the recovery, the socket's change since the last frame
--     before firing (baseline frozen at the trigger press) is taken in the socket's own frame = the gun's frame;
--   * that kick is applied to the VR gun so it moves together with the hand:
--       Hands mode - the gun is a child of the right VR hand component, so the hand is moved on its controller:
--                    gun = G * hand -> hand' = G^-1 * kick * G * hand (G = gun relative to the hand);
--       IK mode    - the gun rides the IK hand bone, so bl4_vr_ik.lua moves the IK hand target the same way.
--
-- Anything bigger than a kick (reload / melee / equip played while the trigger is held) is not recoil: past the max
-- distance / angle the kick is dropped until the trigger is released. BL4AimFix.dll fires from the visible gun's muzzle,
-- so the kick also climbs the shots during automatic fire.

local uevrUtils = require('libs/uevr_utils')
local configui = require('libs/configui')
local hands = require('libs/hands')
local attachments = require('libs/attachments')

local SOCKET = "R_Hand_Weapon"
local RTS_COMPONENT = 2
local TRIGGER_THRESHOLD = 64 -- of 255

local function log(text)
	pcall(function() uevrUtils.print("[bl4 recoil] " .. tostring(text), LogLevel.Info) end)
end

_G.BL4_SECTIONS = _G.BL4_SECTIONS or {}
table.insert(_G.BL4_SECTIONS, { order = 3, label = "Recoil", layout = {
	{ widgetType = "checkbox", id = "bl4_recoil_enabled", label = "Weapon kick (from the game's arm animation)", initialValue = true },
	{ widgetType = "slider_float", id = "bl4_recoil_strength_loc", label = "Kick distance strength", initialValue = 1.0, range = { 0.0, 3.0 } },
	{ widgetType = "slider_float", id = "bl4_recoil_strength_rot", label = "Kick rotation strength", initialValue = 1.0, range = { 0.0, 3.0 } },
	{ widgetType = "checkbox", id = "bl4_recoil_two_handed", label = "Weapon kick while two-handing", initialValue = true },
	{ widgetType = "slider_float", id = "bl4_recoil_tail", label = "Recovery time after release (s)", initialValue = 0.35, range = { 0.05, 1.5 } },
	{ widgetType = "slider_float", id = "bl4_recoil_max_cm", label = "Ignore motions larger than (cm)", initialValue = 12.0, range = { 2.0, 40.0 } },
	{ widgetType = "slider_float", id = "bl4_recoil_max_deg", label = "Ignore rotations larger than (deg)", initialValue = 25.0, range = { 2.0, 90.0 } },
	{ widgetType = "text", id = "bl4_recoil_status", label = "Last burst: -" },
}})

local function value(id, default)
	local v = configui.getValue(id)
	if v == nil then return default end
	return v
end

local function alive(obj)
	if obj == nil then return false end
	local ok, r = pcall(function() return obj:get_full_name() ~= nil end)
	return ok and r
end

local function isIKMode()
	return _G.getHandsMode ~= nil and _G.getHandsMode() == 2
end

-- fire button = right trigger (read after UEVR mapped the VR controller into the gamepad state)
local triggerHeld = false
uevrUtils.registerOnPreInputGetStateCallback(function(retval, user_index, state)
	triggerHeld = state.Gamepad.bRightTrigger >= TRIGGER_THRESHOLD
end)

local function readSocket(arms)
	local t = arms:GetSocketTransform(SOCKET, RTS_COMPONENT)
	local l, r = t.Translation, kismet_math_library:Quat_Rotator(t.Rotation)
	return { loc = { X = l.X, Y = l.Y, Z = l.Z }, rot = { Pitch = r.Pitch, Yaw = r.Yaw, Roll = r.Roll } }
end

local function makeT(p)
	return kismet_math_library:MakeTransform(uevrUtils.vector(p.loc.X, p.loc.Y, p.loc.Z), uevrUtils.rotator(p.rot.Pitch, p.rot.Yaw, p.rot.Roll), uevrUtils.vector(1, 1, 1))
end

-- kick state
local active = false
local suppressedUntilRelease = false
local baseline = nil      -- socket pose (arms space) the last frame before firing
local lastPose = nil      -- socket pose of the previous frame
local releasedAt = nil
local handRest = nil      -- Hands mode: { hand, loc, rot, scale } of the right hand before the kick
local peakCm, peakDeg = 0, 0

local function restoreHand()
	if handRest == nil then return end
	if alive(handRest.hand) then
		pcall(uevrUtils.set_component_relative_transform, handRest.hand, handRest.loc, handRest.rot, handRest.scale)
	end
	handRest = nil
end

-- Two-handing (bl4_vr_two_handed.lua) rebuilds the right hand / gun / two-hand frame from its own base every view, so a
-- kick applied here would be overwritten. While two-handing the kick is only published (_G.bl4RecoilKick, gun frame)
-- and two-handing adds it after its pivot with these helpers.
_G.bl4RecoilKick = nil
_G.bl4RecoilRestoreHand = function() restoreHand() end -- two-handing captures the hand's rest: never a kicked one

-- world pose (loc table, rotator) of a gun-frame thing -> kicked: kick * T
_G.bl4KickWorld = function(loc, rot)
	local k = _G.bl4RecoilKick
	if k == nil then return loc, rot end
	local t = kismet_math_library:ComposeTransforms(makeT(k), kismet_math_library:MakeTransform(uevrUtils.vector(loc.X, loc.Y, loc.Z), rot, uevrUtils.vector(1, 1, 1)))
	local l = t.Translation
	return { X = l.X, Y = l.Y, Z = l.Z }, kismet_math_library:Quat_Rotator(t.Rotation)
end

-- the gun hangs on parent: move parent (from its current relative transform) so the gun gets the kick
_G.bl4KickParentOfGun = function(parent, gun)
	local k = _G.bl4RecoilKick
	if k == nil or not alive(parent) or not alive(gun) then return end
	local pl, pr, ps = parent.RelativeLocation, parent.RelativeRotation, parent.RelativeScale3D
	local parentT = kismet_math_library:MakeTransform(uevrUtils.vector(pl.X, pl.Y, pl.Z), uevrUtils.rotator(pr.Pitch, pr.Yaw, pr.Roll), uevrUtils.vector(1, 1, 1))
	local gl, gr = gun.RelativeLocation, gun.RelativeRotation
	local gunT = kismet_math_library:MakeTransform(uevrUtils.vector(gl.X, gl.Y, gl.Z), uevrUtils.rotator(gr.Pitch, gr.Yaw, gr.Roll), uevrUtils.vector(1, 1, 1))
	local t = kismet_math_library:ComposeTransforms(kismet_math_library:ComposeTransforms(
		kismet_math_library:ComposeTransforms(kismet_math_library:InvertTransform(gunT), makeT(k)), gunT), parentT)
	local l, r = t.Translation, kismet_math_library:Quat_Rotator(t.Rotation)
	uevrUtils.set_component_relative_transform(parent, { X = l.X, Y = l.Y, Z = l.Z }, { Pitch = r.Pitch, Yaw = r.Yaw, Roll = r.Roll }, { X = ps.X, Y = ps.Y, Z = ps.Z })
end

-- a component placed in world space with the gun's frame (the raw-controller gun): kick it in place
_G.bl4KickComponentWorld = function(component)
	if _G.bl4RecoilKick == nil or not alive(component) then return end
	local loc, rot = _G.bl4KickWorld(component:K2_GetComponentLocation(), component:K2_GetComponentRotation())
	component:K2_SetWorldLocationAndRotation(uevrUtils.vector(loc.X, loc.Y, loc.Z), rot, false, uevrUtils.get_reuseable_struct_object("ScriptStruct /Script/Engine.HitResult"), false)
end

local function endKick(reason)
	_G.bl4RecoilKick = nil
	if not active then return end
	active = false
	baseline, releasedAt = nil, nil
	restoreHand()
	if _G.bl4SetIKHandKick ~= nil then _G.bl4SetIKHandKick(nil) end
	configui.setLabel("bl4_recoil_status", string.format("Last burst: peak %.1f cm, %.1f deg%s", peakCm, peakDeg, reason and (" (" .. reason .. ")") or ""))
end

-- Hands mode: move the right VR hand (the gun's parent) so that the gun gets the kick in its own frame
local function applyToHand(gun, kickT)
	local hand = hands.getHandComponent(Handed.Right)
	if not alive(hand) then return end
	local parentOk = false
	pcall(function() parentOk = gun.AttachParent ~= nil and gun.AttachParent:get_address() == hand:get_address() end)
	if not parentOk then return end
	if handRest == nil or handRest.hand ~= hand then
		restoreHand()
		local l, r, s = hand.RelativeLocation, hand.RelativeRotation, hand.RelativeScale3D
		handRest = { hand = hand, loc = { X = l.X, Y = l.Y, Z = l.Z }, rot = { Pitch = r.Pitch, Yaw = r.Yaw, Roll = r.Roll }, scale = { X = s.X, Y = s.Y, Z = s.Z } }
	end
	local gl, gr = gun.RelativeLocation, gun.RelativeRotation
	local gunT = kismet_math_library:MakeTransform(uevrUtils.vector(gl.X, gl.Y, gl.Z), uevrUtils.rotator(gr.Pitch, gr.Yaw, gr.Roll), uevrUtils.vector(1, 1, 1))
	local restT = makeT(handRest)
	local t = kismet_math_library:ComposeTransforms(kismet_math_library:ComposeTransforms(
		kismet_math_library:ComposeTransforms(kismet_math_library:InvertTransform(gunT), kickT), gunT), restT)
	local l, r = t.Translation, kismet_math_library:Quat_Rotator(t.Rotation)
	uevrUtils.set_component_relative_transform(hand, { X = l.X, Y = l.Y, Z = l.Z }, { Pitch = r.Pitch, Yaw = r.Yaw, Roll = r.Roll }, handRest.scale)
end

local function tick()
	local twoHanding = _G.isTwoHandingActive == true
	if value("bl4_recoil_enabled", true) == false or _G.bl4 == nil or (twoHanding and value("bl4_recoil_two_handed", true) == false) then
		endKick() lastPose = nil return
	end
	local pawn = _G.bl4.getPlayerCharacter()
	local arms = pawn ~= nil and _G.bl4.getFirstPersonArms(pawn) or nil
	local gun = nil
	pcall(function() gun = attachments.getCurrentGrippedAttachment(Handed.Right) end)
	if not alive(arms) or not alive(gun) then endKick() lastPose = nil return end

	local ok, pose = pcall(readSocket, arms)
	if not ok or pose == nil then endKick() lastPose = nil return end

	if not triggerHeld then suppressedUntilRelease = false end
	if not active then
		if triggerHeld and not suppressedUntilRelease and lastPose ~= nil then
			active, baseline, releasedAt = true, lastPose, nil
			peakCm, peakDeg = 0, 0
		else
			lastPose = pose
			return
		end
	end
	lastPose = pose

	local now = os.clock()
	if triggerHeld then releasedAt = nil elseif releasedAt == nil then releasedAt = now end
	local weight = 1.0
	if releasedAt ~= nil then
		local f = (now - releasedAt) / math.max(0.05, value("bl4_recoil_tail", 0.35))
		if f >= 1.0 then endKick() return end
		if f > 0.7 then weight = (1.0 - f) / 0.3 end
	end

	-- the socket's change since the trigger press, in the socket's (= gun's) own frame
	local d = kismet_math_library:MakeRelativeTransform(makeT(pose), makeT(baseline))
	local t, r = d.Translation, kismet_math_library:Quat_Rotator(d.Rotation)
	local cm = math.sqrt(t.X * t.X + t.Y * t.Y + t.Z * t.Z)
	local deg = math.max(math.abs(r.Pitch), math.abs(r.Yaw), math.abs(r.Roll))
	if cm > value("bl4_recoil_max_cm", 12.0) or deg > value("bl4_recoil_max_deg", 25.0) then
		suppressedUntilRelease = true
		endKick("larger motion ignored")
		return
	end
	if cm > peakCm then peakCm = cm end
	if deg > peakDeg then peakDeg = deg end

	local sl, sr = value("bl4_recoil_strength_loc", 1.0) * weight, value("bl4_recoil_strength_rot", 1.0) * weight
	local kick = { loc = { X = t.X * sl, Y = t.Y * sl, Z = t.Z * sl }, rot = { Pitch = r.Pitch * sr, Yaw = r.Yaw * sr, Roll = r.Roll * sr } }

	if twoHanding then
		-- bl4_vr_two_handed.lua adds it after its pivot (see _G.bl4RecoilKick above)
		restoreHand()
		if _G.bl4SetIKHandKick ~= nil then _G.bl4SetIKHandKick(nil) end
		_G.bl4RecoilKick = kick
	elseif isIKMode() then
		_G.bl4RecoilKick = nil
		restoreHand()
		if _G.bl4SetIKHandKick ~= nil then _G.bl4SetIKHandKick(kick) end
	else
		_G.bl4RecoilKick = nil
		if _G.bl4SetIKHandKick ~= nil then _G.bl4SetIKHandKick(nil) end
		applyToHand(gun, makeT(kick))
	end
end

-- once per frame, after the world tick (the arms pose of this frame) and before bl4_vr_ik.lua's post-stereo hand update
local ranThisFrame = false
uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta) ranThisFrame = false end)
uevrUtils.registerPreCalculateStereoViewCallback(function(device, view_index, world_to_meters, position, rotation, is_double)
	if ranThisFrame then return end
	ranThisFrame = true
	local ok, err = pcall(tick)
	if not ok then
		log("tick: " .. tostring(err))
		pcall(endKick, "error")
	end
end)

uevrUtils.registerPreLevelChangeCallback(function(level)
	active, baseline, lastPose, releasedAt, handRest = false, nil, nil, nil, nil
	_G.bl4RecoilKick = nil
	if _G.bl4SetIKHandKick ~= nil then _G.bl4SetIKHandKick(nil) end
end)

log("loaded")
