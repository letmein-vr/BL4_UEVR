#pragma once

#include <windows.h>

#include <atomic>
#include <filesystem>
#include <memory>
#include <string>

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
    void on_pre_engine_tick(uevr::API::UGameEngine* engine, float delta) override;

    struct Config {
        bool enabled{true};
        int mode{1};                         // 0 = log only, 1 = override
        bool debug{true};                    // first builds: log every player projectile (turn off once confirmed)
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
    bool capture_context(uevr::API::UObject* weapon, ShotContext& ctx);
    uevr::API::UObject* resolve_weak(const uint8_t* weak) const;
    bool is_weapon(uevr::API::UObject* obj);
    uevr::API::UObject* first_person_mesh(uevr::API::UObject* weapon);
    uevr::API::UObject* m_mesh_cache_weapon{};
    uevr::API::UObject* m_mesh_cache{};
    int32_t m_mesh_cache_index{-1};
    int32_t m_mesh_cache_serial{0};

    using ManagerSpawnFn = uintptr_t (*)(void* manager, void* out_handle, const uint8_t* data);
    static uintptr_t on_manager_spawn(void* manager, void* out_handle, const uint8_t* data);
    inline static ManagerSpawnFn m_orig_spawn{};

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
