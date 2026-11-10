package com.p2pintercom.p2p_intercom

import android.Manifest
import android.app.Application
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Owns the single, long-lived Flutter engine that runs the intercom.
 *
 * The engine (and with it the Dart networking/audio code) is created on
 * demand — by the activity when the user opens the app, or by
 * [IntercomService] when it starts after boot — and survives the activity
 * being closed while background mode is on.
 *
 * Also hosts the `p2p_intercom/platform` method channel, so it works whether
 * or not an activity is showing.
 */
class GundilApp : Application() {
    companion object {
        const val ENGINE_ID = "gundil_main"
        private const val CHANNEL = "p2p_intercom/platform"
        private const val PREFS = "gundil_native"
        const val PREF_BACKGROUND = "background"
        const val PREF_BOOT = "start_on_boot"

        fun prefs(context: Context): SharedPreferences =
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    }

    /** The visible activity, if any (needed for permission dialogs). */
    var activity: MainActivity? = null

    private var multicastLock: WifiManager.MulticastLock? = null

    val backgroundEnabled: Boolean
        get() = prefs(this).getBoolean(PREF_BACKGROUND, false)

    /** Returns the running engine, starting the Dart app if needed. */
    fun ensureEngine(): FlutterEngine {
        FlutterEngineCache.getInstance().get(ENGINE_ID)?.let { return it }
        val engine = FlutterEngine(this)
        engine.addEngineLifecycleListener(object : FlutterEngine.EngineLifecycleListener {
            override fun onPreEngineRestart() {}
            override fun onEngineWillDestroy() {
                FlutterEngineCache.getInstance().remove(ENGINE_ID)
                camera.stop()
                releaseMulticastLock()
            }
        })
        setUpChannel(engine)
        setUpCamera(engine)
        engine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint.createDefault()
        )
        FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
        return engine
    }

    /**
     * Starts (or upgrades) the background service. [withMic] adds the
     * microphone service type so a connection answered in the background can
     * use the mic; Android only allows that while the app is visible.
     */
    fun startBackgroundService(withMic: Boolean = false) {
        val intent = Intent(this, IntercomService::class.java)
            .putExtra(IntercomService.EXTRA_WITH_MIC, withMic)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    fun stopBackgroundService() {
        stopService(Intent(this, IntercomService::class.java))
    }

    /** Channel to Dart, also used to push audio-route changes. */
    private var channel: MethodChannel? = null

    private fun setUpChannel(engine: FlutterEngine) {
        val ch = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        channel = ch
        ch.setMethodCallHandler { call, result ->
                when (call.method) {
                    "requestMicrophone" ->
                        requestPermission(Manifest.permission.RECORD_AUDIO, result)
                    "requestNotifications" ->
                        if (Build.VERSION.SDK_INT >= 33) {
                            requestPermission(Manifest.permission.POST_NOTIFICATIONS, result)
                        } else {
                            result.success(true)
                        }
                    "startCallAudio" -> { startCallAudio(); result.success(null) }
                    "setSpeaker" -> {
                        router.setSpeaker(call.argument<Boolean>("speaker") ?: true)
                        result.success(null)
                    }
                    "getAudioRoutes" -> result.success(router.state())
                    "setAudioRoute" -> {
                        val id = call.argument<String>("id")
                        result.success(if (id == null) router.state() else router.select(id))
                    }
                    "stopCallAudio" -> { stopCallAudio(); result.success(null) }
                    "setStatus" -> {
                        IntercomService.instance?.setStatus(
                            call.argument<String>("title"),
                            call.argument<String>("text")
                        )
                        result.success(null)
                    }
                    "acquireMulticastLock" -> { acquireMulticastLock(); result.success(null) }
                    "releaseMulticastLock" -> { releaseMulticastLock(); result.success(null) }
                    "getBackground" -> result.success(backgroundEnabled)
                    "setBackground" -> {
                        val on = call.argument<Boolean>("enabled") ?: false
                        prefs(this).edit().putBoolean(PREF_BACKGROUND, on).apply()
                        if (on) startBackgroundService(withMic = activity != null)
                        else stopBackgroundService()
                        result.success(on)
                    }
                    "getStartOnBoot" -> result.success(prefs(this).getBoolean(PREF_BOOT, false))
                    "setStartOnBoot" -> {
                        val on = call.argument<Boolean>("enabled") ?: false
                        prefs(this).edit().putBoolean(PREF_BOOT, on).apply()
                        result.success(on)
                    }
                    "isIgnoringBatteryOptimizations" -> result.success(isIgnoringBatteryOptimizations())
                    "requestIgnoreBatteryOptimizations" -> {
                        requestIgnoreBatteryOptimizations()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // --------------------------------------------------------------- camera

    /** Video-call camera (see [CameraCapture]). */
    private val camera by lazy { CameraCapture(this) }

    private fun setUpCamera(engine: FlutterEngine) {
        val messenger = engine.dartExecutor.binaryMessenger
        EventChannel(messenger, "p2p_intercom/camera/frames").setStreamHandler(camera)
        MethodChannel(messenger, "p2p_intercom/camera").setMethodCallHandler { call, result ->
            when (call.method) {
                "requestPermission" -> requestPermission(Manifest.permission.CAMERA, result)
                "list" -> result.success(camera.list())
                "start" -> camera.start(
                    id = call.argument<String>("id") ?: CameraCapture.FRONT,
                    width = call.argument<Int>("width") ?: 640,
                    height = call.argument<Int>("height") ?: 480,
                    fps = call.argument<Int>("fps") ?: 15,
                    quality = call.argument<Int>("quality") ?: 70,
                    result = result
                )
                "stop" -> { camera.stop(); result.success(null) }
                else -> result.notImplemented()
            }
        }
    }

    private fun requestPermission(permission: String, result: MethodChannel.Result) {
        if (checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED) {
            result.success(true)
            return
        }
        val a = activity
        if (a == null) {
            // No UI to ask from (e.g. started at boot).
            result.success(false)
            return
        }
        a.requestPermissionFor(permission) { granted -> result.success(granted) }
    }

    // ----------------------------------------------------------- call audio

    /** Picks the audio output (speaker / earpiece / Bluetooth / wired). */
    private val router by lazy {
        AudioRouter(this) { state -> channel?.invokeMethod("audioRoutesChanged", state) }
    }

    /** Two-way audio: voice-communication mode (hardware echo canceller). */
    private fun startCallAudio() {
        router.start()
        activity?.setKeepScreenOn(true)
    }

    private fun stopCallAudio() {
        router.stop()
        activity?.setKeepScreenOn(false)
    }

    // ------------------------------------------------------------ discovery

    private fun acquireMulticastLock() {
        if (multicastLock?.isHeld == true) return
        val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            ?: return
        multicastLock = wifi.createMulticastLock("gundil-discovery").apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    private fun releaseMulticastLock() {
        multicastLock?.let { if (it.isHeld) it.release() }
        multicastLock = null
    }

    // -------------------------------------------------------------- battery

    private fun isIgnoringBatteryOptimizations(): Boolean {
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        return pm.isIgnoringBatteryOptimizations(packageName)
    }

    /** Asks the user to let the app run unrestricted (needed for Doze). */
    private fun requestIgnoreBatteryOptimizations() {
        if (isIgnoringBatteryOptimizations()) return
        val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
            .setData(Uri.parse("package:$packageName"))
        val ctx: Context = activity ?: this
        if (ctx !== activity) intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            ctx.startActivity(intent)
        } catch (_: Exception) {
            // Some OEM builds lack this screen; fall back to the app list.
            try {
                ctx.startActivity(
                    Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                )
            } catch (_: Exception) {}
        }
    }
}
