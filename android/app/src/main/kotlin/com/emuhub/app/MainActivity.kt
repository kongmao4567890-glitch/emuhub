package com.emuhub.app

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val updateChannel = "com.emuhub.app/app_update"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            updateChannel,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getAppVersion" -> result.success(
                    mapOf(
                        "versionCode" to BuildConfig.VERSION_CODE,
                        "versionName" to BuildConfig.VERSION_NAME,
                    ),
                )
                "canInstallPackages" -> result.success(canInstallPackages())
                "installApk" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) {
                        result.error("INVALID_PATH", "APK path is empty", null)
                        return@setMethodCallHandler
                    }
                    try {
                        result.success(installApk(path))
                    } catch (error: Exception) {
                        result.error("INSTALL_FAILED", error.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun canInstallPackages(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
            packageManager.canRequestPackageInstalls()

    private fun installApk(path: String): String {
        val apk = File(path).canonicalFile
        val allowedRoot = File(cacheDir, "updates").canonicalFile
        val allowedPrefix = allowedRoot.path + File.separator
        require(apk.path.startsWith(allowedPrefix) && apk.name.endsWith(".apk")) {
            "APK path is outside the update cache"
        }
        require(apk.isFile && apk.length() > 0L) { "APK file is missing" }

        if (!canInstallPackages()) {
            val permissionIntent = Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:$packageName"),
            )
            try {
                startActivity(permissionIntent)
            } catch (_: ActivityNotFoundException) {
                startActivity(Intent(Settings.ACTION_SECURITY_SETTINGS))
            }
            return "permission_required"
        }

        val uri = FileProvider.getUriForFile(
            this,
            "$packageName.fileprovider",
            apk,
        )
        val installIntent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(installIntent)
        return "launched"
    }
}
