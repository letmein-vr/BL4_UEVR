-- Ordnance throws (throwing knives, grenades) along the left hand's swing for Borderlands 4 (2026-11-05), the swing /
-- release half of the Hellraiser profile's throwables.lua.
--
-- Game facts (MCP 2026-11-05, Jakobs throwing knives):
--   * Holding the ordnance button (RB) readies a knife: the pawn's GrenadeGadget (OakCharacter.GetGrenadeGadget) goes
--     AttachState 0 -> 1 and its first-person mesh is held in the left hand (bl4_main.lua puts it on the VR left hand).
--   * Releasing throws: AttachState 1 -> 0 on the same tick as NumberOfCharges drops, and a ModularGrenade actor
--     ("jakobs_grenade_*", an OakProjectile / GbxGame.projectile) appears, instigator = the pawn, ~8000 cm/s along the
--     camera (head aim). It has no ProjectileMovementComponent; projectile.SetVelocity steers it.
--
-- VR: while a knife is readied, the left hand's velocity relative to the head is sampled (walking / turning does not
-- count), keeping the fastest one of the last PEAK_WINDOW_S. On the throw, the new projectile is moved in front of the
-- left hand and flies at the game's speed (x panel scale, so damage and range stay the game's) where the left
-- controller points at release (default; a curved swing's path drifted off the aim, xaero 2026-11-05) or along the swing.
-- A release slower than the panel minimum keeps the game's own head-aimed throw.

local uevrUtils = require('libs/uevr_utils')
local controllers = require('libs/controllers')
local configui = require('libs/configui')

local ORDNANCE_IN_HAND = 1        -- InventoryGadget.AttachState while readied in the hand
local PROJECTILE_CLASS = "Class /Script/GbxGame.projectile"
local SAMPLE_WINDOW_S  = 0.06     -- hand velocity = motion over this window
local PEAK_WINDOW_S    = 0.12     -- best windowed velocity this long before the release counts
local SPAWN_WAIT_S     = 1.0      -- look for the thrown projectile this long after the button release
local SPAWN_MAX_AGE_S  = 0.3      -- only projectiles this young are the throw
local REAPPLY_S        = 0.2      -- keep our velocity this long if the game writes its own again
local SAME_DIR_DOT     = 0.9986   -- ~3 deg

_G.BL4_SECTIONS = _G.BL4_SECTIONS or {}
table.insert(_G.BL4_SECTIONS, { order = 2.8, label = "Throwing", layout = {
    { widgetType = "checkbox", id = "bl4_thr_enabled", label = "Throw knives / grenades with a left hand swing (off = the game's head-aimed throw)", initialValue = true },
    { widgetType = "combo", id = "bl4_thr_direction", label = "Throw direction", initialValue = 1,
        selections = { "Where the left hand points (fastest moment of the swing)", "Along the swing", "Where you look (HMD)" } },
    { widgetType = "slider_float", id = "bl4_thr_pitch_trim", label = "Aim down / up (deg, + = up)", initialValue = 0.0, range = {-45.0, 45.0}, speed = 0.5 },
    { widgetType = "slider_float", id = "bl4_thr_min_swing", label = "Slowest swing that steers the throw (cm/s)", initialValue = 150.0, range = {50.0, 600.0}, speed = 5.0 },
    { widgetType = "slider_float", id = "bl4_thr_speed", label = "Throw speed (x game speed)", initialValue = 1.0, range = {0.5, 2.0}, speed = 0.01 },
    { widgetType = "slider_float", id = "bl4_thr_spawn_dist", label = "Start this far ahead of the hand (cm)", initialValue = 20.0, range = {0.0, 80.0}, speed = 0.5 },
    { widgetType = "text", id = "bl4_thr_last", label = "Last throw: -" },
    { widgetType = "text", label = "Knife / grenade trim in the left hand (both hand modes; 0 = the game's L_Hand_Object grip)" },
    { widgetType = "drag_float3", id = "bl4_ik_ordnance_loc", label = "Grip position trim (cm)", initialValue = { 0.0, 0.0, 0.0 }, range = {-30, 30}, speed = 0.1 },
    { widgetType = "drag_float3", id = "bl4_ik_ordnance_rot", label = "Grip rotation trim (deg)", initialValue = { 0.0, 0.0, 0.0 }, range = {-180, 180}, speed = 0.5 },
}})

local function log(text)
    if _G.bl4 ~= nil and _G.bl4.log ~= nil then _G.bl4.log("[throw] " .. tostring(text)) else print("[throw] " .. tostring(text)) end
end

local function cfgNum(id, default)
    local v = configui.getValue(id)
    return type(v) == "number" and v or default
end

local function vlen(v) return math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z) end
local function alive(o) return o ~= nil and uevrUtils.getValid(o) ~= nil end

-- ---------------------------------------------------------------------------------------------
-- Left hand velocity (relative to the head), sampled once per tick from the post-stereo callback (valid poses)
-- ---------------------------------------------------------------------------------------------
local samples = {}      -- { t, X, Y, Z } of hand - head, newest last
local lastHand = nil    -- world position of the hand at the newest sample
local lastPointing = nil -- the left controller's forward at the newest sample (direction mode "where it points")
local bestVel = nil     -- { t, X, Y, Z }: fastest windowed velocity within PEAK_WINDOW_S

local function clearSamples()
    samples, bestVel, lastHand, lastPointing = {}, nil, nil, nil
end

local function sampleHand()
    local hand = controllers.getController(Handed.Left, true)
    local head = controllers.getHMDController()
    if not alive(hand) or not alive(head) then clearSamples() return end
    local hp, hd = hand:K2_GetComponentLocation(), head:K2_GetComponentLocation()
    if hp == nil or hd == nil then clearSamples() return end
    local now = os.clock()
    local newest = samples[#samples]
    if newest ~= nil and now - newest.t > 0.1 then clearSamples() end
    lastHand = { X = hp.X, Y = hp.Y, Z = hp.Z }
    local f = kismet_math_library:GetForwardVector(hand:K2_GetComponentRotation())
    lastPointing = { X = f.X, Y = f.Y, Z = f.Z }
    table.insert(samples, { t = now, X = hp.X - hd.X, Y = hp.Y - hd.Y, Z = hp.Z - hd.Z })
    while #samples > 1 and now - samples[1].t > 0.3 do table.remove(samples, 1) end

    local cur = samples[#samples]
    local old = nil
    for i = #samples - 1, 1, -1 do
        old = samples[i]
        if cur.t - old.t >= SAMPLE_WINDOW_S then break end
    end
    if old == nil or cur.t - old.t < 0.005 then return end
    local dt = cur.t - old.t
    local v = { t = now, X = (cur.X - old.X) / dt, Y = (cur.Y - old.Y) / dt, Z = (cur.Z - old.Z) / dt }
    -- the controller's pointing is kept from the fastest moment of the swing: at the release of an overhand throw the
    -- wrist is tipped back and the controller points 40-50 deg up (log 2026-11-05: dir Z 0.64-0.78)
    v.pointing = lastPointing
    if bestVel == nil or now - bestVel.t > PEAK_WINDOW_S or vlen(v) >= vlen(bestVel) then bestVel = v end
end

-- ---------------------------------------------------------------------------------------------
-- Release -> projectile
-- ---------------------------------------------------------------------------------------------
local readied = false  -- the gadget was in the hand on the last tick
local pending = nil    -- swing throw waiting for its projectile: { at, dir, hand, handSpeed }
local corrected = nil  -- { actor, vel, gameDir, at }
local handled = {}     -- projectile address -> true

local function ordnanceReadied(pawn)
    local ok, state = pcall(function()
        local gadget = uevrUtils.getValid(pawn:GetGrenadeGadget())
        return gadget ~= nil and gadget.AttachState or nil
    end)
    return ok and state == ORDNANCE_IN_HAND
end

-- Called on the RB release (the input edge), not on AttachState 1 -> 0: the game takes the knife out of the hand only
-- when its throw animation ends, 0.3-0.5 s later, when the swing is long over (log 2026-11-05: "swing 14 cm/s").
local function onRelease()
    local v = bestVel
    if configui.getValue("bl4_thr_enabled") == false then return end
    if v == nil or lastHand == nil then
        log(string.format("release without hand samples (%d samples) - game throw", #samples))
        return
    end
    local handSpeed = vlen(v)
    if handSpeed < cfgNum("bl4_thr_min_swing", 150.0) then
        configui.setLabel("bl4_thr_last", string.format("Last throw: game aim (swing %.0f cm/s too slow)", handSpeed))
        log(string.format("release: swing %.0f cm/s below the minimum - game throw", handSpeed))
        return
    end
    log(string.format("release: swing %.0f cm/s, looking for the projectile", handSpeed))
    local dir = { X = v.X / handSpeed, Y = v.Y / handSpeed, Z = v.Z / handSpeed }
    local mode = configui.getValue("bl4_thr_direction")
    if mode == 3 then
        local head = controllers.getHMDController()
        local g = kismet_math_library:GetForwardVector(head:K2_GetComponentRotation())
        dir = { X = g.X, Y = g.Y, Z = g.Z }
    elseif mode ~= 2 and (v.pointing or lastPointing) ~= nil then
        dir = v.pointing or lastPointing
    end
    -- aim pitch trim (+ = up), about the direction's own horizontal right axis
    local trim = math.rad(cfgNum("bl4_thr_pitch_trim", 0.0))
    if trim ~= 0 then
        local horizontal = math.sqrt(dir.X * dir.X + dir.Y * dir.Y)
        if horizontal > 0.001 then
            local pitch = math.atan(dir.Z, horizontal) + trim
            local h = math.cos(pitch) / horizontal
            dir = { X = dir.X * h, Y = dir.Y * h, Z = math.sin(pitch) }
        end
    end
    pending = { at = os.clock(), dir = dir, hand = { X = lastHand.X, Y = lastHand.Y, Z = lastHand.Z }, handSpeed = handSpeed }
end

local function steer(actor, p)
    local gv = actor:GetVelocity()
    local gameSpeed = vlen(gv)
    if gameSpeed < 1 then return false end
    local gameDir = { X = gv.X / gameSpeed, Y = gv.Y / gameSpeed, Z = gv.Z / gameSpeed }
    local speed = gameSpeed * cfgNum("bl4_thr_speed", 1.0)
    local dist = cfgNum("bl4_thr_spawn_dist", 20.0)
    local d = p.dir
    -- start from the hand where it is now (the spawn comes up to ~0.5 s after the release), else where it released
    local hand = p.hand
    pcall(function()
        local h = controllers.getController(Handed.Left, true):K2_GetComponentLocation()
        if h ~= nil then hand = { X = h.X, Y = h.Y, Z = h.Z } end
    end)
    local pos = { X = hand.X + d.X * dist, Y = hand.Y + d.Y * dist, Z = hand.Z + d.Z * dist }
    local vel = { X = d.X * speed, Y = d.Y * speed, Z = d.Z * speed }
    local rot = kismet_math_library:Conv_VectorToRotator(uevrUtils.vector(vel.X, vel.Y, vel.Z))
    actor:K2_SetActorLocationAndRotation(uevrUtils.vector(pos.X, pos.Y, pos.Z), rot, false, reusable_hit_result, true)
    actor:SetVelocity(uevrUtils.vector(vel.X, vel.Y, vel.Z))
    corrected = { actor = actor, vel = vel, gameDir = gameDir, at = os.clock() }
    configui.setLabel("bl4_thr_last", string.format("Last throw: swing %.0f cm/s -> %.0f cm/s", p.handSpeed, speed))
    log(string.format("%s: release -> spawn %.0f ms, swing %.0f cm/s, game dir (%.2f %.2f %.2f) %.0f cm/s -> dir (%.2f %.2f %.2f) %.0f cm/s",
        actor:get_fname():to_string(), (os.clock() - p.at) * 1000, p.handSpeed, gameDir.X, gameDir.Y, gameDir.Z, gameSpeed,
        d.X, d.Y, d.Z, speed))
    return true
end

local function findThrownProjectile(pawn)
    local pawnAddress = pawn:get_address()
    for _, actor in ipairs(uevrUtils.getAllActorsOfClass(PROJECTILE_CLASS)) do
        local address = actor ~= nil and actor:get_address() or nil
        if address ~= nil and not handled[address] then
            local ok, mine = pcall(function()
                local instigator = actor:GetInstigator()
                return instigator ~= nil and instigator:get_address() == pawnAddress
                    and actor:GetGameTimeSinceCreation() <= SPAWN_MAX_AGE_S
            end)
            if ok and mine then
                handled[address] = true
                return actor
            end
        end
    end
    return nil
end

-- the game writing its own velocity again right after the spawn: put ours back; anything else (a hit) ends it
local function holdVelocity()
    local c = corrected
    if c == nil then return end
    if os.clock() - c.at > REAPPLY_S or not alive(c.actor) then corrected = nil return end
    local v = c.actor:GetVelocity()
    local speed = vlen(v)
    if speed < 1 then corrected = nil return end
    if (v.X * c.gameDir.X + v.Y * c.gameDir.Y + v.Z * c.gameDir.Z) / speed >= SAME_DIR_DOT
        and vlen({ X = v.X - c.vel.X, Y = v.Y - c.vel.Y, Z = v.Z - c.vel.Z }) > 50 then
        c.actor:SetVelocity(uevrUtils.vector(c.vel.X, c.vel.Y, c.vel.Z))
        log("the game re-applied its own velocity - ours put back")
    end
end

uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
    local pawn = _G.bl4 ~= nil and _G.bl4.getPlayerCharacter() or nil
    if pawn == nil then
        readied, pending = false, nil
        return
    end
    local now = ordnanceReadied(pawn)
    if now ~= readied then log(now and "ordnance readied" or "ordnance out of the hand") end
    readied = now

    if pending ~= nil then
        local ok, err = pcall(function()
            local actor = findThrownProjectile(pawn)
            if actor ~= nil then
                steer(actor, pending)
                pending = nil
            elseif os.clock() - pending.at > SPAWN_WAIT_S then
                pending = nil
                log("no projectile appeared after the release")
            end
        end)
        if not ok then
            pending = nil
            log(tostring(err))
        end
    end
end)

-- the throw button (RB = right grip). Default priority: after holsters.lua (25), so a grip swallowed for a holster
-- zone is never seen as a throw.
local BTN_RB = 0x0200
local throwButtonDown = false
uevrUtils.registerOnPreInputGetStateCallback(function(retval, user_index, state)
    if user_index ~= 0 or state == nil then return end
    local down = uevrUtils.isButtonPressed(state, BTN_RB)
    if throwButtonDown and not down and readied then
        local ok, err = pcall(onRelease)
        if not ok then log(tostring(err)) end
    end
    throwButtonDown = down
end)

uevr.sdk.callbacks.on_post_engine_tick(function(engine, delta)
    local ok = pcall(holdVelocity)
    if not ok then corrected = nil end
end)

local ranThisTick = false
uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta) ranThisTick = false end)
uevrUtils.registerPostCalculateStereoViewCallback(function(device, view_index, world_to_meters, position, rotation, is_double)
    if ranThisTick then return end
    ranThisTick = true
    if not readied then
        if #samples > 0 then clearSamples() end
        return
    end
    local ok, err = pcall(sampleHand)
    if not ok then log(tostring(err)) end
end)

uevrUtils.registerPreLevelChangeCallback(function(level)
    readied, pending, corrected, handled = false, nil, nil, {}
    clearSamples()
end)

log("loaded")
