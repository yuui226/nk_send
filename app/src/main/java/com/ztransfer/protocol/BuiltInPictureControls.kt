package com.ztransfer.protocol

import android.content.res.AssetManager
import org.json.JSONObject

internal data class BuiltInPictureControl(
    val name: String,
    val assetPath: String,
    val sizeBytes: Int,
    val sha256: String,
) {
    fun read(assets: AssetManager): NikonPictureControlFile {
        val bytes = assets.open(assetPath).use { it.readBytes() }
        require(bytes.size == sizeBytes && pictureControlDigest(bytes) == sha256) {
            "Built-in Picture Control integrity check failed"
        }
        return NikonPictureControlFile.parse(bytes).also {
            require(it.name == name) { "Built-in Picture Control name mismatch" }
        }
    }
}

/** Names and source files ship together; opening the tool never needs a download. */
internal fun builtInPictureControls(assets: AssetManager): List<BuiltInPictureControl> {
    val json = assets.open("picture_controls/catalog.json").bufferedReader().use { JSONObject(it.readText()) }
    require(json.getInt("schemaVersion") == 1)
    val presets = json.getJSONArray("presets")
    return List(presets.length()) { index ->
        val entry = presets.getJSONObject(index)
        val file = entry.getString("file")
        require('/' !in file && '\\' !in file && file.endsWith(".NP3"))
        BuiltInPictureControl(
            name = entry.getString("name"),
            assetPath = "picture_controls/$file",
            sizeBytes = entry.getInt("sizeBytes"),
            sha256 = entry.getString("sha256"),
        )
    }.also { entries ->
        require(entries.isNotEmpty() && entries.map { it.assetPath }.distinct().size == entries.size)
    }
}
