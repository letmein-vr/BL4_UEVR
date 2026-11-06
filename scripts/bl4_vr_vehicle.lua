-- Vehicles: first-person view from the driver's seat, IK arms on the handlebars (2026-11-06).
--
-- View. BL4 vehicles only have a chase camera: OakPlayerCameraManager.CameraModeState.CameraLocationOffset is about
-- (-550, 0, +175) behind the car (MCP 2026-11-06, Grazer), orbiting it with the control rotation. bl4_main.lua switches
-- the aim method to Game while driving (the right stick steers - BL4 vehicles drive toward the camera's yaw - and the
-- head only looks around); this script moves the VR view from the chase camera to the driver's head:
-- - position: the driver's (OakVehicle.DriverPawn) Head bone, held in the vehicle mesh's own frame and smoothed, so
--   steering / bump animations of the driver do not shake the view, but the view stays fixed to the car;
-- - rotation: level (pitch / roll 0), yaw = the aim (control rotation, like the flat game's camera) or the vehicle
--   body (option);
-- - the driver's head bone is hidden, so the view is not inside the head mesh.
-- EARLY stereo callback, like bl4_main's view correction: the HMD pose is added on top by UEVR afterwards.
--
-- IK Arms mode (xaero 2026-11-06: the game's arms out, the IK arms on the handlebars, no per-vehicle tuning). The game
-- animates the driver's third-person body onto the vehicle's controls, so that pose is the reference:
-- - the driver's arms are hidden (HideBoneByName R/L_Upperarm: render only, the bones keep animating); the rest of
--   the body stays visible;
-- - the IK rig is placed in the seat: its shoulders' midpoint on the driver's (R/L_Upperarm), yaw = the vehicle's
--   (libs/ik.lua setMeshPlacementOverride: after the rig's normal coupling, before the solve). Without it the rig sat
--   100 cm low (ik.lua takes the height from the pawn's capsule; the vehicle pawn has none) and turned with the head;
-- - each IK hand is pinned to the driver's hand bone (on_accessory_attach, parent = driver mesh, socket R_Hand / L_Hand).
--   The solver puts the hand bone at target * (end_bone_offset, end_bone_rotation) - the controller-to-hand offsets -
--   so the attach offset is the inverse of that transform and the IK hand lands exactly on the driver's hand. The 1P
--   arms and the 3P body share the hand-bone axes (MCP: fingers along +X, index toward +Z on both), so the grip
--   rotation carries over unchanged;
-- - the finger bones copy the driver's grip, relative to the hand (same names on both skeletons).
-- No motion-controller components exist while driving (UObjectHook lists none), so nothing else drives the hands.

local uevrUtils = require('libs/uevr_utils')
local configui = require('libs/configui')
local ik = require('libs/ik')
local hands = require('libs/hands')

local function log(text)
	pcall(function() uevrUtils.print("[bl4 vehicle] " .. tostring(text), LogLevel.Info) end)
end

_G.BL4_SECTIONS = _G.BL4_SECTIONS or {}
table.insert(_G.BL4_SECTIONS, { order = 5, label = "Vehicles", layout = {
	{ widgetType = "checkbox", id = "bl4_vehicle_first_person", label = "First-person view from the driver's seat", initialValue = true },
	{ widgetType = "combo", id = "bl4_vehicle_view_yaw", label = "View turns with", initialValue = 1,
		selections = { "The aim (right stick, like the flat game)", "The vehicle body" } },
	{ widgetType = "drag_float3", id = "bl4_vehicle_eye_offset", label = "Eye offset from the driver's head (forward, right, up; cm)",
		initialValue = { 0.0, 0.0, 0.0 }, range = {-100, 100}, speed = 0.5 },
	{ widgetType = "checkbox", id = "bl4_vehicle_ik_hands", label = "IK Arms: hide the driver's arms, IK hands on the vehicle's controls", initialValue = true },
	{ widgetType = "checkbox", id = "bl4_vehicle_gaze_aim", label = "Aim the vehicle's guns with your head (gaze)", initialValue = true },
}})

-- Gaze aim for the vehicle's guns lives in plugins/BL4AimFix.dll (light-projectile spawn hook): the shot keeps the
-- game's muzzle and spread and points along the HMD gaze instead of the chase camera. The option state goes to the
-- plugin as custom event "bl4.vehicle_gaze_aim" on change and every 10 s (a reloaded plugin starts at its default).
local function sendGazeAim()
	pcall(function() uevr.api:dispatch_custom_event("bl4.vehicle_gaze_aim", configui.getValue("bl4_vehicle_gaze_aim") == false and "0" or "1") end)
end
configui.onUpdate("bl4_vehicle_gaze_aim", function(value) sendGazeAim() end)
uevrUtils.setInterval(10000, sendGazeAim)
uevrUtils.setTimeout(1000, sendGazeAim)

local SMOOTH_TIME = 0.25 -- seconds: time constant of the head-position low-pass (in the car's frame)
local HANDS_MODE_IK = 2
local FINGERS = { "Thumb", "Index", "Middle", "Ring", "Pinky" }
local FINGER_PARTS = { "_Meta", "_01", "_02", "_03" } -- parent first

local fnames = {}
local function fname(s)
	local n = fnames[s]
	if n == nil then n = uevrUtils.fname_from_string(s) fnames[s] = n end
	return n
end

local function alive(obj)
	return obj ~= nil and uevrUtils.getValid(obj) ~= nil
end

local function vec3(id)
	local v = configui.getValue(id)
	if type(v) == "table" or type(v) == "userdata" then
		local ok, x, y, z = pcall(function() return v.X or v.x or v[1], v.Y or v.y or v[2], v.Z or v.z or v[3] end)
		if ok and type(x) == "number" and type(y) == "number" and type(z) == "number" then return x, y, z end
	end
	return 0, 0, 0
end

local function firstPersonEnabled() return configui.getValue("bl4_vehicle_first_person") ~= false end
local function ikSeatWanted()
	return configui.getValue("bl4_vehicle_ik_hands") ~= false and _G.getHandsMode ~= nil and _G.getHandsMode() == HANDS_MODE_IK
end

local function getVehicle()
	return _G.bl4 ~= nil and _G.bl4.getVehicle ~= nil and _G.bl4.getVehicle() or nil
end

local function driverMeshOf(vehicle)
	local mesh = nil
	pcall(function()
		local driver = uevrUtils.getValid(vehicle.DriverPawn)
		mesh = driver ~= nil and uevrUtils.getValid(driver.Mesh) or nil
	end)
	return mesh
end

-- ---------------------------------------------------------------------------------------------
-- Driver head bone (view inside the head)
-- ---------------------------------------------------------------------------------------------
local headHiddenMesh = nil

local function restoreHead()
	if headHiddenMesh ~= nil then
		pcall(function() if alive(headHiddenMesh) then headHiddenMesh:UnHideBoneByName(fname("Head")) end end)
		headHiddenMesh = nil
	end
end

local function hideHead(mesh)
	if headHiddenMesh == mesh then return end
	restoreHead()
	pcall(function() mesh:HideBoneByName(fname("Head"), 0) end) -- 0 = PBO_None
	headHiddenMesh = mesh
end

-- ---------------------------------------------------------------------------------------------
-- IK seat: driver's arms hidden, rig in the seat, hands pinned, fingers copied
-- ---------------------------------------------------------------------------------------------
local seat = nil -- { driverMesh, root, rigShoulders = {}, fingers = nil, fingerRig = nil }

-- Only the driver's arms are hidden (xaero): the upper arm bones and everything under them. HideBoneByName only zeroes
-- the bones for rendering; their transforms keep animating, so the IK hands stay pinned to the hand bones.
local ARM_BONES = { "R_Upperarm", "L_Upperarm" }

local function hideArms(mesh)
	for _, bone in ipairs(ARM_BONES) do
		pcall(function() mesh:HideBoneByName(fname(bone), 0) end) -- 0 = PBO_None
	end
	return mesh
end

local function restoreArms(mesh)
	if not alive(mesh) then return end
	for _, bone in ipairs(ARM_BONES) do
		pcall(function() mesh:UnHideBoneByName(fname(bone)) end)
	end
end

-- shoulders' midpoint: rig mesh (component space, cached per rig mesh) and driver (world)
local function rigShoulderMid(mesh)
	local key = mesh:get_address()
	local mid = seat.rigShoulders[key]
	if mid == nil then
		local r = mesh:GetSocketTransform(fname("R_Upperarm"), 2).Translation -- 2 = RTS_Component
		local l = mesh:GetSocketTransform(fname("L_Upperarm"), 2).Translation
		mid = { X = (r.X + l.X) * 0.5, Y = (r.Y + l.Y) * 0.5, Z = (r.Z + l.Z) * 0.5 }
		seat.rigShoulders[key] = mid
	end
	return mid
end

local function seatPlacement(mesh)
	if seat == nil or not alive(seat.driverMesh) or not alive(seat.root) then return nil end
	local local_ = rigShoulderMid(mesh)
	local dr = seat.driverMesh:GetSocketLocation(fname("R_Upperarm"))
	local dl = seat.driverMesh:GetSocketLocation(fname("L_Upperarm"))
	local rot = uevrUtils.rotator(0, seat.root:K2_GetComponentRotation().Yaw, 0)
	local off = kismet_math_library:GreaterGreater_VectorRotator(uevrUtils.vector(local_.X, local_.Y, local_.Z), rot)
	return uevrUtils.vector((dr.X + dl.X) * 0.5 - off.X, (dr.Y + dl.Y) * 0.5 - off.Y, (dr.Z + dl.Z) * 0.5 - off.Z), rot
end

-- attach offset = inverse of the solver's (end_bone_offset, end_bone_rotation): hand bone = driver hand bone
local function inverseOffset(o)
	local t = kismet_math_library:MakeTransform(uevrUtils.vector(o.off[1], o.off[2], o.off[3]),
		uevrUtils.rotator(o.rot[1], o.rot[2], o.rot[3]), uevrUtils.vector(1, 1, 1))
	local inv = kismet_math_library:InvertTransform(t)
	local l, r = inv.Translation, kismet_math_library:Quat_Rotator(inv.Rotation)
	return { X = l.X, Y = l.Y, Z = l.Z }, { Pitch = r.Pitch, Yaw = r.Yaw, Roll = r.Roll }
end

local function pinHands()
	if seat == nil or _G.bl4IKHandOffsets == nil then return end
	local ok, offsets = pcall(_G.bl4IKHandOffsets)
	if not ok or offsets == nil then return end
	pcall(function()
		local rl, rr = inverseOffset(offsets.right)
		local ll, lr = inverseOffset(offsets.left)
		uevrUtils.executeUEVRCallbacks("on_accessory_attach", Handed.Right, seat.driverMesh, "R_Hand", 0, rl, rr)
		uevrUtils.executeUEVRCallbacks("on_accessory_attach", Handed.Left, seat.driverMesh, "L_Hand", 0, ll, lr)
	end)
end

-- finger bones present on both the rig and the driver, per hand, parents first
local function buildFingers(rig, driver)
	local list = { R = {}, L = {} }
	for side, bones in pairs(list) do
		for _, finger in ipairs(FINGERS) do
			for _, part in ipairs(FINGER_PARTS) do
				local name = side .. "_" .. finger .. part
				local ok, both = pcall(function()
					return rig:GetBoneIndex(fname(name)) ~= -1 and driver:GetBoneIndex(fname(name)) ~= -1
				end)
				if ok and both then table.insert(bones, fname(name)) end
			end
		end
	end
	return list
end

-- quaternions (x, y, z, w), Hamilton product as FQuat operator* (a * b = b first, then a)
local function qmul(ax, ay, az, aw, bx, by, bz, bw)
	return aw * bx + ax * bw + ay * bz - az * by,
		aw * by - ax * bz + ay * bw + az * bx,
		aw * bz + ax * by - ay * bx + az * bw,
		aw * bw - ax * bx - ay * by - az * bz
end

-- FQuat::Rotator
local function quatToRotator(x, y, z, w)
	local test = z * x - w * y
	local yawY = 2 * (w * z + x * y)
	local yawX = 1 - 2 * (y * y + z * z)
	local yaw = math.deg(math.atan(yawY, yawX))
	if test < -0.4999995 then
		return -90, yaw, math.deg(-math.rad(yaw) - 2 * math.atan(x, w)) % 360
	elseif test > 0.4999995 then
		return 90, yaw, math.deg(math.rad(yaw) - 2 * math.atan(x, w)) % 360
	end
	return math.deg(math.asin(2 * test)), yaw, math.deg(math.atan(-2 * (w * x + y * z), 1 - 2 * (x * x + y * y)))
end

-- each finger bone's world rotation = rig hand * (driver hand^-1 * driver bone): the driver's grip relative to the hand
local function copyFingers()
	if seat == nil then return end
	local rig = ik.getCurrentMesh(1)
	if not alive(rig) or not alive(seat.driverMesh) then return end
	if seat.fingerRig ~= rig then
		seat.fingers = buildFingers(rig, seat.driverMesh)
		seat.fingerRig = rig
	end
	for side, bones in pairs(seat.fingers) do
		local hand = fname(side .. "_Hand")
		local dh = seat.driverMesh:GetSocketQuaternion(hand)
		local rh = rig:GetSocketQuaternion(hand)
		-- M = rh * conj(dh)
		local mx, my, mz, mw = qmul(rh.X, rh.Y, rh.Z, rh.W, -dh.X, -dh.Y, -dh.Z, dh.W)
		for _, bone in ipairs(bones) do
			local db = seat.driverMesh:GetSocketQuaternion(bone)
			local x, y, z, w = qmul(mx, my, mz, mw, db.X, db.Y, db.Z, db.W)
			local p, yw, r = quatToRotator(x, y, z, w)
			rig:SetBoneRotationByName(bone, uevrUtils.rotator(p, yw, r), 0) -- 0 = world space
		end
	end
end

local function leaveSeat()
	if seat == nil then return end
	local s = seat
	seat = nil
	ik.setMeshPlacementOverride(nil)
	pcall(function()
		uevrUtils.executeUEVRCallbacks("on_accessory_detach", Handed.Right)
		uevrUtils.executeUEVRCallbacks("on_accessory_detach", Handed.Left)
	end)
	restoreArms(s.driverMesh)
	-- the finger poses go back to the weapon / input poses
	pcall(function()
		hands.updateAnimationState(Handed.Right)
		hands.updateAnimationState(Handed.Left)
	end)
	log("IK seat: left; driver's arms restored, IK hands back on the controllers")
end

local function enterSeat(vehicle, driverMesh)
	leaveSeat()
	local root = nil
	pcall(function() root = vehicle.RootComponent end)
	if not alive(root) then return end
	seat = { driverMesh = hideArms(driverMesh), root = root, rigShoulders = {} }
	ik.setMeshPlacementOverride(seatPlacement)
	pinHands()
	log("IK seat: driver's arms hidden, IK hands pinned to the driver's hands")
end

-- ---------------------------------------------------------------------------------------------
-- View
-- ---------------------------------------------------------------------------------------------
local localHead = nil    -- smoothed head position in the vehicle mesh frame {x, y, z}
local lastTime = nil
local frame = { tick = -1, x = nil, y = nil, z = nil, yaw = nil }
local tick = 0
local inVehicle = false

local function resetView()
	restoreHead()
	localHead = nil
	lastTime = nil
	frame.tick = -1
end

-- Driver head in world space for this frame (computed once per tick, used by both eyes)
local function computeFrame()
	frame.tick = tick
	frame.x = nil
	local vehicle = getVehicle()
	if vehicle == nil then return end
	pcall(function()
		local root = vehicle.RootComponent
		if root == nil then return end
		local t = root:K2_GetComponentToWorld()
		local mesh = driverMeshOf(vehicle)
		if mesh ~= nil then
			hideHead(mesh)
			local head = mesh:GetSocketLocation(fname("Head"))
			local l = kismet_math_library:InverseTransformLocation(t, head)
			local now = os.clock()
			if localHead == nil or lastTime == nil then
				localHead = { x = l.X, y = l.Y, z = l.Z }
			else
				local a = math.min(1, math.max(0, (now - lastTime) / SMOOTH_TIME))
				localHead.x = localHead.x + (l.X - localHead.x) * a
				localHead.y = localHead.y + (l.Y - localHead.y) * a
				localHead.z = localHead.z + (l.Z - localHead.z) * a
			end
			lastTime = now
		end
		if localHead == nil then return end
		local ox, oy, oz = vec3("bl4_vehicle_eye_offset")
		-- the vehicle mesh frame: X forward, Y right, Z up
		local w = kismet_math_library:TransformLocation(t, uevrUtils.vector(localHead.x + ox, localHead.y + oy, localHead.z + oz))
		frame.x, frame.y, frame.z = w.X, w.Y, w.Z
		if configui.getValue("bl4_vehicle_view_yaw") == 2 then
			frame.yaw = root:K2_GetComponentRotation().Yaw
		else
			local pc = uevr.api:get_player_controller(0)
			local control = pc ~= nil and pc:GetControlRotation() or nil
			frame.yaw = control ~= nil and control.Yaw or root:K2_GetComponentRotation().Yaw
		end
	end)
end

uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
	tick = tick + 1
	local vehicle = getVehicle()
	local now = vehicle ~= nil
	if now ~= inVehicle then
		inVehicle = now
		if now then log("driving: view in the driver's seat") else resetView() log("left the vehicle: view back to normal") end
	end
	if vehicle ~= nil and not firstPersonEnabled() and (headHiddenMesh ~= nil or localHead ~= nil) then resetView() end

	-- IK seat
	local driverMesh = vehicle ~= nil and driverMeshOf(vehicle) or nil
	local want = driverMesh ~= nil and ikSeatWanted() and alive(ik.getCurrentMesh(1))
	if not want then
		if seat ~= nil then leaveSeat() end
	elseif seat == nil or seat.driverMesh ~= driverMesh then
		enterSeat(vehicle, driverMesh)
	else
		pinHands() -- re-assert: cheap, and survives any accessory detach and solver offset change
	end
end)

uevr.sdk.callbacks.on_early_calculate_stereo_view_offset(function(device, view_index, world_to_meters, position, rotation, is_double)
	if rotation == nil or position == nil or not firstPersonEnabled() then return end
	if frame.tick ~= tick then computeFrame() end
	if frame.x == nil then return end
	position.x = frame.x
	position.y = frame.y
	position.z = frame.z
	rotation.Pitch = 0
	rotation.Yaw = frame.yaw
	rotation.Roll = 0
end)

-- fingers after the IK solve (post engine tick) and the hand poses, once per frame
local fingerTick = -1
uevrUtils.registerPostCalculateStereoViewCallback(function(device, view_index, world_to_meters, position, rotation, is_double)
	if seat == nil or fingerTick == tick then return end
	fingerTick = tick
	local ok, err = pcall(copyFingers)
	if not ok then log("fingers: " .. tostring(err)) end
end)

uevr.sdk.callbacks.on_script_reset(function()
	leaveSeat()
	resetView()
end)

log("loaded")
