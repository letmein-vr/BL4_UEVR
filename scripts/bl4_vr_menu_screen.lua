-- Menus on a flat screen, whole in both eyes (2026-11-05).
--
-- BL4's ECHO menu (map, inventory, skills, customization ...) is drawn ONCE across the whole double-wide stereo render
-- instead of once per eye, so the left eye saw the left half of the menu and the right eye the right half - the map was
-- unusable, and plain 2D Screen Mode (one eye's half per eye) did not help. Fix from Lorewright-Studios/UEVR
-- (bl4-menu-fullsource e7eedb5 + 856b490), ported into our backend (merge-ue57-2026-10-23): VR_2DScreenFullSource
-- shows the entire render in each eye's 2D screen and halves the per-eye render width so the menu keeps the window's
-- proportions. This script turns VR_2DScreenMode + VR_2DScreenFullSource on while the controller shows the mouse
-- cursor (true in the ECHO menus, MCP 2026-11-05 with the map open) and back off when it closes. Gameplay stays 3D.
-- Needs the backend with VR_2DScreenFullSource (UEVR Build 2026-11-05, sha1 d29e7b6d); older backends ignore it.
-- Always on: the panel option (bl4_menu_flat_screen) was removed 2026-11-09 (xaero: should be on at all times).

local uevrUtils = require('libs/uevr_utils')

local function log(text)
	pcall(function() uevrUtils.print("[bl4 menu screen] " .. tostring(text), LogLevel.Info) end)
end

local function getMod(name)
	local ok, value = pcall(function() return uevr.params.vr:get_mod_value(name) end)
	return ok and value ~= nil and string.sub(tostring(value), 1, 4) == "true"
end

local function setMods(on)
	local v = on and "true" or "false"
	pcall(function()
		uevr.params.vr.set_mod_value("VR_2DScreenFullSource", v)
		uevr.params.vr.set_mod_value("VR_2DScreenMode", v)
	end)
end

-- UEVR saves the live values at exit: quitting with a menu open would start the next session in the flat screen
if getMod("VR_2DScreenFullSource") then
	setMods(false)
	log("cleared a flat menu screen left on from the last session")
end

local active = false
-- in game only: the main menu (no player character) also shows the cursor but draws fine in 3D (xaero 2026-11-05).
-- ECHO menus only: the pause menu also shows the cursor and pauses the game, but it sits over the live world and
-- draws fine in 3D (xaero 2026-11-07). The ECHO menu stops the world view: PC.bPlayerViewRenderingSuspended is true
-- with the map open and false in the pause menu (MCP 2026-11-07); pause state and Prysm views are the same for both.
local function menuOpen()
	local open = false
	pcall(function()
		if _G.bl4 == nil or _G.bl4.getPlayerCharacter() == nil then return end
		local pc = uevr.api:get_player_controller(0)
		open = pc ~= nil and pc.bShowMouseCursor == true and pc.bPlayerViewRenderingSuspended == true
	end)
	return open
end

uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
	local want = menuOpen()
	if want == active then return end
	active = want
	setMods(want)
	log(want and "menu open: flat screen, whole render in both eyes" or "menu closed: back to 3D")
end)

uevr.sdk.callbacks.on_script_reset(function()
	if active then setMods(false) active = false end
end)
