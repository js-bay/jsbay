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
val licenseFile = rootProject.file("../../LICENSE")
val noticesFile = rootProject.file("../../THIRD_PARTY_NOTICES.md")

group = "io.jsbay"
version = jsbayVersion.get()

android {
    namespace = "io.jsbay"
    compileSdk = 35
    ndkVersion = "28.2.13676358"
    defaultConfig {
        minSdk = 24
        ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
        consumerProguardFiles("consumer-rules.pro")
        val jniRoot = providers.gradleProperty("jsbayJniLibs").orNull
        if (jniRoot != null) {
            sourceSets.getByName("main").jniLibs.srcDir(jniRoot)
            externalNativeBuild { cmake { arguments += "-DJSBAY_JNI_LIBS=$jniRoot" } }
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
        doLast {
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
                artifactId = "js-bay-android"
                pom {
                    name.set("JsBay Android SDK")
                    description.set("Embedded JavaScript engine for Android")
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
        }
    }
}
