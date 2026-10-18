/* ShapeKeySystem_Mocap: parsers and Lua registration shared with the offline test. */
#ifndef SKS_MOCAP_H
#define SKS_MOCAP_H

#include <stddef.h>

#define N_FACE 52
#define N_HEAD 6

struct lua_State;

/* expressions with other names than the ARKit 52, kept under the sender's spelling */
#define VMC_MAX_EXTRA 128
#define VMC_NAME 64
typedef struct {
    char name[VMC_NAME];
    float v;
} VmcExtra;

/* VMC sends one expression per message; values gather here until Blend/Apply */
typedef struct {
    float w[N_FACE];
    float head[N_HEAD];
    int head_new, dirty, seen_apply;
    VmcExtra x[VMC_MAX_EXTRA];    /* gathering */
    int nx;
    VmcExtra cx[VMC_MAX_EXTRA];   /* the last committed frame */
    int ncx;
} VmcState;

int sks_parse_ifm(const char *p, int n, float *out, float *head, int *has_head);
int sks_parse_osc(const unsigned char *p, size_t n, float *out, int depth);
int sks_parse_vmc(const unsigned char *p, size_t n, VmcState *v, float *out, float *head, int *has_head);
int sks_register(struct lua_State *L);
int sks_host_lua_matches(void *module);

#endif
