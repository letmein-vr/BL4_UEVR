#pragma once

#include <windows.h>

#include <atomic>
#include <filesystem>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "uevr/API.hpp"
// uevr_plugin_required_version (exported by uevr/Plugin.hpp) reports the header's minor version, and UEVR unloads
// plugins that ask for a newer minor than it has. The merged headers are 2.41 (owned FName, controller input tail),
// official UEVR is 2.39, and this plugin uses nothing newer than 2.39 - so ask for 2.39.
#undef UEVR_PLUGIN_VERSION_MINOR
#define UEVR_PLUGIN_VERSION_MINOR 39
#include "uevr/Plugin.hpp"

// UE5 FVector / FRotator (doubles)
struct Vec3 { double x{}, y{}, z{}; };
struct Rot3 { double pitch{}, yaw{}, roll{}; };

class BL4AimFixPlugin;
extern std::unique_ptr<BL4AimFixPlugin> g_plugin;

// Weapon aim fix for Borderlands 4 (UE 5.5.4, no PDB) under UEVR: shots leave the VR gun's muzzle along its barrel.
//
// How the game shoots (2026-10-30): weapon fire is native (WeaponBehavior_FireProjectile, no UFunctions). Every
// bullet is a "light projectile" created by ALightProjectileManager::SpawnProjectile(this, FHandle* out,
// const FLightProjectileSpawnData& data) - the same function the Blueprint helper
// ULightProjectileStatics::SpawnLightProjectile ends in. The spawn data carries Location (+0x20), Direction (+0x38),
// EndLocation (+0x50) and weak pointers to the instigator (+0x6C), Source (+0x74) and DamageCauser (+0x80).
//
// Override: a projectile whose instigator is the local pawn and which starts near the camera (within
// StartTolerance) or at the first-person muzzle, pointing within MaxAngleFromAim of the game's aim line, is spawned
// from the muzzle instead, its direction rotated by aim line -> barrel so the game's own spread survives. The aim
// line runs from the spawn point to the crosshair target on the camera ray (not camera forward: with the gun on the
// VR hand the game fires from the muzzle at that target, and the parallax is not spread). The caller's spawn data is not
// modified; the hook passes an edited copy. Mode=0 only logs.
class BL4AimFixPlugin : public uevr::Plugin {
public:
    BL4AimFixPlugin() = default;
    virtual ~BL4AimFixPlugin() = default;

    void on_initialize() override;
    void on_custom_event(const char* event_name, const char* event_data) override;
    void on_pre_engine_tick(uevr::API::UGameEngine* engine, float delta) override;
    void on_post_engine_tick(uevr::API::UGameEngine* engine, float delta) override;
    void on_pre_viewport_client_draw(UEVR_UGameViewportClientHandle viewport_client, UEVR_FViewportHandle viewport,
                                     UEVR_FCanvasHandle canvas) override;
    void on_pre_calculate_stereo_view_offset(UEVR_StereoRenderingDeviceHandle device, int view_index, float world_to_meters,
                                             UEVR_Vector3f* position, UEVR_Rotatorf* rotation, bool is_double) override;
    void on_post_calculate_stereo_view_offset(UEVR_StereoRenderingDeviceHandle device, int view_index, float world_to_meters,
                                              UEVR_Vector3f* position, UEVR_Rotatorf* rotation, bool is_double) override;

    struct Config {
        bool enabled{true};
        int mode{1};                         // 0 = log only, 1 = override
        bool debug{false};                   // per-shot / per-10 s diagnostics; Debug=1 in plugins/BL4AimFix.txt turns them on
        double start_tolerance{120.0};       // cm: spawn must be this close to the camera to be redirected
        double max_angle_from_aim{30.0};     // deg: and point within this of camera forward
        std::wstring weapon_class{L"Class /Script/GbxWeapon.Weapon"};
        std::wstring muzzle_socket{L"Muzzle"};
        bool use_socket_rotation{true};      // barrel = socket forward (X); else barrel_axis of the mesh
        std::wstring barrel_axis{L"+X"};
        double muzzle_forward_offset{0.0};
        double pitch_offset_deg{0.0};        // + = aim up
        double yaw_offset_deg{0.0};          // + = aim right
        // RVAs (module base relative), exe 2026-10-30. The chain is verified before hooking:
        // SpawnLightProjectile thunk -> native -> tail jump to the static spawn helper -> call to the manager spawn.
        uintptr_t rva_spawn_light_projectile_native{0x130E0A2};
        uintptr_t rva_manager_spawn{0x842D26};
        int axis_index{0};
        double axis_sign{1.0};
        // Beam weapons (WeaponBehavior_FireBeam -> GbxGame LightBeam): beams aim from the camera mode's POV
        // (CameraModeState.POV), which follows the body, not UEVR's aim. While the beam manager ticks, the POV holds
        // the VR gun's muzzle + barrel (restored right after, so the view never sees it). BeamAim=0 turns this off.
        bool beam_aim{true};
        // Scoped sights (WeaponBehaviorDef_Sight.bHideWeapon) hide the first-person gun when fully zoomed; in VR the
        // gun is on the hand and must stay. Clears the flag in the held gun's sight definitions (shared game data,
        // stays cleared until the game restarts). ShowWeaponWhenScoped=0 turns this off.
        bool show_weapon_when_scoped{true};
        // Vehicle guns aimed with the head (gaze): shots from the local vehicle pawn's weapons keep the game's muzzle
        // and spread but point along the HMD gaze instead of the chase camera. VehicleGazeAim=0 turns this off; the
        // panel option (scripts/bl4_vr_vehicle.lua, custom event "bl4.vehicle_gaze_aim") switches it at runtime.
        bool vehicle_gaze_aim{true};
    };

private:
    struct ShotContext {
        bool valid{false};
        uevr::API::UObject* weapon{};
        Vec3 muzzle{};
        Vec3 barrel{};
        Vec3 cam_loc{};
        Vec3 cam_fwd{};
    };

    void load_config(const std::filesystem::path& file);
    void install_hooks();
    void update_scope_weapon_hide();
    // grapple hand aim (scripts/bl4_vr_grapple.lua sends it every frame as custom event "bl4.grapple_aim")
    Rot3 m_grapple_rot{};
    double m_grapple_time{-1.0};
    uint32_t m_grapple_writes{0};
    bool m_grapple_enabled{false};
    double m_grapple_heartbeat{-100.0};
    bool m_grapple_hooked{false};
    bool m_grapple_hook_failed{false};
    void install_grapple_hook();
public:
    uintptr_t on_grapple_update(void* self, uintptr_t a2, uintptr_t a3, uintptr_t a4);
private:
    uevr::API::UObject* m_scope_weapon{};
    double m_scope_next_check{0.0};
    uevr::API::UClass* m_sight_class{};
    int32_t m_sight_hide_offset{-1};      // WeaponBehaviorDef_Sight.bHideWeapon (reflection); -2 = not found
    int32_t m_sight_class_name_offset{-1}; // WeaponBehaviorDef.BehaviorClass AssetName FName (reflection + 16)
    uint32_t m_sight_defs_cleared{0};
    bool capture_context(uevr::API::UObject* weapon, ShotContext& ctx);
    uevr::API::UObject* resolve_weak(const uint8_t* weak) const;
    bool is_weapon(uevr::API::UObject* obj);
    uevr::API::UObject* first_person_mesh(uevr::API::UObject* weapon);
    uevr::API::UObject* m_mesh_cache_weapon{};
    uevr::API::UObject* m_mesh_cache{};
    int32_t m_mesh_cache_index{-1};
    int32_t m_mesh_cache_serial{0};

    // ---- vehicle gaze aim ----
    // final eye poses from UEVR's stereo views (world, after the HMD is applied); the gaze = their midpoint + rotation
    Vec3 m_eye_loc[2]{};
    Rot3 m_eye_rot{};
    double m_eye_time[2]{-100.0, -100.0};
    bool m_vehicle_gaze_enabled{true};       // runtime switch (panel); the config value gates it too
    uevr::API::UClass* m_vehicle_class{};
    uint32_t m_vehicle_overrides{0};
    bool is_vehicle_pawn(uevr::API::UObject* pawn);
    // returns true and fills `edited` when the shot was re-aimed along the gaze
    bool gaze_aim_vehicle_shot(const uint8_t* data, uint8_t* edited);

    using ManagerSpawnFn = uintptr_t (*)(void* manager, void* out_handle, const uint8_t* data);
    static uintptr_t on_manager_spawn(void* manager, void* out_handle, const uint8_t* data);
    inline static ManagerSpawnFn m_orig_spawn{};

    // ---- beam aim: tick wrappers (beam manager, held weapon, player character, player controller) ----
    // Each wrapper can hold the camera-mode POV on the gun while the original runs (restored after) and records whether
    // an active beam's end point changed during the call - to find where the game aims its beams.
    enum TickRole { ROLE_MANAGER = 0, ROLE_WEAPON, ROLE_PAWN, ROLE_CONTROLLER, ROLE_CAMERA, ROLE_COUNT };
    static constexpr int MAX_TICK_HOOKS = 5;
    using TickFn = void (*)(void* actor, float delta, uintptr_t a3, uintptr_t a4);
    template <int I> static void tick_detour(void* actor, float delta, uintptr_t a3, uintptr_t a4) {
        g_plugin->tick_wrapper(I, actor, delta, a3, a4);
    }
    void tick_wrapper(int slot, void* actor, float delta, uintptr_t a3, uintptr_t a4);
    void install_beam_hook();
    void update_gun_pose();
    void poll_beam_flags();
    double beam_target_sum() const;
    inline static TickFn m_tick_orig[MAX_TICK_HOOKS]{};
    uintptr_t m_tick_fn[MAX_TICK_HOOKS]{};
    bool m_slot_roles[MAX_TICK_HOOKS][ROLE_COUNT]{};
    int m_tick_hooks{0};
    bool m_beam_hooked{false};
    void* m_manager{nullptr};
    void* m_held_weapon{nullptr};
    void* m_local_pawn_ptr{nullptr};
    void* m_local_pc_ptr{nullptr};
    bool m_swap_role[ROLE_COUNT]{false, false, false, false, false}; // POV swap per tick (diagnostic; plugins/BL4AimFix_beam.txt UPPERCASE M W P C)
    bool m_restore_role[ROLE_COUNT]{true, false, false, false, false}; // end the gun-pose hold at the start of these ticks (lowercase)
    int m_hold_start_role{ROLE_CONTROLLER}; // start the gun-pose hold at the end of this tick (">" + letter)
    void* m_local_cm_ptr{nullptr};
    uint32_t m_role_pov_restores[ROLE_COUNT]{};
    void aim_player_beams();
    uint32_t m_beams_aimed{0};
    // frame-long POV hold: gun pose in CameraModeState.POV from the start of the frame until the camera update
    bool player_beam_active() const;
    void restore_pov();
    void install_camera_hook();
    using UpdateCameraFn = void (*)(void* camera_manager, float delta);
    static void on_update_camera(void* camera_manager, float delta);
    inline static UpdateCameraFn m_orig_update_camera{};
    bool m_camera_hooked{false};
    bool m_pov_held{false};
    uint8_t* m_pov_held_ptr{nullptr}; // the POV written by the hold (restored there even if m_pov changed)
    // camera manager view caches (CameraCachePrivate / LastFrameCameraCachePrivate .POV location + rotation, 48 bytes):
    // snapshot at hold start, undone at hold end if something copied the held POV into them
    uint8_t* m_cache_pov[2]{};
    uint8_t* m_cache_held_ptr[2]{};
    uint8_t m_cache_saved[2][48]{};
    uint32_t m_cache_touched{0};
    Vec3 m_pov_hold_gun_loc{}; // the gun pose written by the current hold
    Rot3 m_pov_hold_gun_rot{};
    Vec3 m_pov_saved_loc{};
    Rot3 m_pov_saved_rot{};
    uint32_t m_pov_holds{0};
    uint32_t m_pov_restored_by_camera{0};
    // APlayerCameraManager::ProcessViewRotation, which UEVR's HMD aim hooks (base + HMD, then recenter): during the
    // hold it must see the real view rotation, not the gun's
    void install_pvr_hook();
    using ProcessViewRotationFn = void (*)(void* pcm, float delta, Rot3* rot, Rot3* delta_rot);
    static void on_process_view_rotation(void* pcm, float delta, Rot3* rot, Rot3* delta_rot);
    inline static ProcessViewRotationFn m_orig_pvr{};
    bool m_pvr_hooked{false};
    uintptr_t m_pvr_target{0};
    uint8_t m_pvr_seen_bytes[5]{};
    double m_pvr_stable_since{0.0};
    uint32_t m_pvr_calls{0};
    uint32_t m_pvr_calls_held{0};
    uint32_t m_pvr_fixed{0};
    Rot3 m_pvr_last_in{};
    double m_last_flags_poll{0.0};
    uint32_t m_role_calls[ROLE_COUNT]{};
    uint32_t m_role_swaps[ROLE_COUNT]{};
    uint32_t m_role_target_changed[ROLE_COUNT]{};
    uint32_t m_frames_target_changed{0};
    double m_last_frame_target_sum{0.0};
    // game thread only (pre engine tick writes, the ticks on the game thread read)
    bool m_gun_valid{false};
    Vec3 m_gun_muzzle{};
    Rot3 m_gun_rot{};
    uint8_t* m_pov{nullptr}; // CameraModeState.POV (FMinimalViewInfo-like: Location, Rotation)
    uint32_t m_beam_off_thread{0};

    Config m_cfg{};
    bool m_hooks_ok{false};
    uevr::API::UClass* m_weapon_class{};
    std::atomic<DWORD> m_game_thread{0};

    double m_last_debug_log{0.0};
    uint32_t m_player_spawns{0};
    uint32_t m_overrides{0};
    uint32_t m_kept_far{0};
    uint32_t m_kept_angle{0};
    uint32_t m_no_weapon{0};
    uint32_t m_no_muzzle{0};
    uint32_t m_off_thread{0};
    uint32_t m_socket_missing{0};
};
