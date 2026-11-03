#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <string>

#include <utility/Module.hpp>

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

void BL4AimFixPlugin::on_pre_engine_tick(API::UGameEngine*, float) {
    m_game_thread.store(GetCurrentThreadId());
    if (!m_hooks_ok || !m_cfg.debug) return;
    const double t = now_seconds();
    if (t - m_last_debug_log < 10.0) return;
    m_last_debug_log = t;
    API::get()->log_info("BL4AimFix[sum]: playerSpawns=%u overrides=%u keptNotAlongAim=%u keptNotFromCamera=%u notFromWeapon=%u noMuzzle=%u socketMissing=%u offThread=%u",
        m_player_spawns, m_overrides, m_kept_angle, m_kept_far, m_no_weapon, m_no_muzzle, m_socket_missing, m_off_thread);
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
    }
}
