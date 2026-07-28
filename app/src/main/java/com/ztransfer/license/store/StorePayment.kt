package com.ztransfer.license.store

import android.app.Activity
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * Channel-neutral contract used by the common purchase UI.
 *
 * The direct build keeps its existing QR-code flow. The Play build supplies a
 * [StorePaymentClient] backed by Google Play Billing without leaking BillingClient
 * classes into the common or direct source sets.
 */
interface StorePaymentClient : AutoCloseable {
    val catalog: StateFlow<StoreCatalogState>
    val events: SharedFlow<StorePaymentEvent>

    /** Connect, load localized prices, and reconcile owned purchases. */
    fun start()

    suspend fun refreshProducts(): StoreCatalogState

    /** Must be called from the main thread because Google owns the purchase UI. */
    suspend fun launchPurchase(
        activity: Activity,
        product: StoreProduct,
    ): StoreLaunchResult

    suspend fun restorePurchases(): StoreRestoreResult

    override fun close()
}

enum class StoreProduct(
    val serverValue: String,
    val googleProductId: String,
    val kind: StoreProductKind,
) {
    LIFETIME(
        serverValue = "lifetime",
        googleProductId = "ztransfer_pro_lifetime",
        kind = StoreProductKind.ONE_TIME,
    ),
    ANNUAL(
        serverValue = "annual",
        googleProductId = "ztransfer_pro_annual",
        kind = StoreProductKind.SUBSCRIPTION,
    );

    companion object {
        fun fromGoogleProductId(productId: String?): StoreProduct? =
            entries.firstOrNull { it.googleProductId == productId }

        fun fromServerValue(value: String?): StoreProduct? =
            entries.firstOrNull { it.serverValue == value?.lowercase() }
    }
}

enum class StoreProductKind {
    ONE_TIME,
    SUBSCRIPTION,
}

data class StoreOffer(
    val product: StoreProduct,
    val title: String,
    val description: String,
    val formattedPrice: String,
)

sealed interface StoreCatalogState {
    data object Loading : StoreCatalogState
    data class Ready(val offers: Map<StoreProduct, StoreOffer>) : StoreCatalogState
    data class Failed(
        val code: String,
        val message: String? = null,
        val recoverable: Boolean = true,
    ) : StoreCatalogState
}

sealed interface StoreLaunchResult {
    /** The Google-owned purchase sheet was displayed. Final status arrives through [StorePaymentClient.events]. */
    data object Launched : StoreLaunchResult
    data class Failed(
        val code: String,
        val message: String? = null,
        val recoverable: Boolean = true,
    ) : StoreLaunchResult
}

sealed interface StorePaymentEvent {
    data class Completed(
        val product: StoreProduct,
        val restored: Boolean,
    ) : StorePaymentEvent

    data class Pending(val product: StoreProduct) : StorePaymentEvent
    data object Cancelled : StorePaymentEvent
    data class Failed(
        val code: String,
        val message: String? = null,
        val recoverable: Boolean = true,
    ) : StorePaymentEvent
}

sealed interface StoreRestoreResult {
    data class Complete(
        val restoredCount: Int,
        val pendingCount: Int,
    ) : StoreRestoreResult

    data class Failed(
        val code: String,
        val message: String? = null,
        val recoverable: Boolean = true,
    ) : StoreRestoreResult
}
