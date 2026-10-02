#pragma once
#include <stdint.h>

/// Add 192.168.42.253/24 to an existing interface. Returns 0 or -errno.
int luna_add_ipv4_alias(const char *ifname, const char *ip, const char *mask);
