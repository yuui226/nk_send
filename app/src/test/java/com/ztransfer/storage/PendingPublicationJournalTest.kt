package com.ztransfer.storage

import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PendingPublicationJournalTest {
    @Test
    fun pendingUriSurvivesReloadUntilVerified() {
        val directory = Files.createTempDirectory("zt-pending").toFile()
        try {
            val first = PendingPublicationJournal(directory)
            val entry = first.begin("content://provider/document/one")
            assertEquals(listOf(entry), first.pending())

            val reloaded = PendingPublicationJournal(directory)
            assertEquals(listOf(entry), reloaded.pending())
            reloaded.verified(entry)
            assertTrue(reloaded.pending().isEmpty())
            assertTrue(directory.listFiles().orEmpty().isEmpty())
        } finally {
            directory.deleteRecursively()
        }
    }
}
