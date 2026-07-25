plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-plugin-loader")
}

android {
    namespace = "com.emuhub.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = "11"
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
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // workmanager 插件依赖的 AndroidX WorkManager 运行时库
    implementation("androidx.work:work-runtime-ktx:2.9.0")
    // flutter_local_notifications 依赖的 AndroidX 核心库
    implementation("androidx.core:core-ktx:1.13.1")
}
