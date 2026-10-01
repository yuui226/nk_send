package com.ztransfer.lut

import android.content.Context
import android.util.AtomicFile
import com.ztransfer.filter.CubePhotoFilterParameters
import com.ztransfer.filter.PhotoFilterPreset
import com.ztransfer.filter.PhotoFilterSelection
import com.ztransfer.filter.normalizePhotoFilterIntensity
import java.io.File
import java.util.WeakHashMap

/** Photo-only directory and effects. Shared URI grants are coordinated by the repository. */
internal class PhotoLutStore(context: Context) {
    private val app = context.applicationContext
    val preferences = app.getSharedPreferences("photo_lut", Context.MODE_PRIVATE)
    val folders = LutPreferences(preferences)
    private val directory = File(app.filesDir, "photo-lut-snapshots")

    fun favorites(): Set<String> = preferences.getStringSet("favorites", emptySet())!!.toSet()
    fun toggleFavorite(uri: String) {
        val next = favorites().toMutableSet()
        if (!next.add(uri)) next.remove(uri)
        preferences.edit().putStringSet("favorites", next).apply()
    }
    fun intensity(uri: String) = normalizePhotoFilterIntensity(preferences.getInt("strength:$uri", 80))
    fun rememberIntensity(uri: String, value: Int) {
        preferences.edit().putInt("strength:$uri", normalizePhotoFilterIntensity(value)).apply()
    }
    fun uri(role: String): String? = preferences.getString("$role:uri", null)

    /** Only metadata is read on the UI thread. Table loading is lazy on the existing render worker. */
    fun restore(role: String): PhotoFilterSelection? {
        val digest = preferences.getString("$role:digest", null)?.takeIf { it.matches(Regex("[a-f0-9]{64}")) } ?: return null
        val file = File(directory, "$digest.bin")
        if (!file.isFile) return null
        val name = preferences.getString("$role:name", null) ?: return null
        val parameters = synchronized(live) {
            live.keys.firstOrNull { live[it] == file.absolutePath }
                ?: CubePhotoFilterParameters.fromSnapshot(file.absolutePath) { readSnapshot(file, digest) }
                    .also { live[it] = file.absolutePath }
        }
        return PhotoFilterSelection(PhotoFilterPreset("cube:$digest", name, parameters),
            preferences.getInt("$role:strength", 80))
    }

    fun save(role: String, selection: PhotoFilterSelection?, uri: String?) {
        preferences.edit().apply {
            if (selection == null) {
                remove("$role:digest"); remove("$role:name"); remove("$role:uri"); remove("$role:strength")
            } else {
                require(selection.preset.parameters is CubePhotoFilterParameters)
                putString("$role:digest", selection.preset.id.removePrefix("cube:"))
                putString("$role:name", selection.preset.name)
                putString("$role:uri", uri)
                putInt("$role:strength", selection.normalizedIntensityPercent)
            }
        }.apply()
    }

    /** IO only; content-addressing lets pending tasks keep the exact recipe after external edits. */
    fun snapshot(file: LutFile, table: CubeLut): PhotoFilterSelection {
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
        return PhotoFilterSelection(PhotoFilterPreset("cube:${table.digest}", file.label.ifBlank { file.name }, parameters), intensity(file.uri.toString()))
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

    private companion object { val live = WeakHashMap<CubePhotoFilterParameters, String>() }
}
