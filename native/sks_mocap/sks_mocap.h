/* ShapeKeySystem_Mocap: parsers and Lua registration shared with the offline test. */
#ifndef SKS_MOCAP_H
#define SKS_MOCAP_H

#include <stddef.h>

#define N_FACE 52
#define N_HEAD 6

struct lua_State;

/* VMC sends one expression per message; values gather here until Blend/Apply */
typedef struct {
    float w[N_FACE];
    float head[N_HEAD];
    int head_new, dirty, seen_apply;
} VmcState;

int sks_parse_ifm(const char *p, int n, float *out, float *head, int *has_head);
int sks_parse_osc(const unsigned char *p, size_t n, float *out, int depth);
int sks_parse_vmc(const unsigned char *p, size_t n, VmcState *v, float *out, float *head, int *has_head);
int sks_register(struct lua_State *L);
int sks_host_lua_matches(void *module);

#endif
