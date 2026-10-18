package com.ztransfer.ui.screen

import java.io.File
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import com.ztransfer.ui.screen.PictureControlReports.Kind

class PictureControlReportsTest {
    @get:Rule val temporary = TemporaryFolder()

    @Test fun reopeningKeepsFailedOperationAndReplacesOnlyPreviousRead() {
        val history = PictureControlReports.History()
        history.finish(history.begin(Kind.OPERATION), "operation FAILED camera=D5600")
        history.finish(history.begin(Kind.OVERVIEW), "first read")
        history.finish(history.begin(Kind.OVERVIEW), "second read camera=D5600")
        assertEquals("operation FAILED camera=D5600\n\nsecond read camera=D5600", history.text())
        history.finish(history.begin(Kind.OPERATION), "new operation SUCCESS")
        assertEquals("new operation SUCCESS\n\nsecond read camera=D5600", history.text())
    }

    @Test fun lateCancelledReadCannotReplaceNewReadButOperationCanFinishIndependently() {
        val history = PictureControlReports.History()
        val operation = history.begin(Kind.OPERATION)
        val oldRead = history.begin(Kind.OVERVIEW)
        val newRead = history.begin(Kind.OVERVIEW)
        history.finish(newRead, "new read")
        history.finish(oldRead, "old read cancelled")
        history.finish(operation, "operation rollback completed")
        assertEquals("operation rollback completed\n\nnew read", history.text())
    }

    @Test fun diskRestoreDoesNotReplaceStartedOrFinishedRuns() {
        val history = PictureControlReports.History()
        val read = history.begin(Kind.OVERVIEW)
        history.restore(mapOf(Kind.OVERVIEW to "old read", Kind.OPERATION to "saved failure"))
        assertEquals("saved failure", history.text())
        history.finish(read, "new read")
        history.finish(history.begin(Kind.OPERATION), "new operation")
        history.restore(mapOf(Kind.OVERVIEW to "old read", Kind.OPERATION to "old operation"))
        assertEquals("new operation\n\nnew read", history.text())
    }

    @Test fun recoveryFindsBothKindsAndIgnoresSharedSnapshotsAndEmptyNewFiles() {
        val filesDir = temporary.newFolder()
        val directory = File(filesDir, "picture_control_reports").apply { mkdirs() }
        File(directory, "PictureControl-100-old.txt").writeText("Picture Control slots v6\nFAILED")
        File(directory, "PictureControl-200-overview-old.txt").writeText("old overview")
        File(directory, "PictureControl-300-overview-new.txt").writeText("new overview")
        File(directory, "PictureControl-400-operation-empty.txt").writeText("")
        PictureControlReports.shareSnapshot(filesDir, "shared report must not become a run")
        val restored = PictureControlReports.latest(filesDir)
        assertEquals("Picture Control slots v6\nFAILED", restored[Kind.OPERATION])
        assertEquals("new overview", restored[Kind.OVERVIEW])
        assertEquals(2, restored.size)
    }

    @Test fun journalsPersistSeparatelyAndSharedSnapshotDoesNotChange() {
        val filesDir = temporary.newFolder()
        val operation = PictureControlReports.Journal(filesDir, Kind.OPERATION)
        operation.append("operation FAILED")
        val read = PictureControlReports.Journal(filesDir, Kind.OVERVIEW)
        read.append("overview SUCCESS")
        val snapshot = PictureControlReports.shareSnapshot(filesDir, operation.report())
        operation.append("rollback complete")
        assertEquals("operation FAILED\n", snapshot.readText())
        assertEquals(mapOf(Kind.OPERATION to operation.report(), Kind.OVERVIEW to read.report()),
            PictureControlReports.latest(filesDir))
    }

    @Test fun journalStillRetainsTextWhenDirectoryCannotBeCreated() {
        val journal = PictureControlReports.Journal(temporary.newFile(), Kind.OVERVIEW)
        journal.append("READ FAILED camera=D5600")
        assertTrue(journal.saveFailed)
        assertEquals("READ FAILED camera=D5600\n", journal.report())
    }
}
