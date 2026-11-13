package com.ztransfer.grain

import android.content.SharedPreferences
import java.lang.reflect.Proxy
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PhotoGrainPreferencesTest {
    private val savedIntensities = mapOf(
        PhotoGrainStyle.FINE to 30,
        PhotoGrainStyle.MEDIUM to 50,
        PhotoGrainStyle.COARSE to 70,
    )

    @Test fun everyStyleAndItsIndependentIntensitySurviveRestartAndDisabling() {
        val memory = MemoryPreferences()
        for (style in PhotoGrainStyle.entries) {
            for (enabled in listOf(true, false)) {
                val settings = PhotoGrainSettings(savedIntensities.getValue(style), enabled, style)
                PhotoGrainPreferences(memory.preferences, "photo_grain").save(settings, savedIntensities)
                val restarted = PhotoGrainPreferences(memory.preferences, "photo_grain").load()
                assertEquals(settings, restarted.settings)
                assertEquals(savedIntensities, restarted.intensities)
                // A downgrade must restore the original fine style's strength, not another style's.
                assertEquals(30, memory.values["photo_grain_intensity"])
            }
        }
    }

    @Test fun rememberedDraftsWinOverOldCurrentIntensityAndHidingDoesNotEraseThem() {
        val memory = MemoryPreferences()
        val preferences = PhotoGrainPreferences(memory.preferences, "photo_grain")
        preferences.save(PhotoGrainSettings(80, true), normalizedPhotoGrainIntensities())
        for ((style, intensity) in savedIntensities) preferences.rememberIntensity(style, intensity)
        assertEquals("fine", memory.values["photo_grain_style"])
        assertEquals(true, memory.values["photo_grain_enabled"])
        val hidden = preferences.load(allowEnabled = false)
        assertEquals(PhotoGrainSettings(30, false, PhotoGrainStyle.FINE), hidden.settings)
        assertEquals(savedIntensities, hidden.intensities)
        val shownAfterRestart = PhotoGrainPreferences(memory.preferences, "photo_grain").load()
        assertEquals(hidden, shownAfterRestart)
        assertFalse(shownAfterRestart.settings.enabled)
    }

    @Test fun currentStyleUsesItsHistoryEvenWhenLegacyIntensityHasNotBeenCommitted() {
        val values = mapOf(
            "grain_style" to "coarse",
            "grain_enabled" to true,
            "grain_intensity" to 91,
            "grain_intensity_fine" to 30,
            "grain_intensity_medium" to 50,
            "grain_intensity_coarse" to 70,
        )
        val restored = restorePhotoGrainPreferences(values, "grain")
        assertEquals(PhotoGrainSettings(70, true, PhotoGrainStyle.COARSE), restored.settings)
        assertEquals(savedIntensities, restored.intensities)
    }

    @Test fun explicitCurrentSettingsWinWhenSavedWithoutReplacingOtherStyles() {
        val memory = MemoryPreferences()
        val preferences = PhotoGrainPreferences(memory.preferences, "grain")
        val current = PhotoGrainSettings(0, true, PhotoGrainStyle.MEDIUM)
        preferences.save(current, savedIntensities)
        val restored = preferences.load()
        assertEquals(current, restored.settings)
        assertEquals(savedIntensities + (PhotoGrainStyle.MEDIUM to 0), restored.intensities)
        assertFalse(restored.settings.isEnabled)
    }

    @Test fun legacyIntensityMigratesOnlyToFineAndExplicitOffWins() {
        for (intensity in listOf(0, 37, 100)) {
            val memory = MemoryPreferences(mutableMapOf("grain_intensity" to intensity))
            val restored = PhotoGrainPreferences(memory.preferences, "grain").load()
            assertEquals(PhotoGrainSettings(intensity, intensity > 0), restored.settings)
            assertEquals(intensity, restored.intensities[PhotoGrainStyle.FINE])
            assertEquals(40, restored.intensities[PhotoGrainStyle.MEDIUM])
            assertEquals(30, restored.intensities[PhotoGrainStyle.COARSE])
            assertEquals(restored, PhotoGrainPreferences(memory.preferences, "grain").load())
        }
        val explicitOff = restorePhotoGrainPreferences(mapOf(
            "grain_intensity" to 73, "grain_enabled" to false,
        ), "grain")
        assertEquals(PhotoGrainSettings(73, false), explicitOff.settings)
    }

    @Test fun missingAndMalformedPreferencesRecoverToSafeCanonicalValues() {
        val empty = MemoryPreferences()
        val fresh = PhotoGrainPreferences(empty.preferences, "grain").load()
        assertEquals(PhotoGrainSettings.OFF, fresh.settings)
        assertEquals(mapOf(PhotoGrainStyle.FINE to 50, PhotoGrainStyle.MEDIUM to 40,
            PhotoGrainStyle.COARSE to 30), fresh.intensities)

        val corrupt = MemoryPreferences(mutableMapOf(
            "grain_style" to "not-a-style",
            "grain_enabled" to "true",
            "grain_intensity" to "invalid",
            "grain_intensity_fine" to Float.NaN,
            "grain_intensity_medium" to Long.MAX_VALUE,
            "grain_intensity_coarse" to Long.MIN_VALUE,
        ))
        val restored = PhotoGrainPreferences(corrupt.preferences, "grain").load()
        assertEquals(PhotoGrainSettings.OFF, restored.settings)
        assertEquals(mapOf(PhotoGrainStyle.FINE to 50, PhotoGrainStyle.MEDIUM to 100,
            PhotoGrainStyle.COARSE to 0), restored.intensities)
        assertEquals(restored, PhotoGrainPreferences(corrupt.preferences, "grain").load())
        assertEquals("fine", corrupt.values["grain_style"])
        assertEquals(false, corrupt.values["grain_enabled"])

        val stringNumber = restorePhotoGrainPreferences(mapOf("grain_intensity" to " 37 "), "grain")
        assertEquals(PhotoGrainSettings(37, true), stringNumber.settings)
        val malformedSwitch = restorePhotoGrainPreferences(mapOf(
            "grain_intensity" to 37, "grain_enabled" to 1,
        ), "grain")
        assertFalse(malformedSwitch.settings.enabled)
        val newFormatMissingSwitch = restorePhotoGrainPreferences(mapOf(
            "grain_style" to "medium", "grain_intensity_medium" to 65,
        ), "grain")
        assertEquals(PhotoGrainSettings(65, false, PhotoGrainStyle.MEDIUM), newFormatMissingSwitch.settings)
    }

    @Test fun newDefaultsNeverReplacePersistedFiftyOrZeroAndOnlyFillMissingStyles() {
        for (stored in listOf(50, 0)) {
            val values = mutableMapOf<String, Any>(
                "grain_style" to "coarse", "grain_enabled" to true, "grain_intensity" to 73,
            )
            for (style in PhotoGrainStyle.entries) values["grain_intensity_${style.id}"] = stored
            val memory = MemoryPreferences(values)
            val restored = PhotoGrainPreferences(memory.preferences, "grain").load()
            assertEquals(PhotoGrainSettings(stored, true, PhotoGrainStyle.COARSE), restored.settings)
            assertEquals(PhotoGrainStyle.entries.associateWith { stored }, restored.intensities)
            assertEquals(restored, PhotoGrainPreferences(memory.preferences, "grain").load())
        }
        val partial = MemoryPreferences(mutableMapOf(
            "grain_style" to "coarse", "grain_enabled" to true,
            "grain_intensity_fine" to 0, "grain_intensity_medium" to 50,
        ))
        val restored = PhotoGrainPreferences(partial.preferences, "grain").load()
        assertEquals(PhotoGrainSettings(30, true, PhotoGrainStyle.COARSE), restored.settings)
        assertEquals(mapOf(PhotoGrainStyle.FINE to 0, PhotoGrainStyle.MEDIUM to 50,
            PhotoGrainStyle.COARSE to 30), restored.intensities)
    }

    @Test fun zeroIsARealValueForAllStyles() {
        val memory = MemoryPreferences()
        val preferences = PhotoGrainPreferences(memory.preferences, "grain")
        preferences.load()
        for (style in PhotoGrainStyle.entries) preferences.rememberIntensity(style, 0)
        val restored = preferences.load()
        assertEquals(PhotoGrainStyle.entries.associateWith { 0 }, restored.intensities)
        assertEquals(0, restored.settings.intensityPercent)
        assertFalse(restored.settings.enabled)
    }

    @Test fun cameraAndPhoneNamespacesNeverOverwriteEachOther() {
        // Even if accidentally given the same file, their namespaces remain independent.
        val memory = MemoryPreferences()
        val camera = PhotoGrainPreferences(memory.preferences, "photo_grain")
        val phone = PhotoGrainPreferences(memory.preferences, "grain")
        camera.save(PhotoGrainSettings(70, true, PhotoGrainStyle.COARSE), savedIntensities)
        phone.save(PhotoGrainSettings(12, false, PhotoGrainStyle.MEDIUM),
            mapOf(PhotoGrainStyle.FINE to 0, PhotoGrainStyle.COARSE to 95))
        phone.rememberIntensity(PhotoGrainStyle.COARSE, 90)
        assertEquals(PhotoGrainSettings(70, true, PhotoGrainStyle.COARSE), camera.load().settings)
        assertEquals(savedIntensities, camera.load().intensities)
        assertEquals(PhotoGrainSettings(12, false, PhotoGrainStyle.MEDIUM), phone.load().settings)
        assertEquals(mapOf(PhotoGrainStyle.FINE to 0, PhotoGrainStyle.MEDIUM to 12,
            PhotoGrainStyle.COARSE to 90), phone.load().intensities)
    }

    @Test fun writeToKeepsLocalSettingsAndAllStyleMemoriesInOneEditor() {
        val memory = MemoryPreferences()
        val editor = memory.preferences.edit().putBoolean("another_control", true)
        PhotoGrainPreferences(memory.preferences, "grain").writeTo(editor,
            PhotoGrainSettings(70, false, PhotoGrainStyle.COARSE), savedIntensities)
        assertTrue(memory.values.isEmpty())
        editor.apply()
        assertEquals(true, memory.values["another_control"])
        assertEquals(savedIntensities, PhotoGrainPreferences(memory.preferences, "grain").load().intensities)
    }

    private class MemoryPreferences(val values: MutableMap<String, Any> = mutableMapOf()) {
        val preferences: SharedPreferences = Proxy.newProxyInstance(
            SharedPreferences::class.java.classLoader,
            arrayOf(SharedPreferences::class.java),
        ) { _, method, _ ->
            when (method.name) {
                "getAll" -> values.toMap()
                "edit" -> editor()
                else -> error("Unexpected SharedPreferences call: ${method.name}")
            }
        } as SharedPreferences

        private fun editor(): SharedPreferences.Editor {
            val pending = mutableMapOf<String, Any>()
            return Proxy.newProxyInstance(SharedPreferences.Editor::class.java.classLoader,
                arrayOf(SharedPreferences.Editor::class.java)) { self, method, args ->
                when (method.name) {
                    "putString", "putBoolean", "putInt" -> {
                        pending[args!![0] as String] = args[1]!!
                        self
                    }
                    "apply" -> { values.putAll(pending); null }
                    "commit" -> { values.putAll(pending); true }
                    else -> error("Unexpected Editor call: ${method.name}")
                }
            } as SharedPreferences.Editor
        }
    }
}
