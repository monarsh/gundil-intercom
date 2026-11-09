package com.p2pintercom.p2p_intercom

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Starts the background intercom after the phone boots (or after the app is
 * updated) when the user enabled "Start when phone turns on".
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED -> {
                val prefs = GundilApp.prefs(context)
                val boot = prefs.getBoolean(GundilApp.PREF_BOOT, false)
                val background = prefs.getBoolean(GundilApp.PREF_BACKGROUND, false)
                val start = if (intent.action == Intent.ACTION_MY_PACKAGE_REPLACED) {
                    background // keep running across app updates
                } else {
                    boot && background
                }
                if (start) {
                    (context.applicationContext as GundilApp).startBackgroundService()
                }
            }
        }
    }
}
