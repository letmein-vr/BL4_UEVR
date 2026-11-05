-- PiP (picture-in-picture) scopes for Borderlands 4 (2026-11-05), built with libs/scope.lua (OW2 version).
--
-- Which guns get one: the gun's own parts. BL4 builds each gun from parts; the sight part adds a WeaponBehavior_Sight to
-- OakWeapon.behaviors (lowercase: BL4's reflection spelling) with the game's zoom (ZoomFOVScale), and a scope part maps
-- the gun's generic "ScopeSocket" to its own socket (GestaltData.SocketMappings; iron sights map "EyeSocket"). A gun
-- gets a PiP when a ScopeSocket part is fitted and the sight magnifies at least "Only scopes of at least" (2x). Every
-- weapon variant decides for itself; nothing is set per weapon. Some scopes have a mask mesh
-- (WeaponBehavior_Sight.MaskMeshComponent, e.g. JAK_SG_Scope_02_L1_Mask), many don't (BOR_SR_Scope_01_L2, 3.5x).
--
-- Where the eyepiece is: the game attaches the mask to the first-person gun's "Root" socket with no offset, so the
-- mask mesh is modelled in gun space around the eyepiece. MCP 2026-11-05, Jakobs shotgun 2.5x scope:
-- JAK_SG_Scope_02_L1_Mask = a flat disc at X 3.78, Z 10.6 (bounds 2.26 x 3.02 cm), on the scope's optical axis (the
-- ADS eye point ScopeSocket sits on the same axis at X -27.5, Z 10.55). The ocular lens goes on the Root socket at the
-- mask's bounds centre with the mask's width as its diameter. Scopes without a mask use the rear end of the fitted scope
-- parts' bounds (rig GestaltData.GestaltPartBounds) on the ScopeSocket eye axis. Every scope places and sizes itself.
--
-- The objective lens (the scene capture) sits on the gun's Muzzle socket (gestalt-resolved to the fitted barrel; X =
-- bore, the same muzzle BL4AimFix.dll fires from), so the centre of the picture is where the shots go. The capture
-- ignores the gun and everything attached to it, so the scope body can't block the view.
--
-- Zoom = the game's own: WeaponBehavior_Sight.ZoomFOVScale (0.4 = 2.5x, 0.18 = 5.5x; the flat zoomed FOV is
-- 2*atan(tan(FOV/2) * ZoomFOVScale), measured 20.6 deg for 0.18182 at 90). For the same magnification in VR, the
-- picture must show the world ZoomFOVScale times narrower than the lens appears to the eye, so every frame the capture
-- FOV is set to 2*atan(lens radius / eye distance * ZoomFOVScale). Moving the eye closer or further keeps the
-- magnification. scope.lua's stick zoom is off (the scope's zoom is fixed by the part).
--
-- The flat scope overlay (mask mesh + vignette) is hidden by bl4_vr_scope.lua, and BL4AimFix.dll keeps the gun drawn
-- while scoped (WeaponBehaviorDef_Sight.bHideWeapon cleared).

local uevrUtils = require('libs/uevr_utils')
local configui = require('libs/configui')
local controllers = require('libs/controllers')
local scope = require('libs/scope')
local plugin = require('libs/core/plugin')

local partBoundsCache = {} -- rig (GestaltSkeletalMesh) address -> GestaltData.GestaltPartBounds (static asset data)

local LENS_MESH_DIAMETER = 5.0  -- cm: scope.lua's ocular lens = engine Cylinder (100 cm) scaled by 0.05 * scale
local MIN_EYE_DISTANCE = 3.0    -- cm: clamp for the FOV formula
local POLL_S = 0.25

-- BL4 gun meshes point the barrel along +X: rotation X = 90 cancels scope.lua's -90 pitch (objective) and turns the
-- lens disc's face toward the eye (ocular), as on OW2.
scope.setParameterDefault("objective_lens_rotation", {90.0, 0.0, 0.0})
scope.setParameterDefault("objective_lens_location", {0.0, 0.0, 0.0})
scope.setParameterDefault("lens_offset", 0.0) -- per-scope eyepiece offset toward the eye (cm), set in the panel
scope.setParameterDefault("ocular_lens_rotation", {90.0, 0.0, 0.0})
-- Shown only while aiming down sights (OakCharacter.ZoomState.bWantsToZoom = LT held; MCP 2026-11-05: true with State 2
-- while scoped), switched by this script through Scope:disable. scope.lua's own eye-distance switch is kept out of the
-- way with a distance it never reaches.
scope.setParameterDefault("deactivate_distance", 100000.0)
scope.setAutoHandleInput(false)

_G.BL4_SECTIONS = _G.BL4_SECTIONS or {}
table.insert(_G.BL4_SECTIONS, { order = 4, label = "PiP Scope", layout = {
	{ widgetType = "checkbox", id = "bl4_pip_enabled", label = "PiP scopes on guns with a magnifying scope", initialValue = true },
	{ widgetType = "text", id = "bl4_pip_status", label = "Scope: -" },
	{ widgetType = "slider_float", id = "bl4_pip_min_magnification", label = "Only scopes of at least (x magnification)", initialValue = 2.0, range = { 1.0, 6.0 } },
	{ widgetType = "slider_float", id = "bl4_pip_lens_offset", label = "Lens offset toward the eye (cm) - this scope only", initialValue = 0.0, range = { -10.0, 15.0 } },
	{ widgetType = "slider_float", id = "bl4_pip_lens_size", label = "Lens size (x the eyepiece)", initialValue = 1.0, range = { 0.5, 2.0 } },
	{ widgetType = "slider_float", id = "bl4_pip_magnification", label = "Magnification (x the game's)", initialValue = 1.0, range = { 0.5, 2.0 } },
	{ widgetType = "slider_float", id = "bl4_pip_brightness", label = "Brightness", initialValue = 2.0, range = { 0.1, 8.0 } },
}})

local function value(id, default)
	local v = configui.getValue(id)
	if v == nil then return default end
	return v
end

local function log(text)
	pcall(function() uevrUtils.print("[bl4 pip] " .. tostring(text), LogLevel.Info) end)
end

-- errors go to log.txt, each distinct message once
local loggedErrors = {}
local function logError(text)
	if loggedErrors[text] then return end
	loggedErrors[text] = true
	pcall(function() uevr.params.functions.log_error("[bl4 pip] " .. text) end)
end

local function setStatus(text)
	pcall(function() configui.setLabel("bl4_pip_status", text) end)
end

local function addressOf(object)
	if object == nil then return nil end
	local ok, address = pcall(function() return object:get_address() end)
	return ok and address or nil
end

local function isAlive(object)
	return object ~= nil and pcall(function() return object:get_full_name() end)
end

-- current = what the PiP was built for (objects compared by address)
local current = { weapon = nil, mesh = nil, sight = nil, maskMesh = nil, instance = nil, sightObj = nil,
	eyepiece = nil, diameter = nil, status = "" }

local sightClass, primitiveClass = nil, nil
local rootSocket, muzzleSocket = nil, nil

local function zoomScale(sight)
	local z = nil
	pcall(function() z = sight.ZoomFOVScale.Value end)
	if z == nil or z <= 0 or z > 1 then return 1.0 end
	return z
end

-- the held gun's sight (WeaponBehavior_Sight), preferring the current use mode's (behaviors are named UM<mode>_<n>),
-- plus its scope mask mesh when it has one (many scopes have none, e.g. BOR_SR_Scope_01_L2, MCP 2026-11-05)
local function findSight(weapon)
	if sightClass == nil then sightClass = uevrUtils.get_class("Class /Script/OakGame.WeaponBehavior_Sight") end
	if sightClass == nil then return nil end
	local mode = nil
	pcall(function() mode = weapon.CurrentUseModeIndex end)
	local preferred = mode ~= nil and ("UM" .. tostring(mode) .. "_") or nil
	local found = nil
	local behaviors = weapon.behaviors
	for i = 1, #(behaviors or {}) do
		local b = behaviors[i]
		if b ~= nil and b:is_a(sightClass) then
			if preferred ~= nil and string.sub(b:get_fname():to_string(), 1, #preferred) == preferred then found = b break end
			if found == nil then found = b end
		end
	end
	if found == nil then return nil end
	local maskMesh = nil
	pcall(function()
		local mask = uevrUtils.getValid(found.MaskMeshComponent)
		maskMesh = mask ~= nil and uevrUtils.getValid(mask.StaticMesh) or nil
	end)
	return found, maskMesh
end

local function nameString(name)
	if name == nil then return nil end
	if type(name) == "string" then return name end
	local ok, s = pcall(function() return name:to_string() end)
	return ok and s or tostring(name)
end

-- Fitted scope part from the gun's gestalt data: GbxSkeletalMeshComponent.GestaltData.SocketMappings maps the generic
-- "ScopeSocket" (the ADS eye point) to the fitted part's socket, e.g. "BOR_SR_Scope_01_L2_ScopeSocket"; iron sights map
-- "EyeSocket" instead. Returns the part name ("BOR_SR_Scope_01_L2") or nil.
-- UEVR Lua returns nil for arrays of structs / names (only object and class arrays are converted), so the gestalt
-- arrays are read through libs/core/plugin.lua (uevr_utils.dll), which converts them to Lua tables.
local function fittedScopePart(mesh)
	local part = nil
	pcall(function()
		local mappings = plugin.getProperty(mesh, "GestaltData.SocketMappings")
		for i = 1, #(mappings or {}) do
			local m = mappings[i]
			if nameString(m.MappedName) == "ScopeSocket" then
				local unique = nameString(m.UniqueSocketName) or ""
				part = string.match(unique, "^(.*)_ScopeSocket$")
				return
			end
		end
	end)
	return part
end

-- Scope extent in gun space: the union of the reference-pose bounds (rig GestaltData.GestaltPartBounds) of the fitted
-- parts that belong to the scope - the scope part and its base/variants, e.g. BOR_SR_Scope_01 + _01_A + _01_L2 for
-- part BOR_SR_Scope_01_L2 (fitted parts = component GestaltData.PartNames).
local function scopeBounds(mesh, part)
	local base = string.gsub(part, "_L%d+$", "")
	local fitted = {}
	pcall(function()
		local names = plugin.getProperty(mesh, "GestaltData.PartNames")
		for i = 1, #(names or {}) do fitted[nameString(names[i])] = true end
	end)
	local minX, minY, minZ, maxX, maxY, maxZ = math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge
	local used = {}
	pcall(function()
		local rig = mesh.SkeletalMesh
		local key = addressOf(rig)
		if partBoundsCache[key] == nil then partBoundsCache[key] = plugin.getProperty(rig, "GestaltData.GestaltPartBounds") or {} end
		local bounds = partBoundsCache[key]
		for i = 1, #(bounds or {}) do
			local entry = bounds[i]
			local name = nameString(entry.PartName)
			if name ~= nil and fitted[name] and (name == part or string.sub(name, 1, #base) == base) then
				local b = entry.ReferencePoseBounds
				local o, e = b.Origin, b.BoxExtent
				local ox, oy, oz = o.X or o.x, o.Y or o.y, o.Z or o.z
				local ex, ey, ez = e.X or e.x, e.Y or e.y, e.Z or e.z
				minX, maxX = math.min(minX, ox - ex), math.max(maxX, ox + ex)
				minY, maxY = math.min(minY, oy - ey), math.max(maxY, oy + ey)
				minZ, maxZ = math.min(minZ, oz - ez), math.max(maxZ, oz + ez)
				table.insert(used, name)
			end
		end
	end)
	if #used == 0 then return nil end
	return { minX = minX, maxX = maxX, minY = minY, maxY = maxY, minZ = minZ, maxZ = maxZ, parts = table.concat(used, "+") }
end

-- Eyepiece centre (gun space) and diameter.
--   * Scope with a mask mesh: the mask's bounds (the game attaches it to the Root socket with no offset; confirmed).
--   * No mask: the rear end of the scope parts' bounds, on the ADS eye axis (ScopeSocket Y/Z), with a diameter of
--     MASKLESS_DIAMETER_SCALE x the tube's smaller cross-section.
local MASKLESS_DIAMETER_SCALE = 0.6
local scopeSocketName = nil
local function eyepiece(mesh, maskMesh, part)
	local bounds = part ~= nil and scopeBounds(mesh, part) or nil
	if maskMesh ~= nil then
		local b = maskMesh:GetBounds()
		local o, e = b.Origin, b.BoxExtent
		local detail = bounds ~= nil and string.format(" (scope parts %s: X %.1f..%.1f)", bounds.parts, bounds.minX, bounds.maxX) or ""
		return { X = o.X, Y = o.Y, Z = o.Z }, 2.0 * math.min(e.Y, e.Z), "mask" .. detail
	end
	if bounds == nil then return nil end
	if scopeSocketName == nil then scopeSocketName = uevrUtils.fname_from_string("ScopeSocket") end
	local eye = mesh:GetSocketTransform(scopeSocketName, 2).Translation -- RTS_Component
	local diameter = MASKLESS_DIAMETER_SCALE * math.min(bounds.maxY - bounds.minY, bounds.maxZ - bounds.minZ)
	return { X = bounds.minX, Y = eye.Y, Z = eye.Z }, diameter,
		string.format("scope parts %s: X %.1f..%.1f, Y %.1f..%.1f, Z %.1f..%.1f; eye axis Y %.1f Z %.1f",
			bounds.parts, bounds.minX, bounds.maxX, bounds.minY, bounds.maxY, bounds.minZ, bounds.maxZ, eye.Y, eye.Z)
end

local function hideWeaponFromCapture(instance, mesh)
	local capture = instance:getObjectiveLensComponent()
	if capture == nil then return end
	if primitiveClass == nil then primitiveClass = uevrUtils.get_class("Class /Script/Engine.PrimitiveComponent") end
	local ocularAddress = addressOf(instance:getOcularLensComponent())
	capture:HideComponent(mesh)
	local function hideChildren(parent, depth)
		local children = parent.AttachChildren
		if children == nil or depth > 3 then return end
		for i = 1, #children do
			local child = children[i]
			if child ~= nil and addressOf(child) ~= ocularAddress then
				if primitiveClass ~= nil and child:is_a(primitiveClass) then capture:HideComponent(child) end
				hideChildren(child, depth + 1)
			end
		end
	end
	hideChildren(mesh, 1)
end

-- ocular lens on the Root socket at the eyepiece, objective on the Muzzle socket
local function placeLenses(instance, mesh)
	if rootSocket == nil then rootSocket = uevrUtils.fname_from_string("Root") end
	if muzzleSocket == nil then muzzleSocket = uevrUtils.fname_from_string("Muzzle") end
	local ocular = instance:getOcularLensComponent()
	if ocular ~= nil then
		if mesh:DoesSocketExist(rootSocket) == true then ocular:K2_AttachToComponent(mesh, rootSocket, 0, 0, 0, false) end
		local p = current.eyepiece
		instance:setOcularLensRelativeLocation({ p.X - (scope.getParameter(current.scopeID, "lens_offset") or 0.0), p.Y, p.Z })
		instance:setOcularLensRelativeRotation({ 90.0, 0.0, 0.0 })
		instance:setOcularLensScale(current.diameter * value("bl4_pip_lens_size", 1.0) / LENS_MESH_DIAMETER)
		-- depth: the lens is attached under the gun, so bl4_main.lua's "View model depth" puts it in the gun's layer
		-- (world depth by default; the gun's foreground layer never depth-tested against a normal-scene lens)
	end
	local objective = instance:getObjectiveLensComponent()
	local atMuzzle = false
	if objective ~= nil and mesh:DoesSocketExist(muzzleSocket) == true then
		objective:K2_AttachToComponent(mesh, muzzleSocket, 0, 0, 0, false)
		instance:setObjectiveLensRelativeLocation({ 0.0, 0.0, 0.0 })
		-- Some barrels model the Muzzle socket rolled about the bore (Vladof SK_VLA_SR: 90 deg, quat X 0.707 W 0.707;
		-- MCP 2026-11-05), which rolled the PiP picture 90 deg (gun up -> picture moved right). Roll is the innermost
		-- rotation (socket X axis), so a relative roll of minus the socket's roll levels the camera with the gun's up
		-- axis without changing where it looks. scope.lua's setter subtracts 90 from the pitch value.
		local socketRoll = 0.0
		pcall(function()
			local t = mesh:GetSocketTransform(muzzleSocket, 2) -- RTS_Component
			socketRoll = kismet_math_library:Quat_Rotator(t.Rotation).Roll or 0.0
		end)
		instance:setObjectiveLensRelativeRotation({ 90.0, 0.0, -socketRoll })
		atMuzzle = true
	end
	return atMuzzle
end

local function destroyScope()
	if current.instance ~= nil then
		pcall(function() current.instance:destroy() end)
		current.instance = nil
	end
	current.sightObj = nil
	current.scopeID = nil
end

local function reset()
	destroyScope()
	current.weapon, current.mesh, current.sight, current.maskMesh = nil, nil, nil, nil
end

local function lensDistance(instance)
	local head = controllers.getControllerLocation(2)
	local lens = instance:getOcularLensComponent()
	if head == nil or lens == nil then return nil end
	local l = lens:K2_GetComponentLocation()
	local dx, dy, dz = l.X - head.X, l.Y - head.Y, l.Z - head.Z
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- LT held = the game is zooming / zoomed (OakCharacter.ZoomState.bWantsToZoom)
local function isAimingDownSights()
	local pawn = _G.bl4 ~= nil and _G.bl4.getPlayerCharacter() or nil
	if pawn == nil then return false end
	local ok, wants = pcall(function() return pawn.ZoomState.bWantsToZoom end)
	return ok and wants == true
end

local function update()
	local pawn = _G.bl4 ~= nil and _G.bl4.getPlayerCharacter() or nil
	local weapon = pawn ~= nil and _G.bl4.getHeldWeapon(pawn) or nil
	local mesh = weapon ~= nil and _G.bl4.getFirstPersonWeaponMesh(weapon) or nil
	local sight, maskMesh = nil, nil
	if weapon ~= nil and value("bl4_pip_enabled", true) ~= false then sight, maskMesh = findSight(weapon) end

	-- rebuild when the gun, its mesh, its sight or the scope part changes, or the PiP's components died. The mask mesh
	-- counts too: on some scopes the game creates it later.
	local wA, mA, sA, kA = addressOf(weapon), addressOf(mesh), addressOf(sight), addressOf(maskMesh)
	local changed = wA ~= current.weapon or mA ~= current.mesh or sA ~= current.sight or kA ~= current.maskMesh
	if not changed and current.instance ~= nil and not isAlive(current.instance:getOcularLensComponent()) then changed = true end
	if not changed then
		if current.instance ~= nil then
			hideWeaponFromCapture(current.instance, mesh)
			local d = lensDistance(current.instance)
			setStatus(current.status .. string.format(" | eye %s cm - %s",
				d ~= nil and string.format("%.0f", d) or "?", current.instance:isDisplaying() and "showing (ADS)" or "hidden"))
		end
		return
	end

	destroyScope()
	current.weapon, current.mesh, current.sight, current.maskMesh = wA, mA, sA, kA
	if sight == nil or not isAlive(mesh) then
		setStatus(weapon == nil and "Scope: no gun" or "Scope: none on this gun")
		return
	end
	-- a scope = a fitted ScopeSocket part (iron sights use EyeSocket) and at least the minimum magnification
	local magnification = 1.0 / zoomScale(sight)
	local part = fittedScopePart(mesh)
	if part == nil or magnification < value("bl4_pip_min_magnification", 2.0) - 0.01 then
		local text = string.format("Scope: none on this gun (%s, %.1fx)", part or "no ScopeSocket part", magnification)
		setStatus(text)
		log(text)
		return
	end
	local scopeID = maskMesh ~= nil and maskMesh:get_fname():to_string() or part
	local status = "Scope: " .. scopeID .. string.format(" (%.1fx)", magnification)
	local ok, err = pcall(function()
		local source
		current.eyepiece, current.diameter, source = eyepiece(mesh, maskMesh, part)
		if current.eyepiece == nil then error("no eyepiece data for " .. part) end
		log(scopeID .. ": eyepiece from " .. source)
		current.scopeID = scopeID
		current.instance = scope.new(scopeID)
		current.instance:attachTo(mesh)
		local atMuzzle = placeLenses(current.instance, mesh)
		current.instance:setBrightness(value("bl4_pip_brightness", 2.0))
		hideWeaponFromCapture(current.instance, mesh)
		current.sightObj = sight
		status = status .. string.format(" - eyepiece X %.1f Z %.1f, %.1f cm", current.eyepiece.X, current.eyepiece.Z, current.diameter)
			.. (atMuzzle and ", camera at the muzzle" or ", camera on the gun (no Muzzle socket)")
	end)
	if not ok then
		destroyScope()
		setStatus(status .. " - PiP failed: " .. tostring(err))
		logError("PiP for " .. scopeID .. ": " .. tostring(err))
		return
	end
	-- the offset slider shows (and edits) this scope's own value
	pcall(function() configui.setValue("bl4_pip_lens_offset", scope.getParameter(scopeID, "lens_offset") or 0.0, true) end)
	current.status = status
	setStatus(status)
	log(status)
end

local nextPoll = 0
uevrUtils.registerPreEngineTickCallback(function(engine, delta)
	local now = os.clock()
	if now >= nextPoll then
		nextPoll = now + POLL_S
		local ok, err = pcall(update)
		if not ok then
			setStatus("Error: " .. tostring(err))
			logError(tostring(err))
		end
	end
	local instance = current.instance
	if instance == nil or current.sightObj == nil then return end
	-- shown only while aiming down sights
	local ads = isAimingDownSights()
	-- The game re-shows the gun with its attached children (SetVisibility propagation) when a newly picked-up / equipped
	-- gun becomes visible, which re-showed the lens and the scene capture while the PiP was meant to be hidden (shown
	-- until the first ADS, 2026-11-05; OW2 had the same). So the real visibility is checked every frame, not only the
	-- PiP's own state.
	local shownAnyway = false
	if not ads then
		pcall(function()
			local lens, capture = instance:getOcularLensComponent(), instance:getObjectiveLensComponent()
			shownAnyway = (lens ~= nil and lens.bVisible == true) or (capture ~= nil and capture.bVisible == true)
		end)
	end
	if ads ~= instance:isDisplaying() or shownAnyway then pcall(function() instance:disable(not ads) end) end
	if not ads then return end
	-- Many scopes only get their mask mesh on the first zoom after pickup, and until then the lens sits at the
	-- scope-parts fallback position. While aiming without a mask, look for it every frame and re-place at once.
	if current.maskMesh == nil then
		local appeared = false
		pcall(function()
			local mask = uevrUtils.getValid(current.sightObj.MaskMeshComponent)
			appeared = mask ~= nil and uevrUtils.getValid(mask.StaticMesh) ~= nil
		end)
		if appeared then nextPoll = 0 end
	end
	-- the game's magnification, every frame while the PiP shows
	pcall(function()
		local d = lensDistance(instance)
		if d == nil then return end
		local radius = 0.5 * current.diameter * value("bl4_pip_lens_size", 1.0)
		local t = (radius / math.max(d, MIN_EYE_DISTANCE)) * zoomScale(current.sightObj) / value("bl4_pip_magnification", 1.0)
		instance:setFOV(math.max(0.2, 2.0 * math.deg(math.atan(t))))
	end)
end)

-- panel changes: rebuild on the next poll (placement / size), or apply directly
local function rebuild() current.weapon = nil end
configui.onUpdate("bl4_pip_enabled", rebuild)
configui.onUpdate("bl4_pip_min_magnification", rebuild)
-- lens offset: saved for the scope currently held only (scope_parameters.json, key lens_offset), lens moved directly
configui.onUpdate("bl4_pip_lens_offset", function(v)
	local id = current.instance ~= nil and current.scopeID or nil
	if id == nil then return end
	scope.setParameter(id, "lens_offset", v)
	uevrUtils.setTimeout(1, function()
		local instance, p = current.instance, current.eyepiece
		if instance == nil or p == nil or current.scopeID ~= id then return end
		pcall(function() instance:setOcularLensRelativeLocation({ p.X - v, p.Y, p.Z }) end)
	end)
end)
configui.onUpdate("bl4_pip_lens_size", rebuild)
-- configui callbacks run on the draw thread; UFunction calls go on the game thread
configui.onUpdate("bl4_pip_brightness", function(v)
	uevrUtils.setTimeout(1, function()
		if current.instance ~= nil then pcall(function() current.instance:setBrightness(v) end) end
	end)
end)

uevrUtils.registerPreLevelChangeCallback(function(level) reset() end)
uevr.sdk.callbacks.on_script_reset(function() destroyScope() end)
