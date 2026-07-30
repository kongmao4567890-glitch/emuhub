plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

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

    buildTypes {
        release {
            // TODO(发布前必改): 当前 release 使用 debug 签名，仅适合个人测试。
            // 公开发布请配置独立的 upload keystore（通过 CI secrets 注入，
            // 切勿把私钥提交进仓库），否则 APK 可能被他人冒名签名覆盖安装。
            signingConfig = signingConfigs.getByName("debug")
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
