#include "luna_kcp.h"
#include "ikcp.h"

LunaKCP luna_kcp_create(uint32_t conv, void *user) { return ikcp_create(conv, user); }
void luna_kcp_release(LunaKCP k) {
    if (k) ikcp_release((ikcpcb *)k);
}
void luna_kcp_setoutput(LunaKCP k, LunaKCPOutput output) {
    if (k) ikcp_setoutput((ikcpcb *)k, (int (*)(const char *, int, ikcpcb *, void *))output);
}
int luna_kcp_nodelay(LunaKCP k, int nodelay, int interval, int resend, int nc) {
    return k ? ikcp_nodelay((ikcpcb *)k, nodelay, interval, resend, nc) : -1;
}
int luna_kcp_wndsize(LunaKCP k, int sndwnd, int rcvwnd) {
    return k ? ikcp_wndsize((ikcpcb *)k, sndwnd, rcvwnd) : -1;
}
void luna_kcp_update(LunaKCP k, uint32_t current) {
    if (k) ikcp_update((ikcpcb *)k, current);
}
int luna_kcp_send(LunaKCP k, const char *buf, int len) {
    return k ? ikcp_send((ikcpcb *)k, buf, len) : -1;
}
int luna_kcp_input(LunaKCP k, const char *data, long size) {
    return k ? ikcp_input((ikcpcb *)k, data, size) : -1;
}
int luna_kcp_peeksize(LunaKCP k) { return k ? ikcp_peeksize((ikcpcb *)k) : -1; }
int luna_kcp_recv(LunaKCP k, char *buf, int len) {
    return k ? ikcp_recv((ikcpcb *)k, buf, len) : -1;
}
void luna_kcp_jump_send(LunaKCP k, uint32_t nxt) {
    ikcpcb *p = (ikcpcb *)k;
    if (!p || nxt == 0) return;
    if (nxt > p->snd_nxt) {
        p->snd_una = nxt;
        p->snd_nxt = nxt;
    }
}
void luna_kcp_jump_recv(LunaKCP k, uint32_t nxt) {
    ikcpcb *p = (ikcpcb *)k;
    if (!p || nxt == 0) return;
    if (p->rcv_nxt == 0 || nxt > p->rcv_nxt) p->rcv_nxt = nxt;
}
