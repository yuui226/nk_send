package com.ztransfer.filter

import android.content.SharedPreferences
import java.lang.reflect.Proxy
import java.util.Base64
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

class PhotoNp3StoreTest {
    @Test fun classicAndFlexibleDirectoriesAndEditorsShareHintsButKeepIndependentSnapshots() {
        val memory = MemoryPreferences()
        val store = PhotoNp3Store(memory.preferences)
        val classic = PhotoFilterPreset("np3:${"c".repeat(64)}:np3-classic-srgb-v1", "Classic",
            ClassicNp3PhotoFilterParameters(ClassicNp3Style.entries.first(), 8, 2, 4, -3,
                0, 0, 0, 100, IntArray(257) { it * 32767 / 256 }))
        val flexible = recipe('a', 10)
        val uri = "content://photos/classic.NP3"
        store.save("local", classic, uri)
        store.save("transfer", flexible, "content://photos/flexible.NP3")
        store.rememberSource(uri, "c".repeat(64), classic.id)
        val restarted = PhotoNp3Store(memory.preferences)
        val restored = requireNotNull(restarted.restore("local"))
        assertEquals(classic.id, restored.id)
        assertArrayEquals((classic.parameters as ClassicNp3PhotoFilterParameters).toneCurve,
            (restored.parameters as ClassicNp3PhotoFilterParameters).toneCurve)
        assertEquals(classic.id, restarted.knownPresetId(uri))
        assertEquals(mapOf(uri to classic.id), restarted.knownPresetIds(listOf(uri)))
        assertRecipe(flexible, restarted.restore("transfer"))
        store.save("local", null, null)
        assertEquals(classic.id, store.knownPresetId(uri))
        memory.values["local:id"] = classic.id
        memory.values["local:snapshot"] = memory.values.getValue("transfer:snapshot")
        assertNull(store.restore("local"))
    }
    @Test fun independentCurrentRecipesRestoreWithoutAnyExternalSource() {
        val memory = MemoryPreferences()
        val store = PhotoNp3Store(memory.preferences)
        val transfer = recipe('a', 25)
        val local = recipe('b', -50)
        store.save("transfer", transfer, "content://photos/transfer.NP3")
        store.save("local", local, "content://photos/local.NP3")
        val restarted = PhotoNp3Store(memory.preferences)
        assertRecipe(transfer, restarted.restore("transfer"))
        assertRecipe(local, restarted.restore("local"))
        assertEquals("content://photos/transfer.NP3", restarted.uri("transfer"))
        assertEquals("content://photos/local.NP3", restarted.uri("local"))
        restarted.save("local", null, null)
        assertNull(restarted.restore("local"))
        assertNull(restarted.uri("local"))
        assertRecipe(transfer, restarted.restore("transfer"))
    }

    @Test fun identicalBuiltInSourceRetainsItsIdentityAndNeedsNoCustomSnapshot() {
        val memory = MemoryPreferences()
        val store = PhotoNp3Store(memory.preferences)
        val builtIn = BuiltInPhotoFilters.all.first()
        val uri = "content://photos/builtin.NP3"
        store.rememberSource(uri, checkNotNull(BuiltInPhotoFilters.catalogKey(builtIn.id)), builtIn.id)
        store.save("transfer", recipe('a', 10), uri)
        store.save("transfer", builtIn, uri)
        assertEquals(builtIn, store.restore("transfer"))
        assertEquals(builtIn.id, store.knownPresetId(uri))
        assertFalse(memory.values.containsKey("transfer:snapshot"))
        assertEquals(uri, store.uri("transfer"))
    }

    @Test fun sourceHintsSurviveDisablingButContentIdentityChangesAfterSuccessfulRead() {
        val memory = MemoryPreferences()
        val store = PhotoNp3Store(memory.preferences)
        val uri = "content://photos/edited.NP3"
        val old = recipe('a', 10)
        val updated = recipe('b', 20)
        store.rememberSource(uri, "a".repeat(64), old.id)
        store.save("local", old, uri)
        store.save("local", null, null)
        assertEquals(old.id, store.knownPresetId(uri))
        store.rememberSource(uri, "b".repeat(64), updated.id)
        assertEquals(updated.id, PhotoNp3Store(memory.preferences).knownPresetId(uri))
    }

    @Test fun directorySourceHintsUseOnePreferenceSnapshotRegardlessOfFileCount() {
        val memory = MemoryPreferences()
        val store = PhotoNp3Store(memory.preferences)
        val preset = recipe('a', 10)
        val uris = (0 until 200).map { "content://photos/$it.NP3" }
        uris.take(100).forEach { store.rememberSource(it, "a".repeat(64), preset.id) }
        val before = memory.reads
        val hints = store.knownPresetIds(uris)
        assertEquals(before + 1, memory.reads)
        assertEquals(uris.take(100).associateWith { preset.id }, hints)
    }

    @Test fun missingCorruptMismatchedAndOversizedPrivateRecipesNeverRestore() {
        val memory = MemoryPreferences()
        val store = PhotoNp3Store(memory.preferences)
        val preset = recipe('a', 10)
        store.save("transfer", preset, "content://photos/one.NP3")
        val original = memory.values["transfer:snapshot"] as String
        for (bad in listOf("not base64!", Base64.getEncoder().encodeToString(byteArrayOf(1)),
            "a".repeat(PhotoNp3SnapshotCodec.MAX_BYTES * 2), 123)) {
            memory.values["transfer:snapshot"] = bad
            assertNull(store.restore("transfer"))
        }
        memory.values["transfer:snapshot"] = original
        memory.values["transfer:id"] = recipe('b', 20).id
        assertNull(store.restore("transfer"))
        memory.values.remove("transfer:snapshot")
        assertNull(store.restore("transfer"))
    }

    private fun assertRecipe(expected: PhotoFilterPreset, actual: PhotoFilterPreset?) {
        assertEquals(expected.id, actual?.id)
        assertEquals(expected.name, actual?.name)
        val expectedParameters = expected.parameters as Np3PhotoFilterParameters
        val actualParameters = actual!!.parameters as Np3PhotoFilterParameters
        assertEquals(expectedParameters.copy(toneCurve = null), actualParameters.copy(toneCurve = null))
        assertArrayEquals(expectedParameters.toneCurve, actualParameters.toneCurve)
    }

    private fun recipe(digest: Char, contrast: Int) = PhotoFilterPreset(
        "np3:${digest.toString().repeat(64)}:np3-srgb-v1", "Fixture $digest", Np3PhotoFilterParameters(
            contrast, 0, 0, 0, 0, 0,
            PHOTO_FILTER_COLOR_BAND_CENTERS.map { PhotoFilterColorBand(it, 0, 0, 0) },
            IntArray(257) { it * 32767 / 256 },
        ),
    )

    private class MemoryPreferences(val values: MutableMap<String, Any> = mutableMapOf()) {
        var reads = 0
        val preferences = Proxy.newProxyInstance(SharedPreferences::class.java.classLoader,
            arrayOf(SharedPreferences::class.java)) { _, method, _ ->
            when (method.name) {
                "getAll" -> { reads++; values.toMap() }
                "edit" -> editor()
                else -> error("Unexpected preference call: ${method.name}")
            }
        } as SharedPreferences

        private fun editor(): SharedPreferences.Editor {
            val pending = mutableMapOf<String, Any?>()
            return Proxy.newProxyInstance(SharedPreferences.Editor::class.java.classLoader,
                arrayOf(SharedPreferences.Editor::class.java)) { self, method, args ->
                when (method.name) {
                    "putString", "putBoolean" -> { pending[args!![0] as String] = args[1]; self }
                    "remove" -> { pending[args!![0] as String] = null; self }
                    "apply", "commit" -> {
                        pending.forEach { (key, value) -> if (value == null) values.remove(key) else values[key] = value }
                        if (method.name == "commit") true else null
                    }
                    else -> error("Unexpected editor call: ${method.name}")
                }
            } as SharedPreferences.Editor
        }
    }
}
