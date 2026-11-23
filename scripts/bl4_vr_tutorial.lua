-- VR tutorial (2026-11-16): image pages explaining the VR controls, the Outer Worlds 2 profile's vr_tutorial.lua
-- (Cronos 1.7 rules, itself a port of Hellraiser's) ported to Borderlands 4. libs/tutorial.lua = the OW2 / Cronos copy
-- (jbusfield's Atomic Heart lib + gate option, gestureCloses, setCompleted, pageOffset, slot-0 guard).
-- Pages: data/tutorial/intro.png + 1.png .. N.png (counted at runtime), icons data/tutorial/buttons/. They are rendered
-- from the repo art (screenshots/borderlands4vr.png) by D:\UEVR Dev\Tutorials\Borderlands 4\make_pages.ps1.
--
--   * Startup: shown once real gameplay is reached (never in the main menu, see inGameplay), unless the panel option
--     "Show it when gameplay starts" (bl4_tut_startup) is off, at every start until the player closes it once (B or the
--     gesture). After that only the gesture opens it. Also stops when the player finishes it ("Done" on the last page)
--     or turns on "Hide at startup" (Y). data/tutorial_state.json remembers that, the gesture and the last page; it is
--     never shipped, so a fresh install shows the tutorial again.
--   * Any time: left controller up to the eyes + left TRIGGER opens it again at the saved page (libs/gestures
--     EYESCRATCH: within 15 cm in front of the HMD, trigger > 128). The trigger has to be PULLED there: a trigger that
--     is already held when the hand passes the eyes (aiming down sights) never opens it. Read from the physical pad at
--     priority 100002, so before holsters (25), the hand poses (10), two-handing (5) and every other script; the X/B swap
--     (bl4_vr_buttonswitch.lua) is a raw UEVR callback registered after the uevr_utils dispatcher (bl4_main.lua loads
--     it first), so it runs after it.
--     Not on foot = refused (vehicles, main menu: _G.bl4.getPlayerCharacter() is nil), nor during cutscenes / disabled
--     input (libs/ui.lua), while two-handing, with the mouse cursor shown (ECHO menus, pause menu) or while paused. A
--     refused pull reaches the game as usual (aim down sights).
--   * While open: every button is kept from the game and the other scripts (A next / start / done, X back, B close,
--     Y hide at startup; physical buttons, before the X<->B swap) and the game is paused (panel option).
--     The open gesture closes it again on any page (gestureCloses), the same as B.
--   * UI placement: BL4 keeps UEVR's UI head-locked (config UI_FollowView=true) and bl4_main.lua runs libs/ui.lua, so
--     the lib's ui.lua view lock / controller-mouse states are off (lockView / disableControllerMouse = false): clearing
--     the lock on close would hand UEVR's follow-view to ui.lua's default. The page is moved inside its own widget to
--     where UI_X_Offset / UI_Y_Offset PAGE_UI_OFFSET_X / _Y would put it (pageOffset); the offsets are never written.
-- Panel: "VR Tutorial" section of the Borderlands 4 panel (zz_bl4_vr_panel.lua builds it from _G.BL4_SECTIONS).

local uevrUtils = require('libs/uevr_utils')
local configui = require('libs/configui')
local controllers = require('libs/controllers')
local tutorial = require('libs/tutorial')

_G.BL4_SECTIONS = _G.BL4_SECTIONS or {}
table.insert(_G.BL4_SECTIONS, { order = 6, label = "VR Tutorial", layout = {
	{ widgetType = "button", id = "bl4_tut_show", label = "Show the VR tutorial", size = {220, 24} },
	{ widgetType = "checkbox", id = "bl4_tut_startup", label = "Show it when gameplay starts (until closed once)", initialValue = true },
	{ widgetType = "checkbox", id = "bl4_tut_gesture", label = "Open it with the left trigger at your eyes", initialValue = true },
	{ widgetType = "checkbox", id = "bl4_tut_pause", label = "Pause the game while it is open", initialValue = true },
	{ widgetType = "button", id = "bl4_tut_reset", label = "Show it again at the next start", size = {260, 24} },
	{ widgetType = "text", id = "bl4_tut_status", label = "" },
}})

local function enabled(id)
	return configui.getValue(id) ~= false -- nil until the panel exists: the initial value (true)
end

local function log(text)
	pcall(function() uevr.params.functions.log_info("[bl4_vr_tutorial] " .. tostring(text)) end)
end

-- Rising edge of the PHYSICAL left trigger, read before the tutorial's gesture check (priority 100001) and every other
-- handler. gestures.lua's face detector uses the same threshold (> 128).
local TRIGGER_THRESHOLD = 128
local leftTriggerWasDown = false
local leftTriggerPulled = false
uevrUtils.registerOnPreInputGetStateCallback(function(retval, userIndex, state)
	if userIndex ~= nil and userIndex ~= 0 then return end
	local down = state.Gamepad.bLeftTrigger > TRIGGER_THRESHOLD
	leftTriggerPulled = down and not leftTriggerWasDown
	leftTriggerWasDown = down
end, 100002)

-- not the player character on foot (vehicles, main menu), the mouse cursor shown (ECHO menus and the pause menu, MCP
-- 2026-11-05/07: bShowMouseCursor is true in both), pause, or input handed to the game (cutscenes: libs/ui.lua)
local function isBlocked()
	local ok, result = pcall(function()
		if _G.bl4 == nil or _G.bl4.getPlayerCharacter() == nil then return true end
		local pc = uevr.api:get_player_controller(0)
		if pc ~= nil and pc.bShowMouseCursor == true then return true end
		if uevrUtils.isInCutscene() then return true end
		if uevrUtils.executeUEVRCallbacksWithPriorityBooleanResult("is_input_disabled") == true then return true end
		local world = uevrUtils.get_world()
		return world ~= nil and Statics ~= nil and Statics:IsGamePaused(world) == true
	end)
	return not ok or result == true
end

-- false while the left trigger near the eyes belongs to something else (asked only once the gesture is detected)
local function gestureAllowed()
	if not enabled("bl4_tut_gesture") then return false end
	if not leftTriggerPulled then return false end
	if _G.isTwoHandingActive == true then return false end
	if isBlocked() then return false end
	return true
end

-- Where the page appears, in UEVR UI offset metres (see the header): a little right of centre, as in Cronos / OW2
-- (BL4's own HUD sits at UI_X_Offset 0.426)
local PAGE_UI_OFFSET_X = 0.213
local PAGE_UI_OFFSET_Y = 0.0

-- UEVR moves the whole UI quad by UI_X_Offset / UI_Y_Offset metres along its right / up axes, and the quad is UI_Size
-- metres tall for the full viewport height. So moving the page by (target - current) metres is (target - current) /
-- UI_Size viewport heights inside the widget (Slate y points down, UEVR's up axis up). Read at every page layout.
local function pageOffset()
	local ok, x, y = pcall(function()
		local vr = uevr.params.vr
		local currentX = tonumber(vr:get_mod_value("UI_X_Offset")) or 0
		local currentY = tonumber(vr:get_mod_value("UI_Y_Offset")) or 0
		local size = tonumber(vr:get_mod_value("UI_Size")) or 0
		if size <= 0 or WidgetLayoutLibrary == nil then return 0, 0 end
		local world = uevrUtils.get_world()
		local viewport = WidgetLayoutLibrary:GetViewportSize(world)
		local scale = WidgetLayoutLibrary:GetViewportScale(world)
		if viewport == nil or scale == nil or scale <= 0 then return 0, 0 end
		local height = viewport.Y / scale
		return (PAGE_UI_OFFSET_X - currentX) / size * height, -(PAGE_UI_OFFSET_Y - currentY) / size * height
	end)
	if not ok then return 0, 0 end
	return x or 0, y or 0
end

-- true while the tutorial on screen is the automatic startup one: closing that one stops the startup show
local startupShow = false
-- true until the startup tutorial has been shown in gameplay this session (see inGameplay below)
local startupPending = false

local t = tutorial.new({
	imageSize = 1536,
	pauseGame = enabled("bl4_tut_pause"),
	lockView = false,
	disableControllerMouse = false,
	buttons = { start = "A", next = "A", done = "A", back = "X", close = "B", skip = "B", hideAtStartup = "Y" },
	labels = { close = "Close (or gesture)" },
	openGestureCondition = gestureAllowed,
	gestureCloses = true, -- the open gesture is a toggle: it closes the tutorial on any page too
	pageOffset = pageOffset,
	-- once per session: which loaded Widget Blueprint class libs/widget borrowed for the host (it must not be one of
	-- data/ui_parameters.json's widgetlist classes, although ui.ignoreWidget keeps ui.lua off it anyway)
	onOpen = function(self)
		if self.hostClassLogged then return end
		self.hostClassLogged = true
		pcall(function() log("host widget class: " .. self.host:get_class():get_full_name()) end)
	end,
	onClose = function(self, reason)
		if reason == "level_change" then
			-- closed without the player choosing to: the startup tutorial comes back in the next gameplay
			if startupShow then startupPending = true end
			startupShow = false
			return
		end
		if startupShow and (reason == "closed" or reason == "skipped") then self:setCompleted(true) end
		startupShow = false
	end,
})

-- The startup tutorial waits for real gameplay:
--   * the pawn is the player character on foot (OakCharacter, _G.bl4.getPlayerCharacter; the main menu has none)
--   * the player controller is the game's (OakPlayerController)
--   * the motion controller components exist (libs/gestures reads the cached left controller and HMD)
--   * none of isBlocked (menus, pause, cutscenes, disabled input)
-- held for STARTUP_HOLD_S, so a level that is still streaming in or a cutscene about to start does not get it.
-- The controller class is matched by name up the class chain, so the /Script/ module it lives in does not matter.
local function isA(object, classNames)
	if object == nil then return false end
	local class = object:get_class()
	while class ~= nil do
		local name = class:get_fname():to_string()
		for _, wanted in ipairs(classNames) do
			if name == wanted then return true end
		end
		class = class:get_super_struct()
	end
	return false
end

local PLAYER_CONTROLLER = { "OakPlayerController" }

local function inGameplay()
	local ok, result = pcall(function()
		if isBlocked() then return false end -- includes "no player character"
		if not isA(uevr.api:get_player_controller(0), PLAYER_CONTROLLER) then return false end
		return controllers.controllerExists(Handed.Left) and controllers.hmdControllerExists()
	end)
	return ok and result == true
end

startupPending = not t:isCompleted()
local STARTUP_POLL_S = 0.5
local STARTUP_HOLD_S = 2.0
local startupPollTimer = 0
local gameplayFor = 0
uevrUtils.registerPreEngineTickCallback(function(engine, delta)
	if not startupPending or t:isOpen() then return end
	startupPollTimer = startupPollTimer + (tonumber(delta) or 0)
	if startupPollTimer < STARTUP_POLL_S then return end
	local elapsed = startupPollTimer
	startupPollTimer = 0
	if t:isCompleted() then startupPending = false return end
	if not enabled("bl4_tut_startup") then gameplayFor = 0 return end -- option off: keep waiting in case it is turned back on
	if not inGameplay() then gameplayFor = 0 return end
	gameplayFor = gameplayFor + elapsed
	if gameplayFor < STARTUP_HOLD_S then return end
	gameplayFor = 0
	startupPending = false
	startupShow = t:showOnce()
	-- the lib's own warnings are below its log level: say why nothing opened (no pages, or no host widget class)
	if not startupShow then log("startup show failed (pages " .. tostring(t.count) .. ", intro " .. tostring(t.hasIntro) .. ", host " .. tostring(t.host ~= nil) .. ")") end
end)

uevrUtils.registerPreLevelChangeCallback(function()
	gameplayFor = 0
end)

local function updateStatus()
	configui.setLabel("bl4_tut_status", t:isCompleted() and "Shown at start: no (closed, finished or hidden)" or "Shown at start: yes")
end

-- Panel buttons run while UEVR draws its overlay: widgets are made on the next engine tick instead
local pending = nil
configui.onUpdate("bl4_tut_show", function() pending = "show" end)
configui.onUpdate("bl4_tut_reset", function() pending = "reset" end)
configui.onCreateOrUpdate("bl4_tut_pause", function(value) t.options.pauseGame = value ~= false end)

uevrUtils.registerPreEngineTickCallback(function()
	if pending == nil then return end
	local action = pending
	pending = nil
	if action == "show" then
		startupShow = false
		if not t:show(t:getSavedPage() or 1) then log("panel show failed (pages " .. tostring(t.count) .. ", intro " .. tostring(t.hasIntro) .. ")") end
	elseif action == "reset" then
		startupShow = false
		t:resetCompleted()
		t:resetInteraction()
		t:resetSavedPage()
	end
	updateStatus()
end)

uevrUtils.setTimeout(1000, updateStatus)
