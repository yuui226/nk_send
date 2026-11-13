package com.ztransfer.lut

import android.content.Context
import android.content.SharedPreferences
import android.net.Uri
import android.util.AtomicFile
import com.ztransfer.filter.CubePhotoFilterParameters
import com.ztransfer.filter.DEFAULT_PHOTO_FILTER_INTENSITY_PERCENT
import com.ztransfer.filter.PhotoFilterPreset
import com.ztransfer.filter.PhotoFilterSelection
import com.ztransfer.filter.LutAdjustments
import com.ztransfer.filter.normalizePhotoFilterIntensity
import com.ztransfer.presets.presetSourceBelongsToFolder
import kotlinx.coroutines.CancellationException
import java.io.File
import java.util.WeakHashMap
import java.util.concurrent.atomic.AtomicBoolean

/** Photo-only directory and effects. Shared URI grants are coordinated by the repository. */
internal class PhotoLutStore(context: Context) {
    private val app = context.applicationContext
    val preferences = app.getSharedPreferences("photo_lut", Context.MODE_PRIVATE)
    val folders: LutPreferences = LutPreferences(preferences, ::replaceFolder)
    private val directory = File(app.filesDir, "photo-lut-snapshots")
    internal val folderRevision: Long
        get() = try { preferences.getLong(FOLDER_REVISION, 0L) } catch (_: ClassCastException) { 0L }

    /** Only photo LUT directory state is reset; monitor preferences use the default repository. */
    private fun replaceFolder(uri: Uri, ownsGrant: Boolean): Unit = synchronized(preferences) {
        if (folders.folder == uri) {
            if (ownsGrant) folders.markFolderGrantOwned()
            return@synchronized
        }
        val keys = preferences.all.keys.filter { key ->
            key == "favorites" || key.startsWith("transfer:") || key.startsWith("local:") ||
                key.startsWith("lut_adjustments_v1:") || key.startsWith("lut_adjustments_v2:") ||
                key.startsWith("strength:")
        }
        val editor = preferences.edit()
        keys.forEach { editor.remove(it) }
        editor.putLong(FOLDER_REVISION, folderRevision + 1L)
        // One transaction prevents cold restore from observing the new directory with old state.
        folders.writeFolderTo(editor, uri, ownsGrant).apply()
        // Snapshot files are immutable and may still be owned by queued work; do not delete them.
    }

    /** A lightweight lifecycle subscription; parameter/favorite writes never invalidate a draft. */
    fun observeFolderChanges(onChanged: () -> Unit): AutoCloseable = synchronized(preferences) {
        var observed = folders.folder
        var revision = folderRevision
        val closed = AtomicBoolean(false)
        val listener = SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
            if (!closed.get() && (key == LutPreferences.FOLDER || key == FOLDER_REVISION || key == null)) {
                val current = folders.folder
                val currentRevision = folderRevision
                if (current != observed || currentRevision != revision) {
                    observed = current
                    revision = currentRevision
                    onChanged()
                }
            }
        }
        preferences.registerOnSharedPreferenceChangeListener(listener)
        AutoCloseable {
            if (closed.compareAndSet(false, true)) preferences.unregisterOnSharedPreferenceChangeListener(listener)
        }
    }

    /** Unknown legacy/provider trees remain compatible; a proven different tree cannot be restored. */
    fun isSourceCurrent(uri: String?): Boolean {
        val currentFolder = folders.folder ?: return true
        val source = uri?.let(Uri::parse) ?: return true
        return presetSourceBelongsToFolder(source, currentFolder)
    }

    /** Shares the stale-draft guard with owners before they publish a new applied recipe. */
    fun isSelectionCurrent(role: String, selection: PhotoFilterSelection?, uri: String?): Boolean = synchronized(preferences) {
        requirePhotoLutRole(role)
        if (selection == null) return@synchronized true
        if (selection.preset.parameters !is CubePhotoFilterParameters) return@synchronized false
        val digest = selection.preset.id.removePrefix("cube:")
        if (!PHOTO_LUT_DIGEST_PATTERN.matches(digest)) return@synchronized false
        if (uri != null) return@synchronized isSourceCurrent(uri)
        // A legacy recipe may have no URI. It remains valid only while this role still owns
        // its saved recipe; clearing a directory must not let an old URI-less draft restore it.
        folders.folder == null || preferences.all["$role:digest"] == digest
    }

    fun favorites(): Set<String> = preferences.getStringSet("favorites", emptySet())!!.toSet()
    fun toggleFavorite(uri: String) = synchronized(preferences) {
        if (!isSourceCurrent(uri)) return@synchronized
        val next = favorites().toMutableSet()
        if (!next.add(uri)) next.remove(uri)
        preferences.edit().putStringSet("favorites", next).apply()
    }
    fun intensity(role: String, digest: String, uri: String? = null): Int =
        remembered(role, digest, uri).intensityPercent

    fun adjustments(role: String, digest: String): LutAdjustments =
        // A standalone adjustment read may not know a legacy URI-only strength yet. Do not
        // freeze an invented default before snapshot/intensity supplies that source URI.
        remembered(role, digest, null, includeIntensity = false).adjustments

    fun rememberIntensity(role: String, digest: String, uri: String?, value: Int) = synchronized(preferences) {
        if (!isSourceCurrent(uri)) return@synchronized
        remembered(role, digest, uri)
        preferences.edit().putInt("${photoLutMemoryKey(role, digest)}:intensity",
            normalizePhotoFilterIntensity(value)).apply()
    }

    fun rememberAdjustments(role: String, digest: String, value: LutAdjustments) = synchronized(preferences) {
        remembered(role, digest, null, includeIntensity = false)
        preferences.edit().putAdjustments(photoLutMemoryKey(role, digest), value.normalized()).apply()
    }

    private fun remembered(
        role: String,
        digest: String,
        uri: String?,
        includeIntensity: Boolean = true,
    ): PhotoLutParameterMemory = synchronized(preferences) {
        val key = photoLutMemoryKey(role, digest)
        if (!isSourceCurrent(uri)) return@synchronized PhotoLutParameterMemory(DEFAULT_PHOTO_FILTER_INTENSITY_PERCENT, LutAdjustments())
        val values = preferences.all
        val restored = resolvePhotoLutParameterMemory(values, role, digest, uri)
        val migrateIntensity = includeIntensity && "$key:intensity" !in values
        val migrateAdjustments = !hasPhotoLutAdjustments(values, key)
        if (migrateIntensity || migrateAdjustments) {
            preferences.edit().apply {
                if (migrateIntensity) putInt("$key:intensity", restored.intensityPercent)
                if (migrateAdjustments) putAdjustments(key, restored.adjustments)
            }.apply()
        }
        restored
    }

    private fun SharedPreferences.Editor.putAdjustments(key: String, value: LutAdjustments): SharedPreferences.Editor =
        putInt("$key:contrast", value.contrast).putInt("$key:saturation", value.saturation)
            .putInt("$key:highlights", value.highlights).putInt("$key:shadows", value.shadows)

    private fun retainSavedParameters(role: String) {
        requirePhotoLutRole(role)
        val values = preferences.all
        val digest = (values["$role:digest"] as? String)?.takeIf(PHOTO_LUT_DIGEST_PATTERN::matches) ?: return
        if (!isSourceCurrent(values["$role:uri"] as? String)) return
        remembered(role, digest, values["$role:uri"] as? String)
    }

    fun uri(role: String): String? {
        requirePhotoLutRole(role)
        return preferences.all["$role:uri"] as? String
    }

    /** Only metadata is read on the UI thread. Table loading is lazy on the existing render worker. */
    fun restore(role: String): PhotoFilterSelection? = synchronized(preferences) {
        requirePhotoLutRole(role)
        val values = preferences.all
        if (!isSourceCurrent(values["$role:uri"] as? String)) return@synchronized null
        val digest = (values["$role:digest"] as? String)?.takeIf(PHOTO_LUT_DIGEST_PATTERN::matches) ?: return@synchronized null
        val memory = remembered(role, digest, values["$role:uri"] as? String)
        val file = File(directory, "$digest.bin")
        if (!file.isFile) return@synchronized null
        val name = values["$role:name"] as? String ?: return@synchronized null
        val parameters = synchronized(live) {
            live.keys.firstOrNull { live[it] == file.absolutePath }
                ?: CubePhotoFilterParameters.fromSnapshot(file.absolutePath) { readSnapshot(file, digest) }
                    .also { live[it] = file.absolutePath }
        }
        PhotoFilterSelection(PhotoFilterPreset("cube:$digest", name, parameters),
            normalizePhotoFilterIntensity(values["$role:strength"] as? Int ?: memory.intensityPercent),
            if (hasPhotoLutAdjustments(values, "$role:adjustments")) readPhotoLutAdjustments(values, "$role:adjustments")
            else memory.adjustments)
    }

    fun save(role: String, selection: PhotoFilterSelection?, uri: String?) = synchronized(preferences) {
        requirePhotoLutRole(role)
        if (!isSelectionCurrent(role, selection, uri)) return@synchronized
        // On upgrade Off/switch may happen before restore: retain this editor's old applied
        // values before removing its only role-specific snapshot. Existing draft memory wins.
        retainSavedParameters(role)
        preferences.edit().apply {
            if (selection == null) {
                remove("$role:digest"); remove("$role:name"); remove("$role:uri"); remove("$role:strength")
                PHOTO_LUT_ADJUSTMENT_FIELDS.forEach {
                    remove("$role:adjustments:$it")
                }
            } else {
                require(selection.preset.parameters is CubePhotoFilterParameters)
                val digest = selection.preset.id.removePrefix("cube:")
                val memoryKey = photoLutMemoryKey(role, digest)
                putString("$role:digest", digest)
                putString("$role:name", selection.preset.name)
                putString("$role:uri", uri)
                putInt("$role:strength", selection.normalizedIntensityPercent)
                putAdjustments("$role:adjustments", selection.lutAdjustments)
                putInt("$memoryKey:intensity", selection.normalizedIntensityPercent)
                putAdjustments(memoryKey, selection.lutAdjustments)
            }
        }.apply()
    }

    /** IO only; content-addressing lets pending tasks keep the exact recipe after external edits. */
    fun snapshot(role: String, file: LutFile, table: CubeLut): PhotoFilterSelection {
        requirePhotoLutRole(role)
        val sourceFolder = folders.folder
        val sourceRevision = folderRevision
        if (!isSourceCurrent(file.uri.toString())) throw CancellationException("Photo LUT folder changed")
        directory.mkdirs()
        val target = File(directory, "${table.digest}.bin")
        val digest = table.digest
        // Keep a strong owner before writing. Cleanup must retain this path, while UI restore
        // never waits for a provider-sized disk write under the live-recipe lock.
        val parameters = synchronized(live) {
            live.keys.firstOrNull { live[it] == target.absolutePath }
                ?: CubePhotoFilterParameters.fromSnapshot(target.absolutePath) { readSnapshot(target, digest) }
                    .also { live[it] = target.absolutePath }
        }
        if (!target.isFile) {
            val atomic = AtomicFile(target)
            val output = atomic.startWrite()
            try {
                PhotoLutSnapshotCodec.write(table, output)
                atomic.finishWrite(output)
            } catch (failure: Throwable) { atomic.failWrite(output); throw failure }
        }
        CubePhotoFilterParameters.seedSnapshot(target.absolutePath, table)
        val memory = synchronized(preferences) {
            if (folders.folder != sourceFolder || folderRevision != sourceRevision || !isSourceCurrent(file.uri.toString())) {
                throw CancellationException("Photo LUT folder changed")
            }
            remembered(role, table.digest, file.uri.toString())
        }
        return PhotoFilterSelection(
            PhotoFilterPreset("cube:${table.digest}", file.label.ifBlank { file.name }, parameters),
            memory.intensityPercent, memory.adjustments)
    }

    /** IO only. Recipes in editors, queues or renders are strong owners; weak tracking never pins them. */
    fun prune() = synchronized(live) {
        val retained = live.values.toSet() + listOfNotNull(
            preferences.getString("transfer:digest", null), preferences.getString("local:digest", null)
        ).map { File(directory, "$it.bin").absolutePath }
        directory.listFiles()?.filter { it.extension == "bin" && it.absolutePath !in retained }?.forEach { it.delete() }
    }

    private fun readSnapshot(file: File, digest: String): CubeLut = file.inputStream().use {
        PhotoLutSnapshotCodec.read(it, digest)
    }

    private companion object {
        const val FOLDER_REVISION = "photo_lut_folder_revision"
        val live = WeakHashMap<CubePhotoFilterParameters, String>()
    }
}
