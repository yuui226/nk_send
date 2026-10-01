package com.ztransfer.diagnostics

import org.junit.Assert.*
import org.junit.Test

class TimingReportTest {
    @Test fun keepsWholeRecentRecordsWithinBothBudgets() {
        val records = (1..20).map { "#$it " + "颜色计算=10000 ".repeat(30) + "END$it" }
        val report = boundedTimingReport("性能日志\n", records)
        assertTrue(report.length <= 2800)
        assertTrue(report.toByteArray(Charsets.UTF_8).size <= 6000)
        assertTrue(report.contains("END1"))
        assertTrue(report.contains("已省略"))
        for (i in 1..20) assertEquals(report.contains("#$i "), report.contains("END$i\n"))
    }
    @Test fun shortReportsKeepAllRecordsAndEmptyReportsExplainNextStep() {
        assertTrue(boundedTimingReport("test\n", emptyList()).contains("暂无记录"))
        val report = boundedTimingReport("test\n", listOf("#2 完成", "#1 运行中"))
        assertTrue(report.indexOf("#2") < report.indexOf("#1"))
        assertFalse(report.contains("已省略"))
    }
}
