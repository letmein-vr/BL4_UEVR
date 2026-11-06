-- Hands mode for Borderlands 4: VR hands (libs/hands.lua, cut from FirstPersonArms) OR the full-arm IK rig (libs/ik.lua),
-- ported from Hellraiser (hr_hands.lua mode switch, uevrmenus.lua IK setup, weaponhook.lua gun-on-IK-hand).
--
-- They are mutually exclusive: both register the same animation ids (left_arms / right_arms) with hands_animation, so
-- whichever registers last owns the finger poses. Mode switching tears one down and lets the other auto-create.
--
-- IK rig source: FirstPersonArms through the "Custom" mesh hook getCustomIKComponent (FirstPersonArms is not a pawn
-- property). The rig copies are made by uevrUtils.createPoseableMeshFromSkeletalMesh, so bl4_main.lua's wrapper swaps
-- them to the drawable gestalt arms part and puts them on the foreground layer, as for the VR hands.
-- Configure the rig in the IK dev panel (developer mode): mesh "Custom", right / left solver end bones R_Hand / L_Hand;
-- saved to data/ik_parameters.json.
--
-- Named bl4_vr_* so it loads after bl4_main.lua (developer mode, _G.bl4 helpers) and before zz_bl4_vr_panel.lua.

local uevrUtils = require('libs/uevr_utils')
local configui = require('libs/configui')
local controllers = require('libs/controllers')
local hands = require('libs/hands')
local attachments = require('libs/attachments')
local ik = require('libs/ik')

local HANDS_MODE_HANDS = 1
local HANDS_MODE_IK    = 2

-- ik.lua auto-creates by default as soon as its profile has a mesh; the mode decides (applied once the panel loaded)
ik.setAutoCreateArms(false)

-- BL4's capsule chases the control yaw with a lag (MCP 2026-10-30: capsule 169.8 vs control 105.3 mid-turn, equal at
-- rest), so a Pawn Root rig trailed the view on fast stick turns (right shoulder swung into view). With UEVR head aim
-- the control yaw is the HMD yaw anyway: take the rig yaw straight from the HMD.
ik.setLockMeshYawToHmd(true)

_G.BL4_SECTIONS = _G.BL4_SECTIONS or {}
table.insert(_G.BL4_SECTIONS, { order = 1, label = "Hands", layout = {
	{ widgetType = "combo", id = "bl4_hands_mode", label = "Hands", initialValue = HANDS_MODE_HANDS, selections = { "Hands", "IK Arms" } },
	{ widgetType = "text", id = "bl4_hands_mode_status", label = "Status: -" },
	{ widgetType = "text", label = "IK rig setup: IK dev panel -> mesh \"Custom\", end bones R_Hand / L_Hand (data/ik_parameters.json)" },
}})

local function log(text)
	pcall(function() uevrUtils.print("[bl4 ik] " .. tostring(text), LogLevel.Info) end)
end

local function alive(obj)
	if obj == nil then return false end
	local ok, r = pcall(function() return obj:get_full_name() ~= nil end)
	return ok and r
end

local function getHandsMode()
	return configui.getValue("bl4_hands_mode") == HANDS_MODE_IK and HANDS_MODE_IK or HANDS_MODE_HANDS
end
_G.getHandsMode = getHandsMode -- same global as Hellraiser: two-handing checks it (2 = IK)

local function getArms()
	local pawn = _G.bl4 ~= nil and _G.bl4.getPlayerCharacter() or nil
	return pawn ~= nil and _G.bl4.getFirstPersonArms(pawn) or nil
end

-- libs/ik.lua "Custom" mesh hooks (globals)
function getCustomIKComponent(rigId)
	local arms = getArms()
	if arms == nil then return {} end
	return { { instance = arms, animation = "Arms" } }
end

-- animation source when the IK profile's animation mesh is "Custom": the game's own arms (reload / melee montages)
function getCustomAnimationIKComponent(rigId)
	return getArms()
end

-- rig meshes: no shadows; a fresh rig starts in the open pose until an input edge, so re-assert the weapon poses
ik.registerOnMeshCreatedCallback(function(meshList, rig)
	for _, mesh in ipairs(meshList or {}) do
		pcall(function() mesh:SetCastShadow(false) end)
	end
	for _, ms in ipairs({ 300, 1200 }) do
		uevrUtils.setTimeout(ms, function()
			pcall(function()
				hands.updateAnimationState(Handed.Right)
				hands.updateAnimationState(Handed.Left)
			end)
		end)
	end
end)
ik.init(uevrUtils.getDeveloperMode() == true, LogLevel.Warning) -- developer mode: IK dev panel for tuning

local function applyHandsMode()
	if getHandsMode() == HANDS_MODE_IK then
		-- drop the Hands-mode grips first (the library re-grips onto the controllers next poll). Left in place, the entry
		-- keyed under the destroyed VR hand still says "right hand holds <that gun>", and getCurrentGrippedAttachment
		-- returns whichever right-hand entry pairs() meets first: IK kept re-seating the OLD gun on every swap while the
		-- new one stayed on the hidden game arms, rotated, until the stale entry happened to go (log 2026-11-05 01:36-01:37)
		pcall(function() attachments.detachGripAttachments(Handed.Right) end)
		pcall(function() attachments.detachGripAttachments(Handed.Left) end)
		hands.setAutoCreateHands(false)
		hands.destroyHands()
		-- the solvers need the motion controllers; in IK mode nothing else creates them
		controllers.createController(0)
		controllers.createController(1)
		controllers.createController(2)
		ik.setAutoCreateArms(true) -- 1 s auto-create from ik_parameters.json + hands_parameters.json
		configui.setLabel("bl4_hands_mode_status", "Status: IK Arms")
		log("IK mode: VR hands off, rig enabled")
	else
		ik.setAutoCreateArms(false)
		if ik.exists() then ik.destroyAll() end
		hands.setAutoCreateHands(true) -- libs/hands.lua rebuilds from hands_parameters.json
		configui.setLabel("bl4_hands_mode_status", "Status: Hands")
		log("Hands mode: rig off, VR hands enabled")
	end
end

-- configui callbacks run on the draw thread; build / destroy on the game thread
configui.onUpdate("bl4_hands_mode", function(value) uevrUtils.setTimeout(1, applyHandsMode) end)
uevrUtils.setTimeout(1000, applyHandsMode) -- after the panel loaded its saved values

-- Rig watchdog (2026-10-30): ik.lua auto-creates once per second while no rig exists. Before the player character's
-- FirstPersonArms exists (game load), getCustomIKComponent returns {} and ik.lua still builds a rig - with no mesh
-- ("setActive: Missing or invalid mesh") - which then counts as existing, so it is never rebuilt: no IK arms and the gun
-- left on the raw controller (90 deg off). So in IK mode auto-create is only allowed once the arms exist, and a rig
-- without a live mesh (built too early, or its arms copy died with the pawn) is dropped so it rebuilds.
uevrUtils.setInterval(500, function()
	if getHandsMode() ~= HANDS_MODE_IK then return end
	local armsReady = alive(getArms())
	ik.setAutoCreateArms(armsReady)
	if armsReady and ik.exists() and not alive(ik.getCurrentMesh(1)) then
		log("IK rig has no mesh (built before the arms existed); rebuilding")
		ik.destroyAll()
	end
end)

-- ---------------------------------------------------------------------------------------------
-- IK mode: the held weapon rides on the IK hand, not on the controller (Hellraiser weaponhook.lua, 2026-10-08)
-- ---------------------------------------------------------------------------------------------
-- With the gun on the controller and the IK hand only solved toward the controller, the two come apart beyond arm reach
-- and the hand trails the gun (the rig solves from the previous frame's controller pose). In IK mode bl4_main.lua's grip
-- callback has no VR hand to parent to, so the attachments library puts the gun on the raw right controller at its
-- Hands-tuned grip; here the gun's transform relative to the right-hand IK TARGET (what libs/ik.lua solves the hand
-- bone to: controller loc + rotate(end_bone_offset, controller rot), rot = ComposeRotators(end_bone_rotation,
-- controller rot)) is taken, and the gun is moved off UObjectHook onto the rig's hand bone with that relative
-- transform. No new per-weapon offsets. The attachments library leaves it there (its raw-controller attach returns
-- early for an attachment it already holds). Re-asserted each tick (two-handing rotates the gun); cached per weapon.
local ikHeld = nil    -- { mesh = weapon component, rig = rig mesh it is parented to }
local ikRelative = {} -- weapon component address -> { loc = {X,Y,Z}, rot = {Pitch,Yaw,Roll} }
local ikTransferNotBefore = 0
local ikPendingKey = nil
local IK_TRANSFER_SETTLE_S = 0.3
local ikRanThisTick = false
uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta) ikRanThisTick = false end)

-- The right-hand solver (end_control_type 1) of the active IK profile: end bone, end_bone_offset, end_bone_rotation.
-- Read once from data/ik_parameters.json, then kept current from the IK dev panel's "on_ik_config_param_change" events
-- (key {"solvers", solverId, field}), so moving the hand offsets in the panel re-seats the gun at once instead of
-- dragging it along (the gun is a child of the hand bone).
local solverCache = nil -- { id, bone, offset = {x,y,z}, rotation = {p,y,r}, version }
local solverVersion = 0

local function loadRightHandSolver()
	local cache = { id = nil, bone = "R_Hand", offset = { 0, 0, 0 }, rotation = { 0, 0, 0 } }
	pcall(function()
		local params = json.load_file("ik_parameters.json")
		local profileName = params and params["_profileState"] and params["_profileState"]["currentEditingProfile"] or "default"
		local profile = params and (params[profileName] or params["default"])
		for id, solver in pairs(profile and profile["solvers"] or {}) do
			if solver["end_control_type"] == ik.ControllerType.RIGHT_CONTROLLER then
				cache.id = id
				cache.bone = (solver["end_bone"] ~= nil and solver["end_bone"] ~= "") and solver["end_bone"] or cache.bone
				cache.offset = solver["end_bone_offset"] or cache.offset
				cache.rotation = solver["end_bone_rotation"] or cache.rotation
			elseif solver["end_control_type"] == ik.ControllerType.LEFT_CONTROLLER then
				cache.left = { id = id, allowStretch = solver["allow_stretch"] == true,
					startStretchRatio = solver["start_stretch_ratio"] or 0.0, maxStretchScale = solver["max_stretch_scale"] or 0.0,
					offset = solver["end_bone_offset"] or { 0, 0, 0 }, rotation = solver["end_bone_rotation"] or { 0, 0, 0 } }
			end
		end
	end)
	solverVersion = solverVersion + 1
	cache.version = solverVersion
	solverCache = cache
end

-- Two-handing (bl4_vr_two_handed.lua): the foregrip is often beyond the rig's left arm (BL4 arm 22.3 + 25.4 = 47.7 cm,
-- MCP 2026-10-31). With stretch off the IK stops at full extension on the line shoulder -> grip, so the hand slid along
-- the gun as it turned (measured: ~0.6 cm per frame in the gun's own space). While two-handing the left solver may
-- stretch to reach; on release its saved settings (ik_parameters.json) come back. Runtime only, never saved.
_G.bl4SetIKLeftArmStretch = function(enabled, startRatio, maxScale)
	if solverCache == nil then loadRightHandSolver() end
	local left = solverCache.left
	if left == nil or left.id == nil then return end
	if enabled then
		ik.setSolverRuntimeParameter(left.id, "allow_stretch", true)
		ik.setSolverRuntimeParameter(left.id, "start_stretch_ratio", startRatio)
		ik.setSolverRuntimeParameter(left.id, "max_stretch_scale", maxScale)
	else
		ik.setSolverRuntimeParameter(left.id, "allow_stretch", left.allowStretch)
		ik.setSolverRuntimeParameter(left.id, "start_stretch_ratio", left.startStretchRatio)
		ik.setSolverRuntimeParameter(left.id, "max_stretch_scale", left.maxStretchScale)
	end
end

local function rightHandSolver()
	if solverCache == nil then loadRightHandSolver() end
	return solverCache.bone, solverCache.offset, solverCache.rotation
end

-- panel values arrive as arrays, UE vectors / rotators or drag_float3 Vector3f (lowercase x/y/z)
local function toArray3(value, a, b, c)
	local out = nil
	pcall(function()
		if type(value) == "table" and value[1] ~= nil then out = { value[1], value[2], value[3] }
		elseif value ~= nil and value[a] ~= nil then out = { value[a], value[b], value[c] } end
	end)
	if out == nil then
		pcall(function() if value.x ~= nil then out = { value.x, value.y, value.z } end end)
	end
	return out
end

uevrUtils.registerUEVRCallback("on_ik_config_param_change", function(key, value)
	if type(key) ~= "table" then return end
	local field = key[#key]
	local inSolvers = false
	for _, part in ipairs(key) do if part == "solvers" then inSolvers = true end end
	if not inSolvers then return end
	local solverId = key[#key - 1]
	if solverCache ~= nil and solverId == solverCache.id and (field == "end_bone_offset" or field == "end_bone_rotation") then
		local v = field == "end_bone_offset" and toArray3(value, "X", "Y", "Z") or toArray3(value, "Pitch", "Yaw", "Roll")
		if v ~= nil then
			if field == "end_bone_offset" then solverCache.offset = v else solverCache.rotation = v end
			solverVersion = solverVersion + 1
			solverCache.version = solverVersion
			return
		end
	end
	if field == "end_bone_offset" or field == "end_bone_rotation" or field == "end_bone" or field == "end_control_type" then
		uevrUtils.setTimeout(1500, loadRightHandSolver) -- other solver / unknown value shape: re-read once it is saved
	end
end)

-- Per-weapon hand offsets (attachments panel "Hand Position Offset" / "Hand Rotation Offset"), as libs/hands.lua applies
-- them in Hands mode: location added to the hand's controller-space position, rotation composed before it - only the
-- hand moves, the gun keeps its grip. Here they go on top of the right solver's end_bone_offset / end_bone_rotation as a
-- runtime-only solver override (ik_parameters.json keeps the panel values).
local handOffsetVersion = 0
attachments.registerHandOffsetChangeCallback(function(id) handOffsetVersion = handOffsetVersion + 1 end)

local function activeRightAttachmentID()
	local id = nil
	pcall(function() id = attachments.getActiveAttachmentID(Handed.Right) end)
	return (id ~= nil and id ~= "") and id or nil
end

-- effective right-hand target offsets (controller space): solver offsets + the held weapon's hand offsets
local function rightHandTarget()
	local _, off, rotOff = rightHandSolver()
	local id = activeRightAttachmentID()
	local loc, rot = nil, nil
	if id ~= nil then pcall(function() loc, rot = attachments.getAttachmentHandOffset(id) end) end
	if loc == nil and rot == nil then return off, rotOff end
	loc, rot = loc or { 0, 0, 0 }, rot or { 0, 0, 0 }
	local r = kismet_math_library:ComposeRotators(uevrUtils.rotator(rot[1], rot[2], rot[3]), uevrUtils.rotator(rotOff[1], rotOff[2], rotOff[3]))
	return { off[1] + loc[1], off[2] + loc[2], off[3] + loc[3] }, { r.Pitch, r.Yaw, r.Roll }
end

-- The hand-bone offsets each solver applies to its target (controller space): right = what applyRightHandTarget sets,
-- left = the left solver's saved values. bl4_vr_vehicle.lua inverts them to pin the IK hands exactly onto bones.
-- Returns { right = { off = {x,y,z}, rot = {p,y,r} }, left = {...} }.
_G.bl4IKHandOffsets = function()
	local _, rOff, rRot = rightHandSolver()
	local off, rot = rightHandTarget()
	local left = solverCache.left or {}
	return {
		right = { off = off or rOff, rot = rot or rRot },
		left = { off = left.offset or { 0, 0, 0 }, rot = left.rotation or { 0, 0, 0 } },
	}
end

-- what the effective target depends on; a change re-applies it to the rig and re-seats the gun
local function targetVersion()
	return tostring(solverVersion) .. ":" .. tostring(handOffsetVersion) .. ":" .. tostring(activeRightAttachmentID())
end

-- Weapon kick (bl4_vr_recoil.lua): a transform in the GUN's own frame, { loc = {X,Y,Z}, rot = {Pitch,Yaw,Roll} }, or
-- nil. The gun rides the hand bone, so the hand target is moved such that the gun ends up kicked by it:
-- gun = rel * target  ->  rel * target' = kick * rel * target  ->  target' = rel^-1 * kick * rel * target.
-- The gun's bone-relative transform (rel) is NOT recomputed from the kicked target, so the gun moves with the hand.
local ikKick, ikKickSerial = nil, 0
_G.bl4SetIKHandKick = function(kick)
	if kick == nil and ikKick == nil then return end
	ikKick = kick
	ikKickSerial = ikKickSerial + 1
end

local function makeT(loc, rot)
	return kismet_math_library:MakeTransform(uevrUtils.vector(loc.X, loc.Y, loc.Z), uevrUtils.rotator(rot.Pitch, rot.Yaw, rot.Roll), uevrUtils.vector(1, 1, 1))
end

local function kickedTarget(off, rot, rel)
	local targetT = kismet_math_library:MakeTransform(uevrUtils.vector(off[1], off[2], off[3]), uevrUtils.rotator(rot[1], rot[2], rot[3]), uevrUtils.vector(1, 1, 1))
	local relT = makeT(rel.loc, rel.rot)
	local kickT = makeT(ikKick.loc, ikKick.rot)
	local t = kismet_math_library:ComposeTransforms(kismet_math_library:ComposeTransforms(
		kismet_math_library:ComposeTransforms(kismet_math_library:InvertTransform(relT), kickT), relT), targetT)
	local l, r = t.Translation, kismet_math_library:Quat_Rotator(t.Rotation)
	return { l.X, l.Y, l.Z }, { r.Pitch, r.Yaw, r.Roll }
end

local appliedTargetKey = nil
local function applyRightHandTarget(rig)
	rightHandSolver()
	if solverCache.id == nil then return end
	local rel = (ikKick ~= nil and ikHeld ~= nil and alive(ikHeld.mesh)) and ikRelative[ikHeld.mesh:get_address()] or nil
	local key = tostring(rig:get_address()) .. "|" .. targetVersion() .. (rel ~= nil and ("|kick" .. ikKickSerial) or "")
	if key == appliedTargetKey then return end
	local off, rot = rightHandTarget()
	if rel ~= nil then
		local ok, kOff, kRot = pcall(kickedTarget, off, rot, rel)
		if ok then off, rot = kOff, kRot end
	end
	ik.setSolverRuntimeParameter(solverCache.id, "end_bone_offset", off)
	ik.setSolverRuntimeParameter(solverCache.id, "end_bone_rotation", rot)
	appliedTargetKey = key
end

-- the right-hand IK target from this frame's controller pose
local function rightHandTargetTransform(off, rotOff)
	local ctrl = controllers.getController(Handed.Right, true)
	if not alive(ctrl) then return nil end
	local cl, cr = ctrl:K2_GetComponentLocation(), ctrl:K2_GetComponentRotation()
	local offWS = kismet_math_library:GreaterGreater_VectorRotator(uevrUtils.vector(off[1], off[2], off[3]), cr)
	local handLoc = uevrUtils.vector(cl.X + offWS.X, cl.Y + offWS.Y, cl.Z + offWS.Z)
	local handRot = kismet_math_library:ComposeRotators(uevrUtils.rotator(rotOff[1], rotOff[2], rotOff[3]), cr)
	return kismet_math_library:MakeTransform(handLoc, handRot, uevrUtils.vector(1, 1, 1)), { X = handLoc.X, Y = handLoc.Y, Z = handLoc.Z }
end

-- The gun's controller-relative grip is rebuilt from its attachment offsets the way Hands mode applies them (gun on the
-- VR hand, which sits on the controller with an identity relative transform: IgnoreRelativeOffset, no base offset), NOT
-- read from where the attachments library put it in IK mode: there it goes on the raw controller, whose rotation path
-- adds +90 yaw for UEVR's controller frame - copied onto the IK hand that made every gun 90 deg off (2026-10-30).
-- Worked entirely in controller space: target = (end_bone_offset, end_bone_rotation) and grip = attachment offsets, both
-- relative to the controller, so gun-on-bone = grip relative to target. Same result as the world-space version (the
-- controller cancels out) with no controller pose needed. Tagged with the solver version it was made from.
local function computeIKRelative(mesh)
	-- game grip (bl4_main.lua, option on): the game's own hand -> gun offset, measured on FirstPersonArms, is already
	-- relative to the R_Hand bone the gun rides here. Until it is measured (equip montage) the Attachments offsets below.
	local grip = _G.bl4 ~= nil and _G.bl4.getGameGrip ~= nil and _G.bl4.getGameGrip(mesh) or nil
	if grip ~= nil then
		return { loc = { X = grip.loc.X, Y = grip.loc.Y, Z = grip.loc.Z },
			rot = { Pitch = grip.rot.Pitch, Yaw = grip.rot.Yaw, Roll = grip.rot.Roll }, version = targetVersion(), at = os.clock() }
	end
	local result = nil
	pcall(function()
		local off, rotOff = rightHandTarget()
		local targetT = kismet_math_library:MakeTransform(uevrUtils.vector(off[1], off[2], off[3]), uevrUtils.rotator(rotOff[1], rotOff[2], rotOff[3]), uevrUtils.vector(1, 1, 1))
		local gripLoc, gripRot = attachments.getAttachmentOffset(mesh)
		local gripT = kismet_math_library:MakeTransform(gripLoc, gripRot, uevrUtils.vector(1, 1, 1))
		local rel = kismet_math_library:MakeRelativeTransform(gripT, targetT)
		local t = rel.Translation
		local r = kismet_math_library:Quat_Rotator(rel.Rotation)
		result = { loc = { X = t.X, Y = t.Y, Z = t.Z }, rot = { Pitch = r.Pitch, Yaw = r.Yaw, Roll = r.Roll },
			version = targetVersion(), at = os.clock() }
	end)
	return result
end

local REL_REFRESH_S = 1.0 -- also picks up attachment offset edits made in the Attachments panel

local function applyIKRelative(mesh, rel)
	uevrUtils.set_component_relative_transform(mesh, rel.loc, rel.rot, { X = 1, Y = 1, Z = 1 })
end

local function parentToIKHand(mesh, rig, rel)
	local bone = rightHandSolver()
	pcall(function() UEVR_UObjectHook.remove_motion_controller_state(mesh) end)
	local ok = pcall(function() mesh:K2_AttachTo(rig, uevrUtils.fname_from_string(bone), 0, false) end) -- 0 = KeepRelative
	if ok then
		applyIKRelative(mesh, rel)
		ikHeld = { mesh = mesh, rig = rig }
		log("weapon parented to the IK hand (" .. bone .. "): " .. mesh:get_full_name())
	end
	return ok
end

-- leaving IK (or the weapon went away): give the gun back to the attachments library (it re-grips it next poll)
local function releaseFromIKHand(reattach)
	local held = ikHeld
	ikHeld = nil
	if held == nil then return end
	if reattach and alive(held.mesh) then
		pcall(function() held.mesh:DetachFromParent(false, false) end)
		pcall(function() attachments.detachGripAttachments(Handed.Right) end)
		log("weapon returned to the attachments library")
	end
end

local function heldWeaponMesh()
	local mesh = nil
	pcall(function() mesh = attachments.getCurrentGrippedAttachment(Handed.Right) end)
	return alive(mesh) and mesh or nil
end

local function ikHandTick()
	local mesh = heldWeaponMesh()
	if getHandsMode() ~= HANDS_MODE_IK then
		if ikHeld ~= nil then releaseFromIKHand(true) end
		return
	end
	local rig = ik.getCurrentMesh(1)
	if alive(rig) then applyRightHandTarget(rig) end -- also restores the plain solver offsets with no weapon held
	if mesh == nil then ikHeld = nil return end
	if not alive(rig) then return end -- rig rebuilding: the gun keeps its last pose for a moment

	local key = mesh:get_address()
	if ikHeld ~= nil and ikHeld.mesh == mesh and ikHeld.rig == rig then
		-- watchdog: something re-attached the gun elsewhere -> back onto the IK hand
		local onRig = false
		pcall(function() onRig = mesh.AttachParent ~= nil and mesh.AttachParent:get_address() == rig:get_address() end)
		if not onRig and ikRelative[key] ~= nil then
			log("weapon left the IK hand; re-parenting")
			parentToIKHand(mesh, rig, ikRelative[key])
			return
		end
		-- keep the grip exact (two-handing rotates the gun in world space; it restores on release); re-seat it when the
		-- IK hand offsets (panel) or the attachment offsets changed
		local rel = ikRelative[key]
		if rel ~= nil and (rel.version ~= targetVersion() or os.clock() - (rel.at or 0) > REL_REFRESH_S) then
			local fresh = computeIKRelative(mesh)
			if fresh ~= nil then ikRelative[key] = fresh rel = fresh end
		end
		if _G.isTwoHandingActive ~= true and rel ~= nil then applyIKRelative(mesh, rel) end
		return
	end

	local rel = ikRelative[key]
	if rel == nil then
		-- first hand-over of this weapon: UEVR's controller placement must be live first. Settle delay rather than
		-- UEVR_UObjectHook.get_motion_controller_state, which can throw on this backend (uevrlib notes).
		if ikPendingKey ~= key then
			ikPendingKey = key
			ikTransferNotBefore = os.clock() + IK_TRANSFER_SETTLE_S
			return
		end
		if os.clock() < ikTransferNotBefore then return end
		rel = computeIKRelative(mesh)
		if rel == nil then return end
		ikRelative[key] = rel
	end
	parentToIKHand(mesh, rig, rel)
end

-- bl4_vr_two_handed.lua (IK mode): the held gun's UN-PIVOTED pose this frame = the cached grip-relative transform on the
-- right-hand IK TARGET (controller + solver offsets), not the hand bone (two-handing turns the right IK hand with the
-- gun, a bone-based base would turn twice). Returns baseTransform (world), pivot (hand target location, world),
-- rightControllerTransform (world) - or nil when the gun is not on the IK hand. refreshOffsets re-reads the solver.
local twoHandOffsets = nil
_G.bl4IKWeaponBase = function(mesh, refreshOffsets)
	if ikHeld == nil or ikHeld.mesh ~= mesh or not alive(mesh) then return nil end
	local rel = ikRelative[mesh:get_address()]
	if rel == nil then return nil end
	if refreshOffsets or twoHandOffsets == nil then
		local off, rotOff = rightHandTarget()
		twoHandOffsets = { off = off, rot = rotOff }
	end
	local handT, pivot = rightHandTargetTransform(twoHandOffsets.off, twoHandOffsets.rot)
	if handT == nil then return nil end
	local ctrl = controllers.getController(Handed.Right, true)
	local ctrlT = kismet_math_library:MakeTransform(ctrl:K2_GetComponentLocation(), ctrl:K2_GetComponentRotation(), uevrUtils.vector(1, 1, 1))
	local relT = kismet_math_library:MakeTransform(uevrUtils.vector(rel.loc.X, rel.loc.Y, rel.loc.Z),
		uevrUtils.rotator(rel.rot.Pitch, rel.rot.Yaw, rel.rot.Roll), uevrUtils.vector(1, 1, 1))
	return kismet_math_library:ComposeTransforms(relT, handT), pivot, ctrlT
end

uevrUtils.registerPostCalculateStereoViewCallback(function(device, view_index, world_to_meters, position, rotation, is_double)
	if ikRanThisTick then return end
	ikRanThisTick = true
	local ok, err = pcall(ikHandTick)
	if not ok then log("IK hand: " .. tostring(err)) end
end)

uevrUtils.registerPreLevelChangeCallback(function(level)
	ikHeld = nil
	ikRelative = {}
	ikPendingKey = nil
end)

log("loaded")
