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
    { widgetType = "checkbox", id = "bl4_thr_carry_enabled", label = "Carried objects (grappled tanks): throw them with a swing", initialValue = true },
    { widgetType = "slider_float", id = "bl4_thr_carry_speed", label = "Carried objects: swing speed that throws them (cm/s)", initialValue = 1000.0, range = {400.0, 2000.0}, speed = 10.0 },
    { widgetType = "slider_float", id = "bl4_thr_carry_gain", label = "Carried objects: throw strength (x swing speed)", initialValue = 3.0, range = {1.0, 6.0}, speed = 0.05 },
    { widgetType = "text", id = "bl4_thr_last", label = "Last throw: -" },
    { widgetType = "checkbox", id = "bl4_ordnance_game_pose", label = "Left hand takes the game's grip for held knives / grenades (Hands and IK mode)", initialValue = true },
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
local lastVel = nil     -- the newest windowed velocity (carried-object swing: has the peak passed?)

local function clearSamples()
    samples, bestVel, lastHand, lastPointing, lastVel = {}, nil, nil, nil, nil
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
    lastVel = v
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

-- The throw direction from the swing (shared by ordnance and carried objects): nil when there is no usable swing.
local function swingThrow(what)
    local v = bestVel
    if configui.getValue("bl4_thr_enabled") == false then return nil end
    if v == nil or lastHand == nil then
        log(string.format("%s without hand samples (%d samples) - game throw", what, #samples))
        return nil
    end
    local handSpeed = vlen(v)
    if handSpeed < cfgNum("bl4_thr_min_swing", 150.0) then
        configui.setLabel("bl4_thr_last", string.format("Last throw: game aim (swing %.0f cm/s too slow)", handSpeed))
        log(string.format("%s: swing %.0f cm/s below the minimum - game throw", what, handSpeed))
        return nil
    end
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
    return { at = os.clock(), dir = dir, hand = { X = lastHand.X, Y = lastHand.Y, Z = lastHand.Z }, handSpeed = handSpeed }
end

-- Called on the RB release (the input edge), not on AttachState 1 -> 0: the game takes the knife out of the hand only
-- when its throw animation ends, 0.3-0.5 s later, when the swing is long over (log 2026-11-05: "swing 14 cm/s").
local function onRelease()
    local p = swingThrow("release")
    if p == nil then return end
    log(string.format("release: swing %.0f cm/s, looking for the projectile", p.handSpeed))
    pending = p
end

-- ---------------------------------------------------------------------------------------------
-- Carried objects (grappled propane / CO2 tanks; bl4_main getCarriedRoot rides them on the VR left hand). The flat game
-- throws them on LT; here the SWING throws them, no button: while carrying, once a forward swing faster than
-- bl4_thr_carry_swing has passed its peak (speed fallen below 75 % of the peak), LT is pressed for the game for
-- CARRY_PRESS_S. The swing is taken at that moment like an ordnance release, and once the game has let go of the
-- object (no longer carried, physics on) its physics velocity is set along the swing at the swing's peak speed x
-- bl4_thr_carry_gain (the game's own launch speed is random in VR), watched for CARRY_REAPPLY_S in case the game re-aims it.
-- ---------------------------------------------------------------------------------------------
local CARRY_PRESS_S = 0.12      -- how long LT is held for the game
local CARRY_COOLDOWN_S = 1.0    -- no second swing throw this soon
local CARRY_FORWARD_DOT = 0.2   -- the swing must go forward (vs the HMD's horizontal forward)
local carrying = nil            -- the carried root on the last tick
local carryPending = nil        -- { at, dir, hand, handSpeed, root }
local carryCorrected = nil      -- { root, vel, at }
local carryPressUntil = 0       -- LT injected until this time
local carryNextAllowed = 0
local carryStartedAt = nil      -- when the current carry began
local CARRY_RELEASE_WAIT_S = 1.5 -- the game lets go ~60 ms after LT; bl4_main then holds the copy until the launch
local CARRY_REAPPLY_S = 0.5     -- watch the launched object this long in case the game re-aims it
local CARRY_MAX_SPEED = 4000.0  -- cm/s cap on swing-strength throws
local carryTrace = nil          -- { root, startT, untilT, nextT }: the launched object's first second (log)
local NO_BONE = nil

local function carriedRoot(pawn)
    if _G.bl4 == nil or _G.bl4.getCarriedRoot == nil then return nil end
    local ok, root = pcall(_G.bl4.getCarriedRoot, pawn)
    return ok and root or nil
end

-- run after each hand sample while carrying: fire the throw just after the swing's peak
local function checkCarrySwing()
    local now = os.clock()
    if carrying == nil or carryPending ~= nil or now < carryNextAllowed or configui.getValue("bl4_thr_enabled") == false
        or configui.getValue("bl4_thr_carry_enabled") == false then return end
    -- the game has already let go (dropped / thrown by hand): no LT press for an object it is launching
    if _G.bl4.isCarryReleasing ~= nil and _G.bl4.isCarryReleasing() then return end
    -- not in the first second of the carry (the grab itself moves the hand)
    if carryStartedAt == nil or now - carryStartedAt < 1.0 then return end
    local best, cur = bestVel, lastVel
    if best == nil or cur == nil or now - best.t > PEAK_WINDOW_S then return end
    local peak = vlen(best)
    -- 250 cm/s fired on ordinary arm movement (530-720 cm/s, 2026-11-09): default 1000, a real throw
    if peak < cfgNum("bl4_thr_carry_speed", 1000.0) or vlen(cur) > peak * 0.75 then return end
    local head = controllers.getHMDController()
    if not alive(head) then return end
    local f = kismet_math_library:GetForwardVector(head:K2_GetComponentRotation())
    local fh = math.sqrt(f.X * f.X + f.Y * f.Y)
    if fh < 0.001 or (best.X * f.X + best.Y * f.Y) / (fh * peak) < CARRY_FORWARD_DOT then return end
    local p = swingThrow("carry swing")
    if p == nil then return end
    p.root = carrying
    -- the game throws the spawned carryable that owns the first-person copy (bl4_main getCarriedThrowRoot)
    pcall(function() p.throwRoot = _G.bl4.getCarriedThrowRoot ~= nil and _G.bl4.getCarriedThrowRoot() or nil end)
    carryPending = p
    carryPressUntil = now + CARRY_PRESS_S
    carryNextAllowed = now + CARRY_COOLDOWN_S
    log(string.format("carry swing %.0f cm/s: pressing LT for the game", p.handSpeed))
end

-- The game launches the thrown object from its first-person copy, which bl4_main keeps on the VR hand until the launch
-- (the copy left at the world origin is what made tanks fall out of the world, 2026-11-09). Each candidate whose physics
-- is running is put just ahead of the VR hand and launched along the swing; the log names each one and how far from
-- the hand the game launched it.
-- carryable actors the game spawned just now (the carried one is the same actor, moved to the persistent level)
local CARRYABLE_CLASS = "Class /Script/OakGame.CarryableObject"
local function freshCarryables(p)
    local out = {}
    for _, actor in ipairs(uevrUtils.getAllActorsOfClass(CARRYABLE_CLASS) or {}) do
        pcall(function()
            if actor ~= nil and actor:GetGameTimeSinceCreation() <= os.clock() - p.at + 0.1 then
                local root = uevrUtils.getValid(actor.RootComponent)
                if root ~= nil then table.insert(out, root) end
            end
        end)
    end
    return out
end

local function steerCarried(p)
    if NO_BONE == nil then NO_BONE = uevrUtils.fname_from_string("None") end
    local candidates = {}
    local seen = {}
    local function add(name, root)
        if alive(root) and not seen[root:get_address()] then
            seen[root:get_address()] = true
            table.insert(candidates, { name = name, root = root })
        end
    end
    local fresh = freshCarryables(p)
    for i, root in ipairs(fresh) do add("new" .. i, root) end
    add("spawned", p.throwRoot)
    add("carried", p.root)
    if #candidates == 0 then return true end
    if not p.loggedFresh then
        p.loggedFresh = true
        log(string.format("carry release: %d new carryable(s) since the swing", #fresh))
    end
    local hand = p.hand
    pcall(function()
        local h = controllers.getController(Handed.Left, true):K2_GetComponentLocation()
        if h ~= nil then hand = { X = h.X, Y = h.Y, Z = h.Z } end
    end)
    local d = p.dir
    local steered = false
    p.done = p.done or {}
    local remaining = 0
    for _, c in ipairs(candidates) do
        local root = c.root
        local gv = root:GetPhysicsLinearVelocity(NO_BONE)
        local gameSpeed = gv ~= nil and vlen(gv) or 0
        if p.done[c.name] then
            -- already launched
        elseif gameSpeed < 50 then
            remaining = remaining + 1 -- not released yet: next tick
        else -- physics running = released by the game
            p.done[c.name] = true
            local before = root:K2_GetComponentLocation()
            -- the swing sets the speed: the game's own launch speed is no measure in VR (92 .. 2605 cm/s over 9 throws
            -- with similar swings, never pushed again later; log 2026-11-09)
            local speed = math.min(p.handSpeed * cfgNum("bl4_thr_carry_gain", 3.0), CARRY_MAX_SPEED)
            local vel = { X = d.X * speed, Y = d.Y * speed, Z = d.Z * speed }
            -- no move: the game launches it from its copy, which bl4_main holds in the VR hand (a teleport of the
            -- simulating root never stuck anyway, 2026-11-09)
            root:SetPhysicsLinearVelocity(uevrUtils.vector(vel.X, vel.Y, vel.Z), false, NO_BONE)
            if carryCorrected == nil or not steered then carryCorrected = { root = root, vel = vel, dir = d, at = os.clock() } end
            if c.name:sub(1, 3) == "new" or carryTrace == nil then
                carryTrace = { root = root, startT = os.clock(), untilT = os.clock() + 1.0, nextT = 0 }
            end
            steered = true
            configui.setLabel("bl4_thr_last", string.format("Last throw: carried object, swing %.0f cm/s -> %.0f cm/s", p.handSpeed, speed))
            local fromHand = math.sqrt((before.X - hand.X) ^ 2 + (before.Y - hand.Y) ^ 2 + (before.Z - hand.Z) ^ 2)
            log(string.format("carried object thrown (%s %s, launched %.0f cm from the VR hand): swing -> release %.0f ms, game %.0f cm/s -> dir (%.2f %.2f %.2f) %.0f cm/s",
                c.name, root:get_full_name(), fromHand, (os.clock() - p.at) * 1000, gameSpeed, d.X, d.Y, d.Z, speed))
        end
    end
    -- done once nothing is left waiting (the caller also gives up after CARRY_RELEASE_WAIT_S)
    return remaining == 0
end

-- diagnostics: where the launched object goes during the first second (does the move to the hand stick?)
local function traceCarried()
    local t = carryTrace
    if t == nil then return end
    local now = os.clock()
    if now > t.untilT or not alive(t.root) then
        log(alive(t.root) and "carry trace end" or "carry trace: object gone")
        carryTrace = nil
        return
    end
    if now < t.nextT then return end
    t.nextT = now + 0.1
    local p = t.root:K2_GetComponentLocation()
    local v = t.root:GetPhysicsLinearVelocity(NO_BONE)
    local parent = t.root.AttachParent
    local fromHand = -1
    pcall(function()
        local h = controllers.getController(Handed.Left, true):K2_GetComponentLocation()
        fromHand = math.sqrt((p.X - h.X) ^ 2 + (p.Y - h.Y) ^ 2 + (p.Z - h.Z) ^ 2)
    end)
    log(string.format("carry trace +%.0f ms: %.0f cm from the VR hand (z %.0f), vel %.0f cm/s, parent %s, visible %s",
        (now - t.startT) * 1000, fromHand, p.Z, v ~= nil and vlen(v) or -1,
        parent ~= nil and parent:get_fname():to_string() or "none", tostring(t.root.bVisible)))
end

local function holdCarriedVelocity()
    local c = carryCorrected
    if c == nil then return end
    if os.clock() - c.at > CARRY_REAPPLY_S or not alive(c.root) then carryCorrected = nil return end
    local v = c.root:GetPhysicsLinearVelocity(NO_BONE)
    if v == nil then carryCorrected = nil return end
    local speed, want = vlen(v), vlen(c.vel)
    if speed < 1 or want < 1 then carryCorrected = nil return end
    -- the HEADING more than ~10 deg off ours while still flying fast = the game pushed it again; slower = it hit
    -- something. Heading only: gravity and damping never turn it, but the full 3D angle crossed 10 deg after ~0.35 s of
    -- normal fall and the put-back flattened every throw (log 2026-11-09, 1834 -> 2031 cm/s at +370 ms)
    local h, wh = math.sqrt(v.X * v.X + v.Y * v.Y), math.sqrt(c.vel.X * c.vel.X + c.vel.Y * c.vel.Y)
    local dot = (h > 1 and wh > 1) and (v.X * c.vel.X + v.Y * c.vel.Y) / (h * wh) or 1
    if dot < 0.985 and h > 300 and h > wh * 0.6 then
        c.root:SetPhysicsLinearVelocity(uevrUtils.vector(c.vel.X, c.vel.Y, c.vel.Z), false, NO_BONE)
        log("the game re-applied its own carried-object velocity - ours put back")
    end
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

    -- carried object: once the game has let go after our LT press, steer it
    local wasCarrying = carrying
    carrying = carriedRoot(pawn)
    if carrying == nil then carryStartedAt = nil
    elseif wasCarrying == nil or wasCarrying:get_address() ~= carrying:get_address() then carryStartedAt = os.clock() end
    -- (a drop or a throw by hand needs nothing here: the game launches it from the copy, which bl4_main holds on the VR hand)
    if carryPending ~= nil then
        if carrying ~= nil and carrying:get_address() == carryPending.root:get_address() then
            if os.clock() - carryPending.at > CARRY_RELEASE_WAIT_S then
                carryPending = nil
                log("the game never launched the carried object after the LT press")
            end
        else
            local ok, done = pcall(steerCarried, carryPending)
            if not ok then
                log(tostring(done))
                carryPending = nil
            elseif done or os.clock() - carryPending.at > CARRY_RELEASE_WAIT_S then
                carryPending = nil
            end
        end
    end

    if pending ~= nil then
        local ok, err = pcall(function()
            -- a projectile found on its spawn tick has no velocity yet (steer returns false): the same one is retried
            -- each tick (2026-11-09: a knife found that way was dropped silently and flew the game's head aim)
            local actor = alive(pending.actor) and pending.actor or findThrownProjectile(pawn)
            if actor ~= nil and steer(actor, pending) then
                pending = nil
            elseif actor ~= nil then
                pending.actor = actor
                if os.clock() - pending.at > SPAWN_WAIT_S then
                    pending = nil
                    log("the thrown projectile never started moving - game throw")
                end
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
    -- carried object: the swing presses LT (the flat game's throw) for the game
    if os.clock() < carryPressUntil then state.Gamepad.bLeftTrigger = 255 end
end)

uevr.sdk.callbacks.on_post_engine_tick(function(engine, delta)
    local ok = pcall(holdVelocity)
    if not ok then corrected = nil end
    ok = pcall(holdCarriedVelocity)
    if not ok then carryCorrected = nil end
    local tok, terr = pcall(traceCarried)
    if not tok then
        log("carry trace failed: " .. tostring(terr))
        carryTrace = nil
    end
end)

local ranThisTick = false
uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta) ranThisTick = false end)
uevrUtils.registerPostCalculateStereoViewCallback(function(device, view_index, world_to_meters, position, rotation, is_double)
    if ranThisTick then return end
    ranThisTick = true
    if not readied and carrying == nil then
        if #samples > 0 then clearSamples() end
        return
    end
    local ok, err = pcall(sampleHand)
    if not ok then log(tostring(err)) end
    if carrying ~= nil then
        ok, err = pcall(checkCarrySwing)
        if not ok then log(tostring(err)) end
    end
end)

uevrUtils.registerPreLevelChangeCallback(function(level)
    readied, pending, corrected, handled = false, nil, nil, {}
    carrying, carryPending, carryCorrected, carryPressUntil = nil, nil, nil, 0
    clearSamples()
end)

log("loaded")
