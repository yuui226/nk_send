package com.ztransfer.protocol

import android.os.SystemClock
import java.net.SocketTimeoutException
import java.util.zip.CRC32
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/**
 * 无线遥控协议层：Live View、曝光参数读写、触摸对焦、遥控拍摄、事件轮询，
 * 外加开发者面板用的完整能力探测（runLabProbe）。语义与 libgphoto2 ptp.h/library.c 对照，
 * 已在 Z 30 (fw1.20) 真机全项验证。
 * 所有命令经 [NikonCamera.ioMutex] 串行，与传输/缩略图/心跳互斥，不碰下载热路径。
 *
 * 探测/诊断日志固定英文 + 十六进制（用于与 libgphoto2 语义比对），不做 i18n。
 */
private fun hex4(v: Int) = "0x%04X".format(v and 0xFFFF)
private fun hex8(v: Long) = "0x%08X".format(v)
private fun hexCode(v: Int) =
    if (v in 0..0xFFFF) hex4(v) else "0x%05X".format(v)

private const val PROBE_CODES_PER_LINE = 16

/**
 * 将完整码表拆成适合界面显示/复制的稳定文本。探测日志要由用户直接回传，
 * 所以不省略未知码，也不依赖 Set 的原始顺序。
 */
internal fun formatProbeCodeLines(
    label: String,
    codes: Collection<Int>,
    names: Map<Int, String> = emptyMap(),
): List<String> {
    val sorted = codes.distinct().sorted()
    if (sorted.isEmpty()) return listOf("$label (0): <none>")
    return sorted.chunked(PROBE_CODES_PER_LINE).mapIndexed { index, chunk ->
        val from = index * PROBE_CODES_PER_LINE + 1
        val to = from + chunk.size - 1
        "$label (${sorted.size}) [$from-$to]: " + chunk.joinToString(" ") { code ->
            names[code]?.let { "${hexCode(code)}($it)" } ?: hexCode(code)
        }
    }
}

/** 完整保留相机返回的二进制，未知/新属性可在拿不到真机时离线重新解析。 */
internal fun probeHex(data: ByteArray?): String =
    if (data == null) "<none>"
    else if (data.isEmpty()) "<empty>"
    else data.joinToString(separator = "") { "%02X".format(it.toInt() and 0xFF) }

private suspend fun logProbeCodes(
    log: suspend (String) -> Unit,
    label: String,
    codes: Collection<Int>,
    names: Map<Int, String> = emptyMap(),
) {
    formatProbeCodeLines(label, codes, names).forEach { log(it) }
}

/** 单条无 data-out 事务：发命令、收响应码+数据载荷。与正式操作共用互斥锁。 */
suspend fun NikonCamera.labCommand(code: Int, vararg params: Int): Pair<Int, ByteArray?> =
    focusMutex.withLock {
        ioMutex.withLock {
            withContext(Dispatchers.IO) {
                sendCmd(code, *params)
                recvRespWithPayload()
            }
        }
    }

/** SetDevicePropValue：把 [raw]（属性的原始小端编码）写给相机，返回响应码。 */
suspend fun NikonCamera.labSetProp(prop: Int, raw: ByteArray): Int =
    focusMutex.withLock {
        ioMutex.withLock {
            withContext(Dispatchers.IO) {
                sendCmdWithData(Lab.SET_DEVICE_PROP_VALUE, raw, prop)
                recvRespWithPayload().first
            }
        }
    }

// ============================ PTP 数据集解析 ============================

/** 数值仍由 Android 默认 Locale 渲染，shared 只决定相机语义、位数、正号与单位。 */
private fun RcValuePresentation.renderWithAndroidLocale(): String = when (this) {
    is RcValuePresentation.Text -> value
    is RcValuePresentation.Decimal -> {
        val pattern = "%${if (alwaysShowSign) "+" else ""}.${fractionDigits}f"
        prefix + pattern.format(value) + suffix
    }
}

internal fun rcDetailedFormat(prop: Int, raw: Long): String =
    rcDetailedValuePresentation(prop, raw).renderWithAndroidLocale()

/**
 * 解析标准 DevicePropDesc。即使请求参数是 Nikon 的 32 位属性编号，返回数据集里的
 * DevicePropCode 仍是标准 u16；完整编号只存在于命令参数和 0x9439 能力表中。
 */
private fun parseProbePropDescData(prop: Int, d: ByteArray): PtpDevicePropDescriptor {
    return parsePtpDevicePropDescriptor(prop, d)
}

/** 解析 DevicePropDesc 并格式化成单段日志文本。 */
private fun parsePropDesc(prop: Int, d: ByteArray): String {
    val desc = parseProbePropDescData(prop, d)
    val form = when (desc.formFlag) {
        1 ->
            "range[${rcDetailedFormat(prop, desc.rangeMin ?: 0L)}.." +
                "${rcDetailedFormat(prop, desc.rangeMax ?: 0L)} step ${desc.rangeStep}]"
        2 -> {
            // 数字变焦的全部档位正是这次探测要回收的核心信息，即使超过 12 档也不截断。
            // 其他属性仍保持紧凑展示；它们的完整二进制始终另行写入 raw 字段。
            val displayLimit = if (prop in Lab.DIGITAL_ZOOM_PROPS) Int.MAX_VALUE else 12
            val shown = desc.enumValues.take(displayLimit)
                .joinToString(",") { rcDetailedFormat(prop, it) }
            val suffix = if (desc.enumValues.size > displayLimit) ",…]" else "]"
            "enum(${desc.enumValues.size})[$shown$suffix"
        }
        else -> "none"
    }
    val curTxt =
        if (desc.currentIsScalar) "${rcDetailedFormat(prop, desc.current)} (raw=${desc.current})"
        else "<non-scalar>"
    val defTxt =
        if (desc.defaultIsScalar) rcDetailedFormat(prop, desc.defaultValue)
        else "<non-scalar>"
    return "type=${hex4(desc.dataType)} ${if (desc.writable) "RW" else "RO"} " +
        "cur=$curTxt def=$defTxt $form"
}

// ============================ 正式遥控页协议支持 ============================

/**
 * 深度探测不暴力枚举未知整数空间：只使用相机自己给出的 enum，或 range 的端点/
 * 当前值相邻一步。最多 8 档，既能反推出写法，也避免让用户等待几十秒。
 */
private fun digitalZoomProbeValues(desc: PtpDevicePropDescriptor): List<Long> {
    val candidates = when (desc.formFlag) {
        2 -> desc.enumValues
        1 -> buildList {
            desc.rangeMin?.let(::add)
            val step = desc.rangeStep
            if (step != null && step > 0L) {
                add(desc.current - step)
                add(desc.current + step)
            }
            desc.rangeMax?.let(::add)
        }.filter { value ->
            val min = desc.rangeMin
            val max = desc.rangeMax
            (min == null || value >= min) && (max == null || value <= max)
        }
        else -> emptyList()
    }
    val distinct = candidates.distinct().filter { it != desc.current }
    if (distinct.size <= 8) return distinct
    val evenlySpaced = (0 until 8).map { index ->
        distinct[index * (distinct.lastIndex) / 7]
    }
    return evenlySpaced.distinct()
}

/** 遥控参数 UI 的紧凑读数；tile 已标明 ISO/EV，因此数值中不重复单位。 */
fun rcFormat(prop: Int, raw: Long): String =
    rcCompactValuePresentation(prop, raw).renderWithAndroidLocale()

suspend fun NikonCamera.rcGetParam(prop: Int): RcParam? {
    val (rc, d) = labCommand(Lab.GET_DEVICE_PROP_DESC, prop)
    if (rc != Lab.OK || d == null) return null
    val descriptor = runCatching { parsePtpDevicePropDescriptor(d) }.getOrNull() ?: return null
    return rcParamFromDescriptor(prop, descriptor)
}

/**
 * 按机身实际 DevicePropDesc 选择可写曝光属性。优先使用有枚举值的可写属性，
 * 兼容仅暴露标准 PTP 属性或仅暴露 Nikon 厂商属性的机型。
 */
suspend fun NikonCamera.rcGetCompatibleParam(logicalProp: Int): RcParam? {
    var readableFallback: RcParam? = null
    for (actualProp in rcCompatibleExposureProps(logicalProp)) {
        val param = rcGetParam(actualProp) ?: continue
        if (param.writable && param.values.isNotEmpty()) return param
        if (readableFallback == null) readableFallback = param
    }
    return readableFallback
}

/** 只刷新标量属性的当前值，复用已取得的数据类型与值域，避免实时状态轮询重复拉描述。 */
suspend fun NikonCamera.rcRefreshParam(param: RcParam): RcParam? {
    val (rc, data) = labCommand(Lab.GET_DEVICE_PROP_VALUE, param.prop)
    if (rc != Lab.OK || data == null) return null
    val decoded = runCatching { decodePtpTypedValue(param.dataType, data) }.getOrNull()
        ?: return null
    return if (decoded.isScalar) param.copy(current = decoded.value) else null
}

/**
 * 读一次电子水平仪属性描述，供后续只刷标量值（[rcRefreshParam]）复用数据类型。
 * 机身不支持 0xD067（GetDevicePropDesc 直接失败）或值不是可解释的标量时返回 null。
 *
 * 支持性只认这一次实际响应，不查 0x90CA/0x9439 的广告清单：Nikon 厂商属性经常
 * 不出现在 DeviceInfo 与厂商码列表里却照样可读（见 docs/技术调研/无线遥控相机调研.md），
 * 直接问属性描述才是权威答案。
 */
suspend fun NikonCamera.rcGetAngleLevel(): RcParam? =
    rcGetParam(Lab.PROP_NK_ANGLE_LEVEL)?.takeIf { rcAngleLevelRoll(it) != null }

suspend fun NikonCamera.rcGetFocusMode(): RcFocusMode? {
    for (prop in rcFocusModeCandidateProps()) {
        // 对焦模式标签宁缺毋滥：只接受 GetDevicePropValue 成功直读到的当前值。
        // PropDesc 兼容回退在部分机型的失败响应里会带无效默认值 1，曾被误显示成 MF。
        val (valueRc, valueData) = labCommand(Lab.GET_DEVICE_PROP_VALUE, prop)
        val raw = if (valueRc == Lab.OK && valueData != null) {
            rcDecodeFocusModeRaw(valueData)
        } else {
            null
        } ?: continue
        rcFocusModeFromRaw(prop, raw)?.let { return it }
    }
    return null
}

suspend fun NikonCamera.rcSetValue(param: RcParam, value: Long): Int =
    labSetProp(param.prop, encodePtpScalar(param.dataType, value))

/** 写入后由机身回读得到的结果，避免把 0x2001 误当成“参数已经采用”。 */
data class RcSetResult(
    val responseCode: Int,
    val actual: RcParam?,
    val confirmed: Boolean
)

/**
 * Nikon 某些机型会在当前曝光模式或 Live View 状态下接受 SetDevicePropValue，
 * 却延迟采用甚至保持原值。写后短暂回读，并只在相机报告目标值时确认成功；
 * DeviceBusy 和“成功但未采用”各做有限重试，绝不让 UI 长期停在乐观假值上。
 */
suspend fun NikonCamera.rcSetValueVerified(param: RcParam, value: Long): RcSetResult {
    var rc = rcSetValue(param, value)
    var busyRetries = 0
    while (rc == Lab.DEVICE_BUSY && busyRetries < 2) {
        delay(120L * (busyRetries + 1))
        rc = rcSetValue(param, value)
        busyRetries++
    }
    if (rc != Lab.OK) return RcSetResult(rc, null, false)

    var actual: RcParam? = null
    suspend fun readBack(waits: LongArray): Boolean {
        for (waitMs in waits) {
            delay(waitMs)
            rcRefreshParam(param)?.let { refreshed ->
                actual = refreshed
                if (refreshed.current == value) return true
            }
        }
        return false
    }

    if (readBack(longArrayOf(40L, 90L, 160L))) {
        return RcSetResult(rc, actual, true)
    }

    // 已经能回读且仍是旧值时，给会延迟开放写入窗口的机身一次安全重发机会。
    if (actual != null) {
        delay(100)
        rc = rcSetValue(param, value)
        if (rc == Lab.OK && readBack(longArrayOf(70L, 150L))) {
            return RcSetResult(rc, actual, true)
        }
    }
    return RcSetResult(rc, actual, false)
}

private fun NikonCamera.recvFocusResponse(deadlineMs: Long): Pair<Int, ByteArray?> {
    val remaining = deadlineMs - SystemClock.elapsedRealtime()
    if (remaining <= 0L) {
        // 调用方在进入本函数前已发出命令；即使还没有开始读，其响应也
        // 必然会迟到并污染下一事务，因此同样必须废弃连接。
        abortProtocolTransport()
        throw SocketTimeoutException("Focus response deadline exceeded")
    }
    val previousTimeout = setCommandReadTimeout(
        remaining.coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
    )
    return try {
        recvRespWithPayload()
    } catch (e: SocketTimeoutException) {
        // 超时时 PacketReader 可能已消费半个包，不能继续复用该流。
        abortProtocolTransport()
        throw e
    } finally {
        runCatching { restoreCommandReadTimeout(previousTimeout) }
    }
}

/**
 * 一条完整的对焦 PTP 事务。锁只覆盖“发送 + 收完整响应”，等待 AF 状态的间隔不占锁，
 * 让 Live View 能在相机允许时穿插取帧。
 *
 * 返回 null 表示在拿到 I/O 锁前已超过整套对焦流程的截止时间，此时没有发送命令，
 * 因而不会留下迟到响应污染下一事务。
 */
private suspend fun NikonCamera.focusCommand(
    code: Int,
    deadlineMs: Long,
    vararg params: Int
): Pair<Int, ByteArray?>? = withContext(Dispatchers.IO) {
    ioMutex.withLock {
        focusCommandLocked(code, deadlineMs, *params)
    }
}

/** 调用方必须在 I/O 调度器持有 [NikonCamera.ioMutex]，用于组成严格时序的 AF 原子段。 */
private fun NikonCamera.focusCommandLocked(
    code: Int,
    deadlineMs: Long,
    vararg params: Int
): Pair<Int, ByteArray?>? {
    if (SystemClock.elapsedRealtime() >= deadlineMs) return null
    sendCmd(code, *params)
    return recvFocusResponse(deadlineMs)
}

/** 调用方必须持有 focusMutex -> ioMutex；没有活动追踪时不发送冗余命令。 */
private fun NikonCamera.endSubjectTrackingLocked(deadlineMs: Long): Int? {
    if (!subjectTrackingActive) return null
    sendCmd(Lab.NK_END_TRACKING)
    val response = recvFocusResponse(deadlineMs).first
    if (rcEndTrackingClearsActive(response)) {
        subjectTrackingActive = false
    }
    return response
}

private suspend fun NikonCamera.afDriveAndWait(
    startedAt: Long,
    deadlineMs: Long
): RcAfResult = runAfDriveAndWait(
    startedAt = startedAt,
    deadlineMs = deadlineMs,
    elapsedRealtime = SystemClock::elapsedRealtime,
    command = { code -> focusCommand(code, deadlineMs)?.first },
    pause = { durationMs -> delay(durationMs) }
)

/**
 * 按 Nikon 实机抓包时序执行一次完整自动对焦：
 *
 * 1. 只发一次 AfDrive(0x90C1)；
 * 2. 轮询 DeviceReady(0x90C8)；
 * 3. 0x2019 继续等待，0x2001 为合焦成功，0xA002 为未合焦。
 *
 * [NikonCamera.focusMutex] 防止两套 AF 流程互相穿插；[NikonCamera.ioMutex] 只保护
 * 每条完整 PTP 事务，使 Live View 能在 DeviceReady 的轮询间隔内继续取帧。
 */
suspend fun NikonCamera.rcAfDriveAndWait(timeoutMs: Long = 6_000L): RcAfResult =
    focusMutex.withLock {
        val startedAt = SystemClock.elapsedRealtime()
        val deadlineMs = startedAt + timeoutMs
        val endRc = withContext(Dispatchers.IO) {
            ioMutex.withLock { endSubjectTrackingLocked(deadlineMs) }
        }
        if (endRc != null && subjectTrackingActive) {
            RcAfResult(endRc, 0, SystemClock.elapsedRealtime() - startedAt, false)
        } else {
            afDriveAndWait(startedAt, deadlineMs)
        }
    }

/** 结束当前主体追踪；未处于追踪状态时不发送多余命令。 */
suspend fun NikonCamera.rcEndSubjectTracking(timeoutMs: Long = 6_000L): Int? =
    focusMutex.withLock {
        val deadlineMs = SystemClock.elapsedRealtime() + timeoutMs
        withContext(Dispatchers.IO) {
            ioMutex.withLock { endSubjectTrackingLocked(deadlineMs) }
        }
    }

/**
 * 在点击位置启动 Nikon 主体追踪；机身明确不支持 0x9424 时才回退单次点对焦。
 * 重新点击会先结束旧追踪，避免两个追踪生命周期互相覆盖。
 */
suspend fun NikonCamera.rcFocusAt(
    trackingX: Int,
    trackingY: Int,
    focusX: Int,
    focusY: Int,
    timeoutMs: Long = 6_000L
): RcTapFocusResult = focusMutex.withLock {
    val startedAt = SystemClock.elapsedRealtime()
    val deadlineMs = startedAt + timeoutMs
    val (endTrackingRc, start) = withContext(Dispatchers.IO) {
        ioMutex.withLock {
            val endRc = endSubjectTrackingLocked(deadlineMs)
            val startResult = if (subjectTrackingActive) {
                null
            } else {
                runTapFocusStart(
                    trackingX = trackingX,
                    trackingY = trackingY,
                    focusX = focusX,
                    focusY = focusY,
                    tryTracking = subjectTrackingSupported != false,
                    command = { code, params ->
                        focusCommandLocked(code, deadlineMs, *params)?.first
                    },
                    pause = { durationMs -> delay(durationMs) }
                )
            }
            endRc to startResult
        }
    }
    if (start != null) {
        subjectTrackingSupported = rcTrackingSupportAfterStart(
            currentSupport = subjectTrackingSupported,
            trackingResponseCode = start.trackingResponseCode,
        )
        if (start.trackingResponseCode == Lab.OK) subjectTrackingActive = true
    }
    completeTapFocus(
        endTrackingResponseCode = endTrackingRc,
        start = start,
        startedAt = startedAt,
        elapsedRealtime = SystemClock::elapsedRealtime,
        waitForStartedAf = { startResponseCode ->
            runAfReadyWait(
                startedAt = startedAt,
                deadlineMs = deadlineMs,
                startResponseCode = startResponseCode,
                elapsedRealtime = SystemClock::elapsedRealtime,
                command = { code -> focusCommand(code, deadlineMs)?.first },
                pause = { durationMs -> delay(durationMs) },
            )
        },
    )
}

suspend fun NikonCamera.rcPollEvents(): List<Pair<Int, Long>> {
    // STA 初始化已经实际验证过 GetEventEx；只在该会话使用新格式。AP/USB 继续保持
    // 原来的 GetEvent 路径，避免把一台相机的能力假设扩散到其它连接模式。
    if (staAlbumAccessValidated) {
        val (extendedResponse, extendedData) = labCommand(Lab.NK_GET_EVENT_EX)
        if (extendedResponse == Lab.OK) {
            return extendedData?.let { data ->
                runCatching { parseNikonExtendedEvents(data) }.getOrDefault(emptyList())
            }.orEmpty()
        }
        if (extendedResponse != PtpConstants.OPERATION_NOT_SUPPORTED) return emptyList()
    }

    val (response, data) = labCommand(Lab.NK_GET_EVENT)
    if (response != Lab.OK || data == null) return emptyList()
    return runCatching { parseNikonEvents(data) }.getOrDefault(emptyList())
}

/** 发单条命令，DEVICE_BUSY 时退避重试（200ms × 5）。拍摄/录像触发类命令共用。 */
private suspend fun NikonCamera.cmdBusyRetry(code: Int, vararg params: Int): Int {
    return runRemoteBusyCommand(
        command = { labCommand(code, *params).first },
        pause = { delay(it) },
    ).responseCode
}

/** 触发拍摄（无 AF、存卡）。只负责发命令；完成与新照片经事件（ObjectAdded）通知。 */
suspend fun NikonCamera.rcCapture(): Int =
    cmdBusyRetry(Lab.NK_CAPTURE_REC_IN_MEDIA, -1 /*no AF*/, 0 /*card*/)

/** 设置 Live View 分辨率（1=QVGA 2=VGA 3=XGA）。必须在 LV 关闭时调用才生效。 */
suspend fun NikonCamera.rcSetLvSize(size: Int): Int =
    labSetProp(Lab.PROP_NK_LV_IMAGE_SIZE, byteArrayOf(size.toByte()))

/** 实体照片/录像拨杆位置（LiveViewSelector 0xD1A6）：false=照片 true=录像。
 *  读不到（机型无此属性/暂不可读）返回 null，调用方按"照片"处理。 */
suspend fun NikonCamera.rcGetMovieMode(): Boolean? {
    val (rc, d) = labCommand(Lab.GET_DEVICE_PROP_VALUE, Lab.PROP_NK_LV_SELECTOR)
    if (rc != Lab.OK || d == null || d.isEmpty()) return null
    return d[0].toInt() != 0
}

/** 开始录像（存卡）。忙则重试；失败时一并返回录像禁止条件供上层决定是否重建 LV。 */
internal suspend fun NikonCamera.rcStartMovieDetailed(
    log: (String) -> Unit = {}
): RcMovieStartResult {
    val rc = cmdBusyRetry(Lab.NK_START_MOVIE_REC)
    var prohibitCondition: Long? = null
    if (rc != Lab.OK) {
        log("!! StartMovieRec resp=${hex4(rc)}")
        val (prc, pd) = labCommand(Lab.GET_DEVICE_PROP_VALUE, Lab.PROP_NK_MOV_PROHIBIT)
        if (prc == Lab.OK && pd != null && pd.size >= 4) {
            val cond = decodePtpUInt32(pd)
            prohibitCondition = cond
            if (cond != 0L) log("!! MovRecProhibit=${hex8(cond)}")
        }
    }
    return RcMovieStartResult(rc, prohibitCondition)
}

/** 执行 USB 开录序列；调用方必须已持有 ioMutex 并处于 I/O 调度器。 */
private fun NikonCamera.prepareAndStartMovieLocked(): RcMovieStartResult {
    fun command(code: Int, vararg params: Int): Pair<Int, ByteArray?> {
        sendCmd(code, *params)
        return recvRespWithPayload()
    }

    fun setProperty(prop: Int, raw: ByteArray): Int {
        sendCmdWithData(Lab.SET_DEVICE_PROP_VALUE, raw, prop)
        return recvRespWithPayload().first
    }

    fun readMovieProhibit(): Long? =
        command(
            Lab.GET_DEVICE_PROP_VALUE,
            Lab.PROP_NK_MOV_PROHIBIT
        ).let { (rc, data) ->
            if (rc == Lab.OK && data != null && data.size >= 4) decodePtpUInt32(data) else null
        }

    val prohibitExtendedRc = command(
        Lab.NK_GET_DEVICE_PROP_VALUE_EX,
        Lab.PROP_NK_MOV_PROHIBIT
    ).first
    val preflightProhibit = readMovieProhibit()
    val applicationModeRequired =
        movieProhibitRequiresApplicationMode(preflightProhibit)

    var appOpRc: Int? = null
    var appPropRc: Int? = null
    if (applicationModeRequired &&
        !remoteMovieApplicationOpSet &&
        !remoteMovieApplicationPropSet
    ) {
        val rc = command(Lab.NK_CHANGE_APP_MODE, 1).first
        appOpRc = rc
        if (rc == Lab.OK) remoteMovieApplicationOpSet = true

        // 新世代机型优先沿用已经验证的 0x9435 路径；只有相机明确表示不支持
        // 该操作码时，才回退到旧/另一世代使用的 ApplicationMode 属性入口。
        if (shouldFallbackToApplicationModeProperty(rc)) {
            val propRc = setProperty(
                Lab.PROP_NK_APPLICATION_MODE,
                byteArrayOf(1)
            )
            appPropRc = propRc
            if (propRc == Lab.OK) {
                remoteMovieApplicationPropSet = true
                // 读取一次切换后的真实禁止条件，既让相机完成属性应用，也为失败
                // 诊断保留最新状态；是否发送开录以属性写入成功为准。
                readMovieProhibit()
            }
        }
    }

    val applicationModeReady =
        !applicationModeRequired ||
            remoteMovieApplicationOpSet ||
            remoteMovieApplicationPropSet
    val startCommandRc =
        if (applicationModeReady) command(Lab.NK_START_MOVIE_REC).first else null
    val resultRc =
        startCommandRc ?: appPropRc ?: appOpRc ?: Lab.ACCESS_DENIED

    var prohibitCondition: Long? =
        if (resultRc != Lab.OK) preflightProhibit else null
    if (resultRc != Lab.OK) {
        readMovieProhibit()?.let { prohibitCondition = it }
    }

    return RcMovieStartResult(
        responseCode = resultRc,
        prohibitCondition = prohibitCondition,
        prohibitExtendedResponse = prohibitExtendedRc,
        applicationModeResponse = appOpRc,
        applicationModePropertyResponse = appPropRc,
        startCommandResponse = startCommandRc,
    )
}

/**
 * USB 远控会话内的开录原子序列。禁止条件读取、应用模式和 0x920A 共用一次
 * [NikonCamera.ioMutex]，事件轮询与取帧不能插入中途看到半切换状态或把应用模式清回去。
 * Live View 与 PTP 会话始终保持，不在这里发送 EndLiveView。
 */
internal suspend fun NikonCamera.rcPrepareAndStartMovieDetailed(
    log: (String) -> Unit = {}
): RcMovieStartResult {
    val result = focusMutex.withLock {
        ioMutex.withLock {
            withContext(Dispatchers.IO) { prepareAndStartMovieLocked() }
        }
    }
    log("Movie prepare ${result.diagnosticSummary()}")
    return result
}

/** 结束录像。忙则重试；实际停止以事件（0xC108 完成 / 0xC105 中断）为准。 */
suspend fun NikonCamera.rcEndMovie(): Int = cmdBusyRetry(Lab.NK_END_MOVIE_REC)

/**
 * 尼康完整远控模式。USB 开录前设 1，停录回普通待机时清 0；模式切换成功后，
 * 录制期间的 Live View、参数控制和录像命令始终复用同一个 PTP 会话。
 */
suspend fun NikonCamera.rcSetControlMode(enabled: Boolean): Int {
    if (enabled == remoteControlModeSet) return Lab.OK
    val rc = cmdBusyRetry(Lab.NK_SET_CONTROL_MODE, if (enabled) 1 else 0)
    if (rc != Lab.OK) return rc
    remoteControlModeSet = enabled
    return Lab.OK
}

/** 部分 Nikon 机型通过 0xD1F0 设/清应用模式；不支持该属性的机型改走 0x9435。 */
suspend fun NikonCamera.rcSetApplicationMode(on: Boolean): Int =
    labSetProp(Lab.PROP_NK_APPLICATION_MODE, byteArrayOf(if (on) 1 else 0))

/** ChangeApplicationMode（0x9435）：放行的操作码路线（属性路线不通时的备选）。 */
suspend fun NikonCamera.rcChangeApplicationMode(mode: Int): Int =
    labCommand(Lab.NK_CHANGE_APP_MODE, mode).first

/** 相机型号（DeviceInfo.Model），遥控页标题用。 */
suspend fun NikonCamera.rcModelName(): String? = deviceModel

// ============================ Live View ============================

/** 复用连接阶段缓存的 DeviceInfo 取帧能力，监看启动时不再重复查询。 */
private suspend fun NikonCamera.resolveLiveViewImageOperation() {
    if (liveViewImageOperation != null) return
    liveViewImageOperation = preferredLiveViewImageOperation(cachedDeviceInfo?.operations)
}

/**
 * 启动 Live View：Start（忙重试）→ DeviceReady 轮询直到就绪。
 * 返回是否成功；过程写入 [log]。
 */
suspend fun NikonCamera.labStartLiveView(log: suspend (String) -> Unit): Boolean {
    liveViewReadyAtElapsedMs = 0L
    resolveLiveViewImageOperation()
    val frameOperation = liveViewImageOperation ?: Lab.NK_GET_LIVE_VIEW_IMG
    log("LiveView frames: ${Lab.INTEREST_OPS[frameOperation] ?: hex4(frameOperation)}")
    // 0x2019 忙 / 0xA004 InvalidStatus（上一次 EndLiveView 后相机内部状态未落定时常见）
    // 都值得短暂重试。
    val startResult = runLiveViewStartCommand(
        command = { labCommand(Lab.NK_START_LIVE_VIEW).first },
        pause = { delay(it) },
    )
    val rc = startResult.responseCode
    val tries = startResult.completedRetries
    log((if (rc == Lab.OK) "" else "!! ") +
        "StartLiveView(0x9201) resp=${hex4(rc)}${if (tries > 0) " after $tries busy-retries" else ""}")
    if (!liveViewSessionAccepted(startResult, readyResult = null)) {
        // 失败才读禁止条件用于诊断——成功路径省掉这条往返，进页更快。
        val (prc, pd) = labCommand(Lab.GET_DEVICE_PROP_VALUE, Lab.PROP_NK_LV_PROHIBIT)
        if (prc == Lab.OK && pd != null && pd.size >= 4) {
            log("!! LV prohibit condition = ${hex8(decodePtpUInt32(pd))}")
        }
        return false
    }

    val t0 = System.currentTimeMillis()
    val readyResult = runLiveViewReadyWait(
        startedAtMs = t0,
        currentTimeMs = System::currentTimeMillis,
        command = { labCommand(Lab.NK_DEVICE_READY).first },
        pause = { delay(it) },
    )
    // 就绪属正常路径不记日志（StartLiveView 那条已标记会话启动）；没等到才值得留痕。
    if (readyResult.responseCode != Lab.OK) {
        log(
            "!! DeviceReady(0x90C8) resp=${hex4(readyResult.responseCode)} " +
                "after ${readyResult.elapsedMs}ms"
        )
    }
    liveViewReadyAtElapsedMs = SystemClock.elapsedRealtime()
    return liveViewSessionAccepted(startResult, readyResult)
}

suspend fun NikonCamera.labEndLiveView(): Int {
    val rc = focusMutex.withLock {
        ioMutex.withLock {
            withContext(Dispatchers.IO) {
                // EndLiveView 会隐式终止画面，但不能依赖它替我们闭合追踪会话；否则下次
                // 开 LV 时机身仍可能保留旧目标。错误响应不阻止继续关 LV；但若一次事务
                // 没收完整响应，流边界已不可信，必须中止连接，不能再发下一条命令误读迟到包。
                val deadlineMs = SystemClock.elapsedRealtime() + 6_000L
                try {
                    endSubjectTrackingLocked(deadlineMs)
                    subjectTrackingActive = false
                    focusCommandLocked(Lab.NK_END_LIVE_VIEW, deadlineMs)?.first ?: -1
                } catch (e: CancellationException) {
                    throw e
                } catch (_: Exception) {
                    subjectTrackingActive = false
                    abortProtocolTransport()
                    -1
                }
            }
        }
    }
    liveViewReadyAtElapsedMs = 0L
    return rc
}

/**
 * 取一帧 Live View。首次调用从 DeviceInfo 选择机身广告的增强取帧 0x9428；明确不支持时
 * 立即回退 0x9203，其它异常连续两次才回退。整包不剥离头部，BitmapFactory 直接从
 * JPEG 偏移解码，省掉热路径上每帧一次 100KB+ 的复制。
 * 相机忙返回 null（调用方稍后重试）；其它失败抛响应码异常。
 */
suspend fun NikonCamera.labGrabFrame(): LiveViewPacket? =
    ioMutex.withLock {
        withContext(Dispatchers.IO) {
            if (liveViewImageOperation == null) {
                // 正常路径已在 labStartLiveView 前解析；仅为直接调用 labGrabFrame 的
                // 诊断代码兜底，不在 LV 运行中补发 GetDeviceInfo。
                liveViewImageOperation = Lab.NK_GET_LIVE_VIEW_IMG
            }

            fun receive(operation: Int): Pair<Int, ByteArray?> {
                sendCmd(operation)
                return recvRespWithPayload()
            }

            var operation = liveViewImageOperation ?: Lab.NK_GET_LIVE_VIEW_IMG
            var (rc, data) = receive(operation)
            var soi = data?.let(::findLiveViewJpegStart) ?: -1
            val enhancedDecision = liveViewEnhancedFrameDecision(
                operation = operation,
                responseCode = rc,
                jpegFound = soi >= 0,
                previousFailureCount = liveViewEnhancedFailureCount,
            )
            liveViewEnhancedFailureCount = enhancedDecision.failureCount
            if (enhancedDecision.fallbackToBasic) {
                // 明确不支持立即降级；其它错误（包括偶发空/坏首帧）连续两次才降级，
                // 避免支持增强帧的机型因一次传输抖动永久丢失 AF 元数据。
                operation = Lab.NK_GET_LIVE_VIEW_IMG
                liveViewImageOperation = operation
                liveViewEnhancedFailureCount = 0
                val fallback = receive(operation)
                rc = fallback.first
                data = fallback.second
                soi = data?.let(::findLiveViewJpegStart) ?: -1
            }

            if (rc == Lab.DEVICE_BUSY) return@withContext null
            if (rc != Lab.OK || data == null) {
                throw Exception("${Lab.INTEREST_OPS[operation] ?: hex4(operation)} resp=${hex4(rc)}")
            }
            if (soi < 0) throw Exception("GetLiveViewImg: no JPEG SOI in ${data.size} bytes")
            LiveViewPacket(
                bytes = data,
                jpegOffset = soi,
                metadata = parseLiveViewMetadata(data, soi, operation),
                receivedAtElapsedMs = SystemClock.elapsedRealtime()
            )
        }
    }

private data class TrackingProbeCapture(
    val packets: List<LiveViewPacket>,
    val selectedFrames: List<LiveViewFocusFrame>
) {
    val motionConfirmed: Boolean get() = trackingMotionDetected(selectedFrames)
}

private data class TrackingProbeVariantResult(
    val name: String,
    val commands: List<String>,
    val capture: TrackingProbeCapture
)

private fun trackingHeaderDiff(
    baseline: ByteArray?,
    packets: List<LiveViewPacket>
): String {
    if (baseline == null || packets.isEmpty()) return "<unavailable>"
    val headerSize = minOf(baseline.size, packets.minOf { it.jpegOffset })
    val changes = buildList {
        for (offset in 0 until headerSize) {
            val before = baseline[offset].toInt() and 0xFF
            val after = packets.map { it.bytes[offset].toInt() and 0xFF }.toSet()
            if (after.size != 1 || before !in after) {
                add(
                    "+$offset:%02X>%s".format(
                        before,
                        after.take(6).joinToString("/") { "%02X".format(it) } +
                            if (after.size > 6) "/..." else ""
                    )
                )
            }
        }
    }
    if (changes.isEmpty()) return "<none>"
    return changes.take(80).joinToString(" ") +
        if (changes.size > 80) " ... (${changes.size} offsets total)" else ""
}

/**
 * Read the focus-mode context before live view starts, keeping the timed tracking section limited
 * to live-view frames and tracking commands.
 */
private suspend fun NikonCamera.logTrackingFocusProperties(
    log: suspend (String) -> Unit
) {
    suspend fun read(prop: Int, name: String) {
        val (descRc, desc) = labCommand(Lab.GET_DEVICE_PROP_DESC, prop)
        val (valueRc, value) = labCommand(Lab.GET_DEVICE_PROP_VALUE, prop)
        val parsedDesc = if (descRc == Lab.OK && desc != null) {
            runCatching { parsePropDesc(prop, desc) }.getOrElse { "parse-failed:${it.message}" }
        } else {
            "unavailable"
        }
        log(
            "TRACKING PROP ${hex4(prop)} $name desc=${hex4(descRc)} $parsedDesc " +
                "value=${hex4(valueRc)} raw=${probeHex(value)}"
        )
    }

    read(Lab.PROP_NK_STILL_FOCUS_METERING_MODE, "StillFocusMeteringMode")
    read(Lab.PROP_NK_STILL_FOCUS_MODE, "StillFocusMode")
    read(Lab.PROP_FOCUS_MODE, "FocusMode(std)")
}

/**
 * 完整探测中的主体追踪专检。这里故意尝试几种参数/顺序组合，但只使用机身自己
 * 广告的 StartTracking/EndTracking/ChangeAfArea/AfDrive。StartTracking 使用增强帧
 * +16/+18 的完整坐标系，ChangeAfArea 使用 +28/+30 的 AF 网格。仅在 StartTracking
 * 明确成功后发送 EndTracking，避免无意义的状态命令；
 * finally 只清理已经开始的追踪状态。每条协议事务自行获取 focusMutex，外层不得重复持锁。
 *
 * 判定标准不是响应码：至少三帧带相机 AF 框，且框中心跨帧移动超过 1.5% 画幅，
 * 才标记 CAMERA_FRAME_MOTION_CONFIRMED。用户应在这段探测期间缓慢移动中央主体。
 */
private suspend fun NikonCamera.runSubjectTrackingProbe(
    advertisedOps: Set<Int>,
    log: suspend (String) -> Unit,
    onFrame: suspend (ByteArray) -> Unit
): List<TrackingProbeVariantResult> {
    log("--- subject tracking controlled probe ---")
    log("ACTION: keep a textured subject near the center and move it slowly until this section ends.")
    log("SUCCESS RULE: an OK response alone is not success; camera AF-frame motion must be observed.")

    val required = setOf(Lab.NK_CHANGE_AF_AREA, Lab.NK_START_TRACKING, Lab.NK_END_TRACKING)
    val missing = required.filterNot { it in advertisedOps }
    if (missing.isNotEmpty()) {
        log("TRACKING SKIP missing advertised ops=${missing.joinToString(" ") { hex4(it) }}")
        return emptyList()
    }

    suspend fun grabPackets(count: Int): TrackingProbeCapture {
        val packets = mutableListOf<LiveViewPacket>()
        var attempts = 0
        while (packets.size < count && attempts < count * 4) {
            attempts++
            val packet = labGrabFrame()
            if (packet == null) {
                delay(40)
                continue
            }
            packets += packet
            if (packets.size == 1 || packets.size % 4 == 0) {
                onFrame(packet.bytes.copyOfRange(packet.jpegOffset, packet.bytes.size))
            }
        }
        return TrackingProbeCapture(
            packets = packets,
            selectedFrames = packets.mapNotNull { it.metadata?.selectedFocusFrame }
        )
    }

    var trackingMayBeActive = false

    suspend fun runTrackingCommand(
        label: String,
        code: Int,
        vararg params: Int
    ): Int {
        log(
            "TRACKING COMMAND $label send op=${hex4(code)} params=" +
                params.joinToString(",", prefix = "[", postfix = "]")
        )
        val rc = labCommand(code, *params).first
        if (code == Lab.NK_START_TRACKING && rc == Lab.OK) {
            trackingMayBeActive = true
            subjectTrackingActive = true
        }
        log("TRACKING COMMAND $label resp=${hex4(rc)}")
        return rc
    }

    suspend fun endTracking(label: String): Int? {
        if (!trackingMayBeActive) {
            log("TRACKING $label EndTracking SKIP reason=not-started")
            return null
        }
        log("TRACKING COMMAND $label EndTracking send op=${hex4(Lab.NK_END_TRACKING)}")
        val rc = labCommand(Lab.NK_END_TRACKING).first
        log("TRACKING $label EndTracking resp=${hex4(rc)}")
        if (rc == Lab.OK) {
            trackingMayBeActive = false
            subjectTrackingActive = false
        }
        delay(160)
        return rc
    }

    val baseline = grabPackets(5)
    val first = baseline.packets.firstOrNull()
    val trackingWidth = first?.metadata?.trackingCoordinateWidth
    val trackingHeight = first?.metadata?.trackingCoordinateHeight
    val focusWidth = first?.metadata?.focusCoordinateWidth
    val focusHeight = first?.metadata?.focusCoordinateHeight
    if (
        trackingWidth == null || trackingHeight == null ||
        focusWidth == null || focusHeight == null ||
        trackingWidth < 2 || trackingHeight < 2 || focusWidth < 2 || focusHeight < 2
    ) {
        log(
            "TRACKING SKIP enhanced AF coordinate grid unavailable; " +
                "frames=${baseline.packets.size} metadata=${baseline.packets.count { it.metadata != null }}"
        )
        return emptyList()
    }
    val trackingX = (trackingWidth - 1) / 2
    val trackingY = (trackingHeight - 1) / 2
    val focusX = (focusWidth - 1) / 2
    val focusY = (focusHeight - 1) / 2
    val baselinePacket = checkNotNull(first)
    val baselineHeader = baselinePacket.bytes.copyOfRange(0, baselinePacket.jpegOffset)
    log(
        "TRACKING baseline frames=${baseline.packets.size} selected=${baseline.selectedFrames.size} " +
            "trackingGrid=${trackingWidth}x$trackingHeight target=($trackingX,$trackingY) " +
            "focusGrid=${focusWidth}x$focusHeight target=($focusX,$focusY)"
    )
    delay(1_200)

    val results = mutableListOf<TrackingProbeVariantResult>()

    suspend fun runVariant(
        name: String,
        commands: suspend (MutableList<String>) -> Unit
    ) {
        val commandLog = mutableListOf<String>()
        commands(commandLog)
        val capture = grabPackets(18)
        val centers = capture.selectedFrames
        val xRange = centers.takeIf { it.isNotEmpty() }
            ?.let { it.maxOf { f -> f.centerX } - it.minOf { f -> f.centerX } }
        val yRange = centers.takeIf { it.isNotEmpty() }
            ?.let { it.maxOf { f -> f.centerY } - it.minOf { f -> f.centerY } }
        val frameCounts = capture.packets.mapNotNull { packet ->
            packet.bytes.takeIf { packet.jpegOffset > 45 }?.get(44)?.toInt()?.and(0xFF)
        }.groupingBy { it }.eachCount()
        val selectedIndices = capture.packets.mapNotNull { packet ->
            packet.bytes.takeIf { packet.jpegOffset > 45 }?.get(45)?.toInt()?.and(0xFF)
        }.toSet()
        log(
            "TRACKING RESULT $name commands=${commandLog.joinToString(",")} " +
                "frames=${capture.packets.size} metadata=${capture.packets.count { it.metadata != null }} " +
                "selected=${centers.size} frameCounts=$frameCounts selectedIndices=$selectedIndices " +
                "range=${xRange?.let { "%.4f".format(it) } ?: "n/a"}," +
                "${yRange?.let { "%.4f".format(it) } ?: "n/a"} verdict=" +
                if (capture.motionConfirmed) "CAMERA_FRAME_MOTION_CONFIRMED" else "NOT_CONFIRMED"
        )
        log("TRACKING HEADER_DIFF $name ${trackingHeaderDiff(baselineHeader, capture.packets)}")
        results += TrackingProbeVariantResult(name, commandLog, capture)
        val cleanupRc = endTracking("$name/cleanup")
        check(cleanupRc == null || cleanupRc == Lab.OK) {
            "$name EndTracking failed: ${hex4(checkNotNull(cleanupRc))}"
        }
    }

    try {
        runVariant("MOVE_THEN_START") { commands ->
            val move = runTrackingCommand(
                "MOVE_THEN_START/ChangeAfArea",
                Lab.NK_CHANGE_AF_AREA,
                focusX,
                focusY
            )
            commands += "ChangeAfArea=${hex4(move)}"
            delay(80)
            val start = runTrackingCommand(
                "MOVE_THEN_START/StartTracking",
                Lab.NK_START_TRACKING
            )
            commands += "StartTracking()=${hex4(start)}"
        }
        runVariant("START_THEN_MOVE") { commands ->
            val start = runTrackingCommand(
                "START_THEN_MOVE/StartTracking",
                Lab.NK_START_TRACKING
            )
            commands += "StartTracking()=${hex4(start)}"
            delay(80)
            val move = runTrackingCommand(
                "START_THEN_MOVE/ChangeAfArea",
                Lab.NK_CHANGE_AF_AREA,
                focusX,
                focusY
            )
            commands += "ChangeAfArea=${hex4(move)}"
        }
        runVariant("START_WITH_XY") { commands ->
            val start = runTrackingCommand(
                "START_WITH_XY/StartTracking",
                Lab.NK_START_TRACKING,
                trackingX,
                trackingY
            )
            commands += "StartTracking(x,y)=${hex4(start)}"
        }
        runVariant("MOVE_START_AF") { commands ->
            val move = runTrackingCommand(
                "MOVE_START_AF/ChangeAfArea",
                Lab.NK_CHANGE_AF_AREA,
                focusX,
                focusY
            )
            commands += "ChangeAfArea=${hex4(move)}"
            delay(80)
            val start = runTrackingCommand(
                "MOVE_START_AF/StartTracking",
                Lab.NK_START_TRACKING
            )
            commands += "StartTracking()=${hex4(start)}"
            if (Lab.NK_AF_DRIVE in advertisedOps) {
                delay(80)
                val af = runTrackingCommand("MOVE_START_AF/AfDrive", Lab.NK_AF_DRIVE)
                commands += "AfDrive=${hex4(af)}"
            } else {
                commands += "AfDrive=NOT_ADVERTISED"
            }
        }
    } finally {
        withContext(NonCancellable) {
            if (trackingMayBeActive) {
                runCatching { endTracking("final-cleanup") }
            }
        }
    }

    val confirmed = results.filter { it.capture.motionConfirmed }.map { it.name }
    log(
        "TRACKING VERDICT confirmed=" +
            if (confirmed.isEmpty()) "<none>" else confirmed.joinToString(",")
    )
    return results
}

// ============================ 一次性完整探测 ============================

/**
 * 完整探测：DeviceInfo 全量码表 → Nikon 厂商扩展码表 → 所有已广告属性的描述与当前值
 * （包含完整原始十六进制，便于离线分析未知属性）→ 事件轮询 → Live View 试取 8 帧
 * （经 [onFrame] 回显）→ 收尾 EndLiveView。
 *
 * 安全边界：
 * - 不调用未知操作码；只列出相机广告的操作码。
 * - 普通属性全部只读；只有明确报告为 RW、标量且给出 enum/range 的数字变焦候选
 *   会临时试写。每次写入都回读，整个档位扫描由 finally 恢复原始字节。
 * - 不把机身序列号写进可分享日志。
 * - 除相机广告的属性外，只额外只读查询 App 已知的兼容属性。
 *
 * IO 异常向上抛（socket 已死，继续无意义）；协议级失败（非 OK 响应码）逐条记录后继续。
 */
suspend fun NikonCamera.runLabProbe(
    log: suspend (String) -> Unit,
    onFrame: suspend (ByteArray) -> Unit
) {
    val t0 = System.currentTimeMillis()
    log("=== ZTransfer capability probe v9 ===")
    log(
        "scope=priority-subject-tracking-command-matrix+camera-frame-proof+" +
            "u32-vendor-codes+u32-property-params+live-view-digital-zoom-roundtrip " +
            "mode=zoom-only-temporary-writes-with-restore"
    )

    // ---- 1. DeviceInfo ----
    val info = cachedDeviceInfo
    if (info == null) log("!! DeviceInfo unavailable from connection cache")
    val ops = info?.operations ?: emptySet()
    info?.let {
        log("Model: ${it.manufacturer} ${it.model}  fw=${it.deviceVersion}")
        log(
            "VendorExt: id=${hex8(it.vendorExtId)} ver=${it.vendorExtVersion}" +
                if (it.vendorExtDesc.isBlank()) "" else " desc=${it.vendorExtDesc.replace('\n', ' ')}"
        )
        log("Serial: <omitted for privacy>")
        log("ops=${it.operations.size} events=${it.events.size} props=${it.props.size}")
        logProbeCodes(log, "DeviceInfo.operations", it.operations, Lab.INTEREST_OPS)
        logProbeCodes(log, "DeviceInfo.events", it.events)
        logProbeCodes(log, "DeviceInfo.properties", it.props, Lab.INTEREST_PROPS)
        val present = Lab.INTEREST_OPS.keys.filter { op -> op in it.operations }
        val missing = Lab.INTEREST_OPS.filterKeys { op -> op !in it.operations }
        log("remote ops OK: " + present.joinToString(" ") { op -> hex4(op) })
        if (missing.isNotEmpty()) {
            log("remote ops MISSING: " +
                    missing.entries.joinToString(" ") { (op, name) -> "${hex4(op)}($name)" })
        }
    }

    // ---- 2. 厂商属性码 ----
    var vendorProps90ca: Set<Int> = emptySet()
    if (Lab.NK_GET_VENDOR_PROP_CODES in ops) {
        val (rc, d) = labCommand(Lab.NK_GET_VENDOR_PROP_CODES)
        if (rc == Lab.OK && d != null) {
            val parsed = runCatching { parseVendorCodes16(d) }
            parsed.onSuccess {
                vendorProps90ca = it
                logProbeCodes(log, "GetVendorPropCodes(0x90CA).properties", it, Lab.INTEREST_PROPS)
            }.onFailure {
                log(
                    "!! GetVendorPropCodes(0x90CA) parse failed: ${it.message}; " +
                        "raw=${probeHex(d)}"
                )
            }
        } else log("GetVendorPropCodes(0x90CA) resp=${hex4(rc)}")
    } else {
        log("GetVendorPropCodes(0x90CA): not advertised")
    }

    // ---- 3. Z8/Z9 世代 GetVendorCodes（0x9439）----
    var vendorProps9439: Set<Int> = emptySet()
    if (Lab.NK_GET_VENDOR_CODES in ops) {
        // libgphoto2 的 Nikon 实现固定传 0x0D，并按 u32 数组接收属性码。
        val kind = 0x0D
        val (rc, d) = labCommand(Lab.NK_GET_VENDOR_CODES, kind)
        if (rc == Lab.OK && d != null) {
            // 旧探测按 u16 读取会把每个扩展码拆成“低 16 位 + 0”，正是新属性消失的根因。
            val parsed = runCatching { parseVendorCodes32(d) }
            parsed.onSuccess {
                vendorProps9439 = it
                logProbeCodes(
                    log,
                    "GetVendorCodes(0x9439,0x0D).properties",
                    it,
                    Lab.INTEREST_PROPS
                )
            }.onFailure {
                log(
                    "!! GetVendorCodes(0x9439,0x0D) parse failed: ${it.message}; " +
                        "raw=${probeHex(d)}"
                )
            }
        } else {
            log("GetVendorCodes(0x9439, 0x0D) resp=${hex4(rc)}")
        }
    } else {
        log("GetVendorCodes(0x9439): not advertised")
    }

    val allAdvertisedOps = ops
    val advertised = (info?.props ?: emptySet()) + vendorProps90ca + vendorProps9439
    logProbeCodes(log, "Merged.operations", allAdvertisedOps, Lab.INTEREST_OPS)
    logProbeCodes(log, "Merged.properties", advertised, Lab.INTEREST_PROPS)
    log(
        "PowerZoom opcode ${hex4(Lab.NK_POWER_ZOOM_BY_FOCAL_LENGTH)}: " +
            if (Lab.NK_POWER_ZOOM_BY_FOCAL_LENGTH in allAdvertisedOps) "ADVERTISED"
            else "NOT_ADVERTISED"
    )

    // ---- 4. 所有已广告属性 + App 已知隐藏属性的 GetDevicePropDesc/GetDevicePropValue ----
    // Subject tracking is why this probe is currently being run. Keep it ahead of the exhaustive
    // property survey: that survey can take several minutes on bodies with hundreds of vendor
    // properties, so a report copied before completion must still contain the tracking evidence.
    var lvOk = false
    var trackingProbeResults: List<TrackingProbeVariantResult> = emptyList()
    log("--- priority subject-tracking live view test ---")
    if (Lab.NK_START_LIVE_VIEW !in ops) {
        log("StartLiveView not advertised - trying anyway")
    }
    logTrackingFocusProperties(log)
    if (labStartLiveView(log)) {
        lvOk = true
        try {
            trackingProbeResults = runSubjectTrackingProbe(ops, log, onFrame)
        } finally {
            withContext(NonCancellable) {
                val endRc = runCatching { labEndLiveView() }.getOrNull()
                log(
                    if (endRc != null) {
                        "Priority tracking EndLiveView(0x9202) resp=${hex4(endRc)}"
                    } else {
                        "!! Priority tracking EndLiveView(0x9202) failed"
                    }
                )
            }
        }
    }
    val earlyConfirmedTracking = trackingProbeResults
        .filter { it.capture.motionConfirmed }
        .joinToString(",") { it.name }
    log(
        "PRIORITY TRACKING SUMMARY: " +
            if (earlyConfirmedTracking.isNotEmpty()) {
                "CAMERA_FRAME_MOTION_CONFIRMED via=$earlyConfirmedTracking"
            } else if (trackingProbeResults.isNotEmpty()) {
                "NOT_CONFIRMED (inspect TRACKING RESULT/HEADER_DIFF above)"
            } else {
                "NOT_TESTED"
            }
    )

    val probeProps = (advertised + Lab.INTEREST_PROPS.keys).sorted()
    var descOkCount = 0
    var valueOkCount = 0
    val digitalZoomDesc = mutableMapOf<Int, String>()
    val digitalZoomValue = mutableMapOf<Int, String>()
    val digitalZoomParsedDesc = mutableMapOf<Int, PtpDevicePropDescriptor>()
    val digitalZoomDescRoute = mutableMapOf<Int, Int>()
    val digitalZoomValueRoute = mutableMapOf<Int, Int>()
    val digitalZoomValueRaw = mutableMapOf<Int, ByteArray>()
    val digitalZoomSweepResult = mutableMapOf<Int, String>()
    val digitalZoomControlConfirmed = mutableSetOf<Int>()
    log("--- property survey (${probeProps.size}) ---")
    log("Each DESC/VALUE raw field is complete little-endian payload; unknown codes are intentional.")
    for ((index, prop) in probeProps.withIndex()) {
        val name = Lab.INTEREST_PROPS[prop] ?: "Unknown"
        val sources = buildList {
            if (prop in (info?.props ?: emptySet())) add("device")
            if (prop in vendorProps90ca) add("90CA")
            if (prop in vendorProps9439) add("9439")
            if (prop in Lab.INTEREST_PROPS && prop !in advertised) add("known-fallback")
        }.joinToString("+").ifEmpty { "unknown" }

        // PTP 命令参数本身是 u32，0x1D033 直接以完整 Int 传给标准 0x1014。
        val descOp = Lab.GET_DEVICE_PROP_DESC
        val (rc, d) = labCommand(descOp, prop)
        if (rc == Lab.OK && d != null) {
            descOkCount++
            val parsed = runCatching { parsePropDesc(prop, d) }
            val txt = parsed.getOrElse { "parse failed: ${it.message}" }
            log(
                "PROP ${index + 1}/${probeProps.size} ${hexCode(prop)} $name " +
                    "src=$sources DESC via=${hex4(descOp)} resp=${hex4(rc)} " +
                    "bytes=${d.size} $txt raw=${probeHex(d)}"
            )
            if (prop in Lab.DIGITAL_ZOOM_PROPS) {
                digitalZoomDesc[prop] = "OK $txt"
                runCatching { parseProbePropDescData(prop, d) }.getOrNull()?.let {
                    digitalZoomParsedDesc[prop] = it
                    digitalZoomDescRoute[prop] = descOp
                }
            }
        } else {
            log(
                "PROP ${index + 1}/${probeProps.size} ${hexCode(prop)} $name " +
                    "src=$sources DESC via=${hex4(descOp)} resp=${hex4(rc)} " +
                    "bytes=${d?.size ?: 0} raw=${probeHex(d)}"
            )
            if (prop in Lab.DIGITAL_ZOOM_PROPS) {
                digitalZoomDesc[prop] = "resp=${hex4(rc)}"
            }
        }

        // 数字变焦候选即使没有出现在 DeviceInfo 中也强制只读查询。Nikon 的隐藏厂商
        // 属性经常可用却不广告；失败只会返回响应码，不会改变相机状态。
        val valueOp = Lab.GET_DEVICE_PROP_VALUE
        val readValue = valueOp in allAdvertisedOps ||
            prop in Lab.DIGITAL_ZOOM_PROPS
        if (readValue) {
            val (vrc, vd) = labCommand(valueOp, prop)
            if (vrc == Lab.OK && vd != null) valueOkCount++
            log(
                "PROP ${index + 1}/${probeProps.size} ${hexCode(prop)} $name " +
                    "VALUE via=${hex4(valueOp)} resp=${hex4(vrc)} " +
                    "bytes=${vd?.size ?: 0} raw=${probeHex(vd)}"
            )
            if (prop in Lab.DIGITAL_ZOOM_PROPS) {
                digitalZoomValue[prop] =
                    "resp=${hex4(vrc)} bytes=${vd?.size ?: 0} raw=${probeHex(vd)}"
                if (vrc == Lab.OK && vd != null) {
                    digitalZoomValueRaw[prop] = vd
                    digitalZoomValueRoute[prop] = valueOp
                }
            }
        } else if (index == 0) {
            log("GetDevicePropValue(0x1015): not advertised; VALUE survey skipped")
        }

        if ((index + 1) % 20 == 0 || index == probeProps.lastIndex) {
            log(
                "property progress=${index + 1}/${probeProps.size} " +
                    "descOK=$descOkCount valueOK=$valueOkCount"
            )
        }
    }

    // ---- 5. 数字变焦专检汇总 ----
    // DESC 中 RW/RO 决定能否控制，enum/range 给出完整档位；VALUE 保留当前值原始编码。
    // 这里只汇总上面的只读结果，不重复发命令。
    val probeMovieMode = runCatching { rcGetMovieMode() }.getOrNull()
    log("--- digital zoom focus ---")
    log(
        "DIGITAL_ZOOM camera-selector=" +
            when (probeMovieMode) {
                true -> "MOVIE"
                false -> "PHOTO"
                null -> "UNKNOWN"
            }
    )
    Lab.DIGITAL_ZOOM_PROPS.forEach { (prop, name) ->
        val meaning = when (prop) {
            Lab.PROP_NK_LV_IMAGE_ZOOM_RATIO -> "live-view-magnification-ratio"
            Lab.PROP_NK_LV_ZOOM_AREA -> "live-view-magnified-area"
            Lab.PROP_NK_HI_RES_ZOOM -> "movie-hi-res-digital-zoom"
            else -> "captured-output-digital-zoom"
        }
        log(
            "DIGITAL_ZOOM ${hexCode(prop)} $name meaning=$meaning " +
                "advertised=${if (prop in advertised) "YES" else "NO"} " +
                "DESC ${digitalZoomDesc[prop] ?: "NOT_QUERIED"} " +
                "VALUE ${digitalZoomValue[prop] ?: "NOT_QUERIED"}"
        )
    }
    log("DIGITAL_ZOOM 32-bit property IDs use standard PTP 0x1014/0x1015/0x1016")
    log(
        "DIGITAL_ZOOM note: the live-view stage repeats reads after LV starts; " +
            "RW scalar enum/range properties are temporarily swept and restored."
    )
    if (probeMovieMode != true) {
        log(
            "DIGITAL_ZOOM note: Hi-Res Zoom may only be exposed in movie mode; " +
                "if 0x1D033 is unavailable, move the physical selector to movie and probe again."
        )
    }

    // ---- 6. 电子水平仪 AngleLevel (0xD067) 专检 ----
    // Z 30 为首要目标机身，此属性是水平仪唯一数据源（libgphoto2 ptp.h 定义
    // PTP_DPC_NIKON_AngleLevel = 0xD067，Z 30/Z 50/Z 8/Z 9/Z 6iii 全世代共用）。
    // 属性不支持 = toggle 拒绝锁存 + devLog，不画假角度。
    val (alrc, ald) = labCommand(Lab.GET_DEVICE_PROP_VALUE, Lab.PROP_NK_ANGLE_LEVEL)
    if (alrc == Lab.OK && ald != null && ald.size >= 4) {
        val raw = ald.indices.fold(0L) { acc, i ->
            acc or ((ald[i].toLong() and 0xFF) shl (8 * i))
        }
        val rollDeg = raw / 65536.0   // 16.16 定点度数
        log("AngleLevel(0xD067) raw=$raw (INT32 16.16 fixed) roll=%.1f° source=0xD067 poll".format(rollDeg))
    } else {
        log("!! AngleLevel(0xD067) resp=${hex4(alrc)} — level NOT available on this body")
    }

    // ---- 7. 事件轮询 ----
    if (Lab.NK_GET_EVENT in ops) {
        val (rc, d) = labCommand(Lab.NK_GET_EVENT)
        if (rc == Lab.OK && d != null) {
            val evts = runCatching { parseNikonEvents(d) }.getOrDefault(emptyList())
            log("GetEvent(0x90C7): ${evts.size} pending" +
                    if (evts.isEmpty()) "" else " " + evts.joinToString(" ") { (c, p) -> "${hex4(c)}(${hex8(p)})" })
        } else log("GetEvent(0x90C7) resp=${hex4(rc)}")
    }

    suspend fun readDigitalZoomInLiveView() {
        log("--- digital zoom live-view re-read ---")
        for ((prop, name) in Lab.DIGITAL_ZOOM_PROPS) {
            val descRoute = Lab.GET_DEVICE_PROP_DESC
            val (descRc, descData) = labCommand(descRoute, prop)
            val parsed =
                if (descRc == Lab.OK && descData != null) {
                    runCatching { parseProbePropDescData(prop, descData) }
                } else {
                    null
                }
            val descDetail =
                parsed?.fold(
                    onSuccess = {
                        "${parsePropDesc(prop, checkNotNull(descData))} raw=${probeHex(descData)}"
                    },
                    onFailure = {
                        "parse_failed=${it.message} raw=${probeHex(descData)}"
                    }
                ) ?: "raw=${probeHex(descData)}"
            log(
                "DIGITAL_ZOOM_READ stage=live-view prop=${hexCode(prop)} $name " +
                    "DESC via=${hex4(descRoute)} resp=${hex4(descRc)} " +
                    "bytes=${descData?.size ?: 0} $descDetail"
            )
            parsed?.getOrNull()?.let { descriptor ->
                digitalZoomParsedDesc[prop] = descriptor
                digitalZoomDescRoute[prop] = descRoute
                digitalZoomDesc[prop] =
                    "OK ${parsePropDesc(prop, checkNotNull(descData))} via=${hex4(descRoute)}"
            }

            val valueRoute = Lab.GET_DEVICE_PROP_VALUE
            val (valueRc, valueData) = labCommand(valueRoute, prop)
            log(
                "DIGITAL_ZOOM_READ stage=live-view prop=${hexCode(prop)} $name " +
                    "VALUE via=${hex4(valueRoute)} resp=${hex4(valueRc)} " +
                    "bytes=${valueData?.size ?: 0} raw=${probeHex(valueData)}"
            )
            if (valueRc == Lab.OK && valueData != null) {
                digitalZoomValueRaw[prop] = valueData
                digitalZoomValueRoute[prop] = valueRoute
                digitalZoomValue[prop] =
                    "resp=${hex4(valueRc)} bytes=${valueData.size} " +
                        "raw=${probeHex(valueData)} via=${hex4(valueRoute)}"
            }
        }
    }

    suspend fun sweepWritableDigitalZoom() {
        log("--- digital zoom controlled write/readback sweep ---")
        for ((prop, name) in Lab.DIGITAL_ZOOM_PROPS) {
            val desc = digitalZoomParsedDesc[prop]
            val original = digitalZoomValueRaw[prop]
            val valueRoute = digitalZoomValueRoute[prop]
            val descRoute = digitalZoomDescRoute[prop]
            val scalarBytes = desc?.let { ptpScalarSize(it.dataType) }
            val writeRoute =
                if (
                    descRoute == Lab.GET_DEVICE_PROP_DESC &&
                    Lab.SET_DEVICE_PROP_VALUE in allAdvertisedOps
                ) {
                    Lab.SET_DEVICE_PROP_VALUE
                } else {
                    null
                }
            val skipReason = when {
                desc == null -> "no-parseable-desc"
                !desc.writable -> "read-only"
                !desc.currentIsScalar || scalarBytes == null -> "non-scalar"
                original == null || valueRoute == null -> "no-readable-current-value"
                original.size != scalarBytes ->
                    "value-size-${original.size}-expected-$scalarBytes"
                writeRoute == null -> "no-matching-advertised-set-route"
                else -> null
            }
            if (skipReason != null) {
                digitalZoomSweepResult[prop] = "SKIP($skipReason)"
                log(
                    "DIGITAL_ZOOM_SWEEP prop=${hexCode(prop)} $name SKIP reason=$skipReason"
                )
                continue
            }

            val activeDesc = checkNotNull(desc)
            val originalRaw = checkNotNull(original)
            val activeDescRoute = checkNotNull(descRoute)
            val activeValueRoute = checkNotNull(valueRoute)
            val activeWriteRoute = checkNotNull(writeRoute)
            val candidates = digitalZoomProbeValues(activeDesc).map {
                it to encodePtpScalar(activeDesc.dataType, it)
            }.filter { (_, raw) -> !raw.contentEquals(originalRaw) }
            if (candidates.isEmpty()) {
                digitalZoomSweepResult[prop] = "SKIP(no-alternate-enum-or-range-value)"
                log(
                    "DIGITAL_ZOOM_SWEEP prop=${hexCode(prop)} $name SKIP " +
                        "reason=no-alternate-enum-or-range-value"
                )
                continue
            }

            log(
                "DIGITAL_ZOOM_SWEEP prop=${hexCode(prop)} $name " +
                    "descVia=${hex4(activeDescRoute)} readVia=${hex4(activeValueRoute)} " +
                    "writeVia=${hex4(activeWriteRoute)} type=${hex4(activeDesc.dataType)} " +
                    "original=${probeHex(originalRaw)} candidates=" +
                    candidates.joinToString(",") { (value, raw) ->
                        "$value:${probeHex(raw)}"
                    }
            )

            var acceptedValues = 0
            var sweepError: String? = null
            try {
                for ((value, raw) in candidates) {
                    val setRc = labSetProp(prop, raw)
                    delay(220)
                    val (readRc, readRaw) = labCommand(activeValueRoute, prop)
                    val changed = readRc == Lab.OK && readRaw != null &&
                        !readRaw.contentEquals(originalRaw)
                    val matched = readRc == Lab.OK && readRaw?.contentEquals(raw) == true
                    if (setRc == Lab.OK && matched) {
                        acceptedValues++
                        digitalZoomControlConfirmed += prop
                    }
                    log(
                        "DIGITAL_ZOOM_STEP prop=${hexCode(prop)} requested=$value " +
                            "write=${hex4(setRc)} read=${hex4(readRc)} " +
                            "readRaw=${probeHex(readRaw)} changed=$changed matched=$matched"
                    )
                    if (setRc != Lab.OK) break

                    if (Lab.NK_GET_EVENT in allAdvertisedOps) {
                        val (eventRc, eventData) = labCommand(Lab.NK_GET_EVENT)
                        val events = if (eventRc == Lab.OK && eventData != null) {
                            runCatching { parseNikonEvents(eventData) }.getOrDefault(emptyList())
                        } else {
                            emptyList()
                        }
                        log(
                            "DIGITAL_ZOOM_STEP events resp=${hex4(eventRc)} " +
                                events.joinToString(" ") { (code, param) ->
                                    "${hex4(code)}(${hex8(param)})"
                                }.ifEmpty { "<none>" }
                        )
                    }
                    if (Lab.NK_GET_EVENT_EX in allAdvertisedOps) {
                        val (eventExRc, eventExData) = labCommand(Lab.NK_GET_EVENT_EX)
                        log(
                            "DIGITAL_ZOOM_STEP eventsEx resp=${hex4(eventExRc)} " +
                                "bytes=${eventExData?.size ?: 0} raw=${probeHex(eventExData)}"
                        )
                    }

                    var frameInfo: LiveViewPacket? = null
                    repeat(6) {
                        if (frameInfo == null) {
                            frameInfo = labGrabFrame()
                            if (frameInfo == null) delay(40)
                        }
                    }
                    frameInfo?.let { packet ->
                        val jpeg =
                            packet.bytes.copyOfRange(packet.jpegOffset, packet.bytes.size)
                        val crc = CRC32().apply { update(jpeg) }.value
                        log(
                            "DIGITAL_ZOOM_STEP frame bytes=${jpeg.size} " +
                                "jpegOffset=${packet.jpegOffset} crc32=${hex8(crc)}"
                        )
                        onFrame(jpeg)
                        delay(300)
                    } ?: log("DIGITAL_ZOOM_STEP frame=<unavailable>")
                }
            } catch (probeError: Exception) {
                if (probeError is CancellationException) throw probeError
                sweepError = "${probeError.javaClass.simpleName}:${probeError.message}"
                log(
                    "!! DIGITAL_ZOOM_SWEEP prop=${hexCode(prop)} FAILED $sweepError"
                )
            } finally {
                // 用户退出页面会取消探测协程；恢复必须脱离取消状态继续执行。
                withContext(NonCancellable) {
                    try {
                        val restoreRc = labSetProp(prop, originalRaw)
                        delay(180)
                        val (verifyRc, verifyRaw) = labCommand(activeValueRoute, prop)
                        val restored =
                            verifyRc == Lab.OK && verifyRaw?.contentEquals(originalRaw) == true
                        digitalZoomSweepResult[prop] =
                            "accepted=$acceptedValues/${candidates.size} restored=$restored " +
                                "writeVia=${hex4(activeWriteRoute)}" +
                                (sweepError?.let { " error=$it" } ?: "")
                        log(
                            "DIGITAL_ZOOM_RESTORE prop=${hexCode(prop)} " +
                                "write=${hex4(restoreRc)} verify=${hex4(verifyRc)} " +
                                "raw=${probeHex(verifyRaw)} restored=$restored"
                        )
                    } catch (restoreError: Exception) {
                        digitalZoomSweepResult[prop] =
                            "accepted=$acceptedValues/${candidates.size} restore=FAILED " +
                                "error=${restoreError.message}"
                        log(
                            "!! DIGITAL_ZOOM_RESTORE prop=${hexCode(prop)} FAILED " +
                                "${restoreError.javaClass.simpleName}: ${restoreError.message}"
                        )
                    }
                }
            }
        }
    }

    // ---- 8. Live View 试取帧 ----
    log("--- live view test ---")
    if (Lab.NK_START_LIVE_VIEW !in ops) log("StartLiveView not advertised - trying anyway")
    if (labStartLiveView(log)) {
        lvOk = true
        try {
            readDigitalZoomInLiveView()
            sweepWritableDigitalZoom()
            var got = 0
            var totalMs = 0L
            var attempts = 0
            var lastTotal = 0
            var soiOff = -1
            try {
                while (got < 8 && attempts < 30) {
                    attempts++
                    val f0 = System.currentTimeMillis()
                    val frame = labGrabFrame()
                    if (frame == null) { delay(40); continue }
                    val ms = System.currentTimeMillis() - f0
                    val (buf, soi) = frame
                    got++
                    totalMs += ms
                    lastTotal = buf.size
                    soiOff = soi
                    onFrame(buf.copyOfRange(soi, buf.size))   // 探测仅 8 帧，拷贝无所谓
                }
                // 逐帧不打印，只汇总一行（帧大小/头偏移/平均耗时足够定位问题）
                if (got > 0) {
                    log(
                        "LV: $got frames ok / $attempts polls, ~${lastTotal / 1024}KB " +
                            "jpeg@$soiOff, avg ${totalMs / got}ms " +
                            "(~%.1f fps ceiling)".format(1000f / (totalMs / got))
                    )
                }
            } catch (e: Exception) {
                if (e is CancellationException) throw e
                log("!! LV frame error: ${e.message}")
            }
        } finally {
            withContext(NonCancellable) {
                val endRc = runCatching { labEndLiveView() }.getOrNull()
                log(
                    if (endRc != null) {
                        "EndLiveView(0x9202) resp=${hex4(endRc)}"
                    } else {
                        "!! EndLiveView(0x9202) failed"
                    }
                )
            }
        }
    }

    // ---- 9. 结论 ----
    log("--- verdict ---")
    log("property survey: $descOkCount/${probeProps.size} desc, $valueOkCount/${probeProps.size} value")
    log(
        "power zoom op:   " +
            if (Lab.NK_POWER_ZOOM_BY_FOCAL_LENGTH in allAdvertisedOps) {
                "${hex4(Lab.NK_POWER_ZOOM_BY_FOCAL_LENGTH)} ADVERTISED"
            } else {
                "NOT ADVERTISED"
            }
    )
    log("live view:      ${if (lvOk) "YES" else "NO"}")
    val confirmedTracking = trackingProbeResults
        .filter { it.capture.motionConfirmed }
        .joinToString(",") { it.name }
    log(
        "subject tracking: " +
            if (confirmedTracking.isNotEmpty()) {
                "CAMERA_FRAME_MOTION_CONFIRMED via=$confirmedTracking"
            } else if (trackingProbeResults.isNotEmpty()) {
                "NOT_CONFIRMED (inspect TRACKING RESULT/HEADER_DIFF)"
            } else {
                "NOT_TESTED"
            }
    )
    log(
        "live-view zoom: " +
            if (digitalZoomDesc[Lab.PROP_NK_LV_IMAGE_ZOOM_RATIO]?.startsWith("OK ") == true) {
                "0xD1A3 DESC_OK (inspect RW/RO and levels above)"
            } else {
                "0xD1A3 UNAVAILABLE"
            }
    )
    log(
        "digital zoom:   " +
            if (digitalZoomDesc[Lab.PROP_DIGITAL_ZOOM]?.startsWith("OK ") == true) {
                "0x5016 DESC_OK (inspect RW/RO and levels above)"
            } else {
                "0x5016 UNAVAILABLE"
            }
    )
    log(
        "hi-res zoom:    " +
            if (digitalZoomDesc[Lab.PROP_NK_HI_RES_ZOOM]?.startsWith("OK ") == true) {
                "0x1D033 DESC_OK (extended Nikon property)"
            } else {
                "0x1D033 UNAVAILABLE"
            }
    )
    log(
        "zoom area:      " +
            if (digitalZoomDesc[Lab.PROP_NK_LV_ZOOM_AREA]?.startsWith("OK ") == true) {
                "0xD1BD DESC_OK (inspect payload/RO status above)"
            } else {
                "0xD1BD UNAVAILABLE"
            }
    )
    Lab.DIGITAL_ZOOM_PROPS.forEach { (prop, name) ->
        val control =
            if (prop in digitalZoomControlConfirmed) "REMOTE_CONTROL_CONFIRMED"
            else "not-confirmed"
        log(
            "zoom candidate ${hexCode(prop)} $name: $control; " +
                "sweep=${digitalZoomSweepResult[prop] ?: "NOT_RUN"}"
        )
    }
    log("angle level:    ${if (alrc == Lab.OK && ald != null && ald.size >= 4) "0xD067 OK" else "UNAVAILABLE"}")
    log("capture opcode: ${if (Lab.NK_CAPTURE_REC_IN_MEDIA in ops || Lab.NK_CAPTURE_REC_IN_SDRAM in ops) "advertised" else "MISSING"}")
    log("event polling:  ${if (Lab.NK_GET_EVENT in ops || Lab.NK_GET_EVENT_EX in ops) "advertised" else "MISSING"}")
    log("=== probe done in ${System.currentTimeMillis() - t0}ms ===")
}

