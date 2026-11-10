package com.p2pintercom.p2p_intercom

import android.content.Context
import android.graphics.Bitmap
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Size
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Camera for video calls (CameraX). The user turns it on from the call
 * screen; it is never started automatically.
 *
 * Pictures are delivered upright (CameraX rotates them), JPEG-compressed at
 * about 640x480 and [fps] pictures per second, on the
 * `p2p_intercom/camera/frames` event channel as
 * `{"jpeg": ByteArray, "rotation": 0..3, "mirror": Boolean}`.
 *
 * The camera is bound to the activity's lifecycle: Android does not allow
 * using it from the background, so it pauses while the app isn't visible
 * (peers then stop seeing the picture) and resumes when it comes back.
 */
class CameraCapture(private val app: GundilApp) : EventChannel.StreamHandler {
    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private var executor: ExecutorService? = null
    private var provider: ProcessCameraProvider? = null
    private var analysis: ImageAnalysis? = null

    @Volatile private var running = false
    @Volatile private var quality = 70
    @Volatile private var minIntervalMs = 66L
    @Volatile private var mirror = false
    private var lastFrameAt = 0L

    // ------------------------------------------------------------ cameras

    /** Lens directions this phone has: front, back, external (USB). */
    fun list(): List<Map<String, String>> {
        val cm = app.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val facings = linkedSetOf<String>()
        try {
            for (id in cm.cameraIdList) {
                when (cm.getCameraCharacteristics(id).get(CameraCharacteristics.LENS_FACING)) {
                    CameraCharacteristics.LENS_FACING_FRONT -> facings.add(FRONT)
                    CameraCharacteristics.LENS_FACING_BACK -> facings.add(BACK)
                    CameraCharacteristics.LENS_FACING_EXTERNAL -> facings.add(EXTERNAL)
                }
            }
        } catch (_: Exception) {
            // No camera service (some TV boxes): no cameras.
        }
        return listOf(FRONT, BACK, EXTERNAL).filter { it in facings }.map {
            mapOf(
                "id" to it,
                "facing" to it,
                "name" to when (it) {
                    FRONT -> "Front camera"
                    BACK -> "Back camera"
                    else -> "USB camera"
                }
            )
        }
    }

    // ------------------------------------------------------- start / stop

    fun start(
        id: String,
        width: Int,
        height: Int,
        fps: Int,
        quality: Int,
        result: MethodChannel.Result
    ) {
        val activity = app.activity
        if (activity == null) {
            result.error("no_activity", "Open the app to use the camera", null)
            return
        }
        this.quality = quality.coerceIn(30, 95)
        this.minIntervalMs = 1000L / fps.coerceIn(1, 30)
        this.mirror = id == FRONT
        val facing = when (id) {
            FRONT -> CameraSelector.LENS_FACING_FRONT
            BACK -> CameraSelector.LENS_FACING_BACK
            else -> CameraSelector.LENS_FACING_EXTERNAL
        }
        val future = ProcessCameraProvider.getInstance(app)
        future.addListener({
            try {
                val p = future.get()
                provider = p
                p.unbindAll()
                val exec = executor ?: Executors.newSingleThreadExecutor().also { executor = it }
                val a = ImageAnalysis.Builder()
                    .setResolutionSelector(
                        ResolutionSelector.Builder()
                            .setResolutionStrategy(
                                ResolutionStrategy(
                                    Size(width, height),
                                    ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER
                                )
                            )
                            .build()
                    )
                    .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                    .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_RGBA_8888)
                    .setOutputImageRotationEnabled(true)
                    .build()
                a.setAnalyzer(exec) { image -> process(image) }
                analysis = a
                val selector = CameraSelector.Builder().requireLensFacing(facing).build()
                running = true
                lastFrameAt = 0L
                p.bindToLifecycle(activity, selector, a)
                result.success(null)
            } catch (e: Exception) {
                running = false
                result.error("camera", e.message ?: e.javaClass.simpleName, null)
            }
        }, ContextCompat.getMainExecutor(app))
    }

    fun stop() {
        running = false
        analysis?.clearAnalyzer()
        analysis = null
        try {
            provider?.unbindAll()
        } catch (_: Exception) {}
    }

    // ------------------------------------------------------------ pictures

    private fun process(image: ImageProxy) {
        try {
            if (!running) return
            val now = SystemClock.elapsedRealtime()
            if (now - lastFrameAt < minIntervalMs) return
            lastFrameAt = now
            val bitmap: Bitmap = image.toBitmap()
            val out = ByteArrayOutputStream(48 * 1024)
            bitmap.compress(Bitmap.CompressFormat.JPEG, quality, out)
            bitmap.recycle()
            // Normally 0: CameraX already rotated the picture upright.
            val turns = (image.imageInfo.rotationDegrees / 90) and 3
            val event = mapOf(
                "jpeg" to out.toByteArray(),
                "rotation" to turns,
                "mirror" to mirror
            )
            main.post { if (running) sink?.success(event) }
        } catch (e: Exception) {
            // Skip a bad picture; the next one usually works.
        } finally {
            image.close()
        }
    }

    // ------------------------------------------------------- event channel

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    companion object {
        const val FRONT = "front"
        const val BACK = "back"
        const val EXTERNAL = "external"
    }
}
