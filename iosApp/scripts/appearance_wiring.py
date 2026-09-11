"""Only the batch-46 factory argument; all camera/page logic still uses older whole-file guards."""
from original_source_wiring import without_original_source_page
def without_appearance_page(value):
    if 'final class OriginalFilesPageBridge:' in value:
        value = without_original_source_page(value)
    new = 'appearance: AppAppearanceSettings.shared.model, onBack: {'
    old = 'languageTag: Locale.preferredLanguages.first ?? "en", onBack: {'
    assert value.count(new) == 1
    return value.replace(new, old, 1)
