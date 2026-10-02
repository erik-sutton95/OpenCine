#pragma once
#include <stdint.h>
#include <stddef.h>

typedef void *LunaKCP;
typedef int (*LunaKCPOutput)(const char *buf, int len, void *kcp, void *user);

LunaKCP luna_kcp_create(uint32_t conv, void *user);
void luna_kcp_release(LunaKCP k);
void luna_kcp_setoutput(LunaKCP k, LunaKCPOutput output);
int luna_kcp_nodelay(LunaKCP k, int nodelay, int interval, int resend, int nc);
int luna_kcp_wndsize(LunaKCP k, int sndwnd, int rcvwnd);
void luna_kcp_update(LunaKCP k, uint32_t current);
int luna_kcp_send(LunaKCP k, const char *buf, int len);
int luna_kcp_input(LunaKCP k, const char *data, long size);
int luna_kcp_peeksize(LunaKCP k);
int luna_kcp_recv(LunaKCP k, char *buf, int len);
void luna_kcp_jump_send(LunaKCP k, uint32_t nxt);
void luna_kcp_jump_recv(LunaKCP k, uint32_t nxt);
