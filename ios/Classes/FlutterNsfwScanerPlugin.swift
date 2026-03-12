import AVFoundation
import Flutter
import TensorFlowLite
import ImageIO
import Photos
import UIKit

public class FlutterNsfwScanerPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private let registrar: FlutterPluginRegistrar
  private let workerQueue = DispatchQueue(label: "flutter_nsfw_scaner.worker", qos: .userInitiated, attributes: .concurrent)
  private let scannerLock = NSLock()
  private let progressSinkLock = NSLock()
  private let cancelLock = NSLock()
  private var scanner: IOSNsfwScanner?
  private var progressSink: FlutterEventSink?
  private var cancelGeneration = 0
  private var cancelledScanIds = Set<String>()

  private init(registrar: FlutterPluginRegistrar) {
    self.registrar = registrar
    super.init()
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "flutter_nsfw_scaner", binaryMessenger: registrar.messenger())
    let progressChannel = FlutterEventChannel(name: "flutter_nsfw_scaner/progress", binaryMessenger: registrar.messenger())
    let instance = FlutterNsfwScanerPlugin(registrar: registrar)
    registrar.addMethodCallDelegate(instance, channel: channel)
    progressChannel.setStreamHandler(instance)
  }

  public func onListen(withArguments _: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    progressSinkLock.lock()
    progressSink = events
    progressSinkLock.unlock()
    return nil
  }

  public func onCancel(withArguments _: Any?) -> FlutterError? {
    progressSinkLock.lock()
    progressSink = nil
    progressSinkLock.unlock()
    return nil
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getPlatformVersion":
      dispatchResult(result, value: "iOS " + UIDevice.current.systemVersion)
    case "initializeScanner":
      initializeScanner(call, result: result)
    case "scanImage":
      scanImage(call, result: result)
    case "scanBatch":
      scanBatch(call, result: result)
    case "scanVideo":
      scanVideo(call, result: result)
    case "scanMediaBatch":
      scanMediaBatch(call, result: result)
    case "scanGallery":
      scanGallery(call, result: result)
    case "loadImageThumbnail":
      loadImageThumbnail(call, result: result)
    case "loadImageAsset":
      loadImageAsset(call, result: result)
    case "cancelScan":
      cancelScan(call, result: result)
    case "disposeScanner":
      disposeScanner(result: result)
    default:
      dispatchNotImplemented(result)
    }
  }

  private func initializeScanner(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    workerQueue.async {
      do {
        guard let args = call.arguments as? [String: Any] else {
          throw ScannerError.invalidArgument("Expected map arguments")
        }

        guard let modelAssetPath = (args["modelAssetPath"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !modelAssetPath.isEmpty else {
          throw ScannerError.invalidArgument("modelAssetPath is required")
        }

        let labelsAssetPath = (args["labelsAssetPath"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let numThreads = ((args["numThreads"] as? NSNumber)?.intValue ?? 2).clamped(to: 1...8)
        let inputNormalization = InputNormalizationMode(
          wireValue: (args["inputNormalization"] as? String) ?? ""
        )

        let newScanner = try IOSNsfwScanner(
          registrar: self.registrar,
          modelAssetPath: modelAssetPath,
          labelsAssetPath: labelsAssetPath,
          numThreads: numThreads,
          inputNormalization: inputNormalization
        )

        self.scannerLock.lock()
        self.scanner = newScanner
        self.scannerLock.unlock()

        self.dispatchResult(result, value: nil)
      } catch {
        self.dispatchError(result, code: "INIT_FAILED", error: error)
      }
    }
  }

  private func scanImage(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    workerQueue.async {
      do {
        guard let scanner = self.currentScanner() else {
          throw ScannerError.invalidArgument("Scanner is not initialized")
        }
        guard let args = call.arguments as? [String: Any] else {
          throw ScannerError.invalidArgument("Expected map arguments")
        }
        guard let imagePath = (args["imagePath"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !imagePath.isEmpty else {
          throw ScannerError.invalidArgument("imagePath is required")
        }

        let threshold = (args["threshold"] as? NSNumber)?.floatValue ?? 0.7
        let payload = try scanner.scanImage(imagePath: imagePath, threshold: threshold)
        self.dispatchResult(result, value: payload)
      } catch {
        self.dispatchError(result, code: "SCAN_FAILED", error: error)
      }
    }
  }

  private func scanBatch(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    workerQueue.async {
      do {
        guard let scanner = self.currentScanner() else {
          throw ScannerError.invalidArgument("Scanner is not initialized")
        }
        guard let args = call.arguments as? [String: Any] else {
          throw ScannerError.invalidArgument("Expected map arguments")
        }

        let imagePaths = (args["imagePaths"] as? [Any] ?? [])
          .compactMap { $0 as? String }
          .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
          .filter { !$0.isEmpty }
        let scanId = (args["scanId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !scanId.isEmpty else {
          throw ScannerError.invalidArgument("scanId is required")
        }
        self.clearCancelFlag(scanId: scanId)
        defer { self.clearCancelFlag(scanId: scanId) }
        let isCancelled = self.buildCancelChecker(scanId: scanId)

        if imagePaths.isEmpty {
          self.dispatchResult(result, value: [[String: Any]]())
          return
        }

        let threshold = (args["threshold"] as? NSNumber)?.floatValue ?? 0.7
        let maxConcurrency = ((args["maxConcurrency"] as? NSNumber)?.intValue ?? 2).clamped(to: 1...8)

        let payload = try scanner.scanBatch(
          scanId: scanId,
          imagePaths: imagePaths,
          threshold: threshold,
          maxConcurrency: maxConcurrency,
          onProgress: { event in
            self.emitProgress(event)
          },
          isCancelled: isCancelled
        )
        self.dispatchResult(result, value: payload)
      } catch ScannerError.cancelled(let message) {
        self.dispatchError(result, code: "SCAN_CANCELLED", error: ScannerError.cancelled(message))
      } catch {
        self.dispatchError(result, code: "BATCH_SCAN_FAILED", error: error)
      }
    }
  }

  private func disposeScanner(result: @escaping FlutterResult) {
    workerQueue.async {
      self.scannerLock.lock()
      self.scanner = nil
      self.scannerLock.unlock()
      self.dispatchResult(result, value: nil)
    }
  }

  private func cancelScan(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    let scanId = (args?["scanId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    cancelLock.lock()
    if let scanId, !scanId.isEmpty {
      cancelledScanIds.insert(scanId)
    } else {
      cancelGeneration += 1
    }
    cancelLock.unlock()
    dispatchResult(result, value: nil)
  }

  private func scanMediaBatch(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    workerQueue.async {
      do {
        guard let scanner = self.currentScanner() else {
          throw ScannerError.invalidArgument("Scanner is not initialized")
        }
        guard let args = call.arguments as? [String: Any] else {
          throw ScannerError.invalidArgument("Expected map arguments")
        }
        let scanId = (args["scanId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !scanId.isEmpty else {
          throw ScannerError.invalidArgument("scanId is required")
        }
        self.clearCancelFlag(scanId: scanId)
        defer { self.clearCancelFlag(scanId: scanId) }
        let isCancelled = self.buildCancelChecker(scanId: scanId)

        let mediaItems = (args["mediaItems"] as? [Any] ?? []).compactMap { raw -> NativeMediaItem? in
          guard let map = raw as? [String: Any],
                let path = (map["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                !path.isEmpty,
                let type = (map["type"] as? String)?.lowercased(),
                (type == "image" || type == "video") else {
            return nil
          }
          return NativeMediaItem(path: path, type: type)
        }
        let settings = args["settings"] as? [String: Any] ?? [:]

        let payload = try scanner.scanMediaBatch(
          scanId: scanId,
          mediaItems: mediaItems,
          settings: settings,
          onProgress: { event in
            self.emitProgress(event)
          },
          isCancelled: isCancelled
        )
        self.dispatchResult(result, value: payload)
      } catch ScannerError.cancelled(let message) {
        self.dispatchError(result, code: "SCAN_CANCELLED", error: ScannerError.cancelled(message))
      } catch {
        self.dispatchError(result, code: "MEDIA_BATCH_SCAN_FAILED", error: error)
      }
    }
  }

  private func scanGallery(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    workerQueue.async {
      do {
        guard let scanner = self.currentScanner() else {
          throw ScannerError.invalidArgument("Scanner is not initialized")
        }
        guard let args = call.arguments as? [String: Any] else {
          throw ScannerError.invalidArgument("Expected map arguments")
        }
        let scanId = (args["scanId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !scanId.isEmpty else {
          throw ScannerError.invalidArgument("scanId is required")
        }
        self.clearCancelFlag(scanId: scanId)
        defer { self.clearCancelFlag(scanId: scanId) }
        let isCancelled = self.buildCancelChecker(scanId: scanId)
        let settings = args["settings"] as? [String: Any] ?? [:]

        let payload = try scanner.scanGallery(
          scanId: scanId,
          settings: settings,
          onEvent: { event in
            self.emitProgress(event)
          },
          isCancelled: isCancelled
        )
        self.dispatchResult(result, value: payload)
      } catch ScannerError.cancelled(let message) {
        self.dispatchError(result, code: "SCAN_CANCELLED", error: ScannerError.cancelled(message))
      } catch {
        self.dispatchError(result, code: "GALLERY_SCAN_FAILED", error: error)
      }
    }
  }

  private func loadImageThumbnail(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    workerQueue.async {
      do {
        guard let scanner = self.currentScanner() else {
          throw ScannerError.invalidArgument("Scanner is not initialized")
        }
        guard let args = call.arguments as? [String: Any] else {
          throw ScannerError.invalidArgument("Expected map arguments")
        }
        let assetRef = (args["assetRef"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !assetRef.isEmpty else {
          throw ScannerError.invalidArgument("assetRef is required")
        }
        let width = ((args["width"] as? NSNumber)?.intValue ?? 160).clamped(to: 64...1024)
        let height = ((args["height"] as? NSNumber)?.intValue ?? 160).clamped(to: 64...1024)
        let quality = ((args["quality"] as? NSNumber)?.intValue ?? 70).clamped(to: 30...95)

        let payload = try scanner.loadImageThumbnail(
          assetRef: assetRef,
          targetWidth: width,
          targetHeight: height,
          quality: quality
        )
        self.dispatchResult(result, value: payload)
      } catch {
        self.dispatchError(result, code: "LOAD_IMAGE_THUMBNAIL_FAILED", error: error)
      }
    }
  }

  private func loadImageAsset(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    workerQueue.async {
      do {
        guard let scanner = self.currentScanner() else {
          throw ScannerError.invalidArgument("Scanner is not initialized")
        }
        guard let args = call.arguments as? [String: Any] else {
          throw ScannerError.invalidArgument("Expected map arguments")
        }
        let assetRef = (args["assetRef"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !assetRef.isEmpty else {
          throw ScannerError.invalidArgument("assetRef is required")
        }

        let payload = try scanner.loadImageAsset(assetRef: assetRef)
        self.dispatchResult(result, value: payload)
      } catch {
        self.dispatchError(result, code: "LOAD_IMAGE_ASSET_FAILED", error: error)
      }
    }
  }

  private func scanVideo(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    workerQueue.async {
      do {
        guard let scanner = self.currentScanner() else {
          throw ScannerError.invalidArgument("Scanner is not initialized")
        }
        guard let args = call.arguments as? [String: Any] else {
          throw ScannerError.invalidArgument("Expected map arguments")
        }

        guard let videoPath = (args["videoPath"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !videoPath.isEmpty else {
          throw ScannerError.invalidArgument("videoPath is required")
        }
        let rawScanId = (args["scanId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let scanId = (rawScanId?.isEmpty == false ? rawScanId : nil)
          ?? "video_\(Int(Date().timeIntervalSince1970 * 1000))"
        self.clearCancelFlag(scanId: scanId)
        defer { self.clearCancelFlag(scanId: scanId) }
        let isCancelled = self.buildCancelChecker(scanId: scanId)

        let threshold = (args["threshold"] as? NSNumber)?.floatValue ?? 0.7
        let sampleRateFps = (args["sampleRateFps"] as? NSNumber)?.floatValue ?? 0.3
        let maxFrames = (args["maxFrames"] as? NSNumber)?.intValue ?? 300
        let dynamicSampleRate = (args["dynamicSampleRate"] as? Bool) ?? true
        let shortVideoMinSampleRateFps =
          (args["shortVideoMinSampleRateFps"] as? NSNumber)?.doubleValue ?? 0.5
        let shortVideoMaxSampleRateFps =
          (args["shortVideoMaxSampleRateFps"] as? NSNumber)?.doubleValue ?? 0.8
        let mediumVideoMinutesThreshold =
          (args["mediumVideoMinutesThreshold"] as? NSNumber)?.intValue ?? 10
        let longVideoMinutesThreshold =
          (args["longVideoMinutesThreshold"] as? NSNumber)?.intValue ?? 15
        let mediumVideoSampleRateFps =
          (args["mediumVideoSampleRateFps"] as? NSNumber)?.doubleValue ?? 0.3
        let longVideoSampleRateFps =
          (args["longVideoSampleRateFps"] as? NSNumber)?.doubleValue ?? 0.2
        let videoEarlyStopEnabled =
          (args["videoEarlyStopEnabled"] as? Bool) ?? true
        let videoEarlyStopBaseNsfwFrames =
          (args["videoEarlyStopBaseNsfwFrames"] as? NSNumber)?.intValue ?? 3
        let videoEarlyStopMediumBonusFrames =
          (args["videoEarlyStopMediumBonusFrames"] as? NSNumber)?.intValue ?? 1
        let videoEarlyStopLongBonusFrames =
          (args["videoEarlyStopLongBonusFrames"] as? NSNumber)?.intValue ?? 2
        let videoEarlyStopVeryLongMinutesThreshold =
          (args["videoEarlyStopVeryLongMinutesThreshold"] as? NSNumber)?.intValue ?? 30
        let videoEarlyStopVeryLongBonusFrames =
          (args["videoEarlyStopVeryLongBonusFrames"] as? NSNumber)?.intValue ?? 3

        let payload = try scanner.scanVideo(
          scanId: scanId,
          videoPath: videoPath,
          threshold: threshold,
          sampleRateFps: sampleRateFps,
          maxFrames: maxFrames,
          dynamicSampleRate: dynamicSampleRate,
          shortVideoMinSampleRateFps: shortVideoMinSampleRateFps,
          shortVideoMaxSampleRateFps: shortVideoMaxSampleRateFps,
          mediumVideoMinutesThreshold: mediumVideoMinutesThreshold,
          longVideoMinutesThreshold: longVideoMinutesThreshold,
          mediumVideoSampleRateFps: mediumVideoSampleRateFps,
          longVideoSampleRateFps: longVideoSampleRateFps,
          videoEarlyStopEnabled: videoEarlyStopEnabled,
          videoEarlyStopBaseNsfwFrames: videoEarlyStopBaseNsfwFrames,
          videoEarlyStopMediumBonusFrames: videoEarlyStopMediumBonusFrames,
          videoEarlyStopLongBonusFrames: videoEarlyStopLongBonusFrames,
          videoEarlyStopVeryLongMinutesThreshold: videoEarlyStopVeryLongMinutesThreshold,
          videoEarlyStopVeryLongBonusFrames: videoEarlyStopVeryLongBonusFrames,
          onProgress: { event in
            self.emitProgress(event)
          },
          isCancelled: isCancelled
        )
        self.dispatchResult(result, value: payload)
      } catch ScannerError.cancelled(let message) {
        self.dispatchError(result, code: "SCAN_CANCELLED", error: ScannerError.cancelled(message))
      } catch {
        self.dispatchError(result, code: "VIDEO_SCAN_FAILED", error: error)
      }
    }
  }

  private func currentScanner() -> IOSNsfwScanner? {
    scannerLock.lock()
    defer { scannerLock.unlock() }
    return scanner
  }

  private func clearCancelFlag(scanId: String) {
    cancelLock.lock()
    cancelledScanIds.remove(scanId)
    cancelLock.unlock()
  }

  private func buildCancelChecker(scanId: String) -> () -> Bool {
    cancelLock.lock()
    let generationSnapshot = cancelGeneration
    cancelLock.unlock()
    return { [weak self] in
      guard let self else { return true }
      self.cancelLock.lock()
      defer { self.cancelLock.unlock() }
      return self.cancelGeneration != generationSnapshot || self.cancelledScanIds.contains(scanId)
    }
  }

  private func dispatchResult(_ result: @escaping FlutterResult, value: Any?) {
    DispatchQueue.main.async {
      result(value)
    }
  }

  private func dispatchNotImplemented(_ result: @escaping FlutterResult) {
    DispatchQueue.main.async {
      result(FlutterMethodNotImplemented)
    }
  }

  private func dispatchError(_ result: @escaping FlutterResult, code: String, error: Error) {
    let nsError = error as NSError
    let message = nsError.localizedDescription
    DispatchQueue.main.async {
      result(FlutterError(code: code, message: message, details: nsError.debugDescription))
    }
  }

  private func emitProgress(_ payload: [String: Any]) {
    DispatchQueue.main.async {
      self.progressSinkLock.lock()
      let sink = self.progressSink
      self.progressSinkLock.unlock()
      sink?(payload)
    }
  }
}

private enum InputNormalizationMode {
  case zeroToOne
  case minusOneToOne

  init(wireValue: String) {
    switch wireValue.lowercased() {
    case "zero_to_one":
      self = .zeroToOne
    case "minus_one_to_one":
      self = .minusOneToOne
    default:
      self = .minusOneToOne
    }
  }
}

private struct NativeMediaItem {
  let path: String
  let type: String
}

private final class IOSNsfwScanner {
  private let modelData: Data
  private let labels: [String]
  private let numThreads: Int

  private let inputShape: Tensor.Shape
  private let outputShape: Tensor.Shape
  private let inputType: Tensor.DataType
  private let outputType: Tensor.DataType

  private let inputScale: Float
  private let inputZeroPoint: Int
  private let outputScale: Float
  private let outputZeroPoint: Int

  private let inputWidth: Int
  private let inputHeight: Int
  private let inputChannels: Int
  private let outputElementCount: Int
  private let inputNormalizationMode: InputNormalizationMode

  init(
    registrar: FlutterPluginRegistrar,
    modelAssetPath: String,
    labelsAssetPath: String?,
    numThreads: Int,
    inputNormalization: InputNormalizationMode
  ) throws {
    self.modelData = try IOSNsfwScanner.loadAssetData(registrar: registrar, path: modelAssetPath)
    self.labels = try labelsAssetPath.map { try IOSNsfwScanner.loadLabels(registrar: registrar, path: $0) } ?? []
    self.numThreads = numThreads
    self.inputNormalizationMode = inputNormalization

    let probe = try IOSNsfwScanner.createInterpreter(modelData: modelData, numThreads: numThreads)
    try probe.allocateTensors()

    let inputTensor = try probe.input(at: 0)
    let outputTensor = try probe.output(at: 0)

    self.inputShape = inputTensor.shape
    self.outputShape = outputTensor.shape
    self.inputType = inputTensor.dataType
    self.outputType = outputTensor.dataType

    self.inputScale = inputTensor.quantizationParameters?.scale ?? 0
    self.inputZeroPoint = inputTensor.quantizationParameters?.zeroPoint ?? 0
    self.outputScale = outputTensor.quantizationParameters?.scale ?? 0
    self.outputZeroPoint = outputTensor.quantizationParameters?.zeroPoint ?? 0

    guard inputShape.dimensions.count >= 4 else {
      throw ScannerError.invalidArgument("Expected input tensor shape [1,H,W,C], got: \(inputShape.dimensions)")
    }

    self.inputHeight = inputShape.dimensions[1]
    self.inputWidth = inputShape.dimensions[2]
    self.inputChannels = inputShape.dimensions[3]
    guard inputChannels >= 3 else {
      throw ScannerError.invalidArgument("Expected at least 3 input channels, got: \(inputChannels)")
    }

    self.outputElementCount = outputShape.dimensions.reduce(1) { partial, dim in
      partial * max(1, dim)
    }
  }

  func scanImage(imagePath: String, threshold: Float) throws -> [String: Any] {
    let interpreter = try IOSNsfwScanner.createInterpreter(modelData: modelData, numThreads: numThreads)
    try interpreter.allocateTensors()
    return try runSingleScan(interpreter: interpreter, imagePath: imagePath, threshold: threshold)
  }

  func loadImageThumbnail(
    assetRef: String,
    targetWidth: Int,
    targetHeight: Int,
    quality: Int
  ) throws -> String {
    let normalizedRef = assetRef.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedRef.isEmpty else {
      throw ScannerError.invalidArgument("assetRef is required")
    }

    let safeWidth = targetWidth.clamped(to: 64...1024)
    let safeHeight = targetHeight.clamped(to: 64...1024)
    let safeQuality = quality.clamped(to: 30...95)
    let cacheDirectory = try ensureCacheDirectory(named: "thumbnail_cache")
    let cacheKey = IOSNsfwScanner.stableHash("\(normalizedRef)|\(safeWidth)x\(safeHeight)|\(safeQuality)")
    let outputURL = cacheDirectory.appendingPathComponent("thumb_\(cacheKey).jpg")
    if FileManager.default.fileExists(atPath: outputURL.path) {
      return outputURL.path
    }

    if let localPath = resolveLocalFilePath(from: normalizedRef) {
      let downsampled = try IOSNsfwScanner.decodeDownsampledImage(
        imagePath: localPath,
        targetWidth: safeWidth,
        targetHeight: safeHeight
      )
      let resized = try IOSNsfwScanner.resizeImage(downsampled, width: safeWidth, height: safeHeight)
      try writeJPEG(cgImage: resized, quality: safeQuality, to: outputURL)
      return outputURL.path
    }

    let asset = try resolvePhotoAsset(from: normalizedRef)
    let manager = PHCachingImageManager()
    let cgImage = try requestThumbnailImage(
      asset: asset,
      manager: manager,
      thumbnailSize: max(safeWidth, safeHeight)
    )
    let resized = try IOSNsfwScanner.resizeImage(cgImage, width: safeWidth, height: safeHeight)
    try writeJPEG(cgImage: resized, quality: safeQuality, to: outputURL)
    return outputURL.path
  }

  func loadImageAsset(assetRef: String) throws -> String {
    let normalizedRef = assetRef.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedRef.isEmpty else {
      throw ScannerError.invalidArgument("assetRef is required")
    }

    if let localPath = resolveLocalFilePath(from: normalizedRef) {
      return localPath
    }

    let asset = try resolvePhotoAsset(from: normalizedRef)
    let cacheDirectory = try ensureCacheDirectory(named: "asset_cache")
    let cacheKey = IOSNsfwScanner.stableHash(normalizedRef)
    let outputURL = cacheDirectory.appendingPathComponent("asset_\(cacheKey).img")
    if FileManager.default.fileExists(atPath: outputURL.path) {
      return outputURL.path
    }

    if let imageData = try requestImageData(for: asset) {
      try imageData.write(to: outputURL, options: .atomic)
      return outputURL.path
    }

    let manager = PHCachingImageManager()
    let image = try requestUIImage(
      asset: asset,
      manager: manager,
      targetSize: CGSize(width: asset.pixelWidth, height: asset.pixelHeight)
    )
    guard let jpegData = image.jpegData(compressionQuality: 0.97) else {
      throw ScannerError.invalidArgument("Unable to encode image data for asset \(asset.localIdentifier)")
    }
    try jpegData.write(to: outputURL, options: .atomic)
    return outputURL.path
  }

  func scanBatch(
    scanId: String,
    imagePaths: [String],
    threshold: Float,
    maxConcurrency: Int,
    onProgress: @escaping ([String: Any]) -> Void,
    isCancelled: @escaping () -> Bool
  ) throws -> [[String: Any]] {
    if imagePaths.isEmpty {
      return []
    }
    if isCancelled() {
      throw ScannerError.cancelled("Scan cancelled")
    }

    let workerCount = min(maxConcurrency, min(8, imagePaths.count)).clamped(to: 1...8)
    let totalCount = imagePaths.count

    var interpreterPool: [Interpreter] = []
    interpreterPool.reserveCapacity(workerCount)
    for _ in 0..<workerCount {
      let interpreter = try IOSNsfwScanner.createInterpreter(modelData: modelData, numThreads: numThreads)
      try interpreter.allocateTensors()
      interpreterPool.append(interpreter)
    }

    let poolLock = NSLock()
    let resultLock = NSLock()
    let progressLock = NSLock()
    let semaphore = DispatchSemaphore(value: workerCount)
    let group = DispatchGroup()
    let batchQueue = DispatchQueue(label: "flutter_nsfw_scaner.batch", qos: .userInitiated, attributes: .concurrent)

    var orderedResults = Array(repeating: [String: Any](), count: imagePaths.count)
    var processedCount = 0

    onProgress(
      buildProgressPayload(
        scanId: scanId,
        processed: 0,
        total: totalCount,
        imagePath: nil,
        error: nil,
        status: "started"
      )
    )

    for (index, imagePath) in imagePaths.enumerated() {
      if isCancelled() {
        throw ScannerError.cancelled("Scan cancelled")
      }
      group.enter()
      semaphore.wait()

      batchQueue.async {
        var borrowedInterpreter: Interpreter?
        poolLock.lock()
        if !interpreterPool.isEmpty {
          borrowedInterpreter = interpreterPool.removeLast()
        }
        poolLock.unlock()

        defer {
          if let borrowedInterpreter {
            poolLock.lock()
            interpreterPool.append(borrowedInterpreter)
            poolLock.unlock()
          }
          semaphore.signal()
          group.leave()
        }

        guard let interpreter = borrowedInterpreter else {
          resultLock.lock()
          orderedResults[index] = self.buildErrorResult(imagePath: imagePath, error: ScannerError.invalidArgument("No interpreter available"))
          resultLock.unlock()
          return
        }

        do {
          if isCancelled() {
            throw ScannerError.cancelled("Scan cancelled")
          }
          let result = try self.runSingleScan(interpreter: interpreter, imagePath: imagePath, threshold: threshold)
          resultLock.lock()
          orderedResults[index] = result
          resultLock.unlock()

          progressLock.lock()
          processedCount += 1
          let processed = processedCount
          progressLock.unlock()

          onProgress(
            self.buildProgressPayload(
              scanId: scanId,
              processed: processed,
              total: totalCount,
              imagePath: imagePath,
              error: nil,
              status: "running"
            )
          )
        } catch {
          if case ScannerError.cancelled = error {
            return
          }
          resultLock.lock()
          orderedResults[index] = self.buildErrorResult(imagePath: imagePath, error: error)
          resultLock.unlock()

          progressLock.lock()
          processedCount += 1
          let processed = processedCount
          progressLock.unlock()

          onProgress(
            self.buildProgressPayload(
              scanId: scanId,
              processed: processed,
              total: totalCount,
              imagePath: imagePath,
              error: (error as NSError).localizedDescription,
              status: "running"
            )
          )
        }
      }
    }

    group.wait()
    if isCancelled() {
      throw ScannerError.cancelled("Scan cancelled")
    }
    onProgress(
      buildProgressPayload(
        scanId: scanId,
        processed: totalCount,
        total: totalCount,
        imagePath: nil,
        error: nil,
        status: "completed"
      )
    )
    return orderedResults
  }

  func scanVideo(
    scanId: String,
    videoPath: String,
    threshold: Float,
    sampleRateFps: Float,
    maxFrames: Int,
    dynamicSampleRate: Bool,
    shortVideoMinSampleRateFps: Double,
    shortVideoMaxSampleRateFps: Double,
    mediumVideoMinutesThreshold: Int,
    longVideoMinutesThreshold: Int,
    mediumVideoSampleRateFps: Double,
    longVideoSampleRateFps: Double,
    videoEarlyStopEnabled: Bool,
    videoEarlyStopBaseNsfwFrames: Int,
    videoEarlyStopMediumBonusFrames: Int,
    videoEarlyStopLongBonusFrames: Int,
    videoEarlyStopVeryLongMinutesThreshold: Int,
    videoEarlyStopVeryLongBonusFrames: Int,
    onProgress: @escaping ([String: Any]) -> Void,
    isCancelled: @escaping () -> Bool
  ) throws -> [String: Any] {
    if isCancelled() {
      throw ScannerError.cancelled("Scan cancelled")
    }
    let videoURL = URL(fileURLWithPath: videoPath)
    let asset = AVURLAsset(url: videoURL)
    let durationSeconds = CMTimeGetSeconds(asset.duration)
    guard durationSeconds.isFinite, durationSeconds > 0 else {
      throw ScannerError.invalidArgument("Failed to read video duration: \(videoPath)")
    }

    let effectiveSampleRate: Double
    if dynamicSampleRate {
      effectiveSampleRate = computeDynamicSampleRateFps(
        durationSeconds: durationSeconds,
        shortVideoMinSampleRateFps: shortVideoMinSampleRateFps,
        shortVideoMaxSampleRateFps: shortVideoMaxSampleRateFps,
        mediumVideoMinutesThreshold: mediumVideoMinutesThreshold,
        longVideoMinutesThreshold: longVideoMinutesThreshold,
        mediumVideoSampleRateFps: mediumVideoSampleRateFps,
        longVideoSampleRateFps: longVideoSampleRateFps
      )
    } else {
      effectiveSampleRate = max(0.2, min(30, Double(sampleRateFps)))
    }
    let frameTimes = buildVideoFrameTimes(
      durationSeconds: durationSeconds,
      sampleRateFps: effectiveSampleRate,
      maxFrames: maxFrames
    )
    let totalFrames = max(1, frameTimes.count)
    let requiredNsfwFrames = resolveRequiredNsfwFrames(
      durationSeconds: durationSeconds,
      totalFrames: totalFrames,
      enabled: videoEarlyStopEnabled,
      baseFrames: videoEarlyStopBaseNsfwFrames,
      mediumBonus: videoEarlyStopMediumBonusFrames,
      longBonus: videoEarlyStopLongBonusFrames,
      mediumThresholdMinutes: mediumVideoMinutesThreshold,
      longThresholdMinutes: longVideoMinutesThreshold,
      veryLongThresholdMinutes: videoEarlyStopVeryLongMinutesThreshold,
      veryLongBonus: videoEarlyStopVeryLongBonusFrames
    )
    var processedFrames = 0
    onProgress(
      buildProgressPayload(
        scanId: scanId,
        processed: 0,
        total: totalFrames,
        imagePath: videoPath,
        error: nil,
        status: "started"
      )
    )

    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: inputWidth * 2, height: inputHeight * 2)

    let interpreter = try IOSNsfwScanner.createInterpreter(modelData: modelData, numThreads: numThreads)
    try interpreter.allocateTensors()

    var frameResults = [[String: Any]]()
    frameResults.reserveCapacity(frameTimes.count)

    var flaggedFrames = 0
    var maxNsfwScore = 0.0

    for seconds in frameTimes {
      if isCancelled() {
        throw ScannerError.cancelled("Scan cancelled")
      }
      let time = CMTime(seconds: seconds, preferredTimescale: 600)

      do {
        let imageRef = try generator.copyCGImage(at: time, actualTime: nil)
        let frameResult = try runSingleScan(
          interpreter: interpreter,
          cgImage: imageRef,
          frameIdentity: "\(videoPath)#\(Int((seconds * 1000).rounded()))ms",
          threshold: threshold
        )

        let nsfwScore = frameResult["nsfwScore"] as? Double ?? 0
        let isNsfw = frameResult["isNsfw"] as? Bool ?? false
        if isNsfw {
          flaggedFrames += 1
        }
        if nsfwScore > maxNsfwScore {
          maxNsfwScore = nsfwScore
        }

        frameResults.append([
          "timestampMs": seconds * 1000,
          "nsfwScore": nsfwScore,
          "safeScore": frameResult["safeScore"] as? Double ?? 0,
          "isNsfw": isNsfw,
          "topLabel": frameResult["topLabel"] as? String ?? "",
          "topScore": frameResult["topScore"] as? Double ?? 0,
          "scores": frameResult["scores"] as? [String: Double] ?? [:],
          "error": frameResult["error"] ?? NSNull(),
        ])
      } catch {
        frameResults.append([
          "timestampMs": seconds * 1000,
          "nsfwScore": 0.0,
          "safeScore": 0.0,
          "isNsfw": false,
          "topLabel": "",
          "topScore": 0.0,
          "scores": [String: Double](),
          "error": (error as NSError).localizedDescription,
        ])
      }
      processedFrames += 1
      onProgress(
        buildProgressPayload(
          scanId: scanId,
          processed: processedFrames,
          total: totalFrames,
          imagePath: videoPath,
          error: nil,
          status: "running"
        )
      )

      let remaining = totalFrames - processedFrames
      if videoEarlyStopEnabled && flaggedFrames >= requiredNsfwFrames {
        break
      }
      if videoEarlyStopEnabled && (flaggedFrames + remaining) < requiredNsfwFrames {
        break
      }
    }

    if isCancelled() {
      throw ScannerError.cancelled("Scan cancelled")
    }

    let sampledFrames = frameResults.count
    let flaggedRatio: Double = sampledFrames > 0 ? Double(flaggedFrames) / Double(sampledFrames) : 0

    onProgress(
      buildProgressPayload(
        scanId: scanId,
        processed: totalFrames,
        total: totalFrames,
        imagePath: videoPath,
        error: nil,
        status: "completed"
      )
    )

    return [
      "videoPath": videoPath,
      "sampleRateFps": effectiveSampleRate,
      "sampledFrames": sampledFrames,
      "flaggedFrames": flaggedFrames,
      "flaggedRatio": flaggedRatio,
      "maxNsfwScore": maxNsfwScore,
      "isNsfw": flaggedFrames >= requiredNsfwFrames && maxNsfwScore >= Double(threshold),
      "requiredNsfwFrames": requiredNsfwFrames,
      "frames": frameResults,
    ]
  }

  func scanMediaBatch(
    scanId: String,
    mediaItems: [NativeMediaItem],
    settings: [String: Any],
    onProgress: @escaping ([String: Any]) -> Void,
    isCancelled: @escaping () -> Bool
  ) throws -> [String: Any] {
    if mediaItems.isEmpty {
      return [
        "items": [[String: Any]](),
        "processed": 0,
        "successCount": 0,
        "errorCount": 0,
        "flaggedCount": 0,
      ]
    }

    let imageThreshold = (settings["imageThreshold"] as? NSNumber)?.floatValue ?? 0.7
    let videoThreshold = (settings["videoThreshold"] as? NSNumber)?.floatValue ?? 0.7
    let videoSampleRateFps = (settings["videoSampleRateFps"] as? NSNumber)?.floatValue ?? 0.3
    let videoMaxFrames = (settings["videoMaxFrames"] as? NSNumber)?.intValue ?? 300
    let dynamicVideoSampleRate = (settings["dynamicVideoSampleRate"] as? Bool) ?? true
    let shortVideoMinSampleRateFps =
      (settings["shortVideoMinSampleRateFps"] as? NSNumber)?.doubleValue ?? 0.5
    let shortVideoMaxSampleRateFps =
      (settings["shortVideoMaxSampleRateFps"] as? NSNumber)?.doubleValue ?? 0.8
    let mediumVideoMinutesThreshold =
      (settings["mediumVideoMinutesThreshold"] as? NSNumber)?.intValue ?? 10
    let longVideoMinutesThreshold =
      (settings["longVideoMinutesThreshold"] as? NSNumber)?.intValue ?? 15
    let mediumVideoSampleRateFps =
      (settings["mediumVideoSampleRateFps"] as? NSNumber)?.doubleValue ?? 0.3
    let longVideoSampleRateFps =
      (settings["longVideoSampleRateFps"] as? NSNumber)?.doubleValue ?? 0.2
    let videoEarlyStopEnabled = (settings["videoEarlyStopEnabled"] as? Bool) ?? true
    let videoEarlyStopBaseNsfwFrames =
      (settings["videoEarlyStopBaseNsfwFrames"] as? NSNumber)?.intValue ?? 3
    let videoEarlyStopMediumBonusFrames =
      (settings["videoEarlyStopMediumBonusFrames"] as? NSNumber)?.intValue ?? 1
    let videoEarlyStopLongBonusFrames =
      (settings["videoEarlyStopLongBonusFrames"] as? NSNumber)?.intValue ?? 2
    let videoEarlyStopVeryLongMinutesThreshold =
      (settings["videoEarlyStopVeryLongMinutesThreshold"] as? NSNumber)?.intValue ?? 30
    let videoEarlyStopVeryLongBonusFrames =
      (settings["videoEarlyStopVeryLongBonusFrames"] as? NSNumber)?.intValue ?? 3
    let maxConcurrency = ((settings["maxConcurrency"] as? NSNumber)?.intValue ?? 2).clamped(to: 1...8)
    let continueOnError = (settings["continueOnError"] as? Bool) ?? true

    var imageInterpreterPool: [Interpreter] = []
    imageInterpreterPool.reserveCapacity(maxConcurrency)
    for _ in 0..<maxConcurrency {
      let interpreter = try IOSNsfwScanner.createInterpreter(modelData: modelData, numThreads: numThreads)
      try interpreter.allocateTensors()
      imageInterpreterPool.append(interpreter)
    }
    let imageInterpreterPoolLock = NSLock()

    let total = mediaItems.count
    var orderedResults = Array(repeating: [String: Any](), count: total)
    let semaphore = DispatchSemaphore(value: min(maxConcurrency, total))
    let group = DispatchGroup()
    let queue = DispatchQueue(label: "flutter_nsfw_scaner.media_batch", qos: .userInitiated, attributes: .concurrent)
    let lock = NSLock()
    var processed = 0

    onProgress(
      buildProgressPayload(
        scanId: scanId,
        processed: 0,
        total: total,
        imagePath: nil,
        error: nil,
        status: "started",
        mediaType: nil
      )
    )

    for (index, item) in mediaItems.enumerated() {
      if isCancelled() {
        throw ScannerError.cancelled("Scan cancelled")
      }
      group.enter()
      semaphore.wait()
      queue.async {
        var borrowedImageInterpreter: Interpreter?
        defer {
          if let borrowedImageInterpreter {
            imageInterpreterPoolLock.lock()
            imageInterpreterPool.append(borrowedImageInterpreter)
            imageInterpreterPoolLock.unlock()
          }
          semaphore.signal()
          group.leave()
        }

        do {
          if isCancelled() {
            throw ScannerError.cancelled("Scan cancelled")
          }
          let payload: [String: Any]
          if item.type == "video" {
            let videoResult = try self.scanVideo(
              scanId: "\(scanId)_item_\(index)",
              videoPath: item.path,
              threshold: videoThreshold,
              sampleRateFps: videoSampleRateFps,
              maxFrames: videoMaxFrames,
              dynamicSampleRate: dynamicVideoSampleRate,
              shortVideoMinSampleRateFps: shortVideoMinSampleRateFps,
              shortVideoMaxSampleRateFps: shortVideoMaxSampleRateFps,
              mediumVideoMinutesThreshold: mediumVideoMinutesThreshold,
              longVideoMinutesThreshold: longVideoMinutesThreshold,
              mediumVideoSampleRateFps: mediumVideoSampleRateFps,
              longVideoSampleRateFps: longVideoSampleRateFps,
              videoEarlyStopEnabled: videoEarlyStopEnabled,
              videoEarlyStopBaseNsfwFrames: videoEarlyStopBaseNsfwFrames,
              videoEarlyStopMediumBonusFrames: videoEarlyStopMediumBonusFrames,
              videoEarlyStopLongBonusFrames: videoEarlyStopLongBonusFrames,
              videoEarlyStopVeryLongMinutesThreshold: videoEarlyStopVeryLongMinutesThreshold,
              videoEarlyStopVeryLongBonusFrames: videoEarlyStopVeryLongBonusFrames,
              onProgress: { _ in },
              isCancelled: isCancelled
            )
            payload = [
              "path": item.path,
              "type": item.type,
              "imageResult": NSNull(),
              "videoResult": videoResult,
              "error": NSNull(),
            ]
          } else {
            imageInterpreterPoolLock.lock()
            if !imageInterpreterPool.isEmpty {
              borrowedImageInterpreter = imageInterpreterPool.removeLast()
            }
            imageInterpreterPoolLock.unlock()

            guard let imageInterpreter = borrowedImageInterpreter else {
              throw ScannerError.invalidArgument("No interpreter available")
            }
            let imageResult = try self.runSingleScan(
              interpreter: imageInterpreter,
              imagePath: item.path,
              threshold: imageThreshold
            )
            payload = [
              "path": item.path,
              "type": item.type,
              "imageResult": imageResult,
              "videoResult": NSNull(),
              "error": NSNull(),
            ]
          }

          lock.lock()
          orderedResults[index] = payload
          processed += 1
          let currentProcessed = processed
          lock.unlock()

          onProgress(
            self.buildProgressPayload(
              scanId: scanId,
              processed: currentProcessed,
              total: total,
              imagePath: item.path,
              error: nil,
              status: "running",
              mediaType: item.type
            )
          )
        } catch {
          if case ScannerError.cancelled = error {
            return
          }
          if !continueOnError {
            return
          }
          let message = (error as NSError).localizedDescription
          lock.lock()
          orderedResults[index] = [
            "path": item.path,
            "type": item.type,
            "imageResult": NSNull(),
            "videoResult": NSNull(),
            "error": message,
          ]
          processed += 1
          let currentProcessed = processed
          lock.unlock()

          onProgress(
            self.buildProgressPayload(
              scanId: scanId,
              processed: currentProcessed,
              total: total,
              imagePath: item.path,
              error: message,
              status: "running",
              mediaType: item.type
            )
          )
        }
      }
    }

    group.wait()
    if isCancelled() {
      throw ScannerError.cancelled("Scan cancelled")
    }

    let successCount = orderedResults.filter { ($0["error"] == nil) || ($0["error"] is NSNull) }.count
    let errorCount = total - successCount
    let flaggedCount = orderedResults.filter { item in
      guard let type = item["type"] as? String else { return false }
      if type == "video" {
        return (item["videoResult"] as? [String: Any])?["isNsfw"] as? Bool == true
      }
      return (item["imageResult"] as? [String: Any])?["isNsfw"] as? Bool == true
    }.count

    onProgress(
      buildProgressPayload(
        scanId: scanId,
        processed: total,
        total: total,
        imagePath: nil,
        error: nil,
        status: "completed",
        mediaType: nil
      )
    )

    return [
      "items": orderedResults,
      "processed": total,
      "successCount": successCount,
      "errorCount": errorCount,
      "flaggedCount": flaggedCount,
    ]
  }

  private struct GalleryAssetItem {
    let asset: PHAsset
    let assetId: String
    let type: String
  }

  private struct GalleryBatchOutcome {
    let allItems: [[String: Any]]
    let streamedItems: [[String: Any]]
    let processed: Int
    let successCount: Int
    let errorCount: Int
    let flaggedCount: Int
  }

  func scanGallery(
    scanId: String,
    settings: [String: Any],
    onEvent: @escaping ([String: Any]) -> Void,
    isCancelled: @escaping () -> Bool
  ) throws -> [String: Any] {
    try ensurePhotoAccess()

    let includeImages = (settings["includeImages"] as? Bool) ?? true
    let includeVideos = (settings["includeVideos"] as? Bool) ?? true
    if !includeImages && !includeVideos {
      return [
        "items": [[String: Any]](),
        "processed": 0,
        "successCount": 0,
        "errorCount": 0,
        "flaggedCount": 0,
      ]
    }

    let includeCleanResults = (settings["includeCleanResults"] as? Bool) ?? false
    let debugLogging = (settings["debugLogging"] as? Bool) ?? false
    let imageThreshold = (settings["imageThreshold"] as? NSNumber)?.floatValue ?? 0.7
    let videoThreshold = (settings["videoThreshold"] as? NSNumber)?.floatValue ?? 0.7
    let videoSampleRateFps = (settings["videoSampleRateFps"] as? NSNumber)?.floatValue ?? 0.3
    let videoMaxFrames = (settings["videoMaxFrames"] as? NSNumber)?.intValue ?? 300
    let dynamicVideoSampleRate = (settings["dynamicVideoSampleRate"] as? Bool) ?? true
    let shortVideoMinSampleRateFps =
      (settings["shortVideoMinSampleRateFps"] as? NSNumber)?.doubleValue ?? 0.5
    let shortVideoMaxSampleRateFps =
      (settings["shortVideoMaxSampleRateFps"] as? NSNumber)?.doubleValue ?? 0.8
    let mediumVideoMinutesThreshold =
      (settings["mediumVideoMinutesThreshold"] as? NSNumber)?.intValue ?? 10
    let longVideoMinutesThreshold =
      (settings["longVideoMinutesThreshold"] as? NSNumber)?.intValue ?? 15
    let mediumVideoSampleRateFps =
      (settings["mediumVideoSampleRateFps"] as? NSNumber)?.doubleValue ?? 0.3
    let longVideoSampleRateFps =
      (settings["longVideoSampleRateFps"] as? NSNumber)?.doubleValue ?? 0.2
    let videoEarlyStopEnabled = (settings["videoEarlyStopEnabled"] as? Bool) ?? true
    let videoEarlyStopBaseNsfwFrames =
      (settings["videoEarlyStopBaseNsfwFrames"] as? NSNumber)?.intValue ?? 3
    let videoEarlyStopMediumBonusFrames =
      (settings["videoEarlyStopMediumBonusFrames"] as? NSNumber)?.intValue ?? 1
    let videoEarlyStopLongBonusFrames =
      (settings["videoEarlyStopLongBonusFrames"] as? NSNumber)?.intValue ?? 2
    let videoEarlyStopVeryLongMinutesThreshold =
      (settings["videoEarlyStopVeryLongMinutesThreshold"] as? NSNumber)?.intValue ?? 30
    let videoEarlyStopVeryLongBonusFrames =
      (settings["videoEarlyStopVeryLongBonusFrames"] as? NSNumber)?.intValue ?? 3
    let continueOnError = (settings["continueOnError"] as? Bool) ?? true
    let scanBatchSize = ((settings["scanChunkSize"] as? NSNumber)?.intValue ?? 100).clamped(to: 50...200)
    let thumbnailSize = ((settings["thumbnailSize"] as? NSNumber)?.intValue ?? 224).clamped(to: 128...512)
    let loadProgressEvery = ((settings["loadProgressEvery"] as? NSNumber)?.intValue ?? 100).clamped(to: 20...500)
    let maxItemsRaw = (settings["maxItems"] as? NSNumber)?.intValue
    let maxItems = (maxItemsRaw ?? 0) > 0 ? maxItemsRaw! : nil
    let cpuWorkers = max(1, ProcessInfo.processInfo.activeProcessorCount)
    let maxConcurrencySetting = (settings["maxConcurrency"] as? NSNumber)?.intValue ?? cpuWorkers
    let maxConcurrency = max(1, min(8, min(cpuWorkers, maxConcurrencySetting)))
    if debugLogging {
      NSLog("[flutter_nsfw_scaner][gallery:\(scanId)] start includeImages=\(includeImages) includeVideos=\(includeVideos) batchSize=\(scanBatchSize) maxConcurrency=\(maxConcurrency)")
    }

    let fetchOptions = PHFetchOptions()
    var predicates = [NSPredicate]()
    if includeImages {
      predicates.append(NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue))
    }
    if includeVideos {
      predicates.append(NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue))
    }
    if predicates.count == 1 {
      fetchOptions.predicate = predicates.first
    } else if !predicates.isEmpty {
      fetchOptions.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: predicates)
    }
    fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

    let assets = PHAsset.fetchAssets(with: fetchOptions)
    let totalDiscovered = assets.count
    let totalTarget = min(totalDiscovered, maxItems ?? totalDiscovered)

    onEvent(
      buildGalleryLoadPayload(
        scanId: scanId,
        page: 0,
        scannedAssets: 0,
        imageCount: 0,
        videoCount: 0,
        targetCount: totalTarget,
        isCompleted: false
      )
    )
    onEvent(
      buildGalleryScanProgressPayload(
        scanId: scanId,
        processed: 0,
        total: totalTarget,
        imagePath: nil,
        error: nil,
        status: "started",
        mediaType: nil
      )
    )

    if totalTarget <= 0 {
      onEvent(
        buildGalleryLoadPayload(
          scanId: scanId,
          page: 0,
          scannedAssets: 0,
          imageCount: 0,
          videoCount: 0,
          targetCount: 0,
          isCompleted: true
        )
      )
      onEvent(
        buildGalleryScanProgressPayload(
          scanId: scanId,
          processed: 0,
          total: 0,
          imagePath: nil,
          error: nil,
          status: "completed",
          mediaType: nil
        )
      )
      return [
        "items": [[String: Any]](),
        "processed": 0,
        "successCount": 0,
        "errorCount": 0,
        "flaggedCount": 0,
      ]
    }

    var pendingBatch: [GalleryAssetItem] = []
    pendingBatch.reserveCapacity(scanBatchSize)
    var finalItems = [[String: Any]]()

    var scannedAssets = 0
    var imageCount = 0
    var videoCount = 0
    var processedTotal = 0
    var successTotal = 0
    var errorTotal = 0
    var flaggedTotal = 0
    var page = 0

    func flushBatch() throws {
      if pendingBatch.isEmpty {
        return
      }
      let batch = pendingBatch
      pendingBatch.removeAll(keepingCapacity: true)
      let outcome = try processGalleryBatch(
        batch: batch,
        maxConcurrency: maxConcurrency,
        imageThreshold: imageThreshold,
        videoThreshold: videoThreshold,
        videoSampleRateFps: videoSampleRateFps,
        videoMaxFrames: videoMaxFrames,
        dynamicVideoSampleRate: dynamicVideoSampleRate,
        shortVideoMinSampleRateFps: shortVideoMinSampleRateFps,
        shortVideoMaxSampleRateFps: shortVideoMaxSampleRateFps,
        mediumVideoMinutesThreshold: mediumVideoMinutesThreshold,
        longVideoMinutesThreshold: longVideoMinutesThreshold,
        mediumVideoSampleRateFps: mediumVideoSampleRateFps,
        longVideoSampleRateFps: longVideoSampleRateFps,
        videoEarlyStopEnabled: videoEarlyStopEnabled,
        videoEarlyStopBaseNsfwFrames: videoEarlyStopBaseNsfwFrames,
        videoEarlyStopMediumBonusFrames: videoEarlyStopMediumBonusFrames,
        videoEarlyStopLongBonusFrames: videoEarlyStopLongBonusFrames,
        videoEarlyStopVeryLongMinutesThreshold: videoEarlyStopVeryLongMinutesThreshold,
        videoEarlyStopVeryLongBonusFrames: videoEarlyStopVeryLongBonusFrames,
        continueOnError: continueOnError,
        thumbnailSize: thumbnailSize,
        scanId: scanId,
        isCancelled: isCancelled,
        includeCleanResults: includeCleanResults,
        debugLogging: debugLogging
      )
      if debugLogging {
        NSLog(
          "[flutter_nsfw_scaner][gallery:\(scanId)] batch processed=\(outcome.processed) success=\(outcome.successCount) errors=\(outcome.errorCount) flagged=\(outcome.flaggedCount)"
        )
      }

      processedTotal += outcome.processed
      successTotal += outcome.successCount
      errorTotal += outcome.errorCount
      flaggedTotal += outcome.flaggedCount
      if finalItems.count < 2000 && !outcome.streamedItems.isEmpty {
        let remaining = 2000 - finalItems.count
        finalItems.append(contentsOf: outcome.streamedItems.prefix(remaining))
      }

      if !outcome.streamedItems.isEmpty {
        onEvent(
          buildGalleryResultBatchPayload(
            scanId: scanId,
            items: outcome.streamedItems,
            processed: outcome.processed,
            successCount: outcome.successCount,
            errorCount: outcome.errorCount,
            flaggedCount: outcome.flaggedCount,
            processedTotal: processedTotal,
            total: totalTarget
          )
        )
      }

      onEvent(
        buildGalleryScanProgressPayload(
          scanId: scanId,
          processed: processedTotal,
          total: totalTarget,
          imagePath: nil,
          error: nil,
          status: "running",
          mediaType: nil
        )
      )
    }

    var index = 0
    while index < totalTarget {
      if isCancelled() {
        throw ScannerError.cancelled("Scan cancelled")
      }
      let asset = assets.object(at: index)
      defer { index += 1 }

      let type: String
      switch asset.mediaType {
      case .image:
        type = "image"
        imageCount += 1
      case .video:
        type = "video"
        videoCount += 1
      default:
        continue
      }

      scannedAssets += 1
      pendingBatch.append(
        GalleryAssetItem(
          asset: asset,
          assetId: asset.localIdentifier,
          type: type
        )
      )

      if scannedAssets % loadProgressEvery == 0 {
        onEvent(
          buildGalleryLoadPayload(
            scanId: scanId,
            page: page,
            scannedAssets: scannedAssets,
            imageCount: imageCount,
            videoCount: videoCount,
            targetCount: totalTarget,
            isCompleted: false
          )
        )
      }

      if pendingBatch.count >= scanBatchSize {
        try flushBatch()
        page += 1
      }
    }

    try flushBatch()
    onEvent(
      buildGalleryLoadPayload(
        scanId: scanId,
        page: page,
        scannedAssets: scannedAssets,
        imageCount: imageCount,
        videoCount: videoCount,
        targetCount: totalTarget,
        isCompleted: true
      )
    )
    onEvent(
      buildGalleryScanProgressPayload(
        scanId: scanId,
        processed: processedTotal,
        total: totalTarget,
        imagePath: nil,
        error: nil,
        status: "completed",
        mediaType: nil
      )
    )

    let payload: [String: Any] = [
      "items": finalItems,
      "processed": processedTotal,
      "successCount": successTotal,
      "errorCount": errorTotal,
      "flaggedCount": flaggedTotal,
    ]
    if debugLogging {
      NSLog(
        "[flutter_nsfw_scaner][gallery:\(scanId)] completed processed=\(processedTotal) success=\(successTotal) errors=\(errorTotal) flagged=\(flaggedTotal)"
      )
    }
    return payload
  }

  private func processGalleryBatch(
    batch: [GalleryAssetItem],
    maxConcurrency: Int,
    imageThreshold: Float,
    videoThreshold: Float,
    videoSampleRateFps: Float,
    videoMaxFrames: Int,
    dynamicVideoSampleRate: Bool,
    shortVideoMinSampleRateFps: Double,
    shortVideoMaxSampleRateFps: Double,
    mediumVideoMinutesThreshold: Int,
    longVideoMinutesThreshold: Int,
    mediumVideoSampleRateFps: Double,
    longVideoSampleRateFps: Double,
    videoEarlyStopEnabled: Bool,
    videoEarlyStopBaseNsfwFrames: Int,
    videoEarlyStopMediumBonusFrames: Int,
    videoEarlyStopLongBonusFrames: Int,
    videoEarlyStopVeryLongMinutesThreshold: Int,
    videoEarlyStopVeryLongBonusFrames: Int,
    continueOnError: Bool,
    thumbnailSize: Int,
    scanId: String,
    isCancelled: @escaping () -> Bool,
    includeCleanResults: Bool,
    debugLogging: Bool
  ) throws -> GalleryBatchOutcome {
    if batch.isEmpty {
      return GalleryBatchOutcome(
        allItems: [],
        streamedItems: [],
        processed: 0,
        successCount: 0,
        errorCount: 0,
        flaggedCount: 0
      )
    }
    if isCancelled() {
      throw ScannerError.cancelled("Scan cancelled")
    }

    let workerCount = max(1, min(maxConcurrency, batch.count))
    var imageInterpreterPool: [Interpreter] = []
    imageInterpreterPool.reserveCapacity(workerCount)
    for _ in 0..<workerCount {
      let interpreter = try IOSNsfwScanner.createInterpreter(modelData: modelData, numThreads: numThreads)
      try interpreter.allocateTensors()
      imageInterpreterPool.append(interpreter)
    }

    let imageManager = PHCachingImageManager()
    let poolLock = NSLock()
    let resultLock = NSLock()
    let fatalLock = NSLock()

    var firstFatalError: Error?
    var orderedResults = Array(repeating: [String: Any](), count: batch.count)

    let operationQueue = OperationQueue()
    operationQueue.qualityOfService = .userInitiated
    operationQueue.maxConcurrentOperationCount = workerCount
    let group = DispatchGroup()

    for (index, item) in batch.enumerated() {
      if isCancelled() {
        throw ScannerError.cancelled("Scan cancelled")
      }
      group.enter()
      operationQueue.addOperation {
        autoreleasepool {
          defer { group.leave() }

          fatalLock.lock()
          let shouldStop = firstFatalError != nil
          fatalLock.unlock()
          if shouldStop {
            return
          }

          do {
            if isCancelled() {
              throw ScannerError.cancelled("Scan cancelled")
            }

            let payload: [String: Any]
            if item.type == "video" {
              guard let videoPath = self.resolveVideoPath(for: item.asset) else {
                throw ScannerError.invalidArgument("No local file path available for video asset \(item.assetId)")
              }
              let videoResult = try self.scanVideo(
                scanId: "\(scanId)_\(item.assetId)",
                videoPath: videoPath,
                threshold: videoThreshold,
                sampleRateFps: videoSampleRateFps,
                maxFrames: videoMaxFrames,
                dynamicSampleRate: dynamicVideoSampleRate,
                shortVideoMinSampleRateFps: shortVideoMinSampleRateFps,
                shortVideoMaxSampleRateFps: shortVideoMaxSampleRateFps,
                mediumVideoMinutesThreshold: mediumVideoMinutesThreshold,
                longVideoMinutesThreshold: longVideoMinutesThreshold,
                mediumVideoSampleRateFps: mediumVideoSampleRateFps,
                longVideoSampleRateFps: longVideoSampleRateFps,
                videoEarlyStopEnabled: videoEarlyStopEnabled,
                videoEarlyStopBaseNsfwFrames: videoEarlyStopBaseNsfwFrames,
                videoEarlyStopMediumBonusFrames: videoEarlyStopMediumBonusFrames,
                videoEarlyStopLongBonusFrames: videoEarlyStopLongBonusFrames,
                videoEarlyStopVeryLongMinutesThreshold: videoEarlyStopVeryLongMinutesThreshold,
                videoEarlyStopVeryLongBonusFrames: videoEarlyStopVeryLongBonusFrames,
                onProgress: { _ in },
                isCancelled: isCancelled
              )
              payload = self.buildGalleryItemPayload(
                assetId: item.assetId,
                uri: "ph://\(item.assetId)",
                path: videoPath,
                type: item.type,
                imageResult: nil,
                videoResult: videoResult,
                error: nil
              )
            } else {
              var borrowedInterpreter: Interpreter?
              poolLock.lock()
              if !imageInterpreterPool.isEmpty {
                borrowedInterpreter = imageInterpreterPool.removeLast()
              }
              poolLock.unlock()

              guard let interpreter = borrowedInterpreter else {
                throw ScannerError.invalidArgument("No interpreter available")
              }

              defer {
                poolLock.lock()
                imageInterpreterPool.append(interpreter)
                poolLock.unlock()
              }

              let image = try self.requestThumbnailImage(
                asset: item.asset,
                manager: imageManager,
                thumbnailSize: thumbnailSize
              )
              let identityPath = "ph://\(item.assetId)"
              let imageResult = try self.runSingleScan(
                interpreter: interpreter,
                cgImage: image,
                frameIdentity: identityPath,
                threshold: imageThreshold
              )
              payload = self.buildGalleryItemPayload(
                assetId: item.assetId,
                uri: identityPath,
                path: identityPath,
                type: item.type,
                imageResult: imageResult,
                videoResult: nil,
                error: nil
              )
            }

            resultLock.lock()
            orderedResults[index] = payload
            resultLock.unlock()
          } catch {
            if case ScannerError.cancelled = error {
              return
            }
            if !continueOnError {
              fatalLock.lock()
              if firstFatalError == nil {
                firstFatalError = error
              }
              fatalLock.unlock()
              operationQueue.cancelAllOperations()
              return
            }
            if debugLogging {
              NSLog("[flutter_nsfw_scaner][gallery:\(scanId)] item=\(item.type) asset=\(item.assetId) error=\((error as NSError).localizedDescription)")
            }
            let payload = self.buildGalleryItemPayload(
              assetId: item.assetId,
              uri: "ph://\(item.assetId)",
              path: "ph://\(item.assetId)",
              type: item.type,
              imageResult: nil,
              videoResult: nil,
              error: (error as NSError).localizedDescription
            )
            resultLock.lock()
            orderedResults[index] = payload
            resultLock.unlock()
          }
        }
      }
    }

    group.wait()
    operationQueue.cancelAllOperations()

    fatalLock.lock()
    let fatalError = firstFatalError
    fatalLock.unlock()
    if let fatalError {
      throw fatalError
    }
    if isCancelled() {
      throw ScannerError.cancelled("Scan cancelled")
    }

    let nonEmptyResults = orderedResults.filter { !$0.isEmpty }
    let successCount = nonEmptyResults.filter { ($0["error"] == nil) || ($0["error"] is NSNull) }.count
    let errorCount = nonEmptyResults.count - successCount
    let flaggedCount = nonEmptyResults.filter { item in
      guard let type = item["type"] as? String else { return false }
      if type == "video" {
        return (item["videoResult"] as? [String: Any])?["isNsfw"] as? Bool == true
      }
      return (item["imageResult"] as? [String: Any])?["isNsfw"] as? Bool == true
    }.count

    let streamedItems = includeCleanResults
      ? nonEmptyResults
      : nonEmptyResults.filter { item in
          let hasError = !((item["error"] == nil) || (item["error"] is NSNull))
          let isNsfw: Bool
          if (item["type"] as? String) == "video" {
            isNsfw = (item["videoResult"] as? [String: Any])?["isNsfw"] as? Bool == true
          } else {
            isNsfw = (item["imageResult"] as? [String: Any])?["isNsfw"] as? Bool == true
          }
          return hasError || isNsfw
        }

    return GalleryBatchOutcome(
      allItems: nonEmptyResults,
      streamedItems: streamedItems,
      processed: nonEmptyResults.count,
      successCount: successCount,
      errorCount: errorCount,
      flaggedCount: flaggedCount
    )
  }

  private func ensurePhotoAccess() throws {
    if #available(iOS 14, *) {
      let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
      if status == .authorized || status == .limited {
        return
      }
      if status == .denied || status == .restricted {
        throw ScannerError.invalidArgument("Gallery permission not granted.")
      }

      let semaphore = DispatchSemaphore(value: 0)
      var granted = false
      PHPhotoLibrary.requestAuthorization(for: .readWrite) { newStatus in
        granted = newStatus == .authorized || newStatus == .limited
        semaphore.signal()
      }
      semaphore.wait()
      if !granted {
        throw ScannerError.invalidArgument("Gallery permission not granted.")
      }
      return
    }

    let status = PHPhotoLibrary.authorizationStatus()
    if status == .authorized {
      return
    }
    if status == .denied || status == .restricted {
      throw ScannerError.invalidArgument("Gallery permission not granted.")
    }
    let semaphore = DispatchSemaphore(value: 0)
    var granted = false
    PHPhotoLibrary.requestAuthorization { newStatus in
      granted = newStatus == .authorized
      semaphore.signal()
    }
    semaphore.wait()
    if !granted {
      throw ScannerError.invalidArgument("Gallery permission not granted.")
    }
  }

  private func resolvePhotoAsset(from assetRef: String) throws -> PHAsset {
    try ensurePhotoAccess()
    let localIdentifier = normalizedLocalIdentifier(from: assetRef)
    let fetched = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
    guard let asset = fetched.firstObject else {
      throw ScannerError.assetMissing("Asset not found: \(assetRef)")
    }
    return asset
  }

  private func normalizedLocalIdentifier(from assetRef: String) -> String {
    let trimmed = assetRef.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("ph://") {
      return String(trimmed.dropFirst("ph://".count))
    }
    return trimmed
  }

  private func resolveLocalFilePath(from assetRef: String) -> String? {
    let trimmed = assetRef.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return nil
    }
    if trimmed.hasPrefix("/") && FileManager.default.fileExists(atPath: trimmed) {
      return trimmed
    }
    if trimmed.lowercased().hasPrefix("file://"), let url = URL(string: trimmed) {
      let candidate = url.path
      if FileManager.default.fileExists(atPath: candidate) {
        return candidate
      }
    }
    return nil
  }

  private func ensureCacheDirectory(named name: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("flutter_nsfw_scaner", isDirectory: true)
    let directory = root.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: nil
    )
    return directory
  }

  private static func stableHash(_ value: String) -> String {
    var hash: UInt64 = 1469598103934665603
    for byte in value.utf8 {
      hash ^= UInt64(byte)
      hash = hash &* 1099511628211
    }
    return String(format: "%016llx", hash)
  }

  private func writeJPEG(cgImage: CGImage, quality: Int, to url: URL) throws {
    let compression = CGFloat(quality.clamped(to: 30...95)) / 100.0
    let image = UIImage(cgImage: cgImage)
    guard let data = image.jpegData(compressionQuality: compression) else {
      throw ScannerError.invalidArgument("Failed to encode thumbnail image.")
    }
    try data.write(to: url, options: .atomic)
  }

  private func requestThumbnailImage(
    asset: PHAsset,
    manager: PHCachingImageManager,
    thumbnailSize: Int
  ) throws -> CGImage {
    if let imageData = try requestImageData(for: asset),
       let dataThumbnail = IOSNsfwScanner.decodeThumbnailFromImageData(
         imageData,
         targetMaxPixelSize: thumbnailSize
       ) {
      return dataThumbnail
    }

    // Fallback to UIImage request when direct data retrieval is unavailable.
    let requestOptions = PHImageRequestOptions()
    requestOptions.deliveryMode = .highQualityFormat
    requestOptions.resizeMode = .fast
    requestOptions.isSynchronous = false
    requestOptions.isNetworkAccessAllowed = true

    let semaphore = DispatchSemaphore(value: 0)
    var requestedImage: UIImage?
    var requestError: Error?

    manager.requestImage(
      for: asset,
      targetSize: CGSize(width: thumbnailSize, height: thumbnailSize),
      contentMode: .aspectFill,
      options: requestOptions
    ) { image, info in
      if let error = info?[PHImageErrorKey] as? Error {
        requestError = error
      }
      let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
      if let image, !degraded {
        requestedImage = image
      } else if requestedImage == nil, let image {
        requestedImage = image
      }
      if !degraded {
        semaphore.signal()
      }
    }
    semaphore.wait()

    if let requestError {
      throw requestError
    }
    if let cgImage = requestedImage?.cgImage {
      return cgImage
    }
    if let requestedImage {
      let renderSize = CGSize(width: thumbnailSize, height: thumbnailSize)
      let renderer = UIGraphicsImageRenderer(size: renderSize)
      let rendered = renderer.image { _ in
        requestedImage.draw(in: CGRect(origin: .zero, size: renderSize))
      }
      if let cgImage = rendered.cgImage {
        return cgImage
      }
    }
    throw ScannerError.invalidArgument("Unable to fetch thumbnail for asset \(asset.localIdentifier)")
  }

  private func requestUIImage(
    asset: PHAsset,
    manager: PHCachingImageManager,
    targetSize: CGSize
  ) throws -> UIImage {
    let requestOptions = PHImageRequestOptions()
    requestOptions.deliveryMode = .highQualityFormat
    requestOptions.resizeMode = .fast
    requestOptions.isSynchronous = false
    requestOptions.isNetworkAccessAllowed = true

    let safeWidth = max(1, min(targetSize.width, 4096))
    let safeHeight = max(1, min(targetSize.height, 4096))
    let semaphore = DispatchSemaphore(value: 0)
    var requestedImage: UIImage?
    var requestError: Error?

    manager.requestImage(
      for: asset,
      targetSize: CGSize(width: safeWidth, height: safeHeight),
      contentMode: .aspectFit,
      options: requestOptions
    ) { image, info in
      if let error = info?[PHImageErrorKey] as? Error {
        requestError = error
      }
      let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
      if let image, !degraded {
        requestedImage = image
      } else if requestedImage == nil, let image {
        requestedImage = image
      }
      if !degraded {
        semaphore.signal()
      }
    }
    semaphore.wait()

    if let requestError {
      throw requestError
    }
    if let requestedImage {
      return requestedImage
    }
    throw ScannerError.invalidArgument("Unable to fetch image for asset \(asset.localIdentifier)")
  }

  private func requestImageData(for asset: PHAsset) throws -> Data? {
    let requestOptions = PHImageRequestOptions()
    requestOptions.deliveryMode = .highQualityFormat
    requestOptions.resizeMode = .none
    requestOptions.isSynchronous = false
    requestOptions.isNetworkAccessAllowed = true
    requestOptions.version = .current

    let semaphore = DispatchSemaphore(value: 0)
    var resolvedData: Data?
    var requestError: Error?

    PHImageManager.default().requestImageDataAndOrientation(for: asset, options: requestOptions) { data, _, _, info in
      if let error = info?[PHImageErrorKey] as? Error {
        requestError = error
      }
      resolvedData = data
      semaphore.signal()
    }
    semaphore.wait()

    if let requestError {
      throw requestError
    }
    return resolvedData
  }

  private func resolveVideoPath(for asset: PHAsset) -> String? {
    let options = PHVideoRequestOptions()
    options.deliveryMode = .highQualityFormat
    options.isNetworkAccessAllowed = true

    let semaphore = DispatchSemaphore(value: 0)
    var resolvedPath: String?
    PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
      if let urlAsset = avAsset as? AVURLAsset {
        resolvedPath = urlAsset.url.path
      }
      semaphore.signal()
    }
    semaphore.wait()
    return resolvedPath
  }

  private func buildGalleryItemPayload(
    assetId: String,
    uri: String,
    path: String,
    type: String,
    imageResult: [String: Any]?,
    videoResult: [String: Any]?,
    error: String?
  ) -> [String: Any] {
    [
      "assetId": assetId,
      "uri": uri,
      "path": path,
      "type": type,
      "imageResult": imageResult ?? NSNull(),
      "videoResult": videoResult ?? NSNull(),
      "error": error ?? NSNull(),
    ]
  }

  private func buildGalleryLoadPayload(
    scanId: String,
    page: Int,
    scannedAssets: Int,
    imageCount: Int,
    videoCount: Int,
    targetCount: Int,
    isCompleted: Bool
  ) -> [String: Any] {
    [
      "eventType": "gallery_load_progress",
      "scanId": scanId,
      "page": page,
      "scannedAssets": scannedAssets,
      "imageCount": imageCount,
      "videoCount": videoCount,
      "targetCount": targetCount,
      "isCompleted": isCompleted,
    ]
  }

  private func buildGalleryScanProgressPayload(
    scanId: String,
    processed: Int,
    total: Int,
    imagePath: String?,
    error: String?,
    status: String,
    mediaType: String?
  ) -> [String: Any] {
    var payload = buildProgressPayload(
      scanId: scanId,
      processed: processed,
      total: total,
      imagePath: imagePath,
      error: error,
      status: status,
      mediaType: mediaType
    )
    payload["eventType"] = "gallery_scan_progress"
    return payload
  }

  private func buildGalleryResultBatchPayload(
    scanId: String,
    items: [[String: Any]],
    processed: Int,
    successCount: Int,
    errorCount: Int,
    flaggedCount: Int,
    processedTotal: Int,
    total: Int
  ) -> [String: Any] {
    let percent = total <= 0 ? 0.0 : min(1.0, max(0.0, Double(processedTotal) / Double(total)))
    return [
      "eventType": "gallery_result_batch",
      "scanId": scanId,
      "status": "running",
      "processed": processed,
      "processedTotal": processedTotal,
      "total": total,
      "percent": percent,
      "items": items,
      "successCount": successCount,
      "errorCount": errorCount,
      "flaggedCount": flaggedCount,
    ]
  }

  private func computeDynamicSampleRateFps(
    durationSeconds: Double,
    shortVideoMinSampleRateFps: Double,
    shortVideoMaxSampleRateFps: Double,
    mediumVideoMinutesThreshold: Int,
    longVideoMinutesThreshold: Int,
    mediumVideoSampleRateFps: Double,
    longVideoSampleRateFps: Double
  ) -> Double {
    let mediumThreshold = max(1, mediumVideoMinutesThreshold)
    let longThreshold = max(mediumThreshold + 1, longVideoMinutesThreshold)
    let durationMinutes = durationSeconds / 60.0

    let shortMin = max(0.2, min(30, shortVideoMinSampleRateFps))
    let shortMax = max(0.2, min(30, shortVideoMaxSampleRateFps))
    let shortLow = min(shortMin, shortMax)
    let shortHigh = max(shortMin, shortMax)
    let mediumRate = max(0.2, min(30, mediumVideoSampleRateFps))
    let longRate = max(0.2, min(30, longVideoSampleRateFps))

    let dynamicRate: Double
    if durationMinutes >= Double(longThreshold) {
      dynamicRate = longRate
    } else if durationMinutes >= Double(mediumThreshold) {
      dynamicRate = mediumRate
    } else {
      let progress = min(1.0, max(0.0, durationMinutes / Double(mediumThreshold)))
      dynamicRate = shortHigh - ((shortHigh - shortLow) * progress)
    }
    return max(0.2, min(30, dynamicRate))
  }

  private func runSingleScan(interpreter: Interpreter, imagePath: String, threshold: Float) throws -> [String: Any] {
    let inputData = try preprocessImage(imagePath: imagePath)
    try interpreter.copy(inputData, toInputAt: 0)
    try interpreter.invoke()

    let outputTensor = try interpreter.output(at: 0)
    let rawScores = try decodeOutput(outputTensor)

    return buildResultMap(imagePath: imagePath, rawScores: rawScores, threshold: threshold)
  }

  private func runSingleScan(
    interpreter: Interpreter,
    cgImage: CGImage,
    frameIdentity: String,
    threshold: Float
  ) throws -> [String: Any] {
    let inputData = try preprocessCGImage(cgImage)
    try interpreter.copy(inputData, toInputAt: 0)
    try interpreter.invoke()

    let outputTensor = try interpreter.output(at: 0)
    let rawScores = try decodeOutput(outputTensor)
    return buildResultMap(imagePath: frameIdentity, rawScores: rawScores, threshold: threshold)
  }

  private func preprocessImage(imagePath: String) throws -> Data {
    let decodedImage = try IOSNsfwScanner.decodeDownsampledImage(
      imagePath: imagePath,
      targetWidth: inputWidth,
      targetHeight: inputHeight
    )
    return try preprocessCGImage(decodedImage)
  }

  private func preprocessCGImage(_ image: CGImage) throws -> Data {
    // Preserve full image content (no center crop) for better NSFW recall.
    let resized = try IOSNsfwScanner.resizeImage(image, width: inputWidth, height: inputHeight)
    let rgba = try IOSNsfwScanner.rgbaBytes(from: resized, width: inputWidth, height: inputHeight)

    let pixelCount = inputWidth * inputHeight

    switch inputType {
    case .float32:
      var values = [Float](repeating: 0, count: pixelCount * inputChannels)
      var targetIndex = 0

      for pixelIndex in 0..<pixelCount {
        let base = pixelIndex * 4
        let r = normalizeChannel(rgba[base])
        let g = normalizeChannel(rgba[base + 1])
        let b = normalizeChannel(rgba[base + 2])

        values[targetIndex] = r
        values[targetIndex + 1] = g
        values[targetIndex + 2] = b
        targetIndex += inputChannels
      }

      return values.withUnsafeBufferPointer { Data(buffer: $0) }

    case .uInt8:
      var values = [UInt8](repeating: 0, count: pixelCount * inputChannels)
      var targetIndex = 0

      for pixelIndex in 0..<pixelCount {
        let base = pixelIndex * 4
        values[targetIndex] = quantizeToUInt8(normalizeChannel(rgba[base]))
        values[targetIndex + 1] = quantizeToUInt8(normalizeChannel(rgba[base + 1]))
        values[targetIndex + 2] = quantizeToUInt8(normalizeChannel(rgba[base + 2]))
        targetIndex += inputChannels
      }

      return values.withUnsafeBufferPointer { Data(buffer: $0) }

    default:
      throw ScannerError.unsupportedTensorType("Unsupported input tensor type: \(inputType)")
    }
  }

  private func decodeOutput(_ tensor: Tensor) throws -> [Float] {
    switch outputType {
    case .float32:
      let count = tensor.data.count / MemoryLayout<Float>.size
      return tensor.data.withUnsafeBytes { rawBuffer in
        let floatBuffer = rawBuffer.bindMemory(to: Float.self)
        return Array(floatBuffer.prefix(count))
      }

    case .uInt8:
      let bytes = [UInt8](tensor.data)
      return bytes.prefix(outputElementCount).map { value in
        if outputScale > 0 {
          return (Float(value) - Float(outputZeroPoint)) * outputScale
        }
        return Float(value) / 255
      }

    default:
      throw ScannerError.unsupportedTensorType("Unsupported output tensor type: \(outputType)")
    }
  }

  private func buildResultMap(imagePath: String, rawScores: [Float], threshold: Float) -> [String: Any] {
    let probabilities = toProbabilities(rawScores)
    let labelList = resolveLabelList(for: probabilities.count)

    let topPair = probabilities.enumerated().max(by: { $0.element < $1.element })
    let topIndex = topPair?.offset ?? 0
    let topScore = topPair?.element ?? 0

    let nsfwIndices = resolveNsfwIndices(labels: labelList)
    let safeIndices = resolveSafeIndices(labels: labelList)
    let normalizedLabels = labelList.map { $0.lowercased() }

    func findIndex(_ keywords: [String]) -> Int? {
      normalizedLabels.firstIndex { label in
        keywords.contains { keyword in label.contains(keyword) }
      }
    }

    let pornIdx = findIndex(["porn"])
    let hentaiIdx = findIndex(["hentai"])
    let sexyIdx = findIndex(["sexy"])
    let explicitIdx = findIndex(["explicit", "sexual", "adult"])

    let pornScore = pornIdx.map { probabilities.indices.contains($0) ? probabilities[$0] : 0 } ?? 0
    let hentaiScore = hentaiIdx.map { probabilities.indices.contains($0) ? probabilities[$0] : 0 } ?? 0
    let sexyScore = sexyIdx.map { probabilities.indices.contains($0) ? probabilities[$0] : 0 } ?? 0
    let explicitScore = explicitIdx.map { probabilities.indices.contains($0) ? probabilities[$0] : 0 } ?? 0

    let nsfwScore: Float
    if probabilities.count == 1 {
      nsfwScore = probabilities[0]
    } else if pornIdx != nil || hentaiIdx != nil || sexyIdx != nil || explicitIdx != nil {
      // Calibrated for typical NSFW-5 outputs:
      // porn/hentai are stronger indicators, sexy is weaker.
      nsfwScore = max(
        0,
        min(
          1,
          pornScore + (0.9 * hentaiScore) + (0.35 * sexyScore) + (0.6 * explicitScore)
        )
      )
    } else if !nsfwIndices.isEmpty {
      let sum = nsfwIndices.reduce(0.0) { partial, index in
        partial + Double(probabilities.indices.contains(index) ? probabilities[index] : 0)
      }
      nsfwScore = max(0, min(1, Float(sum)))
    } else {
      nsfwScore = topScore
    }

    let safeScore: Float
    if probabilities.count == 1 {
      safeScore = max(0, min(1, 1 - nsfwScore))
    } else if !safeIndices.isEmpty {
      let sum = safeIndices.reduce(0.0) { partial, index in
        partial + Double(probabilities.indices.contains(index) ? probabilities[index] : 0)
      }
      safeScore = max(0, min(1, Float(sum)))
    } else {
      safeScore = max(0, min(1, 1 - nsfwScore))
    }

    var scoreMap = [String: Double]()
    for (index, label) in labelList.enumerated() where index < probabilities.count {
      scoreMap[label] = Double(probabilities[index])
    }

    let explicitClassScore = max(pornScore, max(hentaiScore, explicitScore))
    let explicitClassFloor = max(0.25, threshold * 0.58)
    let isNsfw = nsfwScore >= threshold || explicitClassScore >= explicitClassFloor

    return [
      "imagePath": imagePath,
      "nsfwScore": Double(nsfwScore),
      "safeScore": Double(safeScore),
      "isNsfw": isNsfw,
      "topLabel": labelList.indices.contains(topIndex) ? labelList[topIndex] : "",
      "topScore": Double(topScore),
      "scores": scoreMap,
    ]
  }

  private func buildErrorResult(imagePath: String, error: Error) -> [String: Any] {
    [
      "imagePath": imagePath,
      "nsfwScore": 0.0,
      "safeScore": 0.0,
      "isNsfw": false,
      "topLabel": "",
      "topScore": 0.0,
      "scores": [String: Double](),
      "error": (error as NSError).localizedDescription,
    ]
  }

  private func buildProgressPayload(
    scanId: String,
    processed: Int,
    total: Int,
    imagePath: String?,
    error: String?,
    status: String,
    mediaType: String? = nil
  ) -> [String: Any] {
    let percent: Double
    if total <= 0 {
      percent = 0
    } else {
      percent = max(0, min(1, Double(processed) / Double(total)))
    }

    return [
      "scanId": scanId,
      "processed": processed,
      "total": total,
      "percent": percent,
      "status": status,
      "imagePath": imagePath ?? NSNull(),
      "error": error ?? NSNull(),
      "mediaType": mediaType ?? NSNull(),
    ]
  }

  private func resolveLabelList(for size: Int) -> [String] {
    if labels.count == size {
      return labels
    }

    var resolved = [String]()
    resolved.reserveCapacity(size)

    for index in 0..<size {
      resolved.append(index < labels.count ? labels[index] : "class_\(index)")
    }

    return resolved
  }

  private func resolveNsfwIndices(labels: [String]) -> [Int] {
    let keywords = ["nsfw", "porn", "adult", "explicit", "sexy", "sexual", "hentai", "erotic"]
    let indices = labels.enumerated().compactMap { index, label -> Int? in
      let normalized = label.lowercased()
      return keywords.contains(where: { normalized.contains($0) }) ? index : nil
    }
    if !indices.isEmpty {
      return indices
    }
    return labels.count == 2 ? [1] : [max(0, labels.count - 1)]
  }

  private func resolveSafeIndices(labels: [String]) -> [Int] {
    let keywords = ["safe", "sfw", "neutral", "clean", "drawing", "drawings"]
    let indices = labels.enumerated().compactMap { index, label -> Int? in
      let normalized = label.lowercased()
      return keywords.contains(where: { normalized.contains($0) }) ? index : nil
    }
    return indices.isEmpty ? [0] : indices
  }

  private func toProbabilities(_ rawScores: [Float]) -> [Float] {
    guard !rawScores.isEmpty else {
      return [0]
    }

    if rawScores.count == 1 {
      let value = rawScores[0]
      if value >= 0 && value <= 1 {
        return [value]
      }
      let sigmoid = 1 / (1 + exp(-value))
      return [max(0, min(1, sigmoid))]
    }

    let hasOutOfRange = rawScores.contains { $0 < 0 || $0 > 1 }
    if hasOutOfRange {
      return softmax(rawScores)
    }

    let sum = rawScores.reduce(0, +)
    if sum <= 0 {
      return softmax(rawScores)
    }

    if sum >= 0.95 && sum <= 1.05 {
      return rawScores
    }

    return rawScores.map { $0 / sum }
  }

  private func softmax(_ values: [Float]) -> [Float] {
    let maxValue = values.max() ?? 0
    let exps = values.map { Foundation.exp(Double($0 - maxValue)) }
    let expSum = exps.reduce(0, +)

    if expSum <= 0 {
      return Array(repeating: 0, count: values.count)
    }

    return exps.map { Float($0 / expSum) }
  }

  private func normalizeChannel(_ byte: UInt8) -> Float {
    let zeroToOne = Float(byte) / 255
    switch inputNormalizationMode {
    case .zeroToOne:
      return zeroToOne
    case .minusOneToOne:
      return (zeroToOne * 2) - 1
    }
  }

  private func quantizeToUInt8(_ normalized: Float) -> UInt8 {
    let scale: Float = inputScale > 0 ? inputScale : (1 / 255)
    let quantized = Int(round((normalized / scale) + Float(inputZeroPoint))).clamped(to: 0...255)
    return UInt8(quantized)
  }

  private func buildVideoFrameTimes(
    durationSeconds: Double,
    sampleRateFps: Double,
    maxFrames: Int
  ) -> [Double] {
    let step = max(1.0 / 30.0, 1.0 / sampleRateFps)
    var times = [Double]()
    var current = 0.0

    while current <= durationSeconds {
      times.append(current)
      current += step
    }
    if times.isEmpty {
      times = [0.0]
    }

    let clampedMaxFrames = max(1, maxFrames)
    if times.count <= clampedMaxFrames {
      return times
    }

    var reduced = [Double]()
    reduced.reserveCapacity(clampedMaxFrames)
    let ratio = Double(times.count) / Double(clampedMaxFrames)
    for index in 0..<clampedMaxFrames {
      let sourceIndex = min(times.count - 1, Int(Double(index) * ratio))
      reduced.append(times[sourceIndex])
    }
    return reduced
  }

  private func resolveRequiredNsfwFrames(
    durationSeconds: Double,
    totalFrames: Int,
    enabled: Bool,
    baseFrames: Int,
    mediumBonus: Int,
    longBonus: Int,
    mediumThresholdMinutes: Int,
    longThresholdMinutes: Int,
    veryLongThresholdMinutes: Int,
    veryLongBonus: Int
  ) -> Int {
    if !enabled {
      return 1
    }
    let durationMinutes = durationSeconds / 60.0
    var required = max(3, baseFrames)
    if durationMinutes >= Double(max(1, mediumThresholdMinutes)) {
      required += max(0, mediumBonus)
    }
    if durationMinutes >= Double(max(mediumThresholdMinutes + 1, longThresholdMinutes)) {
      required += max(0, longBonus)
    }
    if durationMinutes >= Double(max(longThresholdMinutes + 1, veryLongThresholdMinutes)) {
      required += max(0, veryLongBonus)
    }
    return max(1, min(totalFrames, required))
  }

  private static func createInterpreter(modelData: Data, numThreads: Int) throws -> Interpreter {
    var options = Interpreter.Options()
    options.threadCount = numThreads
    return try Interpreter(modelData: modelData, options: options)
  }

  private static func loadAssetData(registrar: FlutterPluginRegistrar, path: String) throws -> Data {
    let key = registrar.lookupKey(forAsset: path)
    guard let resolvedPath = Bundle.main.path(forResource: key, ofType: nil) else {
      throw ScannerError.assetMissing("Asset not found: \(path)")
    }
    return try Data(contentsOf: URL(fileURLWithPath: resolvedPath), options: .mappedIfSafe)
  }

  private static func loadLabels(registrar: FlutterPluginRegistrar, path: String) throws -> [String] {
    let data = try loadAssetData(registrar: registrar, path: path)
    guard let content = String(data: data, encoding: .utf8) else {
      throw ScannerError.invalidArgument("Failed to parse labels file: \(path)")
    }

    return content
      .split(whereSeparator: \ .isNewline)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  private static func decodeDownsampledImage(
    imagePath: String,
    targetWidth: Int,
    targetHeight: Int
  ) throws -> CGImage {
    let imageURL = URL(fileURLWithPath: imagePath) as CFURL
    let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithURL(imageURL, sourceOptions) else {
      throw ScannerError.invalidArgument("Failed to create image source at path: \(imagePath)")
    }

    let maxPixelSize = max(targetWidth, targetHeight) * 2
    let thumbnailOptions: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
    ]

    guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
      throw ScannerError.invalidArgument("Failed to decode image at path: \(imagePath)")
    }

    return thumbnail
  }

  fileprivate static func decodeThumbnailFromImageData(
    _ imageData: Data,
    targetMaxPixelSize: Int
  ) -> CGImage? {
    let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithData(imageData as CFData, sourceOptions) else {
      return nil
    }
    let maxPixel = max(64, targetMaxPixelSize)
    let thumbnailOptions: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixel,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary)
  }

  private static func centerCropToAspectRatio(
    _ image: CGImage,
    targetWidth: Int,
    targetHeight: Int
  ) throws -> CGImage {
    let sourceWidth = image.width
    let sourceHeight = image.height
    if sourceWidth <= 0 || sourceHeight <= 0 {
      throw ScannerError.invalidArgument("Invalid image size: \(sourceWidth)x\(sourceHeight)")
    }

    let targetAspect = CGFloat(targetWidth) / CGFloat(targetHeight)
    let sourceAspect = CGFloat(sourceWidth) / CGFloat(sourceHeight)
    var cropRect = CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight)

    if sourceAspect > targetAspect {
      let cropWidth = Int((CGFloat(sourceHeight) * targetAspect).rounded(.down))
      cropRect.origin.x = CGFloat(max(0, (sourceWidth - cropWidth) / 2))
      cropRect.size.width = CGFloat(cropWidth)
    } else if sourceAspect < targetAspect {
      let cropHeight = Int((CGFloat(sourceWidth) / targetAspect).rounded(.down))
      cropRect.origin.y = CGFloat(max(0, (sourceHeight - cropHeight) / 2))
      cropRect.size.height = CGFloat(cropHeight)
    }

    guard let cropped = image.cropping(to: cropRect.integral) else {
      throw ScannerError.invalidArgument("Failed to crop image")
    }
    return cropped
  }

  private static func resizeImage(_ image: CGImage, width: Int, height: Int) throws -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
      throw ScannerError.invalidArgument("Failed to create resize context")
    }

    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    guard let resized = context.makeImage() else {
      throw ScannerError.invalidArgument("Failed to resize image")
    }
    return resized
  }

  private static func rgbaBytes(from image: CGImage, width: Int, height: Int) throws -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let colorSpace = CGColorSpaceCreateDeviceRGB()

    guard let context = CGContext(
      data: &bytes,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
      throw ScannerError.invalidArgument("Failed to create pixel context")
    }

    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return bytes
  }
}

private enum ScannerError: LocalizedError {
  case invalidArgument(String)
  case assetMissing(String)
  case unsupportedTensorType(String)
  case cancelled(String)

  var errorDescription: String? {
    switch self {
    case let .invalidArgument(message):
      return message
    case let .assetMissing(message):
      return message
    case let .unsupportedTensorType(message):
      return message
    case let .cancelled(message):
      return message
    }
  }
}

private extension Comparable {
  func clamped(to limits: ClosedRange<Self>) -> Self {
    min(max(self, limits.lowerBound), limits.upperBound)
  }
}
