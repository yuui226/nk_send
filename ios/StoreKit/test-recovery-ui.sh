#!/bin/bash
# Local Xcode StoreKit only. The UI test checks the "Xcode / no charge" sheet
# before confirming, and never injects an entitlement into the application.
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "Usage: $0 SIMULATOR_ID [TEST_METHOD]" >&2
    exit 2
fi
test_methods=(
    testDebugPremiumAnimationPreviewKeepsFreeWatermarkLocked
    testLifetimePurchaseSurvivesImmediateAppRelaunch
    testLifetimePurchaseClosesAfterSystemAcknowledgement
    testPurchasedBadgeCelebratesWithoutReopeningPurchaseInBothSettings
    testAnnualToLifetimeKeepsRenewalManagementAfterRelaunch
    testAppleSubscriptionManagementCancelsRenewalAndKeepsPaidTerm
    testPurchasePageLayoutInAllLanguages
    testFreeWorkbenchLocksWatermarkButAllowsFiltersAndFrames
    testPurchasedWorkbenchEditsAndPersistsTextWatermark
    testPurchasedWorkbenchImportsImageWatermarkAndKeepsItAfterCancelAndRelaunch
    testFreeCameraEffectsKeepWatermarkLockedAndSaveFreeChoices
    testPurchasedCameraEffectsSaveTextWatermarkWhenPopupCloses
    testPurchasedCameraImportsImageWatermarkAndKeepsItAfterCancelAndRelaunch
    testFreeWorkbenchSavesPhotoThroughSystemAuthorization
    testFreeWorkbenchSavesTwoPhotosThroughSystemAuthorization
    testWorkbenchDeniedPhotoSaveReportsFailureAndCanRetry
)
# The current runtime rejects SKTestSession calls from the UI runner. Keep
# the failing refund probe explicitly runnable; it is NOT a passed UI case.
diagnostic_methods=(testRefundWhileWorkbenchEditorIsOpenRestoresFreeWatermark)
if [[ $# -eq 2 ]]; then
    known_method=false
    for test_method in "${test_methods[@]}" "${diagnostic_methods[@]}"; do
        if [[ $2 == "$test_method" ]]; then known_method=true; break; fi
    done
    [[ $known_method == true ]] || { echo "Unknown test method: $2" >&2; exit 2; }
    test_methods=("$2")
fi
ios_dir="$(cd "$(dirname "$0")/.." && pwd)"
results_dir="$(mktemp -d "${TMPDIR:-/tmp}/ztransfer-storekit-ui.XXXXXX")"
derived_dir="${ZTRANSFER_TEST_DERIVED_DATA:-$results_dir/DerivedData}"
common=(-project "$ios_dir/ZTransfer.xcodeproj" -configuration Debug
    -destination "platform=iOS Simulator,id=$1" -derivedDataPath "$derived_dir"
    -collect-test-diagnostics never)
fixture_test='ZTransferStoreKitTests/StoreKitPurchaseTests/testConfiguredPricesTypesAndFamilySharing'

run_fixture() {
    xcodebuild "${common[@]}" -scheme ZTransfer-StoreKit -only-testing:"$fixture_test" \
        -resultBundlePath "$results_dir/$1.xcresult" test CODE_SIGN_IDENTITY=- > "$results_dir/$1.log" 2>&1
}

cleanup() {
    local result=$?
    trap - EXIT
    if ! run_fixture cleanup; then
        echo "StoreKit cleanup failed; see $results_dir/cleanup.log" >&2
        [[ $result -ne 0 ]] || result=1
    fi
    echo "StoreKit UI results: $results_dir"
    exit "$result"
}
trap cleanup EXIT

echo "Preparing local StoreKit environment: $results_dir"
# This hosted fixture verifies the configured products and clears transactions
# in teardown. SKTestSession in a separate UI runner is not authorized on the
# current simulator, so it must not silently pretend to reset this environment.
for test_method in "${test_methods[@]}"; do
    photo_export=false
    expected_exports=0
    if [[ $test_method == testFreeWorkbenchSavesPhotoThroughSystemAuthorization ]]; then
        photo_export=true
        expected_exports=1
    elif [[ $test_method == testFreeWorkbenchSavesTwoPhotosThroughSystemAuthorization ]]; then
        photo_export=true
        expected_exports=2
    elif [[ $test_method == testWorkbenchDeniedPhotoSaveReportsFailureAndCanRetry ]]; then
        photo_export=true
    fi
    if [[ $photo_export == true ]]; then
        python3 "$ios_dir/StoreKit/verify-photo-export.py" check "$1"
    fi
    if [[ $test_method == testPurchasedWorkbenchImportsImageWatermarkAndKeepsItAfterCancelAndRelaunch || $test_method == testPurchasedCameraImportsImageWatermarkAndKeepsItAfterCancelAndRelaunch || $photo_export == true ]]; then
        xcrun simctl addmedia "$1" "$ios_dir/ZTransfer/Resources/debug_sample_01.jpg"
    fi
    if [[ $test_method == testFreeWorkbenchSavesTwoPhotosThroughSystemAuthorization ]]; then
        xcrun simctl addmedia "$1" "$ios_dir/ZTransfer/Resources/debug_sample_fhd.jpg"
    fi
    run_fixture "prepare-$test_method"
    if [[ $photo_export == true ]]; then
        python3 "$ios_dir/StoreKit/verify-photo-export.py" snapshot "$1" "$results_dir/$test_method-photos.json"
        xcrun simctl privacy "$1" reset photos com.ztransfer.ios
        xcrun simctl privacy "$1" reset photos-add com.ztransfer.ios
    fi
    xcodebuild "${common[@]}" -scheme ZTransfer-StoreKitUI \
        -only-testing:"ZTransferStoreKitUITests/PremiumRecoveryUITests/$test_method" \
        -resultBundlePath "$results_dir/$test_method.xcresult" test CODE_SIGN_IDENTITY=- > "$results_dir/$test_method.log" 2>&1
    if [[ $photo_export == true ]]; then
        python3 "$ios_dir/StoreKit/verify-photo-export.py" verify "$results_dir/$test_method-photos.json" "$expected_exports"
    fi
done
