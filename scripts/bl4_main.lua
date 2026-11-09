-- Borderlands 4 VR: the equipped weapon on the right controller / VR right hand (libs/attachments.lua) and VR hands
-- (libs/hands.lua, built in game with the hands configuration tool).
--
-- Not called hands.lua or main.lua on purpose: the hands wizard's "generate script" step writes scripts/hands.lua
-- with its own template. If that file appears, delete it (it would create a second pair of hands).
--
-- Borderlands 4 facts (MCP, 2026-10-30, UE 5.5.4):
--   * Player pawn: OakCharacter. Its first-person meshes are components FirstPersonArms (BPAnim_Player_1st) and
--     FirstPersonLegs, both GbxSkeletalMeshComponents on the capsule; neither is a reflected property.
--   * Equipped weapon: WeaponStatics::GetWeapon(pawn, 0) (slot 0 = the held gun; 1 and 2 were empty).
--   * An OakWeapon has TWO skeletal meshes: RootComponent = the third-person gun on the body's CharacterMesh
--     (R_Hand_Weapon), and an owner-only first-person gun (bOnlyOwnerSee, bGbxForeground) on FirstPersonArms
--     R_Hand_Weapon. The first-person one is the gun the player sees, and the one BL4AimFix.dll shoots from.
--   * The first-person gun has its OWN Anim Blueprint (e.g. BPAnim_DAD_PS_C, AnimationMode 0, no leader pose), so
--     slide / magazine / reload animations keep playing when it rides the controller.
--   * Its barrel runs along mesh +X (socket Muzzle points down +X), hence the default attach rotation (0,0,0).

local uevrUtils = require('libs/uevr_utils')
local configui = require('libs/configui')
local hands = require('libs/hands')
local attachments = require('libs/attachments')
local input = require('libs/input')
local pawnModule = require('libs/pawn')
local reticule = require('libs/reticule')
local controllers = require('libs/controllers')
local montage = require('libs/montage')
local ui = require('libs/ui')

-- uevrlib developer mode OFF (xaero 2026-11-09): no Hand Config / Attachments / Pawn / UI / Reticule / Input / IK /
-- montage dev panels, and none of their dev-only work (the montage dev monitor records every montage played into
-- data/montage_parameters.json; the dev save timers). Their saved settings (data/*_parameters.json) still load and
-- apply. Set true again (and re-enable the hands configuration tool) to tune with the lib panels.
uevrUtils.setDeveloperMode(false)
-- hands configuration tool (hands wizard, "Hand Config" panel): only for building the hands; data/hands_parameters.json
-- holds the tuned result
-- hands.enableConfigurationTool()
-- Our own "Dev Config" node in the Borderlands 4 panel (zz_bl4_vr_panel.lua), independent of uevrlib developer mode.
_G.BL4_DEV_CONFIG = true
-- barrel along +X. New weapons start at the tuned right-hand pistol grip location (xaero, 2026-10-30); saved
-- per-weapon offsets win.
attachments.init(false, nil, {4.6, -1.4, 4.1}, {0,0,0})

-- Panel sections: the "Borderlands 4" panel is built by zz_bl4_vr_panel.lua from _G.BL4_SECTIONS (bl4_ik.lua and
-- bl4_two_handed.lua add theirs); saved values live in data/bl4_config.json.
_G.BL4_SECTIONS = _G.BL4_SECTIONS or {}
table.insert(_G.BL4_SECTIONS, { order = 0, label = "General", layout = {
	{ widgetType = "checkbox", id = "bl4_weapon_on_hand", label = "Weapon on the right hand", initialValue = true },
	{ widgetType = "checkbox", id = "bl4_game_grip", label = "Weapons use the game's grip (off = per-weapon Attachments offsets)", initialValue = true },
	{ widgetType = "button", id = "bl4_game_grip_reset_current", label = "Re-measure this weapon's grip", size = {200, 22} },
	{ widgetType = "same_line" },
	{ widgetType = "button", id = "bl4_game_grip_reset", label = "Re-measure all weapon grips", size = {200, 22} },
	{ widgetType = "checkbox", id = "bl4_roomscale", label = "Roomscale turning (the character turns with your body)", initialValue = true },
	{ widgetType = "checkbox", id = "bl4_no_camera_shake", label = "Disable camera shakes (melee, shooting, hits)", initialValue = true },
	{ widgetType = "checkbox", id = "bl4_no_camera_anim", label = "Disable camera animations (melee etc.)", initialValue = true },
	{ widgetType = "checkbox", id = "bl4_no_camera_kick", label = "Disable camera kick (melee view sway)", initialValue = true },
	{ widgetType = "checkbox", id = "bl4_level_game_pitch", label = "Keep the game's pitch level (stops recoil view sway)", initialValue = true },
	{ widgetType = "checkbox", id = "bl4_block_stick_pitch", label = "Ignore right stick up/down on foot with head aim", initialValue = true },
	{ widgetType = "combo", id = "bl4_gameplay_aim", label = "Aim method in game (menus and cutscenes always use Game)", initialValue = 1,
		selections = { "Head", "Right controller", "Left controller" } },
}})
-- developer mode only (Dev Config): spawns weapons for setting up attachments / grips (see "Weapon spawner" below)
table.insert(_G.BL4_SECTIONS, { order = 90, label = "Weapon Spawner", layout = {
	{ widgetType = "combo", id = "bl4_spawn_manufacturer", label = "Manufacturer", initialValue = 1,
		selections = { "Daedalus", "Jakobs", "Maliwan", "Order", "Ripper", "Tediore", "Torgue", "Vladof" } },
	{ widgetType = "combo", id = "bl4_spawn_type", label = "Weapon type", initialValue = 1,
		selections = { "Pistol", "SMG", "Assault Rifle", "Shotgun", "Sniper", "Heavy" } },
	{ widgetType = "button", id = "bl4_spawn_one", label = "Spawn weapon", size = {160, 24} },
	{ widgetType = "same_line" },
	{ widgetType = "button", id = "bl4_spawn_all_types", label = "Spawn all types of this manufacturer", size = {260, 24} },
	{ widgetType = "text", label = "Ordnance (grenades / throwing knives) of the manufacturer above:" },
	{ widgetType = "button", id = "bl4_spawn_ordnance", label = "Spawn ordnance", size = {160, 24} },
	{ widgetType = "same_line" },
	{ widgetType = "button", id = "bl4_spawn_all_ordnance", label = "Spawn ordnance of every manufacturer", size = {260, 24} },
	{ widgetType = "text", id = "bl4_spawn_status", label = "" },
}})

local WEAPON_SLOT = 0

local function log(text)
	pcall(function() uevrUtils.print("[bl4] " .. tostring(text), LogLevel.Info) end)
end

local oakCharacterClass = nil
local skeletalMeshClass = nil
local weaponStatics = nil

local function getPlayerCharacter()
	local pawn = uevr.api:get_local_pawn(0)
	if uevrUtils.getValid(pawn) == nil then return nil end
	if oakCharacterClass == nil then oakCharacterClass = uevrUtils.get_class("Class /Script/OakGame.OakCharacter") end
	local ok, isPlayer = pcall(function() return oakCharacterClass ~= nil and pawn:is_a(oakCharacterClass) end)
	if not (ok and isPlayer) then return nil end -- vehicles etc.
	return pawn
end

-- The possessed vehicle (OakVehicle) while driving, else nil.
local oakVehicleClass = nil
local function getVehicle()
	local pawn = uevr.api:get_local_pawn(0)
	if uevrUtils.getValid(pawn) == nil then return nil end
	if oakVehicleClass == nil then oakVehicleClass = uevrUtils.get_class("Class /Script/OakGame.OakVehicle") end
	local ok, isVehicle = pcall(function() return oakVehicleClass ~= nil and pawn:is_a(oakVehicleClass) end)
	if not (ok and isVehicle) then return nil end
	return pawn
end

local function getHeldWeapon(pawn)
	if weaponStatics == nil then weaponStatics = uevrUtils.find_default_instance("Class /Script/GbxWeapon.WeaponStatics") end
	if weaponStatics == nil then return nil end
	local ok, weapon = pcall(function() return weaponStatics:GetWeapon(pawn, WEAPON_SLOT) end)
	if ok then return uevrUtils.getValid(weapon) end
	return nil
end

local function getSkeletalMeshClass()
	if skeletalMeshClass == nil then skeletalMeshClass = uevrUtils.get_class("Class /Script/Engine.SkeletalMeshComponent") end
	return skeletalMeshClass
end

-- the weapon's first-person mesh: the owner-only skeletal mesh that is not the RootComponent (cached per weapon)
local meshCache = { weapon = nil, mesh = nil }
local function getFirstPersonWeaponMesh(weapon)
	if meshCache.weapon == weapon and uevrUtils.getValid(meshCache.mesh) ~= nil then return meshCache.mesh end
	meshCache.weapon, meshCache.mesh = nil, nil
	local class = getSkeletalMeshClass()
	if class == nil then return nil end
	local chosen = nil
	pcall(function()
		local root = weapon.RootComponent
		local components = weapon:K2_GetComponentsByClass(class)
		for _, c in ipairs(components or {}) do
			if c ~= nil and c ~= root and (chosen == nil or c.bOnlyOwnerSee == true) then chosen = c end
		end
	end)
	if chosen ~= nil then
		meshCache.weapon, meshCache.mesh = weapon, chosen
		log("weapon " .. weapon:get_full_name() .. " -> first-person mesh " .. chosen:get_full_name())
	end
	return chosen
end

-- the pawn's FirstPersonArms component (not a reflected property: found by name, cached per pawn)
local armsCache = { pawn = nil, arms = nil }
local function getFirstPersonArms(pawn)
	if armsCache.pawn == pawn and uevrUtils.getValid(armsCache.arms) ~= nil then return armsCache.arms end
	armsCache.pawn, armsCache.arms = nil, nil
	local class = getSkeletalMeshClass()
	if class == nil then return nil end
	pcall(function()
		for _, c in ipairs(pawn:K2_GetComponentsByClass(class) or {}) do
			if c ~= nil and c:get_fname():to_string() == "FirstPersonArms" then
				armsCache.pawn, armsCache.arms = pawn, c
				break
			end
		end
	end)
	return armsCache.arms
end

uevrUtils.registerPreLevelChangeCallback(function(level)
	meshCache = { weapon = nil, mesh = nil }
	armsCache = { pawn = nil, arms = nil }
end)

-- Gearbox "gestalt" meshes: FirstPersonArms draws a runtime-merged mesh (Transient_Gestalt_<pawn>_SkelMesh) through
-- the GbxSkeletalMeshComponent's own gestalt render data. A plain PoseableMeshComponent given that mesh is created,
-- attached and visible but never drawn (WasRecentlyRendered stays false, MCP 2026-10-30). The component's single
-- gestalt part (GestaltMeshParts[1], e.g. SKPart_ExoSoldier_First_Person) is a real skeletal mesh on the same
-- skeleton and draws fine. Every poseable copy (hands wizard, libs/hands.lua, libs/ik.lua) is made through
-- uevrUtils.createPoseableMeshFromSkeletalMesh, so the copy is switched to that part right after it is made - before
-- the hands library cuts bones on it.
-- Gadgets add parts: with the Grabber unlocked FirstPersonArms has SKPart_ExoSoldier_First_Person +
-- SKPart_ExoSoldier_First_Person_Grabber (MCP 2026-10-30) and the old "exactly one part" rule skipped the swap -> the
-- hands were created but invisible. A copy holds one mesh: take the arms part (name ending "_First_Person"), else the
-- first part.
local function getRenderableGestaltPart(source)
	local part = nil
	pcall(function()
		local parts = source.GestaltMeshParts
		if parts == nil or #parts == 0 then return end
		for i = 1, #parts do
			local p = parts[i]
			if p ~= nil and string.find(p:get_fname():to_string(), "_First_Person$") ~= nil then
				part = p
				return
			end
		end
		part = parts[1]
	end)
	return part
end

-- view model depth state (used by the copy hook below; see "View model depth")
_G.bl4ViewModelCopies = _G.bl4ViewModelCopies or {}
-- always world depth: the panel option (bl4_world_depth) was removed 2026-11-09 (xaero: should be on at all times)
_G.bl4WorldDepth = function() return true end

local createPoseableMeshFromSkeletalMesh = uevrUtils.createPoseableMeshFromSkeletalMesh
uevrUtils.createPoseableMeshFromSkeletalMesh = function(skeletalMeshComponent, options)
	local copy = createPoseableMeshFromSkeletalMesh(skeletalMeshComponent, options)
	if copy == nil or skeletalMeshComponent == nil then return copy end
	-- Copies keep their source's Gearbox foreground layer. The first-person gun is a bGbxForeground primitive; VR hands
	-- left in the normal scene did not depth-sort against it (wrong overlap at the grip). Same layer = correct sorting
	-- (confirmed 2026-10-30); the backend gives the foreground layer the stereo projection.
	-- With world depth (always on, see "View model depth" below) the gun leaves the foreground layer, so the copies
	-- stay in the normal scene with it; every copy is tracked so the option applies live.
	pcall(function()
		if skeletalMeshComponent.bGbxForeground == true then
			table.insert(_G.bl4ViewModelCopies, copy)
			if not _G.bl4WorldDepth() and copy.SetGbxForeground ~= nil then copy:SetGbxForeground(true) end
		end
	end)
	local part = getRenderableGestaltPart(skeletalMeshComponent)
	if part == nil then return copy end
	local ok, err = pcall(function()
		if copy.SkeletalMesh == part then return end
		copy:SetSkinnedAssetAndUpdate(part, true)
		-- the asset change re-initialises the pose; copy the source pose again unless a default pose was asked for
		if (options == nil or options.useDefaultPose ~= true) and copy.CopyPoseFromSkeletalComponent ~= nil then
			copy:CopyPoseFromSkeletalComponent(skeletalMeshComponent)
		end
		log("poseable copy of " .. skeletalMeshComponent:get_fname():to_string() .. " uses gestalt part " .. part:get_full_name())
	end)
	if not ok then log("gestalt part swap failed: " .. tostring(err)) end
	return copy
end

-- Hands source mesh. The hands wizard (and libs/hands.lua at runtime) list only the pawn's reflected skeletal-mesh
-- properties, and the only one here is Pawn.Mesh = the third-person body. FirstPersonArms hangs off the capsule
-- with no property, so the hands config uses Mesh = "Custom", and both libraries call this global for it.
function getCustomHandComponent(meshName)
	local pawn = getPlayerCharacter()
	if pawn == nil then return nil end
	return getFirstPersonArms(pawn)
end

-- shared with bl4_ik.lua / bl4_two_handed.lua (scripts load in name order: bl4_ik.lua runs before this file, so it
-- only reads _G.bl4 at runtime)
_G.bl4 = {
	log = log,
	getPlayerCharacter = getPlayerCharacter,
	getVehicle = getVehicle,
	getHeldWeapon = getHeldWeapon,
	getFirstPersonWeaponMesh = getFirstPersonWeaponMesh,
	getFirstPersonArms = getFirstPersonArms,
}

-- ---------------------------------------------------------------------------------------------
-- Weapon on the hand. The attachments library polls this and keeps the returned mesh gripped; returning nothing
-- (holstered, vehicle, option off) releases the grip. Parent: the VR right hand once the hands exist, else the raw
-- right controller. allowReattach = true makes the raw-controller attachment permanent (UObjectHook set_permanent),
-- so the game thread - and BL4AimFix.dll's muzzle socket read - sees the gun where it is drawn.
-- ---------------------------------------------------------------------------------------------
-- Ordnance (throwing knives, grenades) in the LEFT hand. BL4 holds it in the left hand while readying a throw (MCP
-- 2026-11-05, Jakobs knives): the pawn's GrenadeGadget (OakCharacter.GetGrenadeGadget) goes AttachState 0 -> 1 and its
-- owner-only first-person mesh is attached to FirstPersonArms L_Hand_Object; on the throw both go back together (same
-- tick as NumberOfCharges drops). The game arms are hidden, so while AttachState is 1 the mesh rides the left VR hand
-- (or the raw left controller) instead. Released without reattaching to its origin: the game detaches it at the throw.
-- Both hands get explicit option tables: the old "true, true" made the LEFT boolean the reattach switch for both.
local GUN_GRIP_OPTIONS = {
	detachFromOriginOnGrip = true, maintainWorldPositionOnDetachFromOrigin = false,
	detachFromParentOnRelease = true, maintainWorldPositionOnDetachFromParent = false,
	reattachToOriginOnRelease = true, restoreTransformToOriginOnReattach = true, useZeroTransformOnReattach = false,
	allowChildVisibilityHandling = true, allowChildHiddenInGameHandling = true, allowRenderInMainPassHandling = true,
}
local ORDNANCE_GRIP_OPTIONS = {
	detachFromOriginOnGrip = true, maintainWorldPositionOnDetachFromOrigin = false,
	detachFromParentOnRelease = true, maintainWorldPositionOnDetachFromParent = false,
	reattachToOriginOnRelease = false, restoreTransformToOriginOnReattach = false, useZeroTransformOnReattach = false,
	allowChildVisibilityHandling = true, allowChildHiddenInGameHandling = true, allowRenderInMainPassHandling = true,
}
-- Carried objects: the library must not touch the first-person copy when the grip ends. Its detach kept the RELATIVE
-- transform, which dropped the copy at the world origin (world (0, -1.3, -22.3) = its hand offset); the game then
-- launched the thrown tank from there and it fell out of the world (z -523000, 2026-11-09). bl4_main hands the copy
-- back itself (handBackCarryVisual).
local CARRY_GRIP_OPTIONS = {
	detachFromOriginOnGrip = true, maintainWorldPositionOnDetachFromOrigin = false,
	detachFromParentOnRelease = false, maintainWorldPositionOnDetachFromParent = true,
	reattachToOriginOnRelease = false, restoreTransformToOriginOnReattach = false, useZeroTransformOnReattach = false,
	allowChildVisibilityHandling = true, allowChildHiddenInGameHandling = true, allowRenderInMainPassHandling = true,
}
local ORDNANCE_IN_HAND = 1 -- InventoryGadget.AttachState while readied in the hand

local ordnanceCache = { gadget = nil, mesh = nil }
local function getHeldOrdnanceMesh(pawn)
	local gadget = nil
	pcall(function() gadget = uevrUtils.getValid(pawn:GetGrenadeGadget()) end)
	if gadget == nil or gadget.AttachState ~= ORDNANCE_IN_HAND then return nil end
	if ordnanceCache.gadget == gadget and uevrUtils.getValid(ordnanceCache.mesh) ~= nil then return ordnanceCache.mesh end
	ordnanceCache.gadget, ordnanceCache.mesh = gadget, nil
	local class = getSkeletalMeshClass()
	if class == nil then return nil end
	pcall(function()
		local root = gadget.RootComponent
		for _, c in ipairs(gadget:K2_GetComponentsByClass(class) or {}) do
			if c ~= nil and c ~= root and c.bOnlyOwnerSee == true then ordnanceCache.mesh = c end
		end
	end)
	if ordnanceCache.mesh ~= nil then log("ordnance " .. gadget:get_full_name() .. " -> first-person mesh " .. ordnanceCache.mesh:get_full_name()) end
	return ordnanceCache.mesh
end
_G.bl4.getHeldOrdnanceMesh = getHeldOrdnanceMesh

-- Carried objects (propane / CO2 tanks etc. pulled in with the grapple, thrown with LT; MCP 2026-11-09): the game's
-- carry system, CarryableObjectStatics.GetCarriedActor(pawn) -> CarryableObject, whose root (a GbxDestructibleComponent)
-- the game attaches to the THIRD-person CharacterMesh at L_Hand_Object with an authored offset (propane tank:
-- (0, -1.3, -22.3) / roll 30). In VR that body hand is elsewhere, so the object floated off the VR hand at the wrong
-- place and depth. While carried it rides the VR left hand like ordnance: the hand copies the game's left hand pose
-- (FirstPersonArms L_Hand_Object relative to L_Hand matches CharacterMesh's within 1 cm), the object sits on the VR
-- hand's L_Hand_Object with the game's own offset, read from the game's attachment before we move it.
-- What the player SEES is not the root: the carried actor has a second, owner-only copy (RootStaticMesh_0,
-- bOnlyOwnerSee, foreground) that the game hangs on FirstPersonArms L_Hand_Object at view-model scale 0.275 (offset
-- (0, -0.8, -13.6)) - it moved with the HMD (xaero 2026-11-09). The full-size root on CharacterMesh is not drawn for
-- the owner. So the VISIBLE copy rides the VR hand, at scale 1 with the root's real-size offset; the root stays the
-- physics object the game throws (bl4_vr_throw steers it).
-- The throw / drop: GetCarriedActor goes nil ~60 ms after LT, but the game LAUNCHES the object ~300 ms later, from
-- where the first-person copy is (in the flat game: still in the hand, through the throw animation). So after the game
-- lets go, the copy stays on the VR hand (carryCache.releasedAt; getCarriedRoot still returns the root) until the root
-- simulates physics (launched), the game takes the copy off the hand, or CARRY_HOLD_S. Then the copy goes back where
-- the game had it (FirstPersonArms L_Hand_Object, its own offset and 0.275 scale), as the flat game has it at that point.
local CARRY_HOLD_S = 0.8
local carryStatics = nil
local carryCache = { actor = nil, root = nil, visual = nil, rel = nil, visualOrigin = nil, releasedAt = nil }
local primitiveClassForCarry = nil
local carryNoBone = nil
-- The copy = the owner-only primitive the game hangs on something OUTSIDE the actor (FirstPersonArms). Its own
-- owner-only children ride along: an object with a cap (StaticMeshComponent_Cap_0 on RootStaticMesh_0) put only the
-- cap on the VR hand when the last owner-only primitive was taken (2026-11-09). nil until the game has attached it.
local function findCarryVisual(actor, root)
	local visual = nil
	pcall(function()
		if primitiveClassForCarry == nil then primitiveClassForCarry = uevrUtils.get_class("Class /Script/Engine.PrimitiveComponent") end
		local actorAddress = actor:get_address()
		for _, c in ipairs(actor:K2_GetComponentsByClass(primitiveClassForCarry) or {}) do
			if c ~= nil and (root == nil or c:get_address() ~= root:get_address()) and c.bOnlyOwnerSee == true then
				local parent = c.AttachParent
				local parentOwner = parent ~= nil and parent:GetOwner() or nil
				if parent ~= nil and (parentOwner == nil or parentOwner:get_address() ~= actorAddress) then visual = c end
			end
		end
	end)
	return visual
end
local function isVRLeftParent(component)
	if component == nil then return false end
	local address = component:get_address()
	local hand = hands.exists() and hands.getHandComponent(Handed.Left) or nil
	if hand ~= nil and hand:get_address() == address then return true end
	local ok, rig = pcall(function() return require('libs/ik').getCurrentMesh(1) end)
	return ok and rig ~= nil and uevrUtils.getValid(rig) ~= nil and rig:get_address() == address
end
-- the copy back where the game had it, unless the game has already taken it off the VR hand itself
local function handBackCarryVisual(cache)
	local visual = uevrUtils.getValid(cache.visual)
	local o = cache.visualOrigin
	if visual == nil or o == nil or uevrUtils.getValid(o.parent) == nil or not isVRLeftParent(visual.AttachParent) then return end
	local ok, err = pcall(function()
		visual:K2_AttachTo(o.parent, uevrUtils.fname_from_string(o.socket), 0, false)
		visual:K2_SetRelativeLocationAndRotation(uevrUtils.vector(o.loc.X, o.loc.Y, o.loc.Z),
			uevrUtils.rotator(o.rot.Pitch, o.rot.Yaw, o.rot.Roll), false, reusable_hit_result, true)
		visual:SetRelativeScale3D(uevrUtils.vector(o.scale.X, o.scale.Y, o.scale.Z))
	end)
	log(ok and ("carried object's copy handed back to the game's " .. o.socket) or ("carry hand-back: " .. tostring(err)))
end
-- after the game let go: nil while the copy should stay on the VR hand, else why the hold is over
local function carryHoldOver(cache)
	if os.clock() - cache.releasedAt > CARRY_HOLD_S then return "no launch seen" end
	local visual = uevrUtils.getValid(cache.visual)
	if visual == nil or not isVRLeftParent(visual.AttachParent) then return "the game took the copy" end
	local root = uevrUtils.getValid(cache.root)
	if root == nil then return "object gone" end
	if carryNoBone == nil then carryNoBone = uevrUtils.fname_from_string("None") end
	if root:IsSimulatingPhysics(carryNoBone) == true then return "launched" end
	return nil
end
local function getCarriedRoot(pawn)
	if carryStatics == nil then carryStatics = uevrUtils.find_default_instance("Class /Script/OakGame.CarryableObjectStatics") end
	if carryStatics == nil or pawn == nil then return nil end
	local actor = nil
	pcall(function() actor = uevrUtils.getValid(carryStatics:GetCarriedActor(pawn)) end)
	if actor == nil then
		if carryCache.actor ~= nil then
			if carryCache.releasedAt == nil then
				local visual = uevrUtils.getValid(carryCache.visual)
				if visual ~= nil and isVRLeftParent(visual.AttachParent) then
					carryCache.releasedAt = os.clock()
					log("the game let go of the carried object: its copy stays on the VR hand until the launch")
				end
			end
			if carryCache.releasedAt ~= nil then
				local ok, over = pcall(carryHoldOver, carryCache)
				if ok and over == nil then return carryCache.root end
				-- the hypothesis check: the game launches the root from the copy (root - copy distance at the launch)
				local gap = -1
				pcall(function()
					local a, b = carryCache.root:K2_GetComponentLocation(), carryCache.visual:K2_GetComponentLocation()
					gap = math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2 + (a.Z - b.Z) ^ 2)
				end)
				log(string.format("carried object hold over after %.0f ms: %s (root %.0f cm from the copy)",
					(os.clock() - carryCache.releasedAt) * 1000, ok and over or tostring(over), gap))
			end
			handBackCarryVisual(carryCache)
		end
		carryCache = { actor = nil, root = nil, visual = nil, rel = nil, visualOrigin = nil, releasedAt = nil }
		return nil
	end
	if carryCache.actor == nil or carryCache.actor:get_address() ~= actor:get_address() then
		if carryCache.actor ~= nil then handBackCarryVisual(carryCache) end
		local root = nil
		pcall(function() root = uevrUtils.getValid(actor.RootComponent) end)
		carryCache = { actor = actor, root = root, visual = nil, rel = nil, visualOrigin = nil, releasedAt = nil }
		if root ~= nil then
			local simulating = nil
			pcall(function()
				if carryNoBone == nil then carryNoBone = uevrUtils.fname_from_string("None") end
				simulating = root:IsSimulatingPhysics(carryNoBone)
			end)
			log("carrying " .. actor:get_full_name() .. " (root simulating physics: " .. tostring(simulating) .. ")")
		end
	end
	carryCache.releasedAt = nil -- carried (again)
	-- the owner-only first-person copy can appear a tick after the carry starts; where the game has it is saved for
	-- the hand-back (read before the attachments library moves it to the VR hand)
	if carryCache.visual == nil then
		local visual = findCarryVisual(actor, carryCache.root)
		if visual ~= nil then
			carryCache.visual = visual
			pcall(function()
				local s = visual.RelativeScale3D
				local parent = visual.AttachParent
				if parent ~= nil and not isVRLeftParent(parent) then
					local l, r = visual.RelativeLocation, visual.RelativeRotation
					carryCache.visualOrigin = { parent = parent,
						socket = visual.AttachSocketName ~= nil and visual.AttachSocketName:to_string() or "None",
						loc = { X = l.X, Y = l.Y, Z = l.Z }, rot = { Pitch = r.Pitch, Yaw = r.Yaw, Roll = r.Roll },
						scale = { X = s.X, Y = s.Y, Z = s.Z } }
				end
				log(string.format("carried object's first-person copy %s (scale %.3f, on %s)", visual:get_full_name(), s.X,
					parent ~= nil and parent:get_fname():to_string() or "nothing"))
			end)
		end
	end
	local root = carryCache.root
	if root ~= nil and carryCache.rel == nil then
		pcall(function()
			local parent = root.AttachParent
			local socket = root.AttachSocketName ~= nil and root.AttachSocketName:to_string() or ""
			if parent ~= nil and socket == "L_Hand_Object" and not isVRLeftParent(parent) then
				local l, r = root.RelativeLocation, root.RelativeRotation
				-- the object's real size: the propane tank's world scale is 0.45 (mesh authored large); scale 1 on the VR
				-- hand was over twice too big (xaero "massive", 2026-11-09)
				local s = root:K2_GetComponentScale()
				carryCache.rel = { loc = { X = l.X, Y = l.Y, Z = l.Z }, rot = { Pitch = r.Pitch, Yaw = r.Yaw, Roll = r.Roll },
					scale = { X = s.X, Y = s.Y, Z = s.Z } }
				log(string.format("carry grip from the game: (%.1f %.1f %.1f) / (%.1f %.1f %.1f) world scale %.3f", l.X, l.Y, l.Z,
					r.Pitch, r.Yaw, r.Roll, s.X))
			end
		end)
	end
	return root
end
_G.bl4.getCarriedRoot = getCarriedRoot
-- true while the game has let go but the object's copy is still held on the VR hand for the launch
_G.bl4.isCarryReleasing = function() return carryCache.releasedAt ~= nil end
-- The object the game actually throws: the root of the actor that OWNS the first-person copy - a second carryable the
-- game spawns (CarryableObject_<n>), not the one GetCarriedActor names. After a throw its root was the one flying,
-- launched from the first-person arms' hand near the world origin (z -113000 / -145000, 2026-11-09). nil = no copy yet.
_G.bl4.getCarriedThrowRoot = function()
	local visual = uevrUtils.getValid(carryCache.visual)
	if visual == nil then return nil end
	local root = nil
	pcall(function()
		local owner = visual:GetOwner()
		root = owner ~= nil and uevrUtils.getValid(owner.RootComponent) or nil
	end)
	return root
end
-- the component the player sees while carrying (the first-person copy; the root when there is none)
local function getCarriedVisual(pawn)
	local root = getCarriedRoot(pawn)
	if root == nil then return nil end
	return uevrUtils.getValid(carryCache.visual) or root
end

-- ---------------------------------------------------------------------------------------------
-- View model depth (always on; the bl4_world_depth option was removed 2026-11-09). BL4 draws the first-person gun and everything attached to it
-- (reticle FX, scope parts) in Gearbox's foreground layer (bGbxForeground): its own depth, composited over the scene,
-- with no depth test against normal-scene primitives. Anything added to the gun in the normal scene (the PiP scope
-- lens) is always drawn behind and displaced, and setting the lens foreground alone did not help (2026-11-05). With the
-- option on, the held gun, every primitive attached under it, the held ordnance and the VR hand / IK arm copies are
-- drawn in the normal scene, all at real world depth, so they sort correctly against each other and against the PiP
-- lens. Cost: the gun can poke into walls (the foreground layer hid that).
-- SetGbxForeground does not rebuild the render state on its own; toggling custom depth forces it (as the Lorewright BL4
-- mod's GunFix does). Applied every 0.25 s to whatever is not in the wanted layer yet (the game re-creates FX parts).
-- ---------------------------------------------------------------------------------------------
local primitiveClass = nil
local function setForegroundLayer(component, foreground)
	if component == nil or component.bGbxForeground == foreground or component.SetGbxForeground == nil then return end
	component:SetGbxForeground(foreground)
	pcall(function()
		local customDepth = component.bRenderCustomDepth == true
		component:SetRenderCustomDepth(not customDepth)
		component:SetRenderCustomDepth(customDepth)
	end)
end

local function setTreeForegroundLayer(root, foreground, depth)
	if root == nil or depth > 4 then return end
	setForegroundLayer(root, foreground)
	if primitiveClass == nil then primitiveClass = uevrUtils.get_class("Class /Script/Engine.PrimitiveComponent") end
	local children = root.AttachChildren
	for i = 1, #(children or {}) do
		local child = children[i]
		if child ~= nil then
			if primitiveClass ~= nil and child:is_a(primitiveClass) then setForegroundLayer(child, foreground) end
			setTreeForegroundLayer(child, foreground, depth + 1)
		end
	end
end

local nextViewModelDepth = 0
local depthCarried = nil -- the carried object last put in the hands' layer; back to its own layer once thrown / dropped
local depthCarriedWas = false -- its own bGbxForeground (the first-person copy: true)
uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
	local now = os.clock()
	if now < nextViewModelDepth then return end
	nextViewModelDepth = now + 0.25
	local foreground = not _G.bl4WorldDepth()
	local ok, err = pcall(function()
		local pawn = getPlayerCharacter()
		local carried = nil
		if pawn ~= nil then
			local weapon = getHeldWeapon(pawn)
			local mesh = weapon ~= nil and getFirstPersonWeaponMesh(weapon) or nil
			if mesh ~= nil then setTreeForegroundLayer(mesh, foreground, 1) end
			local ordnance = getHeldOrdnanceMesh(pawn)
			if ordnance ~= nil then setTreeForegroundLayer(ordnance, foreground, 1) end
			carried = getCarriedVisual(pawn)
		end
		if depthCarried ~= nil and (carried == nil or carried:get_address() ~= depthCarried:get_address()) then
			if uevrUtils.getValid(depthCarried) ~= nil then setTreeForegroundLayer(depthCarried, depthCarriedWas, 1) end
			depthCarried = nil
		end
		if carried ~= nil then
			if depthCarried == nil then
				depthCarriedWas = carried.bGbxForeground == true
				depthCarried = carried
			end
			setTreeForegroundLayer(carried, foreground, 1)
		end
		local live = {}
		for _, copy in ipairs(_G.bl4ViewModelCopies) do
			if uevrUtils.getValid(copy) ~= nil then
				table.insert(live, copy)
				pcall(function() setForegroundLayer(copy, foreground) end)
			end
		end
		_G.bl4ViewModelCopies = live
	end)
	if not ok then log("view model depth: " .. tostring(err)) end
end)

-- ---------------------------------------------------------------------------------------------
-- Game grip (option bl4_game_grip, default on): weapons and ordnance sit on the VR hands / IK arms exactly as the game
-- holds them, with no per-weapon tuning. The VR hands and the IK rig are copies of FirstPersonArms, so they carry its
-- bones and sockets (MCP 2026-11-05: R_Hand_Weapon and L_Hand_Object exist on the copies).
--   * Ordnance: L_Hand_Object sits on the L_Hand bone, so the copy's socket is the game grip -> attached there at zero
--     relative (plus the Throwing panel trim), in both hand modes.
--   * Guns: R_Hand_Weapon hangs off a separate weapon bone (on a copy: 46 cm / 90 deg from R_Hand), which only the game's
--     own animation drives - nothing poses it on the copies. So the grip is MEASURED on the game's FirstPersonArms (they
--     keep animating while hidden): R_Hand_Weapon relative to R_Hand, once no montage plays (equip / reload / melee move
--     the hand off the gun). Pistol check: game grip (13.3, -3.3, 4.3) cm / (20.9, 4.4, 2.9) deg against the hand-tuned
--     IK offset (12.1, -2.6, 4.4) / (23.9, 8.2, 3.3). Cached per weapon model, saved in data/bl4_game_grips.json. The gun
--     then rides the copy's R_Hand bone at that offset: the VR right hand here, the IK rig in bl4_vr_ik.lua.
-- Off: the per-weapon Attachments offsets as before (no socket).
-- ---------------------------------------------------------------------------------------------
local ikLib = require('libs/ik')
local ORDNANCE_SOCKET, ORDNANCE_BONE = "L_Hand_Object", "L_Hand"
local GUN_HAND_BONE, GUN_SOCKET = "R_Hand", "R_Hand_Weapon"
local GAME_GRIPS_FILE = "bl4_game_grips.json"
local GRIP_MAX_CM = 40.0 -- a measured grip farther from the hand than this is not a grip

local function gameGripEnabled() return configui.getValue("bl4_game_grip") ~= false end

local socketCache = {} -- component address -> { [socket] = true / false }
local function hasSocket(component, socket)
	local key = component:get_address()
	socketCache[key] = socketCache[key] or {}
	if socketCache[key][socket] == nil then
		local has = false
		pcall(function() has = component:DoesSocketExist(uevrUtils.fname_from_string(socket)) == true end)
		socketCache[key][socket] = has
	end
	return socketCache[key][socket]
end

local function ikRig()
	if _G.getHandsMode == nil or _G.getHandsMode() ~= 2 then return nil end -- 2 = IK (bl4_vr_ik.lua)
	return uevrUtils.getValid(ikLib.getCurrentMesh(1))
end

-- ordnance parent + socket: VR left hand or the IK rig, at L_Hand_Object (game grip) or as before
local function ordnanceParent()
	local parent = nil
	if hands.exists() then parent = hands.getHandComponent(Handed.Left) else parent = ikRig() end
	if parent == nil then return nil, nil end
	if gameGripEnabled() or not hands.exists() then
		if hasSocket(parent, ORDNANCE_SOCKET) then return parent, ORDNANCE_SOCKET end
		if not hands.exists() then return parent, ORDNANCE_BONE end
	end
	return parent, nil
end

local gameGrips = {}
pcall(function() gameGrips = json.load_file(GAME_GRIPS_FILE) or {} end)
local function weaponModel(mesh)
	local name = nil
	pcall(function() name = mesh.SkeletalMesh:get_full_name() end)
	return name
end
-- The equip animation is not a montage in BL4: "no montage" alone let a mid-equip pose through (Vladof SMG measured
-- pitch 75.7 / roll 26.6 vs 7-26 / within +-4 for the other guns, xaero "facing upwards", 2026-11-05). So a model is
-- accepted only GRIP_SETTLE_S after it first appears and once its hand -> gun offset has stayed within GRIP_STABLE_CM /
-- GRIP_STABLE_DEG for GRIP_STABLE_S. Probed every tick from the pre-engine tick below (both hand modes).
-- Standing still only (GRIP_MAX_SPEED): moving / sprinting poses hold the gun differently and are just as stable. MCP
-- 2026-11-05, Jakobs shotgun: standing idle grip (14.4, -3.1, 4.6) / (32.5, 4.5, -1.6), the same at 5 and 20 deg view
-- pitch and with the gun on the game arms or the VR hand; the saved one (11.3, -4.2, 4.6) / (26.3, -1.6, -3.9) had the
-- exact rotation of the Maliwan shotgun's = a shared non-idle pose ("hand in the wrong place on the gun", both modes).
-- Entries without v = GRIP_VERSION were measured without that gate and are measured again.
local GRIP_SETTLE_S, GRIP_STABLE_S = 1.0, 0.75
local GRIP_STABLE_CM, GRIP_STABLE_DEG = 1.0, 3.0
local GRIP_MAX_SPEED = 20.0 -- cm/s, horizontal
local GRIP_VERSION = 2
local gripProbe = { model = nil, since = 0, last = nil, stableSince = nil }
-- "Re-measure this weapon's grip": model -> true. The old grip stays in use until the new one is saved (no jump to the
-- Attachments offsets meanwhile).
local gripRemeasure = {}

local function measureGrip(arms)
	local grip = nil
	pcall(function()
		local hand = arms:GetSocketTransform(GUN_HAND_BONE, 0)
		local socket = arms:GetSocketTransform(GUN_SOCKET, 0)
		local rel = kismet_math_library:MakeRelativeTransform(socket, hand)
		local t, r = rel.Translation, kismet_math_library:Quat_Rotator(rel.Rotation)
		if math.sqrt(t.X * t.X + t.Y * t.Y + t.Z * t.Z) <= GRIP_MAX_CM then
			grip = { loc = { X = t.X, Y = t.Y, Z = t.Z }, rot = { Pitch = r.Pitch, Yaw = r.Yaw, Roll = r.Roll } }
		end
	end)
	return grip
end

local function angleDelta(a, b) return math.abs((a - b + 180) % 360 - 180) end
local function gripsClose(a, b)
	local dx, dy, dz = a.loc.X - b.loc.X, a.loc.Y - b.loc.Y, a.loc.Z - b.loc.Z
	return math.sqrt(dx * dx + dy * dy + dz * dz) <= GRIP_STABLE_CM
		and angleDelta(a.rot.Pitch, b.rot.Pitch) <= GRIP_STABLE_DEG and angleDelta(a.rot.Yaw, b.rot.Yaw) <= GRIP_STABLE_DEG
		and angleDelta(a.rot.Roll, b.rot.Roll) <= GRIP_STABLE_DEG
end

-- the game's hand -> gun offset for this weapon model, measured on FirstPersonArms; nil until measured
local function getGameGrip(mesh)
	local model = weaponModel(mesh)
	if model == nil then return nil end
	local grip = gameGrips[model]
	if grip ~= nil and grip.v == GRIP_VERSION then return grip end
	return nil
end

local function standingStill(pawn)
	local still = false
	pcall(function()
		local v = pawn:GetVelocity()
		still = math.sqrt(v.X * v.X + v.Y * v.Y) <= GRIP_MAX_SPEED
	end)
	return still
end

-- The game's LEFT hand on the gun, for two-handing (bl4_vr_two_handed.lua, 2026-11-09): L_Hand relative to
-- R_Hand_Weapon on FirstPersonArms = where the flat game holds the fore-grip, in the gun's own frame (the first-person
-- gun sits on R_Hand_Weapon with no offset - same position, MCP 2026-11-09; L_Hand ~27 cm from it toward the Muzzle).
-- Measured alongside the right grip, same gate (settled after equip, no montage, standing still, steady 0.75 s), saved
-- in the model's entry as .lefts[variant] (see below). Accepted only ON the gun: within LEFT_MAX_OFF_BARREL_CM of the line from the gun's
-- origin to its Muzzle socket, from the origin to LEFT_MAX_PAST_MUZZLE_CM past the muzzle. A steady pose off the gun
-- (a one-handed gun, or the game's hand doing something else) is saved as { none = true }: grip-point placement then.
-- "Re-measure this weapon's grip" measures both hands again.
-- Per gun VARIANT (version 2, 2026-11-09): one gestalt model (SK_JAK_SG) is assembled from different parts - a Jakobs
-- shotgun with or without the pump fore-grip shares the model but not the grip (xaero "they recycle the same left
-- grip"). MCP diff of two SK_JAK_SG: barrel JAK_SG_Barrel_02_B vs _02 (11 vs 9 parts), GestaltData.ReferencePoseBounds
-- extent 44.6 x 5.1 x 14.2 vs 31.8 x 4.9 x 14.0. The part names are a TArray<FName> inside a struct (unreadable from
-- UEVR Lua); the reference-pose bounds are plain floats, fixed per part combination: the variant key. Saved under
-- [model].lefts[variant]; the right grip stays per model (the pistol grip does not change with the fore-grip).
local LEFT_GRIP_VERSION = 2
local LEFT_MAX_OFF_BARREL_CM, LEFT_MAX_PAST_MUZZLE_CM = 20.0, 15.0
local leftProbe = { last = nil, stableSince = nil, variant = nil }
local leftRemeasure = {} -- model -> true
local muzzleFName = nil

-- read every time (a few property reads): a cache by component address could hand a re-used address a stale key
local function gunVariant(mesh)
	local key = nil
	pcall(function()
		local b = mesh.GestaltData.ReferencePoseBounds
		local e, o = b.BoxExtent, b.Origin
		key = string.format("%.1f,%.1f,%.1f/%.1f,%.1f,%.1f", e.X, e.Y, e.Z, o.X, o.Y, o.Z)
	end)
	return key or "default"
end

local function leftGripEntry(model, mesh)
	local g = gameGrips[model]
	local lefts = g ~= nil and g.lefts or nil
	local left = lefts ~= nil and lefts[gunVariant(mesh)] or nil
	if left == nil or left.v ~= LEFT_GRIP_VERSION then return nil end
	return left
end

local function measureLeftGrip(arms, mesh)
	local grip = nil
	pcall(function()
		local rel = kismet_math_library:MakeRelativeTransform(arms:GetSocketTransform("L_Hand", 0), arms:GetSocketTransform(GUN_SOCKET, 0))
		local t, r = rel.Translation, kismet_math_library:Quat_Rotator(rel.Rotation)
		local onGun = false
		if muzzleFName == nil then muzzleFName = uevrUtils.fname_from_string("Muzzle") end
		if mesh:DoesSocketExist(muzzleFName) then
			-- the muzzle in the gun's own unit-scale frame = in R_Hand_Weapon's frame
			local gunT = kismet_math_library:MakeTransform(mesh:K2_GetComponentLocation(), mesh:K2_GetComponentRotation(), uevrUtils.vector(1, 1, 1))
			local m = kismet_math_library:InverseTransformLocation(gunT, mesh:GetSocketLocation(muzzleFName))
			local len = math.sqrt(m.X * m.X + m.Y * m.Y + m.Z * m.Z)
			if len >= 1.0 then
				local along = (t.X * m.X + t.Y * m.Y + t.Z * m.Z) / len
				local px, py, pz = t.X - m.X / len * along, t.Y - m.Y / len * along, t.Z - m.Z / len * along
				local off = math.sqrt(px * px + py * py + pz * pz)
				onGun = along >= 0 and along <= len + LEFT_MAX_PAST_MUZZLE_CM and off <= LEFT_MAX_OFF_BARREL_CM
			end
		end
		grip = { loc = { X = t.X, Y = t.Y, Z = t.Z }, rot = { Pitch = r.Pitch, Yaw = r.Yaw, Roll = r.Roll }, onGun = onGun }
	end)
	return grip
end

local function probeLeft(model, arms, mesh, busy, now)
	local grip = not busy and measureLeftGrip(arms, mesh) or nil
	if grip == nil then leftProbe.last, leftProbe.stableSince = nil, nil return end
	if leftProbe.last ~= nil and leftProbe.last.onGun == grip.onGun and gripsClose(grip, leftProbe.last) then
		leftProbe.stableSince = leftProbe.stableSince or now
	else
		leftProbe.stableSince = nil
	end
	leftProbe.last = grip
	if leftProbe.stableSince == nil or now - leftProbe.stableSince < GRIP_STABLE_S then return end
	local variant = gunVariant(mesh)
	gameGrips[model] = gameGrips[model] or {}
	gameGrips[model].left = nil -- version 1 (per model, any variant) is not used any more
	gameGrips[model].lefts = gameGrips[model].lefts or {}
	if grip.onGun then
		gameGrips[model].lefts[variant] = { loc = grip.loc, rot = grip.rot, v = LEFT_GRIP_VERSION }
		log(string.format("game LEFT grip %s [%s]: (%.1f %.1f %.1f) / (%.1f %.1f %.1f)", model, variant, grip.loc.X, grip.loc.Y,
			grip.loc.Z, grip.rot.Pitch, grip.rot.Yaw, grip.rot.Roll))
	else
		gameGrips[model].lefts[variant] = { none = true, v = LEFT_GRIP_VERSION }
		log(string.format("game LEFT grip %s [%s]: the game's left hand is not on the gun (%.1f %.1f %.1f) - grip-point placement",
			model, variant, grip.loc.X, grip.loc.Y, grip.loc.Z))
	end
	leftRemeasure[model] = nil
	leftProbe = { last = nil, stableSince = nil, variant = nil }
	pcall(function() json.dump_file(GAME_GRIPS_FILE, gameGrips, 4) end)
end

local function probeGameGrip(mesh)
	local model = weaponModel(mesh)
	if model == nil then return end
	local needRight = getGameGrip(mesh) == nil or gripRemeasure[model]
	local needLeft = leftGripEntry(model, mesh) == nil or leftRemeasure[model]
	if not needRight and not needLeft then return end
	local now = os.clock()
	-- per model AND variant: swapping between two builds of one model settles again before measuring
	local probeKey = model .. "|" .. gunVariant(mesh)
	if gripProbe.model ~= probeKey then
		gripProbe = { model = probeKey, since = now, last = nil, stableSince = nil }
		leftProbe = { last = nil, stableSince = nil, variant = nil }
	end
	if now - gripProbe.since < GRIP_SETTLE_S then return end
	local pawn = getPlayerCharacter()
	local arms = pawn ~= nil and getFirstPersonArms(pawn) or nil
	if arms == nil then return end
	local busy = true
	pcall(function() busy = arms:GetAnimInstance():IsAnyMontagePlaying() == true end)
	if not busy and not standingStill(pawn) then busy = true end
	if needLeft then probeLeft(model, arms, mesh, busy, now) end
	if not needRight then return end
	local grip = not busy and measureGrip(arms) or nil
	if grip == nil then
		gripProbe.last, gripProbe.stableSince = nil, nil
		return
	end
	if gripProbe.last ~= nil and gripsClose(grip, gripProbe.last) then
		gripProbe.stableSince = gripProbe.stableSince or now
	else
		gripProbe.stableSince = nil
	end
	gripProbe.last = grip
	if gripProbe.stableSince == nil or now - gripProbe.stableSince < GRIP_STABLE_S then return end
	grip.v = GRIP_VERSION
	grip.lefts = gameGrips[model] ~= nil and gameGrips[model].lefts or nil -- keep the measured left grips
	gameGrips[model] = grip
	gripRemeasure[model] = nil
	pcall(function() json.dump_file(GAME_GRIPS_FILE, gameGrips, 4) end)
	log(string.format("game grip %s: (%.1f %.1f %.1f) / (%.1f %.1f %.1f)", model, grip.loc.X, grip.loc.Y, grip.loc.Z,
		grip.rot.Pitch, grip.rot.Yaw, grip.rot.Roll))
end

configui.onUpdate("bl4_game_grip_reset", function(value)
	gameGrips = {}
	gripProbe = { model = nil, since = 0, last = nil, stableSince = nil }
	pcall(function() json.dump_file(GAME_GRIPS_FILE, gameGrips, 4) end)
	log("game grips cleared - each weapon is measured again on its next equip")
end)
-- the held weapon only (button callbacks run on the draw thread: the mesh is read on the game thread)
configui.onUpdate("bl4_game_grip_reset_current", function(value)
	uevrUtils.setTimeout(1, function()
		local pawn = getPlayerCharacter()
		local weapon = pawn ~= nil and getHeldWeapon(pawn) or nil
		local gun = weapon ~= nil and getFirstPersonWeaponMesh(weapon) or nil
		local model = gun ~= nil and weaponModel(gun) or nil
		if model == nil then log("re-measure grip: no weapon held") return end
		gripRemeasure[model] = true
		leftRemeasure[model] = true
		gripProbe = { model = nil, since = 0, last = nil, stableSince = nil }
		log("re-measuring the grip of " .. model .. " - stand still for 2 s")
	end)
end)
_G.bl4.getGameGrip = function(mesh)
	if not gameGripEnabled() then return nil end
	return getGameGrip(mesh)
end
-- the game's left hand on this gun (gun-local, relative to R_Hand_Weapon = the gun's own frame): { loc, rot } or nil
-- (this variant not measured yet, or the game holds it one-handed). bl4_vr_two_handed.lua places the left hand with it.
_G.bl4.getGameLeftGrip = function(mesh)
	local model = mesh ~= nil and weaponModel(mesh) or nil
	local left = model ~= nil and leftGripEntry(model, mesh) or nil
	if left == nil or left.none or left.loc == nil then return nil end
	return left
end

-- Ordnance trim (Throwing panel, default 0 = the game's own grip) on the L_Hand_Object socket, applied on attach and
-- whenever the panel values change.
local function panelVec3(id)
	local v = configui.getValue(id)
	local out = { 0, 0, 0 }
	pcall(function()
		if type(v) == "table" and v[1] ~= nil then out = { v[1], v[2], v[3] }
		elseif v ~= nil then out = { v.X or v.x, v.Y or v.y, v.Z or v.z } end
	end)
	for i = 1, 3 do if type(out[i]) ~= "number" then out[i] = 0 end end
	return out
end
local function onSocketOf(mesh, parent, socket)
	local p = mesh.AttachParent
	return p ~= nil and parent ~= nil and p:get_address() == parent:get_address()
		and mesh.AttachSocketName ~= nil and mesh.AttachSocketName:to_string() == socket
end
local function setRelative(mesh, loc, rot)
	mesh:K2_SetRelativeLocationAndRotation(uevrUtils.vector(loc.X, loc.Y, loc.Z), uevrUtils.rotator(rot.Pitch, rot.Yaw, rot.Roll),
		false, reusable_hit_result, true)
end

-- re-seat on the game grip after the attachments library attached (it applies the Attachments entry offsets first)
local ordnanceApplied, gunApplied, carryApplied = nil, nil, nil
-- carried objects always go on L_Hand_Object (their game offset is relative to it), VR left hand or IK rig
local function carryParent()
	local parent = hands.exists() and hands.getHandComponent(Handed.Left) or ikRig()
	if parent == nil then return nil, nil end
	if hasSocket(parent, ORDNANCE_SOCKET) then return parent, ORDNANCE_SOCKET end
	return parent, nil
end
uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
	local ok, err = pcall(function()
		local mesh = ordnanceCache.mesh
		local parent, socket = nil, nil
		if mesh ~= nil and uevrUtils.getValid(mesh) ~= nil then parent, socket = ordnanceParent() end
		if socket == ORDNANCE_SOCKET and onSocketOf(mesh, parent, socket) then
			local l, r = panelVec3("bl4_ik_ordnance_loc"), panelVec3("bl4_ik_ordnance_rot")
			local key = mesh:get_address() .. "|" .. table.concat(l, ",") .. "|" .. table.concat(r, ",")
			if key ~= ordnanceApplied then
				setRelative(mesh, { X = l[1], Y = l[2], Z = l[3] }, { Pitch = r[1], Yaw = r[2], Roll = r[3] })
				ordnanceApplied = key
			end
		else
			ordnanceApplied = nil
		end
	end)
	if not ok then log("ordnance grip: " .. tostring(err)) ordnanceApplied = nil end

	-- carried object: the game's own offset on the VR hand's L_Hand_Object (getCarriedRoot read it from the game's
	-- attachment before the attachments library moved it)
	ok, err = pcall(function()
		-- the visible first-person copy (else the root), at the real object's world size (the copy is 0.275 on the arms)
		local root, rel = uevrUtils.getValid(carryCache.visual) or carryCache.root, carryCache.rel
		local parent, socket = nil, nil
		if root ~= nil and rel ~= nil and uevrUtils.getValid(root) ~= nil then parent, socket = carryParent() end
		if socket ~= nil and onSocketOf(root, parent, socket) then
			-- the attachments library writes its own (default) offset after attaching, so check every tick rather than
			-- once (2026-11-09: the tank sat at the library's (4.6, -1.4, 4.1) instead of the game's (0, -1.3, -22.3))
			local l, r, s = root.RelativeLocation, root.RelativeRotation, root:K2_GetComponentScale()
			local want = rel.scale or { X = 1, Y = 1, Z = 1 }
			local off = math.abs(l.X - rel.loc.X) + math.abs(l.Y - rel.loc.Y) + math.abs(l.Z - rel.loc.Z)
				+ (math.abs(r.Pitch - rel.rot.Pitch) + math.abs(r.Yaw - rel.rot.Yaw) + math.abs(r.Roll - rel.rot.Roll)) * 0.1
				+ math.abs(s.X - want.X) * 10
			if off > 0.05 then
				setRelative(root, rel.loc, rel.rot)
				root:SetWorldScale3D(uevrUtils.vector(want.X, want.Y, want.Z))
				local key = root:get_address() .. "|" .. parent:get_address()
				if key ~= carryApplied then log("carried object seated on the VR hand with the game's grip") end
				carryApplied = key
			end
		else
			carryApplied = nil
		end
	end)
	if not ok then log("carry grip: " .. tostring(err)) carryApplied = nil end

	-- grip probe (both modes) + Hands mode gun (IK mode: bl4_vr_ik.lua uses the same grip)
	ok, err = pcall(function()
		if not gameGripEnabled() then gunApplied = nil return end
		local pawn = getPlayerCharacter()
		local weapon = pawn ~= nil and getHeldWeapon(pawn) or nil
		local gun = weapon ~= nil and getFirstPersonWeaponMesh(weapon) or nil
		if gun ~= nil then probeGameGrip(gun) end
		if not hands.exists() then gunApplied = nil return end
		local hand = hands.getHandComponent(Handed.Right)
		if gun == nil or hand == nil or not onSocketOf(gun, hand, GUN_HAND_BONE) then gunApplied = nil return end
		local grip = getGameGrip(gun)
		if grip == nil then return end
		local key = gun:get_address() .. "|" .. hand:get_address() .. "|" .. tostring(grip) -- re-seat on a re-measured grip
		if key == gunApplied then return end
		setRelative(gun, grip.loc, grip.rot)
		gunApplied = key
	end)
	if not ok then log("gun grip: " .. tostring(err)) gunApplied = nil end
end)

-- Left hand takes the game's grip while ordnance is in hand (Hands mode, option bl4_ordnance_game_pose, default on).
-- L_Hand_Object is an animated BONE (index 34, child of L_Hand; MCP 2026-11-09), not a fixed socket: the game's arm
-- animation places it - and curls the fingers - per item. Nothing animates the VR hand copy, so every knife / grenade
-- sat at the bone's reference spot with a generic hand pose and each needed its own offsets. While an item is readied
-- every bone BELOW L_Hand (fingers + L_Hand_Object) is copied from the game's FirstPersonArms onto the VR left hand,
-- relative to the wrist (animation.copyDescendantTransforms): the VR wrist stays on the controller, the fingers and
-- L_Hand_Object are where the game has them, so the item rides L_Hand_Object exactly as in the flat game, for any item,
-- with no per-item data. Not the hands lib's full animate-from-mesh: that rebuilds the wrist from the copied Root bone,
-- which on FirstPersonArms sits in camera space - the left hand vanished (xaero 2026-11-09). Copied in the post-engine
-- tick so it lands after the hands lib's own finger animation; on release the hand's default pose comes back.
-- IK mode too (2026-11-09): the target is the IK rig, one poseable copy of FirstPersonArms with both arms, whose L_Hand
-- is the left solver's end bone. Without the copy its left fingers - and L_Hand_Object, a descendant of L_Hand - were
-- posed by the hands animation lib from the left controller's grip / trigger state: the item's rotation changed with
-- that input ("sometimes wrong") and the fingers never took the game's grip (xaero 2026-11-09). The copy stores bone-
-- local transforms below L_Hand, so the IK solve moving L_Hand (same post tick, either order) carries them along.
-- Release in IK mode: the rig's bones below L_Hand get back the exact local transforms they had before the first copy
-- (snapshot). hands.updateAnimationState was not enough (xaero 2026-11-09: "IK hand stuck in the throwable pose until
-- I press grip / trigger / thumb"): at the release the attachments library still lists the item as held (it re-checks
-- on a timer), so it re-posed the knife grip, and its later open_left resets only the finger 01-03 rotations - the
-- copied locations and other hand bones stayed.
local animationLib = require('libs/animation')
local ordnancePose = { arms = nil, active = false, target = nil, mode = nil, snapshot = nil }
local function snapshotHandBones(rig)
	local saved = {}
	for _, name in ipairs(animationLib.getDescendantBones(rig, "L_Hand", false) or {}) do
		local fname = uevrUtils.fname_from_string(name)
		local rot, loc, scale = animationLib.getBoneSpaceLocalTransform(rig, fname)
		if rot ~= nil and loc ~= nil and scale ~= nil then
			table.insert(saved, { fname = fname, rot = uevrUtils.rotator(rot.Pitch, rot.Yaw, rot.Roll),
				loc = uevrUtils.vector(loc.X, loc.Y, loc.Z), scale = uevrUtils.vector(scale.X, scale.Y, scale.Z) })
		end
	end
	return saved
end
local function restoreHandBones(rig, saved)
	for _, b in ipairs(saved or {}) do
		animationLib.setBoneSpaceLocalTransform(rig, b.fname, kismet_math_library:MakeTransform(b.loc, b.rot, b.scale))
	end
end
-- the left hand the game grip is copied onto: the VR left hand (Hands mode) or the IK rig (IK mode)
local function ordnancePoseTarget()
	if hands.exists() then
		local hand = uevrUtils.getValid(hands.getHandComponent(Handed.Left))
		return hand, hand ~= nil and "hands" or nil
	end
	local rig = ikRig()
	return rig, rig ~= nil and "ik" or nil
end
local function releaseOrdnancePose()
	if not ordnancePose.active then return end
	ordnancePose.active = false
	if ordnancePose.mode == "ik" then
		local rig, saved = ordnancePose.target, ordnancePose.snapshot
		local ok, err = pcall(function()
			if uevrUtils.getValid(rig) ~= nil then restoreHandBones(rig, saved) end
		end)
		if not ok then log("ordnance pose restore: " .. tostring(err)) end
	else
		pcall(function() hands.setInitialTransform(Handed.Left) end)
	end
	ordnancePose.mode, ordnancePose.snapshot = nil, nil
end
uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
	local arms, target, mode = nil, nil, nil
	pcall(function()
		local pawn = getPlayerCharacter()
		if pawn == nil then return end
		-- ordnance / carried objects (Throwing option), or two-handing on the game's left grip (bl4_vr_two_handed.lua
		-- sets _G.bl4TwoHandGameLeft while the left hand sits where the flat game holds the gun: its fingers too)
		local ordnance = configui.getValue("bl4_ordnance_game_pose") ~= false
			and (getHeldOrdnanceMesh(pawn) ~= nil or getCarriedRoot(pawn) ~= nil)
		if not ordnance and _G.bl4TwoHandGameLeft ~= true then return end
		target, mode = ordnancePoseTarget()
		if target ~= nil then arms = getFirstPersonArms(pawn) end
	end)
	-- a hand mode switch mid-hold: hand the old target back first (release restores ordnancePose.target, the old one)
	if ordnancePose.active and mode ~= ordnancePose.mode then releaseOrdnancePose() end
	if arms == nil then releaseOrdnancePose() end
	ordnancePose.arms, ordnancePose.target = arms, target
	if arms ~= nil and mode ~= ordnancePose.mode and not ordnancePose.active then
		ordnancePose.mode = mode
		log("ordnance: left hand takes the game's grip (" .. mode .. " mode)")
	end
end)
uevr.sdk.callbacks.on_post_engine_tick(function(engine, delta)
	local arms, target = ordnancePose.arms, ordnancePose.target
	if arms == nil or target == nil then return end
	local ok, err = pcall(function()
		if uevrUtils.getValid(target) == nil or uevrUtils.getValid(arms) == nil then return end
		-- IK: keep the rig hand's own pose for the release (the VR hand has setInitialTransform instead)
		if not ordnancePose.active and ordnancePose.mode == "ik" then ordnancePose.snapshot = snapshotHandBones(target) end
		animationLib.copyDescendantTransforms(arms, target, "L_Hand", false)
		ordnancePose.active = true
	end)
	if not ok then log("ordnance pose: " .. tostring(err)) ordnancePose.arms = nil end
end)

attachments.registerOnGripUpdateCallback(function()
	if configui.getValue("bl4_weapon_on_hand") == false then return end
	local pawn = getPlayerCharacter()
	if pawn == nil then return end
	local gun = nil
	local weapon = getHeldWeapon(pawn)
	if weapon ~= nil then
		local mesh = getFirstPersonWeaponMesh(weapon)
		if mesh ~= nil and mesh.SkeletalMesh ~= nil then gun = mesh end -- no mesh asset yet in the first frames after equip
	end
	local ordnance = getHeldOrdnanceMesh(pawn)
	local carried = ordnance == nil and getCarriedVisual(pawn) or nil
	if gun == nil and ordnance == nil and carried == nil then return end
	local rightParent, rightSocket, leftParent, leftSocket = nil, nil, nil, nil
	if hands.exists() then
		rightParent = hands.getHandComponent(Handed.Right)
		if gameGripEnabled() then rightSocket = GUN_HAND_BONE end
	end
	if ordnance ~= nil then leftParent, leftSocket = ordnanceParent()
	elseif carried ~= nil then leftParent, leftSocket = carryParent() end
	-- ordnance: the game detaches it itself at the throw; carried objects: handBackCarryVisual puts the copy back
	return gun, rightParent, rightSocket, ordnance or carried, leftParent, leftSocket, GUN_GRIP_OPTIONS,
		ordnance ~= nil and ORDNANCE_GRIP_OPTIONS or CARRY_GRIP_OPTIONS
end)

-- ---------------------------------------------------------------------------------------------
-- Game arms: hidden by libs/pawn.lua (Pawn panel, data/pawn_parameters.json). FirstPersonArms is no pawn property,
-- so the panel's mesh lists cannot show it; the saved descriptor "Pawn.CapsuleComponent(FirstPersonArms)" resolves
-- it through the capsule's attach children. Hide settings = render-pass flags only, never bVisible / bHiddenInGame
-- (a hidden skeletal mesh can stop ticking its pose). With the weapon left on the game arms they stay shown.
-- ---------------------------------------------------------------------------------------------
local function gameArmsHidden()
	if configui.getValue("bl4_weapon_on_hand") == false then return false, 0 end
	return nil
end
pawnModule.registerIsPawnArmsHiddenCallback(gameArmsHidden)
pawnModule.registerIsPawnAnimationArmsHiddenCallback(gameArmsHidden)
pawnModule.init()

-- ---------------------------------------------------------------------------------------------
-- Montages (libs/montage.lua, Montage Config dev panel in developer mode, data/montage_config.json). The library
-- polls pawn:GetCurrentMontage() = Pawn.Mesh (third-person body); BL4 plays its first-person montages (fire, reload,
-- melee, equip, interactions) on FirstPersonArms, so that mesh is monitored too (same descriptor as the Pawn panel).
-- ---------------------------------------------------------------------------------------------
montage.init()
montage.addMeshMonitor("Arms", "Pawn.CapsuleComponent(FirstPersonArms)")

-- UI (libs/ui.lua, UI Config dev panel in developer mode, data/ui_parameters.json): cutscene / pause / hidden-character
-- detection, configured in the panel (nothing set yet = library defaults).
ui.init()

-- ---------------------------------------------------------------------------------------------
-- VR weapon reticule (libs/reticule.lua, Reticule panel, data/reticule_parameters.json: library default reticule,
-- target method Custom = 6). BL4's crosshair is not a UMG widget: the HUD is Coherent Gameface (CohtmlHUD, HTML
-- from /Game/uiresources), drawn into one HUD texture, with the crosshair built from per-weapon pieces - nothing for
-- reticule.lua to take over the way Hellraiser uses W_WeaponCrosshairs_C. The reticule traces from the first-person
-- gun's Muzzle socket along the socket's forward (= barrel, mesh +X): the muzzle and axis BL4AimFix.dll fires from.
-- No gun out -> hidden (this library keeps the last hit when the target callback has nothing, so it is hidden
-- explicitly rather than left frozen there).
-- ---------------------------------------------------------------------------------------------
local muzzleSocketName = nil
local gameReticleActive = false -- the backend's game-crosshair layer is showing (see "Game crosshair layer" below)
reticule.init()
reticule.registerCustomTargetCallback(function()
	local location, rotation = nil, nil
	pcall(function()
		local pawn = getPlayerCharacter()
		if pawn == nil or configui.getValue("bl4_weapon_on_hand") == false then return end
		local weapon = getHeldWeapon(pawn)
		local mesh = weapon ~= nil and getFirstPersonWeaponMesh(weapon) or nil
		if mesh == nil then return end
		if muzzleSocketName == nil then muzzleSocketName = uevrUtils.fname_from_string("Muzzle") end
		if mesh:DoesSocketExist(muzzleSocketName) then
			location = mesh:GetSocketLocation(muzzleSocketName)
			rotation = mesh:GetSocketRotation(muzzleSocketName)
		end
	end)
	reticule.setHidden(location == nil or gameReticleActive)
	if location == nil then return uevrUtils.vector(0, 0, 0), uevrUtils.rotator(0, 0, 0) end
	return location, rotation
end)

-- Reticule look ("Reticule" section): the dot is the library default (Engine Sphere + Widget3DPassThrough, unlit).
-- Colour and brightness go on a dynamic material instance of that material: SlateUI = white texture (so the tint is
-- the colour exactly), TintColorAndOpacity = colour x brightness (unlit, so > 1 is brighter). Size = the library's
-- scale multiplier (reticule.setScale). The reticule is rebuilt on loads, so a 250 ms poll re-applies the material
-- whenever the live component's material is not ours, and whenever a setting changes.
table.insert(_G.BL4_SECTIONS, { order = 0.6, label = "Reticule", layout = {
	{ widgetType = "checkbox", id = "bl4_ret_game", label = "Use the game's crosshair at the aim point (needs the BL4 UEVR build)", initialValue = true },
	{ widgetType = "slider_float", id = "bl4_ret_game_scale", label = "Game crosshair size", initialValue = 1.0, range = { 0.25, 4.0 } },
	{ widgetType = "slider_int", id = "bl4_ret_game_crop", label = "Game crosshair crop (UI pixels)", initialValue = 256, range = { 64, 512 } },
	{ widgetType = "slider_float", id = "bl4_ret_game_maxdist", label = "Game crosshair max distance (m)", initialValue = 50.0, range = { 2.0, 100.0 } },
	{ widgetType = "combo", id = "bl4_ret_game_pose", label = "Controller pose (the one that puts it on the barrel)", initialValue = 1, selections = { "Grip", "Aim" } },
	{ widgetType = "text", id = "bl4_ret_game_status", label = "Game crosshair: waiting" },
	{ widgetType = "text", label = "Dot reticule (used when the game crosshair is off or unavailable):" },
	{ widgetType = "color_picker", id = "bl4_ret_color", label = "Colour", initialValue = "#FFFFFFFF" },
	{ widgetType = "slider_float", id = "bl4_ret_size", label = "Size", initialValue = 1.0, range = { 0.25, 4.0 } },
	{ widgetType = "slider_float", id = "bl4_ret_brightness", label = "Brightness", initialValue = 1.0, range = { 0.1, 10.0 } },
}})

local RETICULE_MATERIAL_PATH = "Material /Engine/EngineMaterials/Widget3DPassThrough.Widget3DPassThrough"
local RETICULE_WHITE_TEXTURE_PATH = "Texture2D /Engine/EngineResources/WhiteSquareTexture.WhiteSquareTexture"
local reticuleMid, reticuleMidAddress = nil, nil
local reticuleAppliedTint, reticuleAppliedSize = nil, nil

-- configui stores the picker as an integer with R in the low byte (strings only before the panel exists)
local function reticuleColorRgba(value)
	local hex = type(value) == "string" and value or uevrUtils.intToHexString(value or 0xFFFFFFFF)
	local r = (tonumber(string.sub(hex, 2, 3), 16) or 255) / 255
	local g = (tonumber(string.sub(hex, 4, 5), 16) or 255) / 255
	local b = (tonumber(string.sub(hex, 6, 7), 16) or 255) / 255
	local a = #hex >= 9 and ((tonumber(string.sub(hex, 8, 9), 16) or 255) / 255) or 1
	return r, g, b, a
end

local function applyReticuleLook()
	local size = configui.getValue("bl4_ret_size") or 1.0
	if size ~= reticuleAppliedSize then
		reticule.setScale(size)
		reticuleAppliedSize = size
	end

	local component = uevrUtils.getValid(reticule.getComponent())
	if component == nil or component.GetMaterial == nil then return end
	local current = component:GetMaterial(0)
	local currentAddress = current ~= nil and current:get_address() or nil
	if reticuleMid == nil or currentAddress ~= reticuleMidAddress then
		local template = uevrUtils.getSafeInstanceOf("Class /Script/Engine.Material", RETICULE_MATERIAL_PATH)
		if template == nil then return end
		reticuleMid = component:CreateDynamicMaterialInstance(0, template, uevrUtils.fname_from_string("bl4_reticule_material"))
		if reticuleMid == nil then reticuleMidAddress = nil return end
		reticuleMidAddress = reticuleMid:get_address()
		local white = uevrUtils.getSafeInstanceOf("Class /Script/Engine.Texture2D", RETICULE_WHITE_TEXTURE_PATH)
		if white ~= nil then reticuleMid:SetTextureParameterValue(uevrUtils.fname_from_string("SlateUI"), white) end
		reticuleAppliedTint = nil
	end

	local color = configui.getValue("bl4_ret_color") or "#FFFFFFFF"
	local brightness = configui.getValue("bl4_ret_brightness") or 1.0
	local tintKey = tostring(color) .. "|" .. tostring(brightness)
	if tintKey == reticuleAppliedTint then return end
	local r, g, b, a = reticuleColorRgba(color)
	reticuleMid:SetVectorParameterValue(uevrUtils.fname_from_string("TintColorAndOpacity"),
		uevrUtils.color_from_rgba(r * brightness, g * brightness, b * brightness, a))
	reticuleAppliedTint = tintKey
end

local reticuleLookLastError = nil
uevrUtils.setInterval(250, function()
	local ok, err = pcall(applyReticuleLook)
	if not ok then
		reticuleMid, reticuleMidAddress = nil, nil
		if tostring(err) ~= reticuleLookLastError then log("reticule look: " .. tostring(err)) end
		reticuleLookLastError = tostring(err)
	end
end)

-- ---------------------------------------------------------------------------------------------
-- Game crosshair layer (BL4 UEVR build only, backend src/mods/vr/Borderlands4ReticleLayer.hpp). The game's crosshair is
-- Prysm HTML in the UI, so in the world it gets tonemapped (dark, washed out - dev test 2026-11-07). Instead the backend
-- takes the key-coloured crosshair pixels (see the colour key below) from the UI centre into its own OpenXR quad layer
-- (composited after the tonemapper like the HUD = real colours), poses it every frame from the live right-controller
-- pose, and erases only those pixels from the UI quad. Every tick this sends
-- "active,distance,origin xyz,dir xyz,crop,scale,pose,0,0,real colours" via set_mod_value("BL4_ReticleLayer"): the muzzle and
-- barrel direction in the right motion controller component's local space (the gun hangs off it, so this is near
-- constant and the backend applies it to the newest pose) and the hit distance along the barrel. The backend drops
-- the layer if this stops for 0.5 s (script reset). The dot reticule hides only once the backend has echoed the value
-- back (get_mod_value), so an older UEVR build keeps the dot.
-- ---------------------------------------------------------------------------------------------
local GAME_RETICLE_KEY = "BL4_ReticleLayer"
local gameReticleSupported = nil -- nil = not known yet
local gameReticleLastText = nil
local gameReticleStatus = nil

local function setGameReticleStatus(text)
	if text == gameReticleStatus then return end
	gameReticleStatus = text
	log("game crosshair: " .. text)
	configui.setLabel("bl4_ret_game_status", "Game crosshair: " .. text)
end

local function sendGameReticle(text)
	uevr.params.vr.set_mod_value(GAME_RETICLE_KEY, text)
	gameReticleLastText = text
	if gameReticleSupported == nil then
		local echoed = uevr.params.vr:get_mod_value(GAME_RETICLE_KEY)
		gameReticleSupported = echoed ~= nil and echoed == text
		log("game crosshair layer " .. (gameReticleSupported and "supported by this UEVR build" or "NOT supported by this UEVR build (dot reticule stays)"))
	end
end

-- Colour key (backend shaders/bl4_reticle_key.fx). The backend can't tell the crosshair from other HUD content near
-- the screen centre (item cards, prompts, damage numbers), so while the layer is active the game's own crosshair
-- colour settings are switched to key colours no other HUD element uses (red/blue mixes with zero green). The backend
-- moves only the key-coloured pixels to the gun, recoloured to the player's real colours, and leaves the rest of the
-- HUD alone. The real colours are kept in data/bl4_crosshair_colors.txt (a crash can leave the keys in the game's
-- saved settings; the next session reads the real ones back from there) and restored whenever the layer is off and
-- on script reset.
local CROSSHAIR_KEYS = {
	{ get = "GetCrosshairNeutralColor", set = "SetCrosshairNeutralColor", key = { 1.0, 0.0, 1.0 }, default = { 1.0, 1.0, 1.0 } },
	{ get = "GetCrosshairEnemyColor", set = "SetCrosshairEnemyColor", key = { 1.0, 0.0, 0.12 }, default = { 1.0, 0.142361, 0.167265 } },
	{ get = "GetCrosshairFriendlyColor", set = "SetCrosshairFriendlyColor", key = { 0.12, 0.0, 1.0 }, default = { 0.226316, 0.938686, 0.461698 } },
}
local CROSSHAIR_COLORS_FILE = "bl4_crosshair_colors.txt"
local crosshairOriginals = nil -- { {r,g,b}, x3 } linear, the player's real colours
local crosshairKeysApplied = false
local crosshairKeyNextCheck = 0
local crosshairColorsCsv = nil

local oakLocalPlayer = nil
local function getOakLocalPlayer()
	if oakLocalPlayer == nil or not uevrUtils.getValid(oakLocalPlayer) then
		local pc = uevr.api:get_player_controller(0)
		oakLocalPlayer = pc ~= nil and uevrUtils.getValid(pc.Player) or nil
		if oakLocalPlayer == nil then
			oakLocalPlayer = uevrUtils.find_first_of("Class /Script/OakGame.OakLocalPlayer", false)
		end
	end
	return oakLocalPlayer
end

local function isKeyColor(c, key)
	return c ~= nil and math.abs(c.R - key[1]) < 0.01 and math.abs(c.G - key[2]) < 0.01 and math.abs(c.B - key[3]) < 0.01
end

-- any key colour this or an earlier version used (zero green, full red or blue): never taken as the player's colour
local function looksLikeKey(c)
	return c ~= nil and c.G < 0.005 and math.max(c.R, c.B) > 0.99
end

local function linearToSrgb(v)
	v = math.max(0.0, math.min(1.0, v))
	if v <= 0.0031308 then return v * 12.92 end
	return 1.055 * v ^ (1.0 / 2.4) - 0.055
end

local function updateCrosshairColorsCsv()
	local parts = {}
	for i = 1, 3 do
		local c = crosshairOriginals[i] or CROSSHAIR_KEYS[i].default
		parts[#parts + 1] = string.format("%.4f,%.4f,%.4f", linearToSrgb(c[1]), linearToSrgb(c[2]), linearToSrgb(c[3]))
	end
	crosshairColorsCsv = table.concat(parts, ",")
end

local function loadCrosshairOriginals()
	local originals = {}
	local ok, text = pcall(fs.read, CROSSHAIR_COLORS_FILE)
	if ok and type(text) == "string" then
		local i = 0
		for r, g, b in text:gmatch("([%d%.%-]+),([%d%.%-]+),([%d%.%-]+)") do
			i = i + 1
			if i <= 3 then originals[i] = { tonumber(r), tonumber(g), tonumber(b) } end
		end
	end
	return originals
end

local function saveCrosshairOriginals()
	local lines = {}
	for i = 1, 3 do
		local c = crosshairOriginals[i] or CROSSHAIR_KEYS[i].default
		lines[#lines + 1] = string.format("%.6f,%.6f,%.6f", c[1], c[2], c[3])
	end
	pcall(fs.write, CROSSHAIR_COLORS_FILE, table.concat(lines, "\n") .. "\n")
end

-- Switches the game's crosshair colours to the keys; a colour that is not a key is the player's own (first run, or
-- changed in the game's options since) and becomes the colour shown on the gun.
local function applyCrosshairKeys()
	local now = os.clock()
	if crosshairKeysApplied and now < crosshairKeyNextCheck then return true end
	crosshairKeyNextCheck = now + 0.5
	local player = getOakLocalPlayer()
	if player == nil then return false end
	if crosshairOriginals == nil then crosshairOriginals = loadCrosshairOriginals() end
	local changed = false
	for i, k in ipairs(CROSSHAIR_KEYS) do
		local c = player[k.get](player)
		if c ~= nil and not isKeyColor(c, k.key) then
			if not looksLikeKey(c) then
				crosshairOriginals[i] = { c.R, c.G, c.B }
				changed = true
			end
			player[k.set](player, uevrUtils.color_from_rgba(k.key[1], k.key[2], k.key[3], 1.0))
		end
	end
	if changed then
		saveCrosshairOriginals()
		log("game crosshair: colour key on (real colours saved)")
	end
	if changed or crosshairColorsCsv == nil then updateCrosshairColorsCsv() end
	crosshairKeysApplied = true
	return true
end

local function restoreCrosshairColors()
	if not crosshairKeysApplied then return end
	crosshairKeysApplied = false
	local player = getOakLocalPlayer()
	if player == nil or crosshairOriginals == nil then return end
	for i, k in ipairs(CROSSHAIR_KEYS) do
		local c = crosshairOriginals[i] or k.default
		player[k.set](player, uevrUtils.color_from_rgba(c[1], c[2], c[3], 1.0))
	end
end

-- once per session: keys left in the game's settings by a crash go back to the saved real colours
local crosshairLeftoverChecked = false
local function restoreLeftoverCrosshairKeys()
	local player = getOakLocalPlayer()
	if player == nil then return false end
	local originals = loadCrosshairOriginals()
	for i, k in ipairs(CROSSHAIR_KEYS) do
		if looksLikeKey(player[k.get](player)) then
			local c = originals[i] or k.default
			player[k.set](player, uevrUtils.color_from_rgba(c[1], c[2], c[3], 1.0))
			log("game crosshair: restored a leftover key colour")
		end
	end
	return true
end

uevr.sdk.callbacks.on_script_reset(function() pcall(restoreCrosshairColors) end)

local function measureGameReticle()
	local pawn = getPlayerCharacter()
	if pawn == nil or configui.getValue("bl4_weapon_on_hand") == false then return nil, "no character" end
	local pc = uevr.api:get_player_controller(0)
	if pc ~= nil and pc.bShowMouseCursor == true then return nil, "menu open" end
	local weapon = getHeldWeapon(pawn)
	local mesh = weapon ~= nil and getFirstPersonWeaponMesh(weapon) or nil
	if mesh == nil then return nil, "no gun" end
	if muzzleSocketName == nil then muzzleSocketName = uevrUtils.fname_from_string("Muzzle") end
	if not mesh:DoesSocketExist(muzzleSocketName) then return nil, "no muzzle (melee / unarmed)" end
	local controller = uevrUtils.getValid(controllers.getController(1, true))
	if controller == nil then return nil, "no right controller component" end

	local muzzle = mesh:GetSocketLocation(muzzleSocketName)
	local forward = kismet_math_library:GetForwardVector(mesh:GetSocketRotation(muzzleSocketName))
	local maxDistance = (configui.getValue("bl4_ret_game_maxdist") or 50.0) * 100.0
	local hit = uevrUtils.getTargetLocation(muzzle, forward, 0, { pawn }, false, 10, maxDistance)
	local distance = hit ~= nil and uevrUtils.vectorDistance(muzzle, hit) or maxDistance
	if distance < 10 then distance = 10 end

	local controllerLocation = controller:K2_GetComponentLocation()
	local controllerRotation = controller:K2_GetComponentRotation()
	local origin = kismet_math_library:LessLess_VectorRotator(kismet_math_library:Subtract_VectorVector(muzzle, controllerLocation), controllerRotation)
	local direction = kismet_math_library:LessLess_VectorRotator(forward, controllerRotation)
	local poseType = (configui.getValue("bl4_ret_game_pose") or 1) - 1
	if not applyCrosshairKeys() then return nil, "no local player" end
	return string.format("1,%.2f,%.3f,%.3f,%.3f,%.5f,%.5f,%.5f,%d,%.3f,%d,0,0,%s", distance,
		origin.X, origin.Y, origin.Z, direction.X, direction.Y, direction.Z,
		math.floor(configui.getValue("bl4_ret_game_crop") or 256), configui.getValue("bl4_ret_game_scale") or 1.0, poseType,
		crosshairColorsCsv), "showing"
end

uevrUtils.registerPreEngineTickCallback(function()
	local text, status = nil, "off"
	if configui.getValue("bl4_ret_game") ~= false and gameReticleSupported ~= false then
		local ok, result, reason = pcall(measureGameReticle)
		if ok then text, status = result, reason else status = "error: " .. tostring(result) end
	elseif gameReticleSupported == false then
		status = "not supported by this UEVR build"
	end

	if text ~= nil then
		local ok = pcall(sendGameReticle, text)
		gameReticleActive = ok and gameReticleSupported == true
	else
		if gameReticleLastText ~= "0" then pcall(sendGameReticle, "0") end
		gameReticleActive = false
	end
	-- the keys only while the backend is moving the crosshair; otherwise the HUD shows the player's real colours
	if not gameReticleActive then
		if crosshairKeysApplied then
			pcall(restoreCrosshairColors)
		elseif not crosshairLeftoverChecked then
			local ok, done = pcall(restoreLeftoverCrosshairKeys)
			crosshairLeftoverChecked = not ok or done == true
		end
	end
	setGameReticleStatus(status)
end)

-- ---------------------------------------------------------------------------------------------
-- Weapon spawner (developer mode): BL4's own loot code, OakInventoryStatics.SpawnInventoryFromCharacter(owner context,
-- inventory type "<MFR>_<TYPE>", comp "", instancing 0, owner only false, owner) - drops a real, usable item pickup a
-- few metres from the character after a short delay (MCP 2026-10-30: "DAD_PS" -> Daedalus pistol, picked up and
-- equipped). Type names come from the item data (Nexus inventory aspects inv_aspect-<mfr>_<type>_...); a combination
-- the game does not have spawns nothing. For setting up attachment offsets and hand grips per weapon.
-- ---------------------------------------------------------------------------------------------
local SPAWN_MANUFACTURERS = { "DAD", "JAK", "MAL", "ORD", "BOR", "TED", "TOR", "VLA" } -- order = panel combo
local SPAWN_TYPES = { "PS", "SM", "AR", "SG", "SR", "HW" }
local inventoryStatics = nil

local function spawnWeapon(inventoryType)
	local pawn = getPlayerCharacter()
	if pawn == nil then return false end
	if inventoryStatics == nil then inventoryStatics = uevrUtils.find_default_instance("Class /Script/OakGame.OakInventoryStatics") end
	if inventoryStatics == nil then return false end
	local ok, err = pcall(function() inventoryStatics:SpawnInventoryFromCharacter(pawn, inventoryType, "", 0, false, pawn) end)
	if not ok then log("spawn " .. inventoryType .. " failed: " .. tostring(err)) end
	return ok
end

local function spawnSelected(allTypes)
	local manufacturer = SPAWN_MANUFACTURERS[configui.getValue("bl4_spawn_manufacturer") or 1]
	local types = allTypes and SPAWN_TYPES or { SPAWN_TYPES[configui.getValue("bl4_spawn_type") or 1] }
	local requested = {}
	for _, weaponType in ipairs(types) do
		local name = manufacturer .. "_" .. weaponType
		if spawnWeapon(name) then table.insert(requested, name) end
	end
	local text = #requested > 0 and ("Requested " .. table.concat(requested, ", ") .. " - drops near you in a moment (types the game lacks spawn nothing)")
		or "Not spawned - load into gameplay as your character first"
	configui.setLabel("bl4_spawn_status", text)
	log(text)
end

-- Ordnance: the same loot call with the inventory root "<mfr>_grenade_gadget" (lowercase; Ripper = "borg"). The asset
-- names (Body_TOR_GRN_Inv, SK_JAK_GRN) are NOT inventory types: "<MFR>_GRN" spawned nothing (2026-11-09). The roots come
-- from item serials (superexboom/Borderlands4-SaveEditor embedded_serial_catalog.json: dad/jak/ord/tor/vla/borg seen,
-- next to the weapon roots DAD_PS etc. that this spawner already uses). A manufacturer without ordnance spawns nothing.
local ORDNANCE_ROOT_PREFIX = { DAD = "dad", JAK = "jak", MAL = "mal", ORD = "ord", BOR = "borg", TED = "ted", TOR = "tor", VLA = "vla" }
local function spawnOrdnance(allManufacturers)
	local manufacturers = allManufacturers and SPAWN_MANUFACTURERS
		or { SPAWN_MANUFACTURERS[configui.getValue("bl4_spawn_manufacturer") or 1] }
	local requested = {}
	for _, manufacturer in ipairs(manufacturers) do
		local name = (ORDNANCE_ROOT_PREFIX[manufacturer] or manufacturer:lower()) .. "_grenade_gadget"
		if spawnWeapon(name) then table.insert(requested, name) end
	end
	local text = #requested > 0 and ("Requested " .. table.concat(requested, ", ") .. " - drops near you in a moment (manufacturers without ordnance spawn nothing)")
		or "Not spawned - load into gameplay as your character first"
	configui.setLabel("bl4_spawn_status", text)
	log(text)
end

-- configui button callbacks run on the draw thread; UFunction calls go on the game thread
configui.onUpdate("bl4_spawn_one", function() uevrUtils.setTimeout(1, function() spawnSelected(false) end) end)
configui.onUpdate("bl4_spawn_all_types", function() uevrUtils.setTimeout(1, function() spawnSelected(true) end) end)
configui.onUpdate("bl4_spawn_ordnance", function() uevrUtils.setTimeout(1, function() spawnOrdnance(false) end) end)
configui.onUpdate("bl4_spawn_all_ordnance", function() uevrUtils.setTimeout(1, function() spawnOrdnance(true) end) end)

-- ---------------------------------------------------------------------------------------------
-- Camera stabilisation (as Hellraiser's camera_stabilize.lua). OakPlayerCameraManager.ModifierList (MCP 2026-10-30):
-- CameraAnimationCameraModifier (camera animation sequences - melee swings), CameraModifier_GbxCameraShake and
-- CameraModifier_CameraShake (shakes: melee impacts, shots, hits). Disabled modifiers apply nothing to the view; the
-- game can re-enable them, so they are re-checked every second. Unticking re-enables them.
-- ---------------------------------------------------------------------------------------------
local CAMERA_MODIFIERS = {
	CameraAnimationCameraModifier = "bl4_no_camera_anim",
	CameraModifier_GbxCameraShake = "bl4_no_camera_shake",
	CameraModifier_CameraShake = "bl4_no_camera_shake",
}
local cameraModifierState = {} -- modifier -> disabled by us (true) / re-enabled by us (false)
local nextCameraRefresh = 0

local function refreshCameraModifiers()
	local pc = uevr.api:get_player_controller(0)
	if pc == nil then return end
	local cm = pc.PlayerCameraManager
	if uevrUtils.getValid(cm) == nil then return end
	local list = cm.ModifierList
	if list == nil then return end
	local stopShakes = false
	for i = 1, #list do
		local mod = list[i]
		local optionID = mod ~= nil and CAMERA_MODIFIERS[uevrUtils.getShortName(mod:get_class())] or nil
		if optionID ~= nil then
			local wantDisabled = configui.getValue(optionID) ~= false
			if wantDisabled then
				if mod:IsDisabled() == false then mod:DisableModifier(true) end
				if optionID == "bl4_no_camera_shake" then stopShakes = true end
			elseif cameraModifierState[mod] == true then
				mod:EnableModifier()
			end
			cameraModifierState[mod] = wantDisabled
		end
	end
	if stopShakes and cm.StopAllCameraShakes ~= nil then cm:StopAllCameraShakes(true) end
end

uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
	local now = os.clock()
	if now < nextCameraRefresh then return end
	nextCameraRefresh = now + 1.0
	local ok, err = pcall(refreshCameraModifiers)
	if not ok then log("camera modifiers: " .. tostring(err)) end
end)
-- Camera kick: the melee sway is not a modifier. Gearbox camera-mode behaviours write it into
-- OakPlayerCameraManager.CameraModeState.CameraRotationOffset (MCP watch 2026-10-30: up to ~4 deg yaw / ~1 deg
-- pitch+roll per swing, back to 0 after; ControlRotation, pawn and FirstPersonArms do not move) and it is applied in
-- the same camera update that builds the view, so it cannot be zeroed from a tick. The VR view's base rotation is
-- replaced with the control rotation's yaw instead (pitch / roll 0: decoupled pitch), which carries no camera-mode
-- offset; the HMD rotation is added on top as usual. Player character on foot only (vehicles / cinematics keep the
-- game camera).
-- EARLY stereo callback, not the pre one: the backend's UObjectHook places the motion controllers (VR hands, gripped
-- weapon) from the view rotation in its own pre callback, which runs before Lua's pre callbacks - there the hands
-- kept the kick while the eyes did not. Early callbacks run for every mod before any pre callback.
-- With a UEVR aim method on (VR_AimMethod Head / controller - the game's interaction trace and prompts then follow
-- the head), ControlRotation carries the HMD yaw while the incoming view rotation does not (UEVR keeps the aim out of
-- the view); the control yaw as view base turned the view twice with the head (2026-10-30). Then the base is the
-- incoming view yaw minus the camera-mode offsets instead.
-- UEVR's head aim (IXRTrackingSystemHook::update_view_rotation) writes base + HMD into the game rotation and then
-- recenter_view()s, so the eyes lose the HMD yaw on the assumption that the game camera turns with that rotation.
-- BL4's camera does not (MCP 2026-10-30: ControlRotation 129.9 with the head turned, camera POV stayed 124.5 - BL4
-- keeps its own rotation), so the view stayed glued to the face: head left -> world turned with it. The recenter
-- leaves UEVR's rotation offset = -HMD yaw; subtracting the offset's yaw from the base puts the head yaw back.
local rotationOffsetQuat = Quaternionf.new(0, 0, 0, 0)
local function uevrRotationOffsetYaw()
	uevr.params.vr.get_rotation_offset(rotationOffsetQuat)
	local q = rotationOffsetQuat
	-- UEVR (SteamVR, Y up) -> Unreal quaternion: (X = q.Z, Y = q.X, Z = -q.Y, W = q.W) (as libs/input.lua); yaw about Z
	local x, y, z, w = q.Z, q.X, -q.Y, q.W
	return math.deg(math.atan(2 * (w * z + x * y), 1 - 2 * (y * y + z * z)))
end

-- Roomscale turning (option bl4_roomscale, default on; 2026-11-05). With the above, the head yaw lived only in UEVR's
-- rotation offset and the rendered view: physically turning never turned the game's rotation, so the pawn, its capsule
-- and the camera the game traces from kept facing the old way and interaction prompts did not show. OW2 / Hellraiser
-- turn the pawn through libs/input.lua (pawnRotationMode Locked: SetControlRotation + root rotation), but BL4 reverts
-- those writes; ClientSetRotation(rot, true) sticks and turns the camera, the pawn actor and the capsule together
-- (MCP 2026-11-05: all three went 58.8 -> 88.8). So every frame the CHANGE of the head yaw (relative to the game, = minus
-- UEVR's offset yaw) is added to the game rotation with ClientSetRotation; the right stick still turns on top.
-- roomscaleApplied = head yaw already put into the game. The view takes the current head yaw at render time minus that
-- (no double turn, no added latency), and the movement stick is only rotated by what is not applied yet.
local roomscaleApplied = nil
local function roomscaleEnabled() return configui.getValue("bl4_roomscale") ~= false end

local kickLockActive = false
local uevrAimActive = false
local cameraModeState = nil
uevr.sdk.callbacks.on_early_calculate_stereo_view_offset(function(device, view_index, world_to_meters, position, rotation, is_double)
	if not kickLockActive or rotation == nil then return end
	local yaw = nil
	if uevrAimActive then
		if cameraModeState == nil then return end
		pcall(function()
			yaw = rotation.Yaw - cameraModeState.CameraRotationOffset.Yaw - cameraModeState.BaseRotationOffset.Yaw
				- uevrRotationOffsetYaw() - (roomscaleApplied or 0)
		end)
	else
		local pc = uevr.api:get_player_controller(0)
		local control = pc ~= nil and pc:GetControlRotation() or nil
		if control ~= nil then yaw = control.Yaw end
	end
	if yaw == nil then return end
	rotation.Pitch = 0
	rotation.Yaw = yaw
	rotation.Roll = 0
end)

-- Head-relative movement with UEVR head aim: UEVR skips its own movement-orientation stick rotation when Movement
-- Orientation equals the Aim Method (VR.cpp, assumes the game moves along the aim). BL4 moves along its own internal
-- rotation, which never gets the head yaw (see above), so forward stayed body-forward (2026-10-30). The left stick is
-- rotated here by the head yaw relative to that base: minus the yaw of UEVR's rotation offset after its per-frame
-- recenter (the same quantity the view correction adds back). Keep UEVR Movement Orientation on Head/HMD or Game.
local HMD_AIM_METHOD = 1
local STICK_MAX = 32767
uevrUtils.registerOnPreInputGetStateCallback(function(retval, user_index, state)
	if not kickLockActive or uevr.params.vr.get_aim_method() ~= HMD_AIM_METHOD then return end
	local lx, ly = state.Gamepad.sThumbLX, state.Gamepad.sThumbLY
	if lx == 0 and ly == 0 then return end
	local ok, headYaw = pcall(function() return -uevrRotationOffsetYaw() end)
	if not ok or headYaw == nil then return end
	-- roomscale: the game's forward already carries the applied head yaw
	headYaw = headYaw - (roomscaleApplied or 0)
	local rad = math.rad(headYaw)
	local c, s = math.cos(rad), math.sin(rad)
	-- stick Y = forward, X = right; a positive (UE) yaw turns right
	local forward = ly * c - lx * s
	local right = ly * s + lx * c
	state.Gamepad.sThumbLY = math.floor(math.max(-STICK_MAX, math.min(STICK_MAX, forward)) + 0.5)
	state.Gamepad.sThumbLX = math.floor(math.max(-STICK_MAX, math.min(STICK_MAX, right)) + 0.5)
end)

-- Game pitch: with decoupled pitch the view pitch is the HMD's, but the game keeps its own pitch from the right stick
-- and it drifts (MCP 2026-10-30: 61 deg, later 88 deg). Near the pole the per-shot recoil pitch kick shows up as a
-- 3-4 deg yaw + roll swing of ControlRotation (gimbal) - and the view yaw above comes from ControlRotation. It also
-- tilted the hands (FirstPersonArms follow the game pitch). BL4 ignores SetControlRotation and direct field writes;
-- ClientSetRotation(rot, bResetCamera = true) takes (verified live). Re-levelled when more than LEVEL_PITCH_LIMIT
-- off level, which leaves the recoil kick itself (~0.2 deg, recovers) alone.
-- With UEVR head aim, ControlRotation pitch is the HEAD's (UEVR writes it every frame), but BL4's camera mode keeps a
-- hidden pitch of its own that the right stick (and recoil climb) still moves. Pushed to the pole (MCP 2026-10-31:
-- CameraModeState.POV pitch 88 while ControlRotation pitch was 17) every shot became a 3-10 deg yaw swing of
-- ControlRotation that head aim passed into the view and the pawn turned after ("camera / pawn movement when firing").
-- So under head aim the hidden pitch is measured on CameraModeState.POV (the grapple hand-aim overrides the camera
-- CACHE, not this) and levelled the same way; ClientSetRotation(0, camera yaw) levelled it live without moving the view,
-- and head aim puts ControlRotation pitch straight back on the head.
local LEVEL_PITCH_LIMIT = 5.0
local function levelGamePitch(cameraModeState)
	local pc = uevr.api:get_player_controller(0)
	if pc == nil then return end
	local rot = nil
	if cameraModeState ~= nil then
		rot = cameraModeState.POV.Rotation
	else
		rot = pc:GetControlRotation()
	end
	if rot == nil then return end
	local pitch = rot.Pitch
	if pitch > 180 then pitch = pitch - 360 end
	if math.abs(pitch) <= LEVEL_PITCH_LIMIT then return end
	pc:ClientSetRotation(uevrUtils.rotator(0, rot.Yaw, 0), true)
end

uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
	-- not in cutscenes: the view must keep the cine camera's yaw (the control yaw put the view ~90 deg off, 2026-11-05)
	local onFoot = getPlayerCharacter() ~= nil and not uevrUtils.isInCutscene()
	kickLockActive = configui.getValue("bl4_no_camera_kick") ~= false and onFoot
	uevrAimActive = uevr.params.vr.get_aim_method() ~= 0
	cameraModeState = nil
	if kickLockActive and uevrAimActive then
		pcall(function()
			local cms = uevr.api:get_player_controller(0).PlayerCameraManager.CameraModeState
			if uevrUtils.getValid(cms) ~= nil then cameraModeState = cms end
		end)
	end
	-- no aim method: the game pitch is ControlRotation's; head aim: the camera mode's hidden pitch (see above)
	if onFoot and configui.getValue("bl4_level_game_pitch") ~= false and (not uevrAimActive or cameraModeState ~= nil) then
		local ok, err = pcall(levelGamePitch, uevrAimActive and cameraModeState or nil)
		if not ok then log("level game pitch: " .. tostring(err)) end
	end
	-- roomscale turning (see roomscaleApplied): head aim on foot only, outside menus / cutscenes
	local roomscaleActive = kickLockActive and cameraModeState ~= nil and uevr.params.vr.get_aim_method() == HMD_AIM_METHOD
		and roomscaleEnabled()
	if roomscaleActive then
		local ok, err = pcall(function()
			local head = -uevrRotationOffsetYaw()
			if roomscaleApplied == nil then roomscaleApplied = 0 end -- the first frame turns the game to the view
			local delta = uevrUtils.clampAngle180(head - roomscaleApplied)
			if math.abs(delta) < 0.05 then return end
			local rot = cameraModeState.POV.Rotation
			uevr.api:get_player_controller(0):ClientSetRotation(uevrUtils.rotator(rot.Pitch, rot.Yaw + delta, 0), true)
			roomscaleApplied = head
		end)
		if not ok then log("roomscale: " .. tostring(err)) end
	elseif roomscaleApplied ~= nil then
		-- switched off on foot: take the applied head yaw back out of the game so the view does not jump
		if kickLockActive and cameraModeState ~= nil and not roomscaleEnabled() then
			pcall(function()
				local rot = cameraModeState.POV.Rotation
				uevr.api:get_player_controller(0):ClientSetRotation(uevrUtils.rotator(rot.Pitch, rot.Yaw - roomscaleApplied, 0), true)
			end)
		end
		roomscaleApplied = nil
	end
end)

-- Under head aim the right stick's up/down only feeds that hidden pitch (the view pitch is the HMD's, the grapple aims
-- with the hand): it is kept from the game on foot, so the pitch cannot be pushed to the pole in the first place.
uevrUtils.registerOnPreInputGetStateCallback(function(retval, user_index, state)
	if not kickLockActive or not uevrAimActive or configui.getValue("bl4_block_stick_pitch") == false then return end
	state.Gamepad.sThumbRY = 0
end)

configui.onUpdate("bl4_no_camera_shake", function(value) nextCameraRefresh = 0 end)
configui.onUpdate("bl4_no_camera_anim", function(value) nextCameraRefresh = 0 end)
uevrUtils.registerPreLevelChangeCallback(function(level) cameraModifierState = {} end)

-- ---------------------------------------------------------------------------------------------
-- Input (Input panel, data/input_parameters.json): body / aim / turning. Only for the player character - menu and
-- vehicle pawns keep the game camera (input.lua pins the VR camera to the pawn root every frame).
-- ---------------------------------------------------------------------------------------------
input.registerIsDisabledCallback(function()
	if getPlayerCharacter() == nil then return true, 100 end
	return nil
end)
input.init()

-- Main menu (no pawn at all): UEVR's head / controller aim writes the HMD yaw into the control rotation, and the menu
-- camera follows it, so turning the head turned the camera the same way and the scene slid the opposite way
-- (xaero 2026-11-04). Without a pawn the aim method is Game (0) and the view is recentred once, so the menu sits in
-- front; with a pawn again the panel's gameplay aim method is restored. The gameplay value comes from the panel, not
-- from UEVR's live setting: UEVR saves the live value at exit, so quitting from the main menu would store Game.
-- In-game cutscenes (ViewTarget = OakCineCameraActor, libs cutscene detection) get the same treatment: the aim is not
-- needed there and the recentre puts the shot in front, as the flat game frames it. data/ui_parameters.json "cutscene"
-- disables libs/input.lua meanwhile (it forced the VR view into the pawn's head instead of the cine camera) and hides
-- the VR hands / IK arms.
-- The libs' own cutscene check reads PlayerCameraManager.ViewTarget.Target, but BL4's reflection spells that member
-- "target" (lowercase, MCP 2026-11-04), so it never saw the cine camera. The profile detects it itself through the
-- GetViewTarget() function and feeds the result to the libs with setIsInCutsceneOverride.
-- Vehicles (2026-11-06): the vehicle camera orbits the car following the control rotation, and UEVR's head aim wrote the
-- head yaw into it, so turning the head swung the chase camera round the car and the world slid the opposite way
-- (xaero). While driving the aim method is Game too: the right stick steers (BL4 vehicles drive toward the camera's yaw)
-- and the head only looks around. bl4_vr_vehicle.lua puts the view in the driver's seat.
local AIM_GAME = 0
local aimState = nil -- "menu" / "vehicle" / "pawn"; nil = not applied yet (covers a saved Game value)
local cineCameraClass = nil
local function isViewingCineCamera()
	if cineCameraClass == nil then cineCameraClass = uevrUtils.get_class("Class /Script/CinematicCamera.CineCameraActor") end
	if cineCameraClass == nil then return false end
	local ok, result = pcall(function()
		local target = uevr.api:get_player_controller(0):GetViewTarget()
		return target ~= nil and target:is_a(cineCameraClass)
	end)
	return ok and result == true
end
local function gameplayAimMethod()
	local index = configui.getValue("bl4_gameplay_aim")
	return (type(index) == "number" and index >= 1 and index <= 3) and index or HMD_AIM_METHOD
end
local function setAimMethod(method)
	pcall(function() uevr.params.vr.set_aim_method(method) end)
end
uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
	local noPawn = uevr.api:get_local_pawn(0) == nil
	local inCutscene = not noPawn and isViewingCineCamera()
	uevrUtils.setIsInCutsceneOverride(inCutscene)
	local state = (noPawn or inCutscene) and "menu" or (getVehicle() ~= nil and "vehicle" or "pawn")
	if state == aimState then return end
	aimState = state
	if state == "pawn" then
		setAimMethod(gameplayAimMethod())
		log("pawn: aim method " .. tostring(gameplayAimMethod()))
	else
		setAimMethod(AIM_GAME)
		pcall(function() uevr.params.vr.recenter_view() end)
		log(state .. ": aim method Game, view recentred")
	end
end)
configui.onUpdate("bl4_gameplay_aim", function(value)
	if aimState == "pawn" then setAimMethod(gameplayAimMethod()) end
end)

log("loaded")
