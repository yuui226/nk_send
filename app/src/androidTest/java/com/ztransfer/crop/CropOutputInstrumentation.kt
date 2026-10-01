package com.ztransfer.crop

import android.app.Activity
import android.app.Instrumentation
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.net.Uri
import android.os.Bundle
import android.provider.DocumentsContract
import androidx.exifinterface.media.ExifInterface
import com.ztransfer.frame.*
import kotlinx.coroutines.runBlocking
import java.io.File

/** The real SAF publisher and real photo-effects exporter share a disposable DocumentsProvider. */
class CropOutputInstrumentation:Instrumentation() {
    private val authority="com.ztransfer.debug.test.cropfixture"
    override fun onCreate(arguments:Bundle?) {super.onCreate(arguments);start()}
    override fun onStart() {
        val result=Bundle();var code=Activity.RESULT_CANCELED
        val scratch=File(targetContext.cacheDir,"crop-output-fixture").apply {mkdirs()}
        try {
            runBlocking {
                val provider = CropFixtureProvider()
                provider.attachInfo(targetContext, android.content.pm.ProviderInfo().apply {
                    authority = this@CropOutputInstrumentation.authority
                    exported = true; grantUriPermissions = true
                    readPermission = "android.permission.MANAGE_DOCUMENTS"
                    writePermission = "android.permission.MANAGE_DOCUMENTS"
                })
                val resolver = android.content.ContentResolver.wrap(provider)
                val tree=DocumentsContract.buildTreeDocumentUri(authority,"root")
                val root=DocumentsContract.buildDocumentUriUsingTree(tree,"root")
                fun reset(rename:Boolean=false,fail:Boolean=false) {
                    resolver.call(Uri.parse("content://$authority"),"fixture_reset",null,Bundle().apply {
                        putBoolean("rejectRename",rename);putBoolean("rejectFinalWrite",fail)
                    })
                }
                fun children(parent:Uri):List<Pair<String,Uri>> {
                    val uri=DocumentsContract.buildChildDocumentsUriUsingTree(tree,DocumentsContract.getDocumentId(parent))
                    return resolver.query(uri,arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME,DocumentsContract.Document.COLUMN_DOCUMENT_ID),null,null,null)!!.use {cursor->
                        buildList {while(cursor.moveToNext()) add(cursor.getString(0) to DocumentsContract.buildDocumentUriUsingTree(tree,cursor.getString(1)))}
                    }
                }
                val original=File(scratch,"source.jpg")
                val cropped=File(scratch,"cropped.jpg")
                val bitmap=Bitmap.createBitmap(640,480,Bitmap.Config.ARGB_8888).apply {eraseColor(Color.rgb(57,105,145))}
                original.outputStream().use {check(bitmap.compress(Bitmap.CompressFormat.JPEG,94,it))};bitmap.recycle()
                ExifInterface(original).apply {setAttribute(ExifInterface.TAG_ORIENTATION,"6");setAttribute(ExifInterface.TAG_MODEL,"NIKON Z 30");saveAttributes()}
                val source=checkNotNull(LosslessJpeg.readSource(original))
                LosslessJpeg.crop(original,cropped,JpegCropRecipe(source,CropRect(32,16,512,336)))
                // Production passes a private file URI to the existing effects exporter.
                targetContext.contentResolver.openFileDescriptor(Uri.fromFile(cropped), "r")!!.use {
                    check(ExifInterface(it.fileDescriptor).getAttributeInt(ExifInterface.TAG_ORIENTATION, 1) == 6)
                }
                for(rename in listOf(false,true)) {
                    reset(rename)
                    val published=publishCropOutput(resolver,cropped,root,"crop.jpg",".nkcrop_fixture.part")
                    check(children(root).map {it.first}==listOf("crop.jpg"))
                    resolver.openInputStream(published)!!.use {check(it.readBytes().contentEquals(cropped.readBytes()))}
                }
                reset(rename=true,fail=true)
                check(runCatching {publishCropOutput(resolver,cropped,root,"crop.jpg",".nkcrop_fixture.part")}.isFailure)
                check(children(root).isEmpty()) {"Failed publish left output files"}
                reset()
                val inputUri=checkNotNull(DocumentsContract.createDocument(resolver,root,"image/jpeg",".fixture-source.jpg"))
                resolver.openOutputStream(inputUri)!!.use { output -> cropped.inputStream().use {it.copyTo(output)} }
                val destination=PhotoFrameExporter.prepareDestination(resolver,tree,root)
                val exported=PhotoFrameExporter.export(targetContext,resolver,destination,inputUri,"crop.jpg",
                    PhotoFramePreset.MINIMAL,PhotoFrameWatermark(enabled=false)).getOrThrow()
                DocumentsContract.deleteDocument(resolver,inputUri)
                check(children(root).size==1&&children(root).single().first==PHOTO_FRAME_OUTPUT_DIRECTORY)
                val outputs=children(destination.directoryUri)
                check(outputs.size==1&&outputs.single().first==exported.displayName)
                val dimensions=BitmapFactory.Options().apply {inJustDecodeBounds=true}
                resolver.openInputStream(outputs.single().second)!!.use {BitmapFactory.decodeStream(it,null,dimensions)}
                check(dimensions.outWidth>0&&dimensions.outHeight>0)
                check(dimensions.outHeight>dimensions.outWidth) {"Crop EXIF portrait orientation was lost during effects"}
                reset()
                result.putString("result","PASS: one byte-identical crop output; rename fallback; failed-write cleanup; one effects output; portrait orientation")
            }
            code=Activity.RESULT_OK
        } catch(failure:Throwable) {result.putString("failure",failure.stackTraceToString())}
        finally {scratch.deleteRecursively()}
        finish(code,result)
    }
}
