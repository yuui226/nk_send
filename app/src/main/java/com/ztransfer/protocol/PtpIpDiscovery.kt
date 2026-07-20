package com.ztransfer.protocol

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.Socket
import java.util.Collections
import java.util.concurrent.ConcurrentHashMap
import kotlin.coroutines.resume
import kotlinx.coroutines.suspendCancellableCoroutine

/** 手机热点模式的受限发现器：mDNS 优先，随后只扫描可识别的热点私网接口。 */
class PtpIpDiscovery(private val context: Context) {
    data class Subnet(val interfaceName: String, val address: Inet4Address, val prefixLength: Int)

    suspend fun discover(
        lastIp: String?,
        onProgress: (String) -> Unit,
        tryCandidate: suspend (String) -> Boolean
    ): String? {
        val tried = HashSet<String>()
        suspend fun tryOnce(ip: String, source: String): Boolean {
            if (!tried.add(ip)) return false
            Log.i(TAG, "DISCOVERY_CANDIDATE source=$source ip=$ip")
            onProgress("$source · $ip")
            return tryCandidate(ip)
        }

        if (!lastIp.isNullOrBlank() && tryOnce(lastIp, "last_ip")) return lastIp

        discoverMdns().forEach { if (tryOnce(it, "mdns")) return it }

        val subnets = hotspotSubnets()
        if (subnets.isEmpty()) {
            Log.w(TAG, "DISCOVERY_NO_HOTSPOT_SUBNET automatic_discovery_unavailable=true")
            return null
        }
        for (subnet in subnets) {
            Log.i(TAG, "DISCOVERY_SCAN iface=${subnet.interfaceName} address=${subnet.address.hostAddress}/${subnet.prefixLength}")
            val hosts = hosts(subnet)
            for (batch in hosts.chunked(SCAN_BATCH_SIZE)) {
                val open = coroutineScope {
                    val gate = Semaphore(SCAN_CONCURRENCY)
                    batch.map { ip ->
                        async(Dispatchers.IO) {
                            gate.withPermit { if (isPortOpen(ip)) ip else null }
                        }
                    }.awaitAll().filterNotNull()
                }
                for (ip in open) if (tryOnce(ip, "subnet_scan")) return ip
            }
        }
        return null
    }

    private suspend fun discoverMdns(): List<String> {
        val nsd = context.getSystemService(Context.NSD_SERVICE) as NsdManager
        val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        val lock = wifi.createMulticastLock("ZTransfer:ptpip-discovery").apply { setReferenceCounted(false) }
        val found = ConcurrentHashMap.newKeySet<String>()
        runCatching { lock.acquire() }
        try {
            for (type in listOf("_ptp._tcp.", "_nikon._tcp.")) {
                withTimeoutOrNull(MDNS_TIMEOUT_MS) {
                    suspendCancellableCoroutine<Unit> { continuation ->
                        val listener = object : NsdManager.DiscoveryListener {
                            override fun onDiscoveryStarted(serviceType: String) {
                                Log.i(TAG, "DISCOVERY_MDNS_START type=$serviceType")
                            }
                            override fun onServiceFound(service: NsdServiceInfo) {
                                if (service.serviceType != type) return
                                @Suppress("DEPRECATION")
                                nsd.resolveService(service, object : NsdManager.ResolveListener {
                                    override fun onResolveFailed(info: NsdServiceInfo, code: Int) {
                                        Log.w(TAG, "DISCOVERY_MDNS_RESOLVE_FAILED type=$type code=$code")
                                    }
                                    override fun onServiceResolved(info: NsdServiceInfo) {
                                        @Suppress("DEPRECATION")
                                        (info.host as? Inet4Address)?.hostAddress?.let(found::add)
                                    }
                                })
                            }
                            override fun onServiceLost(service: NsdServiceInfo) = Unit
                            override fun onDiscoveryStopped(serviceType: String) {
                                if (continuation.isActive) continuation.resume(Unit)
                            }
                            override fun onStartDiscoveryFailed(serviceType: String, code: Int) {
                                Log.w(TAG, "DISCOVERY_MDNS_START_FAILED type=$serviceType code=$code")
                                runCatching { nsd.stopServiceDiscovery(this) }
                                if (continuation.isActive) continuation.resume(Unit)
                            }
                            override fun onStopDiscoveryFailed(serviceType: String, code: Int) {
                                if (continuation.isActive) continuation.resume(Unit)
                            }
                        }
                        nsd.discoverServices(type, NsdManager.PROTOCOL_DNS_SD, listener)
                        continuation.invokeOnCancellation { runCatching { nsd.stopServiceDiscovery(listener) } }
                    }
                }
                // timeout 会触发 cancellation hook；给 NsdManager 一拍完成 stop，避免并发 discovery。
                delay(100)
            }
        } catch (e: Exception) {
            Log.w(TAG, "DISCOVERY_MDNS_EXCEPTION ${e.javaClass.simpleName}: ${e.message}")
        } finally {
            runCatching { if (lock.isHeld) lock.release() }
        }
        Log.i(TAG, "DISCOVERY_MDNS_DONE found=${found.joinToString()}")
        return found.toList()
    }

    private suspend fun hotspotSubnets(): List<Subnet> = withContext(Dispatchers.IO) {
        val interfaces = Collections.list(NetworkInterface.getNetworkInterfaces())
        interfaces.filter { iface ->
            runCatching { iface.isUp && !iface.isLoopback && !iface.isPointToPoint }.getOrDefault(false)
        }.flatMap { iface ->
            iface.interfaceAddresses.mapNotNull { ia ->
                val address = ia.address as? Inet4Address ?: return@mapNotNull null
                val prefix = ia.networkPrefixLength.toInt()
                val nameLooksLikeAp = AP_INTERFACE_PATTERN.containsMatchIn(iface.name)
                // 不凭“.1”猜测热点，避免误扫 VPN/公司网/家庭 Wi-Fi；只接受明确呈现为
                // Android AP/tether/WLAN 的接口。识别不到就安全退回 mDNS + 手工 IP。
                if (!nameLooksLikeAp || !address.isSiteLocalAddress || prefix !in MIN_PREFIX..MAX_PREFIX) return@mapNotNull null
                Subnet(iface.name, address, prefix)
            }
        }.distinctBy { "${it.interfaceName}/${it.address.hostAddress}/${it.prefixLength}" }
    }

    private fun hosts(subnet: Subnet): List<String> {
        val ip = ipv4ToLong(subnet.address)
        val mask = (0xFFFFFFFFL shl (32 - subnet.prefixLength)) and 0xFFFFFFFFL
        val network = ip and mask
        val broadcast = network or mask.inv().and(0xFFFFFFFFL)
        val count = broadcast - network - 1
        if (count <= 0 || count > MAX_SCAN_HOSTS) {
            Log.w(TAG, "DISCOVERY_SCAN_SKIPPED iface=${subnet.interfaceName} hosts=$count")
            return emptyList()
        }
        return (network + 1 until broadcast)
            .asSequence()
            .filter { it != ip }
            .map(::longToIpv4)
            .toList()
    }

    private fun isPortOpen(ip: String): Boolean = runCatching {
        Socket().use { it.connect(InetSocketAddress(ip, PtpConstants.PTP_PORT), SCAN_CONNECT_TIMEOUT_MS) }
        true
    }.getOrDefault(false)

    private fun ipv4ToLong(address: InetAddress): Long = address.address.fold(0L) { value, byte ->
        (value shl 8) or byte.toLong().and(0xFF)
    }

    private fun longToIpv4(value: Long): String = listOf(24, 16, 8, 0)
        .joinToString(".") { shift -> ((value shr shift) and 0xFF).toString() }

    companion object {
        private const val TAG = "ZTransfer.Discovery"
        private const val MDNS_TIMEOUT_MS = 1_500L
        private const val SCAN_CONNECT_TIMEOUT_MS = 600
        private const val SCAN_CONCURRENCY = 24
        private const val SCAN_BATCH_SIZE = 48
        private const val MAX_SCAN_HOSTS = 4094L
        private const val MIN_PREFIX = 20
        private const val MAX_PREFIX = 30
        private val AP_INTERFACE_PATTERN = Regex("(?i)^(ap|softap|swlan|wlan|wifi|tether)[a-z0-9_.-]*$")
    }
}
