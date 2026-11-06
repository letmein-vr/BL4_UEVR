# BL4AimFix: UEVR weapon aim plugin for Borderlands 4 (UE 5.5.4)

Makes the player's shots leave the barrel of the motion-controller-held gun and fly along it, instead of starting at
the camera and following the head. Built from the HellraiserAimFix template (same hook pattern; this game ships no PDB).

## How the game fires (2026-10-30)

Weapon fire is native: the firing behaviours (`WeaponBehavior_FireProjectile` / `_OakFire` / `_Fire`) have no
UFunctions, and bullets are "light projectiles" spawned by
`ALightProjectileManager::SpawnProjectile(mgr, FHandle* out, const FLightProjectileSpawnData&)`.
`FLightProjectileSpawnData` (reflection, size 0x1C8): Location +0x20, Direction +0x38, EndLocation +0x50, Flags +0x68,
weak Instigator +0x6C, Source +0x74, DamageCauser +0x80.

With the gun on the VR hand the game spawns the shot at the first-person gun's muzzle and points it from there at the
crosshair target, so the direction is up to ~10° off camera forward: that is parallax, not spread.

## What the plugin hooks

| Function | RVA |
|---|---|
| `LightProjectileStatics.SpawnLightProjectile` native (thunk 0x130DDE0) | 0x130E0A2 |
| `ALightProjectileManager::SpawnProjectile` | 0x842D26 |

The chain is verified with bddisasm before hooking: SpawnLightProjectile native → tail jump to the static spawn helper
→ call to the manager spawn (six direct callers). RVAs are config overridable.

Gate: only projectiles whose instigator is the local pawn (or its controller) and whose causer / source is a
`GbxWeapon.Weapon`, spawned within `StartTolerance` (120 cm) of the camera or 30 cm of the muzzle, and within
`MaxAngleFromAim` (30°) of the aim.
Override: the plugin passes an edited shallow copy of the spawn data - Location = the `Muzzle` socket of the weapon's
first-person mesh (the owner-only `bOnlyOwnerSee` skeletal mesh, not the RootComponent, which is the third-person gun),
Direction = the barrel (socket forward) with the game's spread kept, EndLocation re-projected along it. Spread is
measured against muzzle → camera-ray point at the shot's EndLocation distance, so the parallax above is not mistaken
for spread. Other projectiles are left alone.

## Beam weapons (2026-11-05)

Beams (`WeaponBehavior_FireBeam` → GbxGame `LightBeam`) never reach the projectile spawn. They aim from
`PlayerCameraManager.CameraModeState.POV`, which the camera computes in the player controller's tick and which follows
the body, not UEVR's aim. While the local pawn owns an active beam, the plugin writes the VR gun's muzzle + barrel
into that POV at the end of the controller tick. It restores the real POV at the start of the LightBeamManager tick,
with backstops at pre-draw, pre-stereo, post-engine-tick and the next controller tick. The camera cache copies written
in between are corrected on restore. All tick hooks are found from class default objects and verified against
`ExecuteTick`.

## Scoped sights keep the gun visible (2026-11-05)

High-magnification scopes have `WeaponBehaviorDef_Sight.bHideWeapon` set: fully zoomed, the game stops drawing the
first-person gun natively. In VR the gun is on the hand, so it just vanished. Each `WeaponBehavior_Sight` in the held
gun's `behaviors` points at its definition from +0x38 (not reflected). The plugin checks that the definition's
`BehaviorClass` asset name equals the behavior's class name, then clears the flag with an SEH-guarded write. The
offsets come from reflection. The scope mask mesh and vignette are hidden by `scripts/bl4_vr_scope.lua`.

## Grapple hand aim (2026-11-05)

BL4 scores grapple targets against the camera's cached view (`PlayerCameraManager.CameraCachePrivate.POV`). GbxAudio
places its listener from that same view, so writing the hand's aim there for the whole frame made the sound follow the
right hand. The plugin now holds the hand aim in the cached view only while the `GrappleTargetingStrategy` updates:
its one virtual of its own (vtable slot 84, +0x2A0) is found from the live `OakPlayerController.GrappleTargetingStrategy`
object and inline-hooked, and the real view is restored straight after the call. The aim is the gun's barrel, or with no
gun out the right controller aim sent by `scripts/bl4_vr_grapple.lua`. The script sends custom events: `bl4.grapple_hand_aim`
as an on/off heartbeat every 2 s, and `bl4.grapple_aim` (pitch / yaw) at 20 Hz only while no gun is out.

## Vehicle guns aimed with the head (2026-11-06)

`OakVehicleWeapon` is an `OakWeapon`, so vehicle shots reach the same light-projectile spawn hook. While the local
pawn is an `OakVehicle`, the hand-gun barrel path is skipped. Instead the shot keeps the game's muzzle and spread (measured
against the game's no-spread direction, the same as for the hand gun) and points at the spot on the gaze ray that is as
far from the eyes as the game's own target. The gaze is the midpoint and rotation of UEVR's final eye poses
(`on_post_calculate_stereo_view_offset`). Steering is untouched, because the chase camera still follows the right stick.
UEVR's HUD follows the head (`UI_FollowView`), so the crosshair sits on the gaze. `scripts/bl4_vr_vehicle.lua` sends the
panel option as custom event `bl4.vehicle_gaze_aim` (`1` / `0`) on change and every 10 s.

## Config: `<profile>\plugins\BL4AimFix.txt` (optional)

`Enabled`, `Mode` (0 log / 1 override), `Debug` (logs every player projectile, plus a summary every 10 s),
`StartTolerance`, `MaxAngleFromAim`, `WeaponClass`, `MuzzleSocket`, `UseSocketRotation`, `BarrelAxis`,
`MuzzleForwardOffset`, `PitchOffset`, `YawOffset`, `RVA_SpawnLightProjectileNative`, `RVA_ManagerSpawn`,
`BeamAim` (default 1), `ShowWeaponWhenScoped` (default 1), `VehicleGazeAim` (default 1).

## Build

`_build.bat` (VS 2026, offline FetchContent from the Cronos `_deps`, glm from OW2AimFixProject, UEVR headers from
`D:\UEVR Dev\UEVR-PureDark-AFW-Joey-Merged-updated\include`; these paths point at local folders and need adjusting).
Requires UEVR plugin API 2.39 or newer. Output `build\Release\BL4AimFix.dll` → profile `plugins\`. Fully restart the
game after deploying.
