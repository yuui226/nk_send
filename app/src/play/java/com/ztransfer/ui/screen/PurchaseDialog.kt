package com.ztransfer.ui.screen

import android.content.Context
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.ztransfer.R
import com.ztransfer.license.LicenseManager
import com.ztransfer.license.store.GooglePlayPaymentClient
import com.ztransfer.license.store.StoreCatalogState
import com.ztransfer.license.store.StoreLaunchResult
import com.ztransfer.license.store.StorePaymentEvent
import com.ztransfer.license.store.StoreProduct
import com.ztransfer.license.store.StoreRestoreResult
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Play-specific purchase UI. Google renders the actual checkout surface; this
 * dialog only shows the current Play price, restore action, and verification state.
 */
@Composable
fun PurchaseDialog(
    onDismiss: () -> Unit,
    onCelebrate: () -> Unit = {},
    onRestored: () -> Unit = {},
    onHoldCameraWifi: (Boolean) -> Unit = {},
    product: LicenseManager.ProductId,
    renew: Boolean = false,
) {
    val context = LocalContext.current
    val activity = remember(context) { context.findActivity() }
    val client = remember(context.applicationContext) {
        GooglePlayPaymentClient(context.applicationContext)
    }
    val scope = rememberCoroutineScope()
    val catalog by client.catalog.collectAsState()
    val storeProduct = remember(product) {
        when (product) {
            LicenseManager.ProductId.LIFETIME -> StoreProduct.LIFETIME
            LicenseManager.ProductId.ANNUAL -> StoreProduct.ANNUAL
        }
    }
    var busy by remember { mutableStateOf(false) }
    var status by remember { mutableStateOf<String?>(null) }
    var completed by remember { mutableStateOf(false) }

    DisposableEffect(client) {
        onHoldCameraWifi(false)
        client.start()
        onDispose {
            client.close()
            onHoldCameraWifi(true)
        }
    }

    LaunchedEffect(client) {
        client.events.collect { event ->
            when (event) {
                is StorePaymentEvent.Completed -> {
                    busy = false
                    completed = true
                    status = if (event.restored) {
                        context.getString(R.string.play_purchase_restored)
                    } else {
                        context.getString(R.string.play_purchase_completed)
                    }
                    delay(900)
                    if (event.restored) onRestored() else onCelebrate()
                }
                is StorePaymentEvent.Pending -> {
                    busy = false
                    status = context.getString(R.string.play_purchase_pending)
                }
                StorePaymentEvent.Cancelled -> {
                    busy = false
                    status = context.getString(R.string.play_purchase_cancelled)
                }
                is StorePaymentEvent.Failed -> {
                    busy = false
                    status = playErrorMessage(context, event.code, event.message)
                }
            }
        }
    }

    val ready = catalog as? StoreCatalogState.Ready
    val offer = ready?.offers?.get(storeProduct)
    val catalogFailure = catalog as? StoreCatalogState.Failed
    val title = when (storeProduct) {
        StoreProduct.LIFETIME -> stringResource(R.string.play_purchase_lifetime_title)
        StoreProduct.ANNUAL -> stringResource(R.string.play_purchase_annual_title)
    }

    AlertDialog(
        onDismissRequest = { if (!busy && !completed) onDismiss() },
        title = { Text(title) },
        text = {
            Column(modifier = androidx.compose.ui.Modifier.fillMaxWidth()) {
                when {
                    catalog is StoreCatalogState.Loading -> {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.Center,
                            modifier = androidx.compose.ui.Modifier.fillMaxWidth(),
                        ) {
                            CircularProgressIndicator(
                                modifier = androidx.compose.ui.Modifier
                                    .width(24.dp)
                                    .height(24.dp)
                            )
                            Spacer(androidx.compose.ui.Modifier.width(12.dp))
                            Text(stringResource(R.string.play_purchase_loading))
                        }
                    }
                    offer != null -> {
                        if (offer.description.isNotBlank()) Text(offer.description)
                        Spacer(androidx.compose.ui.Modifier.height(10.dp))
                        Text(
                            if (storeProduct == StoreProduct.ANNUAL) {
                                stringResource(
                                    R.string.play_purchase_subscription_price,
                                    offer.formattedPrice,
                                )
                            } else {
                                stringResource(
                                    R.string.play_purchase_one_time_price,
                                    offer.formattedPrice,
                                )
                            }
                        )
                        Spacer(androidx.compose.ui.Modifier.height(8.dp))
                        Text(stringResource(R.string.play_purchase_google_managed))
                    }
                    catalogFailure != null -> {
                        Text(
                            playErrorMessage(
                                context,
                                catalogFailure.code,
                                catalogFailure.message,
                            )
                        )
                    }
                    else -> Text(stringResource(R.string.play_purchase_not_configured))
                }
                status?.let {
                    Spacer(androidx.compose.ui.Modifier.height(12.dp))
                    Text(it)
                }
            }
        },
        confirmButton = {
            if (offer != null && !completed) {
                Button(
                    enabled = !busy && activity != null,
                    onClick = {
                        val host = activity ?: return@Button
                        busy = true
                        status = null
                        scope.launch {
                            when (val result = client.launchPurchase(host, storeProduct)) {
                                StoreLaunchResult.Launched -> Unit
                                is StoreLaunchResult.Failed -> {
                                    busy = false
                                    status = playErrorMessage(
                                        context,
                                        result.code,
                                        result.message,
                                    )
                                }
                            }
                        }
                    }
                ) {
                    if (busy) {
                        CircularProgressIndicator(
                            modifier = androidx.compose.ui.Modifier
                                .width(18.dp)
                                .height(18.dp)
                        )
                        Spacer(androidx.compose.ui.Modifier.width(8.dp))
                    }
                    Text(stringResource(R.string.play_purchase_buy_button))
                }
            } else if (catalogFailure != null || ready != null && offer == null) {
                TextButton(
                    enabled = !busy,
                    onClick = {
                        scope.launch {
                            busy = true
                            client.refreshProducts()
                            busy = false
                        }
                    }
                ) {
                    Text(stringResource(R.string.play_purchase_retry))
                }
            }
        },
        dismissButton = {
            Row {
                if (!completed) {
                    TextButton(
                        enabled = !busy,
                        onClick = {
                            scope.launch {
                                busy = true
                                status = null
                                when (val result = client.restorePurchases()) {
                                    is StoreRestoreResult.Complete -> {
                                        busy = false
                                        if (result.restoredCount == 0) {
                                            status = if (result.pendingCount > 0) {
                                                context.getString(R.string.play_purchase_pending)
                                            } else {
                                                context.getString(R.string.play_purchase_none)
                                            }
                                        }
                                    }
                                    is StoreRestoreResult.Failed -> {
                                        busy = false
                                        status = playErrorMessage(
                                            context,
                                            result.code,
                                            result.message,
                                        )
                                    }
                                }
                            }
                        }
                    ) {
                        Text(stringResource(R.string.play_purchase_restore))
                    }
                }
                TextButton(
                    enabled = !busy,
                    onClick = onDismiss,
                ) {
                    Text(
                        stringResource(
                            if (completed) R.string.purchase_done
                            else R.string.play_purchase_close
                        )
                    )
                }
            }
        },
    )
}

private fun playErrorMessage(
    context: Context,
    code: String,
    detail: String?,
): String = when {
    code == "PRODUCT_UNAVAILABLE" ->
        context.getString(R.string.play_purchase_not_available)
    code == "VERIFY_UNREACHABLE" || code.contains("-3") ||
        code.contains("-1") || code.contains("NETWORK") ->
        context.getString(R.string.play_purchase_network_error)
    code == "GOOGLE_CREDENTIALS_NOT_CONFIGURED" ->
        context.getString(R.string.play_purchase_server_not_ready)
    else -> context.getString(
        R.string.play_purchase_error,
        detail?.takeIf { it.isNotBlank() } ?: code,
    )
}
