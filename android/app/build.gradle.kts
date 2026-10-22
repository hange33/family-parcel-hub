plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// family-hub: 固定签名。
// 目的：每次 CI 出包用同一把钥匙，新包可以直接覆盖安装，不用卸载 → 登录态与数据不丢。
// 密钥库在 android/keystore/（私有仓库），口令也在同目录 keystore.properties。
import java.io.FileInputStream
import java.util.Properties

val hubKeystorePropsFile = rootProject.file("keystore/keystore.properties")
val hubKeystoreProps = Properties().apply {
    if (hubKeystorePropsFile.exists()) {
        FileInputStream(hubKeystorePropsFile).use { load(it) }
    }
}

android {
    namespace = "com.example.pickup_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.pickup_app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hubKeystorePropsFile.exists()) {
            create("hubRelease") {
                storeFile = rootProject.file(
                    "keystore/" + hubKeystoreProps.getProperty("storeFile")
                )
                storePassword = hubKeystoreProps.getProperty("storePassword")
                keyAlias = hubKeystoreProps.getProperty("keyAlias")
                keyPassword = hubKeystoreProps.getProperty("keyPassword")
                storeType = "PKCS12"
            }
        }
    }

    buildTypes {
        release {
            // family-hub: 有固定签名就用固定签名；没有才退回 debug（仅本地构建兜底）
            signingConfig = if (hubKeystorePropsFile.exists()) {
                signingConfigs.getByName("hubRelease")
            } else {
                signingConfigs.getByName("debug")
            }
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    implementation("androidx.webkit:webkit:1.15.0")
}

flutter {
    source = "../.."
}
