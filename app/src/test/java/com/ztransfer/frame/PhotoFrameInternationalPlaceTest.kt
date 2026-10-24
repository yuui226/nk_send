package com.ztransfer.frame

import org.junit.Assert.assertEquals
import org.junit.Test

/** Structured provider fields may omit administrative suffixes; missing levels stay missing. */
class PhotoFrameInternationalPlaceTest {
    private data class Case(
        val description: String,
        val locality: String?,
        val subLocality: String?,
        val subAdmin: String?,
        val admin: String?,
        val country: String?,
        val expected: FramePlace,
    )

    private fun checkCases(vararg cases: Case) {
        cases.forEach { case ->
            assertEquals(case.description, case.expected, framePlace(
                case.locality, case.subLocality, case.subAdmin, case.admin, case.country,
            ))
        }
    }

    @Test
    fun hongKongAndMacaoKeepUntypedStructuredDivisionsWithoutRepeatingTheTerritory() = checkCases(
        Case("Hong Kong subAdmin does not require a District suffix",
            null, "Central", "Central and Western", "Hong Kong", "HK",
            FramePlace("Hong Kong", "Central and Western")),
        Case("Macao subAdmin does not require a Parish suffix",
            null, null, "Nossa Senhora de Fátima", "Macau", "MO",
            FramePlace("Macau", "Nossa Senhora de Fátima")),
        Case("Chinese Hong Kong repeats the English territory",
            null, null, "香港", "Hong Kong", "HK",
            FramePlace("Hong Kong", null)),
        Case("English Macau repeats the Chinese territory",
            null, null, "Macau", "澳門", "MO",
            FramePlace("澳門", null)),
    )

    @Test
    fun taiwanPreservesSuppliedBareParentAndLocalNames() = checkCases(
        Case("bare admin supplies a parent when locality is absent",
            null, "Da'an District", null, "Taipei", "TW",
            FramePlace("Taipei", "Da'an District")),
        Case("bare locality remains a city when no parent is supplied",
            "Taipei", null, null, null, "TW",
            FramePlace("Taipei", null)),
        Case("bare county-administered city retains its explicit county",
            "Zhubei", null, "Hsinchu County", "Taiwan", "TW",
            FramePlace("Hsinchu County", "Zhubei")),
        Case("bare town retains its explicit county",
            "Luodong", null, "Yilan County", "Taiwan", "TW",
            FramePlace("Yilan County", "Luodong")),
        Case("repeated city fields do not replace the actual district",
            "Taipei", "Da'an District", "TAIPEI", "Taipei", "TW",
            FramePlace("Taipei", "Da'an District")),
    )

    @Test
    fun taiwanDoesNotPromoteScienceParksOrCommunitiesToAdministrativeDivisions() = checkCases(
        Case("a science park is not a district despite ending in 區",
            "臺中市", "中部科學園區", null, "臺中市", "TW",
            FramePlace("臺中市", null)),
        Case("a community is not a district despite ending in 區",
            "臺北市", "幸福社區", null, "臺北市", "TW",
            FramePlace("臺北市", null)),
        Case("an English science park is not a local city or town",
            "Central Taiwan Science Park", null, null, "Taichung City", "TW",
            FramePlace("Taichung City", null)),
    )

    @Test
    fun overseasSubLocalityNeedsAnExplicitDistrictTypeAndCannotOverrideSubAdmin() = checkCases(
        Case("explicit District can fill an absent subAdmin",
            "Example City", "Example District", null, "Example State", "US",
            FramePlace("Example City", "Example District")),
        Case("SoHo is not promoted from neighborhood to county or district",
            "New York", "SoHo", null, "New York", "US",
            FramePlace("New York", null)),
        Case("supplied administrative county takes precedence over subLocality",
            "San Jose", "Downtown District", "Santa Clara County", "California", "US",
            FramePlace("San Jose", "Santa Clara County")),
        Case("case and surrounding whitespace do not duplicate a city as its region",
            " Paris ", "Montmartre", "PARIS", "Île-de-France", "FR",
            FramePlace("Paris", null)),
    )

    @Test
    fun missingOrBlankFieldsDoNotInventEitherLevel() = checkCases(
        Case("all fields missing",
            null, null, null, null, null,
            FramePlace(null, null)),
        Case("all fields blank even with a known regional format",
            " ", "\t", "\n", "  ", "TW",
            FramePlace(null, null)),
    )
}
