package com.example.flutter_nsfw_scaner

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.ContentUris
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.util.Size
import android.util.Log
import android.webkit.MimeTypeMap
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.FlutterPlugin.FlutterAssets
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.PluginRegistry
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.tensorflow.lite.DataType
import org.tensorflow.lite.Interpreter
import java.io.BufferedReader
import java.io.File
import java.io.InputStreamReader
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import java.util.Locale
import java.util.concurrent.Callable
import java.util.concurrent.CancellationException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.exp
import kotlin.math.max
import kotlin.math.roundToInt

class FlutterNsfwScanerPlugin : FlutterPlugin, MethodCallHandler, EventChannel.StreamHandler, ActivityAware, PluginRegistry.ActivityResultListener, PluginRegistry.RequestPermissionsResultListener {
    private lateinit var channel: MethodChannel
    private lateinit var progressChannel: EventChannel
    private lateinit var context: Context
    private lateinit var flutterAssets: FlutterAssets

    private val mainHandler = Handler(Looper.getMainLooper())
    private val backgroundExecutor: ExecutorService = Executors.newCachedThreadPool()
    private val sinkLock = Any()
    private val cancelledScanIds = ConcurrentHashMap.newKeySet<String>()
    private val cancelGeneration = AtomicInteger(0)
    private val pickerLock = Any()

    private var activityBinding: ActivityPluginBinding? = null
    private var activity: Activity? = null
    private var pendingPickerResult: Result? = null
    private var pendingPermissionResult: Result? = null
    private var pendingPickerAllowImages: Boolean = true
    private var pendingPickerAllowVideos: Boolean = true
    private var pendingPickerMultiple: Boolean = false

    private val mediaPickerRequestCode = 9331
    private val mediaPermissionRequestCode = 9332

    @Volatile
    private var scanner: AndroidNsfwScanner? = null

    @Volatile
    private var progressSink: EventChannel.EventSink? = null

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        context = flutterPluginBinding.applicationContext
        flutterAssets = flutterPluginBinding.flutterAssets
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, "flutter_nsfw_scaner")
        progressChannel = EventChannel(flutterPluginBinding.binaryMessenger, "flutter_nsfw_scaner/progress")
        channel.setMethodCallHandler(this)
        progressChannel.setStreamHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "getPlatformVersion" -> dispatchSuccess(result, "Android ${android.os.Build.VERSION.RELEASE}")
            "initializeScanner" -> initializeScanner(call, result)
            "scanImage" -> scanImage(call, result)
            "scanBatch" -> scanBatch(call, result)
            "scanVideo" -> scanVideo(call, result)
            "scanMediaBatch" -> scanMediaBatch(call, result)
            "scanGallery" -> scanGallery(call, result)
            "loadImageThumbnail" -> loadImageThumbnail(call, result)
            "loadImageAsset" -> loadImageAsset(call, result)
            "pickMedia" -> pickMedia(call, result)
            "cancelScan" -> cancelScan(call, result)
            "disposeScanner" -> disposeScanner(result)
            else -> dispatchNotImplemented(result)
        }
    }

    private fun cancelScan(call: MethodCall, result: Result) {
        val args = call.arguments as? Map<*, *>
        val scanId = args?.get("scanId")?.toString()?.trim()
        if (scanId.isNullOrEmpty()) {
            cancelGeneration.incrementAndGet()
        } else {
            cancelledScanIds.add(scanId)
        }
        dispatchSuccess(result, null)
    }

    private fun initializeScanner(call: MethodCall, result: Result) {
        backgroundExecutor.execute {
            try {
                val args = requireArgs(call)
                val modelAssetPath = args["modelAssetPath"]?.toString()?.trim().orEmpty()
                if (modelAssetPath.isEmpty()) {
                    throw IllegalArgumentException("modelAssetPath is required")
                }

                val labelsAssetPath = args["labelsAssetPath"]?.toString()?.trim().takeUnless { it.isNullOrEmpty() }
                val numThreads = (args["numThreads"] as? Number)?.toInt()?.coerceIn(1, 8) ?: 2
                val inputNormalization = InputNormalizationMode.fromWireValue(
                    args["inputNormalization"]?.toString(),
                )

                val newScanner = AndroidNsfwScanner(
                    context = context,
                    flutterAssets = flutterAssets,
                    modelAssetPath = modelAssetPath,
                    labelsAssetPath = labelsAssetPath,
                    defaultNumThreads = numThreads,
                    inputNormalization = inputNormalization,
                )

                scanner?.close()
                scanner = newScanner
                dispatchSuccess(result, null)
            } catch (error: Exception) {
                dispatchError(result, "INIT_FAILED", error.message ?: "Failed to initialize scanner", error)
            }
        }
    }

    private fun scanImage(call: MethodCall, result: Result) {
        backgroundExecutor.execute {
            try {
                val currentScanner = scanner ?: throw IllegalStateException("Scanner is not initialized")
                val args = requireArgs(call)

                val imagePath = args["imagePath"]?.toString()?.trim().orEmpty()
                if (imagePath.isEmpty()) {
                    throw IllegalArgumentException("imagePath is required")
                }

                val threshold = (args["threshold"] as? Number)?.toFloat() ?: 0.7f
                val scanId = "image_${System.currentTimeMillis()}"
                val isCancelled = buildCancelChecker(scanId)
                val payload = currentScanner.scanImage(imagePath = imagePath, threshold = threshold)
                if (isCancelled()) {
                    throw CancellationException("Scan cancelled")
                }
                dispatchSuccess(result, payload)
            } catch (error: CancellationException) {
                dispatchError(result, "SCAN_CANCELLED", error.message ?: "Scan cancelled", error)
            } catch (error: Exception) {
                dispatchError(result, "SCAN_FAILED", error.message ?: "Failed to scan image", error)
            }
        }
    }

    private fun scanBatch(call: MethodCall, result: Result) {
        backgroundExecutor.execute {
            try {
                val currentScanner = scanner ?: throw IllegalStateException("Scanner is not initialized")
                val args = requireArgs(call)
                val scanId = args["scanId"]?.toString()?.trim().orEmpty()
                if (scanId.isEmpty()) {
                    throw IllegalArgumentException("scanId is required")
                }
                val isCancelled = buildCancelChecker(scanId)
                cancelledScanIds.remove(scanId)

                val imagePaths = (args["imagePaths"] as? List<*>)
                    ?.mapNotNull { it?.toString() }
                    ?.filter { it.isNotBlank() }
                    .orEmpty()

                if (imagePaths.isEmpty()) {
                    dispatchSuccess(result, emptyList<Map<String, Any>>())
                    return@execute
                }

                val threshold = (args["threshold"] as? Number)?.toFloat() ?: 0.7f
                val maxConcurrency = (args["maxConcurrency"] as? Number)?.toInt() ?: 2

                val payload = currentScanner.scanBatch(
                    scanId = scanId,
                    imagePaths = imagePaths,
                    threshold = threshold,
                    maxConcurrency = maxConcurrency,
                    onProgress = ::emitProgress,
                    isCancelled = isCancelled,
                )
                dispatchSuccess(result, payload)
            } catch (error: CancellationException) {
                dispatchError(result, "SCAN_CANCELLED", error.message ?: "Scan cancelled", error)
            } catch (error: Exception) {
                dispatchError(result, "BATCH_SCAN_FAILED", error.message ?: "Failed to scan batch", error)
            } finally {
                val args = call.arguments as? Map<*, *>
                val scanId = args?.get("scanId")?.toString()?.trim()
                if (!scanId.isNullOrEmpty()) {
                    cancelledScanIds.remove(scanId)
                }
            }
        }
    }

    private fun scanVideo(call: MethodCall, result: Result) {
        backgroundExecutor.execute {
            try {
                val currentScanner = scanner ?: throw IllegalStateException("Scanner is not initialized")
                val args = requireArgs(call)

                val scanId = args["scanId"]?.toString()?.trim().orEmpty()
                    .ifBlank { "video_${System.currentTimeMillis()}" }
                val isCancelled = buildCancelChecker(scanId)
                cancelledScanIds.remove(scanId)
                val videoPath = args["videoPath"]?.toString()?.trim().orEmpty()
                if (videoPath.isEmpty()) {
                    throw IllegalArgumentException("videoPath is required")
                }

                val threshold = (args["threshold"] as? Number)?.toFloat() ?: 0.7f
                val sampleRateFps = (args["sampleRateFps"] as? Number)?.toFloat() ?: 0.3f
                val maxFrames = (args["maxFrames"] as? Number)?.toInt() ?: 300
                val dynamicSampleRate = (args["dynamicSampleRate"] as? Boolean) ?: true
                val shortVideoMinSampleRateFps =
                    (args["shortVideoMinSampleRateFps"] as? Number)?.toFloat() ?: 0.5f
                val shortVideoMaxSampleRateFps =
                    (args["shortVideoMaxSampleRateFps"] as? Number)?.toFloat() ?: 0.8f
                val mediumVideoMinutesThreshold =
                    (args["mediumVideoMinutesThreshold"] as? Number)?.toInt() ?: 10
                val longVideoMinutesThreshold =
                    (args["longVideoMinutesThreshold"] as? Number)?.toInt() ?: 15
                val mediumVideoSampleRateFps =
                    (args["mediumVideoSampleRateFps"] as? Number)?.toFloat() ?: 0.3f
                val longVideoSampleRateFps =
                    (args["longVideoSampleRateFps"] as? Number)?.toFloat() ?: 0.2f
                val videoEarlyStopEnabled = (args["videoEarlyStopEnabled"] as? Boolean) ?: true
                val videoEarlyStopBaseNsfwFrames =
                    (args["videoEarlyStopBaseNsfwFrames"] as? Number)?.toInt() ?: 3
                val videoEarlyStopMediumBonusFrames =
                    (args["videoEarlyStopMediumBonusFrames"] as? Number)?.toInt() ?: 1
                val videoEarlyStopLongBonusFrames =
                    (args["videoEarlyStopLongBonusFrames"] as? Number)?.toInt() ?: 2
                val videoEarlyStopVeryLongMinutesThreshold =
                    (args["videoEarlyStopVeryLongMinutesThreshold"] as? Number)?.toInt() ?: 30
                val videoEarlyStopVeryLongBonusFrames =
                    (args["videoEarlyStopVeryLongBonusFrames"] as? Number)?.toInt() ?: 3

                val payload = currentScanner.scanVideo(
                    scanId = scanId,
                    videoPath = videoPath,
                    threshold = threshold,
                    sampleRateFps = sampleRateFps,
                    maxFrames = maxFrames,
                    dynamicSampleRate = dynamicSampleRate,
                    shortVideoMinSampleRateFps = shortVideoMinSampleRateFps,
                    shortVideoMaxSampleRateFps = shortVideoMaxSampleRateFps,
                    mediumVideoMinutesThreshold = mediumVideoMinutesThreshold,
                    longVideoMinutesThreshold = longVideoMinutesThreshold,
                    mediumVideoSampleRateFps = mediumVideoSampleRateFps,
                    longVideoSampleRateFps = longVideoSampleRateFps,
                    videoEarlyStopEnabled = videoEarlyStopEnabled,
                    videoEarlyStopBaseNsfwFrames = videoEarlyStopBaseNsfwFrames,
                    videoEarlyStopMediumBonusFrames = videoEarlyStopMediumBonusFrames,
                    videoEarlyStopLongBonusFrames = videoEarlyStopLongBonusFrames,
                    videoEarlyStopVeryLongMinutesThreshold = videoEarlyStopVeryLongMinutesThreshold,
                    videoEarlyStopVeryLongBonusFrames = videoEarlyStopVeryLongBonusFrames,
                    onProgress = ::emitProgress,
                    isCancelled = isCancelled,
                )
                dispatchSuccess(result, payload)
            } catch (error: CancellationException) {
                dispatchError(result, "SCAN_CANCELLED", error.message ?: "Scan cancelled", error)
            } catch (error: Exception) {
                dispatchError(result, "VIDEO_SCAN_FAILED", error.message ?: "Failed to scan video", error)
            } finally {
                val args = call.arguments as? Map<*, *>
                val scanId = args?.get("scanId")?.toString()?.trim()
                if (!scanId.isNullOrEmpty()) {
                    cancelledScanIds.remove(scanId)
                }
            }
        }
    }

    private fun disposeScanner(result: Result) {
        backgroundExecutor.execute {
            scanner?.close()
            scanner = null
            dispatchSuccess(result, null)
        }
    }

    private fun scanMediaBatch(call: MethodCall, result: Result) {
        backgroundExecutor.execute {
            try {
                val currentScanner = scanner ?: throw IllegalStateException("Scanner is not initialized")
                val args = requireArgs(call)
                val scanId = args["scanId"]?.toString()?.trim().orEmpty()
                if (scanId.isEmpty()) {
                    throw IllegalArgumentException("scanId is required")
                }
                val isCancelled = buildCancelChecker(scanId)
                cancelledScanIds.remove(scanId)

                val mediaItems = (args["mediaItems"] as? List<*>)
                    ?.mapNotNull { raw ->
                        val map = raw as? Map<*, *> ?: return@mapNotNull null
                        val path = map["path"]?.toString()?.trim().orEmpty()
                        val type = map["type"]?.toString()?.trim()?.lowercase(Locale.US).orEmpty()
                        if (path.isEmpty() || (type != "image" && type != "video")) {
                            return@mapNotNull null
                        }
                        NativeMediaItem(path = path, type = type)
                    }
                    .orEmpty()
                if (mediaItems.isEmpty()) {
                    dispatchSuccess(
                        result,
                        linkedMapOf(
                            "items" to emptyList<Map<String, Any?>>(),
                            "processed" to 0,
                            "successCount" to 0,
                            "errorCount" to 0,
                            "flaggedCount" to 0,
                        ),
                    )
                    return@execute
                }

                val settings = (args["settings"] as? Map<*, *>)
                    ?.entries
                    ?.associate { "${it.key}" to it.value }
                    .orEmpty()

                val payload = currentScanner.scanMediaBatch(
                    scanId = scanId,
                    mediaItems = mediaItems,
                    settings = settings,
                    onProgress = ::emitProgress,
                    isCancelled = isCancelled,
                )
                dispatchSuccess(result, payload)
            } catch (error: CancellationException) {
                dispatchError(result, "SCAN_CANCELLED", error.message ?: "Scan cancelled", error)
            } catch (error: Exception) {
                dispatchError(result, "MEDIA_BATCH_SCAN_FAILED", error.message ?: "Failed to scan media batch", error)
            } finally {
                val args = call.arguments as? Map<*, *>
                val scanId = args?.get("scanId")?.toString()?.trim()
                if (!scanId.isNullOrEmpty()) {
                    cancelledScanIds.remove(scanId)
                }
            }
        }
    }

    private fun scanGallery(call: MethodCall, result: Result) {
        backgroundExecutor.execute {
            try {
                val currentScanner = scanner ?: throw IllegalStateException("Scanner is not initialized")
                val args = requireArgs(call)
                val scanId = args["scanId"]?.toString()?.trim().orEmpty()
                if (scanId.isEmpty()) {
                    throw IllegalArgumentException("scanId is required")
                }
                val isCancelled = buildCancelChecker(scanId)
                cancelledScanIds.remove(scanId)

                val settings = (args["settings"] as? Map<*, *>)
                    ?.entries
                    ?.associate { "${it.key}" to it.value }
                    .orEmpty()

                val payload = currentScanner.scanGallery(
                    scanId = scanId,
                    settings = settings,
                    onEvent = ::emitProgress,
                    isCancelled = isCancelled,
                )
                dispatchSuccess(result, payload)
            } catch (error: CancellationException) {
                dispatchError(result, "SCAN_CANCELLED", error.message ?: "Scan cancelled", error)
            } catch (error: Exception) {
                dispatchError(result, "GALLERY_SCAN_FAILED", error.message ?: "Failed to scan gallery", error)
            } finally {
                val args = call.arguments as? Map<*, *>
                val scanId = args?.get("scanId")?.toString()?.trim()
                if (!scanId.isNullOrEmpty()) {
                    cancelledScanIds.remove(scanId)
                }
            }
        }
    }

    private fun loadImageThumbnail(call: MethodCall, result: Result) {
        backgroundExecutor.execute {
            try {
                val currentScanner = scanner ?: throw IllegalStateException("Scanner is not initialized")
                val args = requireArgs(call)
                val assetRef = args["assetRef"]?.toString()?.trim().orEmpty()
                if (assetRef.isEmpty()) {
                    throw IllegalArgumentException("assetRef is required")
                }
                val width = (args["width"] as? Number)?.toInt()?.coerceIn(64, 1024) ?: 160
                val height = (args["height"] as? Number)?.toInt()?.coerceIn(64, 1024) ?: 160
                val quality = (args["quality"] as? Number)?.toInt()?.coerceIn(30, 95) ?: 70
                val payload = currentScanner.loadImageThumbnail(
                    assetRef = assetRef,
                    targetWidth = width,
                    targetHeight = height,
                    quality = quality,
                )
                dispatchSuccess(result, payload)
            } catch (error: Exception) {
                dispatchError(result, "LOAD_IMAGE_THUMBNAIL_FAILED", error.message ?: "Failed to load thumbnail", error)
            }
        }
    }

    private fun loadImageAsset(call: MethodCall, result: Result) {
        backgroundExecutor.execute {
            try {
                val currentScanner = scanner ?: throw IllegalStateException("Scanner is not initialized")
                val args = requireArgs(call)
                val assetRef = args["assetRef"]?.toString()?.trim().orEmpty()
                if (assetRef.isEmpty()) {
                    throw IllegalArgumentException("assetRef is required")
                }
                val payload = currentScanner.loadImageAsset(assetRef = assetRef)
                dispatchSuccess(result, payload)
            } catch (error: Exception) {
                dispatchError(result, "LOAD_IMAGE_ASSET_FAILED", error.message ?: "Failed to load asset", error)
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        scanner?.close()
        scanner = null
        channel.setMethodCallHandler(null)
        progressChannel.setStreamHandler(null)
        backgroundExecutor.shutdown()
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        synchronized(sinkLock) {
            progressSink = events
        }
    }

    override fun onCancel(arguments: Any?) {
        synchronized(sinkLock) {
            progressSink = null
        }
    }

    private fun dispatchSuccess(result: Result, payload: Any?) {
        mainHandler.post {
            result.success(payload)
        }
    }

    private fun dispatchError(result: Result, code: String, message: String, error: Throwable?) {
        mainHandler.post {
            result.error(code, message, error?.stackTraceToString())
        }
    }

    private fun dispatchNotImplemented(result: Result) {
        mainHandler.post {
            result.notImplemented()
        }
    }

    private fun emitProgress(payload: Map<String, Any?>) {
        mainHandler.post {
            synchronized(sinkLock) {
                progressSink?.success(payload)
            }
        }
    }

    @Suppress("UNCHECKED_CAST")
    private fun requireArgs(call: MethodCall): Map<String, Any?> {
        val map = call.arguments as? Map<*, *> ?: throw IllegalArgumentException("Expected map arguments")
        return map.entries.associate { "${it.key}" to it.value }
    }

    private fun buildCancelChecker(scanId: String): () -> Boolean {
        val generationSnapshot = cancelGeneration.get()
        return {
            cancelGeneration.get() != generationSnapshot || cancelledScanIds.contains(scanId)
        }
    }
}

private data class NativeMediaItem(
    val path: String,
    val type: String,
)

private data class NativeGalleryMediaItem(
    val assetId: String,
    val uri: Uri,
    val type: String,
    val path: String?,
)

private enum class InputNormalizationMode {
    ZERO_TO_ONE,
    MINUS_ONE_TO_ONE,
    ;

    companion object {
        fun fromWireValue(value: String?): InputNormalizationMode {
            return when (value?.lowercase(Locale.US)) {
                "zero_to_one" -> ZERO_TO_ONE
                "minus_one_to_one" -> MINUS_ONE_TO_ONE
                else -> MINUS_ONE_TO_ONE
            }
        }
    }
}

private class AndroidNsfwScanner(
    context: Context,
    flutterAssets: FlutterAssets,
    modelAssetPath: String,
    labelsAssetPath: String?,
    defaultNumThreads: Int,
    inputNormalization: InputNormalizationMode,
) {
    private val appContext = context
    private val assetManager = context.assets
    private val defaultThreadCount = defaultNumThreads.coerceIn(1, 8)
    private val inputNormalizationMode = inputNormalization

    private val modelBuffer: ByteBuffer
    private val labels: List<String>

    private val inputShape: List<Int>
    private val outputShape: List<Int>
    private val inputType: DataType
    private val outputType: DataType

    private val inputScale: Float
    private val inputZeroPoint: Int
    private val outputScale: Float
    private val outputZeroPoint: Int

    private val inputWidth: Int
    private val inputHeight: Int
    private val inputChannels: Int
    private val outputElementCount: Int

    private data class DecodedFrame(
        val index: Int,
        val timestampUs: Long,
        val bitmap: Bitmap?,
        val error: String?,
        val isEnd: Boolean = false,
    ) {
        companion object {
            fun end(): DecodedFrame = DecodedFrame(-1, -1L, null, null, isEnd = true)
        }
    }

    private data class PreprocessedFrame(
        val index: Int,
        val timestampUs: Long,
        val input: ByteBuffer?,
        val error: String?,
        val isEnd: Boolean = false,
    ) {
        companion object {
            fun end(): PreprocessedFrame = PreprocessedFrame(-1, -1L, null, null, isEnd = true)
        }
    }

    private data class PreprocessWorkspace(
        val pixelBuffer: IntArray,
        val inputBuffer: ByteBuffer,
    )

    private data class InferenceWorkspace(
        val preprocess: PreprocessWorkspace,
        val floatOutputBuffer: ByteBuffer?,
        val quantizedOutputBuffer: ByteArray?,
        val scoresBuffer: FloatArray,
    )

    private data class WorkerContext(
        val interpreter: Interpreter,
        val workspace: InferenceWorkspace,
    )

    init {
        modelBuffer = loadAssetAsDirectBuffer(flutterAssets.getAssetFilePathByName(modelAssetPath))
        labels = labelsAssetPath?.let { loadLabels(flutterAssets.getAssetFilePathByName(it)) } ?: emptyList()

        val probeInterpreter = createInterpreter(defaultThreadCount)
        try {
            val inputTensor = probeInterpreter.getInputTensor(0)
            val outputTensor = probeInterpreter.getOutputTensor(0)

            inputShape = inputTensor.shape().toList()
            outputShape = outputTensor.shape().toList()
            inputType = inputTensor.dataType()
            outputType = outputTensor.dataType()

            val inputQuant = inputTensor.quantizationParams()
            inputScale = inputQuant.scale
            inputZeroPoint = inputQuant.zeroPoint

            val outputQuant = outputTensor.quantizationParams()
            outputScale = outputQuant.scale
            outputZeroPoint = outputQuant.zeroPoint

            if (inputShape.size < 4) {
                throw IllegalStateException("Expected input tensor shape [1, H, W, C], got: $inputShape")
            }

            inputHeight = inputShape[1]
            inputWidth = inputShape[2]
            inputChannels = inputShape[3]

            if (inputChannels < 3) {
                throw IllegalStateException("Expected at least 3 input channels, got: $inputChannels")
            }

            outputElementCount = outputShape.fold(1) { acc, dim -> acc * max(dim, 1) }
        } finally {
            probeInterpreter.close()
        }
    }

    fun scanImage(imagePath: String, threshold: Float): Map<String, Any> {
        val interpreter = createInterpreter(defaultThreadCount)
        val workspace = createInferenceWorkspace()
        return try {
            runSingleScan(
                interpreter = interpreter,
                imagePath = imagePath,
                threshold = threshold,
                workspace = workspace,
            )
        } finally {
            interpreter.close()
        }
    }

    fun scanVideo(
        scanId: String,
        videoPath: String,
        threshold: Float,
        sampleRateFps: Float,
        maxFrames: Int,
        dynamicSampleRate: Boolean,
        shortVideoMinSampleRateFps: Float,
        shortVideoMaxSampleRateFps: Float,
        mediumVideoMinutesThreshold: Int,
        longVideoMinutesThreshold: Int,
        mediumVideoSampleRateFps: Float,
        longVideoSampleRateFps: Float,
        videoEarlyStopEnabled: Boolean,
        videoEarlyStopBaseNsfwFrames: Int,
        videoEarlyStopMediumBonusFrames: Int,
        videoEarlyStopLongBonusFrames: Int,
        videoEarlyStopVeryLongMinutesThreshold: Int,
        videoEarlyStopVeryLongBonusFrames: Int,
        onProgress: (Map<String, Any?>) -> Unit,
        isCancelled: () -> Boolean,
    ): Map<String, Any> {
        val interpreter = createInterpreter(defaultThreadCount)
        val retriever = MediaMetadataRetriever()

        return try {
            if (isCancelled()) {
                throw CancellationException("Scan cancelled")
            }
            retriever.setDataSource(videoPath)
            val durationMs = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                ?.toLongOrNull()
                ?: 0L
            if (durationMs <= 0L) {
                throw IllegalArgumentException("Failed to read video duration: $videoPath")
            }

            val effectiveSampleRate = if (dynamicSampleRate) {
                computeDynamicSampleRateFps(
                    durationMs = durationMs,
                    shortVideoMinSampleRateFps = shortVideoMinSampleRateFps,
                    shortVideoMaxSampleRateFps = shortVideoMaxSampleRateFps,
                    mediumVideoMinutesThreshold = mediumVideoMinutesThreshold,
                    longVideoMinutesThreshold = longVideoMinutesThreshold,
                    mediumVideoSampleRateFps = mediumVideoSampleRateFps,
                    longVideoSampleRateFps = longVideoSampleRateFps,
                )
            } else {
                sampleRateFps.coerceIn(0.2f, 30f)
            }
            val timestampsUs = buildFrameTimestamps(
                durationMs = durationMs,
                sampleRateFps = effectiveSampleRate,
                maxFrames = maxFrames,
            )
            val totalFrames = timestampsUs.size.coerceAtLeast(1)
            var processedFrames = 0
            onProgress(
                buildProgressPayload(
                    scanId = scanId,
                    processed = 0,
                    total = totalFrames,
                    imagePath = videoPath,
                    error = null,
                    status = "started",
                ),
            )

            val frameResults = ArrayList<Map<String, Any>>(totalFrames)
            var flaggedFrames = 0
            var maxNsfwScore = 0.0
            val requiredNsfwFrames = resolveRequiredNsfwFrames(
                durationMs = durationMs,
                totalFrames = totalFrames,
                enabled = videoEarlyStopEnabled,
                baseFrames = videoEarlyStopBaseNsfwFrames,
                mediumBonus = videoEarlyStopMediumBonusFrames,
                longBonus = videoEarlyStopLongBonusFrames,
                mediumThresholdMinutes = mediumVideoMinutesThreshold,
                longThresholdMinutes = longVideoMinutesThreshold,
                veryLongThresholdMinutes = videoEarlyStopVeryLongMinutesThreshold,
                veryLongBonus = videoEarlyStopVeryLongBonusFrames,
            )
            val decodeQueue = LinkedBlockingQueue<DecodedFrame>(3)
            val preprocessQueue = LinkedBlockingQueue<PreprocessedFrame>(3)
            val frameWorkspace = createInferenceWorkspace()
            val stopSignal = java.util.concurrent.atomic.AtomicBoolean(false)
            val decodeThread = Thread {
                try {
                    for ((index, timestampUs) in timestampsUs.withIndex()) {
                        if (stopSignal.get() || isCancelled()) {
                            break
                        }
                        val bitmap = decodeVideoFrame(
                            retriever = retriever,
                            timestampUs = timestampUs,
                            targetWidth = inputWidth,
                            targetHeight = inputHeight,
                        )
                        decodeQueue.put(
                            DecodedFrame(
                                index = index,
                                timestampUs = timestampUs,
                                bitmap = bitmap,
                                error = if (bitmap == null) "Failed to decode frame" else null,
                            ),
                        )
                    }
                } finally {
                    decodeQueue.put(DecodedFrame.end())
                }
            }
            val preprocessThread = Thread {
                try {
                    while (true) {
                        val decoded = decodeQueue.take()
                        if (decoded.isEnd) {
                            break
                        }
                        if (decoded.error != null || decoded.bitmap == null) {
                            preprocessQueue.put(
                                PreprocessedFrame(
                                    index = decoded.index,
                                    timestampUs = decoded.timestampUs,
                                    input = null,
                                    error = decoded.error ?: "Failed to decode frame",
                                ),
                            )
                            continue
                        }

                        val inputBuffer = try {
                            preprocessBitmap(decoded.bitmap, frameWorkspace.preprocess)
                        } catch (error: Exception) {
                            null
                        } finally {
                            decoded.bitmap.recycle()
                        }
                        preprocessQueue.put(
                            PreprocessedFrame(
                                index = decoded.index,
                                timestampUs = decoded.timestampUs,
                                input = inputBuffer,
                                error = if (inputBuffer == null) "Failed to preprocess frame" else null,
                            ),
                        )
                    }
                } finally {
                    preprocessQueue.put(PreprocessedFrame.end())
                }
            }
            decodeThread.start()
            preprocessThread.start()

            while (true) {
                val preprocessed = preprocessQueue.take()
                if (preprocessed.isEnd) {
                    break
                }
                if (isCancelled()) {
                    stopSignal.set(true)
                    continue
                }
                val frameResult = if (preprocessed.error != null || preprocessed.input == null) {
                    linkedMapOf(
                        "timestampMs" to (preprocessed.timestampUs.toDouble() / 1000.0),
                        "nsfwScore" to 0.0,
                        "safeScore" to 0.0,
                        "isNsfw" to false,
                        "topLabel" to "",
                        "topScore" to 0.0,
                        "scores" to emptyMap<String, Double>(),
                        "error" to (preprocessed.error ?: "Failed to preprocess frame"),
                    )
                } else {
                    val rawResult = runSingleInference(
                        interpreter = interpreter,
                        input = preprocessed.input,
                        frameIdentity = "$videoPath#${preprocessed.timestampUs / 1000L}ms",
                        threshold = threshold,
                        workspace = frameWorkspace,
                    )
                    linkedMapOf(
                        "timestampMs" to (preprocessed.timestampUs.toDouble() / 1000.0),
                        "nsfwScore" to ((rawResult["nsfwScore"] as? Double) ?: 0.0),
                        "safeScore" to ((rawResult["safeScore"] as? Double) ?: 0.0),
                        "isNsfw" to (rawResult["isNsfw"] == true),
                        "topLabel" to ((rawResult["topLabel"] as? String) ?: ""),
                        "topScore" to ((rawResult["topScore"] as? Double) ?: 0.0),
                        "scores" to ((rawResult["scores"] as? Map<String, Double>) ?: emptyMap<String, Double>()),
                        "error" to ((rawResult["error"] as? String)),
                    )
                }

                val isNsfw = frameResult["isNsfw"] == true
                if (isNsfw) {
                    flaggedFrames += 1
                }
                val nsfwScore = (frameResult["nsfwScore"] as? Double) ?: 0.0
                if (nsfwScore > maxNsfwScore) {
                    maxNsfwScore = nsfwScore
                }
                frameResults.add(frameResult)
                processedFrames += 1

                onProgress(
                    buildProgressPayload(
                        scanId = scanId,
                        processed = processedFrames,
                        total = totalFrames,
                        imagePath = videoPath,
                        error = frameResult["error"] as? String,
                        status = "running",
                    ),
                )

                val remaining = totalFrames - processedFrames
                if (videoEarlyStopEnabled && flaggedFrames >= requiredNsfwFrames) {
                    stopSignal.set(true)
                    break
                }
                if (videoEarlyStopEnabled && (flaggedFrames + remaining) < requiredNsfwFrames) {
                    stopSignal.set(true)
                    break
                }
            }

            stopSignal.set(true)
            decodeThread.join()
            preprocessThread.join()
            if (isCancelled()) {
                throw CancellationException("Scan cancelled")
            }

            val sampledFrames = frameResults.size
            val flaggedRatio = if (sampledFrames == 0) 0.0 else flaggedFrames.toDouble() / sampledFrames.toDouble()

            onProgress(
                buildProgressPayload(
                    scanId = scanId,
                    processed = totalFrames,
                    total = totalFrames,
                    imagePath = videoPath,
                    error = null,
                    status = "completed",
                ),
            )

            linkedMapOf(
                "videoPath" to videoPath,
                "sampleRateFps" to effectiveSampleRate.toDouble(),
                "sampledFrames" to sampledFrames,
                "flaggedFrames" to flaggedFrames,
                "flaggedRatio" to flaggedRatio,
                "maxNsfwScore" to maxNsfwScore,
                "isNsfw" to (flaggedFrames >= requiredNsfwFrames && maxNsfwScore >= threshold),
                "requiredNsfwFrames" to requiredNsfwFrames,
                "frames" to frameResults,
            )
        } finally {
            retriever.release()
            interpreter.close()
        }
    }

    private fun computeDynamicSampleRateFps(
        durationMs: Long,
        shortVideoMinSampleRateFps: Float,
        shortVideoMaxSampleRateFps: Float,
        mediumVideoMinutesThreshold: Int,
        longVideoMinutesThreshold: Int,
        mediumVideoSampleRateFps: Float,
        longVideoSampleRateFps: Float,
    ): Float {
        val mediumThreshold = mediumVideoMinutesThreshold.coerceAtLeast(1)
        val longThreshold = longVideoMinutesThreshold.coerceAtLeast(mediumThreshold + 1)
        val durationMinutes = durationMs.toDouble() / 60_000.0

        val minShort = shortVideoMinSampleRateFps.coerceIn(0.2f, 30f)
        val maxShort = shortVideoMaxSampleRateFps.coerceIn(0.2f, 30f)
        val shortLow = minOf(minShort, maxShort)
        val shortHigh = maxOf(minShort, maxShort)

        val mediumRate = mediumVideoSampleRateFps.coerceIn(0.2f, 30f)
        val longRate = longVideoSampleRateFps.coerceIn(0.2f, 30f)

        val dynamicRate = when {
            durationMinutes >= longThreshold.toDouble() -> longRate
            durationMinutes >= mediumThreshold.toDouble() -> mediumRate
            else -> {
                val progress = (durationMinutes / mediumThreshold.toDouble()).coerceIn(0.0, 1.0)
                (shortHigh - ((shortHigh - shortLow) * progress)).toFloat()
            }
        }
        return dynamicRate.coerceIn(0.2f, 30f)
    }

    fun scanBatch(
        scanId: String,
        imagePaths: List<String>,
        threshold: Float,
        maxConcurrency: Int,
        onProgress: (Map<String, Any?>) -> Unit,
        isCancelled: () -> Boolean,
    ): List<Map<String, Any>> {
        if (imagePaths.isEmpty()) {
            return emptyList()
        }
        if (isCancelled()) {
            throw CancellationException("Scan cancelled")
        }

        val workerCount = maxConcurrency.coerceIn(1, minOf(8, imagePaths.size))
        val workerPool = Executors.newFixedThreadPool(workerCount)
        val workerContexts = LinkedBlockingQueue<WorkerContext>()
        val totalCount = imagePaths.size
        val processedCount = AtomicInteger(0)

        onProgress(
            buildProgressPayload(
                scanId = scanId,
                processed = 0,
                total = totalCount,
                imagePath = null,
                error = null,
                status = "started",
            ),
        )

        repeat(workerCount) {
            workerContexts.put(
                WorkerContext(
                    interpreter = createInterpreter(defaultThreadCount),
                    workspace = createInferenceWorkspace(),
                ),
            )
        }

        return try {
            val futures = imagePaths.mapIndexed { index, imagePath ->
                workerPool.submit(Callable {
                    if (isCancelled()) {
                        throw CancellationException("Scan cancelled")
                    }
                    val workerContext = workerContexts.take()
                    try {
                        val payload = runSingleScan(
                            interpreter = workerContext.interpreter,
                            imagePath = imagePath,
                            threshold = threshold,
                            workspace = workerContext.workspace,
                        )
                        val processed = processedCount.incrementAndGet()
                        onProgress(
                            buildProgressPayload(
                                scanId = scanId,
                                processed = processed,
                                total = totalCount,
                                imagePath = imagePath,
                                error = null,
                                status = "running",
                            ),
                        )
                        index to payload
                    } catch (error: Exception) {
                        if (error is CancellationException) {
                            throw error
                        }
                        val processed = processedCount.incrementAndGet()
                        onProgress(
                            buildProgressPayload(
                                scanId = scanId,
                                processed = processed,
                                total = totalCount,
                                imagePath = imagePath,
                                error = error.message ?: "Unknown error",
                                status = "running",
                            ),
                        )
                        index to buildErrorResult(imagePath, error)
                    } finally {
                        workerContexts.put(workerContext)
                    }
                })
            }

            val orderedResults = MutableList<Map<String, Any>>(imagePaths.size) { emptyMap() }
            futures.forEach { future ->
                val (index, payload) = future.get()
                orderedResults[index] = payload
            }
            if (isCancelled()) {
                throw CancellationException("Scan cancelled")
            }
            onProgress(
                buildProgressPayload(
                    scanId = scanId,
                    processed = totalCount,
                    total = totalCount,
                    imagePath = null,
                    error = null,
                    status = "completed",
                ),
            )
            orderedResults
        } finally {
            workerPool.shutdown()
            while (true) {
                val context = workerContexts.poll() ?: break
                context.interpreter.close()
            }
        }
    }

    fun scanMediaBatch(
        scanId: String,
        mediaItems: List<NativeMediaItem>,
        settings: Map<String, Any?>,
        onProgress: (Map<String, Any?>) -> Unit,
        isCancelled: () -> Boolean,
    ): Map<String, Any> {
        if (mediaItems.isEmpty()) {
            return linkedMapOf(
                "items" to emptyList<Map<String, Any?>>(),
                "processed" to 0,
                "successCount" to 0,
                "errorCount" to 0,
                "flaggedCount" to 0,
            )
        }

        val imageThreshold = (settings["imageThreshold"] as? Number)?.toFloat() ?: 0.7f
        val videoThreshold = (settings["videoThreshold"] as? Number)?.toFloat() ?: 0.7f
        val videoSampleRateFps = (settings["videoSampleRateFps"] as? Number)?.toFloat() ?: 0.3f
        val videoMaxFrames = (settings["videoMaxFrames"] as? Number)?.toInt() ?: 300
        val dynamicVideoSampleRate = (settings["dynamicVideoSampleRate"] as? Boolean) ?: true
        val shortVideoMinSampleRateFps = (settings["shortVideoMinSampleRateFps"] as? Number)?.toFloat() ?: 0.5f
        val shortVideoMaxSampleRateFps = (settings["shortVideoMaxSampleRateFps"] as? Number)?.toFloat() ?: 0.8f
        val mediumVideoMinutesThreshold = (settings["mediumVideoMinutesThreshold"] as? Number)?.toInt() ?: 10
        val longVideoMinutesThreshold = (settings["longVideoMinutesThreshold"] as? Number)?.toInt() ?: 15
        val mediumVideoSampleRateFps = (settings["mediumVideoSampleRateFps"] as? Number)?.toFloat() ?: 0.3f
        val longVideoSampleRateFps = (settings["longVideoSampleRateFps"] as? Number)?.toFloat() ?: 0.2f
        val videoEarlyStopEnabled = (settings["videoEarlyStopEnabled"] as? Boolean) ?: true
        val videoEarlyStopBaseNsfwFrames = (settings["videoEarlyStopBaseNsfwFrames"] as? Number)?.toInt() ?: 3
        val videoEarlyStopMediumBonusFrames = (settings["videoEarlyStopMediumBonusFrames"] as? Number)?.toInt() ?: 1
        val videoEarlyStopLongBonusFrames = (settings["videoEarlyStopLongBonusFrames"] as? Number)?.toInt() ?: 2
        val videoEarlyStopVeryLongMinutesThreshold =
            (settings["videoEarlyStopVeryLongMinutesThreshold"] as? Number)?.toInt() ?: 30
        val videoEarlyStopVeryLongBonusFrames = (settings["videoEarlyStopVeryLongBonusFrames"] as? Number)?.toInt() ?: 3
        val maxConcurrency = ((settings["maxConcurrency"] as? Number)?.toInt() ?: 2).coerceIn(1, minOf(8, mediaItems.size))
        val continueOnError = (settings["continueOnError"] as? Boolean) ?: true

        val workerPool = Executors.newFixedThreadPool(maxConcurrency)
        val imageWorkerContexts = LinkedBlockingQueue<WorkerContext>()
        val processedCount = AtomicInteger(0)
        val orderedResults = MutableList<Map<String, Any?>>(mediaItems.size) { emptyMap() }

        repeat(maxConcurrency) {
            imageWorkerContexts.put(
                WorkerContext(
                    interpreter = createInterpreter(defaultThreadCount),
                    workspace = createInferenceWorkspace(),
                ),
            )
        }

        onProgress(
            buildProgressPayload(
                scanId = scanId,
                processed = 0,
                total = mediaItems.size,
                imagePath = null,
                error = null,
                status = "started",
                mediaType = null,
            ),
        )

        return try {
            val futures = mediaItems.mapIndexed { index, item ->
                workerPool.submit(Callable {
                    if (isCancelled()) {
                        throw CancellationException("Scan cancelled")
                    }
                    val itemPayload = try {
                        if (item.type == "video") {
                            val videoResult = scanVideo(
                                scanId = "${scanId}_item_$index",
                                videoPath = item.path,
                                threshold = videoThreshold,
                                sampleRateFps = videoSampleRateFps,
                                maxFrames = videoMaxFrames,
                                dynamicSampleRate = dynamicVideoSampleRate,
                                shortVideoMinSampleRateFps = shortVideoMinSampleRateFps,
                                shortVideoMaxSampleRateFps = shortVideoMaxSampleRateFps,
                                mediumVideoMinutesThreshold = mediumVideoMinutesThreshold,
                                longVideoMinutesThreshold = longVideoMinutesThreshold,
                                mediumVideoSampleRateFps = mediumVideoSampleRateFps,
                                longVideoSampleRateFps = longVideoSampleRateFps,
                                videoEarlyStopEnabled = videoEarlyStopEnabled,
                                videoEarlyStopBaseNsfwFrames = videoEarlyStopBaseNsfwFrames,
                                videoEarlyStopMediumBonusFrames = videoEarlyStopMediumBonusFrames,
                                videoEarlyStopLongBonusFrames = videoEarlyStopLongBonusFrames,
                                videoEarlyStopVeryLongMinutesThreshold = videoEarlyStopVeryLongMinutesThreshold,
                                videoEarlyStopVeryLongBonusFrames = videoEarlyStopVeryLongBonusFrames,
                                onProgress = {},
                                isCancelled = isCancelled,
                            )
                            linkedMapOf(
                                "path" to item.path,
                                "type" to item.type,
                                "imageResult" to null,
                                "videoResult" to videoResult,
                                "error" to null,
                            )
                        } else {
                            val workerContext = imageWorkerContexts.take()
                            try {
                                val imageResult = runSingleScan(
                                    interpreter = workerContext.interpreter,
                                    imagePath = item.path,
                                    threshold = imageThreshold,
                                    workspace = workerContext.workspace,
                                )
                                linkedMapOf(
                                    "path" to item.path,
                                    "type" to item.type,
                                    "imageResult" to imageResult,
                                    "videoResult" to null,
                                    "error" to null,
                                )
                            } finally {
                                imageWorkerContexts.put(workerContext)
                            }
                        }
                    } catch (error: Exception) {
                        if (error is CancellationException) {
                            throw error
                        }
                        if (!continueOnError) {
                            throw error
                        }
                        linkedMapOf(
                            "path" to item.path,
                            "type" to item.type,
                            "imageResult" to null,
                            "videoResult" to null,
                            "error" to (error.message ?: "Unknown error"),
                        )
                    }

                    val processed = processedCount.incrementAndGet()
                    onProgress(
                        buildProgressPayload(
                            scanId = scanId,
                            processed = processed,
                            total = mediaItems.size,
                            imagePath = item.path,
                            error = itemPayload["error"] as? String,
                            status = "running",
                            mediaType = item.type,
                        ),
                    )
                    index to itemPayload
                })
            }

            futures.forEach { future ->
                val (index, payload) = future.get()
                orderedResults[index] = payload
            }
            if (isCancelled()) {
                throw CancellationException("Scan cancelled")
            }

            val successCount = orderedResults.count { it["error"] == null }
            val errorCount = orderedResults.size - successCount
            val flaggedCount = orderedResults.count { item ->
                val type = item["type"] as? String
                if (type == "video") {
                    (item["videoResult"] as? Map<*, *>)?.get("isNsfw") == true
                } else {
                    (item["imageResult"] as? Map<*, *>)?.get("isNsfw") == true
                }
            }

            onProgress(
                buildProgressPayload(
                    scanId = scanId,
                    processed = mediaItems.size,
                    total = mediaItems.size,
                    imagePath = null,
                    error = null,
                    status = "completed",
                    mediaType = null,
                ),
            )

            linkedMapOf(
                "items" to orderedResults,
                "processed" to mediaItems.size,
                "successCount" to successCount,
                "errorCount" to errorCount,
                "flaggedCount" to flaggedCount,
            )
        } finally {
            workerPool.shutdown()
            while (true) {
                val context = imageWorkerContexts.poll() ?: break
                context.interpreter.close()
            }
        }
    }

    private data class GalleryBatchOutcome(
        val allItems: List<Map<String, Any?>>,
        val streamedItems: List<Map<String, Any?>>,
        val processed: Int,
        val successCount: Int,
        val errorCount: Int,
        val flaggedCount: Int,
    )

    private data class ResolvedVideoPath(
        val path: String,
        val tempFile: File?,
    )

    fun scanGallery(
        scanId: String,
        settings: Map<String, Any?>,
        onEvent: (Map<String, Any?>) -> Unit,
        isCancelled: () -> Boolean,
    ): Map<String, Any> = runBlocking {
        withContext(Dispatchers.IO) {
            val includeImages = (settings["includeImages"] as? Boolean) ?: true
            val includeVideos = (settings["includeVideos"] as? Boolean) ?: true
            if (!includeImages && !includeVideos) {
                return@withContext linkedMapOf(
                    "items" to emptyList<Map<String, Any?>>(),
                    "processed" to 0,
                    "successCount" to 0,
                    "errorCount" to 0,
                    "flaggedCount" to 0,
                )
            }

            val includeCleanResults = (settings["includeCleanResults"] as? Boolean) ?: false
            val debugLogging = (settings["debugLogging"] as? Boolean) ?: false
            val imageThreshold = (settings["imageThreshold"] as? Number)?.toFloat() ?: 0.7f
            val videoThreshold = (settings["videoThreshold"] as? Number)?.toFloat() ?: 0.7f
            val videoSampleRateFps = (settings["videoSampleRateFps"] as? Number)?.toFloat() ?: 0.3f
            val videoMaxFrames = (settings["videoMaxFrames"] as? Number)?.toInt() ?: 300
            val dynamicVideoSampleRate = (settings["dynamicVideoSampleRate"] as? Boolean) ?: true
            val shortVideoMinSampleRateFps =
                (settings["shortVideoMinSampleRateFps"] as? Number)?.toFloat() ?: 0.5f
            val shortVideoMaxSampleRateFps =
                (settings["shortVideoMaxSampleRateFps"] as? Number)?.toFloat() ?: 0.8f
            val mediumVideoMinutesThreshold =
                (settings["mediumVideoMinutesThreshold"] as? Number)?.toInt() ?: 10
            val longVideoMinutesThreshold =
                (settings["longVideoMinutesThreshold"] as? Number)?.toInt() ?: 15
            val mediumVideoSampleRateFps =
                (settings["mediumVideoSampleRateFps"] as? Number)?.toFloat() ?: 0.3f
            val longVideoSampleRateFps =
                (settings["longVideoSampleRateFps"] as? Number)?.toFloat() ?: 0.2f
            val videoEarlyStopEnabled = (settings["videoEarlyStopEnabled"] as? Boolean) ?: true
            val videoEarlyStopBaseNsfwFrames =
                (settings["videoEarlyStopBaseNsfwFrames"] as? Number)?.toInt() ?: 3
            val videoEarlyStopMediumBonusFrames =
                (settings["videoEarlyStopMediumBonusFrames"] as? Number)?.toInt() ?: 1
            val videoEarlyStopLongBonusFrames =
                (settings["videoEarlyStopLongBonusFrames"] as? Number)?.toInt() ?: 2
            val videoEarlyStopVeryLongMinutesThreshold =
                (settings["videoEarlyStopVeryLongMinutesThreshold"] as? Number)?.toInt() ?: 30
            val videoEarlyStopVeryLongBonusFrames =
                (settings["videoEarlyStopVeryLongBonusFrames"] as? Number)?.toInt() ?: 3
            val continueOnError = (settings["continueOnError"] as? Boolean) ?: true
            val scanBatchSize = ((settings["scanChunkSize"] as? Number)?.toInt() ?: 100).coerceIn(50, 200)
            val thumbnailSize = ((settings["thumbnailSize"] as? Number)?.toInt() ?: 224).coerceIn(128, 512)
            val loadProgressEvery = ((settings["loadProgressEvery"] as? Number)?.toInt() ?: 100).coerceIn(20, 500)
            val maxItems = (settings["maxItems"] as? Number)?.toInt()?.takeIf { it > 0 }

            val cpuWorkers = Runtime.getRuntime().availableProcessors().coerceAtLeast(1)
            val maxConcurrencySetting = (settings["maxConcurrency"] as? Number)?.toInt()
            val maxConcurrency = when {
                maxConcurrencySetting == null || maxConcurrencySetting <= 0 -> cpuWorkers
                else -> minOf(maxConcurrencySetting, cpuWorkers)
            }.coerceIn(1, 8)
            if (debugLogging) {
                Log.i(
                    "FlutterNsfwScaner",
                    "[gallery:$scanId] start includeImages=$includeImages includeVideos=$includeVideos batchSize=$scanBatchSize maxConcurrency=$maxConcurrency",
                )
            }

            val selectedTypes = ArrayList<Int>(2)
            if (includeImages) {
                selectedTypes += MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE
            }
            if (includeVideos) {
                selectedTypes += MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO
            }
            if (selectedTypes.isEmpty()) {
                return@withContext linkedMapOf(
                    "items" to emptyList<Map<String, Any?>>(),
                    "processed" to 0,
                    "successCount" to 0,
                    "errorCount" to 0,
                    "flaggedCount" to 0,
                )
            }

            val resolver = appContext.contentResolver
            val queryUri = MediaStore.Files.getContentUri("external")
            val selection = selectedTypes.joinToString(" OR ") { "${MediaStore.Files.FileColumns.MEDIA_TYPE}=?" }
            val selectionArgs = selectedTypes.map { it.toString() }.toTypedArray()
            @Suppress("DEPRECATION")
            val dataColumn = MediaStore.MediaColumns.DATA
            val projection = arrayOf(
                MediaStore.MediaColumns._ID,
                MediaStore.Files.FileColumns.MEDIA_TYPE,
                dataColumn,
            )
            val sortOrder = "${MediaStore.MediaColumns.DATE_ADDED} DESC"

            resolver.query(queryUri, projection, selection, selectionArgs, sortOrder)?.use { cursor ->
                val totalDiscovered = cursor.count.coerceAtLeast(0)
                val totalTarget = maxItems?.let { minOf(it, totalDiscovered) } ?: totalDiscovered

                onEvent(
                    buildGalleryLoadPayload(
                        scanId = scanId,
                        page = 0,
                        scannedAssets = 0,
                        imageCount = 0,
                        videoCount = 0,
                        targetCount = totalTarget,
                        isCompleted = false,
                    ),
                )
                onEvent(
                    buildGalleryScanProgressPayload(
                        scanId = scanId,
                        processed = 0,
                        total = totalTarget,
                        imagePath = null,
                        error = null,
                        status = "started",
                        mediaType = null,
                    ),
                )

                if (totalTarget <= 0) {
                    onEvent(
                        buildGalleryLoadPayload(
                            scanId = scanId,
                            page = 0,
                            scannedAssets = 0,
                            imageCount = 0,
                            videoCount = 0,
                            targetCount = 0,
                            isCompleted = true,
                        ),
                    )
                    onEvent(
                        buildGalleryScanProgressPayload(
                            scanId = scanId,
                            processed = 0,
                            total = 0,
                            imagePath = null,
                            error = null,
                            status = "completed",
                            mediaType = null,
                        ),
                    )
                    return@withContext linkedMapOf(
                        "items" to emptyList<Map<String, Any?>>(),
                        "processed" to 0,
                        "successCount" to 0,
                        "errorCount" to 0,
                        "flaggedCount" to 0,
                    )
                }

                val idIndex = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
                val typeIndex = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.MEDIA_TYPE)
                val pathIndex = cursor.getColumnIndex(dataColumn)

                val pendingBatch = ArrayList<NativeGalleryMediaItem>(scanBatchSize)
                val finalItems = ArrayList<Map<String, Any?>>()
                var scannedAssets = 0
                var imageCount = 0
                var videoCount = 0
                var processedTotal = 0
                var successTotal = 0
                var errorTotal = 0
                var flaggedTotal = 0
                var page = 0

                suspend fun flushBatch() {
                    if (pendingBatch.isEmpty()) {
                        return
                    }
                    val batch = ArrayList(pendingBatch)
                    pendingBatch.clear()
                    val outcome = processGalleryBatch(
                        batch = batch,
                        maxConcurrency = maxConcurrency,
                        imageThreshold = imageThreshold,
                        videoThreshold = videoThreshold,
                        videoSampleRateFps = videoSampleRateFps,
                        videoMaxFrames = videoMaxFrames,
                        dynamicVideoSampleRate = dynamicVideoSampleRate,
                        shortVideoMinSampleRateFps = shortVideoMinSampleRateFps,
                        shortVideoMaxSampleRateFps = shortVideoMaxSampleRateFps,
                        mediumVideoMinutesThreshold = mediumVideoMinutesThreshold,
                        longVideoMinutesThreshold = longVideoMinutesThreshold,
                        mediumVideoSampleRateFps = mediumVideoSampleRateFps,
                        longVideoSampleRateFps = longVideoSampleRateFps,
                        videoEarlyStopEnabled = videoEarlyStopEnabled,
                        videoEarlyStopBaseNsfwFrames = videoEarlyStopBaseNsfwFrames,
                        videoEarlyStopMediumBonusFrames = videoEarlyStopMediumBonusFrames,
                        videoEarlyStopLongBonusFrames = videoEarlyStopLongBonusFrames,
                        videoEarlyStopVeryLongMinutesThreshold = videoEarlyStopVeryLongMinutesThreshold,
                        videoEarlyStopVeryLongBonusFrames = videoEarlyStopVeryLongBonusFrames,
                        continueOnError = continueOnError,
                        thumbnailSize = thumbnailSize,
                        scanId = scanId,
                        isCancelled = isCancelled,
                        includeCleanResults = includeCleanResults,
                        debugLogging = debugLogging,
                    )
                    if (debugLogging) {
                        Log.i(
                            "FlutterNsfwScaner",
                            "[gallery:$scanId] batch processed=${outcome.processed} success=${outcome.successCount} errors=${outcome.errorCount} flagged=${outcome.flaggedCount}",
                        )
                    }

                    processedTotal += outcome.processed
                    successTotal += outcome.successCount
                    errorTotal += outcome.errorCount
                    flaggedTotal += outcome.flaggedCount
                    if (finalItems.size < 2000 && outcome.streamedItems.isNotEmpty()) {
                        val remaining = 2000 - finalItems.size
                        finalItems.addAll(outcome.streamedItems.take(remaining))
                    }

                    if (outcome.streamedItems.isNotEmpty()) {
                        onEvent(
                            buildGalleryResultBatchPayload(
                                scanId = scanId,
                                items = outcome.streamedItems,
                                processed = outcome.processed,
                                successCount = outcome.successCount,
                                errorCount = outcome.errorCount,
                                flaggedCount = outcome.flaggedCount,
                                processedTotal = processedTotal,
                                total = totalTarget,
                            ),
                        )
                    }

                    onEvent(
                        buildGalleryScanProgressPayload(
                            scanId = scanId,
                            processed = processedTotal,
                            total = totalTarget,
                            imagePath = null,
                            error = null,
                            status = "running",
                            mediaType = null,
                        ),
                    )
                }

                while (cursor.moveToNext()) {
                    if (isCancelled()) {
                        throw CancellationException("Scan cancelled")
                    }
                    if (processedTotal + pendingBatch.size >= totalTarget) {
                        break
                    }
                    val id = cursor.getLong(idIndex)
                    val mediaType = cursor.getInt(typeIndex)
                    val type = when (mediaType) {
                        MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE -> "image"
                        MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO -> "video"
                        else -> null
                    } ?: continue

                    val uri = if (type == "video") {
                        ContentUris.withAppendedId(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, id)
                    } else {
                        ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, id)
                    }
                    val path = if (pathIndex >= 0) {
                        cursor.getString(pathIndex)?.trim()?.takeIf { it.isNotEmpty() }
                    } else {
                        null
                    }
                    val item = NativeGalleryMediaItem(
                        assetId = "$type:$id",
                        uri = uri,
                        type = type,
                        path = path,
                    )
                    pendingBatch += item
                    scannedAssets += 1
                    if (type == "video") {
                        videoCount += 1
                    } else {
                        imageCount += 1
                    }

                    if (scannedAssets % loadProgressEvery == 0) {
                        onEvent(
                            buildGalleryLoadPayload(
                                scanId = scanId,
                                page = page,
                                scannedAssets = scannedAssets,
                                imageCount = imageCount,
                                videoCount = videoCount,
                                targetCount = totalTarget,
                                isCompleted = false,
                            ),
                        )
                    }

                    if (pendingBatch.size >= scanBatchSize) {
                        flushBatch()
                        page += 1
                    }
                }

                flushBatch()
                onEvent(
                    buildGalleryLoadPayload(
                        scanId = scanId,
                        page = page,
                        scannedAssets = scannedAssets,
                        imageCount = imageCount,
                        videoCount = videoCount,
                        targetCount = totalTarget,
                        isCompleted = true,
                    ),
                )
                onEvent(
                    buildGalleryScanProgressPayload(
                        scanId = scanId,
                        processed = processedTotal,
                        total = totalTarget,
                        imagePath = null,
                        error = null,
                        status = "completed",
                        mediaType = null,
                    ),
                )

                return@withContext linkedMapOf(
                    "items" to finalItems,
                    "processed" to processedTotal,
                    "successCount" to successTotal,
                    "errorCount" to errorTotal,
                    "flaggedCount" to flaggedTotal,
                )
                    .also {
                        if (debugLogging) {
                            Log.i(
                                "FlutterNsfwScaner",
                                "[gallery:$scanId] completed processed=$processedTotal success=$successTotal errors=$errorTotal flagged=$flaggedTotal",
                            )
                        }
                    }
            }

            throw IllegalStateException("Failed to query MediaStore gallery.")
        }
    }

    private suspend fun processGalleryBatch(
        batch: List<NativeGalleryMediaItem>,
        maxConcurrency: Int,
        imageThreshold: Float,
        videoThreshold: Float,
        videoSampleRateFps: Float,
        videoMaxFrames: Int,
        dynamicVideoSampleRate: Boolean,
        shortVideoMinSampleRateFps: Float,
        shortVideoMaxSampleRateFps: Float,
        mediumVideoMinutesThreshold: Int,
        longVideoMinutesThreshold: Int,
        mediumVideoSampleRateFps: Float,
        longVideoSampleRateFps: Float,
        videoEarlyStopEnabled: Boolean,
        videoEarlyStopBaseNsfwFrames: Int,
        videoEarlyStopMediumBonusFrames: Int,
        videoEarlyStopLongBonusFrames: Int,
        videoEarlyStopVeryLongMinutesThreshold: Int,
        videoEarlyStopVeryLongBonusFrames: Int,
        continueOnError: Boolean,
        thumbnailSize: Int,
        scanId: String,
        isCancelled: () -> Boolean,
        includeCleanResults: Boolean,
        debugLogging: Boolean,
    ): GalleryBatchOutcome {
        if (batch.isEmpty()) {
            return GalleryBatchOutcome(
                allItems = emptyList(),
                streamedItems = emptyList(),
                processed = 0,
                successCount = 0,
                errorCount = 0,
                flaggedCount = 0,
            )
        }
        if (isCancelled()) {
            throw CancellationException("Scan cancelled")
        }

        val workerCount = minOf(maxConcurrency, batch.size).coerceAtLeast(1)
        val imageWorkerContexts = LinkedBlockingQueue<WorkerContext>()
        repeat(workerCount) {
            imageWorkerContexts.put(
                WorkerContext(
                    interpreter = createInterpreter(defaultThreadCount),
                    workspace = createInferenceWorkspace(),
                ),
            )
        }

        return try {
            val ordered = coroutineScope {
                batch.map { item ->
                    async(Dispatchers.IO) {
                        if (isCancelled()) {
                            throw CancellationException("Scan cancelled")
                        }
                        val itemPayload = try {
                            if (item.type == "video") {
                                val resolvedVideoPath = resolveVideoPathForGallery(item)
                                try {
                                    val videoResult = scanVideo(
                                        scanId = "${scanId}_${item.assetId}",
                                        videoPath = resolvedVideoPath.path,
                                        threshold = videoThreshold,
                                        sampleRateFps = videoSampleRateFps,
                                        maxFrames = videoMaxFrames,
                                        dynamicSampleRate = dynamicVideoSampleRate,
                                        shortVideoMinSampleRateFps = shortVideoMinSampleRateFps,
                                        shortVideoMaxSampleRateFps = shortVideoMaxSampleRateFps,
                                        mediumVideoMinutesThreshold = mediumVideoMinutesThreshold,
                                        longVideoMinutesThreshold = longVideoMinutesThreshold,
                                        mediumVideoSampleRateFps = mediumVideoSampleRateFps,
                                        longVideoSampleRateFps = longVideoSampleRateFps,
                                        videoEarlyStopEnabled = videoEarlyStopEnabled,
                                        videoEarlyStopBaseNsfwFrames = videoEarlyStopBaseNsfwFrames,
                                        videoEarlyStopMediumBonusFrames = videoEarlyStopMediumBonusFrames,
                                        videoEarlyStopLongBonusFrames = videoEarlyStopLongBonusFrames,
                                        videoEarlyStopVeryLongMinutesThreshold = videoEarlyStopVeryLongMinutesThreshold,
                                        videoEarlyStopVeryLongBonusFrames = videoEarlyStopVeryLongBonusFrames,
                                        onProgress = {},
                                        isCancelled = isCancelled,
                                    )
                                    buildGalleryItemPayload(
                                        item = item,
                                        imageResult = null,
                                        videoResult = videoResult,
                                        error = null,
                                    )
                                } finally {
                                    resolvedVideoPath.tempFile?.delete()
                                }
                            } else {
                                val workerContext = imageWorkerContexts.take()
                                try {
                                    val bitmap = loadGalleryImageThumbnail(
                                        uri = item.uri,
                                        targetSize = thumbnailSize,
                                    )
                                    val displayPath = item.path ?: item.uri.toString()
                                    val imageResult = try {
                                        runSingleScan(
                                            interpreter = workerContext.interpreter,
                                            bitmap = bitmap,
                                            frameIdentity = displayPath,
                                            threshold = imageThreshold,
                                            workspace = workerContext.workspace,
                                        )
                                    } finally {
                                        if (!bitmap.isRecycled) {
                                            bitmap.recycle()
                                        }
                                    }
                                    buildGalleryItemPayload(
                                        item = item,
                                        imageResult = imageResult,
                                        videoResult = null,
                                        error = null,
                                    )
                                } finally {
                                    imageWorkerContexts.put(workerContext)
                                }
                            }
                        } catch (error: Exception) {
                            if (error is CancellationException) {
                                throw error
                            }
                            if (!continueOnError) {
                                throw error
                            }
                            if (debugLogging) {
                                Log.w(
                                    "FlutterNsfwScaner",
                                    "[gallery:$scanId] item=${item.type} uri=${item.uri} error=${error.message}",
                                )
                            }
                            buildGalleryItemPayload(
                                item = item,
                                imageResult = null,
                                videoResult = null,
                                error = error.message ?: "Unknown error",
                            )
                        }
                        itemPayload
                    }
                }.awaitAll()
            }

            val successCount = ordered.count { it["error"] == null }
            val errorCount = ordered.size - successCount
            val flaggedCount = ordered.count { item ->
                val type = item["type"] as? String
                if (type == "video") {
                    (item["videoResult"] as? Map<*, *>)?.get("isNsfw") == true
                } else {
                    (item["imageResult"] as? Map<*, *>)?.get("isNsfw") == true
                }
            }
            val streamed = if (includeCleanResults) {
                ordered
            } else {
                ordered.filter { item ->
                    val hasError = item["error"] != null
                    val isNsfw = if ((item["type"] as? String) == "video") {
                        (item["videoResult"] as? Map<*, *>)?.get("isNsfw") == true
                    } else {
                        (item["imageResult"] as? Map<*, *>)?.get("isNsfw") == true
                    }
                    hasError || isNsfw
                }
            }

            GalleryBatchOutcome(
                allItems = ordered,
                streamedItems = streamed,
                processed = ordered.size,
                successCount = successCount,
                errorCount = errorCount,
                flaggedCount = flaggedCount,
            )
        } finally {
            while (true) {
                val context = imageWorkerContexts.poll() ?: break
                context.interpreter.close()
            }
        }
    }

    private fun buildGalleryItemPayload(
        item: NativeGalleryMediaItem,
        imageResult: Map<String, Any>?,
        videoResult: Map<String, Any>?,
        error: String?,
    ): Map<String, Any?> {
        val path = item.path ?: item.uri.toString()
        return linkedMapOf(
            "assetId" to item.assetId,
            "uri" to item.uri.toString(),
            "path" to path,
            "type" to item.type,
            "imageResult" to imageResult,
            "videoResult" to videoResult,
            "error" to error,
        )
    }

    private fun buildGalleryLoadPayload(
        scanId: String,
        page: Int,
        scannedAssets: Int,
        imageCount: Int,
        videoCount: Int,
        targetCount: Int,
        isCompleted: Boolean,
    ): Map<String, Any?> {
        return linkedMapOf(
            "eventType" to "gallery_load_progress",
            "scanId" to scanId,
            "page" to page,
            "scannedAssets" to scannedAssets,
            "imageCount" to imageCount,
            "videoCount" to videoCount,
            "targetCount" to targetCount,
            "isCompleted" to isCompleted,
        )
    }

    private fun buildGalleryScanProgressPayload(
        scanId: String,
        processed: Int,
        total: Int,
        imagePath: String?,
        error: String?,
        status: String,
        mediaType: String?,
    ): Map<String, Any?> {
        return buildProgressPayload(
            scanId = scanId,
            processed = processed,
            total = total,
            imagePath = imagePath,
            error = error,
            status = status,
            mediaType = mediaType,
        ) + ("eventType" to "gallery_scan_progress")
    }

    private fun buildGalleryResultBatchPayload(
        scanId: String,
        items: List<Map<String, Any?>>,
        processed: Int,
        successCount: Int,
        errorCount: Int,
        flaggedCount: Int,
        processedTotal: Int,
        total: Int,
    ): Map<String, Any?> {
        val percent = if (total <= 0) 0.0 else (processedTotal.toDouble() / total.toDouble()).coerceIn(0.0, 1.0)
        return linkedMapOf(
            "eventType" to "gallery_result_batch",
            "scanId" to scanId,
            "status" to "running",
            "processed" to processed,
            "processedTotal" to processedTotal,
            "total" to total,
            "percent" to percent,
            "items" to items,
            "successCount" to successCount,
            "errorCount" to errorCount,
            "flaggedCount" to flaggedCount,
        )
    }

    private fun loadGalleryImageThumbnail(
        uri: Uri,
        targetSize: Int,
    ): Bitmap {
        val safeTarget = targetSize.coerceIn(128, 512)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            try {
                return appContext.contentResolver.loadThumbnail(uri, Size(safeTarget, safeTarget), null)
            } catch (_: Exception) {
                // Fall through to stream decode below for providers with no thumbnail support.
            }
        }

        return decodeGalleryThumbnailFromStream(uri, safeTarget)
    }

    private fun decodeGalleryThumbnailFromStream(
        uri: Uri,
        safeTarget: Int,
    ): Bitmap {
        val imageBytes = appContext.contentResolver.openInputStream(uri)?.use { it.readBytes() }
            ?: throw IllegalArgumentException("Unable to read image bytes for $uri")
        val boundsOptions = BitmapFactory.Options().apply {
            inJustDecodeBounds = true
        }
        BitmapFactory.decodeByteArray(imageBytes, 0, imageBytes.size, boundsOptions)
        val decodeOptions = BitmapFactory.Options().apply {
            inPreferredConfig = Bitmap.Config.ARGB_8888
            inDither = false
            inScaled = false
            inSampleSize = calculateInSampleSize(boundsOptions, safeTarget, safeTarget)
        }
        return BitmapFactory.decodeByteArray(imageBytes, 0, imageBytes.size, decodeOptions)
            ?: throw IllegalArgumentException("Unable to decode image thumbnail for $uri")
    }

    private fun resolveVideoPathForGallery(item: NativeGalleryMediaItem): ResolvedVideoPath {
        item.path?.takeIf { it.isNotBlank() }?.let { localPath ->
            return ResolvedVideoPath(path = localPath, tempFile = null)
        }
        val tempFile = copyVideoUriToTempFile(item.uri)
        return ResolvedVideoPath(path = tempFile.absolutePath, tempFile = tempFile)
    }

    private fun copyVideoUriToTempFile(uri: Uri): File {
        val inputStream = appContext.contentResolver.openInputStream(uri)
            ?: throw IllegalArgumentException("Unable to read video stream for $uri")
        val tempFile = File.createTempFile("nsfw_gallery_video_", ".tmp", appContext.cacheDir)
        inputStream.use { input ->
            tempFile.outputStream().use { output ->
                input.copyTo(output)
            }
        }
        return tempFile
    }

    fun loadImageThumbnail(
        assetRef: String,
        targetWidth: Int,
        targetHeight: Int,
        quality: Int,
    ): String {
        val normalizedRef = assetRef.trim()
        if (normalizedRef.isEmpty()) {
            throw IllegalArgumentException("assetRef is required")
        }
        val safeWidth = targetWidth.coerceIn(64, 1024)
        val safeHeight = targetHeight.coerceIn(64, 1024)
        val safeQuality = quality.coerceIn(30, 95)

        val cacheDir = File(appContext.cacheDir, "nsfw_thumbnail_cache").apply { mkdirs() }
        val cacheKey = stableHash("$normalizedRef|$safeWidth|$safeHeight|$safeQuality")
        val thumbnailFile = File(cacheDir, "thumb_$cacheKey.jpg")
        if (thumbnailFile.exists() && thumbnailFile.length() > 0L) {
            return thumbnailFile.absolutePath
        }

        val bitmap = resolveLocalFilePath(normalizedRef)?.let { localPath ->
            decodeSampledBitmap(
                imagePath = localPath,
                requestedWidth = safeWidth,
                requestedHeight = safeHeight,
            )
        } ?: run {
            val uri = resolveAssetUri(normalizedRef)
                ?: throw IllegalArgumentException("Unable to resolve image asset reference: $normalizedRef")
            loadGalleryImageThumbnail(
                uri = uri,
                targetSize = max(safeWidth, safeHeight),
            )
        }

        try {
            val scaledBitmap = if (bitmap.width == safeWidth && bitmap.height == safeHeight) {
                bitmap
            } else {
                Bitmap.createScaledBitmap(bitmap, safeWidth, safeHeight, true)
            }
            val shouldRecycleScaled = scaledBitmap !== bitmap
            try {
                thumbnailFile.outputStream().use { output ->
                    if (!scaledBitmap.compress(Bitmap.CompressFormat.JPEG, safeQuality, output)) {
                        throw IllegalStateException("Failed to encode thumbnail for $normalizedRef")
                    }
                }
            } finally {
                if (shouldRecycleScaled && !scaledBitmap.isRecycled) {
                    scaledBitmap.recycle()
                }
            }
        } finally {
            if (!bitmap.isRecycled) {
                bitmap.recycle()
            }
        }
        return thumbnailFile.absolutePath
    }

    fun loadImageAsset(assetRef: String): String {
        val normalizedRef = assetRef.trim()
        if (normalizedRef.isEmpty()) {
            throw IllegalArgumentException("assetRef is required")
        }

        resolveLocalFilePath(normalizedRef)?.let { return it }
        val sourceUri = resolveAssetUri(normalizedRef)
            ?: throw IllegalArgumentException("Unable to resolve image asset reference: $normalizedRef")
        if (sourceUri.scheme.equals("file", ignoreCase = true)) {
            val sourceFile = File(sourceUri.path.orEmpty())
            if (sourceFile.exists()) {
                return sourceFile.absolutePath
            }
        }

        val cacheDir = File(appContext.cacheDir, "nsfw_asset_cache").apply { mkdirs() }
        val mimeType = appContext.contentResolver.getType(sourceUri)
        val extension = MimeTypeMap.getSingleton()
            .getExtensionFromMimeType(mimeType)
            ?.takeIf { it.isNotBlank() }
            ?: "jpg"
        val cacheKey = stableHash(normalizedRef)
        val outputFile = File(cacheDir, "asset_$cacheKey.$extension")
        if (outputFile.exists() && outputFile.length() > 0L) {
            return outputFile.absolutePath
        }

        appContext.contentResolver.openInputStream(sourceUri)?.use { input ->
            outputFile.outputStream().use { output ->
                input.copyTo(output)
            }
        } ?: throw IllegalArgumentException("Unable to read image stream for $sourceUri")

        return outputFile.absolutePath
    }

    private fun resolveLocalFilePath(assetRef: String): String? {
        val trimmed = assetRef.trim()
        if (trimmed.isEmpty()) {
            return null
        }

        if (trimmed.startsWith("/")) {
            val file = File(trimmed)
            if (file.exists()) {
                return file.absolutePath
            }
        }

        if (trimmed.startsWith("file://", ignoreCase = true)) {
            val uri = Uri.parse(trimmed)
            val file = File(uri.path.orEmpty())
            if (file.exists()) {
                return file.absolutePath
            }
        }

        return null
    }

    private fun resolveAssetUri(assetRef: String): Uri? {
        val trimmed = assetRef.trim()
        if (trimmed.isEmpty()) {
            return null
        }
        if (trimmed.startsWith("content://", ignoreCase = true) || trimmed.startsWith("file://", ignoreCase = true)) {
            return Uri.parse(trimmed)
        }

        if (trimmed.startsWith("image:", ignoreCase = true) || trimmed.startsWith("video:", ignoreCase = true)) {
            val separatorIndex = trimmed.indexOf(':')
            val typePrefix = trimmed.substring(0, separatorIndex).lowercase(Locale.US)
            val idValue = trimmed.substring(separatorIndex + 1).toLongOrNull() ?: return null
            return if (typePrefix == "video") {
                ContentUris.withAppendedId(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, idValue)
            } else {
                ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, idValue)
            }
        }

        return null
    }

    private fun stableHash(value: String): String {
        val digest = MessageDigest.getInstance("SHA-1").digest(value.toByteArray(Charsets.UTF_8))
        return buildString(digest.size * 2) {
            digest.forEach { byte ->
                append(String.format("%02x", byte))
            }
        }
    }

    fun close() {
        // Interpreters are created per-request and closed after use.
    }

    private fun runSingleScan(
        interpreter: Interpreter,
        imagePath: String,
        threshold: Float,
        workspace: InferenceWorkspace? = null,
    ): Map<String, Any> {
        val input = preprocessImage(imagePath, workspace?.preprocess)
        return runSingleInference(
            interpreter = interpreter,
            input = input,
            frameIdentity = imagePath,
            threshold = threshold,
            workspace = workspace,
        )
    }

    private fun runSingleScan(
        interpreter: Interpreter,
        bitmap: Bitmap,
        frameIdentity: String,
        threshold: Float,
        workspace: InferenceWorkspace? = null,
    ): Map<String, Any> {
        val input = preprocessBitmap(bitmap, workspace?.preprocess)
        return runSingleInference(
            interpreter = interpreter,
            input = input,
            frameIdentity = frameIdentity,
            threshold = threshold,
            workspace = workspace,
        )
    }

    private fun runSingleInference(
        interpreter: Interpreter,
        input: ByteBuffer,
        frameIdentity: String,
        threshold: Float,
        workspace: InferenceWorkspace? = null,
    ): Map<String, Any> {
        val rawScores = runInference(interpreter, input, workspace)
        return buildResultMap(imagePath = frameIdentity, rawScores = rawScores, threshold = threshold)
    }

    private fun preprocessImage(imagePath: String, workspace: PreprocessWorkspace? = null): ByteBuffer {
        val sampledBitmap = decodeSampledBitmap(
            imagePath = imagePath,
            requestedWidth = inputWidth,
            requestedHeight = inputHeight,
        )
        return try {
            // Preserve full image content (no center crop) for better NSFW recall.
            preprocessBitmap(sampledBitmap, workspace)
        } finally {
            sampledBitmap.recycle()
        }
    }

    private fun preprocessBitmap(bitmap: Bitmap, workspace: PreprocessWorkspace? = null): ByteBuffer {
        val resizedBitmap = if (bitmap.width == inputWidth && bitmap.height == inputHeight) {
            bitmap
        } else {
            Bitmap.createScaledBitmap(bitmap, inputWidth, inputHeight, true)
        }

        val shouldRecycle = resizedBitmap !== bitmap
        return try {
            val pixelCount = inputWidth * inputHeight
            val pixels = workspace?.pixelBuffer ?: IntArray(pixelCount)
            resizedBitmap.getPixels(pixels, 0, inputWidth, 0, 0, inputWidth, inputHeight)

            val outputBuffer = workspace?.inputBuffer ?: createInputBuffer()
            outputBuffer.rewind()

            for (index in 0 until pixelCount) {
                val pixel = pixels[index]
                val r = normalizeChannel((pixel shr 16) and 0xFF)
                val g = normalizeChannel((pixel shr 8) and 0xFF)
                val b = normalizeChannel(pixel and 0xFF)

                when (inputType) {
                    DataType.FLOAT32 -> {
                        outputBuffer.putFloat(r)
                        outputBuffer.putFloat(g)
                        outputBuffer.putFloat(b)
                    }

                    DataType.UINT8 -> {
                        outputBuffer.put(quantizeToUInt8(r))
                        outputBuffer.put(quantizeToUInt8(g))
                        outputBuffer.put(quantizeToUInt8(b))
                    }

                    DataType.INT8 -> {
                        outputBuffer.put(quantizeToInt8(r))
                        outputBuffer.put(quantizeToInt8(g))
                        outputBuffer.put(quantizeToInt8(b))
                    }

                    else -> throw IllegalStateException("Unsupported input tensor type: $inputType")
                }
            }

            outputBuffer.rewind()
            outputBuffer
        } finally {
            if (shouldRecycle) {
                resizedBitmap.recycle()
            }
        }
    }

    private fun createInputBuffer(): ByteBuffer {
        val pixelCount = inputWidth * inputHeight
        return when (inputType) {
            DataType.FLOAT32 -> ByteBuffer
                .allocateDirect(pixelCount * inputChannels * 4)
                .order(ByteOrder.nativeOrder())
            DataType.UINT8, DataType.INT8 -> ByteBuffer
                .allocateDirect(pixelCount * inputChannels)
                .order(ByteOrder.nativeOrder())
            else -> throw IllegalStateException("Unsupported input tensor type: $inputType")
        }
    }

    private fun createInferenceWorkspace(): InferenceWorkspace {
        val pixelCount = inputWidth * inputHeight
        val floatOutputBuffer = if (outputType == DataType.FLOAT32) {
            ByteBuffer
                .allocateDirect(outputElementCount * 4)
                .order(ByteOrder.nativeOrder())
        } else {
            null
        }
        val quantizedOutputBuffer = if (outputType == DataType.UINT8 || outputType == DataType.INT8) {
            ByteArray(outputElementCount)
        } else {
            null
        }
        return InferenceWorkspace(
            preprocess = PreprocessWorkspace(
                pixelBuffer = IntArray(pixelCount),
                inputBuffer = createInputBuffer(),
            ),
            floatOutputBuffer = floatOutputBuffer,
            quantizedOutputBuffer = quantizedOutputBuffer,
            scoresBuffer = FloatArray(outputElementCount),
        )
    }

    private fun buildFrameTimestamps(
        durationMs: Long,
        sampleRateFps: Float,
        maxFrames: Int,
    ): List<Long> {
        val durationUs = (durationMs * 1000L).coerceAtLeast(1L)
        val stepUs = (1_000_000.0 / sampleRateFps.toDouble()).toLong().coerceAtLeast(33_333L)
        val timestamps = ArrayList<Long>()

        var currentUs = 0L
        while (currentUs <= durationUs) {
            timestamps.add(currentUs)
            currentUs += stepUs
        }
        if (timestamps.isEmpty()) {
            timestamps.add(0L)
        }

        val clampedMaxFrames = maxFrames.coerceAtLeast(1)
        if (timestamps.size <= clampedMaxFrames) {
            return timestamps
        }

        val reduced = ArrayList<Long>(clampedMaxFrames)
        val ratio = timestamps.size.toDouble() / clampedMaxFrames.toDouble()
        for (index in 0 until clampedMaxFrames) {
            val sourceIndex = (index * ratio).toInt().coerceIn(0, timestamps.lastIndex)
            reduced.add(timestamps[sourceIndex])
        }
        return reduced
    }

    private fun resolveRequiredNsfwFrames(
        durationMs: Long,
        totalFrames: Int,
        enabled: Boolean,
        baseFrames: Int,
        mediumBonus: Int,
        longBonus: Int,
        mediumThresholdMinutes: Int,
        longThresholdMinutes: Int,
        veryLongThresholdMinutes: Int,
        veryLongBonus: Int,
    ): Int {
        if (!enabled) {
            return 1
        }
        val durationMinutes = durationMs.toDouble() / 60_000.0
        var required = baseFrames.coerceAtLeast(3)
        if (durationMinutes >= mediumThresholdMinutes.coerceAtLeast(1).toDouble()) {
            required += mediumBonus.coerceAtLeast(0)
        }
        if (durationMinutes >= longThresholdMinutes.coerceAtLeast(mediumThresholdMinutes + 1).toDouble()) {
            required += longBonus.coerceAtLeast(0)
        }
        if (durationMinutes >= veryLongThresholdMinutes.coerceAtLeast(longThresholdMinutes + 1).toDouble()) {
            required += veryLongBonus.coerceAtLeast(0)
        }
        return required.coerceIn(1, totalFrames.coerceAtLeast(1))
    }

    private fun decodeVideoFrame(
        retriever: MediaMetadataRetriever,
        timestampUs: Long,
        targetWidth: Int,
        targetHeight: Int,
    ): Bitmap? {
        val scaledMax = max(targetWidth, targetHeight) * 2
        return if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O_MR1) {
            retriever.getScaledFrameAtTime(
                timestampUs,
                MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
                scaledMax,
                scaledMax,
            )
        } else {
            retriever.getFrameAtTime(
                timestampUs,
                MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
            )
        }
    }

    private fun decodeSampledBitmap(
        imagePath: String,
        requestedWidth: Int,
        requestedHeight: Int,
    ): Bitmap {
        val boundsOptions = BitmapFactory.Options().apply {
            inJustDecodeBounds = true
        }
        BitmapFactory.decodeFile(imagePath, boundsOptions)
        if (boundsOptions.outWidth <= 0 || boundsOptions.outHeight <= 0) {
            throw IllegalArgumentException("Failed to decode image bounds at path: $imagePath")
        }

        val decodeOptions = BitmapFactory.Options().apply {
            inPreferredConfig = Bitmap.Config.ARGB_8888
            inDither = false
            inScaled = false
            inSampleSize = calculateInSampleSize(boundsOptions, requestedWidth, requestedHeight)
        }

        return BitmapFactory.decodeFile(imagePath, decodeOptions)
            ?: throw IllegalArgumentException("Failed to decode image at path: $imagePath")
    }

    private fun calculateInSampleSize(
        options: BitmapFactory.Options,
        requestedWidth: Int,
        requestedHeight: Int,
    ): Int {
        val sourceWidth = options.outWidth
        val sourceHeight = options.outHeight
        var inSampleSize = 1

        if (sourceHeight > requestedHeight || sourceWidth > requestedWidth) {
            var halfHeight = sourceHeight / 2
            var halfWidth = sourceWidth / 2

            while (
                halfHeight / inSampleSize >= requestedHeight * 2 &&
                halfWidth / inSampleSize >= requestedWidth * 2
            ) {
                inSampleSize *= 2
            }
        }

        return inSampleSize.coerceAtLeast(1)
    }

    private fun centerCropToAspectRatio(
        bitmap: Bitmap,
        targetWidth: Int,
        targetHeight: Int,
    ): Bitmap {
        val sourceWidth = bitmap.width
        val sourceHeight = bitmap.height
        if (sourceWidth <= 0 || sourceHeight <= 0) {
            return bitmap
        }

        val targetAspect = targetWidth.toFloat() / targetHeight.toFloat()
        val sourceAspect = sourceWidth.toFloat() / sourceHeight.toFloat()

        return if (sourceAspect > targetAspect) {
            val cropWidth = (sourceHeight * targetAspect).toInt().coerceAtLeast(1)
            val x = ((sourceWidth - cropWidth) / 2).coerceAtLeast(0)
            Bitmap.createBitmap(bitmap, x, 0, cropWidth, sourceHeight)
        } else if (sourceAspect < targetAspect) {
            val cropHeight = (sourceWidth / targetAspect).toInt().coerceAtLeast(1)
            val y = ((sourceHeight - cropHeight) / 2).coerceAtLeast(0)
            Bitmap.createBitmap(bitmap, 0, y, sourceWidth, cropHeight)
        } else {
            bitmap
        }
    }

    private fun normalizeChannel(channelValue: Int): Float {
        val zeroToOne = channelValue.toFloat() / 255f
        return when (inputNormalizationMode) {
            InputNormalizationMode.ZERO_TO_ONE -> zeroToOne
            InputNormalizationMode.MINUS_ONE_TO_ONE -> (zeroToOne * 2f) - 1f
        }
    }

    private fun runInference(
        interpreter: Interpreter,
        input: ByteBuffer,
        workspace: InferenceWorkspace? = null,
    ): FloatArray {
        return when (outputType) {
            DataType.FLOAT32 -> {
                val outputBuffer = workspace?.floatOutputBuffer
                    ?: ByteBuffer
                        .allocateDirect(outputElementCount * 4)
                        .order(ByteOrder.nativeOrder())

                outputBuffer.rewind()
                interpreter.run(input, outputBuffer)
                outputBuffer.rewind()

                val scores = workspace?.scoresBuffer ?: FloatArray(outputElementCount)
                for (index in 0 until outputElementCount) {
                    scores[index] = outputBuffer.float
                }
                scores
            }

            DataType.UINT8, DataType.INT8 -> {
                val outputBuffer = workspace?.quantizedOutputBuffer ?: ByteArray(outputElementCount)
                interpreter.run(input, outputBuffer)

                val scores = workspace?.scoresBuffer ?: FloatArray(outputElementCount)
                for (idx in 0 until outputElementCount) {
                    val quantized = if (outputType == DataType.UINT8) {
                        outputBuffer[idx].toInt() and 0xFF
                    } else {
                        outputBuffer[idx].toInt()
                    }
                    scores[idx] = if (outputScale > 0f) {
                        (quantized - outputZeroPoint) * outputScale
                    } else {
                        (quantized and 0xFF) / 255f
                    }
                }
                scores
            }

            else -> throw IllegalStateException("Unsupported output tensor type: $outputType")
        }
    }

    private fun buildResultMap(
        imagePath: String,
        rawScores: FloatArray,
        threshold: Float,
    ): Map<String, Any> {
        if (rawScores.isEmpty()) {
            throw IllegalStateException("Model returned no scores")
        }

        val probabilities = toProbabilities(rawScores)
        val labelList = resolveLabelList(probabilities.size)

        val topIndex = probabilities.indices.maxBy { probabilities[it] }
        val topScore = probabilities[topIndex]
        val topLabel = labelList[topIndex]

        val nsfwIndices = resolveNsfwIndices(labelList)
        val safeIndices = resolveSafeIndices(labelList)
        val normalizedLabels = labelList.map { it.lowercase(Locale.US) }

        fun findIndex(vararg keywords: String): Int? {
            return normalizedLabels.indexOfFirst { label ->
                keywords.any { keyword -> label.contains(keyword) }
            }.takeIf { it >= 0 }
        }

        val pornIdx = findIndex("porn")
        val hentaiIdx = findIndex("hentai")
        val sexyIdx = findIndex("sexy")
        val explicitIdx = findIndex("explicit", "sexual", "adult")

        val pornScore = pornIdx?.let { probabilities.getOrElse(it) { 0f } } ?: 0f
        val hentaiScore = hentaiIdx?.let { probabilities.getOrElse(it) { 0f } } ?: 0f
        val sexyScore = sexyIdx?.let { probabilities.getOrElse(it) { 0f } } ?: 0f
        val explicitScore = explicitIdx?.let { probabilities.getOrElse(it) { 0f } } ?: 0f

        val nsfwScore = when {
            probabilities.size == 1 -> probabilities[0]
            pornIdx != null || hentaiIdx != null || sexyIdx != null || explicitIdx != null -> {
                // Calibrated for typical NSFW-5 outputs:
                // porn/hentai are stronger indicators, sexy is weaker.
                (
                    pornScore +
                        (0.9f * hentaiScore) +
                        (0.35f * sexyScore) +
                        (0.6f * explicitScore)
                    ).coerceIn(0f, 1f)
            }
            nsfwIndices.isNotEmpty() -> nsfwIndices.sumOf { idx ->
                probabilities.getOrElse(idx) { 0f }.toDouble()
            }.toFloat().coerceIn(0f, 1f)
            else -> topScore
        }

        val safeScore = when {
            probabilities.size == 1 -> (1f - nsfwScore).coerceIn(0f, 1f)
            safeIndices.isNotEmpty() -> safeIndices.sumOf { idx ->
                probabilities.getOrElse(idx) { 0f }.toDouble()
            }.toFloat().coerceIn(0f, 1f)
            else -> (1f - nsfwScore).coerceIn(0f, 1f)
        }

        val scoreMap = LinkedHashMap<String, Double>(probabilities.size)
        probabilities.forEachIndexed { index, score ->
            scoreMap[labelList[index]] = score.toDouble()
        }

        val explicitClassScore = maxOf(pornScore, hentaiScore, explicitScore)
        val explicitClassFloor = maxOf(0.25f, threshold * 0.58f)
        val isNsfw = nsfwScore >= threshold || explicitClassScore >= explicitClassFloor

        return linkedMapOf(
            "imagePath" to imagePath,
            "nsfwScore" to nsfwScore.toDouble(),
            "safeScore" to safeScore.toDouble(),
            "isNsfw" to isNsfw,
            "topLabel" to topLabel,
            "topScore" to topScore.toDouble(),
            "scores" to scoreMap,
        )
    }

    private fun buildErrorResult(imagePath: String, error: Throwable): Map<String, Any> {
        return linkedMapOf(
            "imagePath" to imagePath,
            "nsfwScore" to 0.0,
            "safeScore" to 0.0,
            "isNsfw" to false,
            "topLabel" to "",
            "topScore" to 0.0,
            "scores" to emptyMap<String, Double>(),
            "error" to (error.message ?: "Unknown error"),
        )
    }

    private fun buildProgressPayload(
        scanId: String,
        processed: Int,
        total: Int,
        imagePath: String?,
        error: String?,
        status: String,
        mediaType: String? = null,
    ): Map<String, Any?> {
        val percent = if (total <= 0) 0.0 else processed.toDouble() / total.toDouble()
        return linkedMapOf(
            "scanId" to scanId,
            "processed" to processed,
            "total" to total,
            "percent" to percent.coerceIn(0.0, 1.0),
            "status" to status,
            "imagePath" to imagePath,
            "error" to error,
            "mediaType" to mediaType,
        )
    }

    private fun resolveLabelList(size: Int): List<String> {
        if (labels.size == size) {
            return labels
        }

        return List(size) { index ->
            labels.getOrNull(index) ?: "class_$index"
        }
    }

    private fun resolveNsfwIndices(labels: List<String>): List<Int> {
        val keywords = listOf("nsfw", "porn", "adult", "explicit", "sexy", "sexual", "hentai", "erotic")
        val indices = labels.mapIndexedNotNull { index, label ->
            val normalized = label.lowercase(Locale.US)
            if (keywords.any { keyword -> normalized.contains(keyword) }) index else null
        }
        if (indices.isNotEmpty()) {
            return indices
        }
        return if (labels.size == 2) listOf(1) else listOf(labels.lastIndex)
    }

    private fun resolveSafeIndices(labels: List<String>): List<Int> {
        val keywords = listOf("safe", "sfw", "neutral", "clean", "drawing", "drawings")
        val indices = labels.mapIndexedNotNull { index, label ->
            val normalized = label.lowercase(Locale.US)
            if (keywords.any { keyword -> normalized.contains(keyword) }) index else null
        }
        return if (indices.isNotEmpty()) indices else listOf(0)
    }

    private fun toProbabilities(rawScores: FloatArray): FloatArray {
        if (rawScores.size == 1) {
            val value = rawScores[0]
            val probability = if (value in 0f..1f) {
                value
            } else {
                (1f / (1f + exp(-value)))
            }
            return floatArrayOf(probability.coerceIn(0f, 1f))
        }

        val hasOutOfRangeValues = rawScores.any { it < 0f || it > 1f }
        if (hasOutOfRangeValues) {
            return softmax(rawScores)
        }

        val sum = rawScores.sum()
        if (sum <= 0f) {
            return softmax(rawScores)
        }

        if (sum in 0.95f..1.05f) {
            return rawScores
        }

        return FloatArray(rawScores.size) { index -> rawScores[index] / sum }
    }

    private fun softmax(values: FloatArray): FloatArray {
        val maxValue = values.maxOrNull() ?: 0f
        val expValues = FloatArray(values.size)
        var sum = 0f

        for (index in values.indices) {
            val expValue = exp(values[index] - maxValue)
            expValues[index] = expValue
            sum += expValue
        }

        if (sum <= 0f) {
            return FloatArray(values.size) { 0f }
        }

        return FloatArray(values.size) { index -> expValues[index] / sum }
    }

    private fun quantizeToUInt8(normalized: Float): Byte {
        val scale = if (inputScale > 0f) inputScale else (1f / 255f)
        val quantized = ((normalized / scale) + inputZeroPoint)
            .roundToInt()
            .coerceIn(0, 255)
        return (quantized and 0xFF).toByte()
    }

    private fun quantizeToInt8(normalized: Float): Byte {
        val scale = if (inputScale > 0f) inputScale else (1f / 128f)
        val quantized = ((normalized / scale) + inputZeroPoint)
            .roundToInt()
            .coerceIn(-128, 127)
        return quantized.toByte()
    }

    private fun createInterpreter(numThreads: Int): Interpreter {
        val options = Interpreter.Options().apply {
            setNumThreads(numThreads)
        }

        val duplicatedBuffer = modelBuffer.duplicate().order(ByteOrder.nativeOrder())
        duplicatedBuffer.rewind()
        return Interpreter(duplicatedBuffer, options)
    }

    private fun loadAssetAsDirectBuffer(assetPath: String): ByteBuffer {
        val bytes = assetManager.open(assetPath).use { input ->
            input.readBytes()
        }

        return ByteBuffer
            .allocateDirect(bytes.size)
            .order(ByteOrder.nativeOrder())
            .apply {
                put(bytes)
                rewind()
            }
    }

    private fun loadLabels(assetPath: String): List<String> {
        return assetManager.open(assetPath).use { stream ->
            BufferedReader(InputStreamReader(stream)).readLines()
                .map { it.trim() }
                .filter { it.isNotEmpty() }
        }
    }
}
