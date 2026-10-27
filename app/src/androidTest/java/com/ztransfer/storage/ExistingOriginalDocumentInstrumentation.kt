package com.ztransfer.storage

import android.app.Activity
import android.app.Instrumentation
import android.content.ContentProvider
import android.content.ContentResolver
import android.content.ContentValues
import android.content.pm.ProviderInfo
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.Bundle
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract.Document
import android.system.Os
import android.system.OsConstants
import kotlinx.coroutines.CancellationException
import java.io.File
import java.io.FileDescriptor
import java.io.FileNotFoundException
import java.io.IOException

/** Disposable provider/files only. No user albums, preferences, camera or network access. */
class ExistingOriginalDocumentInstrumentation : Instrumentation() {
    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        start()
    }

    override fun onStart() {
        val result = Bundle()
        var code = Activity.RESULT_CANCELED
        val scratch = File(targetContext.cacheDir, "existing-original-check-fixture").apply { mkdirs() }
        var provider: OriginalFixtureProvider? = null
        try {
            val file = File(scratch, "read-view.jpg").apply { writeBytes(byteArrayOf(1, 2, 3)) }
            val fixture = OriginalFixtureProvider(file)
            provider = fixture
            fixture.attachInfo(targetContext, ProviderInfo().apply {
                authority = AUTHORITY
                exported = true
                grantUriPermissions = true
            })
            val resolver = ContentResolver.wrap(fixture)
            val uri = Uri.parse("content://$AUTHORITY/document/original")
            fun read() = readExistingOriginalDocument(resolver, uri)
            fun reset() = fixture.reset()
            fun expectFailure(type: Class<out Throwable>) {
                val failure = runCatching { read() }.exceptionOrNull()
                check(type.isInstance(failure)) { "Expected ${type.simpleName}, got $failure" }
                fixture.checkClosedAndUnread()
            }

            // Provider metadata is authoritative for size. A redacted JPEG view may be smaller.
            check(read() == ExistingOriginalDocument("DSC_0001.JPG", 100L))
            check(fixture.queries == 1 && fixture.opens == listOf("r"))
            fixture.checkClosedAndUnread()
            check(file.readBytes().contentEquals(byteArrayOf(1, 2, 3)))

            reset()
            fixture.name = "renamed.JPG"
            fixture.bytes = 200L
            check(read() == ExistingOriginalDocument("renamed.JPG", 200L))
            fixture.checkClosedAndUnread()

            reset()
            fixture.queryMode = "empty"
            check(read() == null)
            check(fixture.opens.isEmpty())

            reset()
            fixture.queryMode = "missing"
            check(read() == null)

            // A cached/stale metadata row must not hide a file deleted in another app.
            reset()
            fixture.openMode = "missing"
            check(read() == null)
            check(fixture.queries == 1 && fixture.opens == listOf("r"))

            reset()
            fixture.queryMode = "null"
            expectFailure(IOException::class.java)
            check(fixture.opens.isEmpty())

            reset()
            fixture.openMode = "null"
            expectFailure(IOException::class.java)

            for (fromQuery in listOf(true, false)) {
                reset()
                if (fromQuery) fixture.queryMode = "denied" else fixture.openMode = "denied"
                expectFailure(SecurityException::class.java)
            }

            reset()
            fixture.queryMode = "cancelled"
            expectFailure(CancellationException::class.java)

            reset()
            fixture.omitMetadata = true
            check(read() == ExistingOriginalDocument(null, null))
            fixture.checkClosedAndUnread()

            reset()
            fixture.bytes = null
            check(read() == ExistingOriginalDocument("DSC_0001.JPG", null))
            fixture.checkClosedAndUnread()

            reset()
            fixture.directory = true
            expectFailure(IOException::class.java)
            check(fixture.opens.isEmpty())

            result.putString("result", "PASS: metadata, deletion, stale row, unknown size, provider errors, cancellation; no content reads")
            code = Activity.RESULT_OK
        } catch (failure: Throwable) {
            result.putString("error", failure.stackTraceToString())
        } finally {
            provider?.closeDuplicates()
            scratch.deleteRecursively()
        }
        finish(code, result)
    }

    private class OriginalFixtureProvider(private val file: File) : ContentProvider() {
        var queryMode = "present"
        var openMode = "present"
        var name = "DSC_0001.JPG"
        var bytes: Long? = 100L
        var omitMetadata = false
        var directory = false
        var queries = 0
        val opens = mutableListOf<String>()
        private val descriptors = mutableListOf<FileDescriptor>()
        private val duplicates = mutableListOf<ParcelFileDescriptor>()

        fun checkClosedAndUnread() {
            check(descriptors.none { it.valid() }) { "Read descriptor leaked" }
            check(duplicates.all { Os.lseek(it.fileDescriptor, 0L, OsConstants.SEEK_CUR) == 0L }) {
                "Existence check read image bytes"
            }
        }

        fun closeDuplicates() {
            duplicates.forEach { it.close() }
            duplicates.clear()
        }

        fun reset() {
            checkClosedAndUnread()
            closeDuplicates()
            descriptors.clear()
            queryMode = "present"
            openMode = "present"
            name = "DSC_0001.JPG"
            bytes = 100L
            omitMetadata = false
            directory = false
            queries = 0
            opens.clear()
        }

        override fun onCreate() = true
        override fun query(uri: Uri, projection: Array<out String>?, selection: String?,
            selectionArgs: Array<out String>?, sortOrder: String?): Cursor? {
            check(uri.path == "/document/original") { "Whole directory query is forbidden" }
            queries++
            when (queryMode) {
                "null" -> return null
                "missing" -> throw FileNotFoundException("Deleted")
                "denied" -> throw SecurityException("Denied")
                "cancelled" -> throw CancellationException("Cancelled")
            }
            val columns = if (omitMetadata) arrayOf(Document.COLUMN_DOCUMENT_ID)
                else projection ?: arrayOf(Document.COLUMN_DISPLAY_NAME, Document.COLUMN_SIZE)
            return MatrixCursor(columns).apply {
                if (queryMode != "empty") {
                    addRow(columns.map {
                        when (it) {
                            Document.COLUMN_DOCUMENT_ID -> "original"
                            Document.COLUMN_DISPLAY_NAME -> name
                            Document.COLUMN_SIZE -> bytes
                            Document.COLUMN_MIME_TYPE -> if (directory) Document.MIME_TYPE_DIR else "image/jpeg"
                            else -> null
                        }
                    }.toTypedArray())
                }
            }
        }

        override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor? {
            check(uri.path == "/document/original")
            check(mode == "r") { "Verification must never request write access" }
            opens += mode
            when (openMode) {
                "null" -> return null
                "missing" -> throw FileNotFoundException("Stale metadata row")
                "denied" -> throw SecurityException("Denied")
            }
            return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY).also {
                descriptors += it.fileDescriptor
                duplicates += ParcelFileDescriptor.dup(it.fileDescriptor)
            }
        }

        override fun getType(uri: Uri) = "image/jpeg"
        override fun insert(uri: Uri, values: ContentValues?): Uri? = error("No writes")
        override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?) = error("No deletion")
        override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?) = error("No writes")
    }

    private companion object {
        const val AUTHORITY = "com.ztransfer.fixture.existing-original"
    }
}
