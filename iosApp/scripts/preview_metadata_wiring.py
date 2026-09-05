"""Exact original preview metadata extraction; Android keeps its platform decimal renderers."""

ORIGINAL_DATE = 'internal fun formatPreviewCaptureDate(raw: String?): String? {\n    if (raw == null || raw.length < 8 || !raw.take(8).all(Char::isDigit)) return null\n    val year = raw.substring(0, 4).toInt()\n    val month = raw.substring(4, 6).toInt()\n    val day = raw.substring(6, 8).toInt()\n    runCatching { java.time.LocalDate.of(year, month, day) }.getOrNull() ?: return null\n    val date = "%04d-%02d-%02d".format(year, month, day)\n    if (raw.length < 15 || raw[8] != \'T\' || !raw.substring(9, 15).all(Char::isDigit)) {\n        return date\n    }\n    val hour = raw.substring(9, 11).toInt()\n    val minute = raw.substring(11, 13).toInt()\n    val second = raw.substring(13, 15).toInt()\n    runCatching { java.time.LocalTime.of(hour, minute, second) }.getOrNull() ?: return date\n    return "$date %02d:%02d:%02d".format(hour, minute, second)\n}\n'

DELEGATED_DATE = 'internal fun formatPreviewCaptureDate(raw: String?): String? = previewCaptureDateText(raw,\n    dateText = { year, month, day -> "%04d-%02d-%02d".format(year, month, day) },\n    timeText = { hour, minute, second -> "%02d:%02d:%02d".format(hour, minute, second) },\n)\n'

ORIGINAL_VIDEO = 'internal fun videoPreviewMetadata(\n    fileSize: Long,\n    captureDate: String?,\n    overFourGbLabel: String,\n): String = listOfNotNull(\n    when {\n        fileSize == PtpConstants.SIZE_UNKNOWN || fileSize > FOUR_GIB_BYTES -> overFourGbLabel\n        fileSize > 0L -> formatFileSize(fileSize)\n        else -> null\n    },\n    formatPreviewCaptureDate(captureDate),\n).joinToString("  ·  ")\n'

DELEGATED_VIDEO = 'internal fun videoPreviewMetadata(\n    fileSize: Long,\n    captureDate: String?,\n    overFourGbLabel: String,\n): String = previewVideoMetadataText(fileSize, captureDate, overFourGbLabel,\n    sizeText = ::formatFileSize, captureText = ::formatPreviewCaptureDate)\n'

def delegate_preview_metadata(value):
    for original, delegated in ((ORIGINAL_DATE, DELEGATED_DATE), (ORIGINAL_VIDEO, DELEGATED_VIDEO)):
        assert value.count(original) == 1
        value = value.replace(original, delegated, 1)
    return value


def restore_preview_metadata(value):
    for original, delegated in ((ORIGINAL_DATE, DELEGATED_DATE), (ORIGINAL_VIDEO, DELEGATED_VIDEO)):
        assert value.count(delegated) == 1
        value = value.replace(delegated, original, 1)
    return value


MODEL_FIELDS = '''    fun previewDateText(year: Int, month: Int, day: Int): String
    fun previewTimeText(hour: Int, minute: Int, second: Int): String
'''
MODEL_FORMAT = '''    internal fun previewMetadata(file: CameraFileInfo, overFourGbLabel: String): String {
        val owner = platform ?: return ""
        return previewVideoMetadataText(file.size, file.captureDate, overFourGbLabel,
            sizeText = { com.ztransfer.format.formatFileSizeText(it, queue::fixed) },
            captureText = { previewCaptureDateText(it, owner::previewDateText, owner::previewTimeText) })
    }

'''
PAGE_FORMAT = '''    func previewDateText(year: Int32, month: Int32, day: Int32) -> String {
        ApplePreviewDateText.date(year: year, month: month, day: day)
    }
    func previewTimeText(hour: Int32, minute: Int32, second: Int32) -> String {
        ApplePreviewDateText.time(hour: hour, minute: minute, second: second)
    }

'''


def remove_once(value, addition):
    assert value.count(addition) == 1
    return value.replace(addition, '', 1)


def without_metadata_model(value):
    return remove_once(remove_once(value, MODEL_FIELDS), MODEL_FORMAT)


def without_metadata_page(value):
    return remove_once(value, PAGE_FORMAT)
