package com.p2pintercom.p2p_intercom

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.Manifest
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * Foreground service that keeps the intercom receiving while the app is in
 * the background, the screen is off, or after the phone boots.
 *
 * It shows a permanent notification (required by Android), keeps the Flutter
 * engine running, and holds a partial wake lock plus a Wi-Fi lock so audio
 * keeps arriving and playing with the screen off.
 */
class IntercomService : Service() {
    companion object {
        private const val CHANNEL_ID = "intercom_background"
        private const val NOTIFICATION_ID = 4712
        const val EXTRA_WITH_MIC = "with_mic"

        /** The running service, to update its notification. */
        @Volatile var instance: IntercomService? = null

        private const val DEFAULT_TITLE = "Gundil Intercom is ready"
        private const val DEFAULT_TEXT =
            "Other intercoms can connect for two-way talk. Tap to open."
    }

    private var title = DEFAULT_TITLE
    private var text = DEFAULT_TEXT

    /** Shows who we're connected with / who is calling (empty = idle). */
    fun setStatus(newTitle: String?, newText: String?) {
        title = if (newTitle.isNullOrEmpty()) DEFAULT_TITLE else newTitle
        text = if (newTitle.isNullOrEmpty()) DEFAULT_TEXT else (newText ?: "")
        goForeground()
    }

    private var withMic = false

    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        goForeground()
        (application as GundilApp).ensureEngine()
        acquireLocks()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Upgrade to the microphone type when started from the visible app.
        val mic = intent?.getBooleanExtra(EXTRA_WITH_MIC, false) ?: false
        if (mic && !withMic) {
            withMic = true
            goForeground()
        }
        // If the system kills us under memory pressure, come back.
        return START_STICKY
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        releaseLocks()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun goForeground() {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "Background intercom",
                    NotificationManager.IMPORTANCE_LOW
                ).apply {
                    description = "Shown while Gundil Intercom listens in the background"
                    setShowBadge(false)
                }
            )
        }
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        @Suppress("DEPRECATION")
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            Notification.Builder(this).setPriority(Notification.PRIORITY_LOW)
        }
        val notification = builder
            .setContentTitle(title)
            .setContentText(text)
            .setOnlyAlertOnce(true)
            .setSmallIcon(R.drawable.ic_stat_intercom)
            .setContentIntent(open)
            .setOngoing(true)
            .setShowWhen(false)
            .build()

        val micAllowed = withMic &&
            checkSelfPermission(Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED
        try {
            when {
                Build.VERSION.SDK_INT >= 34 -> startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE or
                        (if (micAllowed) ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE else 0)
                )
                Build.VERSION.SDK_INT >= 30 -> startForeground(
                    NOTIFICATION_ID,
                    notification,
                    if (micAllowed) ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE else 0
                )
                else -> startForeground(NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            // Not allowed to add the microphone type right now (app in the
            // background); keep running without it.
            if (Build.VERSION.SDK_INT >= 34) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun acquireLocks() {
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "gundil:intercom").apply {
            setReferenceCounted(false)
            acquire()
        }
        val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
        val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            WifiManager.WIFI_MODE_FULL_LOW_LATENCY
        } else {
            WifiManager.WIFI_MODE_FULL_HIGH_PERF
        }
        wifiLock = wifi?.createWifiLock(mode, "gundil:intercom")?.apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    private fun releaseLocks() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        wifiLock?.let { if (it.isHeld) it.release() }
        wifiLock = null
    }
}
