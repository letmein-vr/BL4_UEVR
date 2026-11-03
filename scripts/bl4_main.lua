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
local montage = require('libs/montage')
local ui = require('libs/ui')

-- developer mode: Input / Pawn / Attachments dev panels (settings saved in data/input_parameters.json,
-- data/pawn_parameters.json, data/attachments_parameters.json; they still apply with developer mode off)
uevrUtils.setDeveloperMode(true)
-- hands configuration tool (hands wizard): build the VR hands from the FirstPersonArms mesh; comment out once
-- data/hands_parameters.json exists and the hands are tuned
hands.enableConfigurationTool()
-- developer mode shows the Attachments panel (per-weapon grip offsets saved in data/); barrel along +X.
-- New weapons start at the tuned right-hand pistol grip location (xaero, 2026-10-30); saved per-weapon offsets win.
attachments.init(true, nil, {4.6, -1.4, 4.1}, {0,0,0})

-- Panel sections: the "Borderlands 4" panel is built by zz_bl4_vr_panel.lua from _G.BL4_SECTIONS (bl4_ik.lua and
-- bl4_two_handed.lua add theirs); saved values live in data/bl4_config.json.
_G.BL4_SECTIONS = _G.BL4_SECTIONS or {}
table.insert(_G.BL4_SECTIONS, { order = 0, label = "General", layout = {
	{ widgetType = "checkbox", id = "bl4_weapon_on_hand", label = "Weapon on the right hand", initialValue = true },
	{ widgetType = "checkbox", id = "bl4_no_camera_shake", label = "Disable camera shakes (melee, shooting, hits)", initialValue = true },
	{ widgetType = "checkbox", id = "bl4_no_camera_anim", label = "Disable camera animations (melee etc.)", initialValue = true },
	{ widgetType = "checkbox", id = "bl4_no_camera_kick", label = "Disable camera kick (melee view sway)", initialValue = true },
	{ widgetType = "checkbox", id = "bl4_level_game_pitch", label = "Keep the game's pitch level (stops recoil view sway)", initialValue = true },
	{ widgetType = "checkbox", id = "bl4_block_stick_pitch", label = "Ignore right stick up/down on foot with head aim", initialValue = true },
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

local createPoseableMeshFromSkeletalMesh = uevrUtils.createPoseableMeshFromSkeletalMesh
uevrUtils.createPoseableMeshFromSkeletalMesh = function(skeletalMeshComponent, options)
	local copy = createPoseableMeshFromSkeletalMesh(skeletalMeshComponent, options)
	if copy == nil or skeletalMeshComponent == nil then return copy end
	-- Copies keep their source's Gearbox foreground layer. The first-person gun is a bGbxForeground primitive; VR hands
	-- left in the normal scene did not depth-sort against it (wrong overlap at the grip). Same layer = correct sorting
	-- (confirmed 2026-10-30); the backend gives the foreground layer the stereo projection.
	pcall(function()
		if skeletalMeshComponent.bGbxForeground == true and copy.SetGbxForeground ~= nil then copy:SetGbxForeground(true) end
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
attachments.registerOnGripUpdateCallback(function()
	if configui.getValue("bl4_weapon_on_hand") == false then return end
	local pawn = getPlayerCharacter()
	if pawn == nil then return end
	local weapon = getHeldWeapon(pawn)
	if weapon == nil then return end
	local mesh = getFirstPersonWeaponMesh(weapon)
	if mesh == nil or mesh.SkeletalMesh == nil then return end -- no mesh asset yet (first frames after equip)
	local parent = nil
	if hands.exists() then parent = hands.getHandComponent(Handed.Right) end
	return mesh, parent, nil, nil, nil, nil, true, true
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
	reticule.setHidden(location == nil)
	if location == nil then return uevrUtils.vector(0, 0, 0), uevrUtils.rotator(0, 0, 0) end
	return location, rotation
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

-- configui button callbacks run on the draw thread; UFunction calls go on the game thread
configui.onUpdate("bl4_spawn_one", function() uevrUtils.setTimeout(1, function() spawnSelected(false) end) end)
configui.onUpdate("bl4_spawn_all_types", function() uevrUtils.setTimeout(1, function() spawnSelected(true) end) end)

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
				- uevrRotationOffsetYaw()
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
	local onFoot = getPlayerCharacter() ~= nil
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

log("loaded")
