plugins {
    id("com.android.application") version "8.10.1" apply false
    id("com.android.library") version "8.10.1" apply false
    id("org.jetbrains.kotlin.android") version "2.2.21" apply false
    id("org.jetbrains.kotlin.multiplatform") version "2.2.21" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.2.21" apply false
    // 1.8.2 provides stable iOS UI without upgrading Kotlin/AGP or adopting an alpha release.
    id("org.jetbrains.compose") version "1.8.2" apply false
}
