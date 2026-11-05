# Borderlands 4 – UEVR VR Profile

A full motion-controller VR conversion of Borderlands 4 for UEVR, with visible hands or IK arms, guns that shoot where you point them, two-handed aiming, weapon recoil from the game's own animations, body holsters, a hand-aimed grapple and a stable, comfortable camera. Special thanks to praydog, jbusfield (for his libs framework), and joeyhodge!

![Borderlands 4 VR](screenshots/borderlands4vr.png)

## IMPORTANT!

- My custom UEVR backend is required - see the releases on [letmein-vr/UEVR](https://github.com/letmein-vr/UEVR/releases) to download it. It carries the Borderlands 4 fixes this profile depends on: visible first-person arms and guns in stereo, working console variables, flicker-free menus, a usable map and inventory preview, and a working Ghosting Fix.
- Inject UEVR at the main menu.

## Features

### Hands and body

- **Two hand modes.** Pick **Hands** (glove hands cut from the game's own first-person arms) or **IK Arms** (full arms from your shoulders to the controllers, elbows solved in between). Switch live from the top of the Borderlands 4 panel.
- **Per-weapon hand poses.** The hands wrap around each weapon type with separate grip and trigger poses.
- **Game arms hidden.** The game's own first-person arms are hidden while your VR hands or arms hold the gun, so there is only ever one pair of hands.

### Weapons and combat

- **Weapon in hand.** The equipped weapon sits in your right hand (or on the IK hand) and aims where you point it, with per-weapon position and rotation offsets. Bullets leave the barrel of the gun you see thanks to a small native plugin (BL4AimFix.dll, source in `source/BL4AimFix`), which hooks the game's projectile spawn.
- **Beam weapons aim too.** Beam guns (e.g. Maliwan beam SMGs) follow your hand as well: the plugin hands the game's beam aim the barrel of the gun you hold.
- **Game grip.** Weapons sit in your hand the way the game holds them, measured from the game's own arms, so new weapons need no per-weapon tuning (per-weapon offsets are still available).
- **Weapon animations kept.** Each first-person gun keeps its own animation, so slides, magazines and reloads still animate while it rides your hand.
- **Weapon recoil.** Every shot kicks the gun in your hand, taken from the game's own firing animation, so each weapon kicks the way it does in the flat game - back into your hand with muzzle flip, then recovering. Works in Hands and IK modes and while two-handing; distance and rotation strength are adjustable.
- **Two-handed aiming.** Bring your left hand to the gun's fore-grip and hold the left grip (or left trigger); the gun then pivots between both hands. The left hand glides on and off the gun and holds the weapon's left-hand grip pose. In IK mode the whole left arm is solved onto the fore-grip.
- **Dynamic reticule.** A weapon reticule at the barrel's aim point.
- **PiP scopes.** Guns with a magnifying scope get a picture-in-picture scope while you aim down sights (left trigger). Every weapon variant works it out from its own parts: the lens sits at that scope's eyepiece, the picture uses the scope's in-game magnification and is centred where your shots go. Scope-less variants of the same gun get none. The lens position can be fine-tuned per scope model.
- **Clean ADS.** Aiming down sights no longer puts the game's flat-screen scope mask (a black square with a peephole) in front of your face, and scoped guns stay visible instead of vanishing.
- **Thrown ordnance.** Grenades and throwing knives are held in your left hand and thrown with a real throwing motion.
- **Body holsters.** Press the right grip with your hand at a body spot to switch weapons: right hip, right shoulder, left shoulder, left hip (weapon slots 1-4). A short pulse tells you when your hand is in a holster zone.

### Movement

- **Hand-aimed grapple.** The grapple targets where your right hand (the gun's barrel, or the controller with no gun out) points, not where your head looks.
- **Head-directed movement.** Push forward and you walk where you're looking; the right stick still turns you.

### Camera and comfort

- **Steady camera.** Camera shakes (melee, shooting, hits), camera animations and the melee view sway are disabled.
- **Level view.** The game's hidden pitch is kept level, which stops recoil and full-auto fire from swinging the view or turning your character.
- **Decoupled pitch.** Looking up and down does not tilt the game camera; right stick up/down is ignored on foot with head aim.

## Controls

| Action | Input |
|---|---|
| Move | Left stick, relative to where you look |
| Turn | Right stick |
| Aim / fire | Point the right controller, right trigger |
| Aim down sights / PiP scope | Left trigger |
| Two-hand a gun | Bring the left hand to the fore-grip, hold left grip |
| Switch weapon | Right grip at right hip / right shoulder / left shoulder / left hip |
| Grapple | Point the right hand at the grapple point |

## Installation

1. Install my custom UEVR (see above).
2. Import this profile in UEVR (or copy the files into `%APPDATA%\UnrealVRMod\Borderlands4`).
3. Start the game and inject UEVR at the main menu.

## Tuning

Everything is adjustable in the **Borderlands 4** panel in the UEVR overlay, without editing files. The top of the panel has the everyday switches (weapon on hand, camera options, hand mode, two-handing, recoil, grapple); each feature has its own section below:

- **Attachments** – per-weapon position, rotation and two-handed flag.
- **Hands / IK Arms** – rig setup and offsets.
- **Two-Handed Aiming** – grab button, grab and release radius, glide time, fore-grip point per weapon, IK arm stretch.
- **Recoil** – kick strength, recovery tail, motion limits, kick while two-handing.
- **Holsters** – on / off, haptic pulse, zone size and each zone's position, with a live readout of your hand's position.
- **Grapple** – hand aim on / off.
- **PiP Scope** – on / off, minimum magnification that counts as a scope, lens offset for the scope you're holding (saved per scope model), lens size, magnification trim and brightness.
- **General → Gun and hands at world depth** – on by default (needed for PiP scopes). Off restores the game's foreground drawing, which keeps the gun from poking into walls.

## Under the hood

Built on jbusfield's shared uevrlib Lua framework, running on my UEVR backend. Game-specific logic lives in small scripts on top of the framework: the weapon and hands bootstrap and camera handling (`bl4_main.lua`), the hands / IK mode switch (`bl4_vr_ik.lua`), two-handed aiming, recoil, holsters and the grapple aim.

Scopes: each sight part adds a sight behaviour with the game's zoom, and a scope part maps the gun's generic `ScopeSocket` to its own socket, so a PiP is built from the parts actually fitted (`bl4_vr_pip_scope.lua`, on jbusfield's `scope.lua`). The eyepiece comes from the scope's own mask mesh, or from the scope parts' bounds when it has none. The game's flat scope mask and vignette are hidden by `bl4_vr_scope.lua`, and BL4AimFix.dll clears the sight definition's "hide weapon when zoomed" flag. The picture only sorts correctly against the gun at real depth, so by default the gun, its parts and the VR hands / IK arms are moved out of the game's foreground layer.

Borderlands 4 draws the first-person arms and gun in its own foreground pass with a separate projection that the game only fills in its flat-screen path; the backend fills it from the VR projection, which is what makes the arms and gun visible in stereo. BL4 also has no player-side "equip weapon slot" function, so the holsters press the game's own number keys through `plugins/luakey.dll`, with a primer key first so the game accepts keyboard input while you're on a controller.

The native plugin (BL4AimFix.dll) hooks the game's light-projectile spawn: player shots start at the muzzle of the first-person gun you see and fly along its barrel. Its source is in `source/BL4AimFix` (build paths in its CMakeLists.txt point at local folders and need adjusting).
