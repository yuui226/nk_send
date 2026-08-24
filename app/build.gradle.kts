import java.io.FileInputStream
import java.time.LocalDateTime
import java.time.format.DateTimeFormatter
import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

// 发布签名从 keystore.properties 读取（该文件不入库）。缺失时回退到 debug 签名，
// 保证开发者本地仍可构建 release，同时避免把签名口令硬编码进版本库。
val keystorePropsFile = rootProject.file("keystore.properties")
val hasReleaseKeystore = keystorePropsFile.exists()
val keystoreProps = Properties().apply {
    if (hasReleaseKeystore) FileInputStream(keystorePropsFile).use { load(it) }
}

android {
    namespace = "com.ztransfer"
    compileSdk = 35

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                storeFile = file(keystoreProps.getProperty("storeFile"))
                storePassword = keystoreProps.getProperty("storePassword")
                keyAlias = keystoreProps.getProperty("keyAlias")
                keyPassword = keystoreProps.getProperty("keyPassword")
            }
        }
    }

    defaultConfig {
        applicationId = "com.ztransfer"
        minSdk = 26
        targetSdk = 35
        versionCode = 43
        versionName = "1.73"

        // The app exposes exactly English, Simplified Chinese and Traditional
        // Chinese. Do not package translations contributed by AndroidX for
        // languages the app itself does not support.
        resourceConfigurations += listOf("en", "zh", "zh-rCN", "zh-rHK", "zh-rTW")
    }

    buildTypes {
        debug {
            // 调试包与已安装的正式包并存，避免模拟器验证覆盖用户数据或遇到签名冲突。
            applicationIdSuffix = ".debug"
            versionNameSuffix = "-debug"
        }
        release {
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
    buildFeatures {
        compose = true
        buildConfig = true
    }
    composeOptions {
        kotlinCompilerExtensionVersion = "1.5.5"
    }
    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
    }
    bundle {
        // AppLocale can switch languages independently of the device locale,
        // so every installed split must contain all three supported languages.
        language {
            enableSplit = false
        }
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.12.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.6.2")
    implementation("androidx.activity:activity-compose:1.8.2")

    implementation(platform("androidx.compose:compose-bom:2023.10.01"))
    // 1.7 起 LazyGrid 的 animateItem 原生同时处理插入、移除和重排；仅定向覆盖
    // Foundation，避免旧 animateItemPlacement 在大量网格变更时产生离屏钳制。
    implementation("androidx.compose.foundation:foundation:1.7.6")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-graphics")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")

    implementation("androidx.navigation:navigation-compose:2.7.6")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.6.2")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.6.2")
    implementation("androidx.exifinterface:exifinterface:1.3.7")

    // 二维码生成:把虎皮椒手机端支付链接画成码,自己排版 + 存相册,不塞它的页面。
    // 只用 core（纯 Java 编码器,约 500KB,不含安卓摄像头扫码那套）。
    implementation("com.google.zxing:core:3.5.3")

    debugImplementation("androidx.compose.ui:ui-tooling")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
    testImplementation("junit:junit:4.13.2")
}

// assembleDebug 完成后额外复制一份带秒级时间戳的 APK。保留 AGP 的 app-debug.apk，
// 避免破坏 IDE/ADB 对标准产物路径的依赖；实际发到手机时使用 dist-debug 下的唯一文件名，
// 不会被 QQ、网盘或文件管理器的同名缓存误认为旧安装包。
val copyTimestampedDebugApk = tasks.register("copyTimestampedDebugApk") {
    group = "build"
    description = "Copy the debug APK to dist with a unique build timestamp"
    outputs.upToDateWhen { false }
    doLast {
        val source = layout.buildDirectory.file("outputs/apk/debug/app-debug.apk").get().asFile
        check(source.isFile) { "Debug APK not found: ${source.absolutePath}" }
        val stamp = LocalDateTime.now().format(DateTimeFormatter.ofPattern("yyyyMMdd-HHmmss"))
        val version = android.defaultConfig.versionName ?: "unknown"
        val destinationDirectory = rootProject.file("dist-debug").apply { mkdirs() }
        val destination = destinationDirectory.resolve(
            "ZTransfer-debug-$version-$stamp.apk"
        )
        source.copyTo(destination, overwrite = false)
        println("Timestamped debug APK: ${destination.absolutePath}")
    }
}

tasks.configureEach {
    if (name == "assembleDebug") finalizedBy(copyTimestampedDebugApk)
}

// 手动安装到设备的便捷任务：./gradlew installToDevice（构建 release 后按需调用，
// 不再自动挂到 assembleRelease，避免 CI/无设备环境构建失败）。
tasks.register("installToDevice") {
    doLast {
        val apk = file("build/outputs/apk/release/app-release.apk")
        println("Installing ${apk.absolutePath} ...")
        val result = project.exec {
            commandLine("adb", "install", "-r", apk.absolutePath)
            isIgnoreExitValue = false
        }
        if (result.exitValue != 0) {
            throw GradleException("adb install failed with exit code ${result.exitValue}")
        }
        exec {
            commandLine("adb", "shell", "am", "start", "-n", "com.ztransfer/.MainActivity")
        }
    }
}
