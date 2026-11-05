-- Scoped ADS for Borderlands 4: hide the flat-screen scope overlay (2026-11-05).
--
-- Scoped guns (snipers, high-magnification sights) carry WeaponBehavior_Sight entries in OakWeapon.behaviors (lowercase:
-- BL4's reflection spelling). On zoom-in each sight shows two flat-only overlays (MCP 2026-11-05, Maliwan sniper, 5.5x):
--   * MaskMeshComponent - a StaticMeshComponent (e.g. MAL_SR_Scope_02_L1_Mask), a large black plane with a hole, attached
--     to the first-person gun at the eyepiece. Created once per sight and reused for every zoom.
--   * VignetteComponent - a NiagaraComponent (e.g. NS_MAL_SR_Scope_01_L2_Vignette, sprite sized by
--     GbxNiagaraDataInterfaceViewportScale), spawned on zoom-in and destroyed on zoom-out.
-- In flat the camera sits at the eyepiece, so these just frame the scope picture. In VR the eyes are not there: the
-- player sees a black square with a peephole floating in front of the face, covering the gun ("the weapon disappears").
-- Both are hidden with bHiddenInGame (the game toggles their visibility itself, not hidden-in-game), re-checked every
-- frame because the vignette is a new component on every zoom. Iron sights / red dots have no mask or vignette.

local uevrUtils = require('libs/uevr_utils')
local configui = require('libs/configui')

local function log(text)
	pcall(function() uevrUtils.print("[bl4 scope] " .. tostring(text), LogLevel.Info) end)
end

-- option goes into bl4_main.lua's "General" section (bl4_main loads first; a second "General" entry would make a
-- second header)
local OPTION = { widgetType = "checkbox", id = "bl4_hide_scope_overlay", label = "Hide the flat scope overlay (black mask) when aiming down sights", initialValue = true }
_G.BL4_SECTIONS = _G.BL4_SECTIONS or {}
local general = nil
for _, section in ipairs(_G.BL4_SECTIONS) do
	if section.label == "General" then general = section end
end
if general ~= nil then
	table.insert(general.layout, OPTION)
else
	table.insert(_G.BL4_SECTIONS, { order = 0, label = "General", layout = { OPTION } })
end

local sightClass = nil
local sightCache = { weapon = nil, sights = {} }
-- address -> component we hid (restored when the option is turned off). Only the reused mask meshes stay listed;
-- vignettes are destroyed on zoom-out and dropped as soon as they are no longer valid.
local hiddenByUs = {}

local function getSights(weapon)
	if sightCache.weapon == weapon then return sightCache.sights end
	sightCache.weapon, sightCache.sights = weapon, {}
	if sightClass == nil then sightClass = uevrUtils.get_class("Class /Script/OakGame.WeaponBehavior_Sight") end
	if sightClass == nil then return sightCache.sights end
	pcall(function()
		local behaviors = weapon.behaviors
		for i = 1, #(behaviors or {}) do
			local b = behaviors[i]
			if b ~= nil and b:is_a(sightClass) then table.insert(sightCache.sights, b) end
		end
	end)
	if #sightCache.sights > 0 then log(weapon:get_full_name() .. ": " .. #sightCache.sights .. " sight(s)") end
	return sightCache.sights
end

local function prune()
	for address, component in pairs(hiddenByUs) do
		if uevrUtils.getValid(component) == nil then hiddenByUs[address] = nil end
	end
end

local function hide(component)
	if component == nil then return end
	pcall(function()
		if component.bHiddenInGame == true then return end
		component:SetHiddenInGame(true, false)
		prune()
		hiddenByUs[component:get_address()] = component
	end)
end

local function restoreAll()
	for _, component in pairs(hiddenByUs) do
		if uevrUtils.getValid(component) ~= nil then pcall(function() component:SetHiddenInGame(false, false) end) end
	end
	hiddenByUs = {}
end

uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
	if configui.getValue("bl4_hide_scope_overlay") == false then
		if next(hiddenByUs) ~= nil then restoreAll() end
		return
	end
	if _G.bl4 == nil then return end
	local pawn = _G.bl4.getPlayerCharacter()
	local weapon = pawn ~= nil and _G.bl4.getHeldWeapon(pawn) or nil
	if weapon == nil then return end
	for _, sight in ipairs(getSights(weapon)) do
		pcall(function()
			hide(uevrUtils.getValid(sight.MaskMeshComponent))
			hide(uevrUtils.getValid(sight.VignetteComponent))
		end)
	end
end)
