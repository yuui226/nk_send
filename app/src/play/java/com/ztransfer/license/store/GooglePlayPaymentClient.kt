package com.ztransfer.license.store

import android.app.Activity
import android.content.Context
import com.android.billingclient.api.BillingClient
import com.android.billingclient.api.BillingClientStateListener
import com.android.billingclient.api.BillingFlowParams
import com.android.billingclient.api.BillingResult
import com.android.billingclient.api.PendingPurchasesParams
import com.android.billingclient.api.ProductDetails
import com.android.billingclient.api.Purchase
import com.android.billingclient.api.PurchasesUpdatedListener
import com.android.billingclient.api.QueryProductDetailsParams
import com.android.billingclient.api.QueryPurchasesParams
import com.ztransfer.BuildConfig
import com.ztransfer.license.LicenseManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlin.coroutines.resume
import kotlinx.coroutines.suspendCancellableCoroutine

/**
 * Google Play implementation. Purchase tokens are opaque on-device and are
 * accepted only after [LicenseManager] receives a positive backend verification.
 */
class GooglePlayPaymentClient(context: Context) :
    StorePaymentClient,
    PurchasesUpdatedListener {

    private val appContext = context.applicationContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val connectionMutex = Mutex()
    private val verificationMutex = Mutex()
    private val verifyingTokens = mutableSetOf<String>()

    private val _catalog = MutableStateFlow<StoreCatalogState>(StoreCatalogState.Loading)
    override val catalog: StateFlow<StoreCatalogState> = _catalog

    private val _events = MutableSharedFlow<StorePaymentEvent>(extraBufferCapacity = 16)
    override val events: SharedFlow<StorePaymentEvent> = _events

    private data class BillingOffer(
        val details: ProductDetails,
        val offerToken: String?,
        val display: StoreOffer,
    )

    private var billingOffers: Map<StoreProduct, BillingOffer> = emptyMap()

    private val billingClient = BillingClient.newBuilder(appContext)
        .setListener(this)
        .enablePendingPurchases(
            PendingPurchasesParams.newBuilder()
                .enableOneTimeProducts()
                .build()
        )
        .enableAutoServiceReconnection()
        .build()

    override fun start() {
        scope.launch {
            refreshProducts()
            restorePurchases()
        }
    }

    override suspend fun refreshProducts(): StoreCatalogState {
        _catalog.value = StoreCatalogState.Loading
        val connection = ensureConnected()
        if (connection.responseCode != BillingClient.BillingResponseCode.OK) {
            return catalogFailure(connection).also { _catalog.value = it }
        }

        val params = QueryProductDetailsParams.newBuilder()
            .setProductList(
                StoreProduct.entries.map { product ->
                    QueryProductDetailsParams.Product.newBuilder()
                        .setProductId(product.googleProductId)
                        .setProductType(product.billingProductType())
                        .build()
                }
            )
            .build()
        val response = suspendCancellableCoroutine<ProductQueryResponse> { continuation ->
            billingClient.queryProductDetailsAsync(params) { result, detailsResult ->
                if (continuation.isActive) {
                    continuation.resume(
                        ProductQueryResponse(result, detailsResult.productDetailsList)
                    )
                }
            }
        }
        if (response.result.responseCode != BillingClient.BillingResponseCode.OK) {
            return catalogFailure(response.result).also { _catalog.value = it }
        }

        val resolved = response.details.mapNotNull(::toBillingOffer)
            .associateBy { it.display.product }
        billingOffers = resolved
        val state = StoreCatalogState.Ready(resolved.mapValues { it.value.display })
        _catalog.value = state
        return state
    }

    override suspend fun launchPurchase(
        activity: Activity,
        product: StoreProduct,
    ): StoreLaunchResult = withContext(Dispatchers.Main.immediate) {
        val connection = ensureConnected()
        if (connection.responseCode != BillingClient.BillingResponseCode.OK) {
            return@withContext launchFailure(connection)
        }

        // ProductDetails can become stale when eligibility or country changes.
        refreshProducts()
        val offer = billingOffers[product]
            ?: return@withContext StoreLaunchResult.Failed(
                code = "PRODUCT_UNAVAILABLE",
                message = "This product is not available for this Google Play account.",
                recoverable = false,
            )
        val productParamsBuilder = BillingFlowParams.ProductDetailsParams.newBuilder()
            .setProductDetails(offer.details)
        offer.offerToken?.takeIf { it.isNotBlank() }?.let(productParamsBuilder::setOfferToken)
        val productParams = productParamsBuilder.build()
        val result = billingClient.launchBillingFlow(
            activity,
            BillingFlowParams.newBuilder()
                .setProductDetailsParamsList(listOf(productParams))
                .setIsOfferPersonalized(false)
                .build()
        )
        if (result.responseCode == BillingClient.BillingResponseCode.OK) {
            StoreLaunchResult.Launched
        } else {
            launchFailure(result)
        }
    }

    override fun onPurchasesUpdated(
        billingResult: BillingResult,
        purchases: MutableList<Purchase>?,
    ) {
        when (billingResult.responseCode) {
            BillingClient.BillingResponseCode.OK -> {
                if (purchases.isNullOrEmpty()) {
                    _events.tryEmit(
                        StorePaymentEvent.Failed(
                            code = "EMPTY_PURCHASE",
                            message = billingResult.debugMessage,
                        )
                    )
                } else {
                    purchases.forEach { purchase ->
                        scope.launch { processPurchase(purchase, restored = false) }
                    }
                }
            }
            BillingClient.BillingResponseCode.USER_CANCELED ->
                _events.tryEmit(StorePaymentEvent.Cancelled)
            BillingClient.BillingResponseCode.ITEM_ALREADY_OWNED ->
                scope.launch { restorePurchases() }
            else ->
                _events.tryEmit(paymentFailure(billingResult))
        }
    }

    override suspend fun restorePurchases(): StoreRestoreResult {
        val connection = ensureConnected()
        if (connection.responseCode != BillingClient.BillingResponseCode.OK) {
            return restoreFailure(connection)
        }

        val allPurchases = mutableListOf<Purchase>()
        for (type in listOf(BillingClient.ProductType.INAPP, BillingClient.ProductType.SUBS)) {
            val result = queryPurchases(type)
            if (result.result.responseCode == BillingClient.BillingResponseCode.OK) {
                allPurchases += result.purchases
            } else if (
                type != BillingClient.ProductType.SUBS ||
                result.result.responseCode != BillingClient.BillingResponseCode.FEATURE_NOT_SUPPORTED
            ) {
                return restoreFailure(result.result)
            }
        }

        var restoredCount = 0
        var pendingCount = 0
        for (purchase in allPurchases.distinctBy { it.purchaseToken }) {
            when (purchase.purchaseState) {
                Purchase.PurchaseState.PURCHASED -> {
                    if (processPurchase(purchase, restored = true)) restoredCount++
                }
                Purchase.PurchaseState.PENDING -> {
                    pendingCount++
                    purchase.storeProduct()?.let {
                        _events.emit(StorePaymentEvent.Pending(it))
                    }
                }
            }
        }
        return StoreRestoreResult.Complete(restoredCount, pendingCount)
    }

    private suspend fun processPurchase(
        purchase: Purchase,
        restored: Boolean,
    ): Boolean {
        val product = purchase.storeProduct()
        if (product == null) {
            _events.emit(
                StorePaymentEvent.Failed(
                    code = "UNKNOWN_PRODUCT",
                    message = purchase.products.joinToString(),
                    recoverable = false,
                )
            )
            return false
        }
        if (purchase.purchaseState == Purchase.PurchaseState.PENDING) {
            _events.emit(StorePaymentEvent.Pending(product))
            return false
        }
        if (purchase.purchaseState != Purchase.PurchaseState.PURCHASED) {
            _events.emit(
                StorePaymentEvent.Failed(
                    code = "PURCHASE_NOT_COMPLETED",
                    recoverable = true,
                )
            )
            return false
        }

        val shouldVerify = verificationMutex.withLock {
            verifyingTokens.add(purchase.purchaseToken)
        }
        if (!shouldVerify) return false
        try {
            when (
                val verification = LicenseManager.verifyGooglePlayPurchase(
                    packageName = appContext.packageName,
                    googleProductId = product.googleProductId,
                    purchaseToken = purchase.purchaseToken,
                    appVersion = BuildConfig.VERSION_NAME,
                )
            ) {
                is LicenseManager.GooglePlayVerificationResult.Success -> {
                    // The verification endpoint is the single authority for
                    // acknowledge. It grants the signed entitlement first and
                    // safely retries a transient acknowledge failure on the
                    // next verify/restore/RTDN, so the app must not race it
                    // with a second acknowledgement based on stale local state.
                    _events.emit(StorePaymentEvent.Completed(product, restored))
                    return true
                }
                LicenseManager.GooglePlayVerificationResult.Unreachable -> {
                    _events.emit(
                        StorePaymentEvent.Failed(
                            code = "VERIFY_UNREACHABLE",
                            message = "Purchase is safe in Google Play. Connect to the internet and restore it.",
                            recoverable = true,
                        )
                    )
                }
                is LicenseManager.GooglePlayVerificationResult.Rejected -> {
                    _events.emit(
                        StorePaymentEvent.Failed(
                            code = verification.err,
                            message = "Google Play purchase verification failed.",
                            recoverable = verification.err in RECOVERABLE_SERVER_ERRORS,
                        )
                    )
                }
            }
            return false
        } finally {
            verificationMutex.withLock { verifyingTokens.remove(purchase.purchaseToken) }
        }
    }

    private suspend fun queryPurchases(type: String): PurchaseQueryResponse =
        suspendCancellableCoroutine { continuation ->
            billingClient.queryPurchasesAsync(
                QueryPurchasesParams.newBuilder()
                    .setProductType(type)
                    .build()
            ) { result, purchases ->
                if (continuation.isActive) {
                    continuation.resume(PurchaseQueryResponse(result, purchases))
                }
            }
        }

    private suspend fun ensureConnected(): BillingResult = connectionMutex.withLock {
        if (billingClient.isReady) return@withLock okResult()
        suspendCancellableCoroutine { continuation ->
            billingClient.startConnection(object : BillingClientStateListener {
                override fun onBillingSetupFinished(result: BillingResult) {
                    if (continuation.isActive) continuation.resume(result)
                }

                override fun onBillingServiceDisconnected() {
                    // Auto service reconnection is enabled. The next API call retries.
                }
            })
        }
    }

    private fun toBillingOffer(details: ProductDetails): BillingOffer? {
        val product = StoreProduct.fromGoogleProductId(details.productId) ?: return null
        return when (product.kind) {
            StoreProductKind.ONE_TIME -> {
                val offer = details.oneTimePurchaseOfferDetailsList
                    ?.firstOrNull { it.rentalDetails == null }
                    ?: details.oneTimePurchaseOfferDetails
                    ?: return null
                BillingOffer(
                    details = details,
                    offerToken = offer.offerToken,
                    display = StoreOffer(
                        product = product,
                        title = details.name,
                        description = details.description,
                        formattedPrice = offer.formattedPrice,
                    ),
                )
            }
            StoreProductKind.SUBSCRIPTION -> {
                // Prefer a base plan (no promotional offerId), then any eligible offer.
                val offer = details.subscriptionOfferDetails
                    ?.firstOrNull { it.offerId == null }
                    ?: details.subscriptionOfferDetails?.firstOrNull()
                    ?: return null
                val recurringPhase = offer.pricingPhases.pricingPhaseList.lastOrNull()
                    ?: return null
                BillingOffer(
                    details = details,
                    offerToken = offer.offerToken,
                    display = StoreOffer(
                        product = product,
                        title = details.name,
                        description = details.description,
                        formattedPrice = recurringPhase.formattedPrice,
                    ),
                )
            }
        }
    }

    private fun Purchase.storeProduct(): StoreProduct? =
        products.asSequence().mapNotNull(StoreProduct::fromGoogleProductId).firstOrNull()

    override fun close() {
        scope.cancel()
        billingClient.endConnection()
    }

    private data class ProductQueryResponse(
        val result: BillingResult,
        val details: List<ProductDetails>,
    )

    private data class PurchaseQueryResponse(
        val result: BillingResult,
        val purchases: List<Purchase>,
    )

    companion object {
        private val RECOVERABLE_SERVER_ERRORS = setOf(
            "HTTP_429",
            "HTTP_500",
            "HTTP_502",
            "HTTP_503",
            "HTTP_504",
            "GOOGLE_UNREACHABLE",
            "GOOGLE_API_ERROR",
        )
    }
}

private fun StoreProduct.billingProductType(): String = when (kind) {
    StoreProductKind.ONE_TIME -> BillingClient.ProductType.INAPP
    StoreProductKind.SUBSCRIPTION -> BillingClient.ProductType.SUBS
}

private fun okResult(): BillingResult = BillingResult.newBuilder()
    .setResponseCode(BillingClient.BillingResponseCode.OK)
    .build()

private fun catalogFailure(result: BillingResult): StoreCatalogState.Failed =
    StoreCatalogState.Failed(
        code = "BILLING_${result.responseCode}",
        message = result.debugMessage,
        recoverable = result.isRecoverableBillingError(),
    )

private fun launchFailure(result: BillingResult): StoreLaunchResult.Failed =
    StoreLaunchResult.Failed(
        code = "BILLING_${result.responseCode}",
        message = result.debugMessage,
        recoverable = result.isRecoverableBillingError(),
    )

private fun restoreFailure(result: BillingResult): StoreRestoreResult.Failed =
    StoreRestoreResult.Failed(
        code = "BILLING_${result.responseCode}",
        message = result.debugMessage,
        recoverable = result.isRecoverableBillingError(),
    )

private fun paymentFailure(
    result: BillingResult,
    codePrefix: String = "BILLING",
): StorePaymentEvent.Failed =
    StorePaymentEvent.Failed(
        code = "${codePrefix}_${result.responseCode}",
        message = result.debugMessage,
        recoverable = result.isRecoverableBillingError(),
    )

private fun BillingResult.isRecoverableBillingError(): Boolean =
    responseCode in setOf(
        BillingClient.BillingResponseCode.ERROR,
        BillingClient.BillingResponseCode.SERVICE_DISCONNECTED,
        BillingClient.BillingResponseCode.SERVICE_UNAVAILABLE,
        BillingClient.BillingResponseCode.NETWORK_ERROR,
    )
