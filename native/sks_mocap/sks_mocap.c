/* ShapeKeySystem_Mocap: in-game UDP receiver for the 面捕 page (Mocap.lua).
 *
 * REFramework Lua cannot open sockets, so this plugin does it and hands each frame to Lua through
 * the global table `sks_mocap_native` (start / stop / poll). Supported phone apps:
 *   ifacialmocap  text packets "name-12|name&12|head#a,b,c,d,e,f|" on UDP 49983; the phone only
 *                 streams after a trigger string is sent to it, re-sent while no data arrives
 *   rhylive       OSC message (or #bundle) "/Face" with 52 big-endian float32 in ARKit order, UDP 9000;
 *                 the phone is told the PC's address, which local_ips() lists for the page
 *   vmc           VMC protocol (OSC) from any sender, on UDP 39539: /VMC/Ext/Blend/Val name
 *                 value per expression, committed by /VMC/Ext/Blend/Apply. ARKit / Perfect Sync
 *                 names (any case) fill w; other names go to `extra` under their own spelling.
 *                 The Head bone's rotation from /VMC/Ext/Bone/Pos becomes the head turn
 *
 * Constraints:
 * - No thread: poll() drains the nonblocking socket on the caller's (game) thread, so nothing here
 *   races the Lua state and a script reset needs no shutdown.
 * - The Lua C API is compiled in (REFramework exports none) and works on REFramework's own state,
 *   which is only safe with the same Lua release. The host module is searched for its Lua version
 *   string first; on any other release the table is not registered and Mocap.lua falls back to
 *   live.json.
 */

#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "API.h"
#include "lua.h"
#include "lauxlib.h"
#include "sks_mocap.h"

#define EXPORT __declspec(dllexport)
#define TRIGGER_MS 2000
#define REQUIRED_LUA "$LuaVersion: Lua 5.4.3 "

static const char *ARKIT[N_FACE] = {
    "browDownLeft", "browDownRight", "browInnerUp", "browOuterUpLeft", "browOuterUpRight",
    "cheekPuff", "cheekSquintLeft", "cheekSquintRight",
    "eyeBlinkLeft", "eyeBlinkRight", "eyeLookDownLeft", "eyeLookDownRight", "eyeLookInLeft", "eyeLookInRight",
    "eyeLookOutLeft", "eyeLookOutRight", "eyeLookUpLeft", "eyeLookUpRight", "eyeSquintLeft", "eyeSquintRight",
    "eyeWideLeft", "eyeWideRight",
    "jawForward", "jawLeft", "jawOpen", "jawRight",
    "mouthClose", "mouthDimpleLeft", "mouthDimpleRight", "mouthFrownLeft", "mouthFrownRight", "mouthFunnel",
    "mouthLeft", "mouthLowerDownLeft", "mouthLowerDownRight", "mouthPressLeft", "mouthPressRight", "mouthPucker",
    "mouthRight", "mouthRollLower", "mouthRollUpper", "mouthShrugLower", "mouthShrugUpper", "mouthSmileLeft",
    "mouthSmileRight", "mouthStretchLeft", "mouthStretchRight", "mouthUpperUpLeft", "mouthUpperUpRight",
    "noseSneerLeft", "noseSneerRight",
    "tongueOut",
};
static const char IFM_TRIGGER[] = "iFacialMocap_sahuasouryya9218sauhuiayeta91555dy3719";

enum { SCHEME_NONE, SCHEME_IFM, SCHEME_RHYLIVE, SCHEME_VMC };

static struct {
    SOCKET sock;
    int wsa, scheme, port, error;
    float w[N_FACE];
    float head[N_HEAD];
    int has_head;
    uint64_t seq, packets, rejected;
    ULONGLONG rx_at, trigger_at;
    struct sockaddr_in target;   /* where the iFacialMocap trigger goes; follows the sender */
    int has_target;
    char sender[INET_ADDRSTRLEN];
    VmcState vmc;
} R = { INVALID_SOCKET };

static const REFrameworkPluginFunctions *ref_fn;
static int lua_ok = -1;   /* -1 unchecked, 0 wrong Lua release, 1 ok */

static float clamp01(float v) { return v < 0 ? 0 : (v > 1 ? 1 : v); }

/* ---------------------------------------------------------------- iFacialMocap */
static int arkit_index(const char *name, size_t n)
{
    char buf[64];
    if (n == 0 || n >= sizeof(buf) - 8) return -1;
    memcpy(buf, name, n);
    buf[n] = 0;
    /* "eyeBlink_L" -> "eyeBlinkLeft" */
    if (n > 2 && buf[n - 2] == '_' && (buf[n - 1] == 'L' || buf[n - 1] == 'R')) {
        strcpy(buf + n - 2, buf[n - 1] == 'L' ? "Left" : "Right");
    }
    for (int i = 0; i < N_FACE; ++i)
        if (!strcmp(buf, ARKIT[i])) return i;
    return -1;
}

/* Fills out / head in place (values persist between packets). Returns the number of shapes. */
int sks_parse_ifm(const char *p, int n, float *out, float *head, int *has_head)
{
    int hits = 0;
    int i = 0;
    while (i < n) {
        int j = i;
        while (j < n && p[j] != '|') ++j;
        const char *f = p + i;
        int len = j - i;
        i = j + 1;
        while (len > 0 && (*f == '=' || *f == ' ')) { ++f; --len; }
        if (len <= 0) continue;
        const char *hash = memchr(f, '#', (size_t)len);
        if (hash) {
            if (hash - f == 4 && !memcmp(f, "head", 4)) {
                char buf[256];
                int vl = len - (int)(hash - f) - 1;
                if (vl <= 0 || vl >= (int)sizeof(buf)) continue;
                memcpy(buf, hash + 1, (size_t)vl);
                buf[vl] = 0;
                float v[N_HEAD];
                int k = 0;
                char *s = buf, *end;
                while (k < N_HEAD) {
                    double d = strtod(s, &end);
                    if (end == s || !isfinite(d)) break;
                    v[k++] = (float)d;
                    s = end;
                    if (*s == ',') ++s; else break;
                }
                if (k == N_HEAD) { memcpy(head, v, sizeof(v)); *has_head = 1; }
            }
            continue;
        }
        /* "name-12" (classic) or "name&12" (newer app versions) */
        int sep = -1;
        for (int k = len - 1; k > 0; --k)
            if (f[k] == '-' || f[k] == '&') { sep = k; break; }
        if (sep <= 0) continue;
        int idx = arkit_index(f, (size_t)sep);
        if (idx < 0) continue;
        char num[32];
        int nl = len - sep - 1;
        if (nl <= 0 || nl >= (int)sizeof(num)) continue;
        memcpy(num, f + sep + 1, (size_t)nl);
        num[nl] = 0;
        char *end;
        double d = strtod(num, &end);
        if (end == num || !isfinite(d)) continue;
        out[idx] = clamp01((float)(d / 100.0));
        ++hits;
    }
    return hits;
}

/* ---------------------------------------------------------------- RhyLive (OSC) */
static uint32_t be32(const unsigned char *p)
{
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}

/* OSC string: NUL-terminated, padded to 4 bytes. Returns the offset after it, or 0. */
static size_t osc_str(const unsigned char *p, size_t n, size_t off, const char **s)
{
    size_t e = off;
    while (e < n && p[e]) ++e;
    if (e >= n) return 0;
    size_t next = (e + 4) & ~(size_t)3;
    if (next > n) return 0;
    *s = (const char *)p + off;
    return next;
}

/* Returns 1 when a /Face message was found (the last one in a bundle wins), 0 for other OSC
 * traffic, -1 for a malformed packet. out is only written on 1. */
int sks_parse_osc(const unsigned char *p, size_t n, float *out, int depth)
{
    if (depth > 4 || n < 4 || (n & 3)) return -1;
    if (n >= 8 && !memcmp(p, "#bundle", 8)) {
        if (n < 16) return -1;
        size_t off = 16;   /* "#bundle\0" + 8-byte time tag */
        int found = 0;
        while (off < n) {
            if (n - off < 4) return -1;
            uint32_t len = be32(p + off);
            off += 4;
            if (len == 0 || len > n - off || (len & 3)) return -1;
            int r = sks_parse_osc(p + off, len, out, depth + 1);
            if (r < 0) return -1;
            if (r) found = 1;
            off += len;
        }
        return found;
    }
    const char *addr, *tags;
    size_t off = osc_str(p, n, 0, &addr);
    if (!off || addr[0] != '/') return -1;
    if (strcmp(addr, "/Face")) return 0;
    off = osc_str(p, n, off, &tags);
    if (!off || tags[0] != ',' || strlen(tags) != N_FACE + 1) return -1;
    if (n - off != N_FACE * 4) return -1;
    float v[N_FACE];
    for (int i = 0; i < N_FACE; ++i) {
        if (tags[i + 1] != 'f') return -1;
        uint32_t bits = be32(p + off + (size_t)i * 4);
        float x;
        memcpy(&x, &bits, 4);
        if (!isfinite(x)) return -1;
        v[i] = clamp01(x);
    }
    memcpy(out, v, sizeof(v));
    return 1;
}

/* ---------------------------------------------------------------- VMC */
static int arkit_index_ci(const char *name)
{
    for (int i = 0; i < N_FACE; ++i)
        if (!_stricmp(name, ARKIT[i])) return i;
    return -1;
}

static float be_float(const unsigned char *p)
{
    uint32_t b = be32(p);
    float x;
    memcpy(&x, &b, 4);
    return x;
}

/* Unity quaternion (x, y, z, w) -> degrees about X (pitch), Y (yaw), Z (roll), Unity's ZXY order */
static void quat_euler(float x, float y, float z, float w, float *out)
{
    const double R2D = 57.29577951308232;
    double sp = 2.0 * (w * x - y * z);
    if (sp > 1) sp = 1; else if (sp < -1) sp = -1;
    out[0] = (float)(asin(sp) * R2D);
    out[1] = (float)(atan2(2.0 * (w * y + x * z), 1.0 - 2.0 * (x * x + y * y)) * R2D);
    out[2] = (float)(atan2(2.0 * (w * z + x * y), 1.0 - 2.0 * (x * x + z * z)) * R2D);
}

/* a non-ARKit expression: updated in place, appended while there is room; longer names are dropped */
static void vmc_extra(VmcState *v, const char *name, float x)
{
    if (strlen(name) >= VMC_NAME || !name[0]) return;
    for (int i = 0; i < v->nx; ++i) {
        if (!strcmp(v->x[i].name, name)) { v->x[i].v = x; return; }
    }
    if (v->nx >= VMC_MAX_EXTRA) return;
    strcpy(v->x[v->nx].name, name);
    v->x[v->nx++].v = x;
}

static void vmc_commit(VmcState *v, float *out, float *head, int *has_head)
{
    memcpy(out, v->w, sizeof(v->w));
    memcpy(v->cx, v->x, sizeof(VmcExtra) * (size_t)v->nx);
    v->ncx = v->nx;
    if (v->head_new) { memcpy(head, v->head, sizeof(v->head)); *has_head = 1; v->head_new = 0; }
    v->dirty = 0;
}

/* one OSC element; returns -1 malformed, 0 nothing to show, 1 a frame was committed */
static int vmc_elem(const unsigned char *p, size_t n, VmcState *v, float *out, float *head, int *has_head, int depth)
{
    if (depth > 4 || n < 4 || (n & 3)) return -1;
    if (n >= 8 && !memcmp(p, "#bundle", 8)) {
        if (n < 16) return -1;
        size_t off = 16;
        int found = 0;
        while (off < n) {
            if (n - off < 4) return -1;
            uint32_t len = be32(p + off);
            off += 4;
            if (len == 0 || len > n - off || (len & 3)) return -1;
            int r = vmc_elem(p + off, len, v, out, head, has_head, depth + 1);
            if (r < 0) return -1;
            if (r) found = 1;
            off += len;
        }
        return found;
    }
    const char *addr, *tags, *name;
    size_t off = osc_str(p, n, 0, &addr);
    if (!off || addr[0] != '/') return -1;
    if (strncmp(addr, "/VMC/Ext/", 9)) return 0;
    const char *what = addr + 9;
    int val = !strcmp(what, "Blend/Val"), bone = !strcmp(what, "Bone/Pos");
    if (!strcmp(what, "Blend/Apply")) {
        v->seen_apply = 1;
        vmc_commit(v, out, head, has_head);
        return 1;
    }
    if (!val && !bone) return 0;   /* Root/Pos, OK, T, Cam ... */
    off = osc_str(p, n, off, &tags);
    if (!off || tags[0] != ',' || tags[1] != 's') return -1;
    size_t noff = osc_str(p, n, off, &name);
    if (!noff) return -1;
    off = noff;
    if (val) {
        if (strcmp(tags, ",sf") || n - off < 4) return -1;
        float x = be_float(p + off);
        if (!isfinite(x)) return 0;
        int idx = arkit_index_ci(name);
        if (idx >= 0) v->w[idx] = clamp01(x);
        else vmc_extra(v, name, clamp01(x));
        v->dirty = 1;
        return 0;
    }
    if (_stricmp(name, "Head")) return 0;
    if (strncmp(tags, ",sfffffff", 9) || n - off < 28) return -1;
    float f[7];
    for (int i = 0; i < 7; ++i) {
        f[i] = be_float(p + off + (size_t)i * 4);
        if (!isfinite(f[i])) return -1;
    }
    quat_euler(f[3], f[4], f[5], f[6], v->head);
    v->head[3] = f[0]; v->head[4] = f[1]; v->head[5] = f[2];
    v->head_new = 1;
    return 0;
}

/* One UDP packet. A sender that never sends Blend/Apply gets each packet with expression values
 * committed as a frame. Returns -1 malformed, 0 nothing new, 1 a frame was committed. */
int sks_parse_vmc(const unsigned char *p, size_t n, VmcState *v, float *out, float *head, int *has_head)
{
    int r = vmc_elem(p, n, v, out, head, has_head, 0);
    if (r == 0 && !v->seen_apply && v->dirty) { vmc_commit(v, out, head, has_head); r = 1; }
    return r;
}

/* ---------------------------------------------------------------- socket */
static void close_sock(void)
{
    if (R.sock != INVALID_SOCKET) { closesocket(R.sock); R.sock = INVALID_SOCKET; }
    R.scheme = SCHEME_NONE;
}

/* phone_ip may be NULL: iFacialMocap then waits until the phone streams on its own. */
static int start(int scheme, int port, const char *phone_ip)
{
    close_sock();
    memset(R.w, 0, sizeof(R.w));
    memset(R.head, 0, sizeof(R.head));
    R.has_head = 0;
    memset(&R.vmc, 0, sizeof(R.vmc));
    R.seq = R.packets = R.rejected = 0;
    R.rx_at = R.trigger_at = 0;
    R.has_target = 0;
    R.sender[0] = 0;
    R.error = 0;
    if (!R.wsa) {
        WSADATA d;
        if ((R.error = WSAStartup(MAKEWORD(2, 2), &d))) return R.error;
        R.wsa = 1;
    }
    if (phone_ip && *phone_ip) {
        memset(&R.target, 0, sizeof(R.target));
        R.target.sin_family = AF_INET;
        R.target.sin_port = htons((u_short)port);
        if (InetPtonA(AF_INET, phone_ip, &R.target.sin_addr) != 1) return R.error = WSAEINVAL;
        R.has_target = 1;
    }
    SOCKET s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (s == INVALID_SOCKET) return R.error = WSAGetLastError();
    BOOL excl = TRUE;
    u_long nb = 1;
    struct sockaddr_in a = { 0 };
    a.sin_family = AF_INET;
    a.sin_port = htons((u_short)port);
    a.sin_addr.s_addr = htonl(INADDR_ANY);
    if (setsockopt(s, SOL_SOCKET, SO_EXCLUSIVEADDRUSE, (const char *)&excl, sizeof(excl)) ||
        ioctlsocket(s, FIONBIO, &nb) || bind(s, (struct sockaddr *)&a, sizeof(a))) {
        R.error = WSAGetLastError();
        closesocket(s);
        return R.error;
    }
    R.sock = s;
    R.scheme = scheme;
    R.port = port;
    return 0;
}

static void pump(void)
{
    if (R.sock == INVALID_SOCKET) return;
    ULONGLONG now = GetTickCount64();
    if (R.scheme == SCHEME_IFM && R.has_target && now - R.rx_at > TRIGGER_MS && now - R.trigger_at > TRIGGER_MS) {
        sendto(R.sock, IFM_TRIGGER, (int)sizeof(IFM_TRIGGER) - 1, 0, (struct sockaddr *)&R.target, sizeof(R.target));
        R.trigger_at = now;
    }
    static unsigned char pkt[65536];
    /* bounded work per frame; a backlog drains over the next frames */
    for (int i = 0; i < 256; ++i) {
        struct sockaddr_in from;
        int fl = sizeof(from);
        int n = recvfrom(R.sock, (char *)pkt, (int)sizeof(pkt) - 1, 0, (struct sockaddr *)&from, &fl);
        if (n == SOCKET_ERROR) {
            int e = WSAGetLastError();
            if (e == WSAEWOULDBLOCK) break;
            /* ICMP port-unreachable for the trigger shows up here on Windows */
            if (e == WSAECONNRESET || e == WSAEMSGSIZE) { ++R.rejected; continue; }
            R.error = e;
            close_sock();
            break;
        }
        ++R.packets;
        int ok;
        if (R.scheme == SCHEME_IFM) {
            pkt[n] = 0;
            ok = sks_parse_ifm((const char *)pkt, n, R.w, R.head, &R.has_head) > 0;
        } else if (R.scheme == SCHEME_VMC) {
            ok = sks_parse_vmc(pkt, (size_t)n, &R.vmc, R.w, R.head, &R.has_head) == 1;
            if (!ok) continue;   /* bone-only packets between frames are normal, not rejects */
        } else {
            ok = sks_parse_osc(pkt, (size_t)n, R.w, 0) == 1;
        }
        if (!ok) { ++R.rejected; continue; }
        ++R.seq;
        R.rx_at = GetTickCount64();
        InetNtopA(AF_INET, &from.sin_addr, R.sender, sizeof(R.sender));
        if (R.scheme == SCHEME_IFM) {   /* re-trigger the phone that actually streams */
            R.target = from;
            R.target.sin_port = htons((u_short)R.port);
            R.has_target = 1;
        }
    }
}

/* ---------------------------------------------------------------- Lua */
static int scheme_of(const char *s)
{
    if (!strcmp(s, "ifacialmocap")) return SCHEME_IFM;
    if (!strcmp(s, "rhylive")) return SCHEME_RHYLIVE;
    if (!strcmp(s, "vmc")) return SCHEME_VMC;
    return SCHEME_NONE;
}

/* start(scheme, port?, phone_ip?) -> true | nil, error code */
static int l_start(lua_State *L)
{
    int scheme = scheme_of(luaL_checkstring(L, 1));
    if (scheme == SCHEME_NONE) return luaL_argerror(L, 1, "ifacialmocap / rhylive / vmc");
    lua_Integer port = luaL_optinteger(L, 2, scheme == SCHEME_IFM ? 49983 : scheme == SCHEME_VMC ? 39539 : 9000);
    if (port < 1 || port > 65535) return luaL_argerror(L, 2, "1..65535");
    const char *ip = luaL_optstring(L, 3, NULL);
    int err = start(scheme, (int)port, ip);
    if (err) {
        lua_pushnil(L);
        lua_pushinteger(L, err);
        return 2;
    }
    lua_pushboolean(L, 1);
    return 1;
}

static int l_stop(lua_State *L)
{
    (void)L;
    close_sock();
    return 0;
}

static void set_num(lua_State *L, const char *k, lua_Number v) { lua_pushnumber(L, v); lua_setfield(L, -2, k); }
static void set_int(lua_State *L, const char *k, lua_Integer v) { lua_pushinteger(L, v); lua_setfield(L, -2, k); }

/* the array field k of the table on top, created when missing */
static void fill_array(lua_State *L, const char *k, const float *v, int n)
{
    if (lua_getfield(L, -1, k) != LUA_TTABLE) {
        lua_pop(L, 1);
        lua_createtable(L, n, 0);
        lua_pushvalue(L, -1);
        lua_setfield(L, -3, k);
    }
    for (int i = 0; i < n; ++i) {
        lua_pushnumber(L, (lua_Number)v[i]);
        lua_rawseti(L, -2, i + 1);
    }
    lua_pop(L, 1);
}

/* poll(t?) -> t: running, scheme, port, seq, age_ms (-1 = nothing yet), packets, rejected, error,
 * sender, w[52], head[6] or nil. Reusing t keeps the per-frame call allocation free. */
static int l_poll(lua_State *L)
{
    pump();
    if (!lua_istable(L, 1)) {
        lua_settop(L, 0);
        lua_createtable(L, 0, 12);
    } else {
        lua_settop(L, 1);
    }
    lua_pushboolean(L, R.sock != INVALID_SOCKET);
    lua_setfield(L, -2, "running");
    lua_pushstring(L, R.scheme == SCHEME_IFM ? "ifacialmocap" : R.scheme == SCHEME_RHYLIVE ? "rhylive"
                      : R.scheme == SCHEME_VMC ? "vmc" : "");
    lua_setfield(L, -2, "scheme");
    set_int(L, "port", R.port);
    set_int(L, "seq", (lua_Integer)R.seq);
    set_num(L, "age_ms", R.seq ? (lua_Number)(GetTickCount64() - R.rx_at) : -1);
    set_int(L, "packets", (lua_Integer)R.packets);
    set_int(L, "rejected", (lua_Integer)R.rejected);
    set_int(L, "error", R.error);
    lua_pushstring(L, R.sender);
    lua_setfield(L, -2, "sender");
    fill_array(L, "w", R.w, N_FACE);
    if (R.has_head) {
        fill_array(L, "head", R.head, N_HEAD);
    } else {
        lua_pushnil(L);
        lua_setfield(L, -2, "head");
    }
    /* VMC expressions outside the ARKit 52, { name = value }; nil when there are none */
    if (R.scheme == SCHEME_VMC && R.vmc.ncx > 0) {
        lua_createtable(L, 0, R.vmc.ncx);
        for (int i = 0; i < R.vmc.ncx; ++i) {
            lua_pushnumber(L, (lua_Number)R.vmc.cx[i].v);
            lua_setfield(L, -2, R.vmc.cx[i].name);
        }
    } else {
        lua_pushnil(L);
    }
    lua_setfield(L, -2, "extra");
    return 1;
}

/* local_ips() -> { "192.168.1.20", ... }: this PC's IPv4 addresses, loopback and link-local left out */
static int l_local_ips(lua_State *L)
{
    lua_newtable(L);
    if (!R.wsa) {
        WSADATA d;
        if (WSAStartup(MAKEWORD(2, 2), &d)) return 1;
        R.wsa = 1;
    }
    char host[256];
    if (gethostname(host, sizeof(host))) return 1;
    struct addrinfo hints = { 0 }, *res = NULL;
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_DGRAM;
    if (getaddrinfo(host, NULL, &hints, &res)) return 1;
    int n = 0;
    for (struct addrinfo *a = res; a; a = a->ai_next) {
        struct in_addr ip = ((struct sockaddr_in *)a->ai_addr)->sin_addr;
        uint32_t h = ntohl(ip.s_addr);
        if ((h >> 24) == 127 || (h >> 16) == 0xA9FE) continue;   /* loopback, link-local 169.254 */
        char buf[INET_ADDRSTRLEN];
        if (!InetNtopA(AF_INET, &ip, buf, sizeof(buf))) continue;
        lua_pushstring(L, buf);
        lua_rawseti(L, -2, ++n);
    }
    freeaddrinfo(res);
    return 1;
}

int sks_register(lua_State *L)
{
    static const luaL_Reg fns[] = { { "start", l_start }, { "stop", l_stop }, { "poll", l_poll },
                                    { "local_ips", l_local_ips }, { NULL, NULL } };
    lua_createtable(L, 0, 4);
    luaL_setfuncs(L, fns, 0);
    lua_pushinteger(L, 1);
    lua_setfield(L, -2, "version");
    lua_setglobal(L, "sks_mocap_native");
    return 0;
}

/* ---------------------------------------------------------------- REFramework */
/* the host's Lua version string, searched in its readable memory */
int sks_host_lua_matches(void *module)
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

EXPORT void reframework_plugin_required_version(REFrameworkPluginVersion *v)
{
    v->major = REFRAMEWORK_PLUGIN_VERSION_MAJOR;
    v->minor = 0;
    v->patch = 0;
}

EXPORT bool reframework_plugin_initialize(const REFrameworkPluginInitializeParam *param)
{
    ref_fn = param->functions;
    lua_ok = sks_host_lua_matches(param->reframework_module);
    if (!lua_ok) {
        ref_fn->log_error("[ShapeKeySystem_Mocap] REFramework does not use Lua 5.4.3: not registering "
                          "sks_mocap_native (面捕 falls back to the bridge script)");
        return true;
    }
    ref_fn->on_lua_state_created(on_lua_created);
    ref_fn->log_info("[ShapeKeySystem_Mocap] sks_mocap_native ready");
    return true;
}
