package com.ztransfer.filter

import android.content.Context
import android.content.SharedPreferences
import android.net.Uri
import java.security.MessageDigest
import java.util.Base64

/** Shared source directory; transfer and phone editors save their current recipes independently. */
internal class PhotoNp3Store internal constructor(private val preferences: SharedPreferences) {
    constructor(context: Context) : this(context.applicationContext.getSharedPreferences("photo_np3", Context.MODE_PRIVATE))

    val folders = PhotoNp3FolderPreferences(preferences)

    fun restore(role: String): PhotoFilterPreset? {
        val values = preferences.all
        val id = values["$role:id"] as? String ?: return null
        BuiltInPhotoFilters.all.firstOrNull { it.id == id }?.let { return it }
        if (!PhotoNp3SnapshotCodec.isCustomId(id)) return null
        val encoded = values["$role:snapshot"] as? String ?: return null
        if (encoded.length > PhotoNp3SnapshotCodec.MAX_BYTES * 4 / 3 + 4) return null
        return runCatching { PhotoNp3SnapshotCodec.decode(Base64.getDecoder().decode(encoded)) }
            .getOrNull()?.takeIf { it.id == id }
    }

    fun uri(role: String): String? = (preferences.all["$role:uri"] as? String)?.takeIf(::validSourceUri)

    fun savedId(role: String): String? = preferences.all["$role:id"] as? String

    /** Only bounded preference data is written here; source reads belong to the preset IO worker. */
    fun save(role: String, preset: PhotoFilterPreset?, uri: String?) {
        require(role == "transfer" || role == "local")
        val custom = preset?.takeIf { PhotoNp3SnapshotCodec.isCustomId(it.id) }
        val builtIn = preset?.takeIf { BuiltInPhotoFilters.catalogKey(it.id) != null }
        require(preset == null || custom != null || builtIn != null)
        val snapshot = custom?.let { Base64.getEncoder().encodeToString(PhotoNp3SnapshotCodec.encode(it)) }
        preferences.edit().apply {
            if (preset == null) {
                remove("$role:id"); remove("$role:uri"); remove("$role:snapshot")
            } else {
                putString("$role:id", preset.id)
                if (uri != null && validSourceUri(uri)) putString("$role:uri", uri) else remove("$role:uri")
                if (snapshot != null) putString("$role:snapshot", snapshot) else remove("$role:snapshot")
            }
        }.apply()
    }

    /** Hints describe the last successful read; selecting a row always reads its current bytes. */
    fun rememberSource(uri: String, sourceSha256: String, presetId: String) {
        require(validSourceUri(uri) && digestPattern.matches(sourceSha256))
        require(presetId == "np3:$sourceSha256:${PhotoNp3Parser.CONVERTER_VERSION}" ||
            BuiltInPhotoFilters.catalogKey(presetId) == sourceSha256)
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
        return parts[1].takeIf { it == "np3:${parts[0]}:${PhotoNp3Parser.CONVERTER_VERSION}" ||
            BuiltInPhotoFilters.catalogKey(it) == parts[0] }
    }

    private fun sourceKey(uri: String): String = "source:" + MessageDigest.getInstance("SHA-256")
        .digest(uri.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }

    private companion object {
        val digestPattern = Regex("[a-f0-9]{64}")
        fun validSourceUri(uri: String): Boolean = uri.length in 1..16_384 && uri.startsWith("content://")
    }
}

internal class PhotoNp3FolderPreferences(private val preferences: SharedPreferences) {
    val folder: Uri? get() = (preferences.all["folder"] as? String)?.let(Uri::parse)
    val ownsFolderGrant: Boolean get() = preferences.all["owns_grant"] as? Boolean ?: false
    fun replaceFolder(uri: Uri, ownsGrant: Boolean) {
        preferences.edit().putString("folder", uri.toString()).putBoolean("owns_grant", ownsGrant).apply()
    }
    fun markFolderGrantOwned() { preferences.edit().putBoolean("owns_grant", true).apply() }
    fun retainSharedGrant(uri: Uri): Boolean = (folder == uri).also { shared ->
        if (shared) markFolderGrantOwned()
    }
}
