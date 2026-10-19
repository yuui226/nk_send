plugins {
    java
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

sourceSets.main {
    java.srcDir("third_party/cafe-und-zopfli/src/main/java")
}

dependencies {
    // Keep these in step with AGP. This tool is not an app dependency.
    implementation("com.android:zipflinger:8.6.1")
    implementation("com.android.tools.build:apksig:8.6.1")
    testImplementation("junit:junit:4.13.2")
}

tasks.withType<JavaCompile>().configureEach {
    options.encoding = "UTF-8"
}

val toolClasspath = sourceSets.main.get().runtimeClasspath
val repositoryDirectory = rootProject.layout.projectDirectory.asFile.absolutePath

tasks.register<JavaExec>("optimizeReleaseApk") {
    group = "distribution"
    description = "Build, losslessly compress and verify the signed Release APK"
    dependsOn(":app:assembleRelease")
    classpath = toolClasspath
    mainClass.set("com.ztransfer.build.ReleaseApkOptimizer")
    maxHeapSize = "512m"
    args(
        rootProject.file("app/build/outputs/apk/release/app-release.apk").absolutePath,
        layout.buildDirectory.file("outputs/release-optimized.apk").get().asFile.absolutePath,
        repositoryDirectory,
    )
    // Recheck signing and contents on every distribution run. Never cache keys.
    outputs.upToDateWhen { false }
}

// Explicit audit entry point: uses an existing APK and never builds/installs the app.
tasks.register<JavaExec>("optimizeExistingApk") {
    group = "verification"
    description = "Verify compression on an existing APK (-PapkInput=... -PapkOutput=...)"
    classpath = toolClasspath
    mainClass.set("com.ztransfer.build.ReleaseApkOptimizer")
    maxHeapSize = "512m"
    val input = providers.gradleProperty("apkInput")
    val output = providers.gradleProperty("apkOutput")
    doFirst {
        require(input.isPresent && output.isPresent) { "Specify -PapkInput and -PapkOutput" }
        args(input.get(), output.get(), repositoryDirectory)
    }
}
