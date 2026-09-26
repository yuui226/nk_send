package com.ztransfer.crop

import android.database.Cursor
import android.database.MatrixCursor
import android.os.Bundle
import android.os.CancellationSignal
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract.Document
import android.provider.DocumentsContract.Root
import android.provider.DocumentsProvider
import java.io.File
import java.io.FileNotFoundException

/** Test APK only; exposes only a dedicated disposable cache directory. */
class CropFixtureProvider : DocumentsProvider() {
    private lateinit var root: File
    private var rejectRename=false
    private var rejectFinalWrite=false
    override fun onCreate():Boolean {
        root=File(checkNotNull(context).cacheDir,"crop-provider-fixture").apply {mkdirs()}
        return true
    }
    private fun file(id:String):File {
        val result=if(id=="root") root else File(root,id.removePrefix("root/"))
        require(result.canonicalFile==root.canonicalFile||result.canonicalPath.startsWith(root.canonicalPath+"/"))
        return result
    }
    private fun id(file:File)=if(file==root) "root" else "root/"+file.relativeTo(root).path
    private val columns=arrayOf(Document.COLUMN_DOCUMENT_ID,Document.COLUMN_DISPLAY_NAME,Document.COLUMN_MIME_TYPE,
        Document.COLUMN_SIZE,Document.COLUMN_FLAGS)
    private fun row(cursor:MatrixCursor,file:File) {
        val values=mapOf<String,Any>(Document.COLUMN_DOCUMENT_ID to id(file),
            Document.COLUMN_DISPLAY_NAME to file.name,
            Document.COLUMN_MIME_TYPE to if(file.isDirectory) Document.MIME_TYPE_DIR else "image/jpeg",
            Document.COLUMN_SIZE to file.length(), Document.COLUMN_FLAGS to
                (Document.FLAG_SUPPORTS_WRITE or Document.FLAG_SUPPORTS_DELETE or Document.FLAG_SUPPORTS_RENAME or
                    if(file.isDirectory) Document.FLAG_DIR_SUPPORTS_CREATE else 0))
        cursor.addRow(cursor.columnNames.map {values[it]}.toTypedArray())
    }
    override fun queryRoots(projection:Array<out String>?):Cursor=MatrixCursor(projection?:arrayOf(Root.COLUMN_ROOT_ID,
        Root.COLUMN_DOCUMENT_ID,Root.COLUMN_TITLE,Root.COLUMN_FLAGS)).apply {
        val values=mapOf<String,Any>(Root.COLUMN_ROOT_ID to "fixture",Root.COLUMN_DOCUMENT_ID to "root",
            Root.COLUMN_TITLE to "Crop test fixture",Root.COLUMN_FLAGS to Root.FLAG_SUPPORTS_CREATE)
        addRow(columnNames.map {values[it]}.toTypedArray())
    }
    override fun queryDocument(documentId:String,projection:Array<out String>?):Cursor=
        MatrixCursor(projection?:columns).also {row(it,file(documentId))}
    override fun queryChildDocuments(parentDocumentId:String,projection:Array<out String>?,sortOrder:String?):Cursor=
        MatrixCursor(projection?:columns).also {cursor->file(parentDocumentId).listFiles()?.forEach {row(cursor,it)}}
    override fun isChildDocument(parentDocumentId:String,documentId:String):Boolean=
        file(documentId).canonicalPath.startsWith(file(parentDocumentId).canonicalPath+"/")
    override fun createDocument(parentDocumentId:String,mimeType:String,displayName:String):String {
        require(!displayName.contains('/'))
        var target=File(file(parentDocumentId),displayName)
        var number=1
        while(target.exists()) {target=File(file(parentDocumentId),"${displayName.substringBeforeLast('.')} (${number++}).${displayName.substringAfterLast('.')}")}
        check(if(mimeType==Document.MIME_TYPE_DIR) target.mkdirs() else target.createNewFile())
        return id(target)
    }
    override fun openDocument(documentId:String,mode:String,signal:CancellationSignal?):ParcelFileDescriptor {
        if(rejectFinalWrite&&mode.contains('w')&&!file(documentId).name.startsWith('.')) throw FileNotFoundException("Injected final-write failure")
        return ParcelFileDescriptor.open(file(documentId),ParcelFileDescriptor.parseMode(mode))
    }
    override fun deleteDocument(documentId:String) {check(file(documentId).deleteRecursively())}
    override fun renameDocument(documentId:String,displayName:String):String {
        if(rejectRename)throw UnsupportedOperationException("Injected rename limitation")
        require(!displayName.contains('/'))
        val source=file(documentId)
        val destination=File(source.parentFile,displayName)
        if(destination.exists())throw FileNotFoundException("Destination exists")
        check(source.renameTo(destination));return id(destination)
    }
    override fun call(method:String,arg:String?,extras:Bundle?):Bundle? {
        if(method=="fixture_reset") {
            root.deleteRecursively();root.mkdirs()
            rejectRename=extras?.getBoolean("rejectRename")==true
            rejectFinalWrite=extras?.getBoolean("rejectFinalWrite")==true
            return Bundle()
        }
        return super.call(method,arg,extras)
    }
}
