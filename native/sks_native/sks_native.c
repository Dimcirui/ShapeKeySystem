/*
 * ShapeKeySystem_Native.dll: engine reads that are too call-heavy for Lua, starting with the RE4R
 * facial pose read (NativePose.lua). Registers the Lua table `sks_native`; when the DLL or a
 * function is missing, SKS keeps the Lua path.
 *
 * The pose read mirrors NativePose.lua step by step: per animation layer, per motion node, sample
 * each requested joint from the node's animation resource, sum by node weight, then blend the layer
 * over the result of the layers below by its blend mode and rate. Lua computes everything that
 * only changes at bind time (name hashes, mirrored hashes, eyelid / mouth flags, neutral poses)
 * and reads the facial controller's blink / lip-sync layer IDs; this file holds no engine object
 * between calls. Engine methods are found once through the TDB and called through REFramework's
 * invoke wrapper, which takes and returns System.Single as double.
 */
#include <windows.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "API.h"
#include "lua.h"
#include "lauxlib.h"

#define EXPORT __declspec(dllexport)
#define REQUIRED_LUA "$LuaVersion: Lua 5.4.3 "
#define NATIVE_VERSION 1
#define MAX_SPECS 256
#define MAX_LAYERS 64
#define MAX_MASK 8192
#define MAX_BINDINGS 64

static const REFrameworkPluginFunctions *ref_fn;
static const REFrameworkSDKData *sdk;
static int lua_ok = -1;

/* ---------------------------------------------------------------- engine calls */
#pragma pack(push, 1)
typedef struct {
    union {
        uint8_t bytes[128];
        uint8_t byte;
        uint32_t dword;
        uint64_t qword;
        double d;
        void *ptr;
    };
    bool exception_thrown;
} Ret;
#pragma pack(pop)

typedef struct {
    REFrameworkMethodHandle layer_count, layer, generation, mask_bits, mask_info;
    REFrameworkMethodHandle node_count, node, rate, mode, mask_id;
    REFrameworkMethodHandle weight, frame, motion_info, motion_name, mirrored;
    REFrameworkMethodHandle info_clear, transform;
    REFrameworkMethodHandle data_clear, valid_position, valid_rotation, position, rotation;
    REFrameworkMethodHandle mask_hash, mask_trans, mask_rot;
    REFrameworkMethodHandle array_length, array_get;
} Methods;
static Methods M;
static int methods_state;   /* 0 unresolved, 1 ok, -1 missing */
static char methods_error[160];

static REFrameworkMethodHandle find(const char *type, const char *name)
{
    REFrameworkTDBHandle tdb = sdk->functions->get_tdb();
    REFrameworkMethodHandle m = sdk->tdb->find_method(tdb, type, name);
    if (!m && methods_state == 0)
        snprintf(methods_error, sizeof(methods_error), "missing method %s.%s", type, name);
    return m;
}

static int resolve_methods(void)
{
    if (methods_state) return methods_state;
    Methods m;
    m.layer_count = find("via.motion.Motion", "getLayerCount");
    m.layer = find("via.motion.Motion", "getLayer(System.UInt32)");
    m.generation = find("via.motion.Motion", "get_SkeletonConstructCount");
    m.mask_bits = find("via.motion.Motion", "getJointMaskGroupBits(System.UInt32)");
    m.mask_info = find("via.motion.Motion", "getJointMaskInfo(System.UInt32)");
    m.node_count = find("via.motion.TreeLayer", "getRawMotionNodeCount");
    m.node = find("via.motion.TreeLayer", "getRawMotionNode(System.UInt32)");
    m.rate = find("via.motion.TreeLayer", "get_BlendRate");
    m.mode = find("via.motion.TreeLayer", "get_BlendMode");
    m.mask_id = find("via.motion.TreeLayer", "get_ActiveJointMaskID");
    m.weight = find("via.motion.MotionNodeCtrl", "get_Weight");
    m.frame = find("via.motion.MotionNodeCtrl", "get_Frame");
    m.motion_info = find("via.motion.MotionNodeCtrl", "getMotionInfo(via.motion.MotionInfo)");
    m.motion_name = find("via.motion.MotionNodeCtrl", "get_MotionName");
    m.mirrored = find("via.motion.MotionNodeCtrl", "get_OutputMirrored");
    m.info_clear = find("via.motion.MotionInfo", "clear");
    m.transform = find("via.motion.MotionInfo",
        "getAnimationTransform(System.UInt32, System.Single, via.motion.AnimationTransformData)");
    m.data_clear = find("via.motion.AnimationTransformData", "clear");
    m.valid_position = find("via.motion.AnimationTransformData", "get_ValidPosition");
    m.valid_rotation = find("via.motion.AnimationTransformData", "get_ValidRotation");
    m.position = find("via.motion.AnimationTransformData", "get_Position");
    m.rotation = find("via.motion.AnimationTransformData", "get_Rotation");
    m.mask_hash = find("via.motion.JointMaskInfo", "get_NameHash");
    m.mask_trans = find("via.motion.JointMaskInfo", "get_Trans");
    m.mask_rot = find("via.motion.JointMaskInfo", "get_Rot");
    m.array_length = find("System.Array", "get_Length");
    m.array_get = find("System.Array", "GetValue(System.Int32)");
    REFrameworkMethodHandle *all = (REFrameworkMethodHandle *)&m;
    for (size_t i = 0; i < sizeof(m) / sizeof(*all); ++i) {
        if (!all[i]) { methods_state = -1; return methods_state; }
    }
    M = m;
    methods_state = 1;
    return methods_state;
}

/* NativePose.lua's call(): a failed or throwing call is "no value", not an error */
static bool call(REFrameworkMethodHandle m, void *self, void **args, unsigned n, Ret *out)
{
    if (!self) return false;
    memset(out, 0, sizeof(*out));
    REFrameworkResult r = sdk->method->invoke(m, self, args, n * sizeof(void *), out, sizeof(*out));
    return r == REFRAMEWORK_ERROR_NONE && !out->exception_thrown;
}
static bool call0(REFrameworkMethodHandle m, void *self, Ret *out) { return call(m, self, NULL, 0, out); }
static bool call_u32(REFrameworkMethodHandle m, void *self, uint32_t a, Ret *out)
{
    void *args[1] = { (void *)(uintptr_t)a };
    return call(m, self, args, 1, out);
}
static void *single_arg(double v)
{
    uintptr_t slot = 0;
    memcpy(&slot, &v, sizeof(v));
    return (void *)slot;
}
static bool finite(double v) { return v == v && fabs(v) < HUGE_VAL; }
static bool managed(void *p) { return p && sdk->managed_object->is_managed_object(p); }

/* System.String: managed header (0x10), int32 length, UTF-16 data */
static bool string_contains(void *str, const char *needle)
{
    if (!managed(str)) return false;
    int32_t n = *(const int32_t *)((const uint8_t *)str + 0x10);
    const uint16_t *w = (const uint16_t *)((const uint8_t *)str + 0x14);
    size_t m = strlen(needle);
    if (n < 0 || n > 4096 || (size_t)n < m) return false;
    for (int32_t i = 0; i + (int32_t)m <= n; ++i) {
        size_t k = 0;
        while (k < m && w[i + k] == (uint16_t)(unsigned char)needle[k]) ++k;
        if (k == m) return true;
    }
    return false;
}

/* ---------------------------------------------------------------- quaternions (NativePose.lua) */
static void q_normal(double q[4])
{
    double n = sqrt(q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3]);
    if (n < 1e-9) { q[0] = q[1] = q[2] = 0; q[3] = 1; return; }
    for (int k = 0; k < 4; ++k) q[k] /= n;
}
static void q_blend(const double a[4], const double b[4], double t, double out[4])
{
    double sign = a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3] < 0 ? -1 : 1;
    for (int k = 0; k < 4; ++k) out[k] = a[k] * (1 - t) + b[k] * t * sign;
    q_normal(out);
}
static void q_mul(const double a[4], const double b[4], double out[4])
{
    double r[4] = {
        a[3] * b[0] + a[0] * b[3] + a[1] * b[2] - a[2] * b[1],
        a[3] * b[1] - a[0] * b[2] + a[1] * b[3] + a[2] * b[0],
        a[3] * b[2] + a[0] * b[1] - a[1] * b[0] + a[2] * b[3],
        a[3] * b[3] - a[0] * b[0] - a[1] * b[1] - a[2] * b[2] };
    memcpy(out, r, sizeof(r));
    q_normal(out);
}

/* ---------------------------------------------------------------- pose bindings */
enum { FLAG_EYELID = 1, FLAG_MOUTH = 2 };
typedef struct {
    uint32_t hash, mirror_hash;
    int flags;
    double neutral[7];
} Spec;
typedef struct {
    bool valid;
    uintptr_t motion;   /* bindings are shared by rigs with the same joints: the cache is per Motion */
    uint32_t id, bits, generation;
    ULONGLONG due;
    int count;
    uint32_t *hash;
    int8_t *trans, *rot;   /* -1 unknown, 0 false, 1 true */
} Mask;
typedef struct {
    bool used;
    int n;
    Spec spec[MAX_SPECS];
    Mask mask[MAX_LAYERS];
} Binding;
static Binding *bindings[MAX_BINDINGS];

static void mask_free(Mask *m)
{
    free(m->hash); free(m->trans); free(m->rot);
    memset(m, 0, sizeof(*m));
}

/* the layer's joint mask, re-read after 2 s or a new skeleton (NativePose.lua masks()) */
static Mask *layer_mask(Binding *b, void *motion, void *layer, int li, uint32_t generation, bool have_generation)
{
    Mask *m = &b->mask[li];
    ULONGLONG now = GetTickCount64();
    Ret r;
    bool have_id = call0(M.mask_id, layer, &r);
    uint32_t id = r.dword;
    if (m->valid && m->motion == (uintptr_t)motion && have_id == (m->id != UINT32_MAX) && (!have_id || m->id == id)
        && (!have_generation || m->generation == generation) && now < m->due) return m;
    mask_free(m);
    m->valid = true;
    m->motion = (uintptr_t)motion;
    m->id = have_id ? id : UINT32_MAX;
    m->generation = generation;
    m->due = now + 2000;
    if (!have_id || !call_u32(M.mask_bits, motion, id, &r)) return m;
    uint32_t bits = r.dword;
    if (!call_u32(M.mask_info, motion, bits, &r) || !managed(r.ptr)) return m;
    void *arr = r.ptr;
    if (!call0(M.array_length, arr, &r)) return m;
    int32_t n = (int32_t)r.dword;
    if (n < 0 || n > MAX_MASK) return m;
    m->hash = calloc(n ? n : 1, sizeof(uint32_t));
    m->trans = calloc(n ? n : 1, 1);
    m->rot = calloc(n ? n : 1, 1);
    if (!m->hash || !m->trans || !m->rot) {
        mask_free(m);
        m->valid = true; m->motion = (uintptr_t)motion; m->id = id; m->generation = generation; m->due = now + 2000;
        return m;
    }
    for (int32_t i = 0; i < n; ++i) {
        void *args[1] = { (void *)(intptr_t)i };
        if (!call(M.array_get, arr, args, 1, &r) || !r.ptr) continue;
        void *item = r.ptr;
        if (!call0(M.mask_hash, item, &r)) continue;
        int k = m->count++;
        m->hash[k] = r.dword;
        m->trans[k] = call0(M.mask_trans, item, &r) ? (r.byte != 0) : -1;
        m->rot[k] = call0(M.mask_rot, item, &r) ? (r.byte != 0) : -1;
    }
    return m;
}

typedef struct {
    bool has_p, has_q;
    double p[3], q[4];
} Sample;

/* NativePose.lua sample(): one joint of one node's animation resource at a frame */
static bool sample(void *info, void *data, double frame, uint32_t hash, bool mirrored, Sample *s)
{
    Ret r;
    memset(s, 0, sizeof(*s));
    call0(M.data_clear, data, &r);
    void *args[3] = { (void *)(uintptr_t)hash, single_arg(frame), data };
    if (!call(M.transform, info, args, 3, &r) || r.byte == 0) return false;
    if (call0(M.valid_position, data, &r) && r.byte && call0(M.position, data, &r)) {
        float v[3];
        memcpy(v, r.bytes, sizeof(v));
        if (finite(v[0]) && finite(v[1]) && finite(v[2])) {
            s->has_p = true;
            s->p[0] = v[0]; s->p[1] = v[1]; s->p[2] = v[2];
        }
    }
    if (call0(M.valid_rotation, data, &r) && r.byte && call0(M.rotation, data, &r)) {
        float v[4];
        memcpy(v, r.bytes, sizeof(v));
        if (finite(v[0]) && finite(v[1]) && finite(v[2]) && finite(v[3])) {
            double n = sqrt((double)v[0] * v[0] + (double)v[1] * v[1] + (double)v[2] * v[2] + (double)v[3] * v[3]);
            if (n > .5 && n < 1.5) {
                s->has_q = true;
                for (int k = 0; k < 4; ++k) s->q[k] = v[k] / n;
            }
        }
    }
    if (mirrored) {
        if (s->has_p) s->p[0] = -s->p[0];
        if (s->has_q) { s->q[1] = -s->q[1]; s->q[2] = -s->q[2]; }
    }
    return s->has_p || s->has_q;
}

typedef struct { bool exists, has_p, has_q; double p[3], q[4]; } Pose;
typedef struct { bool used; double pw, qw, p[3], q[4]; } Sum;

static double clamp01(double v) { return v < 0 ? 0 : v > 1 ? 1 : v; }

/* NativePose.lua read() for the selected specs; out[i] belongs to spec sel[i] */
static int read_pose(Binding *b, void *motion, void *info, void *data, int blink, int lipsync,
                     const int *sel, int count, Pose *out)
{
    Ret r;
    memset(out, 0, sizeof(Pose) * count);
    if (!call0(M.layer_count, motion, &r)) return 0;
    int nlayer = (int)r.dword;
    if (nlayer < 0 || nlayer > MAX_LAYERS) return 0;
    bool have_generation = call0(M.generation, motion, &r);
    uint32_t generation = r.dword;
    Sum sums[MAX_SPECS];
    for (int li = 0; li < nlayer; ++li) {
        if (!call_u32(M.layer, motion, (uint32_t)li, &r) || !r.ptr) continue;
        void *layer = r.ptr;
        if (!call0(M.node_count, layer, &r)) continue;
        uint32_t nodes = r.dword;
        if (!call0(M.rate, layer, &r)) continue;
        double rate = r.d;
        if (!call0(M.mode, layer, &r)) continue;
        uint32_t mode = r.dword;
        if (nodes > 128 || !finite(rate) || rate <= 0 || (mode != 0 && mode != 1)) continue;
        Mask *mask = layer_mask(b, motion, layer, li, generation, have_generation);
        memset(sums, 0, sizeof(Sum) * count);
        for (uint32_t ni = 0; ni < nodes && ni < 32; ++ni) {
            if (!call_u32(M.node, layer, ni, &r) || !r.ptr) continue;
            void *node = r.ptr;
            if (!call0(M.weight, node, &r)) continue;
            double weight = r.d;
            if (!call0(M.frame, node, &r)) continue;
            double frame = r.d;
            if (!finite(weight) || weight <= 1e-6 || !finite(frame)) continue;
            call0(M.info_clear, info, &r);
            void *args[1] = { info };
            if (!call(M.motion_info, node, args, 1, &r) || r.byte == 0) continue;
            bool mirrored = call0(M.mirrored, node, &r) && r.byte != 0;
            int role = 0;   /* 0 other, 1 blink, 2 lip-sync */
            if (call0(M.motion_name, node, &r)) {
                if (string_contains(r.ptr, "_blink_")) role = 1;
                else if (string_contains(r.ptr, "_LipSync_")) role = 2;
            }
            /* the controller's layer IDs take precedence over clip-name hints */
            if (li == blink) role = 1; else if (li == lipsync) role = 2;
            for (int i = 0; i < count; ++i) {
                const Spec *spec = &b->spec[sel[i]];
                if (role == 1 && !(spec->flags & FLAG_EYELID)) continue;
                if (role == 2 && !(spec->flags & FLAG_MOUTH)) continue;
                Sample s;
                if (!sample(info, data, frame, mirrored ? spec->mirror_hash : spec->hash, mirrored, &s)) continue;
                for (int k = 0; k < mask->count; ++k) {
                    if (mask->hash[k] != spec->hash) continue;
                    if (mask->trans[k] == 0) s.has_p = false;
                    if (mask->rot[k] == 0) s.has_q = false;
                    break;
                }
                Sum *sum = &sums[i];
                sum->used = true;
                if (s.has_p) {
                    sum->pw += weight;
                    for (int k = 0; k < 3; ++k) sum->p[k] += s.p[k] * weight;
                }
                if (s.has_q) {
                    double dot = sum->q[0] * s.q[0] + sum->q[1] * s.q[1] + sum->q[2] * s.q[2] + sum->q[3] * s.q[3];
                    double sign = sum->qw > 0 && dot < 0 ? -1 : 1;
                    sum->qw += weight;
                    for (int k = 0; k < 4; ++k) sum->q[k] += s.q[k] * weight * sign;
                }
            }
        }
        double alpha = clamp01(rate);
        for (int i = 0; i < count; ++i) {
            Sum *sum = &sums[i];
            if (!sum->used) continue;
            const double *n = b->spec[sel[i]].neutral;
            const double rest_p[3] = { n[0], n[1], n[2] };
            const double rest_q[4] = { n[3], n[4], n[5], n[6] };
            Pose *pose = &out[i];
            pose->exists = true;
            if (sum->pw > 0) {
                const double *base = pose->has_p ? pose->p : rest_p;
                double target[3];
                for (int k = 0; k < 3; ++k) {
                    double v = sum->p[k] / sum->pw;
                    target[k] = mode == 1 ? base[k] + (v - rest_p[k]) * alpha : base[k] * (1 - alpha) + v * alpha;
                }
                memcpy(pose->p, target, sizeof(target));
                pose->has_p = true;
            }
            if (sum->qw > 0) {
                double q[4] = { sum->q[0], sum->q[1], sum->q[2], sum->q[3] };
                q_normal(q);
                double base[4];
                memcpy(base, pose->has_q ? pose->q : rest_q, sizeof(base));
                if (mode == 1) {
                    const double inv[4] = { -rest_q[0], -rest_q[1], -rest_q[2], rest_q[3] };
                    const double identity[4] = { 0, 0, 0, 1 };
                    double delta[4], step[4];
                    q_mul(inv, q, delta);
                    q_blend(identity, delta, alpha, step);
                    q_mul(base, step, pose->q);
                } else {
                    q_blend(base, q, alpha, pose->q);
                }
                pose->has_q = true;
            }
        }
    }
    return 1;
}

/* ---------------------------------------------------------------- blendshape writes */
typedef struct {
    REFrameworkMethodHandle channels, count, list, length, set;
} MeshMethods;
static MeshMethods MM;
static int mesh_state;

static int resolve_mesh_methods(void)
{
    if (mesh_state) return mesh_state;
    REFrameworkTDBHandle tdb = sdk->functions->get_tdb();
    MeshMethods m;
    m.channels = sdk->tdb->find_method(tdb, "via.render.Mesh", "get_BlendShapeChannelNum");
    m.count = sdk->tdb->find_method(tdb, "via.render.Mesh", "get_BlendShapeChannelWeightCount");
    m.list = sdk->tdb->find_method(tdb, "via.render.Mesh", "get_ChannelWeightList");
    m.length = sdk->tdb->find_method(tdb, "System.Array", "get_Length");
    m.set = sdk->tdb->find_method(tdb, "via.render.Mesh", "setBlendShapeChannelWeightParam(System.UInt64, System.Single)");
    mesh_state = m.channels && m.count && m.list && m.length && m.set ? 1 : -1;
    if (mesh_state == 1) MM = m;
    return mesh_state;
}

/* Writer.limit(): the smallest of channel count, weight count and the live weight list (-1 unreadable) */
static int64_t mesh_limit(void *mesh)
{
    Ret r;
    if (!call0(MM.channels, mesh, &r)) return -1;
    int64_t limit = (int32_t)r.dword;
    if (!call0(MM.count, mesh, &r)) return -1;
    int64_t wc = (int32_t)r.dword;
    if (!call0(MM.list, mesh, &r) || !managed(r.ptr)) return -1;
    void *list = r.ptr;
    if (!call0(MM.length, list, &r)) return -1;
    int64_t length = (int32_t)r.dword;
    if (wc < limit) limit = wc;
    if (length < limit) limit = length;
    return limit < 0 ? -1 : limit;
}

/* ---------------------------------------------------------------- Lua */
static uintptr_t check_address(lua_State *L, int i)
{
    lua_Integer v = luaL_checkinteger(L, i);
    return (uintptr_t)v;
}

/* pose_bind({hash, mirror_hash, flags, n1..n7, ...}) -> id | nil, error */
static int l_pose_bind(lua_State *L)
{
    luaL_checktype(L, 1, LUA_TTABLE);
    lua_Integer len = luaL_len(L, 1);
    if (len <= 0 || len % 10 != 0 || len / 10 > MAX_SPECS) {
        lua_pushnil(L); lua_pushstring(L, "bad spec list"); return 2;
    }
    int slot = -1;
    for (int i = 0; i < MAX_BINDINGS; ++i) if (!bindings[i]) { slot = i; break; }
    if (slot < 0) { lua_pushnil(L); lua_pushstring(L, "too many pose bindings"); return 2; }
    Binding *b = calloc(1, sizeof(Binding));
    if (!b) { lua_pushnil(L); lua_pushstring(L, "out of memory"); return 2; }
    b->n = (int)(len / 10);
    for (int s = 0; s < b->n; ++s) {
        double v[10];
        for (int k = 0; k < 10; ++k) {
            lua_rawgeti(L, 1, s * 10 + k + 1);
            v[k] = lua_tonumber(L, -1);
            lua_pop(L, 1);
        }
        b->spec[s].hash = (uint32_t)(int64_t)v[0];
        b->spec[s].mirror_hash = (uint32_t)(int64_t)v[1];
        b->spec[s].flags = (int)v[2];
        memcpy(b->spec[s].neutral, v + 3, sizeof(double) * 7);
    }
    b->used = true;
    bindings[slot] = b;
    lua_pushinteger(L, slot + 1);
    return 1;
}

static Binding *binding_of(lua_State *L, int i)
{
    lua_Integer id = luaL_checkinteger(L, i);
    if (id < 1 || id > MAX_BINDINGS || !bindings[id - 1]) return NULL;
    return bindings[id - 1];
}

static int l_pose_free(lua_State *L)
{
    lua_Integer id = luaL_checkinteger(L, 1);
    if (id >= 1 && id <= MAX_BINDINGS && bindings[id - 1]) {
        Binding *b = bindings[id - 1];
        for (int li = 0; li < MAX_LAYERS; ++li) mask_free(&b->mask[li]);
        free(b);
        bindings[id - 1] = NULL;
    }
    return 0;
}

/* pose_read(id, motion, info, data, blink_layer, lipsync_layer, {spec index (1-based)...})
   -> {exists, has_p, px, py, pz, has_q, qx, qy, qz, qw, ...} per selected spec | nil, error */
static int l_pose_read(lua_State *L)
{
    Binding *b = binding_of(L, 1);
    if (!b) { lua_pushnil(L); lua_pushstring(L, "unknown pose binding"); return 2; }
    if (resolve_methods() != 1) { lua_pushnil(L); lua_pushstring(L, methods_error); return 2; }
    void *motion = (void *)check_address(L, 2);
    void *info = (void *)check_address(L, 3);
    void *data = (void *)check_address(L, 4);
    int blink = (int)luaL_optinteger(L, 5, -1);
    int lipsync = (int)luaL_optinteger(L, 6, -1);
    luaL_checktype(L, 7, LUA_TTABLE);
    if (!managed(motion) || !managed(info) || !managed(data)) {
        lua_pushnil(L); lua_pushstring(L, "invalid motion or buffers"); return 2;
    }
    int sel[MAX_SPECS], count = 0;
    lua_Integer len = luaL_len(L, 7);
    for (lua_Integer i = 1; i <= len && count < MAX_SPECS; ++i) {
        lua_rawgeti(L, 7, i);
        lua_Integer s = lua_tointeger(L, -1);
        lua_pop(L, 1);
        if (s >= 1 && s <= b->n) sel[count++] = (int)(s - 1);
    }
    Pose out[MAX_SPECS];
    read_pose(b, motion, info, data, blink, lipsync, sel, count, out);
    lua_createtable(L, count * 10, 0);
    int k = 1;
    for (int i = 0; i < count; ++i) {
        const Pose *p = &out[i];
        double row[10] = { p->exists, p->has_p, p->p[0], p->p[1], p->p[2],
                           p->has_q, p->q[0], p->q[1], p->q[2], p->q[3] };
        for (int j = 0; j < 10; ++j) { lua_pushnumber(L, row[j]); lua_rawseti(L, -2, k++); }
    }
    return 1;
}

/* write_weights(mesh, {channel index...}, {weight...}, n) -> writes | nil, error.
   Lua has already decided what to write and which channels may be written; this checks the
   bounds once and writes them in one call. */
static int l_write_weights(lua_State *L)
{
    void *mesh = (void *)check_address(L, 1);
    luaL_checktype(L, 2, LUA_TTABLE);
    luaL_checktype(L, 3, LUA_TTABLE);
    lua_Integer n = luaL_checkinteger(L, 4);
    if (resolve_mesh_methods() != 1) { lua_pushnil(L); lua_pushstring(L, "mesh methods missing"); return 2; }
    if (!managed(mesh)) { lua_pushnil(L); lua_pushstring(L, "invalid mesh"); return 2; }
    int64_t limit = mesh_limit(mesh);
    if (limit < 0) { lua_pushnil(L); lua_pushstring(L, "mesh bounds unreadable"); return 2; }
    int written = 0;
    for (lua_Integer i = 1; i <= n; ++i) {
        lua_rawgeti(L, 2, i);
        lua_Integer idx = lua_tointeger(L, -1);
        lua_rawgeti(L, 3, i);
        double v = lua_tonumber(L, -1);
        lua_pop(L, 2);
        if (idx < 0 || idx >= limit || !finite(v)) continue;
        void *args[2] = { (void *)(uintptr_t)idx, single_arg(v) };
        Ret r;
        if (call(MM.set, mesh, args, 2, &r)) ++written;
    }
    lua_pushinteger(L, written);
    return 1;
}

static int l_version(lua_State *L) { lua_pushinteger(L, NATIVE_VERSION); return 1; }

static void sks_register(lua_State *L)
{
    static const luaL_Reg fns[] = { { "version", l_version }, { "pose_bind", l_pose_bind },
        { "pose_free", l_pose_free }, { "pose_read", l_pose_read }, { "write_weights", l_write_weights },
        { NULL, NULL } };
    lua_newtable(L);
    luaL_setfuncs(L, fns, 0);
    lua_setglobal(L, "sks_native");
}

/* ---------------------------------------------------------------- REFramework */
static int host_lua_matches(void *module)
{
    const unsigned char *base = (const unsigned char *)module;
    if (!base) return 0;
    const IMAGE_DOS_HEADER *dos = (const IMAGE_DOS_HEADER *)base;
    const IMAGE_NT_HEADERS *nt = (const IMAGE_NT_HEADERS *)(base + dos->e_lfanew);
    const unsigned char *end = base + nt->OptionalHeader.SizeOfImage;
    const size_t m = sizeof(REQUIRED_LUA) - 1;
    for (const unsigned char *p = base; p < end;) {
        MEMORY_BASIC_INFORMATION mi;
        if (!VirtualQuery(p, &mi, sizeof(mi))) break;
        const unsigned char *r_end = (const unsigned char *)mi.BaseAddress + mi.RegionSize;
        if (r_end > end) r_end = end;
        DWORD prot = mi.Protect & 0xff;
        int readable = mi.State == MEM_COMMIT && !(mi.Protect & PAGE_GUARD) &&
            (prot == PAGE_READONLY || prot == PAGE_READWRITE || prot == PAGE_EXECUTE_READ ||
             prot == PAGE_EXECUTE_READWRITE || prot == PAGE_WRITECOPY || prot == PAGE_EXECUTE_WRITECOPY);
        if (readable && (size_t)(r_end - p) >= m) {
            for (const unsigned char *q = p; q + m <= r_end; ++q) {
                if (*q == '$' && !memcmp(q, REQUIRED_LUA, m)) return 1;
            }
        }
        p = r_end;
    }
    return 0;
}

static void on_lua_created(lua_State *L)
{
    if (lua_ok == 0) return;
    sks_register(L);
}

static void on_lua_destroyed(lua_State *L)
{
    (void)L;
    for (int i = 0; i < MAX_BINDINGS; ++i) {
        if (!bindings[i]) continue;
        for (int li = 0; li < MAX_LAYERS; ++li) mask_free(&bindings[i]->mask[li]);
        free(bindings[i]);
        bindings[i] = NULL;
    }
}

EXPORT void reframework_plugin_required_version(REFrameworkPluginVersion *v)
{
    v->major = REFRAMEWORK_PLUGIN_VERSION_MAJOR;
    v->minor = 0;
    v->patch = 0;
}

EXPORT bool reframework_plugin_initialize(const REFrameworkPluginInitializeParam *param)
{
    ref_fn = param->functions;
    sdk = param->sdk;
    if (!sdk || !param->version || !param->version->game_name || strcmp(param->version->game_name, "RE4") != 0)
        return true;   /* RE4R only for now: elsewhere SKS keeps its Lua paths */
    lua_ok = host_lua_matches(param->reframework_module);
    if (!lua_ok) {
        ref_fn->log_error("[ShapeKeySystem_Native] REFramework does not use Lua 5.4.3: not registering sks_native");
        return true;
    }
    ref_fn->on_lua_state_created(on_lua_created);
    ref_fn->on_lua_state_destroyed(on_lua_destroyed);
    ref_fn->log_info("[ShapeKeySystem_Native] sks_native ready");
    return true;
}
