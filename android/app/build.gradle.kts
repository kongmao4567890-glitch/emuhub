plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseKeystorePath = System.getenv("ANDROID_KEYSTORE_PATH")
val releaseKeystorePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")
val releaseKeyAlias = System.getenv("ANDROID_KEY_ALIAS")
val releaseKeyPassword = System.getenv("ANDROID_KEY_PASSWORD")
// 密钥文件由 CI 仅在 main/master 分支准备；PR 或本地构建时文件不存在，
// 需回退 debug 签名，否则 validateSigningRelease 会因找不到文件而失败。
val hasReleaseSigning = !releaseKeystorePath.isNullOrBlank() &&
    file(releaseKeystorePath).exists() &&
    listOf(
        releaseKeystorePassword,
        releaseKeyAlias,
        releaseKeyPassword,
    ).all { !it.isNullOrBlank() }

android {
    namespace = "com.emuhub.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
        }
    }

    defaultConfig {
        applicationId = "com.emuhub.app"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = file(releaseKeystorePath!!)
                storePassword = releaseKeystorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
                storeType = "PKCS12"
            }
        }
    }

    buildTypes {
        release {
            // 主分支由 GitHub Actions Secrets 注入固定的发布签名。
            // PR/本地未配置签名时回退 debug，便于执行无发布权限的验证构建。
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // core library desugaring（flutter_local_notifications 需要）
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    // workmanager 插件依赖的 AndroidX WorkManager 运行时库
    implementation("androidx.work:work-runtime-ktx:2.9.0")
    // flutter_local_notifications 依赖的 AndroidX 核心库
    implementation("androidx.core:core-ktx:1.13.1")
}
