package com.ztransfer.ui.screen

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Matrix
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sin
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PreviewAnchorGeometryTest {
    private val anchor = Rect(12f, 312f, 348f, 648f)
    private val image = Rect(90f, 850f, 990f, 1450f)
    private val directions = listOf(0f, 90f, 180f, 270f, -90f, -180f, -270f)

    @Test fun openingStartsAtTheTileInsteadOfPartwayTowardTheScreenCentre() {
        val frame = previewAnchorFrame(anchor, image, 0f)
        assertPoint(anchor.center, map(frame, image.center))
        assertRect(anchor, clipBounds(frame, image.center))
        val drawn = bounds(corners(image).map { map(frame, it) })
        assertCropCovers(anchor, drawn)
        // The landscape photo must overflow the square horizontally, then be clipped.
        assertTrue(drawn.width > anchor.width)
        assertEquals(anchor.height, drawn.height, EPS)
    }

    @Test fun savedQuarterTurnsCancelAtTheSourceIncludingAsymmetricVisibleCropping() {
        val visible = Rect(anchor.left + 31f, anchor.top + 87f, anchor.right, anchor.bottom - 13f)
        for (rotation in directions) {
            val destination = destination(rotation)
            val frame = previewAnchorFrame(anchor, destination, 0f, rotation, visible)
            assertPoint(anchor.center, map(frame, destination.center))
            assertRect(visible, clipBounds(frame, destination.center))
            // Follow two original image axes through its saved rotation and the flight.
            val center = destination.center
            val right = map(frame, rotateAround(center, rotation, center + Offset(450f, 0f)))
            val down = map(frame, rotateAround(center, rotation, center + Offset(0f, 300f)))
            assertEquals(anchor.center.y, right.y, EPS)
            assertEquals(anchor.center.x, down.x, EPS)
            assertTrue(right.x > anchor.center.x)
            assertTrue(down.y > anchor.center.y)
            assertEquals(1.5f, (right.x - anchor.center.x) / (down.y - anchor.center.y), EPS)
        }
    }

    @Test fun finishedFrameIsIdentityAndReleasesTheEntirePhoto() {
        val visible = Rect(anchor.left, anchor.top + 100f, anchor.right - 47f, anchor.bottom)
        for (rotation in directions) {
            val destination = destination(rotation)
            val frame = previewAnchorFrame(anchor, destination, 1f, rotation, visible)
            assertEquals(1f, frame.scale, EPS)
            assertEquals(0f, frame.rotation, EPS)
            assertPoint(Offset.Zero, frame.translation)
            for (point in corners(destination) + destination.center) assertPoint(point, map(frame, point))
            assertRect(destination, clipBounds(frame, destination.center))
        }
    }

    @Test fun everyIntermediateFrameMovesContinuouslyAndOnlyReleasesMoreOfTheImage() {
        val visible = Rect(anchor.left + 31f, anchor.top + 87f, anchor.right, anchor.bottom - 13f)
        for (rotation in directions) {
            val destination = destination(rotation)
            val rawBounds = Rect(destination.center.x - 450f, destination.center.y - 300f,
                destination.center.x + 450f, destination.center.y + 300f)
            val first = previewAnchorFrame(anchor, destination, 0f, rotation, visible)
            var previous = first
            for (step in 0..100) {
                val p = step / 100f
                val frame = previewAnchorFrame(anchor, destination, p, rotation, visible)
                val expectedCenter = anchor.center * (1f - p) + destination.center * p
                assertPoint(expectedCenter, map(frame, destination.center))
                assertTrue(frame.scale.isFinite() && frame.scale > 0f)
                assertTrue(frame.scale >= minOf(first.scale, 1f) - EPS)
                assertTrue(frame.scale <= maxOf(first.scale, 1f) + EPS)
                assertTrue(abs(frame.rotation) <= 180f + EPS)
                assertTrue(abs(frame.rotation) <= abs(previous.rotation) + EPS)
                // Clipping stays inside the image, so rotation cannot expose blank corners.
                assertContains(rawBounds, frame.clip)
                assertContains(frame.clip, previous.clip)
                previous = frame
            }
        }
    }

    @Test fun extremeAspectRatiosAndTilesLargerThanTheFinalImageStillUseExactCrop() {
        val smallTile = Rect(20f, 40f, 220f, 240f)
        val destinations = listOf(
            Rect(20f, 500f, 1020f, 520f), // Very wide photograph.
            Rect(500f, 100f, 520f, 1100f), // Very tall photograph.
            Rect(400f, 650f, 480f, 710f), // Destination smaller than the source tile.
            Rect(0f, 0f, 20_000f, 10_000f), // Start scale below the former .05 floor.
        )
        for (destination in destinations) {
            val start = previewAnchorFrame(smallTile, destination, 0f)
            assertPoint(smallTile.center, map(start, destination.center))
            assertRect(smallTile, clipBounds(start, destination.center))
            assertCropCovers(smallTile, bounds(corners(destination).map { map(start, it) }))
            val end = previewAnchorFrame(smallTile, destination, 1f)
            assertRect(destination, clipBounds(end, destination.center))
        }
        assertTrue(previewAnchorFrame(smallTile, destinations[2], 0f).scale > 1f)
        assertTrue(previewAnchorFrame(smallTile, destinations[3], 0f).scale < .05f)
    }

    @Test fun clipRotationMatrixKeepsItsImageCentreFixed() {
        val center = Offset(540f, 1150f)
        for (angle in directions) {
            val matrix = rotationMatrix(center, angle)
            assertPoint(center, matrix.map(center))
        }
        val quarterTurn = rotationMatrix(center, 90f)
        assertPoint(center + Offset(0f, 10f), quarterTurn.map(center + Offset(10f, 0f)))
    }

    @Test fun outOfRangeProgressCannotOvershootEitherEndpoint() {
        assertEquals(previewAnchorFrame(anchor, image, 0f), previewAnchorFrame(anchor, image, -.5f))
        assertEquals(previewAnchorFrame(anchor, image, 1f), previewAnchorFrame(anchor, image, 1.5f))
    }

    private fun destination(rotation: Float): Rect = if (abs(rotation.toInt() / 90) % 2 == 1) {
        Rect(240f, 700f, 840f, 1600f)
    } else image

    /** Apply the returned layer transform to actual points, rather than comparing its formula. */
    private fun map(frame: PreviewAnchorFrame, point: Offset): Offset =
        rotateAround(Offset.Zero, frame.rotation, point) * frame.scale + frame.translation

    private fun rotateAround(center: Offset, degrees: Float, point: Offset): Offset {
        val radians = Math.toRadians(degrees.toDouble())
        val delta = point - center
        return center + Offset((delta.x * cos(radians) - delta.y * sin(radians)).toFloat(),
            (delta.x * sin(radians) + delta.y * cos(radians)).toFloat())
    }

    private fun rotationMatrix(center: Offset, degrees: Float) = Matrix().apply {
        translate(center.x, center.y)
        rotateZ(degrees)
        translate(-center.x, -center.y)
    }

    private fun clipBounds(frame: PreviewAnchorFrame, imageCenter: Offset): Rect {
        val rotation = rotationMatrix(imageCenter, frame.clipRotation)
        return bounds(corners(frame.clip).map { map(frame, rotation.map(it)) })
    }

    private fun corners(rect: Rect) = listOf(rect.topLeft, rect.topRight, rect.bottomRight, rect.bottomLeft)
    private fun bounds(points: List<Offset>) = Rect(points.minOf { it.x }, points.minOf { it.y },
        points.maxOf { it.x }, points.maxOf { it.y })
    private fun assertPoint(expected: Offset, actual: Offset) {
        assertEquals("x", expected.x, actual.x, EPS)
        assertEquals("y", expected.y, actual.y, EPS)
    }
    private fun assertRect(expected: Rect, actual: Rect) {
        assertPoint(expected.topLeft, actual.topLeft)
        assertPoint(expected.bottomRight, actual.bottomRight)
    }
    private fun assertContains(outer: Rect, inner: Rect) {
        assertTrue("$outer must contain $inner", outer.left <= inner.left + EPS &&
            outer.top <= inner.top + EPS && outer.right >= inner.right - EPS && outer.bottom >= inner.bottom - EPS)
    }
    private fun assertCropCovers(tile: Rect, drawn: Rect) {
        assertContains(drawn, tile)
        assertTrue(abs(tile.width - drawn.width) < EPS || abs(tile.height - drawn.height) < EPS)
    }
    private companion object { const val EPS = .01f }
}
