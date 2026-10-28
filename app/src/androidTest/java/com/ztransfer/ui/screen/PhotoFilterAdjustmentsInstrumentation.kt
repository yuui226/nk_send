package com.ztransfer.ui.screen

import android.app.Activity
import android.app.Application
import android.app.Instrumentation
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.net.Uri
import android.os.Bundle
import android.os.SystemClock
import android.provider.DocumentsContract
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelStore
import com.ztransfer.effects.ALL_PHOTO_EFFECT_MODULES
import com.ztransfer.effects.PHOTO_FILTER_ADJUSTMENTS_PREFERENCE_KEY
import com.ztransfer.effects.PHOTO_FILTER_APPLIED_ADJUSTMENTS_PREFERENCE_KEY
import com.ztransfer.effects.FAVORITE_PHOTO_FILTERS_PREFERENCE_KEY
import com.ztransfer.effects.PhotoEffectModule
import com.ztransfer.effects.FavoritePhotoFilter
import com.ztransfer.effects.photoFilterAdjustmentsFor
import com.ztransfer.filter.BuiltInPhotoFilters
import com.ztransfer.filter.LutAdjustments
import com.ztransfer.filter.PhotoNp3Parser
import com.ztransfer.filter.PhotoNp3Store
import com.ztransfer.filter.photoFilterCatalogKey
import com.ztransfer.frame.PhotoFramePreset
import com.ztransfer.frame.PhotoFrameWatermark
import com.ztransfer.lut.CubeLutParser
import com.ztransfer.lut.LutFile
import com.ztransfer.lut.PhotoLutStore
import com.ztransfer.protocol.NikonCamera
import com.ztransfer.viewmodel.TransferViewModel
import com.ztransfer.viewmodel.createQueueTasks
import com.ztransfer.viewmodel.photoFilterSelection
import java.io.File
import java.util.Collections

/** Actual VM/local preference restore, isolated from the user's settings, files and services. */
class PhotoFilterAdjustmentsInstrumentation : Instrumentation() {
    override fun onCreate(arguments: Bundle?) { super.onCreate(arguments); start() }

    override fun onStart() {
        val report = Bundle()
        var result = Activity.RESULT_CANCELED
        val app = FixtureApplication(targetContext)
        var store = ViewModelStore()
        lateinit var model: TransferViewModel
        fun restart() = runOnMainSync {
            store.clear()
            store = ViewModelStore()
            model = ViewModelProvider(store, ViewModelProvider.AndroidViewModelFactory(app))[TransferViewModel::class.java]
        }
        try {
            val raw = app.getSharedPreferences("ztransfer", Context.MODE_PRIVATE)
            val a = BuiltInPhotoFilters.all[0]
            val b = BuiltInPhotoFilters.all[1]
            val aKey = checkNotNull(photoFilterCatalogKey(a.id))
            val bKey = checkNotNull(photoFilterCatalogKey(b.id))
            val applied = LutAdjustments(11, -22, 33, -44)
            val draft = LutAdjustments(-15, 25, -35, 45)
            val other = LutAdjustments(50, -40, 30, -20)
            val legacyLocal = app.getSharedPreferences("local_photo_effects", Context.MODE_PRIVATE)
            raw.edit().putString(FAVORITE_PHOTO_FILTERS_PREFERENCE_KEY, aKey).commit()
            legacyLocal.edit().putString(FAVORITE_PHOTO_FILTERS_PREFERENCE_KEY, "$bKey,60;$aKey").commit()

            // Existing enabled presets are unchanged by the upgrade.
            raw.edit().putString("photo_filter_selected_id", a.id).putBoolean("photo_filter_enabled", true).commit()
            restart()
            check(model.state.value.photoFilterSelection?.lutAdjustments == LutAdjustments())
            check(model.state.value.transferPhotoFilterAdjustments.isEmpty())

            // Existing per-entry favorites merge once. Local draft saves and restart must
            // never restore a favorite that was removed through the shared controller.
            check(model.state.value.favoritePhotoFilters.map { it.catalogKey } == listOf(aKey, bKey))
            val localBeforeFavoriteChange = LocalPhotoEffectsPreferences(app)
                .restore(model.state.value.photoFilters.map { it.id })
            val recipeBeforeFavoriteChange = model.state.value.photoFilterSelection
            runOnMainSync { model.toggleFavoritePhotoFilter(b.id) }
            LocalPhotoEffectsPreferences(app).save(localBeforeFavoriteChange)
            check(model.state.value.photoFilterSelection == recipeBeforeFavoriteChange)
            restart()
            check(model.state.value.favoritePhotoFilters == listOf(FavoritePhotoFilter(aKey)))
            runOnMainSync { model.toggleFavoritePhotoFilter(a.id) }
            restart()
            check(model.state.value.favoritePhotoFilters.isEmpty())
            runOnMainSync { model.toggleFavoritePhotoFilter(a.id) }
            check(LocalPhotoEffectsPreferences(app).restore(model.state.value.photoFilters.map { it.id }) ==
                localBeforeFavoriteChange)

            // Malformed entries and wrong preference types cannot crash startup.
            raw.edit().putString(PHOTO_FILTER_ADJUSTMENTS_PREFERENCE_KEY,
                "$aKey,999,-999,9,-9;bad,1,2,3,4;$bKey,invalid,0,0,0")
                .putInt(PHOTO_FILTER_APPLIED_ADJUSTMENTS_PREFERENCE_KEY, 42).commit()
            restart()
            check(model.state.value.photoFilterAdjustments == LutAdjustments())
            check(model.state.value.transferPhotoFilterAdjustments == mapOf(aKey to LutAdjustments(100, -100, 9, -9)))
            raw.edit().putInt(PHOTO_FILTER_ADJUSTMENTS_PREFERENCE_KEY, 42).commit()
            restart()
            check(model.state.value.transferPhotoFilterAdjustments.isEmpty())

            // Remembered draft controls are separate from the committed camera-transfer recipe.
            runOnMainSync {
                model.setPhotoFilterConfiguration(a.id, 64, true, adjustments = applied)
                model.rememberTransferPhotoFilterAdjustments(a.id, draft)
            }
            check(model.state.value.photoFilterSelection?.lutAdjustments == applied)
            restart()
            check(model.state.value.photoFilterSelection?.lutAdjustments == applied)
            check(model.state.value.transferPhotoFilterAdjustments[aKey] == draft)
            runOnMainSync { model.setPhotoFilterEnabled(false) }
            restart()
            check(model.state.value.photoFilterSelection == null)
            check(model.state.value.photoFilterAdjustments == applied)
            check(model.state.value.transferPhotoFilterAdjustments[aKey] == draft)
            runOnMainSync {
                model.setPhotoFilterConfiguration(b.id, 76, true, adjustments = other)
                model.setPhotoFilterConfiguration(a.id, 64, true)
            }
            restart()
            check(model.state.value.photoFilterSelection?.lutAdjustments == draft)
            runOnMainSync { model.setPhotoFilterConfiguration(b.id, 76, true) }
            check(model.state.value.photoFilterSelection?.lutAdjustments == other)

            val custom = a.copy(id = "np3:${"a".repeat(64)}:${PhotoNp3Parser.CONVERTER_VERSION}", name = "Test NP3")
            runOnMainSync {
                model.registerPhotoFilter(custom)
                model.setPhotoFilterConfiguration(custom.id, 80, true, adjustments = applied)
            }
            restart()
            check(model.state.value.selectedPhotoFilterId == custom.id)
            check(model.state.value.photoFilterSelection?.lutAdjustments == applied)

            // The phone-photo editor persists its own maps; neither editor can rewrite the other.
            val local = LocalPhotoEffectsPreferences(app)
            local.save(defaultLocalPhotoEffectsSettings(a.id).copy(
                filterEnabled = true, filterAdjustments = mapOf(aKey to other),
            ))
            val ids = model.state.value.photoFilters.map { it.id }
            check(photoFilterAdjustmentsFor(a.id, LocalPhotoEffectsPreferences(app).restore(ids).filterAdjustments) == other)
            check(model.state.value.transferPhotoFilterAdjustments[aKey] == draft)
            runOnMainSync { model.rememberTransferPhotoFilterAdjustments(a.id, applied) }
            check(photoFilterAdjustmentsFor(a.id, LocalPhotoEffectsPreferences(app).restore(ids).filterAdjustments) == other)
            local.saveModules(ALL_PHOTO_EFFECT_MODULES xor PhotoEffectModule.FILTER.bit)
            val hidden = LocalPhotoEffectsPreferences(app).restore(ids)
            check(!hidden.filterEnabled && hidden.filterAdjustments[aKey] == other)
            local.saveModules(ALL_PHOTO_EFFECT_MODULES)
            check(!LocalPhotoEffectsPreferences(app).restore(ids).filterEnabled)
            app.getSharedPreferences("local_photo_effects", Context.MODE_PRIVATE).edit()
                .putInt("filter_adjustments_v1", 42).commit()
            check(LocalPhotoEffectsPreferences(app).restore(ids).filterAdjustments.isEmpty())
            check(model.state.value.photoFilterSelection?.lutAdjustments == applied)

            // A directory chosen by the other entry must synchronously reset the actual VM,
            // even when the local page is absent. Queued recipes remain immutable snapshots.
            val oldFolder = Uri.parse("content://effects-directory-test/tree/old")
            val newFolder = Uri.parse("content://effects-directory-test/tree/new")
            val thirdFolder = Uri.parse("content://effects-directory-test/tree/third")
            val oldSource = DocumentsContract.buildDocumentUriUsingTree(oldFolder, "old/preset.np3").toString()
            val customKey = checkNotNull(photoFilterCatalogKey(custom.id))
            val np3Store = PhotoNp3Store(app)
            runOnMainSync {
                np3Store.folders.replaceFolder(oldFolder, false)
                model.setPhotoFilterConfiguration(custom.id, 72, true, np3Uri = oldSource, adjustments = applied)
                model.toggleFavoritePhotoFilter(custom.id)
                np3Store.save("local", custom, oldSource)
                local.save(defaultLocalPhotoEffectsSettings(custom.id).copy(
                    filterEnabled = true, filterIntensityPercent = 48,
                    filterIntensities = mapOf(customKey to 48, aKey to 64),
                    filterAdjustments = mapOf(customKey to other, aKey to draft),
                ))
            }
            val queuedTask = createQueueTasks(
                listOf(NikonCamera.FileInfo(1, 100L, "DSC_1.JPG", captureDate = null)), false,
                photoFramePreset = PhotoFramePreset.MIST,
                photoFrameWatermark = PhotoFrameWatermark(enabled = false),
                photoFilter = model.state.value.photoFilterSelection,
            ).single()
            val queuedRecipe = checkNotNull(queuedTask.photoFilterRequested)
            check(queuedRecipe.lutAdjustments == applied && queuedRecipe.normalizedIntensityPercent == 72)
            runOnMainSync { np3Store.folders.replaceFolder(oldFolder, false) }
            check(model.state.value.selectedPhotoFilterId == custom.id)
            check(model.state.value.transferPhotoFilterAdjustments[customKey] == applied)
            runOnMainSync { np3Store.folders.replaceFolder(newFolder, false) }
            check(model.state.value.photoFilterSelection == null && !model.state.value.photoFilterEnabled)
            check(model.state.value.photoFilters.none { it.id == custom.id })
            check(customKey !in model.state.value.transferPhotoFilterIntensities)
            check(customKey !in model.state.value.transferPhotoFilterAdjustments)
            check(model.state.value.favoritePhotoFilters.none { it.catalogKey == customKey })
            val localCleared = LocalPhotoEffectsPreferences(app).restore(model.state.value.photoFilters.map { it.id })
            check(!localCleared.filterEnabled && customKey !in localCleared.filterAdjustments)
            check(customKey !in localCleared.filterIntensities)
            check(model.state.value.favoritePhotoFilters == listOf(FavoritePhotoFilter(aKey)))
            // Even an old local key with forgotten external favorites is no longer a source.
            legacyLocal.edit().putString(FAVORITE_PHOTO_FILTERS_PREFERENCE_KEY, "$customKey;$bKey;$aKey").commit()
            restart()
            check(model.state.value.favoritePhotoFilters == listOf(FavoritePhotoFilter(aKey)))
            check(localCleared.filterAdjustments[aKey] == draft && localCleared.filterIntensities[aKey] == 64)
            check(queuedTask.photoFilterRequested === queuedRecipe && queuedRecipe.preset.id == custom.id)
            check(queuedRecipe.lutAdjustments == applied && queuedRecipe.normalizedIntensityPercent == 72)
            runOnMainSync {
                model.rememberTransferPhotoFilterAdjustments(custom.id, other)
                model.rememberTransferPhotoFilterIntensity(custom.id, 26)
                model.toggleFavoritePhotoFilter(custom.id)
                model.setPhotoFilterConfiguration(custom.id, 48, true, np3Uri = oldSource, adjustments = other)
            }
            check(model.state.value.photoFilterSelection == null)
            check(customKey !in model.state.value.transferPhotoFilterAdjustments)
            check(customKey !in model.state.value.transferPhotoFilterIntensities)
            // Even a stale registered recipe cannot bypass the source-tree guard or erase
            // the source URI to resurrect a selection cleared by directory replacement.
            runOnMainSync {
                model.registerPhotoFilter(custom)
                model.setPhotoFilterConfiguration(custom.id, 48, true, np3Uri = oldSource, adjustments = other)
                model.setPhotoFilterConfiguration(custom.id, 48, true, adjustments = other)
            }
            check(model.state.value.photoFilterSelection == null)
            runOnMainSync {
                model.setPhotoFilterConfiguration(b.id, 76, true, adjustments = other)
                np3Store.folders.replaceFolder(thirdFolder, false)
            }
            check(model.state.value.selectedPhotoFilterId == b.id && model.state.value.photoFilterEnabled)
            check(model.state.value.photoFilterSelection?.lutAdjustments == other)
            check(model.state.value.transferPhotoFilterAdjustments[bKey] == other)
            restart()
            check(model.state.value.selectedPhotoFilterId == b.id && model.state.value.photoFilterEnabled)
            check(model.state.value.photoFilterSelection?.lutAdjustments == other)
            // A cleared custom ID in an older preference file cannot enable the fallback built-in.
            raw.edit().putString("photo_filter_selected_id", custom.id).putBoolean("photo_filter_enabled", true).commit()
            restart()
            check(!model.state.value.photoFilterEnabled)
            check(model.state.value.photoFilterSelection == null)

            // Real small LUT snapshot, same actual VM observer, no SAF provider or camera IO.
            val lutStore = PhotoLutStore(app)
            val lutFile = LutFile(DocumentsContract.buildDocumentUriUsingTree(oldFolder, "old/test.cube"),
                "test.cube", 100, 1)
            val table = CubeLutParser.parse(("LUT_3D_SIZE 2\n" +
                "0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n").byteInputStream())
            runOnMainSync { lutStore.folders.replaceFolder(oldFolder, false) }
            val lut = lutStore.snapshot("transfer", lutFile, table).copy(intensityPercent = 62, lutAdjustments = applied)
            runOnMainSync {
                model.setPhotoFilterConfiguration(b.id, 76, false, lut, lutFile.uri.toString(), adjustments = other)
                lutStore.folders.replaceFolder(oldFolder, false)
            }
            check(model.state.value.photoLut == lut)
            runOnMainSync { lutStore.folders.replaceFolder(newFolder, false) }
            check(model.state.value.photoLut == null)
            check(lutStore.restore("transfer") == null)
            runOnMainSync {
                model.setPhotoFilterConfiguration(b.id, 76, false, lut, lutFile.uri.toString())
                model.setPhotoFilterConfiguration(b.id, 76, false, lut)
            }
            check(model.state.value.photoLut == null)
            check(lutStore.intensity("transfer", table.digest, lutFile.uri.toString()) == 80)
            check(lutStore.adjustments("transfer", table.digest) == LutAdjustments())
            check(lut.normalizedIntensityPercent == 62 && lut.lutAdjustments == applied)

            // Module visibility must not recommit an older applied recipe over live draft
            // memories. Test the real NP3 and LUT setters with separate applied/draft values.
            fun currentQueuedRecipe() = checkNotNull(createQueueTasks(
                listOf(NikonCamera.FileInfo(2, 100L, "DSC_2.JPG", captureDate = null)), false,
                photoFramePreset = PhotoFramePreset.MIST,
                photoFrameWatermark = PhotoFrameWatermark(enabled = false),
                photoFilter = model.state.value.photoFilterSelection,
            ).single().photoFilterRequested)
            val currentNp3Source = DocumentsContract.buildDocumentUriUsingTree(thirdFolder, "third/current.np3").toString()
            val withoutGrain = ALL_PHOTO_EFFECT_MODULES xor PhotoEffectModule.GRAIN.bit
            runOnMainSync {
                model.setTransferPhotoEffectModules(ALL_PHOTO_EFFECT_MODULES)
                model.registerPhotoFilter(custom)
                model.setPhotoFilterConfiguration(custom.id, 80, true,
                    np3Uri = currentNp3Source, adjustments = applied)
                model.rememberTransferPhotoFilterIntensity(custom.id, 50)
                model.rememberTransferPhotoFilterAdjustments(custom.id, draft)
            }
            val queuedFilterBeforeVisibility = currentQueuedRecipe()
            runOnMainSync { model.setTransferPhotoEffectModules(withoutGrain) }
            check(model.state.value.photoFilterSelection?.normalizedIntensityPercent == 80)
            check(model.state.value.transferPhotoFilterIntensities[customKey] == 50)
            check(model.state.value.transferPhotoFilterAdjustments[customKey] == draft)
            runOnMainSync { model.setTransferPhotoEffectModules(withoutGrain xor PhotoEffectModule.FILTER.bit) }
            check(!model.state.value.photoFilterEnabled && model.state.value.photoFilterSelection == null)
            check(model.state.value.transferPhotoFilterIntensities[customKey] == 50)
            check(model.state.value.transferPhotoFilterAdjustments[customKey] == draft)
            check(queuedFilterBeforeVisibility.normalizedIntensityPercent == 80 && queuedFilterBeforeVisibility.lutAdjustments == applied)

            val currentLutFile = LutFile(DocumentsContract.buildDocumentUriUsingTree(newFolder, "new/current.cube"),
                "current.cube", 100, 1)
            val appliedLut = lutStore.snapshot("transfer", currentLutFile, table)
                .copy(intensityPercent = 80, lutAdjustments = applied)
            runOnMainSync {
                model.setTransferPhotoEffectModules(ALL_PHOTO_EFFECT_MODULES)
                model.setPhotoFilterConfiguration(a.id, 80, false, appliedLut, currentLutFile.uri.toString())
                lutStore.rememberIntensity("transfer", table.digest, currentLutFile.uri.toString(), 50)
                lutStore.rememberAdjustments("transfer", table.digest, draft)
            }
            val queuedLutBeforeVisibility = currentQueuedRecipe()
            runOnMainSync { model.setTransferPhotoEffectModules(withoutGrain) }
            check(model.state.value.photoLut?.normalizedIntensityPercent == 80)
            check(lutStore.intensity("transfer", table.digest, currentLutFile.uri.toString()) == 50)
            check(lutStore.adjustments("transfer", table.digest) == draft)
            runOnMainSync { model.setTransferPhotoEffectModules(withoutGrain xor PhotoEffectModule.LUT.bit) }
            check(model.state.value.photoLut == null && lutStore.restore("transfer") == null)
            check(lutStore.intensity("transfer", table.digest, currentLutFile.uri.toString()) == 50)
            check(lutStore.adjustments("transfer", table.digest) == draft)
            val reselectedLut = lutStore.snapshot("transfer", currentLutFile, table)
            check(reselectedLut.normalizedIntensityPercent == 50 && reselectedLut.lutAdjustments == draft)
            runOnMainSync {
                model.setTransferPhotoEffectModules(ALL_PHOTO_EFFECT_MODULES)
                model.setPhotoFilterConfiguration(a.id, 80, false, reselectedLut, currentLutFile.uri.toString())
            }
            check(model.state.value.photoLut == reselectedLut)
            check(queuedLutBeforeVisibility.normalizedIntensityPercent == 80 && queuedLutBeforeVisibility.lutAdjustments == applied)

            report.putString("stream", "PASS shared favorites migration/merge/removal/restart, no stale-local resurrection, legacy neutral controls, malformed preferences, committed/draft separation, disabled/switch restore, NP3 snapshots, local/transfer parameter isolation, synchronous directory reset, immutable queue recipes, stale-draft rejection and module-visibility draft preservation\n")
            result = Activity.RESULT_OK
        } catch (error: Throwable) {
            report.putString("stream", error.stackTraceToString())
        } finally {
            runOnMainSync { store.clear() }
            app.cleanup()
            finish(result, report)
        }
    }

    private class FixtureApplication(context: Context) : Application() {
        private val prefix = "filter_adjustments_test_${SystemClock.elapsedRealtimeNanos()}_"
        private val preferenceNames = Collections.synchronizedSet(linkedSetOf<String>())
        init { attachBaseContext(context) }
        override fun getApplicationContext(): Context = this
        override fun getSharedPreferences(name: String, mode: Int): SharedPreferences {
            val isolatedName = prefix + name
            preferenceNames.add(isolatedName)
            return baseContext.getSharedPreferences(isolatedName, mode)
        }
        override fun getCacheDir(): File = File(baseContext.cacheDir, prefix).apply { mkdirs() }
        override fun getFilesDir(): File = File(baseContext.filesDir, prefix).apply { mkdirs() }
        override fun stopService(service: Intent): Boolean = false
        fun cleanup() {
            synchronized(preferenceNames) { preferenceNames.toList() }
                .forEach { baseContext.deleteSharedPreferences(it) }
            cacheDir.deleteRecursively()
            filesDir.deleteRecursively()
        }
    }
}
