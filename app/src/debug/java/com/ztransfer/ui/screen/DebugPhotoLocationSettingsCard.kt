package com.ztransfer.ui.screen

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import com.ztransfer.R
import com.ztransfer.location.DebugPhotoLocationInput
import com.ztransfer.location.DebugPhotoLocationStore
import com.ztransfer.location.parseDebugPhotoLocation
import com.ztransfer.frame.PhotoFrameLocationOverride
import com.ztransfer.ui.theme.AppTheme

/** Manual-only GPS experiment. This whole UI source file is absent from Release builds. */
@Composable
internal fun DebugPhotoLocationSettingsCard(
    onStateChanged: (enabled: Boolean, config: PhotoFrameLocationOverride?) -> Unit = { _, _ -> },
) {
    val context = LocalContext.current
    val uriHandler = LocalUriHandler.current
    val colors = AppTheme.colors
    var input by remember { mutableStateOf(DebugPhotoLocationStore.readInput(context)) }
    val config = parseDebugPhotoLocation(input)

    fun outputConfig(value: DebugPhotoLocationInput): PhotoFrameLocationOverride? =
        parseDebugPhotoLocation(value)?.let {
            PhotoFrameLocationOverride(
                latitude = it.latitude,
                longitude = it.longitude,
            )
        }

    LaunchedEffect(config) {
        onStateChanged(input.enabled, outputConfig(input))
    }
    fun update(value: DebugPhotoLocationInput) {
        input = value
        DebugPhotoLocationStore.saveInput(context, value)
        // The workbench may already have an enabled Generate button. Publish edited coordinates
        // in the same input event so a quick tap cannot export the previously entered location.
        onStateChanged(value.enabled, outputConfig(value))
    }

    Spacer(Modifier.height(8.dp))
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(colors.glassSurface.copy(alpha = 0.58f))
            .border(1.dp, colors.accentBlue.copy(alpha = 0.42f), RoundedCornerShape(14.dp))
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = stringResource(R.string.debug_photo_location_title),
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.SemiBold,
                    color = colors.onBackground,
                )
            }
            Switch(
                checked = input.enabled,
                onCheckedChange = { update(input.copy(enabled = it)) },
            )
        }

        AnimatedVisibility(
            visible = input.enabled,
            enter = fadeIn() + expandVertically(),
            exit = fadeOut() + shrinkVertically(),
        ) {
            Column {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedTextField(
                        value = input.latitude,
                        onValueChange = { update(input.copy(latitude = it.take(24))) },
                        label = { Text(stringResource(R.string.debug_photo_location_latitude)) },
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(
                            keyboardType = KeyboardType.Decimal,
                            imeAction = ImeAction.Next,
                        ),
                        modifier = Modifier.weight(1f),
                    )
                    OutlinedTextField(
                        value = input.longitude,
                        onValueChange = { update(input.copy(longitude = it.take(24))) },
                        label = { Text(stringResource(R.string.debug_photo_location_longitude)) },
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(
                            keyboardType = KeyboardType.Decimal,
                            imeAction = ImeAction.Done,
                        ),
                        modifier = Modifier.weight(1f),
                    )
                }
                Text(
                    text = stringResource(R.string.debug_photo_location_lookup),
                    style = MaterialTheme.typography.labelMedium,
                    color = colors.accentBlue,
                    textDecoration = TextDecoration.Underline,
                    modifier = Modifier
                        .align(Alignment.End)
                        .clickable {
                            uriHandler.openUri("https://www.hylab.cn/tool/gis-select")
                        }
                        .padding(top = 7.dp, bottom = 1.dp),
                )
            }
        }
    }
}
