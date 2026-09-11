"""Explicit baseline transforms for the shared signal pill, including the Android settings adapter."""
from transfer_card_extraction import replace_once

HEADER = '''package com.ztransfer.ui.screen

import androidx.compose.animation.*
import androidx.compose.animation.core.*
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.*
import androidx.compose.ui.graphics.*
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.ztransfer.protocol.CameraConnectionType
import com.ztransfer.ui.theme.*

data class SignalPillText(
    val notConnected: String,
    val usb: String,
    val staConnected: String,
    val staDisconnected: String,
    val signalUnavailable: String,
)

'''

ANDROID_BODY = '''    val context = LocalContext.current
    SharedSignalPill(
        rssi = rssi, connected = connected, pulseTrigger = pulseTrigger,
        connectionType = connectionType, staMode = staMode,
        onStaDisconnectedClick = onStaDisconnectedClick,
        text = SignalPillText(
            notConnected = stringResource(R.string.camera_not_connected),
            usb = stringResource(R.string.connection_usb),
            staConnected = stringResource(R.string.sta_signal_connected),
            staDisconnected = stringResource(R.string.sta_signal_disconnected_reconnect),
            signalUnavailable = "", // Android retains its original RSSI-required AP behavior.
        ),
        onOpenWifiSettings = {
            try { context.startActivity(Intent(Settings.ACTION_WIFI_SETTINGS)) } catch (_: Exception) {}
        },
    )
}

'''


def extract_signal_pill(source):
    source = source.replace('\r\n', '\n')
    palette_start = source.index('internal data class SignalBarPalette(')
    palette_end = source.index('/** RSSI 的周期更新', palette_start)
    palette = source[palette_start:palette_end]
    start = source.index('@Composable\nfun SignalPill(')
    end = source.index('@Composable\nprivate fun GroupHeader(', start)
    old_pill = source[start:end]
    helpers_start = old_pill.index('private enum class SignalPillMode')
    pill = old_pill[:helpers_start]
    helpers = old_pill[helpers_start:]
    usb_start = source.index('/** 经典 USB 三叉标：')
    usb_end = source.index('@Composable\nprivate fun LoadingMoreRow()', usb_start)
    usb = source[usb_start:usb_end]
    signature_end = pill.index('    val colors = AppTheme.colors')
    android_pill = pill[:signature_end] + ANDROID_BODY
    pill = replace_once(pill, 'fun SignalPill(', 'fun SharedSignalPill(')
    pill = replace_once(pill, '    rssi: Int?,', '    text: SignalPillText,\n    onOpenWifiSettings: () -> Unit,\n    allowUnknownRssi: Boolean = false,\n    rssi: Int?,')
    pill = replace_once(pill, '    val context = LocalContext.current\n', '')
    pill = replace_once(pill, '''else if (!usbMode) try {
                context.startActivity(Intent(Settings.ACTION_WIFI_SETTINGS))
            } catch (_: Exception) {}''', 'else if (!usbMode) onOpenWifiSettings()')
    pill = replace_once(pill, 'val online = connected && (usbMode || staMode || rssi != null)',
        'val online = signalPillOnline(connected, usbMode, staMode, rssi, allowUnknownRssi)\n    val unknownSignal = online && !usbMode && !staMode && rssi == null')
    pill = replace_once(pill, '        level == 4 -> colors.statusConnected', '        unknownSignal -> colors.accentBlue\n        level == 4 -> colors.statusConnected')
    pill = replace_once(pill, 'else if (online) expanded = !expanded', 'else if (online && !unknownSignal) expanded = !expanded')
    # An unknown-strength online connection must not fall through to the offline settings action.
    pill = replace_once(pill, 'else if (!usbMode) onOpenWifiSettings()', 'else if (!online && !usbMode) onOpenWifiSettings()')
    pill = replace_once(pill, '                    online -> SignalPillMode.WIFI_ONLINE', '                    unknownSignal -> SignalPillMode.WIFI_UNKNOWN\n                    online -> SignalPillMode.WIFI_ONLINE')
    pill = replace_once(pill, '                    SignalPillMode.WIFI_OFFLINE -> Icon(', '''                    SignalPillMode.WIFI_UNKNOWN -> Icon(
                            Icons.Default.Wifi,
                            contentDescription = text.signalUnavailable,
                            tint = colors.accentBlue,
                            modifier = Modifier.wrapContentHeight(unbounded = true).size(18.dp),
                        )

                    SignalPillMode.WIFI_OFFLINE -> Icon(''')
    pill = replace_once(pill, 'visible = expanded && online && !staMode', 'visible = expanded && online && !staMode && !unknownSignal')
    pill = replace_once(pill, 'stringResource(R.string.camera_not_connected)', 'text.notConnected')
    pill = replace_once(pill, 'stringResource(R.string.connection_usb)', 'text.usb')
    pill = replace_once(pill, 'SignalPillMode.USB -> ClassicUsbIcon(', 'SignalPillMode.USB -> SharedClassicUsbIcon(\n                            description = text.usb,')
    pill = replace_once(pill, 'SignalPillMode.STA_OFFLINE -> StaSignalIcon(', 'SignalPillMode.STA_OFFLINE -> StaSignalIcon(\n                        text = text,')
    helpers = replace_once(helpers, '    WIFI_OFFLINE,', '    WIFI_UNKNOWN,\n    WIFI_OFFLINE,')
    helpers = replace_once(helpers, 'private fun StaSignalIcon(\n', 'private fun StaSignalIcon(\n    text: SignalPillText,\n')
    helpers = replace_once(helpers, '''    val description = stringResource(
        if (connected) R.string.sta_signal_connected
        else R.string.sta_signal_disconnected_reconnect,
    )''', '    val description = if (connected) text.staConnected else text.staDisconnected')
    shared_usb = replace_once(usb, 'internal fun ClassicUsbIcon(', 'fun SharedClassicUsbIcon(\n    description: String,')
    shared_usb = replace_once(shared_usb, '    val description = stringResource(R.string.connection_usb)\n', '')
    android_usb = '''/** Android resource adapter; all USB geometry lives in the shared component. */
@Composable
internal fun ClassicUsbIcon(tint: Color, modifier: Modifier = Modifier) {
    SharedClassicUsbIcon(stringResource(R.string.connection_usb), tint, modifier)
}

'''
    android = replace_once(source, palette, '')
    android = replace_once(android, old_pill, android_pill)
    android = replace_once(android, usb, android_usb)
    constant = next(line for line in source.splitlines() if line.startswith('private val TOP_BAR_COMPACT_BUTTON_MIN_WIDTH ='))
    shared = HEADER + constant + '\n\n' + palette.replace('internal data class ', 'data class ').replace('internal fun ', 'fun ') + pill + helpers + shared_usb
    shared += '''/** Unknown RSSI is an explicit platform capability, never an invented signal sample. */
fun signalPillOnline(connected: Boolean, usbMode: Boolean, staMode: Boolean, rssi: Int?, allowUnknownRssi: Boolean = false): Boolean =
    connected && (usbMode || staMode || rssi != null || allowUnknownRssi)
'''
    return android, shared
