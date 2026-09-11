package com.ztransfer.gps

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class GpsPlaceLookupStateTest {
    @Test
    fun defaultsToIdleWithoutCoordinatesOrPlace() {
        val state = GpsPlaceLookupState()

        assertNull(state.latitude)
        assertNull(state.longitude)
        assertEquals(GpsPlaceLookupStatus.IDLE, state.status)
        assertNull(state.placeName)
    }

    @Test
    fun copyKeepsTheRequestedCoordinateAndExistingPlace() {
        val success = GpsPlaceLookupState(
            latitude = 31.2304,
            longitude = 121.4737,
            status = GpsPlaceLookupStatus.SUCCESS,
            placeName = "上海",
        )

        assertEquals(
            GpsPlaceLookupState(
                latitude = 31.2304,
                longitude = 121.4737,
                status = GpsPlaceLookupStatus.LOADING,
                placeName = "上海",
            ),
            success.copy(status = GpsPlaceLookupStatus.LOADING),
        )
    }
}
