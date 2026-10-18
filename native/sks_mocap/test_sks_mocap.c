/* Offline test for ShapeKeySystem_Mocap: parsers, then the Lua table end to end over loopback UDP.
 * Built and run by native/build.ps1 -Test. */

#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include "sks_mocap.h"



static int fails;
#define CHECK(c, what) do { int ok_ = (c); printf("%s %s\n", ok_ ? "ok  " : "FAIL", what); if (!ok_) ++fails; } while (0)

static size_t put_str(unsigned char *p, const char *s)
{
    size_t n = strlen(s) + 1, pad = (n + 3) & ~(size_t)3;
    memset(p, 0, pad);
    memcpy(p, s, n - 1);
    return pad;
}

static void put_be32(unsigned char *p, uint32_t v)
{
    p[0] = (unsigned char)(v >> 24); p[1] = (unsigned char)(v >> 16); p[2] = (unsigned char)(v >> 8); p[3] = (unsigned char)v;
}

/* /Face message with value i/100 on channel i (jawOpen = index 24 gets `jaw`) */
static size_t face_msg(unsigned char *p, float jaw, int tags)
{
    size_t off = put_str(p, "/Face");
    char t[64] = ",";
    for (int i = 0; i < tags; ++i) strcat(t, "f");
    off += put_str(p + off, t);
    for (int i = 0; i < 52; ++i) {
        float v = i == 24 ? jaw : 0.0f;
        uint32_t b;
        memcpy(&b, &v, 4);
        put_be32(p + off, b);
        off += 4;
    }
    return off;
}

static size_t put_f(unsigned char *p, float v) { uint32_t b; memcpy(&b, &v, 4); put_be32(p, b); return 4; }

/* /VMC/Ext/Blend/Val name value */
static size_t vmc_val(unsigned char *p, const char *name, float v)
{
    size_t o = put_str(p, "/VMC/Ext/Blend/Val");
    o += put_str(p + o, ",sf");
    o += put_str(p + o, name);
    return o + put_f(p + o, v);
}

static size_t vmc_bone(unsigned char *p, const char *name, float qx, float qy, float qz, float qw)
{
    size_t o = put_str(p, "/VMC/Ext/Bone/Pos");
    o += put_str(p + o, ",sfffffff");
    o += put_str(p + o, name);
    const float f[7] = { 0.1f, 1.5f, 0.0f, qx, qy, qz, qw };
    for (int i = 0; i < 7; ++i) o += put_f(p + o, f[i]);
    return o;
}

/* bundle of the given elements */
static size_t bundle_of(unsigned char *out, unsigned char **el, size_t *len, int count)
{
    size_t o = put_str(out, "#bundle");
    memset(out + o, 0, 8); o += 8;
    for (int i = 0; i < count; ++i) { put_be32(out + o, (uint32_t)len[i]); o += 4; memcpy(out + o, el[i], len[i]); o += len[i]; }
    return o;
}

/* one VMC frame: two ARKit expressions, a non-ARKit one (Joy), the Head bone (yaw 30 deg), Apply */
static size_t vmc_frame(unsigned char *out, float blink)
{
    static unsigned char a[128], b[128], c[128], d[128], e[64];
    unsigned char *el[5] = { a, b, c, d, e };
    size_t len[5];
    len[0] = vmc_val(a, "EyeBlinkLeft", blink);
    len[1] = vmc_val(b, "jawopen", 0.3f);
    len[2] = vmc_val(c, "Joy", 1.0f);
    len[3] = vmc_bone(d, "Head", 0.0f, sinf(15.0f * 3.14159265f / 180.0f), 0.0f, cosf(15.0f * 3.14159265f / 180.0f));
    len[4] = put_str(e, "/VMC/Ext/Blend/Apply");
    len[4] += put_str(e + len[4], ",");
    return bundle_of(out, el, len, 5);
}

static void send_udp(int port, const void *data, int n)
{
    SOCKET s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    struct sockaddr_in a = { 0 };
    a.sin_family = AF_INET;
    a.sin_port = htons((u_short)port);
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    sendto(s, (const char *)data, n, 0, (struct sockaddr *)&a, sizeof(a));
    closesocket(s);
}

static int lua_check(lua_State *L, const char *code, const char *what)
{
    int ok = luaL_dostring(L, code) == LUA_OK && lua_toboolean(L, -1);
    if (!ok && lua_isstring(L, -1)) printf("     lua: %s\n", lua_tostring(L, -1));
    lua_settop(L, 0);
    CHECK(ok, what);
    return ok;
}

int main(void)
{
    WSADATA d;
    WSAStartup(MAKEWORD(2, 2), &d);
    float w[52] = { 0 }, head[6] = { 0 };
    int has_head = 0;

    /* iFacialMocap text */
    const char *ifm = "eyeBlink_L-80|jawOpen&50|mouthSmile_R-120|unknownKey-30|head#1.5,-2,3,0,0,0|leftEye#1,2,3|";
    int hits = sks_parse_ifm(ifm, (int)strlen(ifm), w, head, &has_head);
    CHECK(hits == 3, "ifm: three known shapes parsed, unknown skipped");
    CHECK(fabsf(w[8] - 0.8f) < 1e-6f && fabsf(w[24] - 0.5f) < 1e-6f, "ifm: _L suffix and & separator");
    CHECK(w[44] == 1.0f, "ifm: values clamp to 1");
    CHECK(has_head && head[0] == 1.5f && head[1] == -2.0f, "ifm: head# six numbers");
    CHECK(sks_parse_ifm("garbage", 7, w, head, &has_head) == 0, "ifm: garbage has no shapes");

    /* RhyLive OSC */
    unsigned char pkt[1024], bundle[1200];
    size_t n = face_msg(pkt, 0.75f, 52);
    memset(w, 0, sizeof(w));
    CHECK(sks_parse_osc(pkt, n, w, 0) == 1 && fabsf(w[24] - 0.75f) < 1e-6f, "osc: /Face message");
    size_t bn = put_str(bundle, "#bundle");
    memset(bundle + bn, 0, 8); bn += 8;
    unsigned char other[64];
    size_t on = put_str(other, "/Other");
    on += put_str(other + on, ",");
    put_be32(bundle + bn, (uint32_t)on); bn += 4; memcpy(bundle + bn, other, on); bn += on;
    put_be32(bundle + bn, (uint32_t)n); bn += 4; memcpy(bundle + bn, pkt, n); bn += n;
    memset(w, 0, sizeof(w));
    CHECK(sks_parse_osc(bundle, bn, w, 0) == 1 && fabsf(w[24] - 0.75f) < 1e-6f, "osc: /Face inside a bundle");
    CHECK(sks_parse_osc(other, on, w, 0) == 0, "osc: other address ignored");
    size_t n51 = face_msg(pkt, 0.5f, 51);
    CHECK(sks_parse_osc(pkt, n51, w, 0) == -1, "osc: 51 type tags rejected");
    n = face_msg(pkt, NAN, 52);
    CHECK(sks_parse_osc(pkt, n, w, 0) == -1, "osc: NaN rejected");
    CHECK(sks_parse_osc(pkt, n - 1, w, 0) == -1, "osc: unaligned length rejected");

    /* VMC */
    VmcState vs;
    memset(&vs, 0, sizeof(vs));
    memset(w, 0, sizeof(w)); memset(head, 0, sizeof(head)); has_head = 0;
    static unsigned char vf[1024];
    size_t vn = vmc_frame(vf, 0.7f);
    CHECK(sks_parse_vmc(vf, vn, &vs, w, head, &has_head) == 1, "vmc: frame committed by Blend/Apply");
    CHECK(fabsf(w[8] - 0.7f) < 1e-6f && fabsf(w[24] - 0.3f) < 1e-6f, "vmc: Perfect Sync names in any case");
    CHECK(vs.ncx == 1 && !strcmp(vs.cx[0].name, "Joy") && vs.cx[0].v == 1.0f, "vmc: other names kept as extra under their spelling");
    CHECK(has_head && fabsf(head[1] - 30.0f) < 0.01f && fabsf(head[0]) < 0.01f && fabsf(head[2]) < 0.01f,
          "vmc: Head quaternion -> yaw 30 deg");
    float w2_dummy[52] = { 0 };
    unsigned char only[128];
    size_t on2 = vmc_val(only, "eyeBlinkRight", 0.5f);
    CHECK(sks_parse_vmc(only, on2, &vs, w, head, &has_head) == 0 && w[9] == 0.0f, "vmc: values wait for the next Apply");
    unsigned char joy[128];
    size_t jn = vmc_val(joy, "Joy", 0.25f);
    CHECK(sks_parse_vmc(joy, jn, &vs, w, head, &has_head) == 0 && vs.cx[0].v == 1.0f && vs.nx == 1 && vs.x[0].v == 0.25f,
          "vmc: an extra updates in place and waits for Apply too");
    VmcState full;
    memset(&full, 0, sizeof(full));
    for (int i = 0; i < VMC_MAX_EXTRA + 5; ++i) {
        char nm[16];
        snprintf(nm, sizeof(nm), "X%d", i);
        size_t xn = vmc_val(joy, nm, 0.5f);
        sks_parse_vmc(joy, xn, &full, w2_dummy, head, &has_head);
    }
    CHECK(full.ncx == VMC_MAX_EXTRA, "vmc: extras are capped");
    VmcState nv2;
    memset(&nv2, 0, sizeof(nv2));
    float w2[52] = { 0 };
    CHECK(sks_parse_vmc(only, on2, &nv2, w2, head, &has_head) == 1 && w2[9] == 0.5f, "vmc: sender without Apply commits per packet");
    unsigned char bad[64];
    size_t bl = put_str(bad, "/VMC/Ext/Blend/Val");
    bl += put_str(bad + bl, ",si");
    bl += put_str(bad + bl, "jawOpen");
    bl += 4;
    CHECK(sks_parse_vmc(bad, bl, &vs, w, head, &has_head) == -1, "vmc: wrong argument types rejected");

    /* Lua table over loopback */
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    sks_register(L);
    lua_check(L, "return type(sks_mocap_native) == 'table' and sks_mocap_native.version == 1", "lua: global table registered");
    lua_check(L, "return not pcall(sks_mocap_native.start, 'nope')", "lua: unknown scheme is an error");
    lua_check(L, "return sks_mocap_native.start('rhylive', 49995) == true", "lua: rhylive start");
    n = face_msg(pkt, 0.6f, 52);
    send_udp(49995, pkt, (int)n);
    Sleep(50);
    lua_check(L, "T = sks_mocap_native.poll({}); return T.running and T.seq == 1 and math.abs(T.w[25] - 0.6) < 1e-6 "
                 "and T.head == nil and T.sender == '127.0.0.1'", "lua: rhylive frame reaches poll()");
    send_udp(49995, "junk", 4);
    Sleep(50);
    lua_check(L, "local t = sks_mocap_native.poll(T); return t == T and t.seq == 1 and t.rejected == 1", "lua: junk counted as rejected, table reused");
    lua_check(L, "return sks_mocap_native.start('ifacialmocap', 49996, '127.0.0.1') == true", "lua: ifm start with phone ip");
    lua_check(L, "local t = sks_mocap_native.poll(); return t.scheme == 'ifacialmocap' and t.seq == 0 and t.age_ms == -1", "lua: restart clears the old frame");
    Sleep(50);
    send_udp(49996, ifm, (int)strlen(ifm));
    Sleep(50);
    lua_check(L, "local t = sks_mocap_native.poll(); return t.seq == 1 and math.abs(t.w[9] - 0.8) < 1e-6 "
                 "and t.head and t.head[1] == 1.5 and t.rejected >= 1", "lua: ifm frame, head, trigger echo rejected");
    lua_check(L, "return not pcall(sks_mocap_native.start, 'rhylive', 0)", "lua: bad port is an error");
    lua_check(L, "return sks_mocap_native.start('vmc', 49997) == true", "lua: vmc start");
    vn = vmc_frame(vf, 0.4f);
    send_udp(49997, vf, (int)vn);
    Sleep(50);
    lua_check(L, "local t = sks_mocap_native.poll(); return t.scheme == 'vmc' and t.seq == 1 "
                 "and math.abs(t.w[9] - 0.4) < 1e-6 and t.head and math.abs(t.head[2] - 30) < 0.01 "
                 "and t.extra and t.extra.Joy == 1 and t.extra.jawopen == nil", "lua: VMC frame, head and extras reach poll()");
    lua_check(L, "sks_mocap_native.stop(); return sks_mocap_native.poll().running == false", "lua: stop");
    lua_check(L, "local ips = sks_mocap_native.local_ips(); for _, ip in ipairs(ips) do "
                 "if not ip:match('^%d+%.%d+%.%d+%.%d+$') or ip:match('^127%.') then return false end end "
                 "print('     local ips: ' .. table.concat(ips, ', ')); return true", "lua: local_ips lists IPv4 without loopback");
    lua_close(L);

    /* SKS_REF_DLL = an installed REFramework dinput8.dll: the version gate must accept it. Mapped
       without running its DllMain. */
    const char *ref = getenv("SKS_REF_DLL");
    if (ref && *ref) {
        HMODULE m = LoadLibraryExA(ref, NULL, DONT_RESOLVE_DLL_REFERENCES);
        CHECK(m != NULL && sks_host_lua_matches(m), "host: REFramework module carries Lua 5.4.3");
        CHECK(!sks_host_lua_matches(GetModuleHandleA("kernel32.dll")), "host: a module without Lua is refused");
        if (m) FreeLibrary(m);
    }
    printf("NATIVE FAILS: %d\n", fails);
    return fails ? 1 : 0;
}
