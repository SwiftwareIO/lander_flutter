package link.lander.lander_flutter

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.android.installreferrer.api.InstallReferrerClient
import com.android.installreferrer.api.InstallReferrerStateListener
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.PluginRegistry
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Native side of lander_flutter on Android.
 *
 * Delivers App Links and custom scheme URLs (launch intent and onNewIntent) to
 * Dart, reads the Play Install Referrer, and stores the SDK's small state in
 * noBackupFilesDir so it is never restored onto another device.
 */
class LanderFlutterPlugin :
    FlutterPlugin,
    MethodCallHandler,
    EventChannel.StreamHandler,
    ActivityAware,
    PluginRegistry.NewIntentListener {

    private lateinit var context: Context
    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var activityBinding: ActivityPluginBinding? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val io: ExecutorService = Executors.newSingleThreadExecutor()

    // Link delivery state. Only touched on the main thread.
    private var launchIntentRead = false
    private var initialLinkRequested = false
    private var initialLink: String? = null
    private var sink: EventChannel.EventSink? = null
    private val pending = ArrayDeque<String>()

    // FlutterPlugin

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, "lander_flutter/methods").also {
            it.setMethodCallHandler(this)
        }
        eventChannel = EventChannel(binding.binaryMessenger, "lander_flutter/links").also {
            it.setStreamHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel?.setMethodCallHandler(null)
        eventChannel?.setStreamHandler(null)
        methodChannel = null
        eventChannel = null
        io.shutdown()
    }

    // ActivityAware

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        attach(binding)
        if (!launchIntentRead) {
            launchIntentRead = true
            linkFrom(binding.activity.intent, isLaunchIntent = true)?.let(::onLaunchLink)
        }
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        // Same launch intent as before the configuration change: do not re-read it.
        attach(binding)
    }

    override fun onDetachedFromActivityForConfigChanges() = detach()

    override fun onDetachedFromActivity() = detach()

    private fun attach(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addOnNewIntentListener(this)
    }

    private fun detach() {
        activityBinding?.removeOnNewIntentListener(this)
        activityBinding = null
    }

    // NewIntentListener (warm start)

    override fun onNewIntent(intent: Intent): Boolean {
        linkFrom(intent, isLaunchIntent = false)?.let(::emit)
        // Do not consume the intent; other plugins may want it too.
        return false
    }

    private fun linkFrom(intent: Intent?, isLaunchIntent: Boolean): String? {
        if (intent == null || intent.action != Intent.ACTION_VIEW) return null
        // Reopening from Recents replays the original intent. It was handled already.
        if (isLaunchIntent && (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0) return null
        return intent.dataString?.takeIf { it.isNotEmpty() }
    }

    private fun onLaunchLink(link: String) {
        // If Dart already asked for the initial link (engine started before the
        // activity attached), hand this one over through the stream instead.
        if (initialLinkRequested) emit(link) else initialLink = link
    }

    private fun emit(link: String) {
        val s = sink
        if (s != null) s.success(link) else pending.addLast(link)
    }

    // EventChannel.StreamHandler

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
        while (pending.isNotEmpty()) events.success(pending.removeFirst())
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    // MethodCallHandler

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "getInitialLink" -> {
                initialLinkRequested = true
                result.success(initialLink)
                initialLink = null
            }
            "getPlatformInfo" -> result.success(
                mapOf(
                    "platform" to "android",
                    "appVersion" to appVersion(),
                    "osVersion" to Build.VERSION.RELEASE,
                )
            )
            "getInstallReferrer" -> readInstallReferrer(result)
            "storageRead" -> storage(call, result) { file -> if (file.exists()) file.readText() else null }
            "storageWrite" -> storage(call, result) { file ->
                val value = call.argument<String>("value") ?: ""
                val tmp = File(file.parentFile, "${file.name}.tmp")
                tmp.writeText(value)
                if (!tmp.renameTo(file)) {
                    file.writeText(value)
                    tmp.delete()
                }
                null
            }
            "storageDelete" -> storage(call, result) { file -> file.delete(); null }
            else -> result.notImplemented()
        }
    }

    private fun appVersion(): String = try {
        val info = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.packageManager.getPackageInfo(context.packageName, PackageManager.PackageInfoFlags.of(0))
        } else {
            @Suppress("DEPRECATION")
            context.packageManager.getPackageInfo(context.packageName, 0)
        }
        info.versionName ?: "0.0.0"
    } catch (e: Exception) {
        "0.0.0"
    }

    private fun storage(call: MethodCall, result: Result, op: (File) -> String?) {
        val key = call.argument<String>("key")
        if (key == null || !KEY_PATTERN.matches(key)) {
            result.error("invalid_key", "Storage keys must match $KEY_PATTERN", null)
            return
        }
        try {
            io.execute {
                try {
                    val dir = File(context.noBackupFilesDir, "lander_flutter").apply { mkdirs() }
                    val value = op(File(dir, key))
                    mainHandler.post { result.success(value) }
                } catch (e: Exception) {
                    mainHandler.post { result.error("storage_error", e.message, null) }
                }
            }
        } catch (e: java.util.concurrent.RejectedExecutionException) {
            // The engine is shutting down.
            result.error("storage_error", "Plugin detached", null)
        }
    }

    private fun readInstallReferrer(result: Result) {
        val replied = AtomicBoolean(false)
        fun reply(value: String?) {
            if (replied.compareAndSet(false, true)) mainHandler.post { result.success(value) }
        }

        val client = try {
            InstallReferrerClient.newBuilder(context).build()
        } catch (e: Exception) {
            reply(null)
            return
        }
        try {
            client.startConnection(object : InstallReferrerStateListener {
                override fun onInstallReferrerSetupFinished(responseCode: Int) {
                    val referrer = if (responseCode == InstallReferrerClient.InstallReferrerResponse.OK) {
                        try {
                            client.installReferrer.installReferrer
                        } catch (e: Exception) {
                            Log.w(TAG, "Install referrer unavailable: ${e.message}")
                            null
                        }
                    } else {
                        null
                    }
                    reply(referrer)
                    try {
                        client.endConnection()
                    } catch (_: Exception) {
                    }
                }

                override fun onInstallReferrerServiceDisconnected() {
                    reply(null)
                }
            })
        } catch (e: Exception) {
            // Thrown on devices without the Play Store or with a broken one.
            Log.w(TAG, "Install referrer connection failed: ${e.message}")
            reply(null)
        }
    }

    private companion object {
        const val TAG = "Lander"
        val KEY_PATTERN = Regex("^[a-z0-9_]{1,64}$")
    }
}
