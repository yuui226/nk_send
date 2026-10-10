package com.ztransfer.storage

import android.os.Build

/**
 * The Harmony document provider has shown intermittent corruption when a
 * reusable protocol buffer is copied directly through SAF.  Keep the
 * compatibility path narrowly scoped: a Huawei device must also positively
 * identify the Harmony system.  If identification is unavailable, the normal
 * Android path remains unchanged.
 */
internal object HarmonyStorageCompatibility {
    private const val HARMONY_BRAND = "Harmony"

    fun isHarmonySystem(): Boolean {
        if (!Build.MANUFACTURER.equals("HUAWEI", ignoreCase = true)) return false
        val brand = runCatching {
            Class.forName("com.huawei.system.BuildEx")
                .getMethod("getOsBrand")
                .invoke(null)
                ?.toString()
        }.getOrNull()
        return brand.equals(HARMONY_BRAND, ignoreCase = true)
    }
}
