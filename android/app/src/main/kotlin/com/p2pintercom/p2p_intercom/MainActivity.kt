package com.p2pintercom.p2p_intercom

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.net.wifi.WifiManager
import android.os.Build
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Hosts the Flutter UI and implements the small set of Android-only features
 * the intercom needs (see lib/src/platform_bridge.dart):
 *  - runtime RECORD_AUDIO permission
 *  - Wi-Fi multicast lock so UDP discovery broadcasts are received
 *  - voice-communication audio mode (enables hardware echo cancellation)
 *    and loudspeaker / earpiece routing
 */
class MainActivity : FlutterActivity() {
    private val channelName = "p2p_intercom/platform"
    private val micRequestCode = 4711
    private var pendingMicResult: MethodChannel.Result? = null
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "requestMicrophone" -> requestMicrophone(result)
                    "acquireMulticastLock" -> { acquireMulticastLock(); result.success(null) }
                    "releaseMulticastLock" -> { releaseMulticastLock(); result.success(null) }
                    "startCallAudio" -> {
                        startCallAudio(call.argument<Boolean>("speaker") ?: true)
                        result.success(null)
                    }
                    "setSpeaker" -> {
                        setSpeaker(call.argument<Boolean>("speaker") ?: true)
                        result.success(null)
                    }
                    "stopCallAudio" -> { stopCallAudio(); result.success(null) }
                    else -> result.notImplemented()
                }
            }
    }

    // ---------------------------------------------------------- permissions

    private fun requestMicrophone(result: MethodChannel.Result) {
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            result.success(true)
            return
        }
        if (pendingMicResult != null) {
            result.error("busy", "Permission request already in progress", null)
            return
        }
        pendingMicResult = result
        requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), micRequestCode)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == micRequestCode) {
            val granted = grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED
            pendingMicResult?.success(granted)
            pendingMicResult = null
        }
    }

    // ------------------------------------------------------------ discovery

    private fun acquireMulticastLock() {
        if (multicastLock?.isHeld == true) return
        val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            ?: return
        multicastLock = wifi.createMulticastLock("p2p-intercom-discovery").apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    private fun releaseMulticastLock() {
        multicastLock?.let { if (it.isHeld) it.release() }
        multicastLock = null
    }

    // ---------------------------------------------------------------- audio

    private val audioManager: AudioManager
        get() = getSystemService(Context.AUDIO_SERVICE) as AudioManager

    private fun startCallAudio(speaker: Boolean) {
        audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
        setSpeaker(speaker)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    @Suppress("DEPRECATION")
    private fun setSpeaker(speaker: Boolean) {
        val am = audioManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            if (speaker) {
                val dev = am.availableCommunicationDevices
                    .firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }
                if (dev != null) am.setCommunicationDevice(dev)
            } else {
                am.clearCommunicationDevice()
            }
        } else {
            am.isSpeakerphoneOn = speaker
        }
    }

    @Suppress("DEPRECATION")
    private fun stopCallAudio() {
        val am = audioManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            am.clearCommunicationDevice()
        } else {
            am.isSpeakerphoneOn = false
        }
        am.mode = AudioManager.MODE_NORMAL
        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    override fun onDestroy() {
        releaseMulticastLock()
        super.onDestroy()
    }
}
