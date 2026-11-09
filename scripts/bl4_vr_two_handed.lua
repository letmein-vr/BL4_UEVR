-- Two-handed weapon aiming for Borderlands 4, ported from Hellraiser's two_handed.lua (itself from the OW2 / Cronos
-- profiles), using libs/two_handed_aiming.lua.
--
-- Only attachments flagged "Two Handed" in the Attachments panel (attachments_parameters.json "two_handed": true) can be
-- two-handed. To grab: bring the left controller to the fore-grip point on the gun and hold the grab button (left grip
-- by default, or left trigger). While held the gun pivots so its barrel points from the right hand towards the left
-- hand, the left hand stays on the gun with the weapon's left grip pose, and the grab button is hidden from the game.
-- Releasing the button (or moving the left hand too far from the grip point) restores everything.
--
-- BL4 differences from Hellraiser:
--   * Hands mode: the gun is a child of the right VR hand (bl4_main.lua grip callback), not of the raw controller, so
--     the right hand cannot be re-parented onto the gun (loop). The right hand mesh itself is pivoted instead (the gun
--     follows as its child), re-applied every view from the hand's rest transform saved at grab (nothing else resets
--     it). The left hand is parented to the gun as in Hellraiser. Same placement as IK mode (2026-11-05): the hand
--     turns about its wrist bone keeping the grab-time direction to the left controller (swingAbout), and the left
--     hand's wrist bone (not the component origin) sits on the grip point with the IK offset meaning; a weapon with no
--     Hands left-hand values uses its IK ones.
--   * Without VR hands (gun on the raw controller): the gun is pivoted (UObjectHook resets it every view).
--   * IK mode: Hellraiser's two-hand frame; the un-pivoted gun base comes from bl4_vr_ik.lua (_G.bl4IKWeaponBase).
--   * Fore-grip point: along the first-person gun's origin -> Muzzle socket line (barrel = mesh +X), plus per-weapon
--     offsets (X = barrel, Y = right, Z = up), saved per attachment id in data/two_handed_parameters.json.
--   * The grab button is also hidden from the game while the left hand is within the grab radius, so the press that
--     starts the grab is not also a game input (left grip / trigger are bound to game actions).
--   * libs/hands.lua here has no setInputLocked / setAccessoryBlendTime (Hellraiser patches): those calls are skipped.

local uevrUtils = require('libs/uevr_utils')
local controllers = require('libs/controllers')
local attachments = require('libs/attachments')
local hands = require('libs/hands')
local configui = require('libs/configui')
local twoHandedAiming = require('libs/two_handed_aiming')
local animation = require('libs/animation')
local pawnModule = require('libs/pawn')
local ik = require('libs/ik')

local vr = uevr.params.vr

local MUZZLE_SOCKET = "Muzzle"
local GRAB_GRIP, GRAB_TRIGGER = 1, 2

local paramsFile = "two_handed_parameters"
local params = {} -- { [attachmentID] = { fraction, offX, offY, offZ, lh*, lhIk*, leftPose } }
local function loadParams()
	local p = json.load_file(paramsFile .. ".json")
	if p ~= nil then params = p end
end
local function saveParams()
	json.dump_file(paramsFile .. ".json", params, 4)
end
loadParams()

-- ---------------------------------------------------------------------------------------------
-- Panel section (zz_bl4_vr_panel.lua: bl4_th_enabled + grab button in the main panel, the rest under Dev Config)
-- ---------------------------------------------------------------------------------------------
_G.BL4_SECTIONS = _G.BL4_SECTIONS or {}
table.insert(_G.BL4_SECTIONS, { order = 2, label = "Two-Handed Aiming", layout = {
	{ widgetType = "checkbox", id = "bl4_th_enabled", label = "Enable Two-Handing", initialValue = true },
	{ widgetType = "combo", id = "bl4_th_grab_button", label = "Two-hand grab button", initialValue = GRAB_GRIP, selections = { "Left grip", "Left trigger" } },
	{ widgetType = "checkbox", id = "bl4_th_game_left_grip", label = "Left hand takes the game's own grip on the gun (hand + fingers, measured per gun; off = grip point + offsets)", initialValue = true },
	{ widgetType = "slider_float", id = "bl4_th_offhand_glide", label = "Off-hand glide time onto / off the gun (s, 0 = snap)", initialValue = 0.15, range = { 0.0, 0.6 } },
	{ widgetType = "checkbox", id = "bl4_th_suppress_grab", label = "Hide grab button from game near / while two-handing", initialValue = true },
	{ widgetType = "checkbox", id = "bl4_th_snap_left_hand", label = "Snap left hand to grip point", initialValue = true },
	{ widgetType = "slider_float", id = "bl4_th_grab_radius", label = "Grab radius (cm)", initialValue = 14.0, range = { 3.0, 40.0 } },
	{ widgetType = "slider_float", id = "bl4_th_release_radius", label = "Release radius (cm)", initialValue = 35.0, range = { 5.0, 100.0 } },
	{ widgetType = "spacing" },
	{ widgetType = "text", id = "bl4_th_weapon_label", label = "Weapon: none" },
	{ widgetType = "text", id = "bl4_th_status_label", label = "Status: idle" },
	{ widgetType = "spacing" },
	{ widgetType = "text", label = "-- Grip point for the current weapon (saved per attachment)" },
	{ widgetType = "slider_float", id = "bl4_th_fraction", label = "Along barrel (0=grip, 1=muzzle)", initialValue = 0.55, range = { 0.0, 1.5 } },
	{ widgetType = "slider_float", id = "bl4_th_off_x", label = "Offset X (forward)", initialValue = 0.0, range = { -40.0, 40.0 } },
	{ widgetType = "slider_float", id = "bl4_th_off_y", label = "Offset Y (right)", initialValue = 0.0, range = { -40.0, 40.0 } },
	{ widgetType = "slider_float", id = "bl4_th_off_z", label = "Offset Z (up)", initialValue = 0.0, range = { -40.0, 40.0 } },
	{ widgetType = "checkbox", id = "bl4_th_show_marker", label = "Show grip point marker", initialValue = false },
	{ widgetType = "checkbox", id = "bl4_th_ik_stretch", label = "IK: left arm stretches to reach the grip", initialValue = true },
	{ widgetType = "slider_float", id = "bl4_th_ik_stretch_max", label = "IK: max left arm stretch (x arm length)", initialValue = 1.35, range = { 1.0, 2.0 } },
	{ widgetType = "spacing" },
	{ widgetType = "text", label = "-- Left hand pose while two-handing (saved per attachment)" },
	{ widgetType = "text", id = "bl4_th_pose_label", label = "Pose: none" },
	{ widgetType = "checkbox", id = "bl4_th_apply_pose", label = "Apply captured pose while two-handing", initialValue = true },
	{ widgetType = "button", id = "bl4_th_capture_pose", label = "Get left hand pose from current mesh", size = { 260, 24 } },
	{ widgetType = "button", id = "bl4_th_clear_pose", label = "Clear left hand pose", size = { 180, 24 } },
	{ widgetType = "spacing" },
	{ widgetType = "text", label = "-- Left hand placement while two-handing, Hands mode (weapon-local, saved per attachment)" },
	{ widgetType = "slider_float", id = "bl4_th_lh_off_x", label = "LH Offset X", initialValue = 0.0, range = { -30.0, 30.0 } },
	{ widgetType = "slider_float", id = "bl4_th_lh_off_y", label = "LH Offset Y", initialValue = 0.0, range = { -30.0, 30.0 } },
	{ widgetType = "slider_float", id = "bl4_th_lh_off_z", label = "LH Offset Z", initialValue = 0.0, range = { -30.0, 30.0 } },
	{ widgetType = "slider_float", id = "bl4_th_lh_rot_pitch", label = "LH Rot Pitch", initialValue = 0.0, range = { -180.0, 180.0 } },
	{ widgetType = "slider_float", id = "bl4_th_lh_rot_yaw", label = "LH Rot Yaw", initialValue = 0.0, range = { -180.0, 180.0 } },
	{ widgetType = "slider_float", id = "bl4_th_lh_rot_roll", label = "LH Rot Roll", initialValue = 0.0, range = { -180.0, 180.0 } },
	{ widgetType = "text", label = "-- Left hand placement while two-handing, IK mode (weapon-local, saved per attachment)" },
	{ widgetType = "slider_float", id = "bl4_th_lh_ik_off_x", label = "IK LH Offset X", initialValue = 0.0, range = { -30.0, 30.0 } },
	{ widgetType = "slider_float", id = "bl4_th_lh_ik_off_y", label = "IK LH Offset Y", initialValue = 0.0, range = { -30.0, 30.0 } },
	{ widgetType = "slider_float", id = "bl4_th_lh_ik_off_z", label = "IK LH Offset Z", initialValue = 0.0, range = { -30.0, 30.0 } },
	{ widgetType = "slider_float", id = "bl4_th_lh_ik_rot_pitch", label = "IK LH Rot Pitch", initialValue = 0.0, range = { -180.0, 180.0 } },
	{ widgetType = "slider_float", id = "bl4_th_lh_ik_rot_yaw", label = "IK LH Rot Yaw", initialValue = 0.0, range = { -180.0, 180.0 } },
	{ widgetType = "slider_float", id = "bl4_th_lh_ik_rot_roll", label = "IK LH Rot Roll", initialValue = 0.0, range = { -180.0, 180.0 } },
	{ widgetType = "checkbox", id = "bl4_th_force", label = "Force two-handing ON (dev)", initialValue = false },
}})

-- ---------------------------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------------------------
local active = false
local currentWeaponID = nil
local lastLeftButtons = 0
local poseReapplyTimer = 0
local grabDown = false   -- the configured grab button (grip or trigger), raw, before the game sees it
local nearGrip = false   -- left controller within the grab radius last tick (grab button hidden from the game)
local ranThisTick = false
local snapshots = {}     -- [hand] = { parent, socket, loc={X,Y,Z}, rot={Pitch,Yaw,Roll} }
local rightPivot = nil   -- Hands mode: { pmc, loc, rot, gripLocal } = the right hand's rest relative transform (pivoted every view)
local leftGlide = nil    -- Hands mode off-hand glide: { pmc, sLoc, sRot, eLoc, eRot, t0, dur, home }
local marker = nil
local hitResult = nil

local function getHitResult()
	if hitResult == nil then
		hitResult = uevrUtils.get_struct_object("ScriptStruct /Script/Engine.HitResult")
	end
	return hitResult
end

local function status(text)
	configui.setLabel("bl4_th_status_label", "Status: " .. text)
end

local function alive(obj)
	if obj == nil then return false end
	local ok, r = pcall(function() return obj:get_full_name() ~= nil end)
	return ok and r
end

local function getWeaponParams(id)
	if id == nil then return nil end
	if params[id] == nil then
		params[id] = { fraction = 0.55, offX = 0, offY = 0, offZ = 0 }
	end
	return params[id]
end

-- Left-hand placement sliders: Hands mode (lh*) and IK mode (lhIk*) have their own values per weapon
local LH_SLIDERS = {
	{ id = "bl4_th_lh_off_x", field = "lhOffX", ik = "lhIkOffX", ikId = "bl4_th_lh_ik_off_x" },
	{ id = "bl4_th_lh_off_y", field = "lhOffY", ik = "lhIkOffY", ikId = "bl4_th_lh_ik_off_y" },
	{ id = "bl4_th_lh_off_z", field = "lhOffZ", ik = "lhIkOffZ", ikId = "bl4_th_lh_ik_off_z" },
	{ id = "bl4_th_lh_rot_pitch", field = "lhRotPitch", ik = "lhIkRotPitch", ikId = "bl4_th_lh_ik_rot_pitch" },
	{ id = "bl4_th_lh_rot_yaw", field = "lhRotYaw", ik = "lhIkRotYaw", ikId = "bl4_th_lh_ik_rot_yaw" },
	{ id = "bl4_th_lh_rot_roll", field = "lhRotRoll", ik = "lhIkRotRoll", ikId = "bl4_th_lh_ik_rot_roll" },
}

-- a weapon without IK values starts from its Hands values (copied once, separate afterwards); true = changed
local function seedIKLeftHand(p)
	local changed = false
	for _, s in ipairs(LH_SLIDERS) do
		if p[s.ik] == nil then p[s.ik] = p[s.field] or 0 changed = true end
	end
	return changed
end

-- Hands and IK place the left hand the same way (wrist bone at the grip point, controller rotation, same offset
-- meaning), so a weapon without Hands values uses its IK ones; the first Hands slider edit copies them (separate after)
local function handsLeftHandUnset(p)
	for _, s in ipairs(LH_SLIDERS) do
		if p[s.field] ~= nil then return false end
	end
	return true
end
local function seedHandsLeftHand(p)
	if not handsLeftHandUnset(p) then return end
	for _, s in ipairs(LH_SLIDERS) do p[s.field] = p[s.ik] or 0 end
end

-- the weapon's left-hand offset for the current hands mode: loc {X,Y,Z}, rot {Pitch,Yaw,Roll}
local function leftHandOffset(p, ikValues)
	local handsUnset = not ikValues and handsLeftHandUnset(p)
	local function v(s)
		if ikValues or handsUnset then return p[s.ik] or 0 end
		return p[s.field] or 0
	end
	local s = LH_SLIDERS
	return { X = v(s[1]), Y = v(s[2]), Z = v(s[3]) }, { Pitch = v(s[4]), Yaw = v(s[5]), Roll = v(s[6]) }
end

-- shows the weapon's saved values in the sliders (no callbacks: those would only write the same values back)
local function loadWeaponParamsToUI(id)
	local p = getWeaponParams(id)
	if p == nil then return end
	configui.setValue("bl4_th_fraction", p.fraction or 0.55, true)
	configui.setValue("bl4_th_off_x", p.offX or 0, true)
	configui.setValue("bl4_th_off_y", p.offY or 0, true)
	configui.setValue("bl4_th_off_z", p.offZ or 0, true)
	if seedIKLeftHand(p) then saveParams() end
	local handsUnset = handsLeftHandUnset(p)
	for _, s in ipairs(LH_SLIDERS) do
		configui.setValue(s.id, (handsUnset and p[s.ik] or p[s.field]) or 0, true)
		configui.setValue(s.ikId, p[s.ik] or 0, true)
	end
end

local GRIP_SLIDERS = { bl4_th_fraction = "fraction", bl4_th_off_x = "offX", bl4_th_off_y = "offY", bl4_th_off_z = "offZ" }
for id, field in pairs(GRIP_SLIDERS) do
	configui.onUpdate(id, function(value)
		local p = getWeaponParams(currentWeaponID)
		if p == nil then return end
		p[field] = value
		saveParams()
	end)
end

-- ---------------------------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------------------------
local muzzleFName = nil

-- World-space fore-grip point for the current weapon mesh
local function getGripPoint(weaponMesh)
	local p = getWeaponParams(currentWeaponID) or { fraction = 0.55, offX = 0, offY = 0, offZ = 0 }
	local origin = weaponMesh:K2_GetComponentLocation()
	local fwd = weaponMesh:GetForwardVector()
	local right = weaponMesh:GetRightVector()
	local up = weaponMesh:GetUpVector()
	if muzzleFName == nil then muzzleFName = uevrUtils.fname_from_string(MUZZLE_SOCKET) end
	local barrelLen = 40.0 -- no socket: assume a 40 cm gun along the mesh's barrel axis (+X on BL4)
	if weaponMesh:DoesSocketExist(muzzleFName) then
		local muzzle = weaponMesh:GetSocketLocation(muzzleFName)
		local dx, dy, dz = muzzle.X - origin.X, muzzle.Y - origin.Y, muzzle.Z - origin.Z
		local len = math.sqrt(dx * dx + dy * dy + dz * dz)
		if len >= 1.0 then
			barrelLen = len
			fwd = { X = dx / len, Y = dy / len, Z = dz / len }
		end
	end
	local along = barrelLen * (p.fraction or 0.55) + (p.offX or 0)
	local oy, oz = (p.offY or 0), (p.offZ or 0)
	return uevrUtils.vector(
		origin.X + fwd.X * along + right.X * oy + up.X * oz,
		origin.Y + fwd.Y * along + right.Y * oy + up.Y * oz,
		origin.Z + fwd.Z * along + right.Z * oy + up.Z * oz)
end

local function distance(a, b)
	local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- The game's own left grip on this gun (2026-11-09): bl4_main.lua measures the flat game's L_Hand relative to
-- R_Hand_Weapon on FirstPersonArms per gun model (= the gun's own frame: the first-person gun sits on that socket). With
-- option bl4_th_game_left_grip the left hand's L_Hand bone goes exactly there - position AND rotation - in both hand
-- modes, and bl4_main copies the game's left finger pose onto it (_G.bl4TwoHandGameLeft). The per-weapon left-hand
-- offsets below belong to the grip-point placement and are not applied on top. nil = not measured yet / one-handed gun:
-- the grip-point placement as before.
local GAME_LEFT_BONE = "L_Hand"
local function gameLeftGripT(weaponMesh)
	if configui.getValue("bl4_th_game_left_grip") == false then return nil end
	if _G.bl4 == nil or _G.bl4.getGameLeftGrip == nil then return nil end
	local ok, g = pcall(_G.bl4.getGameLeftGrip, weaponMesh)
	if not ok or g == nil then return nil end
	return kismet_math_library:MakeTransform(uevrUtils.vector(g.loc.X, g.loc.Y, g.loc.Z),
		uevrUtils.rotator(g.rot.Pitch, g.rot.Yaw, g.rot.Roll), uevrUtils.vector(1, 1, 1))
end

local function updateMarker(weaponMesh, point)
	local show = configui.getValue("bl4_th_show_marker") == true and weaponMesh ~= nil and point ~= nil
	if show then
		if not alive(marker) then
			marker = nil
			pcall(function()
				marker = uevrUtils.createStaticMeshComponent("StaticMesh /Engine/EngineMeshes/Sphere.Sphere", { visible = true, collisionEnabled = false })
				if marker ~= nil then
					uevrUtils.set_component_relative_transform(marker, nil, nil, { X = 0.02, Y = 0.02, Z = 0.02 })
				end
			end)
		end
		if alive(marker) then
			-- same depth layer as the gun: BL4 draws the first-person gun in Gearbox's foreground layer (bGbxForeground),
			-- which a normal-scene sphere does not depth-sort against (shows through / behind the gun wrongly)
			pcall(function()
				local fg = weaponMesh.bGbxForeground == true
				if marker.bGbxForeground ~= fg and marker.SetGbxForeground ~= nil then marker:SetGbxForeground(fg) end
			end)
			pcall(function() marker:K2_SetWorldLocation(point, false, getHitResult(), false) end)
		end
	elseif alive(marker) then
		pcall(function() uevrUtils.destroyComponent(marker, true, true) end)
		marker = nil
	end
end

local function relativeOf(pmc)
	local l, r = pmc.RelativeLocation, pmc.RelativeRotation
	return { X = l.X, Y = l.Y, Z = l.Z }, { Pitch = r.Pitch, Yaw = r.Yaw, Roll = r.Roll }
end

local function snapshotHand(hand)
	local pmc = hands.getHandComponent(hand)
	if not alive(pmc) then return nil end
	local ok, snap = pcall(function()
		local loc, rot = relativeOf(pmc)
		-- grabbed again while the left hand is still gliding home: its rest is the glide's end, not where it is now
		if hand == Handed.Left and leftGlide ~= nil and leftGlide.home and leftGlide.pmc == pmc then
			loc, rot = leftGlide.eLoc, leftGlide.eRot
		end
		return {
			parent = pmc.AttachParent,
			socket = (pmc.AttachSocketName and pmc.AttachSocketName:to_string()) or "",
			loc = loc,
			rot = rot,
		}
	end)
	if ok then snapshots[hand] = snap end
	return pmc
end

-- Off-hand glide, Hands mode: the left hand's relative transform eases from where it was to the target over
-- bl4_th_offhand_glide (cubic ease-out, RLerp), in the parent's space so the pivoting gun never makes it chase. 0 = snap.

local function glideTime()
	local v = configui.getValue("bl4_th_offhand_glide")
	return type(v) == "number" and v or 0.15
end

-- glide pmc's relative transform from (sLoc, sRot) to (eLoc, eRot); puts it at the start right away
local function startLeftGlide(pmc, sLoc, sRot, eLoc, eRot)
	local dur = glideTime()
	if dur <= 0 then leftGlide = nil return false end
	leftGlide = { pmc = pmc, sLoc = sLoc, sRot = sRot, eLoc = eLoc, eRot = eRot, t0 = os.clock(), dur = dur }
	pcall(function() uevrUtils.set_component_relative_transform(pmc, sLoc, sRot, { X = 1, Y = 1, Z = 1 }) end)
	return true
end

local function updateLeftGlide()
	local g = leftGlide
	if g == nil then return end
	if not alive(g.pmc) then leftGlide = nil return end
	local a = math.min(1.0, (os.clock() - g.t0) / g.dur)
	local e = 1 - (1 - a) ^ 3
	local ok = pcall(function()
		local loc = { X = g.sLoc.X + (g.eLoc.X - g.sLoc.X) * e, Y = g.sLoc.Y + (g.eLoc.Y - g.sLoc.Y) * e, Z = g.sLoc.Z + (g.eLoc.Z - g.sLoc.Z) * e }
		local rot = kismet_math_library:RLerp(uevrUtils.rotator(g.sRot.Pitch, g.sRot.Yaw, g.sRot.Roll), uevrUtils.rotator(g.eRot.Pitch, g.eRot.Yaw, g.eRot.Roll), e, true)
		uevrUtils.set_component_relative_transform(g.pmc, loc, rot, { X = 1, Y = 1, Z = 1 })
	end)
	if not ok or a >= 1.0 then leftGlide = nil end
end

local function restoreHand(hand)
	local pmc = hands.getHandComponent(hand)
	local snap = snapshots[hand]
	snapshots[hand] = nil
	if not alive(pmc) then return end
	if hand == Handed.Left then leftGlide = nil end
	pcall(function()
		if snap ~= nil and alive(snap.parent) and hand == Handed.Left and glideTime() > 0 then
			-- back onto the controller without moving, then glide home
			pmc:K2_AttachTo(snap.parent, uevrUtils.fname_from_string(snap.socket or ""), 1, false)
			local sLoc, sRot = relativeOf(pmc)
			if startLeftGlide(pmc, sLoc, sRot, snap.loc, snap.rot) then leftGlide.home = true end
		elseif snap ~= nil and alive(snap.parent) then
			pmc:K2_AttachTo(snap.parent, uevrUtils.fname_from_string(snap.socket or ""), 0, false)
			uevrUtils.set_component_relative_transform(pmc, snap.loc, snap.rot, { X = 1, Y = 1, Z = 1 })
		else
			-- fallback: back onto the controller
			pmc:DetachFromParent(false, false)
			controllers.attachComponentToController(hand, pmc)
		end
	end)
end

local function parentHandToWeapon(hand, weaponMesh, snapToPoint)
	local pmc = snapshotHand(hand)
	if not alive(pmc) then return nil end
	local preLoc, preRot = nil, nil
	pcall(function()
		-- 1 = KeepWorldPosition: the hand stays exactly where the controller put it at grab time
		pmc:K2_AttachTo(weaponMesh, uevrUtils.fname_from_string(""), 1, false)
		preLoc, preRot = relativeOf(pmc) -- where it is now, in the gun's space (glide start)
		if snapToPoint ~= nil then
			pmc:K2_SetWorldLocation(snapToPoint, false, getHitResult(), false)
		end
	end)
	return preLoc, preRot
end

-- ---------------------------------------------------------------------------------------------
-- Left hand pose while two-handing (captured from the game's own arms, per attachment)
-- ---------------------------------------------------------------------------------------------
local leftTargetBone = nil
local function getLeftTargetBone()
	if leftTargetBone == nil then
		leftTargetBone = "L_Hand"
		pcall(function()
			local cfg = json.load_file("hands_parameters.json")
			local profiles = cfg and cfg["profiles"]
			if profiles ~= nil then
				for _, profile in pairs(profiles) do
					for _, meshDef in pairs(profile) do
						if type(meshDef) == "table" and meshDef["Left"] ~= nil and meshDef["Left"]["Name"] ~= nil and meshDef["Left"]["Name"] ~= "" then
							leftTargetBone = meshDef["Left"]["Name"]
							return
						end
					end
				end
			end
		end)
	end
	return leftTargetBone
end

local function getLeftPose()
	local p = currentWeaponID ~= nil and params[currentWeaponID] or nil
	return p and p.leftPose or nil
end

local function updatePoseLabel()
	local pose = getLeftPose()
	local n = 0
	if pose ~= nil then for _ in pairs(pose) do n = n + 1 end end
	configui.setLabel("bl4_th_pose_label", pose ~= nil and ("Pose: " .. n .. " bones captured") or "Pose: none (uses the weapon's left grip pose)")
end

local function ikMode()
	return _G.getHandsMode ~= nil and _G.getHandsMode() == 2
end

-- the mesh that carries the left hand's finger bones: the VR hand in Hands mode, the IK rig mesh in IK mode
local function leftHandMesh()
	local pmc = hands.getHandComponent(Handed.Left)
	if alive(pmc) then return pmc end
	if ikMode() then
		local rigMesh = ik.getCurrentMesh(1)
		if alive(rigMesh) then return rigMesh end
	end
	return nil
end

-- apply the captured pose to the left hand (bone-space rotations)
local function applyLeftPose()
	if not active then return end
	if configui.getValue("bl4_th_apply_pose") == false then return end
	if _G.bl4TwoHandGameLeft == true then return end -- the game's own finger pose is copied every tick (bl4_main.lua)
	local pose = getLeftPose()
	local mesh = leftHandMesh()
	if pose == nil or not alive(mesh) then return end
	pcall(function() animation.initializeBones(mesh, pose) end)
end

local function scheduleLeftPose()
	for _, delayMs in ipairs({ 1, 150, 400 }) do
		uevrUtils.setTimeout(delayMs, applyLeftPose)
	end
end

-- Game thread. Copies the game's arms (pawn module arms mesh = FirstPersonArms) into a temporary poseable mesh (made
-- drawable by bl4_main.lua's wrapper, current pose copied), records the bone-space rotation of every bone below the
-- left hand bone and stores it for the current attachment.
local function captureLeftPose()
	if currentWeaponID == nil then status("capture: no weapon attached") return end
	local source = pawnModule.getArmsMesh()
	if not alive(source) then status("capture: arms mesh not found") return end
	local temp = uevrUtils.createPoseableMeshFromSkeletalMesh(source, { useDefaultPose = false, showDebug = false })
	if temp == nil then status("capture: could not copy arms mesh") return end
	local pose = {}
	local count = 0
	local ok, err = pcall(function()
		local bones = animation.getDescendantBones(temp, getLeftTargetBone(), false)
		for _, boneName in ipairs(bones or {}) do
			local rot = animation.getBoneSpaceLocalTransform(temp, uevrUtils.fname_from_string(boneName), 0)
			if rot ~= nil then
				pose[boneName] = { rotation = { rot.Pitch, rot.Yaw, rot.Roll } }
				count = count + 1
			end
		end
	end)
	pcall(function() uevrUtils.destroyComponent(temp, true, true) end)
	if not ok then status("capture failed: " .. tostring(err)) return end
	if count == 0 then status("capture: no bones found below " .. tostring(getLeftTargetBone())) return end
	getWeaponParams(currentWeaponID).leftPose = pose
	saveParams()
	updatePoseLabel()
	status("captured " .. count .. " bones for " .. tostring(currentWeaponID))
	scheduleLeftPose()
end

configui.onUpdate("bl4_th_capture_pose", function(value)
	-- button callbacks run on the draw thread; the capture spawns a temp component -> defer
	uevrUtils.setTimeout(1, captureLeftPose)
end)

configui.onUpdate("bl4_th_clear_pose", function(value)
	local p = currentWeaponID ~= nil and params[currentWeaponID] or nil
	if p ~= nil then p.leftPose = nil; saveParams() end
	updatePoseLabel()
	if active then
		-- fall back to the weapon's left grip pose from the hands wizard
		local animName = attachments.getCurrentGripAnimation(Handed.Right)
		pcall(function() hands.setHoldingAttachment(Handed.Left, (type(animName) == "string" and animName) or true) end)
	end
end)

-- ---------------------------------------------------------------------------------------------
-- Left hand placement offsets while two-handing (relative to where the hand landed at grab time)
-- ---------------------------------------------------------------------------------------------
local leftBaseRel = nil -- Hands mode: { restT, wrist, loc, rot } captured right after parenting (see applyLeftOffset)

-- forward declarations (IK helpers are defined further down)
local ikBase = nil
local applyIKAccessory = nil
local ikAim = nil

-- IK mode, two-hand frame: both IK hands target this invisible SceneComponent (on the pawn, unattached), placed each
-- post-stereo at the two-handed gun pose; the gun stays on the rig's right hand bone (bl4_vr_ik.lua), so gun and hands
-- come out of the same IK solve. Created ahead of the grab while an IK two-handable gun is held: libs/ik.lua only
-- accepts a target that UEVR_UObjectHook.exists() knows, which a freshly created component may not be yet.
local SCENE_COMPONENT_CLASS = "Class /Script/Engine.SceneComponent"
local twoHandFrame = nil
local twoHandFramePawn = nil -- the frame lives and dies with this pawn

local function frameUsable(frame)
	if frame == nil then return false end
	local ok, r = pcall(function() return UEVR_UObjectHook.exists(frame) end)
	return ok and r == true
end

local function ensureTwoHandFrame()
	local pawn = uevr.api:get_local_pawn(0)
	if pawn ~= twoHandFramePawn then twoHandFrame, twoHandFramePawn = nil, nil end
	if twoHandFrame ~= nil then return twoHandFrame end
	local class = uevr.api:find_uobject(SCENE_COMPONENT_CLASS)
	if pawn == nil or class == nil then return nil end
	local identityT = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = 0, Y = 0, Z = 0 }, Scale3D = { X = 1, Y = 1, Z = 1 } }
	local ok, created = pcall(function() return pawn:AddComponentByClass(class, true, identityT, false) end) -- manual attachment: stays unattached
	if not ok or created == nil or created == false then return nil end
	pcall(function() created:SetMobility(2) end) -- movable
	twoHandFrame, twoHandFramePawn = created, pawn
	return twoHandFrame
end

local function placeTwoHandFrame(frame, loc, rot)
	frame:K2_SetWorldLocationAndRotation(uevrUtils.vector(loc.X, loc.Y, loc.Z), rot, false, getHitResult(), true)
end

-- Hands mode places the left hand the way IK mode places its IK target: the hand's WRIST bone (the hands wizard's
-- Left joint, L_Hand) goes to the grip point + offset, turned to the left controller's rotation + offset, all in the
-- gun's space. The VR hand is a component whose origin sits away from that bone (Left joint Location -7.6 cm), so the
-- component is placed as if a virtual left controller held it there: pmc = restRelativeToController * virtualController,
-- virtualController.loc = target - virtualController.rot * (wrist bone in controller space).
local function applyLeftOffset()
	leftGlide = nil
	if not active or leftBaseRel == nil then return end
	local pmc = hands.getHandComponent(Handed.Left)
	if not alive(pmc) then return end
	local o, r = leftHandOffset(getWeaponParams(currentWeaponID) or {}, false)
	local ok, err = pcall(function()
		local b = leftBaseRel
		if b.gameRel ~= nil then
			-- game grip: the hand's L_Hand bone exactly on the game's grip (pmc = bone^-1 * grip, in the gun's space)
			local t = b.gameRel.Translation
			pmc:K2_SetRelativeLocationAndRotation(uevrUtils.vector(t.X, t.Y, t.Z), kismet_math_library:Quat_Rotator(b.gameRel.Rotation),
				false, getHitResult(), true)
			return
		end
		local tRot = uevrUtils.rotator(b.rot.Pitch + r.Pitch, b.rot.Yaw + r.Yaw, b.rot.Roll + r.Roll)
		local k = kismet_math_library:GreaterGreater_VectorRotator(uevrUtils.vector(b.wrist.X, b.wrist.Y, b.wrist.Z), tRot)
		local ctrlT = kismet_math_library:MakeTransform(
			uevrUtils.vector(b.loc.X + o.X - k.X, b.loc.Y + o.Y - k.Y, b.loc.Z + o.Z - k.Z), tRot, uevrUtils.vector(1, 1, 1))
		local rel = kismet_math_library:ComposeTransforms(b.restT, ctrlT)
		local t = rel.Translation
		pmc:K2_SetRelativeLocationAndRotation(uevrUtils.vector(t.X, t.Y, t.Z), kismet_math_library:Quat_Rotator(rel.Rotation),
			false, getHitResult(), true)
	end)
	if not ok then print("[bl4 two_handed] left placement: " .. tostring(err)) end
end

-- after parentHandToWeapon (snapshot taken = the hand's rest on the controller): the target in the gun's space
-- (grip point, or the controller when not snapping) and the wrist bone's offset in controller space
local function captureLeftBase(weaponMesh, targetPoint)
	leftBaseRel = nil
	local pmc = hands.getHandComponent(Handed.Left)
	local ctrl = controllers.getController(0, true)
	local snap = snapshots[Handed.Left]
	if not alive(pmc) or not alive(ctrl) or snap == nil then return end
	local ok, err = pcall(function()
		local one = uevrUtils.vector(1, 1, 1)
		local restT = kismet_math_library:MakeTransform(uevrUtils.vector(snap.loc.X, snap.loc.Y, snap.loc.Z),
			uevrUtils.rotator(snap.rot.Pitch, snap.rot.Yaw, snap.rot.Roll), one)
		local wristInPmc = kismet_math_library:MakeRelativeTransform(pmc:GetSocketTransform(getLeftTargetBone(), 0), pmc:K2_GetComponentToWorld())
		local w = kismet_math_library:ComposeTransforms(wristInPmc, restT).Translation
		local gunT = weaponMesh:K2_GetComponentToWorld()
		local lp = kismet_math_library:InverseTransformLocation(gunT, targetPoint or ctrl:K2_GetComponentLocation())
		local lr = kismet_math_library:InverseTransformRotation(gunT, ctrl:K2_GetComponentRotation())
		leftBaseRel = {
			restT = restT,
			wrist = { X = w.X, Y = w.Y, Z = w.Z },
			loc = { X = lp.X, Y = lp.Y, Z = lp.Z },
			rot = { Pitch = lr.Pitch, Yaw = lr.Yaw, Roll = lr.Roll },
		}
		-- the game's left grip (the gun's own frame): the component placement that puts this hand's L_Hand bone on it
		local gripT = gameLeftGripT(weaponMesh)
		if gripT ~= nil then
			local boneInPmc = kismet_math_library:MakeRelativeTransform(
				pmc:GetSocketTransform(uevrUtils.fname_from_string(GAME_LEFT_BONE), 0), pmc:K2_GetComponentToWorld())
			leftBaseRel.gameRel = kismet_math_library:ComposeTransforms(kismet_math_library:InvertTransform(boneInPmc), gripT)
		end
	end)
	if not ok then print("[bl4 two_handed] left base: " .. tostring(err)) end
end

local function onLeftHandSlider(field, value)
	local p = getWeaponParams(currentWeaponID)
	if p == nil then return end
	seedIKLeftHand(p)
	if not field:find("Ik", 1, true) then seedHandsLeftHand(p) end -- first Hands edit: start from the IK values
	p[field] = value
	saveParams()
	uevrUtils.setTimeout(1, function()          -- draw thread -> game thread
		applyLeftOffset()                        -- Hands path (no-op without a VR hand)
		if ikBase ~= nil then applyIKAccessory() end -- IK path: re-issue the attach with the new offsets
	end)
end
for _, s in ipairs(LH_SLIDERS) do
	configui.onUpdate(s.id, function(value) onLeftHandSlider(s.field, value) end)
	configui.onUpdate(s.ikId, function(value) onLeftHandSlider(s.ik, value) end)
end

-- ---------------------------------------------------------------------------------------------
-- IK mode: no VR hand to parent, so the left hand's IK TARGET is redirected. libs/ik.lua listens for
-- "on_accessory_attach"(hand, parentComponent, socketName, attachType, localOffset, localRot) and solves that hand
-- towards parent + offset (rotated into the parent's frame) until "on_accessory_detach"(hand).
-- ---------------------------------------------------------------------------------------------
local ikAccessoryAttached = false

local function weaponLocalOffset(weaponMesh, worldPoint, worldRot)
	local loc = weaponMesh:K2_GetComponentLocation()
	local rot = weaponMesh:K2_GetComponentRotation()
	local scale = weaponMesh.K2_GetComponentScale ~= nil and weaponMesh:K2_GetComponentScale() or uevrUtils.vector(1, 1, 1)
	local xf = kismet_math_library:MakeTransform(loc, rot, scale)
	local lp = kismet_math_library:InverseTransformLocation(xf, worldPoint)
	local lr = worldRot ~= nil and kismet_math_library:InverseTransformRotation(xf, worldRot) or nil
	return lp, lr
end

applyIKAccessory = function()
	if not active or ikBase == nil or not alive(ikBase.parent) then return end
	local o, r = leftHandOffset(getWeaponParams(currentWeaponID) or {}, true)
	-- the game's grip is exact: the grip-point trims do not apply to it
	if ikBase.game then o, r = { X = 0, Y = 0, Z = 0 }, { Pitch = 0, Yaw = 0, Roll = 0 } end
	pcall(function()
		uevrUtils.executeUEVRCallbacks("on_accessory_attach", Handed.Left, ikBase.parent, "", 0,
			{ X = ikBase.loc.X + o.X, Y = ikBase.loc.Y + o.Y, Z = ikBase.loc.Z + o.Z },
			{ Pitch = ikBase.rot.Pitch + r.Pitch, Yaw = ikBase.rot.Yaw + r.Yaw, Roll = ikBase.rot.Roll + r.Roll })
		ikAccessoryAttached = true
	end)
end

-- bl4_main.lua copies the game's left finger pose while this is true (the hand sits on the game's own grip)
local function updateGameLeftFlag()
	_G.bl4TwoHandGameLeft = active and ((leftBaseRel ~= nil and leftBaseRel.gameRel ~= nil) or (ikBase ~= nil and ikBase.game == true)) or false
end

local function attachIKLeftHand(weaponMesh, gripPoint)
	ikBase = nil
	local ok, err = pcall(function()
		local leftCtrl = controllers.getController(0, true)
		local ctrlLoc = alive(leftCtrl) and leftCtrl:K2_GetComponentLocation() or nil
		local ctrlRot = alive(leftCtrl) and leftCtrl:K2_GetComponentRotation() or nil
		local snapping = configui.getValue("bl4_th_snap_left_hand") ~= false and gripPoint ~= nil
		local target = (snapping and gripPoint) or ctrlLoc or gripPoint
		if target == nil then return end
		-- two-hand frame (placed at the un-pivoted gun by beginIKAim): offsets relative to it; else to the gun
		local frame = ikAim ~= nil and ikAim.frame or nil
		local lp, lr
		-- the game's left grip: the solver puts L_Hand at target * (end_bone_offset, end_bone_rotation), so the target
		-- on the frame (= the gun's own frame) is that offset's inverse composed with the grip - L_Hand lands on it
		-- exactly (bl4_vr_vehicle.lua pins the IK hands to the driver's bones the same way)
		local gripT = frame ~= nil and gameLeftGripT(weaponMesh) or nil
		local offsets = nil
		if gripT ~= nil and _G.bl4IKHandOffsets ~= nil then
			local okOff, o = pcall(_G.bl4IKHandOffsets)
			offsets = okOff and o or nil
		end
		if gripT ~= nil and offsets ~= nil and offsets.left ~= nil then
			local l = offsets.left
			local offT = kismet_math_library:MakeTransform(uevrUtils.vector(l.off[1], l.off[2], l.off[3]),
				uevrUtils.rotator(l.rot[1], l.rot[2], l.rot[3]), uevrUtils.vector(1, 1, 1))
			local ctrlRelT = kismet_math_library:ComposeTransforms(kismet_math_library:InvertTransform(offT), gripT)
			local t, r = ctrlRelT.Translation, kismet_math_library:Quat_Rotator(ctrlRelT.Rotation)
			ikBase = { weaponMesh = weaponMesh, parent = frame, game = true,
				loc = { X = t.X, Y = t.Y, Z = t.Z }, rot = { Pitch = r.Pitch, Yaw = r.Yaw, Roll = r.Roll } }
			return
		end
		if frame ~= nil then
			if snapping then
				-- The grip point comes from the real gun mesh, which rides the IK rig's hand bone ONE FRAME behind the
				-- controllers (the rig is solved in the post tick), while ikAim.baseT is this frame's pose built from the
				-- right controller. Mixing the two put one frame of travel into the offset: two-handing while moving or
				-- sprinting forwards left the hand further up the gun (xaero 2026-11-09). Taken in the gun's OWN space
				-- (point and gun from the same mesh) the lag cancels; the frame is the un-pivoted gun, so gun space =
				-- frame space.
				local gunT = kismet_math_library:MakeTransform(weaponMesh:K2_GetComponentLocation(),
					weaponMesh:K2_GetComponentRotation(), uevrUtils.vector(1, 1, 1)) -- unit scale, like the frame
				lp = kismet_math_library:InverseTransformLocation(gunT, gripPoint)
			else
				lp = kismet_math_library:InverseTransformLocation(ikAim.baseT, target) -- controller and base: both current
			end
			lr = ctrlRot ~= nil and kismet_math_library:InverseTransformRotation(ikAim.baseT, ctrlRot) or nil
		else
			lp, lr = weaponLocalOffset(weaponMesh, target, ctrlRot)
		end
		ikBase = {
			weaponMesh = weaponMesh,
			parent = frame or weaponMesh,
			loc = { X = lp.X, Y = lp.Y, Z = lp.Z },
			rot = lr ~= nil and { Pitch = lr.Pitch, Yaw = lr.Yaw, Roll = lr.Roll } or { Pitch = 0, Yaw = 0, Roll = 0 },
		}
	end)
	if not ok then print("[bl4 two_handed] IK attach failed: " .. tostring(err)) return end
	applyIKAccessory()
end

local function detachIKLeftHand()
	ikBase = nil
	if not ikAccessoryAttached then return end
	ikAccessoryAttached = false
	pcall(function() uevrUtils.executeUEVRCallbacks("on_accessory_detach", Handed.Left) end)
end

-- ---------------------------------------------------------------------------------------------
-- IK mode: weapon pivot (Hellraiser). The gun rides on the IK rig's right hand bone (bl4_vr_ik.lua), so nothing resets
-- it each frame: it is rebuilt each tick from its un-pivoted grip on the hand (_G.bl4IKWeaponBase) and turned about the
-- hand so the direction hand -> left controller keeps the gun-local direction it had at grab time. The right IK hand's
-- target goes onto the two-hand frame too, so both hands and the gun come out of one solve.
-- ---------------------------------------------------------------------------------------------
local ikRightAttached = false
local activeInIKMode = false

local function ikWeaponBase(weaponMesh, refreshOffsets)
	if _G.bl4IKWeaponBase == nil then return nil end
	local ok, baseT, pivot, ctrlT = pcall(_G.bl4IKWeaponBase, weaponMesh, refreshOffsets)
	if not ok or baseT == nil or pivot == nil then return nil end
	return baseT, pivot, ctrlT
end

local function detachIKRightHand()
	if not ikRightAttached then return end
	ikRightAttached = false
	pcall(function() uevrUtils.executeUEVRCallbacks("on_accessory_detach", Handed.Right) end)
end

-- Turns a pose (baseLoc, baseRot) about pivot so the direction pivot -> g (the left controller's grab-time point, on the
-- un-pivoted pose) becomes pivot -> l (the left controller now). Both hand modes: the gun keeps the grab-time relation
-- to the left controller instead of snapping its barrel onto the line between the controllers.
local function swingAbout(baseLoc, baseRot, pivot, g, l)
	local bx, by, bz = g.X - pivot.X, g.Y - pivot.Y, g.Z - pivot.Z -- hand -> grab point (un-pivoted gun)
	local dx, dy, dz = l.X - pivot.X, l.Y - pivot.Y, l.Z - pivot.Z -- hand -> left controller now
	local bl = math.sqrt(bx * bx + by * by + bz * bz)
	local dl = math.sqrt(dx * dx + dy * dy + dz * dz)
	if bl <= 1.0 or dl <= 1.0 then return baseLoc, baseRot end
	bx, by, bz = bx / bl, by / bl, bz / bl
	dx, dy, dz = dx / dl, dy / dl, dz / dl
	local cx, cy, cz = by * dz - bz * dy, bz * dx - bx * dz, bx * dy - by * dx -- b x d
	local s = math.sqrt(cx * cx + cy * cy + cz * cz)
	local c = bx * dx + by * dy + bz * dz
	if s <= 1e-5 then return baseLoc, baseRot end
	local r = kismet_math_library:RotatorFromAxisAndAngle(uevrUtils.vector(cx / s, cy / s, cz / s), math.deg(math.atan(s, c)))
	local newRot = kismet_math_library:ComposeRotators(baseRot, r) -- base, then the swing
	local off = kismet_math_library:GreaterGreater_VectorRotator(uevrUtils.vector(baseLoc.X - pivot.X, baseLoc.Y - pivot.Y, baseLoc.Z - pivot.Z), r)
	return { X = pivot.X + off.X, Y = pivot.Y + off.Y, Z = pivot.Z + off.Z }, newRot
end

local function beginIKAim(weaponMesh, leftHand)
	ikAim = nil
	local baseT, _, ctrlT = ikWeaponBase(weaponMesh, true)
	if baseT == nil or not alive(leftHand) then return end
	pcall(function()
		local lp = kismet_math_library:InverseTransformLocation(baseT, leftHand:K2_GetComponentLocation())
		ikAim = { gripLocal = { X = lp.X, Y = lp.Y, Z = lp.Z }, baseT = baseT }
	end)
	if ikAim == nil or ctrlT == nil then return end
	local frame = ensureTwoHandFrame()
	if frameUsable(frame) then
		local ok = pcall(function()
			local bt = baseT.Translation
			placeTwoHandFrame(frame, bt, kismet_math_library:Quat_Rotator(baseT.Rotation)) -- no swing at grab
		end)
		if ok then ikAim.frame = frame end
	end
	pcall(function()
		local rel = kismet_math_library:MakeRelativeTransform(ctrlT, baseT)
		local t = rel.Translation
		local r = kismet_math_library:Quat_Rotator(rel.Rotation)
		uevrUtils.executeUEVRCallbacks("on_accessory_attach", Handed.Right, ikAim.frame or weaponMesh, "", 0,
			{ X = t.X, Y = t.Y, Z = t.Z }, { Pitch = r.Pitch, Yaw = r.Yaw, Roll = r.Roll })
		ikRightAttached = true
	end)
end

-- true when the gun was placed here (false: not on the IK hand yet - the caller falls back to the Hands paths)
local function applyIKAim(weaponMesh, leftHand)
	if ikAim == nil then
		beginIKAim(weaponMesh, leftHand) -- gun handed to the IK hand after the grab
		if ikAim ~= nil and ikAim.frame ~= nil then pcall(function() attachIKLeftHand(weaponMesh, getGripPoint(weaponMesh)) end) updateGameLeftFlag() end
	end
	if ikAim == nil then return false end
	local baseT, pivot = ikWeaponBase(weaponMesh)
	if baseT == nil then return false end
	local bt = baseT.Translation
	local baseLoc = { X = bt.X, Y = bt.Y, Z = bt.Z }
	local baseRot = kismet_math_library:Quat_Rotator(baseT.Rotation)
	local g = kismet_math_library:TransformLocation(baseT, uevrUtils.vector(ikAim.gripLocal.X, ikAim.gripLocal.Y, ikAim.gripLocal.Z))
	local newLoc, newRot = swingAbout(baseLoc, baseRot, pivot, g, leftHand:K2_GetComponentLocation())
	-- weapon kick (bl4_vr_recoil.lua) on the gun's pose = the two-hand frame's: both IK hands and the gun follow it
	if _G.bl4KickWorld ~= nil then
		local ok, kLoc, kRot = pcall(_G.bl4KickWorld, newLoc, newRot)
		if ok and kLoc ~= nil then newLoc, newRot = kLoc, kRot end
	end
	if ikAim.frame ~= nil and ikAim.frame == twoHandFrame then
		placeTwoHandFrame(ikAim.frame, newLoc, newRot) -- the hands follow it; the gun follows the right hand bone
	else
		weaponMesh:K2_SetWorldLocationAndRotation(uevrUtils.vector(newLoc.X, newLoc.Y, newLoc.Z), newRot, false, getHitResult(), false)
	end
	return true
end

-- ---------------------------------------------------------------------------------------------
-- Pivot application (every view)
-- ---------------------------------------------------------------------------------------------
-- UObjectHook re-places the controllers (and a raw-controller gun) for EACH stereo view, so the pivot is re-applied
-- after every view's post-stereo. Each path starts from a fresh base (the right hand's saved rest transform, the gun's
-- UObjectHook placement, the IK base), so repeating it is idempotent.
local pivotArgs = nil -- { weaponMesh, rightHand, leftHand } while two-handing

-- Puts the right hand back on its rest transform with the engine setter, which updates the world transform at once.
-- uevrUtils.set_component_relative_transform writes the RelativeLocation / RelativeRotation fields only: the world
-- rotation applyTwoHandedRotation then reads was still last view's pivoted one, so the turn was added again every view
-- (MCP watch 2026-11-05: right hand yaw -25 -> -50 -> -75 deg, then the grip point left the release radius and the grab
-- re-armed every ~5 frames: the weapon "freaking out" and the left hand left offset at the last release).
local function restoreRightRest(pivot)
    pivot.pmc:K2_SetRelativeLocationAndRotation(uevrUtils.vector(pivot.loc.X, pivot.loc.Y, pivot.loc.Z),
        uevrUtils.rotator(pivot.rot.Pitch, pivot.rot.Yaw, pivot.rot.Roll), false, getHitResult(), true)
end

local function applyPivot()
	local a = pivotArgs
	if a == nil or not alive(a.weaponMesh) then return end
	if ikMode() and applyIKAim(a.weaponMesh, a.leftHand) then return end
	-- weapon kick (bl4_vr_recoil.lua, "Recoil while two-handing") goes on top of the pivot; the left hand rides the gun
	if rightPivot ~= nil and alive(rightPivot.pmc) then
		-- Hands mode: turn the right VR hand (the gun is its child) from its rest transform, about its wrist bone, as the
		-- IK path turns the gun about the IK hand target (swingAbout)
		restoreRightRest(rightPivot)
		local pmc = rightPivot.pmc
		local gl = rightPivot.gripLocal
		if gl ~= nil then
			local pivot = rightPivot.wristBone ~= nil and pmc:GetSocketLocation(rightPivot.wristBone) or a.rightHand:K2_GetComponentLocation()
			local g = kismet_math_library:TransformLocation(pmc:K2_GetComponentToWorld(), uevrUtils.vector(gl.X, gl.Y, gl.Z))
			local newLoc, newRot = swingAbout(pmc:K2_GetComponentLocation(), pmc:K2_GetComponentRotation(), pivot, g, a.leftHand:K2_GetComponentLocation())
			pmc:K2_SetWorldLocationAndRotation(uevrUtils.vector(newLoc.X, newLoc.Y, newLoc.Z), newRot, false, getHitResult(), true)
		else
			twoHandedAiming.applyTwoHandedRotation(pmc, a.rightHand, a.leftHand)
		end
		if _G.bl4KickParentOfGun ~= nil then pcall(_G.bl4KickParentOfGun, rightPivot.pmc, a.weaponMesh) end
	else
		twoHandedAiming.applyTwoHandedRotation(a.weaponMesh, a.rightHand, a.leftHand)
		if _G.bl4KickComponentWorld ~= nil then pcall(_G.bl4KickComponentWorld, a.weaponMesh) end
	end
end

-- ---------------------------------------------------------------------------------------------
-- Activation
-- ---------------------------------------------------------------------------------------------
local function activate(weaponMesh, gripPoint)
	if active then return end
	active = true
	-- a kick in progress has the right hand moved: put it back before its rest transform is taken
	if _G.bl4RecoilRestoreHand ~= nil then pcall(_G.bl4RecoilRestoreHand) end
	activeInIKMode = ikMode()
	-- IK: let the left arm reach the foregrip (bl4_vr_ik.lua _G.bl4SetIKLeftArmStretch); restored in deactivate
	if activeInIKMode and configui.getValue("bl4_th_ik_stretch") ~= false and _G.bl4SetIKLeftArmStretch ~= nil then
		pcall(_G.bl4SetIKLeftArmStretch, true, 0.98, configui.getValue("bl4_th_ik_stretch_max") or 1.35)
	end
	rightPivot = nil
	local animName = attachments.getCurrentGripAnimation(Handed.Right)
	if activeInIKMode then
		beginIKAim(weaponMesh, controllers.getController(0, true)) -- first: places the two-hand frame
		attachIKLeftHand(weaponMesh, gripPoint)
	else
		-- the gun hangs on the right VR hand: pivot that hand (see header); remember its rest transform
		local rightPmc = hands.getHandComponent(Handed.Right)
		local gunOnRightHand = false
		pcall(function() gunOnRightHand = alive(rightPmc) and weaponMesh.AttachParent ~= nil and weaponMesh.AttachParent:get_address() == rightPmc:get_address() end)
		if gunOnRightHand then
			pcall(function()
				local loc, rot = relativeOf(rightPmc)
				rightPivot = { pmc = rightPmc, loc = loc, rot = rot }
				-- the left controller's grab point in the right hand's space (the swing keeps it pointing at the controller)
				local lp = kismet_math_library:InverseTransformLocation(rightPmc:K2_GetComponentToWorld(),
					controllers.getController(0, true):K2_GetComponentLocation())
				rightPivot.gripLocal = { X = lp.X, Y = lp.Y, Z = lp.Z }
				local wrist = uevrUtils.fname_from_string("R_Hand")
				if rightPmc:DoesSocketExist(wrist) then rightPivot.wristBone = wrist end
			end)
		end
		-- attached where it is (KeepWorld); captureLeftBase / applyLeftOffset then put its wrist on the grip point
		local preLoc, preRot = parentHandToWeapon(Handed.Left, weaponMesh, nil)
		captureLeftBase(weaponMesh, configui.getValue("bl4_th_snap_left_hand") ~= false and gripPoint or nil)
		applyLeftOffset()
		-- the final transform is now set: glide to it from where the hand was
		local pmc = hands.getHandComponent(Handed.Left)
		if preLoc ~= nil and alive(pmc) then
			pcall(function()
				local eLoc, eRot = relativeOf(pmc)
				startLeftGlide(pmc, preLoc, preRot, eLoc, eRot)
			end)
		end
	end
	-- left hand takes the weapon's left grip pose (left_grip_weapon_<animation>)
	pcall(function() hands.setHoldingAttachment(Handed.Left, (type(animName) == "string" and animName) or true) end)
	pcall(function() if hands.setInputLocked then hands.setInputLocked(Handed.Left, true) end end)
	_G.isTwoHandingActive = true
	updateGameLeftFlag()
	status(_G.bl4TwoHandGameLeft and "two-handing (game's left grip)" or "two-handing")
	scheduleLeftPose()
end

local function deactivate(reason)
	if not active then return end
	active = false
	_G.bl4TwoHandGameLeft = false -- bl4_main.lua hands the left fingers back on its next tick
	leftBaseRel = nil
	ikAim = nil -- bl4_vr_ik.lua re-asserts the un-pivoted grip once _G.isTwoHandingActive is false
	pivotArgs = nil
	if rightPivot ~= nil and alive(rightPivot.pmc) then
		pcall(function() restoreRightRest(rightPivot) end)
	end
	rightPivot = nil
	if activeInIKMode and _G.bl4SetIKLeftArmStretch ~= nil then pcall(_G.bl4SetIKLeftArmStretch, false) end
	detachIKRightHand()
	detachIKLeftHand()
	restoreHand(Handed.Left)
	pcall(function() if hands.setInputLocked then hands.setInputLocked(Handed.Left, false) end end)
	pcall(function() hands.setHoldingAttachment(Handed.Left, nil) end)
	_G.isTwoHandingActive = false
	status("idle (" .. tostring(reason) .. ")")
end

-- suppress the left hand's mesh-driven animation while we own it
hands.registerIsAnimatingFromMeshCallback(function(hand)
	if hand == Handed.Left and active then return false end
	return nil
end)

-- weapon (attachment) changed on the right hand -> release before the mesh goes away
uevrUtils.registerUEVRCallback("attachment_grip_changed", function(id, gripHand, attachment)
	if gripHand == Handed.Right then
		deactivate("weapon changed")
		currentWeaponID = (id ~= nil and id ~= "") and id or nil
		configui.setLabel("bl4_th_weapon_label", "Weapon: " .. tostring(currentWeaponID or "none"))
		loadWeaponParamsToUI(currentWeaponID)
		updatePoseLabel()
	end
end)

uevrUtils.registerPreLevelChangeCallback(function(level)
	active = false
	-- the IK accessory table in libs/ik.lua survives the rig rebuild: release the hands or the new rig would keep
	-- targeting the old world's weapon / frame
	if ikAccessoryAttached then pcall(function() uevrUtils.executeUEVRCallbacks("on_accessory_detach", Handed.Left) end) end
	ikAccessoryAttached = false
	if ikRightAttached then pcall(function() uevrUtils.executeUEVRCallbacks("on_accessory_detach", Handed.Right) end) end
	ikRightAttached = false
	ikBase = nil
	ikAim = nil
	twoHandFrame, twoHandFramePawn = nil, nil -- went with the old world
	pivotArgs = nil
	rightPivot = nil
	snapshots = {}
	leftGlide = nil
	pcall(function() if hands.setInputLocked then hands.setInputLocked(Handed.Left, false) end end)
	marker = nil
	currentWeaponID = nil
	nearGrip = false
	_G.isTwoHandingActive = false
end)

-- ---------------------------------------------------------------------------------------------
-- Input: track the raw grab button, hide it from the game near / while two-handing
-- ---------------------------------------------------------------------------------------------
uevrUtils.registerOnPreInputGetStateCallback(function(retval, user_index, state)
	if user_index ~= 0 then return end
	local useTrigger = configui.getValue("bl4_th_grab_button") == GRAB_TRIGGER
	if useTrigger then
		grabDown = (state.Gamepad.bLeftTrigger or 0) > 100
	else
		grabDown = uevrUtils.isButtonPressed(state, XINPUT_GAMEPAD_LEFT_SHOULDER)
	end
	-- any left button edge while two-handing triggers hand-animation lerps: re-assert our pose after them
	local leftButtons = (grabDown and 1 or 0) + (uevrUtils.isButtonPressed(state, XINPUT_GAMEPAD_LEFT_SHOULDER) and 2 or 0) + (((state.Gamepad.bLeftTrigger or 0) > 100) and 4 or 0)
	if active and leftButtons ~= lastLeftButtons then scheduleLeftPose() end
	lastLeftButtons = leftButtons
	if (active or nearGrip) and configui.getValue("bl4_th_suppress_grab") ~= false then
		if useTrigger then
			state.Gamepad.bLeftTrigger = 0
		else
			uevrUtils.unpressButton(state, XINPUT_GAMEPAD_LEFT_SHOULDER)
		end
	end
end, 5) -- after hands_animation (10) so the left hand still animates as "grip held"; before remap (0) and the game

-- ---------------------------------------------------------------------------------------------
-- Per-tick body (once per tick from the post-stereo callback, where controller and weapon transforms are valid)
-- ---------------------------------------------------------------------------------------------
uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
	updateLeftGlide()
	ranThisTick = false
end)

local function tick()
	if configui.getValue("bl4_th_enabled") == false then
		if active then deactivate("disabled") end
		nearGrip = false
		updateMarker(nil, nil)
		return
	end

	local weaponMesh = attachments.getCurrentGrippedAttachment(Handed.Right)
	local twoHanded = alive(weaponMesh) and attachments.isActiveAttachmentTwoHanded(Handed.Right) == true
	if currentWeaponID == nil and alive(weaponMesh) then
		-- script loaded with a weapon already attached: no grip-changed event yet
		local id = attachments.getActiveAttachmentID(Handed.Right)
		if id ~= nil and id ~= "" then
			currentWeaponID = id
			configui.setLabel("bl4_th_weapon_label", "Weapon: " .. tostring(id))
			loadWeaponParamsToUI(id)
			updatePoseLabel()
		end
	end
	-- Hands <-> IK switched mid-grab: release, so no IK accessory target outlives the grab (re-grab in the new mode)
	if active and activeInIKMode ~= ikMode() then deactivate("hands mode changed") end
	if not twoHanded then
		if active then deactivate("not two-handed") end
		nearGrip = false
		updateMarker(nil, nil)
		return
	end

	-- IK mode: have the two-hand frame ready before a grab (ik.lua needs it known to UObjectHook)
	if ikMode() then pcall(ensureTwoHandFrame) end

	local rightHand = controllers.getController(1, true)
	local leftHand = controllers.getController(0, true)
	if not alive(rightHand) or not alive(leftHand) then nearGrip = false return end

	local ok, gripPoint = pcall(getGripPoint, weaponMesh)
	if not ok or gripPoint == nil then nearGrip = false return end
	updateMarker(weaponMesh, gripPoint)

	local leftPos = leftHand:K2_GetComponentLocation()
	local dist = distance(leftPos, gripPoint)
	local force = configui.getValue("bl4_th_force") == true
	nearGrip = dist <= (configui.getValue("bl4_th_grab_radius") or 14)

	if not active then
		if force or (grabDown and nearGrip) then
			activate(weaponMesh, gripPoint)
		else
			status(string.format("ready (%.0f cm from grip)", dist))
		end
	else
		local release = false
		if not force then
			if not grabDown then release = true end
			if dist > (configui.getValue("bl4_th_release_radius") or 35) then release = true end
		end
		if release then
			deactivate(grabDown and "too far" or "grab released")
		else
			pivotArgs = { weaponMesh = weaponMesh, rightHand = rightHand, leftHand = leftHand }
			applyPivot()
			-- safety net: re-assert the captured pose once a second (hand animation lerps can overwrite it)
			poseReapplyTimer = (poseReapplyTimer or 0) + 1
			if poseReapplyTimer >= 60 then poseReapplyTimer = 0; applyLeftPose() end
		end
	end
end

uevrUtils.registerPostCalculateStereoViewCallback(function(device, view_index, world_to_meters, position, rotation, is_double)
	if not vr.is_hmd_active() then return end
	if ranThisTick then
		-- later views this frame: UObjectHook has re-placed the controllers again, re-apply the pivot
		if active and pivotArgs ~= nil then
			local ok, err = pcall(applyPivot)
			if not ok then print("[bl4 two_handed] pivot: " .. tostring(err)) end
		end
		return
	end
	ranThisTick = true
	local ok, err = pcall(tick)
	if not ok then print("[bl4 two_handed] " .. tostring(err)) end
end)

print("[bl4 two_handed] loaded")
