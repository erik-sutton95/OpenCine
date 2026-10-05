package com.opencapture.opencine.media

import java.net.Inet4Address
import java.net.InetAddress
import java.net.NetworkInterface
import java.net.URI
import java.net.URL
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * The JDK date, address and interface calls behind the diagnostics wire, so the Android app shell
 * reads them as values. A fresh formatter per call: SimpleDateFormat is not thread-safe.
 */
public object DiagnosticWire {
    /** The parts of a URI, or of a URL with its protocol as [scheme]; absent parts are null. */
    public data class Address(
        public val scheme: String?,
        public val host: String?,
        public val userInfo: String?,
        public val path: String?,
        public val query: String?,
        public val fragment: String?,
    )

    /** `yyyy-MM-dd'T'HH:mm:ss'Z'` in UTC. */
    public fun isoSeconds(ms: Long): String = isoSecondsFormat().format(Date(ms))

    /** Reads [isoSeconds] back (lenient, like SimpleDateFormat's default); null when unreadable. */
    public fun parseIsoSeconds(raw: String): Long? = runCatching { isoSecondsFormat().parse(raw)?.time }.getOrNull()

    /** `yyyy-MM-dd'T'HH:mm:ss.SSS'Z'` in UTC. */
    public fun isoMillis(ms: Long): String =
        SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US).apply {
            timeZone = TimeZone.getTimeZone("UTC")
        }.format(Date(ms))

    /** A strict RFC 1123 HTTP-date, as in Retry-After; null when unreadable. */
    public fun parseHttpDate(raw: String): Long? =
        runCatching {
            SimpleDateFormat("EEE, dd MMM yyyy HH:mm:ss zzz", Locale.US).apply {
                timeZone = TimeZone.getTimeZone("GMT")
                isLenient = false
            }.parse(raw)?.time
        }.getOrNull()

    /** [raw] as a java.net.URI; null when it is not one. */
    public fun uri(raw: String): Address? =
        runCatching { URI(raw) }.getOrNull()?.let { Address(it.scheme, it.host, it.userInfo, it.path, it.query, it.fragment) }

    /** [raw] as a java.net.URL; null when it is not one. URL's own parser, which URI.toURL() is stricter than. */
    @Suppress("DEPRECATION")
    public fun url(raw: String): Address? =
        runCatching { URL(raw) }.getOrNull()?.let { Address(it.protocol, it.host, it.userInfo, it.path, it.query, it.ref) }

    /** The dotted IPv4 form of [address], or null when it is not IPv4. */
    public fun ipv4(address: InetAddress?): String? = (address as? Inet4Address)?.hostAddress

    /** IPv4 addresses on this device's interfaces, in interface order; empty when unreadable. */
    public fun localIPv4Addresses(): Sequence<String> =
        sequence {
            val interfaces = runCatching { NetworkInterface.getNetworkInterfaces() }.getOrNull() ?: return@sequence
            for (networkInterface in interfaces) {
                val addresses = runCatching { networkInterface.inetAddresses }.getOrNull() ?: continue
                for (address in addresses) ipv4(address)?.let { yield(it) }
            }
        }

    private fun isoSecondsFormat(): SimpleDateFormat =
        SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US).apply { timeZone = TimeZone.getTimeZone("UTC") }
}
