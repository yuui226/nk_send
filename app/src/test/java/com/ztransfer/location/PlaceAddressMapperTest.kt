package com.ztransfer.location

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.random.Random

class PlaceAddressMapperTest {
    @Test
    fun internationalFallbackPreservesStructuredNamesWithoutALanguageDictionary() {
        val cities = listOf("São Paulo", "東京", "서울", "München", "القاهرة", "กรุงเทพมหานคร")
        val countries = listOf("BR", "JP", "KR", "DE", "EG", "TH", "ZZ")
        for (country in countries) for (city in cities) {
            val address = PlaceAddress(city, "neighborhood", "administrative area", "parent", country)
            assertEquals(PlaceNames(city, "administrative area"), PlaceAddressMapper.resolve(address))
        }
    }

    @Test
    fun mappingOnlyReturnsSuppliedNamesAndNeverChangesTheSource() {
        val random = Random(20261025)
        val values = listOf(null, "", "  ", " 北京市 ", "Beijing", "吉林", "吉林市", "大理白族自治州",
            "大理市", "区", "西湖区", "港区", "Santa Clara County", "Taipei", "Taipei City",
            "香港", "Hong Kong", "昆山市", "苏州市", "中央里", "幸福社区", "City", "new locality")
        val countries = listOf(null, "", "CN", "cn", "HK", "MO", "TW", "US", "JP", "ZZ")
        repeat(1_000) {
            val address = PlaceAddress(values.random(random), values.random(random), values.random(random),
                values.random(random), countries.random(random))
            val snapshot = address.copy()
            val result = PlaceAddressMapper.resolve(address)
            val supplied = listOf(address.locality, address.subLocality, address.subAdminArea, address.adminArea)
                .mapNotNull { it?.trim()?.takeIf(String::isNotEmpty) }
            for (name in listOfNotNull(result.city, result.region)) assertTrue(name in supplied)
            assertEquals(snapshot, address)
            assertEquals(result, PlaceAddressMapper.resolve(address))
        }
    }
}
