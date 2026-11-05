-- Gun aim alignment for the game grip (bl4_main.lua, option bl4_game_grip), Borderlands 4 (2026-11-05).
--
-- With the game grip the gun sits in the hand exactly as the flat game holds it, but the game's grip angles each gun
-- differently against the hand (measured pitch 7-26 deg): in the flat game the camera aims, not the hand. In VR the
-- barrel must follow the controller ("doesn't point where the controller points, rotated right a bit", xaero). The old
-- per-weapon hand offsets (Attachments hand_location / hand_rotation, hand tuned against the old gun offsets) no longer
-- fit either.
--
-- So while the game grip is on, the per-weapon hand offset both hand modes read (attachments.getAttachmentHandOffset:
-- libs/hands.lua joint offset in Hands mode, bl4_vr_ik.lua IK hand target in IK mode) is replaced by an automatic wrist
-- rotation that turns the hand until the gun's frame matches the right controller's frame:
--   gun = controller * Base * Rot * G   (Base = the mode's hand offset, Rot = the per-weapon offset, G = game grip)
--   E = controller^-1 * gun (measured)  ->  wanted Base * Rot' * G = I  ->  Rot' = Rot * G * E^-1 * G^-1
-- applied, re-measured and repeated until E is below ALIGN_DONE_DEG, then saved per weapon and hand mode in
-- data/bl4_auto_hand.json. Location offset 0 (the game grip places the gun). Measured only while the gun rides the hand
-- bone, not two-handing and not firing (recoil moves the hand).

local uevrUtils = require('libs/uevr_utils')
local controllers = require('libs/controllers')
local configui = require('libs/configui')
local attachments = require('libs/attachments')

local AUTO_HAND_FILE = "bl4_auto_hand.json"
local ALIGN_DONE_DEG = 0.3      -- this close counts as aligned
local ALIGN_MAX_STEPS = 6       -- corrections per weapon before giving up (logged)
local ALIGN_SETTLE_S = 0.25     -- after each correction, let the hand / IK apply it first
local BTN_RT_THRESHOLD = 30

-- Global aim trim (xaero 2026-11-05): the alignment matches the gun to the controller component's own axes, which need
-- not match where the hand feels it points. T = rotator(pitch, yaw, 0) in the controller frame; the gun ends up at
-- controller * T. Applied on top of the aligned rotation in closed form (Base * Rot * G = I  ->  Rot * G * T * G^-1
-- gives Base * that * G = T), so moving the sliders needs no re-measuring.
_G.BL4_SECTIONS = _G.BL4_SECTIONS or {}
table.insert(_G.BL4_SECTIONS, { order = 0.5, label = "Weapon Aim", layout = {
    { widgetType = "slider_float", id = "bl4_aim_trim_yaw", label = "Gun aim left / right (deg, + = right)", initialValue = 0.0, range = {-30.0, 30.0}, speed = 0.1 },
    { widgetType = "slider_float", id = "bl4_aim_trim_pitch", label = "Gun aim down / up (deg, + = up)", initialValue = 0.0, range = {-30.0, 30.0}, speed = 0.1 },
}})

local function log(text)
    if _G.bl4 ~= nil and _G.bl4.log ~= nil then _G.bl4.log("[grip align] " .. tostring(text)) else print("[grip align] " .. tostring(text)) end
end

-- ---------------------------------------------------------------------------------------------
-- Quaternions (UE FQuat conventions: q * v * q^-1, A * B = B first, then A)
-- ---------------------------------------------------------------------------------------------
local D2R, R2D = math.pi / 180, 180 / math.pi
local function quatFromRotator(r)
    local sp, cp = math.sin(r.Pitch * D2R / 2), math.cos(r.Pitch * D2R / 2)
    local sy, cy = math.sin(r.Yaw * D2R / 2), math.cos(r.Yaw * D2R / 2)
    local sr, cr = math.sin(r.Roll * D2R / 2), math.cos(r.Roll * D2R / 2)
    return { X = cr * sp * sy - sr * cp * cy, Y = -cr * sp * cy - sr * cp * sy,
        Z = cr * cp * sy - sr * sp * cy, W = cr * cp * cy + sr * sp * sy }
end
local function rotatorFromQuat(q)
    local singularity = q.Z * q.X - q.W * q.Y
    local yaw = math.atan(2 * (q.W * q.Z + q.X * q.Y), 1 - 2 * (q.Y * q.Y + q.Z * q.Z)) * R2D
    if singularity < -0.4999995 then
        return { Pitch = -90, Yaw = yaw, Roll = (-yaw - 2 * math.atan(q.X, q.W) * R2D + 180) % 360 - 180 }
    elseif singularity > 0.4999995 then
        return { Pitch = 90, Yaw = yaw, Roll = (yaw - 2 * math.atan(q.X, q.W) * R2D + 180) % 360 - 180 }
    end
    return { Pitch = math.asin(2 * singularity) * R2D, Yaw = yaw,
        Roll = math.atan(-2 * (q.W * q.X + q.Y * q.Z), 1 - 2 * (q.X * q.X + q.Y * q.Y)) * R2D }
end
local function qmul(a, b)
    return { X = a.W * b.X + a.X * b.W + a.Y * b.Z - a.Z * b.Y, Y = a.W * b.Y - a.X * b.Z + a.Y * b.W + a.Z * b.X,
        Z = a.W * b.Z + a.X * b.Y - a.Y * b.X + a.Z * b.W, W = a.W * b.W - a.X * b.X - a.Y * b.Y - a.Z * b.Z }
end
local function qinv(q) return { X = -q.X, Y = -q.Y, Z = -q.Z, W = q.W } end
local function qangle(q) return 2 * math.acos(math.min(1, math.abs(q.W))) * R2D end

-- ---------------------------------------------------------------------------------------------
-- Per-weapon automatic hand rotation, keyed by attachment id + hand mode (the modes' base hand offsets differ)
-- ---------------------------------------------------------------------------------------------
local autoHand = {}
pcall(function() autoHand = json.load_file(AUTO_HAND_FILE) or {} end)

local function gameGripOn() return configui.getValue("bl4_game_grip") ~= false end
local function modeKey() return (_G.getHandsMode ~= nil and _G.getHandsMode() == 2) and "IK" or "Hands" end
local function entryKey(id) return tostring(id) .. "|" .. modeKey() end

local session = {} -- entryKey -> { rot = {Pitch,Yaw,Roll}, steps, done, at } (unsaved corrections in progress)

local function currentRot(id)
    local key = entryKey(id)
    local s = session[key]
    if s ~= nil then return s.rot end
    local saved = autoHand[key]
    if saved ~= nil then return saved end
    return { Pitch = 0, Yaw = 0, Roll = 0 }
end

local function trimQuat()
    local p, y = configui.getValue("bl4_aim_trim_pitch"), configui.getValue("bl4_aim_trim_yaw")
    p, y = type(p) == "number" and p or 0, type(y) == "number" and y or 0
    if p == 0 and y == 0 then return nil end
    return quatFromRotator({ Pitch = p, Yaw = y, Roll = 0 })
end

local function heldGunAndGrip()
    if _G.bl4 == nil then return nil, nil end
    local pawn = _G.bl4.getPlayerCharacter()
    local weapon = pawn ~= nil and _G.bl4.getHeldWeapon(pawn) or nil
    local gun = weapon ~= nil and _G.bl4.getFirstPersonWeaponMesh(weapon) or nil
    if gun == nil then return nil, nil end
    return gun, _G.bl4.getGameGrip(gun)
end

-- libs/hands.lua asks for both hands' offsets through the same call: remember which hand is asking, so the right
-- hand's automatic rotation never lands on the left hand.
local hands = require('libs/hands')
local askingHand = nil
local originalSetJointOffset = hands.setJointOffsetFromAttachment
hands.setJointOffsetFromAttachment = function(hand, attachmentID)
    askingHand = hand
    local ok, err = pcall(originalSetJointOffset, hand, attachmentID)
    askingHand = nil
    if not ok then error(err) end
end

-- Both hand modes read the per-weapon hand offset here: game grip on -> location 0, the automatic rotation (+ trim).
-- Ordnance / left-hand entries keep their own offsets.
local originalGetHandOffset = attachments.getAttachmentHandOffset
attachments.getAttachmentHandOffset = function(id)
    if gameGripOn() and askingHand ~= Handed.Left and id ~= nil and id ~= ""
        and attachments.getActiveAttachmentID(Handed.Right) == id then
        local r = currentRot(id)
        local t = trimQuat()
        local _, grip = heldGunAndGrip()
        if t ~= nil and grip ~= nil then
            local g = quatFromRotator(grip.rot)
            r = rotatorFromQuat(qmul(qmul(qmul(quatFromRotator(r), g), t), qinv(g)))
        end
        return { 0, 0, 0 }, { r.Pitch, r.Yaw, r.Roll }
    end
    return originalGetHandOffset(id)
end

local function notifyHandOffsetChanged(id)
    uevrUtils.executeUEVRCallbacks("attachment_hand_offset_changed", id)
end

-- ---------------------------------------------------------------------------------------------
-- Alignment probe
-- ---------------------------------------------------------------------------------------------
local triggerHeld = false
uevrUtils.registerOnPreInputGetStateCallback(function(retval, user_index, state)
    if user_index == 0 and state ~= nil then triggerHeld = state.Gamepad.bRightTrigger >= BTN_RT_THRESHOLD end
end)

-- the game grip rotation an alignment was solved for (entries saved before 2026-11-05 have none -> solved again)
local function gripMatches(savedGrip, grip)
    if type(savedGrip) ~= "table" then return false end
    local function d(a, b) return math.abs(((a or 0) - (b or 0) + 180) % 360 - 180) end
    return d(savedGrip.Pitch, grip.rot.Pitch) < 0.5 and d(savedGrip.Yaw, grip.rot.Yaw) < 0.5 and d(savedGrip.Roll, grip.rot.Roll) < 0.5
end

local lastId, lastMode = nil, nil
local function probe()
    if not gameGripOn() or _G.bl4 == nil then return end
    local id = attachments.getActiveAttachmentID(Handed.Right)
    if id == nil or id == "" then return end
    local mode = modeKey()
    if id ~= lastId or mode ~= lastMode then
        -- a new weapon / mode: make the hands pick up this entry's offset at once
        lastId, lastMode = id, mode
        notifyHandOffsetChanged(id)
        return
    end
    local key = entryKey(id)
    local s = session[key]
    if s ~= nil and s.done then return end
    if triggerHeld or _G.isTwoHandingActive == true then return end

    local pawn = _G.bl4.getPlayerCharacter()
    local weapon = pawn ~= nil and _G.bl4.getHeldWeapon(pawn) or nil
    local gun = weapon ~= nil and _G.bl4.getFirstPersonWeaponMesh(weapon) or nil
    if gun == nil then return end
    local grip = _G.bl4.getGameGrip(gun)
    if grip == nil then return end -- not measured yet
    -- saved and aligned earlier, for this grip (a re-measured grip turns the gun in the hand: align again from there)
    if s == nil and autoHand[key] ~= nil and gripMatches(autoHand[key].grip, grip) then return end
    local onHandBone = false
    pcall(function() onHandBone = gun.AttachSocketName ~= nil and gun.AttachSocketName:to_string() == "R_Hand" end)
    if not onHandBone then return end
    if s ~= nil and os.clock() - s.at < ALIGN_SETTLE_S then return end

    local ctrl = controllers.getController(Handed.Right, true)
    if ctrl == nil then return end
    local qc = quatFromRotator(ctrl:K2_GetComponentRotation())
    local qg = quatFromRotator(gun:K2_GetComponentRotation())
    local e = qmul(qinv(qc), qg)
    -- the hand currently carries the trim (gun = controller * E0 * T): measure the untrimmed error E0 = E * T^-1
    local t = trimQuat()
    if t ~= nil then e = qmul(e, qinv(t)) end
    local errorDeg = qangle(e)
    local rot = currentRot(id)
    if errorDeg <= ALIGN_DONE_DEG then
        autoHand[key] = { Pitch = rot.Pitch, Yaw = rot.Yaw, Roll = rot.Roll,
            grip = { Pitch = grip.rot.Pitch, Yaw = grip.rot.Yaw, Roll = grip.rot.Roll } }
        session[key] = { rot = rot, steps = s and s.steps or 0, done = true, at = os.clock() }
        pcall(function() json.dump_file(AUTO_HAND_FILE, autoHand, 4) end)
        log(string.format("%s (%s) aligned: hand rotation (%.1f %.1f %.1f)", id, mode, rot.Pitch, rot.Yaw, rot.Roll))
        return
    end
    local steps = (s and s.steps or 0) + 1
    if steps > ALIGN_MAX_STEPS then
        session[key] = { rot = rot, steps = steps, done = true, at = os.clock() }
        log(string.format("%s (%s): still %.1f deg off after %d corrections - kept (%.1f %.1f %.1f)", id, mode, errorDeg,
            ALIGN_MAX_STEPS, rot.Pitch, rot.Yaw, rot.Roll))
        return
    end
    local qg2 = quatFromRotator(grip.rot)
    local q = qmul(qmul(qmul(quatFromRotator(rot), qg2), qinv(e)), qinv(qg2))
    local newRot = rotatorFromQuat(q)
    session[key] = { rot = newRot, steps = steps, done = false, at = os.clock() }
    log(string.format("%s (%s): gun %.1f deg off the controller -> hand rotation (%.1f %.1f %.1f)", id, mode, errorDeg,
        newRot.Pitch, newRot.Yaw, newRot.Roll))
    notifyHandOffsetChanged(id)
end

uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
    local ok, err = pcall(probe)
    if not ok then log(tostring(err)) end
end)

-- "Re-measure all weapon grips" (bl4_main.lua) also forgets the alignments
configui.onUpdate("bl4_game_grip_reset", function(value)
    autoHand, session = {}, {}
    lastId, lastMode = nil, nil
    pcall(function() json.dump_file(AUTO_HAND_FILE, autoHand, 4) end)
end)
-- "Re-measure this weapon's grip": also align the held weapon again, in both hand modes
configui.onUpdate("bl4_game_grip_reset_current", function(value)
    uevrUtils.setTimeout(1, function()
        local id = attachments.getActiveAttachmentID(Handed.Right)
        if id == nil or id == "" then return end
        for _, mode in ipairs({ "Hands", "IK" }) do
            local key = tostring(id) .. "|" .. mode
            autoHand[key], session[key] = nil, nil
        end
        lastId, lastMode = nil, nil
        pcall(function() json.dump_file(AUTO_HAND_FILE, autoHand, 4) end)
        log(tostring(id) .. ": hand alignment cleared (both modes)")
    end)
end)
configui.onUpdate("bl4_game_grip", function(value)
    lastId, lastMode = nil, nil -- re-apply the right offsets for the new setting
end)
-- trim moved: re-apply the active weapon's hand offset (configui callbacks run on the draw thread -> game thread)
local function reapplyTrim()
    uevrUtils.setTimeout(1, function()
        local id = attachments.getActiveAttachmentID(Handed.Right)
        if id ~= nil and id ~= "" then notifyHandOffsetChanged(id) end
    end)
end
configui.onUpdate("bl4_aim_trim_yaw", reapplyTrim)
configui.onUpdate("bl4_aim_trim_pitch", reapplyTrim)

log("loaded")
