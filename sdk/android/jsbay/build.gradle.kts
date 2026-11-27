import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.zip.ZipEntry
import java.util.zip.ZipFile
import java.util.zip.ZipOutputStream

plugins {
    id("com.android.library")
    kotlin("android")
    `maven-publish`
}

val jsbayVersion = providers.gradleProperty("jsbayVersion").orElse("0.1.0")
val jsbayMavenRepo = providers.gradleProperty("jsbayMavenRepo")
val jsbayJniLibs = providers.gradleProperty("jsbayJniLibs").map { file(it) }.orNull
val jsbayBackendMarker = jsbayJniLibs?.let { layout.projectDirectory.file(it.parentFile.resolve("backend").path) }
val jsbayBackend =
    providers.gradleProperty("jsbayBackend").orNull
        ?: jsbayBackendMarker?.let {
            providers
                .fileContents(it)
                .asText.orNull
                ?.trim()
        }
        ?: "quickjs"
val githubRepository = providers.environmentVariable("GITHUB_REPOSITORY").orNull
val jsbayArtifactId =
    when (jsbayBackend) {
        "quickjs" -> "jsbay-quickjs"
        "quickjs_ng" -> "jsbay-quickjs-ng"
        else -> throw GradleException("Unsupported Android backend: $jsbayBackend")
    }
val jsbayLegacyArtifactId =
    when (jsbayBackend) {
        "quickjs" -> "jsbayquickjs"
        "quickjs_ng" -> "jsbayquickjsng"
        else -> throw GradleException("Unsupported Android backend: $jsbayBackend")
    }
val licenseFile = rootProject.file("../../LICENSE")
val noticesFile = rootProject.file("../../THIRD_PARTY_NOTICES.md")

group = "io.jsbay"
version = jsbayVersion.get()

configurations.configureEach {
    if (name == "releaseVariantReleaseApiPublication" || name == "releaseVariantReleaseRuntimePublication") {
        outgoing.capability("io.jsbay:$jsbayArtifactId:$version")
        outgoing.capability("io.jsbay:$jsbayLegacyArtifactId:$version")
    }
}

android {
    namespace = "io.jsbay"
    compileSdk = 35
    ndkVersion = "28.2.13676358"
    defaultConfig {
        minSdk = 24
        ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
        consumerProguardFiles("consumer-rules.pro")
        if (jsbayJniLibs != null) {
            sourceSets.getByName("main").jniLibs.srcDir(jsbayJniLibs)
            externalNativeBuild { cmake { arguments += "-DJSBAY_JNI_LIBS=$jsbayJniLibs" } }
        }
        externalNativeBuild { cmake { cppFlags += listOf("-Wall", "-Wextra", "-Werror") } }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    externalNativeBuild { cmake { path = file("src/main/cpp/CMakeLists.txt") } }
    publishing { singleVariant("release") { withSourcesJar() } }
}

kotlin { jvmToolchain(17) }

dependencies { implementation("org.jetbrains.kotlin:kotlin-stdlib:1.9.22") }

tasks.configureEach {
    if (name == "bundleReleaseAar") {
        inputs.files(licenseFile, noticesFile).withPropertyName("releaseLegalNotices")
        inputs.property("jsbayBackend", jsbayBackend)
        inputs
            .files(listOfNotNull(jsbayBackendMarker))
            .withPropertyName("jsbayBackendMarker")
            .withPathSensitivity(PathSensitivity.NONE)
        doLast {
            val backendMarker =
                jsbayBackendMarker?.asFile
                    ?: throw GradleException("jsbayJniLibs is required to create the Android release AAR")
            if (!backendMarker.isFile || backendMarker.readText().trim() != jsbayBackend) {
                throw GradleException("Android library backend does not match jsbayBackend=$jsbayBackend")
            }
            val aarFile =
                layout.buildDirectory
                    .file("outputs/aar/jsbay-release.aar")
                    .get()
                    .asFile
            val replacement = aarFile.resolveSibling("${aarFile.name}.with-legal")
            ZipFile(aarFile).use { source ->
                ZipOutputStream(replacement.outputStream().buffered()).use { destination ->
                    source
                        .entries()
                        .asSequence()
                        .filter { it.name !in setOf("META-INF/LICENSE", "META-INF/THIRD_PARTY_NOTICES.md") }
                        .forEach { entry ->
                            destination.putNextEntry(ZipEntry(entry.name).apply { time = entry.time })
                            if (!entry.isDirectory) source.getInputStream(entry).use { it.copyTo(destination) }
                            destination.closeEntry()
                        }
                    for ((name, sourceFile) in listOf(
                        "META-INF/LICENSE" to licenseFile,
                        "META-INF/THIRD_PARTY_NOTICES.md" to noticesFile,
                    )) {
                        destination.putNextEntry(ZipEntry(name))
                        sourceFile.inputStream().use { it.copyTo(destination) }
                        destination.closeEntry()
                    }
                    destination.putNextEntry(ZipEntry("assets/jsbay-backend.txt"))
                    destination.write("$jsbayBackend\n".toByteArray())
                    destination.closeEntry()
                }
            }
            Files.move(replacement.toPath(), aarFile.toPath(), StandardCopyOption.REPLACE_EXISTING)
        }
    }
}

afterEvaluate {
    publishing {
        publications {
            register<MavenPublication>("release") {
                from(components["release"])
                artifactId = jsbayArtifactId
                pom {
                    name.set("JsBay Android SDK ($jsbayBackend)")
                    description.set("Embedded JavaScript engine for Android using $jsbayBackend")
                    licenses {
                        license {
                            name.set("MIT License")
                            url.set("https://opensource.org/license/mit")
                            distribution.set("repo")
                        }
                    }
                }
            }
        }
        repositories {
            maven {
                name = "staging"
                url =
                    uri(
                        jsbayMavenRepo.orNull
                            ?: layout.buildDirectory
                                .dir("staging-repository")
                                .get()
                                .asFile,
                    )
            }
            if (githubRepository != null) {
                maven {
                    name = "GitHubPackages"
                    url = uri("https://maven.pkg.github.com/${githubRepository.lowercase()}")
                    credentials {
                        username = providers.environmentVariable("GITHUB_ACTOR").orNull.orEmpty()
                        password = providers.environmentVariable("GITHUB_TOKEN").orNull.orEmpty()
                    }
                }
            }
        }
    }
}
