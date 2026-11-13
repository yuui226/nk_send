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
    @Test fun sourceDisplayLabelsRestoreImmediatelyWithoutChangingEitherRecipe() {
        val memory = MemoryPreferences()
        val store = PhotoNp3Store(memory.preferences)
        val transfer = recipe('a', 25)
        val local = recipe('b', -50)
        val transferUri = "content://photos/document/opaque-a"
        val localUri = "content://photos/document/opaque-b"
        store.save("transfer", transfer, transferUri)
        store.save("local", local, localUri)
        val label = PhotoNp3SourceLabel("我的滤镜 | 暮色", "人像\n收藏", true, 3)
        store.rememberSourceLabel(transferUri, label)
        store.rememberSourceLabel(localUri, PhotoNp3SourceLabel("Phone look", null, false, null))
        val restarted = PhotoNp3Store(memory.preferences)
        assertEquals(label, restarted.sourceLabel(transferUri))
        assertEquals("我的滤镜 | 暮色 · 人像\n收藏 · 3", restarted.sourceLabel(transferUri)?.displayName("未分类"))
        assertEquals("Phone look", restarted.sourceLabel(localUri)?.displayName("Uncategorized"))
        assertRecipe(transfer, restarted.restore("transfer"))
        assertRecipe(local, restarted.restore("local"))
        assertEquals(transferUri, restarted.uri("transfer"))
        assertEquals(localUri, restarted.uri("local"))
    }

    @Test fun sourceLabelsKeepUncategorizedLocalizedAndBuiltInCopiesDocumentNamed() {
        val memory = MemoryPreferences()
        val store = PhotoNp3Store(memory.preferences)
        val builtIn = BuiltInPhotoFilters.all.first()
        val uri = "content://photos/document/opaque"
        store.save("transfer", builtIn, uri)
        store.rememberSource(uri, checkNotNull(BuiltInPhotoFilters.catalogKey(builtIn.id)), builtIn.id)
        store.rememberSourceLabel(uri, PhotoNp3SourceLabel("User filename", null, true, 2))
        val label = checkNotNull(PhotoNp3Store(memory.preferences).sourceLabel(uri))
        assertEquals("User filename · 未分类 · 2", label.displayName("未分类"))
        assertEquals("User filename · Uncategorized · 2", label.displayName("Uncategorized"))
        assertEquals(builtIn, store.restore("transfer"))
        assertEquals(builtIn.id, store.knownPresetId(uri))
        assertEquals(mapOf(uri to builtIn.id), store.knownPresetIds(listOf(uri)))
        assertFalse(memory.values.containsKey("transfer:snapshot"))
    }

    @Test fun renamedSourceUpdatesOnlyItsDisplayHint() {
        val memory = MemoryPreferences()
        val store = PhotoNp3Store(memory.preferences)
        val uri = "content://photos/document/opaque"
        val preset = recipe('a', 10)
        store.save("transfer", preset, uri)
        store.rememberSource(uri, "a".repeat(64), preset.id)
        store.rememberSourceLabel(uri, PhotoNp3SourceLabel("Old name", null, false, null))
        val before = memory.values.filterKeys { !it.endsWith(":label") }
        store.rememberSourceLabel(uri, PhotoNp3SourceLabel("New name", "Portraits", true, null))
        assertEquals(before, memory.values.filterKeys { !it.endsWith(":label") })
        assertEquals("New name · Portraits", store.sourceLabel(uri)?.displayName("Uncategorized"))
        assertEquals(1, memory.values.keys.count { it.startsWith("source:") && it.endsWith(":label") })
    }

    @Test fun absentInvalidAndOversizedDisplayHintsNeverChangeSavedSelection() {
        val memory = MemoryPreferences()
        val store = PhotoNp3Store(memory.preferences)
        val uri = "content://photos/document/opaque"
        val preset = recipe('a', 10)
        store.save("transfer", preset, uri)
        assertNull(store.sourceLabel(uri)) // Older installs have recipes without display metadata.
        store.rememberSourceLabel(uri, PhotoNp3SourceLabel("Valid", null, false, null))
        val key = memory.values.keys.single { it.endsWith(":label") }
        for (invalid in listOf("bad", "2|VmFsaWQ=|-|0|0", "1|***|-|0|0",
            "1|VmFsaWQ=|-|0|1", "x".repeat(8193), 42)) {
            memory.values[key] = invalid
            assertNull(store.sourceLabel(uri))
            assertRecipe(preset, store.restore("transfer"))
            assertEquals(uri, store.uri("transfer"))
        }
        memory.values.remove(key)
        store.rememberSourceLabel(uri, PhotoNp3SourceLabel("x".repeat(257), null, false, null))
        assertNull(store.sourceLabel(uri))
    }

    @Test fun folderObserverIgnoresOtherKeysAndRepeatedFolderAndUnregistersWhenClosed() {
        val memory = MemoryPreferences()
        val store = PhotoNp3Store(memory.preferences)
        var changes = 0
        val observer = store.observeFolderChanges { changes++ }
        memory.preferences.edit().putString("folder", "content://photos/tree/a").apply()
        assertEquals(1, changes)
        memory.preferences.edit().putBoolean("owns_grant", true).apply()
        memory.preferences.edit().putString("transfer:id", "unrelated").apply()
        memory.preferences.edit().putString("folder", "content://photos/tree/a").apply()
        assertEquals(1, changes)
        memory.preferences.edit().putString("folder", "content://photos/tree/b").apply()
        assertEquals(2, changes)
        observer.close()
        memory.preferences.edit().putString("folder", "content://photos/tree/c").apply()
        assertEquals(2, changes)
        assertEquals(0, memory.listeners.size)
    }

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
        val listeners = mutableSetOf<SharedPreferences.OnSharedPreferenceChangeListener>()
        val preferences = Proxy.newProxyInstance(SharedPreferences::class.java.classLoader,
            arrayOf(SharedPreferences::class.java)) { _, method, args ->
            when (method.name) {
                "getAll" -> { reads++; values.toMap() }
                "edit" -> editor()
                "registerOnSharedPreferenceChangeListener" -> {
                    listeners += args!![0] as SharedPreferences.OnSharedPreferenceChangeListener; null
                }
                "unregisterOnSharedPreferenceChangeListener" -> {
                    listeners -= args!![0] as SharedPreferences.OnSharedPreferenceChangeListener; null
                }
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
                        val changed = pending.filter { (key, value) -> values[key] != value }.keys
                        pending.forEach { (key, value) -> if (value == null) values.remove(key) else values[key] = value }
                        changed.forEach { key -> listeners.toList().forEach { it.onSharedPreferenceChanged(preferences, key) } }
                        if (method.name == "commit") true else null
                    }
                    else -> error("Unexpected editor call: ${method.name}")
                }
            } as SharedPreferences.Editor
        }
    }
}
