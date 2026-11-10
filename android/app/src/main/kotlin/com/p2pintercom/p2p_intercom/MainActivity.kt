package com.p2pintercom.p2p_intercom

import android.content.Context
import android.content.pm.PackageManager
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

/**
 * Shows the Flutter UI on top of the shared engine owned by [GundilApp].
 *
 * With background mode on, closing the activity (Back, or swiping the app
 * away) leaves the engine running inside [IntercomService], so the intercom
 * keeps receiving. With it off, the engine is destroyed with the activity as
 * in a normal app.
 */
class MainActivity : FlutterActivity() {
    private val app: GundilApp
        get() = application as GundilApp

    private val permissionCallbacks = mutableMapOf<Int, (Boolean) -> Unit>()
    private var nextRequestCode = 4800

    override fun provideFlutterEngine(context: Context): FlutterEngine = app.ensureEngine()

    override fun shouldDestroyEngineWithHost(): Boolean = !app.backgroundEnabled

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        app.activity = this
    }

    override fun onResume() {
        super.onResume()
        app.activity = this
        // While visible, (re)start the background service with the
        // microphone type so two-way audio keeps working in the background.
        if (app.backgroundEnabled) app.startBackgroundService(withMic = true)
    }

    fun setKeepScreenOn(on: Boolean) {
        if (on) {
            window.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        } else {
            window.clearFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
    }

    override fun onDestroy() {
        if (app.activity === this) app.activity = null
        super.onDestroy()
    }

    /** Asks for a runtime permission and reports the outcome. */
    fun requestPermissionFor(permission: String, callback: (Boolean) -> Unit) {
        val code = nextRequestCode++
        permissionCallbacks[code] = callback
        requestPermissions(arrayOf(permission), code)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        val cb = permissionCallbacks.remove(requestCode) ?: return
        cb(grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED)
    }
}
