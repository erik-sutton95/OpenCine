#include "luna_ifaddr.h"

#include <arpa/inet.h>
#include <errno.h>
#include <net/if.h>
#include <netinet/in.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <unistd.h>

int luna_add_ipv4_alias(const char *ifname, const char *ip, const char *mask) {
    if (!ifname || !ip || !mask) return -EINVAL;
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) return -errno;

    struct ifaliasreq ifra;
    memset(&ifra, 0, sizeof(ifra));
    strlcpy(ifra.ifra_name, ifname, sizeof(ifra.ifra_name));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_len = sizeof(addr);
    addr.sin_family = AF_INET;
    if (inet_pton(AF_INET, ip, &addr.sin_addr) != 1) {
        close(fd);
        return -EINVAL;
    }
    memcpy(&ifra.ifra_addr, &addr, sizeof(addr));

    struct sockaddr_in netmask;
    memset(&netmask, 0, sizeof(netmask));
    netmask.sin_len = sizeof(netmask);
    netmask.sin_family = AF_INET;
    if (inet_pton(AF_INET, mask, &netmask.sin_addr) != 1) {
        close(fd);
        return -EINVAL;
    }
    memcpy(&ifra.ifra_mask, &netmask, sizeof(netmask));

    struct sockaddr_in broad;
    memset(&broad, 0, sizeof(broad));
    broad.sin_len = sizeof(broad);
    broad.sin_family = AF_INET;
    broad.sin_addr.s_addr = addr.sin_addr.s_addr | ~netmask.sin_addr.s_addr;
    memcpy(&ifra.ifra_broadaddr, &broad, sizeof(broad));

    int rc = ioctl(fd, SIOCAIFADDR, &ifra);
    int err = rc == 0 ? 0 : -errno;
    close(fd);
    return err;
}
