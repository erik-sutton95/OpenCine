package com.opencapture.opencine.core

/**
 * The phone's IPv4 subnet on a station network, as a bounded list of hosts to look for cameras on.
 * Swift twin: `StationSubnet`.
 */
public object StationSubnet {
    /**
     * Every unicast host of [address]'s subnet except [address] and [excluding], in address order;
     * null for a malformed address or mask, a non-contiguous mask, or a subnet with more than 1,022
     * hosts or fewer than two.
     */
    public fun hosts(address: String, mask: String, excluding: Set<String> = emptySet()): List<String>? {
        val ip = parse(address) ?: return null
        val netmask = parse(mask) ?: return null
        val hostBits = netmask.inv() and 0xFFFF_FFFFL
        if (hostBits <= 1L || hostBits > 1023L || (hostBits and (hostBits + 1)) != 0L) return null
        val network = ip and netmask
        return (1 until hostBits).mapNotNull { offset ->
            val value = network or offset
            val host = listOf(24, 16, 8, 0).joinToString(".") { ((value shr it) and 255).toString() }
            if (value == ip || host in excluding) null else host
        }
    }

    /** A dotted IPv4 unicast address a camera can hold: not 0.x, loopback or multicast and above. */
    public fun validAddress(value: String): Boolean {
        val address = parse(value) ?: return false
        val first = address shr 24
        return first in 1L..223L && first != 127L
    }

    private fun parse(string: String): Long? {
        val parts = string.split(".")
        if (parts.size != 4) return null
        var value = 0L
        for (part in parts) {
            if (part.isEmpty() || part.length > 3 || !part.all { it in '0'..'9' }) return null
            val byte = part.toInt()
            if (byte > 255) return null
            value = (value shl 8) or byte.toLong()
        }
        return value
    }
}
