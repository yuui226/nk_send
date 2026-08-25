package com.ztransfer.protocol

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.util.Log
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.Socket
import java.util.Collections
import java.util.concurrent.ConcurrentHashMap
import kotlin.coroutines.resume
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

/** Finds a PTP/IP camera on the LAN used by the phone-hosted hotspot/STA workflow. */
class PtpIpDiscovery(private val context: Context) {
    private data class Subnet(
        val interfaceName: String,
        val address: Inet4Address,
        val prefixLength: Int,
    )

    suspend fun discover(
        lastIp: String?,
        onProgress: (String) -> Unit,
        tryCandidate: suspend (String) -> Boolean,
    ): String? {
        val tried = HashSet<String>()
        val subnets = localSubnets()
        suspend fun tryOnce(ip: String, source: String): Boolean {
            if (!tried.add(ip)) return false
            Log.i(TAG, "candidate source=$source ip=$ip")
            onProgress(ip)
            return tryCandidate(ip)
        }

        // A saved address from a different hotspot/LAN used to enter the full Nikon handshake and
        // readiness retry, wasting more than seven seconds before discovery reached the current
        // subnet. Only probe it when it belongs to an active local subnet and port 15740 is open.
        val lastIpSubnet = lastIp?.takeIf(String::isNotBlank)?.let { savedIp ->
            subnets.firstOrNull { subnet -> subnetContains(subnet, savedIp) }
        }
        if (lastIp != null && lastIpSubnet != null &&
            isPtpPortOpen(lastIp, lastIpSubnet.address) && tryOnce(lastIp, "last_ip")
        ) return lastIp
        discoverMdns().forEach { if (tryOnce(it, "mdns")) return it }

        for (subnet in subnets) {
            Log.i(
                TAG,
                "scan iface=${subnet.interfaceName} " +
                    "address=${subnet.address.hostAddress}/${subnet.prefixLength}",
            )
            for (batch in hosts(subnet).chunked(SCAN_BATCH_SIZE)) {
                val openHosts = coroutineScope {
                    val gate = Semaphore(SCAN_CONCURRENCY)
                    batch.map { ip ->
                        async(Dispatchers.IO) {
                            gate.withPermit {
                                if (isPtpPortOpen(ip, subnet.address)) ip else null
                            }
                        }
                    }.awaitAll().filterNotNull()
                }
                for (ip in openHosts) if (tryOnce(ip, "subnet")) return ip
            }
        }
        return null
    }

    private suspend fun discoverMdns(): List<String> {
        val nsd = context.getSystemService(Context.NSD_SERVICE) as NsdManager
        val wifi = context.applicationContext
            .getSystemService(Context.WIFI_SERVICE) as WifiManager
        val multicastLock = wifi.createMulticastLock("ZTransfer:sta-discovery").apply {
            setReferenceCounted(false)
        }
        val found = ConcurrentHashMap.newKeySet<String>()
        runCatching { multicastLock.acquire() }
        try {
            for (serviceType in MDNS_SERVICE_TYPES) {
                withTimeoutOrNull(MDNS_TIMEOUT_MS) {
                    var activeListener: NsdManager.DiscoveryListener? = null
                    try {
                        suspendCancellableCoroutine<Unit> { continuation ->
                            val listener = object : NsdManager.DiscoveryListener {
                            override fun onDiscoveryStarted(type: String) = Unit

                            override fun onServiceFound(service: NsdServiceInfo) {
                                if (service.serviceType != serviceType) return
                                @Suppress("DEPRECATION")
                                nsd.resolveService(
                                    service,
                                    object : NsdManager.ResolveListener {
                                        override fun onResolveFailed(
                                            serviceInfo: NsdServiceInfo,
                                            errorCode: Int,
                                        ) = Unit

                                        override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                                            @Suppress("DEPRECATION")
                                            (serviceInfo.host as? Inet4Address)
                                                ?.hostAddress
                                                ?.let { address ->
                                                    found += address
                                                    if (continuation.isActive) {
                                                        continuation.resume(Unit)
                                                    }
                                                }
                                        }
                                    },
                                )
                            }

                            override fun onServiceLost(service: NsdServiceInfo) = Unit

                            override fun onDiscoveryStopped(type: String) {
                                if (continuation.isActive) continuation.resume(Unit)
                            }

                            override fun onStartDiscoveryFailed(type: String, errorCode: Int) {
                                runCatching { nsd.stopServiceDiscovery(this) }
                                if (continuation.isActive) continuation.resume(Unit)
                            }

                            override fun onStopDiscoveryFailed(type: String, errorCode: Int) {
                                if (continuation.isActive) continuation.resume(Unit)
                            }
                            }
                            activeListener = listener
                            nsd.discoverServices(
                                serviceType,
                                NsdManager.PROTOCOL_DNS_SD,
                                listener,
                            )
                        }
                    } finally {
                        activeListener?.let { listener ->
                            runCatching { nsd.stopServiceDiscovery(listener) }
                        }
                    }
                }
                if (found.isNotEmpty()) break
                // Let NsdManager finish stopping before starting the next service type.
                delay(100)
            }
        } catch (error: Exception) {
            Log.w(TAG, "mDNS failed: ${error.javaClass.simpleName}: ${error.message}")
        } finally {
            runCatching { if (multicastLock.isHeld) multicastLock.release() }
        }
        return found.toList()
    }

    private suspend fun localSubnets(): List<Subnet> = withContext(Dispatchers.IO) {
        Collections.list(NetworkInterface.getNetworkInterfaces())
            .asSequence()
            .filter { networkInterface ->
                runCatching {
                    networkInterface.isUp &&
                        !networkInterface.isLoopback &&
                        !networkInterface.isPointToPoint
                }.getOrDefault(false)
            }
            .flatMap { networkInterface ->
                networkInterface.interfaceAddresses.asSequence().mapNotNull { interfaceAddress ->
                    val address = interfaceAddress.address as? Inet4Address
                        ?: return@mapNotNull null
                    val prefix = interfaceAddress.networkPrefixLength.toInt()
                    if (!address.isSiteLocalAddress || prefix !in MIN_NETWORK_PREFIX..MAX_PREFIX) {
                        return@mapNotNull null
                    }
                    if (EXCLUDED_NETWORK_INTERFACE.matches(networkInterface.name)) {
                        return@mapNotNull null
                    }
                    // A phone hotspot normally allocates clients in the phone's own /24. On a
                    // broader corporate/home LAN, scanning the whole declared subnet can take
                    // minutes, so search the local /24 first and let mDNS/last-IP cover peers
                    // outside it.
                    Subnet(networkInterface.name, address, prefix.coerceAtLeast(SCAN_PREFIX))
                }
            }
            .distinctBy(::subnetKey)
            .toList()
    }

    private fun subnetKey(subnet: Subnet): String {
        val localIp = ipv4ToLong(subnet.address)
        val mask = (0xFFFFFFFFL shl (32 - subnet.prefixLength)) and 0xFFFFFFFFL
        return "${localIp and mask}/${subnet.prefixLength}"
    }

    private fun subnetContains(subnet: Subnet, candidateIp: String): Boolean {
        val candidate = parseIpv4(candidateIp) ?: return false
        val localIp = ipv4ToLong(subnet.address)
        val mask = (0xFFFFFFFFL shl (32 - subnet.prefixLength)) and 0xFFFFFFFFL
        return (candidate and mask) == (localIp and mask) && candidate != localIp
    }

    private fun parseIpv4(value: String): Long? {
        val parts = value.split('.')
        if (parts.size != 4) return null
        var result = 0L
        for (part in parts) {
            val octet = part.toIntOrNull()?.takeIf { it in 0..255 } ?: return null
            result = (result shl 8) or octet.toLong()
        }
        return result
    }

    private fun hosts(subnet: Subnet): List<String> {
        val localIp = ipv4ToLong(subnet.address)
        val mask = (0xFFFFFFFFL shl (32 - subnet.prefixLength)) and 0xFFFFFFFFL
        val network = localIp and mask
        val broadcast = network or mask.inv().and(0xFFFFFFFFL)
        val count = broadcast - network - 1
        if (count <= 0 || count > MAX_SCAN_HOSTS) return emptyList()
        return (network + 1 until broadcast)
            .asSequence()
            .filter { it != localIp }
            .map(::longToIpv4)
            .toList()
    }

    private fun isPtpPortOpen(ip: String, localAddress: Inet4Address): Boolean = runCatching {
        Socket().use { socket ->
            socket.bind(InetSocketAddress(localAddress, 0))
            socket.connect(
                InetSocketAddress(ip, PtpConstants.PTP_PORT),
                SCAN_CONNECT_TIMEOUT_MS,
            )
        }
        true
    }.getOrDefault(false)

    private fun ipv4ToLong(address: InetAddress): Long =
        address.address.fold(0L) { value, byte ->
            (value shl 8) or byte.toLong().and(0xFF)
        }

    private fun longToIpv4(value: Long): String = listOf(24, 16, 8, 0)
        .joinToString(".") { shift -> ((value shr shift) and 0xFF).toString() }

    private companion object {
        const val TAG = "ZTransfer.StaDiscovery"
        const val MDNS_TIMEOUT_MS = 1_500L
        const val SCAN_CONNECT_TIMEOUT_MS = 450
        const val SCAN_CONCURRENCY = 24
        const val SCAN_BATCH_SIZE = 48
        const val MAX_SCAN_HOSTS = 254L
        const val MIN_NETWORK_PREFIX = 8
        const val SCAN_PREFIX = 24
        const val MAX_PREFIX = 30
        val MDNS_SERVICE_TYPES = listOf("_ptp._tcp.", "_nikon._tcp.")
        val EXCLUDED_NETWORK_INTERFACE =
            Regex("(?i)^(rmnet|ccmni|pdp|wwan|tun|tap|v4-rmnet)[a-z0-9_.-]*$")
    }
}
