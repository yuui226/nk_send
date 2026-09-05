// Read-only dependency resolution; reports are build artifacts, never committed credentials.
gradle.projectsEvaluated {
    val app = rootProject.project(":app")
    app.tasks.register("snapshotUiDependencies") {
        group = "verification"
        doLast {
            val label = app.providers.gradleProperty("uiSnapshot").orElse("current").get()
            require(label.matches(Regex("[a-zA-Z0-9_-]+")))
            val directory = rootProject.layout.buildDirectory.dir("ios-ui-dependencies").get().asFile
            directory.mkdirs()
            for (name in listOf("debugCompileClasspath", "debugRuntimeClasspath", "releaseRuntimeClasspath")) {
                val resolution = app.configurations.getByName(name).incoming.resolutionResult
                val failures = resolution.allDependencies.filterIsInstance<org.gradle.api.artifacts.result.UnresolvedDependencyResult>()
                check(failures.isEmpty()) { failures.joinToString("\n") { it.failure.message.orEmpty() } }
                val modules = resolution.allComponents.mapNotNull { it.moduleVersion?.toString() }.distinct().sorted()
                val report = directory.resolve("$label-$name.txt")
                report.writeText(modules.joinToString("\n", postfix = "\n"))
                println("UI_DEPENDENCIES ${report.absolutePath}: ${modules.size} modules")
            }
        }
    }
}
