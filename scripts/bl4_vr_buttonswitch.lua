-- Swaps the gamepad X and B buttons the game sees (port of the Hellraiser / OW2 profiles' buttonswitch.lua), as an
-- option in the "Borderlands 4" panel's General section. A plain bit swap, so holding both buttons keeps both pressed.
-- No other BL4 script reads X or B (2026-11-05), so nothing else is affected.

local configui = require('libs/configui')

local XINPUT_X = 0x4000
local XINPUT_B = 0x2000

-- option goes into bl4_main.lua's "General" section (bl4_main loads first; a second "General" entry would make a
-- second header)
local OPTION = { widgetType = "checkbox", id = "bl4_swap_xb", label = "Swap X and B buttons", initialValue = true }
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

uevr.sdk.callbacks.on_xinput_get_state(function(retval, user_index, state)
	if state == nil then return end
	if configui.getValue("bl4_swap_xb") == false then return end -- nil until the panel exists: treat as the default (on)
	local buttons = state.Gamepad.wButtons
	local x = (buttons & XINPUT_X) ~= 0
	local b = (buttons & XINPUT_B) ~= 0
	if x == b then return end -- neither or both pressed: nothing to swap
	buttons = buttons & ~(XINPUT_X | XINPUT_B)
	if x then buttons = buttons | XINPUT_B end
	if b then buttons = buttons | XINPUT_X end
	state.Gamepad.wButtons = buttons
end)
