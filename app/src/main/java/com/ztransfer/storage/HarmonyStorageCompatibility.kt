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

    data class Detection(
        val enabled: Boolean,
        val manufacturer: String,
        val osBrand: String?,
        val method: String,
        val error: String? = null,
    )

    fun detect(): Detection {
        val manufacturer = Build.MANUFACTURER.orEmpty()
        if (!manufacturer.equals("HUAWEI", ignoreCase = true)) {
            return Detection(false, manufacturer, null, "manufacturer")
        }
        return try {
            val brand = Class.forName("com.huawei.system.BuildEx")
                .getMethod("getOsBrand")
                .invoke(null)
                ?.toString()
            val knownInvestigationRuntime = Build.MODEL.equals("SLY-AL00", ignoreCase = true) &&
                Build.DISPLAY.contains("104.5.0.001", ignoreCase = true)
            Detection(
                enabled = brand?.contains(HARMONY_BRAND, ignoreCase = true) == true ||
                    knownInvestigationRuntime,
                manufacturer = manufacturer,
                osBrand = brand,
                method = if (knownInvestigationRuntime && brand?.contains(HARMONY_BRAND, true) != true) {
                    "known-runtime-fallback"
                } else {
                    "BuildEx.getOsBrand"
                },
            )
        } catch (error: Throwable) {
            // Do not silently route an affected device through the unsafe SAF path.
            // The exact fallback is deliberately narrow: it covers the Harmony runtime
            // family reported by the investigation build while still leaving ordinary
            // Huawei Android devices unchanged.
            val model = Build.MODEL.orEmpty()
            val display = Build.DISPLAY.orEmpty()
            val knownInvestigationRuntime = model.equals("SLY-AL00", ignoreCase = true) &&
                display.contains("104.5.0.001", ignoreCase = true)
            Detection(
                enabled = knownInvestigationRuntime,
                manufacturer = manufacturer,
                osBrand = null,
                method = if (knownInvestigationRuntime) "known-runtime-fallback" else "BuildEx.getOsBrand",
                error = "${error.javaClass.simpleName}: ${error.message.orEmpty()}"
            )
        }
    }

}
