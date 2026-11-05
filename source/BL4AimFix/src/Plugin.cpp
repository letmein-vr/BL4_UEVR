#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <string>

#include <utility/Module.hpp>
#include <utility/Scan.hpp>

#include <bddisasm.h>

#include "Plugin.hpp"

using namespace uevr;

std::unique_ptr<BL4AimFixPlugin> g_plugin = std::make_unique<BL4AimFixPlugin>();

namespace {

// FLightProjectileSpawnData (reflection, 2026-10-30): size 0x1C8
constexpr size_t SPAWN_DATA_SIZE = 0x1C8;
constexpr size_t SD_LOCATION = 0x20;
constexpr size_t SD_DIRECTION = 0x38;
constexpr size_t SD_END_LOCATION = 0x50;
constexpr size_t SD_INSTIGATOR = 0x6C;
constexpr size_t SD_SOURCE = 0x74;
constexpr size_t SD_DAMAGE_CAUSER = 0x80;

constexpr double MUZZLE_START_TOLERANCE = 30.0; // cm: a spawn this close to the first-person muzzle is a gun shot

double now_seconds() {
    using clock = std::chrono::steady_clock;
    static const auto t0 = clock::now();
    return std::chrono::duration<double>(clock::now() - t0).count();
}

double deg2rad(double d) { return d * 3.14159265358979323846 / 180.0; }
double dot(const Vec3& a, const Vec3& b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
double length(const Vec3& v) { return std::sqrt(dot(v, v)); }
Vec3 sub(const Vec3& a, const Vec3& b) { return Vec3{a.x - b.x, a.y - b.y, a.z - b.z}; }
Vec3 add_scaled(const Vec3& a, const Vec3& d, double s) { return Vec3{a.x + d.x * s, a.y + d.y * s, a.z + d.z * s}; }

Vec3 normalize(const Vec3& v) {
    const double len = length(v);
    if (len < 1e-9) return Vec3{1.0, 0.0, 0.0};
    return Vec3{v.x / len, v.y / len, v.z / len};
}

Vec3 cross(const Vec3& a, const Vec3& b) {
    return Vec3{a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x};
}

// Rodrigues rotation of v around unit axis k by angle (radians)
Vec3 rotate_axis(const Vec3& v, const Vec3& k, double angle) {
    const double c = std::cos(angle), s = std::sin(angle);
    const Vec3 kxv = cross(k, v);
    const double kdv = dot(k, v);
    return Vec3{
        v.x * c + kxv.x * s + k.x * kdv * (1.0 - c),
        v.y * c + kxv.y * s + k.y * kdv * (1.0 - c),
        v.z * c + kxv.z * s + k.z * kdv * (1.0 - c),
    };
}

// Rotate v by the rotation that takes unit vector `from` onto unit vector `to`.
Vec3 rotate_from_to(const Vec3& v, const Vec3& from, const Vec3& to) {
    const Vec3 axis = cross(from, to);
    const double s = length(axis);
    const double c = std::clamp(dot(from, to), -1.0, 1.0);
    if (s < 1e-9) return c > 0.0 ? v : Vec3{-v.x, -v.y, -v.z};
    return rotate_axis(v, Vec3{axis.x / s, axis.y / s, axis.z / s}, std::atan2(s, c));
}

Vec3 rotator_forward(const Rot3& r) {
    const double p = deg2rad(r.pitch), y = deg2rad(r.yaw);
    const double cp = std::cos(p);
    return Vec3{cp * std::cos(y), cp * std::sin(y), std::sin(p)};
}

bool near_zero(const Vec3& v) {
    return std::fabs(v.x) + std::fabs(v.y) + std::fabs(v.z) < 1.0;
}

std::string trim(std::string s) {
    const auto b = s.find_first_not_of(" \t\r\n");
    if (b == std::string::npos) return {};
    const auto e = s.find_last_not_of(" \t\r\n");
    return s.substr(b, e - b + 1);
}

std::string narrow(const std::wstring& w) {
    std::string out;
    out.reserve(w.size());
    for (auto c : w) out.push_back(c < 128 ? (char)c : '?');
    return out;
}

// Null-checked object property read (API::UObject::get_property dereferences blindly).
API::UObject* get_object_prop(API::UObject* obj, std::wstring_view name) {
    if (obj == nullptr) return nullptr;
    auto data = obj->get_property_data<API::UObject*>(name);
    return data != nullptr ? *data : nullptr;
}

std::wstring object_name(API::UObject* obj) {
    if (obj == nullptr) return L"<null>";
    auto fname = obj->get_fname();
    return fname != nullptr ? fname->to_string() : L"<?>";
}

bool decode(uintptr_t ip, INSTRUX& ix) {
    return ND_SUCCESS(NdDecodeEx(&ix, (const ND_UINT8*)ip, ND_MAX_INSTRUCTION_LENGTH, ND_CODE_64, ND_DATA_64));
}

uintptr_t rel_target(uintptr_t ip, const INSTRUX& ix) {
    return ip + ix.Length + (intptr_t)(int32_t)ix.RelativeOffset;
}

// True if the function contains a direct call (E8) to `target` before its first RET.
bool calls_before_ret(uintptr_t fn, uintptr_t target) {
    for (uintptr_t ip = fn, end = fn + 0x1000; ip < end;) {
        INSTRUX ix{};
        if (!decode(ip, ix)) return false;
        if (ix.Instruction == ND_INS_CALLNR && rel_target(ip, ix) == target) return true;
        if (ix.Instruction == ND_INS_RETN) return false;
        ip += ix.Length;
    }
    return false;
}

// First direct JMP (tail call) in the function before its first RET.
uintptr_t first_tail_jump(uintptr_t fn) {
    for (uintptr_t ip = fn, end = fn + 0x400; ip < end;) {
        INSTRUX ix{};
        if (!decode(ip, ix)) return 0;
        if (ix.Instruction == ND_INS_JMPNR && ix.Length == 5) return rel_target(ip, ix);
        if (ix.Instruction == ND_INS_RETN) return 0;
        ip += ix.Length;
    }
    return 0;
}

// Last direct call before the first RET.
uintptr_t last_call_before_ret(uintptr_t fn) {
    uintptr_t last = 0;
    for (uintptr_t ip = fn, end = fn + 0x400; ip < end;) {
        INSTRUX ix{};
        if (!decode(ip, ix)) return 0;
        if (ix.Instruction == ND_INS_CALLNR) last = rel_target(ip, ix);
        if (ix.Instruction == ND_INS_RETN) return last;
        ip += ix.Length;
    }
    return 0;
}

bool install_inline_hook(uintptr_t target, void* dest, void** orig, const char* name) {
    void* original = nullptr;
    const auto id = API::get()->param()->functions->register_inline_hook((void*)target, dest, &original);
    if (id < 0 || original == nullptr) {
        API::get()->log_error("BL4AimFix: inline hook failed for %s at 0x%p", name, (void*)target);
        return false;
    }
    *orig = original;
    API::get()->log_info("BL4AimFix: hooked %s at 0x%p (RVA 0x%llX, hook id %d)", name, (void*)target,
        (unsigned long long)(target - (uintptr_t)utility::get_executable()), id);
    return true;
}

// The engine-registered native thunk of Class::Function, or 0.
uintptr_t ufunction_thunk(const wchar_t* class_name, const wchar_t* fn_name) {
    if (auto klass = API::get()->find_uobject<API::UClass>(class_name); klass != nullptr) {
        if (auto fn = klass->find_function(fn_name); fn != nullptr && fn->get_native_function() != nullptr) {
            return (uintptr_t)fn->get_native_function();
        }
    }
    return 0;
}

void parse_axis(BL4AimFixPlugin::Config& c) {
    const auto& axis = c.barrel_axis;
    c.axis_sign = (!axis.empty() && axis[0] == L'-') ? -1.0 : 1.0;
    const wchar_t letter = axis.empty() ? L'X' : (wchar_t)towupper(axis.back());
    c.axis_index = letter == L'Y' ? 1 : (letter == L'Z' ? 2 : 0);
}

// The direction the game aimed this shot before spread. The game aims from its camera at the crosshair target and
// fires from wherever the first-person gun's muzzle is; with the gun on the VR hand that muzzle is far from the
// camera, so the shot points from the muzzle at the target and sits several degrees off camera forward (parallax,
// ~10 deg at 1 m offset / 6 m target, 2026-10-30). Treating that as spread put it back onto the barrel: shots
// landed up/left of the gun's aim. Reference = muzzle -> the camera-ray point as far away as the shot's EndLocation
// (the game's trace hit), so only real spread is measured.
Vec3 aim_reference(const Vec3& loc, const Vec3& end, bool has_end, const Vec3& cam_loc, const Vec3& cam_fwd) {
    if (!has_end) return cam_fwd;
    const double reach = length(sub(end, loc));
    const Vec3 w = sub(cam_loc, loc);
    const double b = dot(cam_fwd, w);
    const double disc = b * b - (dot(w, w) - reach * reach);
    if (disc < 0.0) return cam_fwd;
    const double s = -b + std::sqrt(disc);
    if (s <= 0.0) return cam_fwd;
    return normalize(sub(add_scaled(cam_loc, cam_fwd, s), loc));
}

Vec3 read_vec(const uint8_t* p) { Vec3 v{}; std::memcpy(&v, p, sizeof(v)); return v; }
void write_vec(uint8_t* p, const Vec3& v) { std::memcpy(p, &v, sizeof(v)); }

} // namespace

// ------------------------------------------------------------------------------------------------

void BL4AimFixPlugin::on_initialize() {
    API::get()->log_info("BL4AimFix: on_initialize");
    load_config(API::get()->get_persistent_dir() / "plugins" / "BL4AimFix.txt");
    parse_axis(m_cfg);

    API::get()->log_info("BL4AimFix: config enabled=%d mode=%d debug=%d startTol=%.0f maxAngle=%.0f socket=%s socketRot=%d axis=%s fwdOff=%.1f pitch=%.2f yaw=%.2f",
        (int)m_cfg.enabled, m_cfg.mode, (int)m_cfg.debug, m_cfg.start_tolerance, m_cfg.max_angle_from_aim,
        narrow(m_cfg.muzzle_socket).c_str(), (int)m_cfg.use_socket_rotation, narrow(m_cfg.barrel_axis).c_str(),
        m_cfg.muzzle_forward_offset, m_cfg.pitch_offset_deg, m_cfg.yaw_offset_deg);

    if (!m_cfg.enabled) {
        API::get()->log_info("BL4AimFix: disabled by config");
        return;
    }
    install_hooks();
}

void BL4AimFixPlugin::install_hooks() {
    const auto base = (uintptr_t)utility::get_executable();

    const auto thunk = ufunction_thunk(L"Class /Script/GbxGame.LightProjectileStatics", L"SpawnLightProjectile");
    if (thunk == 0) {
        API::get()->log_error("BL4AimFix: LightProjectileStatics.SpawnLightProjectile not found - not hooking");
        return;
    }

    // thunk -> ULightProjectileStatics::SpawnLightProjectile(data)
    const auto native = base + m_cfg.rva_spawn_light_projectile_native;
    if (!calls_before_ret(thunk, native)) {
        API::get()->log_error("BL4AimFix: SpawnLightProjectile thunk (RVA 0x%llX) does not call the native at RVA 0x%llX - game build changed? Not hooking",
            (unsigned long long)(thunk - base), (unsigned long long)m_cfg.rva_spawn_light_projectile_native);
        return;
    }

    // native -> tail jump to the static helper (world -> LightProjectileManager -> SpawnProjectile)
    const auto helper = first_tail_jump(native);
    if (helper == 0) {
        API::get()->log_error("BL4AimFix: no tail jump in the SpawnLightProjectile native - not hooking");
        return;
    }

    auto spawn = base + m_cfg.rva_manager_spawn;
    if (!calls_before_ret(helper, spawn)) {
        const auto decoded = last_call_before_ret(helper);
        if (decoded == 0) {
            API::get()->log_error("BL4AimFix: manager spawn not found in the helper at RVA 0x%llX - not hooking",
                (unsigned long long)(helper - base));
            return;
        }
        API::get()->log_info("BL4AimFix: manager spawn not at configured RVA 0x%llX; decoded RVA 0x%llX from the helper",
            (unsigned long long)m_cfg.rva_manager_spawn, (unsigned long long)(decoded - base));
        spawn = decoded;
    }

    m_hooks_ok = install_inline_hook(spawn, (void*)&on_manager_spawn, (void**)&m_orig_spawn, "LightProjectileManager::SpawnProjectile");
    API::get()->log_info("BL4AimFix: hooks %s", m_hooks_ok ? "installed" : "NOT installed");
}

// ------------------------------------------------------------------------------------------------

API::UObject* BL4AimFixPlugin::resolve_weak(const uint8_t* weak) const {
    int32_t index{}, serial{};
    std::memcpy(&index, weak, sizeof(index));
    std::memcpy(&serial, weak + 4, sizeof(serial));
    if (index < 0 || serial == 0) return nullptr;
    auto array = API::FUObjectArray::get();
    if (array == nullptr || index >= array->get_object_count()) return nullptr;
    auto item = array->get_item(index);
    if (item == nullptr || item->serial_number != serial) return nullptr;
    return item->object;
}

bool BL4AimFixPlugin::is_weapon(API::UObject* obj) {
    if (obj == nullptr) return false;
    if (m_weapon_class == nullptr) m_weapon_class = API::get()->find_uobject<API::UClass>(m_cfg.weapon_class);
    return m_weapon_class != nullptr && obj->is_a(m_weapon_class);
}

// The weapon's first-person mesh. The RootComponent is the third-person mesh on the body's CharacterMesh; the gun the
// player sees is a second skeletal mesh (owner-only, bGbxForeground) on FirstPersonArms R_Hand_Weapon. Cached per
// weapon. Game thread only.
API::UObject* BL4AimFixPlugin::first_person_mesh(API::UObject* weapon) {
    // the cached mesh is reused only while its object-array slot still holds it (same serial)
    if (weapon == m_mesh_cache_weapon && m_mesh_cache != nullptr) {
        auto array = API::FUObjectArray::get();
        auto item = array != nullptr ? array->get_item(m_mesh_cache_index) : nullptr;
        if (item != nullptr && item->object == m_mesh_cache && item->serial_number == m_mesh_cache_serial &&
            m_mesh_cache->get_outer() == weapon) {
            return m_mesh_cache;
        }
    }
    m_mesh_cache_weapon = nullptr;
    m_mesh_cache = nullptr;

    static auto s_skeletal_class = API::get()->find_uobject<API::UClass>(L"Class /Script/Engine.SkeletalMeshComponent");
    auto root = get_object_prop(weapon, L"RootComponent");
    API::UObject* chosen = nullptr;
    if (s_skeletal_class != nullptr) {
        struct { API::UClass* cls; API::TArray<API::UObject*> ret; } p{};
        p.cls = s_skeletal_class;
        weapon->call_function(L"K2_GetComponentsByClass", &p);
        for (auto c : p.ret) {
            if (c == nullptr || c == root) continue;
            if (chosen == nullptr || c->get_bool_property(L"bOnlyOwnerSee")) chosen = c;
        }
    }
    if (chosen == nullptr) chosen = root;

    if (chosen != nullptr) {
        // UObjectBase::InternalIndex (+0xC)
        int32_t index{};
        std::memcpy(&index, (const uint8_t*)chosen + 0xC, sizeof(index));
        auto array = API::FUObjectArray::get();
        auto item = array != nullptr && index >= 0 ? array->get_item(index) : nullptr;
        if (item != nullptr && item->object == chosen) {
            m_mesh_cache_weapon = weapon;
            m_mesh_cache = chosen;
            m_mesh_cache_index = index;
            m_mesh_cache_serial = item->serial_number;
        }
        if (m_cfg.debug) {
            API::get()->log_info("BL4AimFix: weapon %ls -> muzzle mesh %ls%s", object_name(weapon).c_str(),
                object_name(chosen).c_str(), chosen == root ? " (root, no first-person mesh found)" : "");
        }
    }
    return chosen;
}

// Muzzle and barrel of the weapon's first-person mesh (the gun the player sees) + the camera the game aimed from.
// Game thread only (calls UFunctions).
bool BL4AimFixPlugin::capture_context(API::UObject* weapon, ShotContext& ctx) {
    auto mesh = first_person_mesh(weapon);
    if (mesh == nullptr) { ++m_no_muzzle; return false; }
    ctx.weapon = weapon;

    struct { Vec3 ret; } loc{}, fwd{}, right{}, up{};
    mesh->call_function(L"K2_GetComponentLocation", &loc);
    if (near_zero(loc.ret)) { ++m_no_muzzle; return false; }

    static API::FName s_socket{m_cfg.muzzle_socket};
    struct { API::FName name; bool ret; } exists{};
    exists.name = s_socket;
    mesh->call_function(L"DoesSocketExist", &exists);

    Vec3 dir{};
    Vec3 origin = loc.ret;
    if (exists.ret) {
        struct { API::FName name; Vec3 ret; } sl{};
        sl.name = s_socket;
        mesh->call_function(L"GetSocketLocation", &sl);
        origin = sl.ret;
        if (m_cfg.use_socket_rotation) {
            struct { API::FName name; Rot3 ret; } sr{};
            sr.name = s_socket;
            mesh->call_function(L"GetSocketRotation", &sr);
            dir = rotator_forward(sr.ret);
        }
    } else {
        ++m_socket_missing;
    }

    if (near_zero(Vec3{dir.x * 10.0, dir.y * 10.0, dir.z * 10.0})) {
        mesh->call_function(L"GetForwardVector", &fwd);
        mesh->call_function(L"GetRightVector", &right);
        mesh->call_function(L"GetUpVector", &up);
        const Vec3 axes[3]{normalize(fwd.ret), normalize(right.ret), normalize(up.ret)};
        const Vec3 a = axes[m_cfg.axis_index];
        dir = Vec3{a.x * m_cfg.axis_sign, a.y * m_cfg.axis_sign, a.z * m_cfg.axis_sign};
    }

    if (m_cfg.yaw_offset_deg != 0.0) dir = rotate_axis(dir, Vec3{0, 0, 1}, deg2rad(m_cfg.yaw_offset_deg));
    if (m_cfg.pitch_offset_deg != 0.0) {
        const Vec3 r = normalize(cross(Vec3{0, 0, 1}, dir));
        dir = rotate_axis(dir, r, -deg2rad(m_cfg.pitch_offset_deg));
    }
    ctx.barrel = normalize(dir);
    ctx.muzzle = add_scaled(origin, ctx.barrel, m_cfg.muzzle_forward_offset);

    auto pc = API::get()->get_player_controller(0);
    auto cm = get_object_prop(pc, L"PlayerCameraManager");
    if (cm == nullptr) return false;
    struct { Vec3 ret; } cl{};
    struct { Rot3 ret; } cr{};
    cm->call_function(L"GetCameraLocation", &cl);
    cm->call_function(L"GetCameraRotation", &cr);
    ctx.cam_loc = cl.ret;
    ctx.cam_fwd = normalize(rotator_forward(cr.ret));
    ctx.valid = true;
    return true;
}

uintptr_t BL4AimFixPlugin::on_manager_spawn(void* manager, void* out_handle, const uint8_t* data) {
    auto& self = *g_plugin;
    if (data == nullptr || !self.m_hooks_ok) return m_orig_spawn(manager, out_handle, data);

    auto pawn = API::get()->get_local_pawn(0);
    const auto instigator = self.resolve_weak(data + SD_INSTIGATOR);
    if (pawn == nullptr || instigator == nullptr ||
        (instigator != pawn && instigator != API::get()->get_player_controller(0)))
    {
        return m_orig_spawn(manager, out_handle, data);
    }
    ++self.m_player_spawns;

    // only bullets fired by a weapon: the damage causer (or the source) is the gun
    auto weapon = self.resolve_weak(data + SD_DAMAGE_CAUSER);
    if (!self.is_weapon(weapon)) weapon = self.resolve_weak(data + SD_SOURCE);
    if (!self.is_weapon(weapon)) {
        ++self.m_no_weapon;
        if (self.m_cfg.debug) {
            auto causer = self.resolve_weak(data + SD_DAMAGE_CAUSER);
            auto source = self.resolve_weak(data + SD_SOURCE);
            API::get()->log_info("BL4AimFix[spawn]: player projectile not from a weapon (causer=%ls source=%ls) - kept",
                object_name(causer).c_str(), object_name(source).c_str());
        }
        return m_orig_spawn(manager, out_handle, data);
    }

    // UFunction calls are only safe on the game thread
    if (self.m_game_thread.load() != 0 && GetCurrentThreadId() != self.m_game_thread.load()) {
        ++self.m_off_thread;
        return m_orig_spawn(manager, out_handle, data);
    }

    ShotContext ctx{};
    if (!self.capture_context(weapon, ctx)) {
        return m_orig_spawn(manager, out_handle, data);
    }

    const Vec3 loc0 = read_vec(data + SD_LOCATION);
    const Vec3 dir0 = read_vec(data + SD_DIRECTION);
    const Vec3 end0 = read_vec(data + SD_END_LOCATION);
    const Vec3 dir = normalize(dir0);
    const double from_cam = length(sub(loc0, ctx.cam_loc));
    const double from_muzzle = length(sub(loc0, ctx.muzzle));
    const bool has_end = !near_zero(end0);
    const Vec3 ref = aim_reference(loc0, end0, has_end, ctx.cam_loc, ctx.cam_fwd);
    const double aim_dot = dot(dir, ref);
    const bool near_aim = aim_dot >= std::cos(deg2rad(self.m_cfg.max_angle_from_aim));
    // the game spawns at the camera (gun in front of it) or at the first-person muzzle (gun on the VR hand)
    const bool from_camera = from_cam <= self.m_cfg.start_tolerance || from_muzzle <= MUZZLE_START_TOLERANCE;

    alignas(16) uint8_t edited[SPAWN_DATA_SIZE];
    const uint8_t* pass = data;
    bool overridden = false;
    Vec3 new_dir{};

    if (near_aim && from_camera) {
        new_dir = normalize(rotate_from_to(dir, ref, ctx.barrel));
        if (self.m_cfg.mode == 1 && API::VR::is_hmd_active()) {
            // shallow copy: the engine reads the spawn data through a const&, the caller keeps ownership
            std::memcpy(edited, data, SPAWN_DATA_SIZE);
            write_vec(edited + SD_LOCATION, ctx.muzzle);
            write_vec(edited + SD_DIRECTION, Vec3{new_dir.x * length(dir0), new_dir.y * length(dir0), new_dir.z * length(dir0)});
            if (has_end) {
                const double reach = length(sub(end0, loc0));
                write_vec(edited + SD_END_LOCATION, add_scaled(ctx.muzzle, new_dir, reach));
            }
            pass = edited;
            overridden = true;
            ++self.m_overrides;
        }
    } else if (!near_aim) {
        ++self.m_kept_angle;
    } else {
        ++self.m_kept_far;
    }

    if (self.m_cfg.debug) {
        API::get()->log_info("BL4AimFix[spawn]: weapon=%ls loc=(%.0f %.0f %.0f) fromCam=%.1f fromMuzzle=%.1f dir=(%.3f %.3f %.3f) |dir|=%.3f dot(dir,camFwd)=%.4f spread=%.2fdeg end=%s(%.0f %.0f %.0f) muzzle=(%.0f %.0f %.0f) muzzleFromCam=%.1f barrel=(%.3f %.3f %.3f) dot(barrel,camFwd)=%.3f %s",
            object_name(weapon).c_str(), loc0.x, loc0.y, loc0.z, from_cam, from_muzzle, dir.x, dir.y, dir.z, length(dir0),
            dot(dir, ctx.cam_fwd), std::acos(std::clamp(aim_dot, -1.0, 1.0)) * 180.0 / 3.14159265358979323846,
            has_end ? "" : "none ", end0.x, end0.y, end0.z, ctx.muzzle.x, ctx.muzzle.y, ctx.muzzle.z,
            length(sub(ctx.muzzle, ctx.cam_loc)), ctx.barrel.x, ctx.barrel.y, ctx.barrel.z, dot(ctx.barrel, ctx.cam_fwd),
            overridden ? "OVERRIDDEN" : (!near_aim ? "kept (not along the aim)" :
                (!from_camera ? "kept (not from camera)" : "kept (mode 0 / no HMD)")));
    }

    return m_orig_spawn(manager, out_handle, pass);
}

// ------------------------------------------------------------------------------------------------

// ------------------------------------------------------------------------------------------------
// Scoped sights: keep the gun visible (MCP 2026-11-05).
// Scoped guns carry WeaponBehavior_Sight entries in OakWeapon.behaviors. A sight's definition
// (WeaponBehaviorDef_Sight, heap data owned by the Nexus inventory aspect, e.g. inv_aspect-sight_5_5x.behavior) has
// bHideWeapon = 1 on high-magnification scopes: fully zoomed, the game stops drawing the first-person gun (natively;
// no reflected property changes). The flat game frames the scope with the mask mesh then; in VR the gun is on the hand
// and simply vanished. The behavior points at its definition from +0x38 (not reflected; the definition starts with a
// vtable, then BehaviorClass = FSoftClassPtr {weak ptr, package FName, asset FName}). Before writing, the definition's
// BehaviorClass asset name must equal the behavior's own class name. Clearing the flag on the live definition was
// confirmed by xaero 2026-11-05 (gun stays visible in ADS). The scope mask mesh / vignette are hidden by
// scripts/bl4_vr_scope.lua.

namespace {
constexpr size_t SIGHT_DEF_PTR_OFFSET = 0x38;

bool seh_read_u64(const void* p, uint64_t& out) {
    __try {
        out = *(const volatile uint64_t*)p;
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}

// 1 -> 0 only (a plain bool); returns true when it changed the byte
bool seh_clear_bool(uint8_t* p) {
    __try {
        if (*(volatile uint8_t*)p != 1) return false;
        *(volatile uint8_t*)p = 0;
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
}
} // namespace

void BL4AimFixPlugin::update_scope_weapon_hide() {
    if (!m_cfg.show_weapon_when_scoped || m_sight_hide_offset == -2) return;
    auto pawn = API::get()->get_local_pawn(0);
    if (pawn == nullptr) return;
    static auto s_statics_class = API::get()->find_uobject<API::UClass>(L"Class /Script/GbxWeapon.WeaponStatics");
    auto statics = s_statics_class != nullptr ? s_statics_class->get_class_default_object() : nullptr;
    if (statics == nullptr) return;
    struct { API::UObject* user; uint8_t slot; API::UObject* ret; } gw{};
    gw.user = pawn;
    gw.slot = 0;
    statics->call_function(L"GetWeapon", &gw);
    auto weapon = gw.ret;
    if (weapon == nullptr) return;
    // once per weapon change, plus a slow recheck (part swaps, new definitions)
    const double t = now_seconds();
    if (weapon == m_scope_weapon && t < m_scope_next_check) return;
    m_scope_weapon = weapon;
    m_scope_next_check = t + 2.0;

    if (m_sight_hide_offset == -1) {
        auto def = API::get()->find_uobject<API::UStruct>(L"ScriptStruct /Script/OakGame.WeaponBehaviorDef_Sight");
        auto hide = def != nullptr ? def->find_property(L"bHideWeapon") : nullptr;
        auto cls = def != nullptr ? def->find_property(L"BehaviorClass") : nullptr;
        m_sight_class = API::get()->find_uobject<API::UClass>(L"Class /Script/OakGame.WeaponBehavior_Sight");
        if (hide == nullptr || cls == nullptr || m_sight_class == nullptr) {
            m_sight_hide_offset = -2;
            API::get()->log_info("BL4AimFix[scope]: WeaponBehaviorDef_Sight.bHideWeapon / BehaviorClass or WeaponBehavior_Sight not found, scoped weapon hide left alone");
            return;
        }
        m_sight_hide_offset = hide->get_offset();
        m_sight_class_name_offset = cls->get_offset() + 16; // FSoftObjectPtr: weak ptr (8), package FName (8), asset FName
        API::get()->log_info("BL4AimFix[scope]: bHideWeapon +0x%X, BehaviorClass asset name +0x%X", m_sight_hide_offset, m_sight_class_name_offset);
    }

    auto behaviors = weapon->get_property_data<API::TArray<API::UObject*>>(L"behaviors");
    if (behaviors == nullptr) return;
    for (auto b : *behaviors) {
        if (b == nullptr || !b->is_a(m_sight_class)) continue;
        uint64_t def_ptr{};
        if (!seh_read_u64((const uint8_t*)b + SIGHT_DEF_PTR_OFFSET, def_ptr) || def_ptr < 0x10000) continue;
        uint64_t def_class_name{}, own_class_name{};
        if (!seh_read_u64((const uint8_t*)def_ptr + m_sight_class_name_offset, def_class_name)) continue;
        std::memcpy(&own_class_name, (const uint8_t*)b->get_class() + 0x18, sizeof(own_class_name)); // UObjectBase::NamePrivate
        if (def_class_name != own_class_name) {
            if (m_cfg.debug) {
                API::get()->log_info("BL4AimFix[scope]: %ls: +0x38 is not its definition (name %llX != %llX), skipped",
                    object_name(b).c_str(), (unsigned long long)def_class_name, (unsigned long long)own_class_name);
            }
            continue;
        }
        if (seh_clear_bool((uint8_t*)def_ptr + m_sight_hide_offset)) {
            ++m_sight_defs_cleared;
            API::get()->log_info("BL4AimFix[scope]: %ls: bHideWeapon cleared (definition %llX, %u so far)",
                object_name(b).c_str(), (unsigned long long)def_ptr, m_sight_defs_cleared);
        }
    }
}

void BL4AimFixPlugin::on_pre_engine_tick(API::UGameEngine*, float) {
    m_game_thread.store(GetCurrentThreadId());
    update_scope_weapon_hide();
    if (m_cfg.enabled && m_cfg.beam_aim) {
        install_beam_hook();
        update_gun_pose();
        poll_beam_flags();
        // install_camera_hook() / install_pvr_hook(): diagnostics from 2026-11-05, not installed (BL4 never calls
        // UpdateCamera; ProcessViewRotation is never called inside the hold, and that hook would sit on top of UEVR's).
        // between frames: did any beam end point change since the last frame (sanity check for the per-tick counters)
        const double sum = beam_target_sum();
        if (sum != m_last_frame_target_sum) ++m_frames_target_changed;
        m_last_frame_target_sum = sum;
        // the gun pose is held in the POV from the end of the player controller's tick (see tick_wrapper) to the end
        // of the frame; never across a controller tick, where the camera computes the view from it
        restore_pov();
    }
    if (!m_cfg.debug) return;
    const double t = now_seconds();
    if (t - m_last_debug_log < 10.0) return;
    m_last_debug_log = t;
    if (m_hooks_ok) {
        API::get()->log_info("BL4AimFix[sum]: playerSpawns=%u overrides=%u keptNotAlongAim=%u keptNotFromCamera=%u notFromWeapon=%u noMuzzle=%u socketMissing=%u offThread=%u",
            m_player_spawns, m_overrides, m_kept_angle, m_kept_far, m_no_weapon, m_no_muzzle, m_socket_missing, m_off_thread);
    }
    if (m_beam_hooked) {
        static const char* names[ROLE_COUNT]{"manager", "weapon", "pawn", "controller", "camera"};
        std::string s;
        for (int r = 0; r < ROLE_COUNT; ++r) {
            char buf[128];
            std::snprintf(buf, sizeof(buf), " %s(calls=%u swaps=%u beamEndChanged=%u povRestores=%u%s)", names[r], m_role_calls[r],
                m_role_swaps[r], m_role_target_changed[r], m_role_pov_restores[r], m_swap_role[r] ? " swap" : "");
            s += buf;
            m_role_calls[r] = m_role_swaps[r] = m_role_target_changed[r] = m_role_pov_restores[r] = 0;
        }
        API::get()->log_info("BL4AimFix[beam]:%s framesBeamEndChanged=%u povHolds=%u restoredBeforeDraw=%u cacheTouched=%u pvr(hooked=%d calls=%u inHold=%u fixed=%u lastIn=%.1f,%.1f gun=%.1f,%.1f saved=%.1f,%.1f) gun=%s",
            s.c_str(), m_frames_target_changed, m_pov_holds, m_pov_restored_by_camera, m_cache_touched, (int)m_pvr_hooked, m_pvr_calls, m_pvr_calls_held,
            m_pvr_fixed, m_pvr_last_in.pitch, m_pvr_last_in.yaw, m_gun_rot.pitch, m_gun_rot.yaw, m_pov_saved_rot.pitch, m_pov_saved_rot.yaw,
            m_gun_valid ? "yes" : "no");
        m_pvr_calls = m_pvr_calls_held = m_pvr_fixed = m_cache_touched = 0;


        m_frames_target_changed = 0;
        m_beams_aimed = 0;
        m_pov_holds = 0;
        m_pov_restored_by_camera = 0;
    }
}

// The view is built from the camera-mode POV again when the viewport draws (after the world tick, before
// post_engine_tick): holding the gun pose until post_engine_tick spun the view (2026-11-05). Restore before the draw,
// before UEVR's stereo view calculation, and at the end of the frame.
void BL4AimFixPlugin::on_pre_viewport_client_draw(UEVR_UGameViewportClientHandle, UEVR_FViewportHandle, UEVR_FCanvasHandle) {
    if (m_pov_held) ++m_pov_restored_by_camera;
    restore_pov();
}

void BL4AimFixPlugin::on_pre_calculate_stereo_view_offset(UEVR_StereoRenderingDeviceHandle, int, float, UEVR_Vector3f*,
                                                           UEVR_Rotatorf*, bool) {
    restore_pov();
}

void BL4AimFixPlugin::on_post_engine_tick(API::UGameEngine*, float) {
    restore_pov();
}

// APlayerCameraManager::ProcessViewRotation (stock: camera modifiers, then OutViewRotation += OutDeltaRot; RVA 0x4571F6
// 2026-11-05). UEVR's HMD aim hooks it (IXRTrackingSystemHook::process_view_rotation: base + HMD into the output, then
// recenter). BL4 calls it inside the gun-pose hold with a rotation built from the held POV, so HMD aim adopted the gun
// as its base and the view spun (aim method HMD only). Found by the bytes after the 5-byte hook jump (unique), and
// hooked only once UEVR's verified hook has sat unchanged for 5 s (UEVR re-hooks once after analysing; a hook layered
// on its analyser would be torn out with it) - so this one runs first.
void BL4AimFixPlugin::install_pvr_hook() {
    if (m_pvr_hooked) return;
    if (m_pvr_target == 0) {
        static bool s_scanned = false;
        if (s_scanned) return;
        s_scanned = true;
        const auto hit = utility::scan(utility::get_executable(), "0F 29 74 24 30 4C 89 CB 4C 89 C6 48 89 CF 83 B9 88 2D 00 00 00");
        if (!hit) {
            API::get()->log_error("BL4AimFix: ProcessViewRotation not found - beam aim may spin the view with HMD aim");
            return;
        }
        m_pvr_target = *hit - 9;
    }
    const auto p = (const uint8_t*)m_pvr_target;
    const double t = now_seconds();
    if (p[0] != 0xE9) { // UEVR has not hooked it (yet): HMD aim inactive, nothing to protect
        m_pvr_stable_since = 0.0;
        return;
    }
    if (std::memcmp(p, m_pvr_seen_bytes, sizeof(m_pvr_seen_bytes)) != 0 || m_pvr_stable_since == 0.0) {
        std::memcpy(m_pvr_seen_bytes, p, sizeof(m_pvr_seen_bytes));
        m_pvr_stable_since = t;
        return;
    }
    if (t - m_pvr_stable_since < 5.0 || m_pov_held) return;
    m_pvr_hooked = install_inline_hook(m_pvr_target, (void*)&on_process_view_rotation, (void**)&m_orig_pvr,
        "PlayerCameraManager::ProcessViewRotation (over UEVR's HMD aim)");
}

void BL4AimFixPlugin::on_process_view_rotation(void* pcm, float delta, Rot3* rot, Rot3* delta_rot) {
    auto& self = *g_plugin;
    ++self.m_pvr_calls;
    if (self.m_pov_held && rot != nullptr && GetCurrentThreadId() == self.m_game_thread.load()) {
        ++self.m_pvr_calls_held;
        auto near_deg = [](double a, double b) { return std::fabs(std::remainder(a - b, 360.0)) < 2.0; };
        self.m_pvr_last_in = *rot;
        if (near_deg(rot->pitch, self.m_gun_rot.pitch) && near_deg(rot->yaw, self.m_gun_rot.yaw)) {
            // built from the held gun pose: HMD aim gets the real view rotation instead
            *rot = self.m_pov_saved_rot;
            ++self.m_pvr_fixed;
        }
    }
    m_orig_pvr(pcm, delta, rot, delta_rot);
}

void BL4AimFixPlugin::restore_pov() {
    if (!m_pov_held) return;
    m_pov_held = false;
    if (m_pov_held_ptr == nullptr) return;
    std::memcpy(m_pov_held_ptr, &m_pov_saved_loc, sizeof(Vec3));
    std::memcpy(m_pov_held_ptr + sizeof(Vec3), &m_pov_saved_rot, sizeof(Rot3));
    m_pov_held_ptr = nullptr;
    // The camera manager's view caches are rewritten from the camera-mode POV inside the hold (2 of 2 per hold,
    // 2026-11-05): this frame's legit update, made from the gun pose. Keep the update, take the gun out of it:
    // cache = written - gun + real POV (location and rotation), i.e. what it would hold without the hold.
    // (Restoring the hold-start snapshot instead left the view a frame stale and HMD aim still drifted.)
    for (int c = 0; c < 2; ++c) {
        uint8_t* cache = m_cache_held_ptr[c];
        m_cache_held_ptr[c] = nullptr;
        if (cache == nullptr || std::memcmp(cache, m_cache_saved[c], 48) == 0) continue;
        Vec3 loc{};
        Rot3 rot{};
        std::memcpy(&loc, cache, sizeof(Vec3));
        std::memcpy(&rot, cache + sizeof(Vec3), sizeof(Rot3));
        loc.x += m_pov_saved_loc.x - m_pov_hold_gun_loc.x;
        loc.y += m_pov_saved_loc.y - m_pov_hold_gun_loc.y;
        loc.z += m_pov_saved_loc.z - m_pov_hold_gun_loc.z;
        rot.pitch += m_pov_saved_rot.pitch - m_pov_hold_gun_rot.pitch;
        rot.yaw += m_pov_saved_rot.yaw - m_pov_hold_gun_rot.yaw;
        rot.roll += m_pov_saved_rot.roll - m_pov_hold_gun_rot.roll;
        std::memcpy(cache, &loc, sizeof(Vec3));
        std::memcpy(cache + sizeof(Vec3), &rot, sizeof(Rot3));
        ++m_cache_touched;
    }
}

// true while the local pawn owns an active beam (ALightBeamManager.ActiveBeams +0x390, beam instigator +0x188)
bool BL4AimFixPlugin::player_beam_active() const {
    if (m_manager == nullptr || m_local_pawn_ptr == nullptr) return false;
    const auto arr = (const uint8_t*)m_manager + 0x390;
    uint8_t* const* data = nullptr;
    int32_t num = 0;
    std::memcpy(&data, arr, sizeof(data));
    std::memcpy(&num, arr + 8, sizeof(num));
    if (data == nullptr || num <= 0 || num > 64) return false;
    for (int i = 0; i < num; ++i) {
        if (data[i] == nullptr) continue;
        void* instigator = nullptr;
        std::memcpy(&instigator, data[i] + 0xA8 + 0xE0, sizeof(instigator));
        if (instigator == m_local_pawn_ptr) return true;
    }
    return false;
}

// APlayerController::UpdateCameraManager = `if (PlayerCameraManager) PlayerCameraManager->UpdateCamera(dt)`:
// mov rcx,[rcx+448h] (PlayerCameraManager, reflection offset 1096); test; je; mov rax,[rcx]; jmp [rax+disp32]. Unique
// in the exe (2026-11-05, RVA 0x7CA1F76, UpdateCamera = vtable +0x7A8). The slot is read from the found code, and
// UpdateCamera is hooked on the OakPlayerCameraManager class.
void BL4AimFixPlugin::install_camera_hook() {
    if (m_camera_hooked) return;
    static bool s_tried = false;
    if (s_tried) return;
    s_tried = true;
    const auto exe = utility::get_executable();
    const auto hit = utility::scan(exe, "48 8B 89 48 04 00 00 48 85 C9 74 ? 48 8B 01 48 FF A0");
    if (!hit) {
        API::get()->log_error("BL4AimFix: UpdateCameraManager not found - beam aim off");
        return;
    }
    int32_t slot = 0;
    std::memcpy(&slot, (const void*)(*hit + 18), sizeof(slot));
    auto cls = API::get()->find_uobject<API::UClass>(L"Class /Script/OakGame.OakPlayerCameraManager");
    auto cdo = cls != nullptr ? cls->get_class_default_object() : nullptr;
    const auto base = (uintptr_t)exe;
    const auto size = utility::get_module_size(exe).value_or(0);
    const auto vtable = cdo != nullptr ? *(uintptr_t**)cdo : nullptr;
    const auto fn = (vtable != nullptr && slot > 0 && slot < 0x2000) ? vtable[slot / sizeof(void*)] : 0;
    if (fn < base || fn >= base + size) {
        API::get()->log_error("BL4AimFix: UpdateCamera (vtable +0x%X) not in the exe - beam aim off", slot);
        return;
    }
    m_camera_hooked = install_inline_hook(fn, (void*)&on_update_camera, (void**)&m_orig_update_camera,
        "OakPlayerCameraManager::UpdateCamera");
}

void BL4AimFixPlugin::on_update_camera(void* camera_manager, float delta) {
    auto& self = *g_plugin;
    if (self.m_pov_held) {
        self.restore_pov();
        ++self.m_pov_restored_by_camera;
    }
    m_orig_update_camera(camera_manager, delta);
}

// ------------------------------------------------------------------------------------------------
// Beam weapons (exe + MCP 2026-11-05). WeaponBehavior_FireBeam spawns a GbxGame LightBeam with the gun as source, the
// pawn as instigator and no direction or target. The beam end then equals BL4's camera-mode view:
// PlayerCameraManager.CameraModeState.POV.Location + POV.Rotation forward * 4000 (measured: end Z == POV Z to 0.002 cm,
// yaw == POV yaw). That POV follows the body (control rotation), not UEVR's aim, so beams ignored the VR gun.
// Not GetActorEyesViewPoint / GetControlRotation / GetPlayerViewPoint (hooked or measured, no beam use).
// Writing the POV for the whole frame feeds the view (it spun). Holding it on the gun during the beam manager's and the
// held weapon's ticks (restored after) left the view still but did not move the beam: the end point is computed
// elsewhere. The tick wrappers below measure which tick changes it (beamEndChanged per role).

// An actor class's tick virtual at TICK_ACTOR_VTABLE_OFFSET (the LightBeamManager batch tick uses +0x650, AActor::Tick
// is +0x458), verified through a tick function embedded in its default object at tick_function_offset: that
// FTickFunction's ExecuteTick (vtable slot 1) must dispatch through the same offset.
static uintptr_t resolve_tick_actor(const wchar_t* class_name, size_t tick_function_offset, size_t TICK_ACTOR_VTABLE_OFFSET) {
    auto cls = API::get()->find_uobject<API::UClass>(class_name);
    auto cdo = cls != nullptr ? cls->get_class_default_object() : nullptr;
    if (cdo == nullptr) {
        API::get()->log_error("BL4AimFix: %ls / default object not found", class_name);
        return 0;
    }
    const auto exe = utility::get_executable();
    const auto base = (uintptr_t)exe;
    const auto size = utility::get_module_size(exe).value_or(0);
    auto in_exe = [&](uintptr_t p) { return p >= base && p < base + size; };
    const auto vtable = *(uintptr_t**)cdo;
    const auto fn = vtable != nullptr ? vtable[TICK_ACTOR_VTABLE_OFFSET / sizeof(void*)] : 0;
    const auto tick_vtable = *(uintptr_t**)((uint8_t*)cdo + tick_function_offset);
    const auto exec_tick = (tick_vtable != nullptr && in_exe((uintptr_t)tick_vtable)) ? tick_vtable[1] : 0;
    // the stock FActorTickFunction::ExecuteTick reaches the tick after early-out checks (and an early return), so scan
    // a whole function's worth for a load / call / jump through the slot
    bool verified = false;
    for (uintptr_t ip = exec_tick, end = exec_tick + 0x400; exec_tick != 0 && in_exe(exec_tick) && ip < end;) {
        INSTRUX ix{};
        if (!decode(ip, ix)) break;
        const bool through_slot = ix.OperandsCount >= 1 &&
            ((ix.Instruction == ND_INS_MOV && ix.OperandsCount >= 2 && ix.Operands[1].Type == ND_OP_MEM &&
              ix.Operands[1].Info.Memory.HasDisp && ix.Operands[1].Info.Memory.Disp == TICK_ACTOR_VTABLE_OFFSET) ||
             ((ix.Instruction == ND_INS_CALLNI || ix.Instruction == ND_INS_JMPNI) && ix.Operands[0].Type == ND_OP_MEM &&
              ix.Operands[0].Info.Memory.HasDisp && ix.Operands[0].Info.Memory.Disp == TICK_ACTOR_VTABLE_OFFSET));
        if (through_slot) {
            verified = true;
            break;
        }
        if (ix.Instruction == ND_INS_INT3) break; // end of the function's padding
        ip += ix.Length;
    }
    if (!in_exe(fn) || !verified) {
        API::get()->log_error("BL4AimFix: %ls tick not verified (fn RVA 0x%llX, ExecuteTick RVA 0x%llX) - game build changed?",
            class_name, (unsigned long long)(in_exe(fn) ? fn - base : 0), (unsigned long long)(in_exe(exec_tick) ? exec_tick - base : 0));
        return 0;
    }
    return fn;
}

void BL4AimFixPlugin::install_beam_hook() {
    if (m_beam_hooked) return;
    static bool s_tried = false;
    if (s_tried) return;
    s_tried = true; // one attempt
    constexpr size_t MANAGER_BATCH_TICK_OFFSET = 0x408; // FActorTickFunction-like struct in ALightBeamManager
    constexpr size_t PRIMARY_ACTOR_TICK_OFFSET = 0x30;  // AActor::PrimaryActorTick (reflection offset 48)
    struct Want { int role; const wchar_t* cls; size_t tick_fn; size_t slot; };
    const Want wants[ROLE_COUNT]{
        {ROLE_MANAGER, L"Class /Script/GbxGame.LightBeamManager", MANAGER_BATCH_TICK_OFFSET, 0x650},
        {ROLE_WEAPON, L"Class /Script/OakGame.OakWeapon", PRIMARY_ACTOR_TICK_OFFSET, 0x458},
        {ROLE_PAWN, L"Class /Script/OakGame.OakCharacter", PRIMARY_ACTOR_TICK_OFFSET, 0x458},
        {ROLE_CONTROLLER, L"Class /Script/OakGame.OakPlayerController", PRIMARY_ACTOR_TICK_OFFSET, 0x458},
        {ROLE_CAMERA, L"Class /Script/OakGame.OakPlayerCameraManager", PRIMARY_ACTOR_TICK_OFFSET, 0x458},
    };
    static void* const detours[MAX_TICK_HOOKS]{(void*)&tick_detour<0>, (void*)&tick_detour<1>, (void*)&tick_detour<2>, (void*)&tick_detour<3>, (void*)&tick_detour<4>};
    static const char* names[ROLE_COUNT]{"LightBeamManager tick", "OakWeapon::Tick", "OakCharacter::Tick", "OakPlayerController::Tick", "OakPlayerCameraManager::Tick"};
    for (const auto& w : wants) {
        const auto fn = resolve_tick_actor(w.cls, w.tick_fn, w.slot);
        if (fn == 0) continue;
        int slot = -1;
        for (int i = 0; i < m_tick_hooks; ++i) if (m_tick_fn[i] == fn) slot = i; // shared tick function: one hook
        if (slot < 0 && m_tick_hooks < MAX_TICK_HOOKS) {
            const int i = m_tick_hooks;
            if (install_inline_hook(fn, detours[i], (void**)&m_tick_orig[i], names[w.role])) {
                m_tick_fn[i] = fn;
                slot = i;
                ++m_tick_hooks;
            }
        }
        if (slot >= 0) m_slot_roles[slot][w.role] = true;
    }
    m_beam_hooked = m_tick_hooks > 0;
}

// plugins/BL4AimFix_beam.txt (diagnostic): which ticks hold the POV on the gun (letters M W P C; missing file = none). Polled 1/s.
void BL4AimFixPlugin::poll_beam_flags() {
    const double t = now_seconds();
    if (t - m_last_flags_poll < 1.0) return;
    m_last_flags_poll = t;
    const auto file = API::get()->get_persistent_dir() / "plugins" / "BL4AimFix_beam.txt";
    // UPPERCASE letter = swap the POV during that tick (diagnostic); lowercase = end the gun-pose hold at the START of
    // that tick (default: m). Missing file = "m".
    // '>' + letter = start the hold at the END of that tick instead (default: >c).
    bool want[ROLE_COUNT]{false, false, false, false, false};
    bool restore[ROLE_COUNT]{true, false, false, false, false};
    int start = ROLE_CONTROLLER;
    if (std::filesystem::exists(file)) {
        std::ifstream in(file);
        std::string s;
        std::getline(in, s);
        for (auto& r : restore) r = false;
        bool next_is_start = false;
        for (char c : s) {
            if (c == '>') { next_is_start = true; continue; }
            int role = -1;
            switch (toupper((unsigned char)c)) {
            case 'M': role = ROLE_MANAGER; break;
            case 'W': role = ROLE_WEAPON; break;
            case 'P': role = ROLE_PAWN; break;
            case 'C': role = ROLE_CONTROLLER; break;
            default: break;
            }
            if (role < 0) { next_is_start = false; continue; }
            if (next_is_start) start = role;
            else if (isupper((unsigned char)c)) want[role] = true;
            else restore[role] = true;
            next_is_start = false;
        }
    }
    for (int r = 0; r < ROLE_COUNT; ++r) {
        m_swap_role[r] = want[r];
        m_restore_role[r] = restore[r];
    }
    m_hold_start_role = start;
}

// Sum of all active beams' live aim direction (+0x3A0) and end point (+0x488) (ALightBeamManager.ActiveBeams +0x390).
// Not ServerTargetPoint (+0x268): that is a replicated copy, refreshed about once per 10 s while firing. Memory diff
// 2026-11-05 while firing: +0x408 muzzle location, +0x420 the gun's muzzle rotation (with roll), +0x3A0 / +0x4B8 the
// unit aim direction the beam uses (yaw == control yaw, pitch level), +0x488 end = muzzle + direction * ~4000.
// Cheap change detector. Game thread.
double BL4AimFixPlugin::beam_target_sum() const {
    if (m_manager == nullptr) return 0.0;
    const auto arr = (const uint8_t*)m_manager + 0x390;
    API::UObject* const* data = nullptr;
    int32_t num = 0;
    std::memcpy(&data, arr, sizeof(data));
    std::memcpy(&num, arr + 8, sizeof(num));
    if (data == nullptr || num <= 0 || num > 64) return 0.0;
    double sum = 0.0;
    for (int i = 0; i < num; ++i) {
        const auto beam = (const uint8_t*)data[i];
        if (beam == nullptr) continue;
        Vec3 d{}, e{};
        std::memcpy(&d, beam + 0x3A0, sizeof(d));
        std::memcpy(&e, beam + 0x488, sizeof(e));
        sum += d.x * 1000.0 + d.y * 3000.0 + d.z * 7000.0 + e.x * 1.0 + e.y * 3.0 + e.z * 7.0;
    }
    return sum;
}

// Game thread: the held weapon's first-person muzzle + barrel, and the camera-mode POV the beams aim from.
void BL4AimFixPlugin::update_gun_pose() {
    m_gun_valid = false;
    m_pov = nullptr;
    m_held_weapon = nullptr;
    auto pawn = API::get()->get_local_pawn(0);
    auto pc = API::get()->get_player_controller(0);
    m_local_pawn_ptr = pawn;
    m_local_pc_ptr = pc;
    if (pawn == nullptr || !API::VR::is_hmd_active()) return;
    auto cm = get_object_prop(pc, L"PlayerCameraManager");
    m_local_cm_ptr = cm;
    if (cm != nullptr) {
        auto c0 = cm->get_property_data<uint8_t>(L"CameraCachePrivate");
        auto c1 = cm->get_property_data<uint8_t>(L"LastFrameCameraCachePrivate");
        m_cache_pov[0] = c0 != nullptr ? c0 + 16 : nullptr; // FCameraCacheEntry.POV (reflection offset 16)
        m_cache_pov[1] = c1 != nullptr ? c1 + 16 : nullptr;
    }
    auto cms = get_object_prop(cm, L"CameraModeState");
    if (cms == nullptr) return;
    static auto s_statics_class = API::get()->find_uobject<API::UClass>(L"Class /Script/GbxWeapon.WeaponStatics");
    auto statics = s_statics_class != nullptr ? s_statics_class->get_class_default_object() : nullptr;
    if (statics == nullptr) return;
    struct { API::UObject* user; uint8_t slot; API::UObject* ret; } gw{};
    gw.user = pawn;
    gw.slot = 0;
    statics->call_function(L"GetWeapon", &gw);
    ShotContext ctx{};
    if (gw.ret == nullptr || !is_weapon(gw.ret) || !capture_context(gw.ret, ctx)) return;
    m_pov = cms->get_property_data<uint8_t>(L"POV");
    if (m_pov == nullptr) return;
    const Vec3 b = ctx.barrel;
    m_gun_muzzle = ctx.muzzle;
    m_gun_rot.pitch = std::atan2(b.z, std::sqrt(b.x * b.x + b.y * b.y)) * 180.0 / 3.14159265358979323846;
    m_gun_rot.yaw = std::atan2(b.y, b.x) * 180.0 / 3.14159265358979323846;
    m_gun_rot.roll = 0.0;
    m_held_weapon = gw.ret;
    m_gun_valid = true;
}

void BL4AimFixPlugin::tick_wrapper(int slot, void* actor, float delta, uintptr_t a3, uintptr_t a4) {
    const auto orig = m_tick_orig[slot];
    int role = -1;
    if (actor != nullptr) {
        if (m_slot_roles[slot][ROLE_MANAGER]) {
            if (m_manager == nullptr) m_manager = actor;
            if (actor == m_manager) role = ROLE_MANAGER;
        }
        if (role < 0 && m_slot_roles[slot][ROLE_WEAPON] && actor == m_held_weapon) role = ROLE_WEAPON;
        if (role < 0 && m_slot_roles[slot][ROLE_PAWN] && actor == m_local_pawn_ptr) role = ROLE_PAWN;
        if (role < 0 && m_slot_roles[slot][ROLE_CONTROLLER] && actor == m_local_pc_ptr) role = ROLE_CONTROLLER;
        if (role < 0 && m_slot_roles[slot][ROLE_CAMERA] && actor == m_local_cm_ptr) role = ROLE_CAMERA;
    }
    if (role < 0 || GetCurrentThreadId() != m_game_thread.load()) {
        if (role >= 0) ++m_beam_off_thread;
        orig(actor, delta, a3, a4);
        return;
    }
    ++m_role_calls[role];
    // The camera reads the camera-mode POV in the controller tick, and UEVR's HMD aim (its PlayerCameraManager::
    // ProcessViewRotation hook writes base + HMD into the view rotation) runs after the beams aim, before the draw:
    // holding the gun pose through it made HMD aim adopt the gun as the base and the view spun (only with aim method
    // HMD, 2026-11-05). End the hold at the start of the controller tick and of the configured ticks (default: the beam
    // manager's, after the beam aim is written).
    if ((role == ROLE_CONTROLLER || role == ROLE_CAMERA || m_restore_role[role]) && m_pov_held) {
        restore_pov();
        ++m_role_pov_restores[role];
    }
    uint8_t* pov = nullptr;
    Vec3 saved_loc{};
    Rot3 saved_rot{};
    if (m_swap_role[role] && m_cfg.mode == 1 && m_gun_valid && m_pov != nullptr) {
        pov = m_pov;
        std::memcpy(&saved_loc, pov, sizeof(Vec3));
        std::memcpy(&saved_rot, pov + sizeof(Vec3), sizeof(Rot3));
        std::memcpy(pov, &m_gun_muzzle, sizeof(Vec3));
        std::memcpy(pov + sizeof(Vec3), &m_gun_rot, sizeof(Rot3));
        ++m_role_swaps[role];
    }
    // (aim_player_beams() before the manager tick re-aimed the stored fields but the beam still fired along the body:
    // the aim is computed, traced and drawn before this tick. Kept for reference, not called.)
    const double before = beam_target_sum();
    orig(actor, delta, a3, a4);
    if (beam_target_sum() != before) ++m_role_target_changed[role];
    if (pov != nullptr) {
        std::memcpy(pov, &saved_loc, sizeof(Vec3));
        std::memcpy(pov + sizeof(Vec3), &saved_rot, sizeof(Rot3));
    }
    // The camera computed this frame's view (CameraModeState.POV) inside the controller tick; the beam aim is computed
    // later in the frame from that POV (2026-11-05: holding the gun pose until the controller tick changed nothing,
    // holding it through the controller tick spun the view). Hold the gun pose from here to the end of the frame.
    if (role == m_hold_start_role && !m_pov_held && m_cfg.mode == 1 && m_gun_valid && m_pov != nullptr && player_beam_active()) {
        std::memcpy(&m_pov_saved_loc, m_pov, sizeof(Vec3));
        std::memcpy(&m_pov_saved_rot, m_pov + sizeof(Vec3), sizeof(Rot3));
        std::memcpy(m_pov, &m_gun_muzzle, sizeof(Vec3));
        std::memcpy(m_pov + sizeof(Vec3), &m_gun_rot, sizeof(Rot3));
        m_pov_held = true;
        m_pov_held_ptr = m_pov;
        m_pov_hold_gun_loc = m_gun_muzzle;
        m_pov_hold_gun_rot = m_gun_rot;
        for (int c = 0; c < 2; ++c) {
            m_cache_held_ptr[c] = m_cache_pov[c];
            if (m_cache_held_ptr[c] != nullptr) std::memcpy(m_cache_saved[c], m_cache_held_ptr[c], 48);
        }
        ++m_pov_holds;
    }
}

// Unreflected ULightBeam aim fields (memory diff while firing, 2026-11-05; end == origin + direction * length exactly):
//   +0x388 aim origin (camera-mode POV)   +0x3A0 aim direction (unit, POV = body yaw)   +0x4B8 copy of the direction
//   +0x488 end point                      +0x4A0 copy of the end point
//   +0x408 / +0x420 the source muzzle location / rotation (the VR gun) - left alone
// ClientState (+0xA8) .instigator (+0xE0) = the pawn that fired. Only the local pawn's beams are re-aimed: origin = the
// first-person muzzle, direction = the barrel, end = origin + barrel * the game's length (its trace / max length).
void BL4AimFixPlugin::aim_player_beams() {
    if (m_manager == nullptr || !m_gun_valid || m_local_pawn_ptr == nullptr) return;
    constexpr size_t ACTIVE_BEAMS = 0x390, INSTIGATOR = 0xA8 + 0xE0;
    constexpr size_t AIM_ORIGIN = 0x388, AIM_DIR = 0x3A0, AIM_DIR_COPY = 0x4B8, END = 0x488, END_COPY = 0x4A0;
    const auto arr = (const uint8_t*)m_manager + ACTIVE_BEAMS;
    uint8_t* const* data = nullptr;
    int32_t num = 0;
    std::memcpy(&data, arr, sizeof(data));
    std::memcpy(&num, arr + 8, sizeof(num));
    if (data == nullptr || num <= 0 || num > 64) return;
    const double p = deg2rad(m_gun_rot.pitch), y = deg2rad(m_gun_rot.yaw);
    const Vec3 barrel{std::cos(p) * std::cos(y), std::cos(p) * std::sin(y), std::sin(p)};
    for (int i = 0; i < num; ++i) {
        uint8_t* beam = data[i];
        if (beam == nullptr) continue;
        void* instigator = nullptr;
        std::memcpy(&instigator, beam + INSTIGATOR, sizeof(instigator));
        if (instigator != m_local_pawn_ptr) continue;
        const Vec3 origin0 = read_vec(beam + AIM_ORIGIN);
        const Vec3 end0 = read_vec(beam + END);
        double reach = length(sub(end0, origin0));
        if (reach < 1.0 || reach > 100000.0) reach = 4000.0;
        const Vec3 end = add_scaled(m_gun_muzzle, barrel, reach);
        write_vec(beam + AIM_ORIGIN, m_gun_muzzle);
        write_vec(beam + AIM_DIR, barrel);
        write_vec(beam + AIM_DIR_COPY, barrel);
        write_vec(beam + END, end);
        write_vec(beam + END_COPY, end);
        ++m_beams_aimed;
    }
}

// ------------------------------------------------------------------------------------------------
// Config: plugins/BL4AimFix.txt (optional; defaults in Plugin.hpp)

void BL4AimFixPlugin::load_config(const std::filesystem::path& file) {
    if (!std::filesystem::exists(file)) {
        API::get()->log_info("BL4AimFix: no config at %ls, using defaults", file.c_str());
        return;
    }
    std::ifstream in(file);
    std::string line;
    while (std::getline(in, line)) {
        line = trim(line);
        if (line.empty() || line[0] == '#' || line[0] == ';') continue;
        if (const auto hash = line.find('#'); hash != std::string::npos) line = trim(line.substr(0, hash));
        const auto eq = line.find('=');
        if (eq == std::string::npos) continue;
        const auto key = trim(line.substr(0, eq));
        const auto val = trim(line.substr(eq + 1));
        auto as_bool = [&]() { return val == "1" || val == "true" || val == "yes" || val == "on"; };
        auto as_num = [&]() { try { return std::stod(val); } catch (...) { return 0.0; } };
        auto as_wide = [&]() { return std::wstring(val.begin(), val.end()); };
        auto as_rva = [&]() { try { return (uintptr_t)std::stoull(val, nullptr, 0); } catch (...) { return (uintptr_t)0; } };

        if (key == "Enabled") m_cfg.enabled = as_bool();
        else if (key == "Mode") m_cfg.mode = (int)as_num();
        else if (key == "Debug") m_cfg.debug = as_bool();
        else if (key == "StartTolerance") m_cfg.start_tolerance = as_num();
        else if (key == "MaxAngleFromAim") m_cfg.max_angle_from_aim = as_num();
        else if (key == "WeaponClass") m_cfg.weapon_class = as_wide();
        else if (key == "MuzzleSocket") m_cfg.muzzle_socket = as_wide();
        else if (key == "UseSocketRotation") m_cfg.use_socket_rotation = as_bool();
        else if (key == "BarrelAxis") m_cfg.barrel_axis = as_wide();
        else if (key == "MuzzleForwardOffset") m_cfg.muzzle_forward_offset = as_num();
        else if (key == "PitchOffset") m_cfg.pitch_offset_deg = as_num();
        else if (key == "YawOffset") m_cfg.yaw_offset_deg = as_num();
        else if (key == "RVA_SpawnLightProjectileNative") { if (auto v = as_rva()) m_cfg.rva_spawn_light_projectile_native = v; }
        else if (key == "RVA_ManagerSpawn") { if (auto v = as_rva()) m_cfg.rva_manager_spawn = v; }
        else if (key == "BeamAim") m_cfg.beam_aim = as_bool();
        else if (key == "ShowWeaponWhenScoped") m_cfg.show_weapon_when_scoped = as_bool();
    }
}
