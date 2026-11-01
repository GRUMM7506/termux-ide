package com.grumm.termux_ide

import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val termuxPkg = "com.termux"
    private val runCommandPerm = "com.termux.permission.RUN_COMMAND"
    private var pendingPermResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "termux_ide/native")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "filesDir" -> result.success(filesDir.absolutePath)
                        "isTermuxInstalled" -> result.success(isTermuxInstalled())
                        "hasPermission" -> result.success(hasPerm())
                        "ensurePermission" -> {
                            if (hasPerm()) {
                                result.success(true)
                            } else if (!isTermuxInstalled()) {
                                result.success(false)
                            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                                pendingPermResult = result
                                requestPermissions(arrayOf(runCommandPerm), 42)
                            } else {
                                result.success(true)
                            }
                        }
                        "runInTermux" -> {
                            runInTermux(
                                call.argument<String>("command")!!,
                                call.argument<String>("workdir"),
                                call.argument<Boolean>("background") ?: false,
                            )
                            result.success(null)
                        }
                        "openTermux" -> {
                            val i = packageManager.getLaunchIntentForPackage(termuxPkg)
                            if (i == null) {
                                result.error("NO_TERMUX", "Termux не установлен", null)
                            } else {
                                startActivity(i)
                                result.success(null)
                            }
                        }
                        "openUrl" -> {
                            startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(call.argument<String>("url")!!)))
                            result.success(null)
                        }
                        "openAppSettings" -> {
                            startActivity(
                                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName"))
                            )
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("NATIVE", e.message ?: e.toString(), null)
                }
            }
    }

    private fun isTermuxInstalled(): Boolean = try {
        packageManager.getPackageInfo(termuxPkg, 0)
        true
    } catch (e: PackageManager.NameNotFoundException) {
        false
    }

    private fun hasPerm(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        return checkSelfPermission(runCommandPerm) == PackageManager.PERMISSION_GRANTED
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 42) {
            pendingPermResult?.success(
                grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
            )
            pendingPermResult = null
        }
    }

    // https://github.com/termux/termux-app/wiki/RUN_COMMAND-Intent
    private fun runInTermux(command: String, workdir: String?, background: Boolean) {
        val prefix = "/data/data/com.termux/files/usr"
        val script = if (background) command else "$command; echo; echo '[Termux IDE: готово, окно можно закрыть]'; exec bash"
        val intent = Intent().apply {
            setClassName(termuxPkg, "com.termux.app.RunCommandService")
            action = "com.termux.RUN_COMMAND"
            putExtra("com.termux.RUN_COMMAND_PATH", "$prefix/bin/bash")
            putExtra("com.termux.RUN_COMMAND_ARGUMENTS", arrayOf("-c", script))
            putExtra("com.termux.RUN_COMMAND_WORKDIR", workdir ?: "/data/data/com.termux/files/home")
            putExtra("com.termux.RUN_COMMAND_BACKGROUND", background)
            // "0" = switch to the new session and open Termux
            putExtra("com.termux.RUN_COMMAND_SESSION_ACTION", "0")
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }
}
