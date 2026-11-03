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

## Config: `<profile>\plugins\BL4AimFix.txt` (optional)

`Enabled`, `Mode` (0 log / 1 override), `Debug` (logs every player projectile, plus a summary every 10 s),
`StartTolerance`, `MaxAngleFromAim`, `WeaponClass`, `MuzzleSocket`, `UseSocketRotation`, `BarrelAxis`,
`MuzzleForwardOffset`, `PitchOffset`, `YawOffset`, `RVA_SpawnLightProjectileNative`, `RVA_ManagerSpawn`.

## Build

`_build.bat` (VS 2026, offline FetchContent from the Cronos `_deps`, glm from OW2AimFixProject, UEVR headers from
`D:\UEVR Dev\UEVR-PureDark-AFW-Joey-Merged-updated\include`; these paths point at local folders and need adjusting).
Requires UEVR plugin API 2.39 or newer. Output `build\Release\BL4AimFix.dll` → profile `plugins\`. Fully restart the
game after deploying.
