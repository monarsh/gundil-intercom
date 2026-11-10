package com.p2pintercom.p2p_intercom

import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper

/**
 * Chooses where two-way call audio plays (and is recorded): loudspeaker,
 * earpiece, Bluetooth headset or wired headset.
 *
 * Android 12+ (API 31) uses the communication-device API; older versions
 * use speakerphone + Bluetooth SCO. Bluetooth and wired headsets carry their
 * own microphone, so the mic follows the chosen output.
 *
 * Behaviour: a call starts on Bluetooth if connected, else a wired headset,
 * else the loudspeaker (intercom default). Plugging in / connecting a
 * headset during a call switches to it; if the current device goes away,
 * the best remaining one is used. [onChange] reports every change so the UI
 * stays in sync.
 */
class AudioRouter(
    private val context: Context,
    private val onChange: (Map<String, Any?>) -> Unit,
) {
    companion object {
        const val SPEAKER = "speaker"
        const val EARPIECE = "earpiece"
        const val BLUETOOTH = "bluetooth"
        const val WIRED = "wired"

        // Constants added in newer API levels (values are stable).
        private const val TYPE_USB_HEADSET = 22      // API 26
        private const val TYPE_HEARING_AID = 23      // API 28
        private const val TYPE_BLE_HEADSET = 26      // API 31
        private const val TYPE_BLE_SPEAKER = 27      // API 31

        /** Preference when picking automatically. */
        private val PRIORITY = listOf(BLUETOOTH, WIRED, SPEAKER, EARPIECE)
    }

    /** One selectable output. [id] is a device id (API 31+) or the type. */
    data class Route(val id: String, val type: String, val name: String) {
        fun toMap() = mapOf("id" to id, "type" to type, "name" to name)
    }

    private val am: AudioManager
        get() = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val main = Handler(Looper.getMainLooper())

    private var active = false
    private var legacyRoute = SPEAKER // API < 31: what we last applied
    private var deviceCallback: AudioDeviceCallback? = null
    private var commListener: Any? = null // AudioManager.OnCommunicationDeviceChangedListener

    // -------------------------------------------------------------- public

    fun start() {
        if (active) return
        active = true
        am.mode = AudioManager.MODE_IN_COMMUNICATION
        applyBest(null)
        registerCallbacks()
        notifyChange()
    }

    fun stop() {
        if (!active) return
        active = false
        unregisterCallbacks()
        if (Build.VERSION.SDK_INT >= 31) {
            am.clearCommunicationDevice()
        } else {
            @Suppress("DEPRECATION")
            run {
                am.stopBluetoothSco()
                am.isBluetoothScoOn = false
                am.isSpeakerphoneOn = false
            }
        }
        am.mode = AudioManager.MODE_NORMAL
        notifyChange()
    }

    /** Current state for the UI: {"active", "routes": [...], "current"}. */
    fun state(): Map<String, Any?> = mapOf(
        "active" to active,
        "routes" to routes().map { it.toMap() },
        "current" to current()?.id,
    )

    /** Switches to the route with [id]. Returns the new state. */
    fun select(id: String): Map<String, Any?> {
        val route = routes().firstOrNull { it.id == id }
        if (route != null) apply(route)
        notifyChange()
        return state()
    }

    /** Compatibility with the old speaker on/off switch. */
    fun setSpeaker(on: Boolean) {
        val wanted = if (on) SPEAKER else EARPIECE
        routes().firstOrNull { it.type == wanted }?.let { apply(it) }
        notifyChange()
    }

    // --------------------------------------------------------------- routes

    private fun typeOf(d: AudioDeviceInfo): String? = when (d.type) {
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> SPEAKER
        AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> EARPIECE
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
        TYPE_BLE_HEADSET, TYPE_BLE_SPEAKER, TYPE_HEARING_AID -> BLUETOOTH
        AudioDeviceInfo.TYPE_WIRED_HEADSET,
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES, TYPE_USB_HEADSET -> WIRED
        else -> null
    }

    private fun labelOf(type: String, product: CharSequence?): String {
        val p = product?.toString()?.trim().orEmpty()
        return when (type) {
            SPEAKER -> "Speaker"
            EARPIECE -> "Phone (earpiece)"
            BLUETOOTH -> if (p.isNotEmpty() && !p.equals(Build.MODEL, true)) p else "Bluetooth"
            WIRED -> if (p.isNotEmpty() && !p.equals(Build.MODEL, true)) p else "Wired headset"
            else -> p
        }
    }

    private fun hasEarpiece(): Boolean =
        context.packageManager.hasSystemFeature(PackageManager.FEATURE_TELEPHONY)

    fun routes(): List<Route> {
        if (Build.VERSION.SDK_INT >= 31) {
            val seen = mutableSetOf<String>()
            return am.availableCommunicationDevices.mapNotNull { d ->
                val type = typeOf(d) ?: return@mapNotNull null
                // Speaker / earpiece appear once; headsets once per device.
                val key = if (type == SPEAKER || type == EARPIECE) type else "$type:${d.productName}"
                if (!seen.add(key)) return@mapNotNull null
                Route(d.id.toString(), type, labelOf(type, d.productName))
            }.sortedBy { PRIORITY.indexOf(it.type) }
        }
        // API < 31: one entry per type.
        val outputs = am.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
        val list = mutableListOf(Route(SPEAKER, SPEAKER, labelOf(SPEAKER, null)))
        val wired = outputs.firstOrNull { typeOf(it) == WIRED }
        if (wired != null) {
            list += Route(WIRED, WIRED, labelOf(WIRED, wired.productName))
        } else if (hasEarpiece()) {
            list += Route(EARPIECE, EARPIECE, labelOf(EARPIECE, null))
        }
        outputs.firstOrNull { it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO }?.let {
            list += Route(BLUETOOTH, BLUETOOTH, labelOf(BLUETOOTH, it.productName))
        }
        return list.sortedBy { PRIORITY.indexOf(it.type) }
    }

    fun current(): Route? {
        val list = routes()
        if (Build.VERSION.SDK_INT >= 31) {
            val dev = am.communicationDevice ?: return null
            return list.firstOrNull { it.id == dev.id.toString() }
                ?: typeOf(dev)?.let { t -> list.firstOrNull { it.type == t } }
        }
        return list.firstOrNull { it.type == legacyRoute }
    }

    // ---------------------------------------------------------------- apply

    /** Picks the best available route (excluding [except], e.g. one just removed). */
    private fun applyBest(except: String?) {
        val best = routes().filter { it.id != except }
            .minByOrNull { PRIORITY.indexOf(it.type) } ?: return
        apply(best)
    }

    @Suppress("DEPRECATION")
    private fun apply(route: Route) {
        if (Build.VERSION.SDK_INT >= 31) {
            val dev = am.availableCommunicationDevices.firstOrNull { it.id.toString() == route.id }
            if (dev != null) am.setCommunicationDevice(dev)
            return
        }
        legacyRoute = route.type
        when (route.type) {
            BLUETOOTH -> {
                am.isSpeakerphoneOn = false
                am.startBluetoothSco()
                am.isBluetoothScoOn = true
            }
            SPEAKER -> {
                am.stopBluetoothSco()
                am.isBluetoothScoOn = false
                am.isSpeakerphoneOn = true
            }
            else -> { // earpiece or wired: the phone picks the wired headset if present
                am.stopBluetoothSco()
                am.isBluetoothScoOn = false
                am.isSpeakerphoneOn = false
            }
        }
    }

    // ------------------------------------------------------------ callbacks

    private fun registerCallbacks() {
        val cb = object : AudioDeviceCallback() {
            override fun onAudioDevicesAdded(added: Array<out AudioDeviceInfo>) {
                if (!active) return
                // A headset was connected during the call: switch to it.
                val headset = added.mapNotNull { typeOf(it) }
                    .firstOrNull { it == BLUETOOTH || it == WIRED }
                if (headset != null) {
                    // Bluetooth needs a moment before it becomes selectable.
                    main.postDelayed({
                        if (!active) return@postDelayed
                        routes().firstOrNull { it.type == headset }?.let { apply(it) }
                        notifyChange()
                    }, 700)
                }
                notifyChange()
            }

            override fun onAudioDevicesRemoved(removed: Array<out AudioDeviceInfo>) {
                if (!active) return
                val cur = current()
                if (cur == null || removed.any { typeOf(it) == cur.type }) applyBest(cur?.id)
                notifyChange()
            }
        }
        am.registerAudioDeviceCallback(cb, main)
        deviceCallback = cb
        if (Build.VERSION.SDK_INT >= 31) {
            val l = AudioManager.OnCommunicationDeviceChangedListener { notifyChange() }
            am.addOnCommunicationDeviceChangedListener(context.mainExecutor, l)
            commListener = l
        }
    }

    private fun unregisterCallbacks() {
        deviceCallback?.let { am.unregisterAudioDeviceCallback(it) }
        deviceCallback = null
        if (Build.VERSION.SDK_INT >= 31) {
            (commListener as? AudioManager.OnCommunicationDeviceChangedListener)?.let {
                am.removeOnCommunicationDeviceChangedListener(it)
            }
        }
        commListener = null
    }

    private fun notifyChange() = onChange(state())
}
