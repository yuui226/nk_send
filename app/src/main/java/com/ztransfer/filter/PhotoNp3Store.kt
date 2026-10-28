package com.ztransfer.filter

import android.content.Context
import android.content.SharedPreferences
import android.net.Uri
import com.ztransfer.presets.presetSourceBelongsToFolder
import java.security.MessageDigest
import java.util.Base64

/** Shared source directory; transfer and phone editors save their current recipes independently. */
internal class PhotoNp3Store internal constructor(private val preferences: SharedPreferences) {
    constructor(context: Context) : this(context.applicationContext.getSharedPreferences("photo_np3", Context.MODE_PRIVATE))

    val folders = PhotoNp3FolderPreferences(preferences)

    /** Keep the returned handle while observing; SharedPreferences keeps listeners weakly. */
    fun observeFolderChanges(onChanged: () -> Unit): AutoCloseable {
        var previous = preferences.all["folder"] as? String
        val listener = SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
            if (key == "folder" || key == null) {
                val current = preferences.all["folder"] as? String
                if (current != previous) {
                    previous = current
                    onChanged()
                }
            }
        }
        preferences.registerOnSharedPreferenceChangeListener(listener)
        return AutoCloseable { preferences.unregisterOnSharedPreferenceChangeListener(listener) }
    }

    fun restore(role: String): PhotoFilterPreset? {
        val values = preferences.all
        val id = values["$role:id"] as? String ?: return null
        BuiltInPhotoFilters.all.firstOrNull { it.id == id }?.let { return it }
        if (!PhotoNp3SnapshotCodec.isCustomId(id)) return null
        if (!sourceMatchesFolder(values["$role:uri"] as? String, values)) return null
        val encoded = values["$role:snapshot"] as? String ?: return null
        if (encoded.length > PhotoNp3SnapshotCodec.MAX_BYTES * 4 / 3 + 4) return null
        return runCatching { PhotoNp3SnapshotCodec.decode(Base64.getDecoder().decode(encoded)) }
            .getOrNull()?.takeIf { it.id == id }
    }

    fun uri(role: String): String? {
        val values = preferences.all
        return (values["$role:uri"] as? String)?.takeIf(::validSourceUri)
            ?.takeIf { sourceMatchesFolder(it, values) }
    }

    fun savedId(role: String): String? = preferences.all["$role:id"] as? String

    /** Shared guard for an owner committing a retained draft after a directory replacement. */
    fun isSelectionCurrent(role: String, preset: PhotoFilterPreset?, uri: String?): Boolean =
        isSelectionCurrent(role, preset, uri, preferences.all)

    private fun isSelectionCurrent(
        role: String,
        preset: PhotoFilterPreset?,
        uri: String?,
        values: Map<String, *>,
    ): Boolean {
        if (preset == null || !PhotoNp3SnapshotCodec.isCustomId(preset.id)) return true
        if (!sourceMatchesFolder(uri, values)) return false
        return uri != null || values["folder"] == null ||
            values["$role:id"] == preset.id && sourceMatchesFolder(values["$role:uri"] as? String, values)
    }

    /** Only bounded preference data is written here; source reads belong to the preset IO worker. */
    fun save(role: String, preset: PhotoFilterPreset?, uri: String?) {
        require(role == "transfer" || role == "local")
        val custom = preset?.takeIf { PhotoNp3SnapshotCodec.isCustomId(it.id) }
        val builtIn = preset?.takeIf { BuiltInPhotoFilters.catalogKey(it.id) != null }
        require(preset == null || custom != null || builtIn != null)
        val values = preferences.all
        // An outgoing editor can save after a different entry has replaced the directory.
        // Ignore that stale custom draft rather than overwriting the new entry's selection.
        if (!isSelectionCurrent(role, preset, uri, values)) return
        val currentUri = uri?.takeIf(::validSourceUri)?.takeIf { sourceMatchesFolder(it, values) }
        val snapshot = custom?.let { Base64.getEncoder().encodeToString(PhotoNp3SnapshotCodec.encode(it)) }
        preferences.edit().apply {
            if (preset == null) {
                remove("$role:id"); remove("$role:uri"); remove("$role:snapshot")
            } else {
                putString("$role:id", preset.id)
                if (currentUri != null) putString("$role:uri", currentUri) else remove("$role:uri")
                if (snapshot != null) putString("$role:snapshot", snapshot) else remove("$role:snapshot")
            }
        }.apply()
    }

    /** Hints describe the last successful read; selecting a row always reads its current bytes. */
    fun rememberSource(uri: String, sourceSha256: String, presetId: String) {
        require(validSourceUri(uri) && digestPattern.matches(sourceSha256))
        require(photoNp3SourceSha256(presetId) == sourceSha256 ||
            BuiltInPhotoFilters.catalogKey(presetId) == sourceSha256)
        if (!sourceMatchesFolder(uri, preferences.all)) return
        preferences.edit().putString(sourceKey(uri), "$sourceSha256|$presetId").apply()
    }

    fun knownPresetId(uri: String): String? {
        return decodeSourceHint(preferences.all[sourceKey(uri)] as? String)
    }

    /** One preference snapshot for a whole directory, normally called on the preset IO worker. */
    fun knownPresetIds(uris: Iterable<String>, checkpoint: () -> Unit = {}): Map<String, String> {
        val values = preferences.all
        return buildMap {
            for (uri in uris) {
                checkpoint()
                decodeSourceHint(values[sourceKey(uri)] as? String)?.let { put(uri, it) }
            }
        }
    }

    private fun decodeSourceHint(encoded: String?): String? {
        if (encoded == null) return null
        val parts = encoded.split('|')
        if (parts.size != 2 || !digestPattern.matches(parts[0])) return null
        return parts[1].takeIf { photoNp3SourceSha256(it) == parts[0] ||
            BuiltInPhotoFilters.catalogKey(it) == parts[0] }
    }

    private fun sourceKey(uri: String): String = "source:" + MessageDigest.getInstance("SHA-256")
        .digest(uri.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }

    private fun sourceMatchesFolder(uri: String?, values: Map<String, *>): Boolean {
        val folder = values["folder"] as? String ?: return true
        if (uri == null) return true // Legacy private recipes may not have a source URI.
        return validSourceUri(uri) && presetSourceBelongsToFolder(Uri.parse(uri), Uri.parse(folder))
    }

    private companion object {
        val digestPattern = Regex("[a-f0-9]{64}")
        fun validSourceUri(uri: String): Boolean = uri.length in 1..16_384 && uri.startsWith("content://")
    }
}

internal class PhotoNp3FolderPreferences(private val preferences: SharedPreferences) {
    val folder: Uri? get() = (preferences.all["folder"] as? String)?.let(Uri::parse)
    val ownsFolderGrant: Boolean get() = preferences.all["owns_grant"] as? Boolean ?: false
    fun replaceFolder(uri: Uri, ownsGrant: Boolean) {
        val values = preferences.all
        val previous = values["folder"] as? String
        val changed = previous != null && previous != uri.toString()
        preferences.edit().apply {
            if (changed) {
                values.keys.filter { it.startsWith("source:") }.forEach(::remove)
                for (role in listOf("transfer", "local")) {
                    val id = values["$role:id"] as? String
                    // Matching an imported source to a built-in must never erase the built-in.
                    if (id == null || BuiltInPhotoFilters.catalogKey(id) == null) remove("$role:id")
                    remove("$role:uri")
                    remove("$role:snapshot")
                }
            }
            putString("folder", uri.toString())
            putBoolean("owns_grant", ownsGrant)
        }.apply()
    }
    fun markFolderGrantOwned() { preferences.edit().putBoolean("owns_grant", true).apply() }
    fun retainSharedGrant(uri: Uri): Boolean = (folder == uri).also { shared ->
        if (shared) markFolderGrantOwned()
    }
}
