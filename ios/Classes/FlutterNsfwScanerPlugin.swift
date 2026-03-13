import AVFoundation
import Flutter
import TensorFlowLite
import ImageIO
import Photos
import PhotosUI
import SQLite3
import UniformTypeIdentifiers
import UIKit

public class FlutterNsfwScanerPlugin: NSObject, FlutterPlugin, FlutterStreamHandler, PHPickerViewControllerDelegate {
  private let registrar: FlutterPluginRegistrar
  private let workerQueue = DispatchQueue(label: "flutter_nsfw_scaner.worker", qos: .userInitiated, attributes: .concurrent)
  private let scannerLock = NSLock()
  private let progressSinkLock = NSLock()
  private let cancelLock = NSLock()
  private var scanner: IOSNsfwScanner?
  private var progressSink: FlutterEventSink?
  private var cancelGeneration = 0
  private var cancelledScanIds = Set<String>()
  private var pendingPickerResult: FlutterResult?
  private var pendingPickerAllowImages = true
  private var pendingPickerAllowVideos = true
  private var pendingPickerMultiple = false
  private var galleryScanCachePrefix: String?
  private var galleryScanCacheTableName: String?

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
    case "getUploadRuntimeInfo":
      getUploadRuntimeInfo(result: result)
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
    case "pickMedia":
      pickMedia(call, result: result)
    case "checkMediaPermission":
      checkMediaPermission(result: result)
    case "requestMediaPermission":
      requestMediaPermission(result: result)
    case "getMediaPermissionStatus":
      getMediaPermissionStatus(result: result)
    case "presentLimitedLibraryPicker":
      presentLimitedLibraryPicker(result: result)
    case "resolveMediaAsset":
      resolveMediaAsset(call, result: result)
    case "listGalleryAssets":
      listGalleryAssets(call, result: result)
    case "cancelScan":
      cancelScan(call, result: result)
    case "resetGalleryScanCache":
      resetGalleryScanCache(result: result)
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
        let galleryScanCachePrefix = (args["galleryScanCachePrefix"] as? String)?
          .trimmingCharacters(in: .whitespacesAndNewlines)
        let galleryScanCacheTableName = (args["galleryScanCacheTableName"] as? String)?
          .trimmingCharacters(in: .whitespacesAndNewlines)

        let newScanner = try IOSNsfwScanner(
          registrar: self.registrar,
          modelAssetPath: modelAssetPath,
          labelsAssetPath: labelsAssetPath,
          numThreads: numThreads,
          inputNormalization: inputNormalization,
          galleryScanCachePrefix: galleryScanCachePrefix,
          galleryScanCacheTableName: galleryScanCacheTableName
        )

        self.galleryScanCachePrefix = galleryScanCachePrefix
        self.galleryScanCacheTableName = galleryScanCacheTableName

        self.scannerLock.lock()
        self.scanner = newScanner
        self.scannerLock.unlock()

        self.dispatchResult(result, value: nil)
      } catch {
        self.dispatchError(result, code: "INIT_FAILED", error: error)
      }
    }
  }

  private func getUploadRuntimeInfo(result: @escaping FlutterResult) {
    let info = Bundle.main.infoDictionary
    let buildVersion = (info?["CFBundleVersion"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let shortVersion = (info?["CFBundleShortVersionString"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedBuildVersion = [shortVersion, buildVersion]
      .compactMap { $0 }
      .filter { !$0.isEmpty }
      .joined(separator: "+")
    let deviceId = UIDevice.current.identifierForVendor?.uuidString.lowercased() ?? ""
    dispatchResult(result, value: [
      "buildVersion": resolvedBuildVersion.isEmpty ? "unknown" : resolvedBuildVersion,
      "deviceId": deviceId,
      "platform": "ios",
    ])
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

  private func resetGalleryScanCache(result: @escaping FlutterResult) {
    workerQueue.async {
      do {
        let prefix = self.galleryScanCachePrefix?.trimmingCharacters(in: .whitespacesAndNewlines)
        let tableName = self.galleryScanCacheTableName?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let store = try GalleryScanHistoryStore(
          prefix: prefix,
          tableName: tableName
        ) else {
          self.dispatchResult(result, value: nil)
          return
        }
        try store.reset()
        self.dispatchResult(result, value: nil)
      } catch {
        self.dispatchError(result, code: "RESET_GALLERY_SCAN_CACHE_FAILED", error: error)
      }
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

  private func pickMedia(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard #available(iOS 14, *) else {
      dispatchError(
        result,
        code: "PICKER_UNAVAILABLE",
        error: ScannerError.invalidArgument("Native media picker requires iOS 14 or newer")
      )
      return
    }

    guard let args = call.arguments as? [String: Any] else {
      dispatchError(result, code: "PICKER_FAILED", error: ScannerError.invalidArgument("Expected map arguments"))
      return
    }

    let allowImages = (args["allowImages"] as? Bool) ?? true
    let allowVideos = (args["allowVideos"] as? Bool) ?? true
    let multiple = (args["multiple"] as? Bool) ?? false

    if !allowImages && !allowVideos {
      dispatchResult(result, value: [
        "imagePaths": [String](),
        "videoPaths": [String](),
      ])
      return
    }

    DispatchQueue.main.async {
      if self.pendingPickerResult != nil {
        self.dispatchError(
          result,
          code: "PICKER_BUSY",
          error: ScannerError.invalidArgument("A picker operation is already in progress")
        )
        return
      }

      guard let presentingViewController = self.topViewController() else {
        self.dispatchError(
          result,
          code: "PICKER_UNAVAILABLE",
          error: ScannerError.invalidArgument("No foreground view controller available")
        )
        return
      }

      self.pendingPickerAllowImages = allowImages
      self.pendingPickerAllowVideos = allowVideos
      self.pendingPickerMultiple = multiple
      self.pendingPickerResult = result

      var configuration = PHPickerConfiguration(photoLibrary: .shared())
      configuration.selectionLimit = multiple ? 0 : 1
      if allowImages && allowVideos {
        configuration.filter = .any(of: [.images, .videos])
      } else if allowImages {
        configuration.filter = .images
      } else {
        configuration.filter = .videos
      }

      let picker = PHPickerViewController(configuration: configuration)
      picker.delegate = self
      presentingViewController.present(picker, animated: true)
    }
  }

  private func requestMediaPermission(result: @escaping FlutterResult) {
    if #available(iOS 14, *) {
      let currentStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
      switch currentStatus {
      case .authorized, .limited:
        dispatchResult(result, value: true)
      case .denied, .restricted:
        dispatchResult(result, value: false)
      case .notDetermined:
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
          let granted = status == .authorized || status == .limited
          self.dispatchResult(result, value: granted)
        }
      @unknown default:
        dispatchResult(result, value: false)
      }
      return
    }

    let status = PHPhotoLibrary.authorizationStatus()
    switch status {
    case .authorized:
      dispatchResult(result, value: true)
    case .denied, .restricted:
      dispatchResult(result, value: false)
    case .notDetermined:
      PHPhotoLibrary.requestAuthorization { newStatus in
        self.dispatchResult(result, value: newStatus == .authorized)
      }
    case .limited:
      dispatchResult(result, value: true)
    @unknown default:
      dispatchResult(result, value: false)
    }
  }

  private func checkMediaPermission(result: @escaping FlutterResult) {
    if #available(iOS 14, *) {
      let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
      let granted = status == .authorized || status == .limited
      dispatchResult(result, value: granted)
      return
    }
    let status = PHPhotoLibrary.authorizationStatus()
    dispatchResult(result, value: status == .authorized)
  }

  private func getMediaPermissionStatus(result: @escaping FlutterResult) {
    if #available(iOS 14, *) {
      let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
      dispatchResult(result, value: permissionStatusString(status))
      return
    }
    let status = PHPhotoLibrary.authorizationStatus()
    dispatchResult(result, value: permissionStatusStringLegacy(status))
  }

  private func presentLimitedLibraryPicker(result: @escaping FlutterResult) {
    guard #available(iOS 14, *) else {
      dispatchResult(result, value: false)
      return
    }
    DispatchQueue.main.async {
      let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
      guard status == .limited else {
        self.dispatchResult(result, value: false)
        return
      }
      guard let presentingViewController = self.topViewController() else {
        self.dispatchResult(result, value: false)
        return
      }
      PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: presentingViewController)
      self.dispatchResult(result, value: true)
    }
  }

  @available(iOS 14, *)
  private func permissionStatusString(_ status: PHAuthorizationStatus) -> String {
    switch status {
    case .authorized:
      return "authorized"
    case .limited:
      return "limited"
    case .denied:
      return "denied"
    case .restricted:
      return "restricted"
    case .notDetermined:
      return "not_determined"
    @unknown default:
      return "unknown"
    }
  }

  private func permissionStatusStringLegacy(_ status: PHAuthorizationStatus) -> String {
    switch status {
    case .authorized:
      return "authorized"
    case .denied:
      return "denied"
    case .restricted:
      return "restricted"
    case .notDetermined:
      return "not_determined"
    case .limited:
      return "limited"
    @unknown default:
      return "unknown"
    }
  }

  private func resolveMediaAsset(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    workerQueue.async {
      do {
        guard let args = call.arguments as? [String: Any] else {
          throw ScannerError.invalidArgument("Expected map arguments")
        }
        let assetId = (args["assetId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !assetId.isEmpty else {
          throw ScannerError.invalidArgument("assetId is required")
        }
        let normalizedId = self.normalizeAssetIdentifier(assetId)
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [normalizedId], options: nil).firstObject else {
          self.dispatchResult(result, value: nil)
          return
        }

        let type: String
        switch asset.mediaType {
        case .video:
          type = "video"
        case .image:
          type = "image"
        default:
          self.dispatchResult(result, value: nil)
          return
        }

        let path = try self.resolveAssetFilePath(asset: asset, preferredType: type)
        self.dispatchResult(result, value: [
          "id": normalizedId,
          "type": type,
          "path": path,
        ])
      } catch {
        self.dispatchError(result, code: "RESOLVE_ASSET_FAILED", error: error)
      }
    }
  }

  private func listGalleryAssets(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    workerQueue.async {
      do {
        guard let args = call.arguments as? [String: Any] else {
          throw ScannerError.invalidArgument("Expected map arguments")
        }
        let start = max(0, (args["start"] as? NSNumber)?.intValue ?? 0)
        let end = max(start + 1, (args["end"] as? NSNumber)?.intValue ?? (start + 200))
        let includeImages = (args["includeImages"] as? Bool) ?? true
        let includeVideos = (args["includeVideos"] as? Bool) ?? true
        if !includeImages && !includeVideos {
          self.dispatchResult(result, value: [
            "items": [[String: Any]](),
            "totalAssets": 0,
            "scannedAssets": 0,
          ])
          return
        }

        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        options.includeAllBurstAssets = true
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let fetched = PHAsset.fetchAssets(with: options)
        var items = [[String: Any]]()
        var totalAssets = 0
        var scannedAssets = 0
        fetched.enumerateObjects { asset, index, _ in
          let type: String
          if asset.mediaType == .image {
            if !includeImages { return }
            type = "image"
          } else if asset.mediaType == .video {
            if !includeVideos { return }
            type = "video"
          } else {
            return
          }

          totalAssets += 1
          if totalAssets <= start || totalAssets > end {
            return
          }
          scannedAssets += 1
          let durationSeconds = Int(max(0, round(asset.duration)))
          let created = Int(asset.creationDate?.timeIntervalSince1970 ?? 0)
          let modified = Int(asset.modificationDate?.timeIntervalSince1970 ?? 0)
          items.append([
            "id": asset.localIdentifier,
            "type": type,
            "width": asset.pixelWidth,
            "height": asset.pixelHeight,
            "durationSeconds": durationSeconds,
            "createDateSecond": created,
            "modifiedDateSecond": modified,
          ])
        }

        self.dispatchResult(result, value: [
          "items": items,
          "totalAssets": totalAssets,
          "scannedAssets": scannedAssets,
        ])
      } catch {
        self.dispatchError(result, code: "LIST_GALLERY_ASSETS_FAILED", error: error)
      }
    }
  }

  @available(iOS 14, *)
  public func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)

    guard let flutterResult = pendingPickerResult else {
      return
    }
    pendingPickerResult = nil

    if results.isEmpty {
      dispatchResult(flutterResult, value: nil)
      return
    }

    let imageType = UTType.image.identifier
    let videoType = UTType.movie.identifier
    let lock = NSLock()
    let group = DispatchGroup()
    var imagePaths = [String]()
    var videoPaths = [String]()

    for item in results {
      let provider = item.itemProvider
      if pendingPickerAllowVideos && provider.hasItemConformingToTypeIdentifier(videoType) {
        group.enter()
        provider.loadFileRepresentation(forTypeIdentifier: videoType) { url, _ in
          defer { group.leave() }
          guard let url, let copiedPath = self.copyPickedFileToCache(sourceURL: url, suffixHint: "mov") else {
            return
          }
          lock.lock()
          videoPaths.append(copiedPath)
          lock.unlock()
        }
        continue
      }

      if pendingPickerAllowImages && provider.hasItemConformingToTypeIdentifier(imageType) {
        group.enter()
        provider.loadFileRepresentation(forTypeIdentifier: imageType) { url, _ in
          defer { group.leave() }
          guard let url, let copiedPath = self.copyPickedFileToCache(sourceURL: url, suffixHint: "jpg") else {
            return
          }
          lock.lock()
          imagePaths.append(copiedPath)
          lock.unlock()
        }
      }
    }

    group.notify(queue: .main) {
      let uniqueImages = Array(NSOrderedSet(array: imagePaths)) as? [String] ?? []
      let uniqueVideos = Array(NSOrderedSet(array: videoPaths)) as? [String] ?? []
      if uniqueImages.isEmpty && uniqueVideos.isEmpty {
        self.dispatchResult(flutterResult, value: nil)
        return
      }
      self.dispatchResult(flutterResult, value: [
        "imagePaths": uniqueImages,
        "videoPaths": uniqueVideos,
      ])
    }
  }

  private func copyPickedFileToCache(sourceURL: URL, suffixHint: String) -> String? {
    do {
      let pickerDir = FileManager.default.temporaryDirectory.appendingPathComponent("picker_cache", isDirectory: true)
      try FileManager.default.createDirectory(at: pickerDir, withIntermediateDirectories: true)
      let destinationURL = pickerDir
        .appendingPathComponent("picked_\(UUID().uuidString)")
        .appendingPathExtension(suffixHint)
      if FileManager.default.fileExists(atPath: destinationURL.path) {
        try FileManager.default.removeItem(at: destinationURL)
      }
      try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
      return destinationURL.path
    } catch {
      return nil
    }
  }

  private func topViewController(base: UIViewController? = nil) -> UIViewController? {
    let root: UIViewController?
    if let base {
      root = base
    } else {
      root = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap { $0.windows }
        .first(where: { $0.isKeyWindow })?
        .rootViewController
    }
    if let navigation = root as? UINavigationController {
      return topViewController(base: navigation.visibleViewController)
    }
    if let tab = root as? UITabBarController {
      return topViewController(base: tab.selectedViewController)
    }
    if let presented = root?.presentedViewController {
      return topViewController(base: presented)
    }
    return root
  }

  private func normalizeAssetIdentifier(_ rawId: String) -> String {
    if rawId.hasPrefix("ph://") {
      return String(rawId.dropFirst(5))
    }
    return rawId
  }

  private func resolveAssetFilePath(asset: PHAsset, preferredType: String) throws -> String {
    if preferredType == "video" {
      return try resolveVideoAssetPath(asset: asset)
    }
    return try resolveImageAssetPath(asset: asset)
  }

  private func resolveImageAssetPath(asset: PHAsset) throws -> String {
    if let directPath = try resolveImageAssetPathUsingImageData(asset: asset) {
      return directPath
    }
    if let resourcePath = try resolveImageAssetPathUsingResourceDownload(asset: asset) {
      return resourcePath
    }
    if let renderedPath = try resolveImageAssetPathUsingRenderedImage(asset: asset) {
      return renderedPath
    }
    throw ScannerError.invalidArgument(
      "Unable to read image data for asset \(asset.localIdentifier). The asset may be unavailable, cloud-only, or restricted."
    )
  }

  private func resolveImageAssetPathUsingImageData(asset: PHAsset) throws -> String? {
    let options = PHImageRequestOptions()
    options.deliveryMode = .highQualityFormat
    options.resizeMode = .none
    options.isSynchronous = false
    options.isNetworkAccessAllowed = true
    options.version = .current

    let semaphore = DispatchSemaphore(value: 0)
    var resolvedData: Data?
    PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
      resolvedData = data
      semaphore.signal()
    }
    semaphore.wait()

    guard let resolvedData, !resolvedData.isEmpty else {
      return nil
    }
    return try writeAssetDataToTemp(data: resolvedData, preferredExtension: "jpg")
  }

  private func resolveImageAssetPathUsingResourceDownload(asset: PHAsset) throws -> String? {
    let resources = PHAssetResource.assetResources(for: asset)
    guard let resource = resources.first(where: { $0.type == .photo || $0.type == .fullSizePhoto }) ?? resources.first else {
      return nil
    }

    let options = PHAssetResourceRequestOptions()
    options.isNetworkAccessAllowed = true

    let semaphore = DispatchSemaphore(value: 0)
    var collectedData = Data()
    PHAssetResourceManager.default().requestData(
      for: resource,
      options: options,
      dataReceivedHandler: { chunk in
        collectedData.append(chunk)
      },
      completionHandler: { _ in
        semaphore.signal()
      }
    )
    semaphore.wait()

    guard !collectedData.isEmpty else {
      return nil
    }

    let ext = (resource.originalFilename as NSString).pathExtension
    return try writeAssetDataToTemp(
      data: collectedData,
      preferredExtension: ext.isEmpty ? "jpg" : ext
    )
  }

  private func resolveImageAssetPathUsingRenderedImage(asset: PHAsset) throws -> String? {
    let options = PHImageRequestOptions()
    options.deliveryMode = .highQualityFormat
    options.resizeMode = .exact
    options.isSynchronous = false
    options.isNetworkAccessAllowed = true
    options.version = .current

    let targetWidth = max(64, min(asset.pixelWidth, 4096))
    let targetHeight = max(64, min(asset.pixelHeight, 4096))

    let semaphore = DispatchSemaphore(value: 0)
    var requestedImage: UIImage?

    PHImageManager.default().requestImage(
      for: asset,
      targetSize: CGSize(width: targetWidth, height: targetHeight),
      contentMode: .aspectFit,
      options: options
    ) { image, info in
      let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
      if let image, !degraded {
        requestedImage = image
      } else if requestedImage == nil, let image {
        requestedImage = image
      }
      let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
      if !degraded || cancelled {
        semaphore.signal()
      }
    }
    semaphore.wait()

    guard let image = requestedImage,
          let data = image.jpegData(compressionQuality: 1.0),
          !data.isEmpty else {
      return nil
    }
    return try writeAssetDataToTemp(data: data, preferredExtension: "jpg")
  }

  private func writeAssetDataToTemp(data: Data, preferredExtension: String) throws -> String {
    let outDir = FileManager.default.temporaryDirectory.appendingPathComponent("asset_cache", isDirectory: true)
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let normalizedExt = preferredExtension.trimmingCharacters(in: .whitespacesAndNewlines)
    let ext = normalizedExt.isEmpty ? "jpg" : normalizedExt
    let out = outDir.appendingPathComponent("asset_\(UUID().uuidString).\(ext)")
    try data.write(to: out, options: .atomic)
    return out.path
  }

  private func resolveVideoAssetPath(asset: PHAsset) throws -> String {
    let resources = PHAssetResource.assetResources(for: asset)
    guard let resource = resources.first(where: { $0.type == .video || $0.type == .fullSizeVideo }) ?? resources.first else {
      throw ScannerError.invalidArgument("Unable to read video resource for asset \(asset.localIdentifier)")
    }
    let outDir = FileManager.default.temporaryDirectory.appendingPathComponent("asset_cache", isDirectory: true)
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let ext = (resource.originalFilename as NSString).pathExtension
    let out = outDir.appendingPathComponent("asset_\(UUID().uuidString).\(ext.isEmpty ? "mov" : ext)")
    let semaphore = DispatchSemaphore(value: 0)
    var writeError: Error?
    let requestOptions = PHAssetResourceRequestOptions()
    requestOptions.isNetworkAccessAllowed = true
    PHAssetResourceManager.default().writeData(
      for: resource,
      toFile: out,
      options: requestOptions
    ) { error in
      writeError = error
      semaphore.signal()
    }
    semaphore.wait()
    if let writeError {
      throw writeError
    }
    return out.path
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

private final class GalleryScanHistoryStore {
  private let dbURL: URL
  private let tableName: String
  private let lock = NSLock()

  init?(prefix: String?, tableName: String?) throws {
    let normalizedPrefix = GalleryScanHistoryStore.sanitizeFileComponent(prefix)
    let normalizedTableName = GalleryScanHistoryStore.sanitizeIdentifier(tableName)
    guard let normalizedPrefix, let normalizedTableName else {
      return nil
    }
    self.tableName = normalizedTableName
    let baseDirectory = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    ).appendingPathComponent("flutter_nsfw_scaner", isDirectory: true)
    try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
    self.dbURL = baseDirectory.appendingPathComponent("\(normalizedPrefix)_gallery_scan_cache.sqlite")
    try initialize()
  }

  func hasScanned(assetId: String) throws -> Bool {
    try lock.withLock {
      let db = try openDatabase()
      defer { sqlite3_close(db) }

      let sql = "SELECT 1 FROM \(tableName) WHERE asset_id = ? LIMIT 1;"
      var statement: OpaquePointer?
      guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
        throw lastError(db)
      }
      defer { sqlite3_finalize(statement) }
      sqlite3_bind_text(statement, 1, assetId, -1, SQLITE_TRANSIENT)
      return sqlite3_step(statement) == SQLITE_ROW
    }
  }

  func loadAllScannedAssetIds() throws -> Set<String> {
    try lock.withLock {
      let db = try openDatabase()
      defer { sqlite3_close(db) }

      let sql = "SELECT asset_id FROM \(tableName);"
      var statement: OpaquePointer?
      guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
        throw lastError(db)
      }
      defer { sqlite3_finalize(statement) }

      var ids = Set<String>()
      while sqlite3_step(statement) == SQLITE_ROW {
        if let rawValue = sqlite3_column_text(statement, 0) {
          ids.insert(String(cString: rawValue))
        }
      }
      return ids
    }
  }

  func markScanned(assetId: String) throws {
    try markScanned(assetIds: [assetId])
  }

  func markScanned(assetIds: [String]) throws {
    if assetIds.isEmpty {
      return
    }
    try lock.withLock {
      let db = try openDatabase()
      defer { sqlite3_close(db) }

      guard sqlite3_exec(db, "BEGIN IMMEDIATE TRANSACTION;", nil, nil, nil) == SQLITE_OK else {
        throw lastError(db)
      }
      var shouldCommit = false
      defer {
        let sql = shouldCommit ? "COMMIT;" : "ROLLBACK;"
        sqlite3_exec(db, sql, nil, nil, nil)
      }

      let sql = """
        INSERT INTO \(tableName) (asset_id, scanned_at_epoch_ms)
        VALUES (?, ?)
        ON CONFLICT(asset_id) DO UPDATE SET scanned_at_epoch_ms = excluded.scanned_at_epoch_ms;
        """
      var statement: OpaquePointer?
      guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
        throw lastError(db)
      }
      defer { sqlite3_finalize(statement) }

      let scannedAt = Int64(Date().timeIntervalSince1970 * 1000)
      for assetId in assetIds {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        sqlite3_bind_text(statement, 1, assetId, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(statement, 2, scannedAt)
        guard sqlite3_step(statement) == SQLITE_DONE else {
          throw lastError(db)
        }
      }
      shouldCommit = true
    }
  }

  func reset() throws {
    try lock.withLock {
      let db = try openDatabase()
      defer { sqlite3_close(db) }
      let sql = "DELETE FROM \(tableName);"
      guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
        throw lastError(db)
      }
    }
  }

  private func initialize() throws {
    let db = try openDatabase()
    defer { sqlite3_close(db) }
    let sql = """
      CREATE TABLE IF NOT EXISTS \(tableName) (
        asset_id TEXT PRIMARY KEY NOT NULL,
        scanned_at_epoch_ms INTEGER NOT NULL
      );
      """
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
      throw lastError(db)
    }
  }

  private func openDatabase() throws -> OpaquePointer? {
    var db: OpaquePointer?
    guard sqlite3_open_v2(
      dbURL.path,
      &db,
      SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
      nil
    ) == SQLITE_OK else {
      if let db {
        defer { sqlite3_close(db) }
        throw lastError(db)
      }
      throw ScannerError.invalidArgument("Failed to open gallery scan cache database.")
    }
    return db
  }

  private func lastError(_ db: OpaquePointer?) -> Error {
    let message = db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) }
      ?? "Unknown SQLite error"
    return ScannerError.invalidArgument(message)
  }

  private static func sanitizeIdentifier(_ rawValue: String?) -> String? {
    let normalized = (rawValue ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(
        of: "[^A-Za-z0-9_]+",
        with: "_",
        options: .regularExpression
      )
      .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    guard !normalized.isEmpty else { return nil }
    if let first = normalized.first, first.isNumber {
      return "t_\(normalized)"
    }
    return normalized
  }

  private static func sanitizeFileComponent(_ rawValue: String?) -> String? {
    let normalized = (rawValue ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(
        of: "[^A-Za-z0-9._-]+",
        with: "_",
        options: .regularExpression
      )
      .trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
    return normalized.isEmpty ? nil : normalized
  }
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
  private let galleryScanHistoryStore: GalleryScanHistoryStore?
  private let photoManager = PHCachingImageManager()
  private var videoDurationCache: [String: Double] = [:]
  private let videoDurationCacheLock = NSLock()

  init(
    registrar: FlutterPluginRegistrar,
    modelAssetPath: String,
    labelsAssetPath: String?,
    numThreads: Int,
    inputNormalization: InputNormalizationMode,
    galleryScanCachePrefix: String?,
    galleryScanCacheTableName: String?
  ) throws {
    self.modelData = try IOSNsfwScanner.loadAssetData(registrar: registrar, path: modelAssetPath)
    self.labels = try labelsAssetPath.map { try IOSNsfwScanner.loadLabels(registrar: registrar, path: $0) } ?? []
    self.numThreads = numThreads
    self.inputNormalizationMode = inputNormalization
    self.galleryScanHistoryStore = try GalleryScanHistoryStore(
      prefix: galleryScanCachePrefix,
      tableName: galleryScanCacheTableName
    )

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
    let cgImage = try requestThumbnailImage(
      asset: asset,
      manager: photoManager,
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
    let cachedCandidates = [
      "jpg",
      "jpeg",
      "png",
      "gif",
      "heic",
      "heif",
      "webp",
      "bmp",
    ].map { cacheDirectory.appendingPathComponent("asset_\(cacheKey).\($0)") }
    if let existing = cachedCandidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
      return existing.path
    }

    let resolvedPath = try resolveImageAssetPath(asset: asset)
    let resolvedURL = URL(fileURLWithPath: resolvedPath)
    let ext = preferredImageExtension(for: asset, fallbackPathExtension: resolvedURL.pathExtension)
    let outputURL = cacheDirectory.appendingPathComponent("asset_\(cacheKey).\(ext)")
    if FileManager.default.fileExists(atPath: outputURL.path) {
      return outputURL.path
    }
    if resolvedURL.path != outputURL.path {
      if FileManager.default.fileExists(atPath: outputURL.path) {
        try FileManager.default.removeItem(at: outputURL)
      }
      try FileManager.default.copyItem(at: resolvedURL, to: outputURL)
      return outputURL.path
    }
    return resolvedPath
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
    let assetOptions: [String: Any] = [AVURLAssetPreferPreciseDurationAndTimingKey: false]
    let videoURL = URL(fileURLWithPath: videoPath)
    let asset = AVURLAsset(url: videoURL, options: assetOptions)
    let resolvedDurationSeconds = resolveVideoDurationSeconds(asset: asset)

    let effectiveSampleRate: Double
    let frameTimes: [Double]
    let requiredNsfwFrames: Int
    if let durationSeconds = resolvedDurationSeconds, durationSeconds > 0 {
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
      frameTimes = buildVideoFrameTimes(
        durationSeconds: durationSeconds,
        sampleRateFps: effectiveSampleRate,
        maxFrames: maxFrames
      )
      requiredNsfwFrames = resolveRequiredNsfwFrames(
        durationSeconds: durationSeconds,
        totalFrames: max(1, frameTimes.count),
        enabled: videoEarlyStopEnabled,
        baseFrames: videoEarlyStopBaseNsfwFrames,
        mediumBonus: videoEarlyStopMediumBonusFrames,
        longBonus: videoEarlyStopLongBonusFrames,
        mediumThresholdMinutes: mediumVideoMinutesThreshold,
        longThresholdMinutes: longVideoMinutesThreshold,
        veryLongThresholdMinutes: videoEarlyStopVeryLongMinutesThreshold,
        veryLongBonus: videoEarlyStopVeryLongBonusFrames
      )
    } else {
      // Some cloud/mutated videos fail direct duration probing.
      // Fallback to at least one frame at t=0 instead of failing the asset.
      effectiveSampleRate = max(0.2, min(30, Double(sampleRateFps)))
      frameTimes = [0.0]
      requiredNsfwFrames = 1
    }
    let totalFrames = max(1, frameTimes.count)
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
            let resolvedVideoPath = try self.resolveVideoScanPath(from: item.path)
            let videoResult = try self.scanVideo(
              scanId: "\(scanId)_item_\(index)",
              videoPath: resolvedVideoPath,
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
            let imageResult = try self.runImageScan(
              interpreter: imageInterpreter,
              assetRefOrPath: item.path,
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
    let scannedAssetIds: [String]
    let deferredRetryItems: [GalleryAssetItem]
  }

  private final class GalleryScanContext {
    let imageManager = PHCachingImageManager()
    let workerCount: Int
    private let poolLock = NSLock()
    private var imageInterpreterPool: [Interpreter]

    init(modelData: Data, numThreads: Int, workerCount: Int) throws {
      self.workerCount = workerCount
      self.imageInterpreterPool = []
      imageInterpreterPool.reserveCapacity(workerCount)
      for _ in 0..<workerCount {
        let interpreter = try IOSNsfwScanner.createInterpreter(
          modelData: modelData,
          numThreads: numThreads
        )
        try interpreter.allocateTensors()
        imageInterpreterPool.append(interpreter)
      }
    }

    func borrowImageInterpreter() -> Interpreter? {
      poolLock.lock()
      defer { poolLock.unlock() }
      guard !imageInterpreterPool.isEmpty else {
        return nil
      }
      return imageInterpreterPool.removeLast()
    }

    func returnImageInterpreter(_ interpreter: Interpreter) {
      poolLock.lock()
      imageInterpreterPool.append(interpreter)
      poolLock.unlock()
    }
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
    let preferThumbnailForImages = (settings["preferThumbnailForImages"] as? Bool) ?? true
    let pageSize = ((settings["pageSize"] as? NSNumber)?.intValue ?? 200).clamped(to: 20...2000)
    let startPage = max(0, (settings["startPage"] as? NSNumber)?.intValue ?? 0)
    let maxPagesRaw = (settings["maxPages"] as? NSNumber)?.intValue
    let maxPages = (maxPagesRaw ?? 0) > 0 ? maxPagesRaw! : nil
    let scanBatchSize = ((settings["scanChunkSize"] as? NSNumber)?.intValue ?? 100).clamped(to: 50...200)
    let thumbnailSize = ((settings["thumbnailSize"] as? NSNumber)?.intValue ?? 224).clamped(to: 128...512)
    let retryPasses = ((settings["retryPasses"] as? NSNumber)?.intValue ?? 2).clamped(to: 1...3)
    let retryDelayMs = ((settings["retryDelayMs"] as? NSNumber)?.intValue ?? 1400).clamped(to: 0...10000)
    let loadProgressEvery = ((settings["loadProgressEvery"] as? NSNumber)?.intValue ?? 100).clamped(to: 20...500)
    let maxRetainedResultItems = max(0, (settings["maxRetainedResultItems"] as? NSNumber)?.intValue ?? 4000)
    let maxItemsRaw = (settings["maxItems"] as? NSNumber)?.intValue
    let maxItems = (maxItemsRaw ?? 0) > 0 ? maxItemsRaw! : nil
    let cpuWorkers = max(1, ProcessInfo.processInfo.activeProcessorCount)
    let maxConcurrencySetting = (settings["maxConcurrency"] as? NSNumber)?.intValue ?? cpuWorkers
    let maxConcurrency = max(1, min(8, min(cpuWorkers, maxConcurrencySetting)))
    let galleryContext = try GalleryScanContext(
      modelData: modelData,
      numThreads: numThreads,
      workerCount: maxConcurrency
    )
    if debugLogging {
      NSLog("[flutter_nsfw_scaner][gallery:\(scanId)] start includeImages=\(includeImages) includeVideos=\(includeVideos) batchSize=\(scanBatchSize) maxConcurrency=\(maxConcurrency)")
    }

    let fetchOptions = PHFetchOptions()
    fetchOptions.includeHiddenAssets = true
    fetchOptions.includeAllBurstAssets = true
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
    var cachedAssetIds = Set<String>()
    if let galleryScanHistoryStore {
      cachedAssetIds = (try? galleryScanHistoryStore.loadAllScannedAssetIds()) ?? []
    }
    let totalDiscovered = assets.count
    let safeStartProduct = Int64(startPage) * Int64(pageSize)
    let startIndex = min(
      totalDiscovered,
      max(0, Int(min(Int64(totalDiscovered), max(0, safeStartProduct))))
    )
    let availableFromStart = max(0, totalDiscovered - startIndex)
    let rangeWindow: Int
    if let maxPages {
      let safeRangeProduct = Int64(maxPages) * Int64(pageSize)
      let requestedRange = max(0, Int(min(Int64(Int.max), safeRangeProduct)))
      rangeWindow = min(availableFromStart, requestedRange)
    } else {
      rangeWindow = availableFromStart
    }
    let totalTarget = min(rangeWindow, maxItems ?? rangeWindow)

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
    var skippedTotal = 0
    var didTruncateItems = false
    var page = 0
    var pendingRetryAssets: [GalleryAssetItem] = []

    func applyOutcome(_ outcome: GalleryBatchOutcome) {
      processedTotal += outcome.processed
      successTotal += outcome.successCount
      errorTotal += outcome.errorCount
      flaggedTotal += outcome.flaggedCount
      if !outcome.deferredRetryItems.isEmpty {
        pendingRetryAssets.append(contentsOf: outcome.deferredRetryItems)
      }
      if !outcome.streamedItems.isEmpty {
        let remainingCapacity = max(0, maxRetainedResultItems - finalItems.count)
        if remainingCapacity > 0 {
          finalItems.append(contentsOf: outcome.streamedItems.prefix(remainingCapacity))
        }
        if outcome.streamedItems.count > remainingCapacity {
          didTruncateItems = true
        }
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
          processed: processedTotal + skippedTotal,
          total: totalTarget,
          imagePath: nil,
          error: nil,
          status: "running",
          mediaType: nil
        )
      )
    }

    func flushBatch(deferRetryableFailures: Bool = true) throws {
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
        preferThumbnailForImages: preferThumbnailForImages,
        thumbnailSize: thumbnailSize,
        context: galleryContext,
        scanId: scanId,
        isCancelled: isCancelled,
        includeCleanResults: includeCleanResults,
        debugLogging: debugLogging,
        deferRetryableFailures: deferRetryableFailures
      )
      if debugLogging {
        NSLog(
          "[flutter_nsfw_scaner][gallery:\(scanId)] batch processed=\(outcome.processed) success=\(outcome.successCount) errors=\(outcome.errorCount) flagged=\(outcome.flaggedCount) deferredRetries=\(outcome.deferredRetryItems.count)"
        )
      }
      applyOutcome(outcome)
      if !outcome.scannedAssetIds.isEmpty {
        for assetId in outcome.scannedAssetIds {
          cachedAssetIds.insert(assetId)
        }
      }
    }

    var index = startIndex
    while scannedAssets < totalTarget && index < totalDiscovered {
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
      if cachedAssetIds.contains(asset.localIdentifier) {
        skippedTotal += 1
        continue
      }
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
    if !pendingRetryAssets.isEmpty {
      if debugLogging {
        NSLog(
          "[flutter_nsfw_scaner][gallery:\(scanId)] retry phase started deferredAssets=\(pendingRetryAssets.count) passes=\(retryPasses) delayMs=\(retryDelayMs)"
        )
      }
      var retryQueue = pendingRetryAssets
      pendingRetryAssets.removeAll(keepingCapacity: true)
      var pass = 1
      while !retryQueue.isEmpty && pass <= retryPasses {
        if isCancelled() {
          throw ScannerError.cancelled("Scan cancelled")
        }
        if retryDelayMs > 0 {
          Thread.sleep(forTimeInterval: Double(retryDelayMs) / 1000.0)
        }
        var nextRetryQueue: [GalleryAssetItem] = []
        var retryCursor = 0
        while retryCursor < retryQueue.count {
          if isCancelled() {
            throw ScannerError.cancelled("Scan cancelled")
          }
          let end = min(retryCursor + scanBatchSize, retryQueue.count)
          let retryBatch = Array(retryQueue[retryCursor..<end])
          let allowDeferAgain = pass < retryPasses
          let outcome = try processGalleryBatch(
            batch: retryBatch,
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
            preferThumbnailForImages: preferThumbnailForImages,
            thumbnailSize: thumbnailSize,
            context: galleryContext,
            scanId: "\(scanId)_retry_\(pass)",
            isCancelled: isCancelled,
            includeCleanResults: includeCleanResults,
            debugLogging: debugLogging,
            deferRetryableFailures: allowDeferAgain
          )
          if !outcome.deferredRetryItems.isEmpty {
            nextRetryQueue.append(contentsOf: outcome.deferredRetryItems)
          }
          if debugLogging {
            NSLog(
              "[flutter_nsfw_scaner][gallery:\(scanId)] retry pass=\(pass) batch processed=\(outcome.processed) success=\(outcome.successCount) errors=\(outcome.errorCount) flagged=\(outcome.flaggedCount) deferred=\(outcome.deferredRetryItems.count)"
            )
          }
          applyOutcome(outcome)
          retryCursor = end
        }
        retryQueue = nextRetryQueue
        pass += 1
      }
    }
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
        processed: processedTotal + skippedTotal,
        total: totalTarget,
        imagePath: nil,
        error: nil,
        status: "completed",
        mediaType: nil
      )
    )

    let payload: [String: Any] = [
      "items": finalItems,
      "processed": processedTotal + skippedTotal,
      "successCount": successTotal,
      "errorCount": errorTotal,
      "flaggedCount": flaggedTotal,
      "skippedCount": skippedTotal,
      "didTruncateItems": didTruncateItems,
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
    preferThumbnailForImages: Bool,
    thumbnailSize: Int,
    context: GalleryScanContext,
    scanId: String,
    isCancelled: @escaping () -> Bool,
    includeCleanResults: Bool,
    debugLogging: Bool,
    deferRetryableFailures: Bool
  ) throws -> GalleryBatchOutcome {
    if batch.isEmpty {
      return GalleryBatchOutcome(
        allItems: [],
        streamedItems: [],
        processed: 0,
        successCount: 0,
        errorCount: 0,
        flaggedCount: 0,
        scannedAssetIds: [],
        deferredRetryItems: []
      )
    }
    if isCancelled() {
      throw ScannerError.cancelled("Scan cancelled")
    }

    let workerCount = max(1, min(maxConcurrency, min(context.workerCount, batch.count)))
    let resultLock = NSLock()
    let fatalLock = NSLock()
    let retryLock = NSLock()

    var firstFatalError: Error?
    var orderedResults = Array(repeating: [String: Any](), count: batch.count)
    var deferredRetryItems: [GalleryAssetItem] = []
    var scannedAssetIds = [String]()

    let operationQueue = OperationQueue()
    operationQueue.qualityOfService = .userInitiated
    operationQueue.maxConcurrentOperationCount = workerCount
    let group = DispatchGroup()
    let imageAssets = batch.filter { $0.type == "image" }.map(\.asset)
    if !imageAssets.isEmpty {
      context.imageManager.startCachingImages(
        for: imageAssets,
        targetSize: CGSize(width: thumbnailSize, height: thumbnailSize),
        contentMode: .aspectFill,
        options: nil
      )
    }
    defer {
      if !imageAssets.isEmpty {
        context.imageManager.stopCachingImages(
          for: imageAssets,
          targetSize: CGSize(width: thumbnailSize, height: thumbnailSize),
          contentMode: .aspectFill,
          options: nil
        )
      }
    }

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
              let identityPath = "ph://\(item.assetId)"
              do {
                let videoPath: String
                if let resolvedVideoPath = try self.resolveVideoPath(for: item.asset) {
                  videoPath = resolvedVideoPath
                } else {
                  // Fallback for cloud-backed videos where AVAsset URL is not immediately available.
                  videoPath = try self.resolveVideoAssetPath(asset: item.asset)
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
                  uri: identityPath,
                  path: videoPath,
                  type: item.type,
                  imageResult: nil,
                  videoResult: videoResult,
                  error: nil
                )
              } catch {
                guard let videoFallbackResult = try? self.scanVideoWithThumbnailFallback(
                  asset: item.asset,
                  assetId: item.assetId,
                  threshold: videoThreshold,
                  thumbnailSize: thumbnailSize
                ) else {
                  throw error
                }
                payload = self.buildGalleryItemPayload(
                  assetId: item.assetId,
                  uri: identityPath,
                  path: identityPath,
                  type: item.type,
                  imageResult: nil,
                  videoResult: videoFallbackResult,
                  error: nil
                )
              }
            } else {
              var borrowedInterpreter: Interpreter?
              borrowedInterpreter = context.borrowImageInterpreter()

              guard let interpreter = borrowedInterpreter else {
                throw ScannerError.invalidArgument("No interpreter available")
              }

              defer {
                context.returnImageInterpreter(interpreter)
              }

              let identityPath = "ph://\(item.assetId)"
              let imageResult: [String: Any]
              var resolvedPathForPayload = identityPath
              if preferThumbnailForImages {
                do {
                  let image = try self.requestThumbnailImage(
                    asset: item.asset,
                    manager: context.imageManager,
                    thumbnailSize: thumbnailSize
                  )
                  imageResult = try self.runSingleScan(
                    interpreter: interpreter,
                    cgImage: image,
                    frameIdentity: identityPath,
                    threshold: imageThreshold
                  )
                } catch {
                  // If thumbnail extraction fails, try full asset materialization to local cache.
                  let localImagePath = try self.resolveImageAssetPath(asset: item.asset)
                  imageResult = try self.runSingleScan(
                    interpreter: interpreter,
                    imagePath: localImagePath,
                    threshold: imageThreshold
                  )
                  resolvedPathForPayload = localImagePath
                }
              } else {
                do {
                  let localImagePath = try self.resolveImageAssetPath(asset: item.asset)
                  imageResult = try self.runSingleScan(
                    interpreter: interpreter,
                    imagePath: localImagePath,
                    threshold: imageThreshold
                  )
                  resolvedPathForPayload = localImagePath
                } catch {
                  // Fallback to thumbnail scanning if full asset materialization fails.
                  let image = try self.requestThumbnailImage(
                    asset: item.asset,
                    manager: context.imageManager,
                    thumbnailSize: thumbnailSize
                  )
                  imageResult = try self.runSingleScan(
                    interpreter: interpreter,
                    cgImage: image,
                    frameIdentity: identityPath,
                    threshold: imageThreshold
                  )
                }
              }
              payload = self.buildGalleryItemPayload(
                assetId: item.assetId,
                uri: identityPath,
                path: resolvedPathForPayload,
                type: item.type,
                imageResult: imageResult,
                videoResult: nil,
                error: nil
              )
            }

            resultLock.lock()
            orderedResults[index] = payload
            scannedAssetIds.append(item.assetId)
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
            if deferRetryableFailures && self.isRetryableGalleryAssetError(error) {
              retryLock.lock()
              deferredRetryItems.append(item)
              retryLock.unlock()
              return
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

    if !scannedAssetIds.isEmpty {
      try? galleryScanHistoryStore?.markScanned(assetIds: scannedAssetIds)
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
      flaggedCount: flaggedCount,
      scannedAssetIds: scannedAssetIds,
      deferredRetryItems: deferredRetryItems
    )
  }

  private func isRetryableGalleryAssetError(_ error: Error) -> Bool {
    let nsError = error as NSError
    if nsError.domain == "PHPhotosErrorDomain" {
      return true
    }
    let message = nsError.localizedDescription.lowercased()
    if message.contains("icloud") ||
      message.contains("cloud") ||
      message.contains("network") ||
      message.contains("tempor") ||
      message.contains("not available") ||
      message.contains("unable to fetch") ||
      message.contains("resource") {
      return true
    }
    return false
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

  private func resolveVideoScanPath(from assetRefOrPath: String) throws -> String {
    if let localPath = resolveLocalFilePath(from: assetRefOrPath) {
      return localPath
    }
    let asset = try resolvePhotoAsset(from: assetRefOrPath)
    if let resolvedPath = try resolveVideoPath(for: asset) {
      return resolvedPath
    }
    return try resolveVideoAssetPath(asset: asset)
  }

  private func runImageScan(
    interpreter: Interpreter,
    assetRefOrPath: String,
    threshold: Float
  ) throws -> [String: Any] {
    if let localPath = resolveLocalFilePath(from: assetRefOrPath) {
      return try runSingleScan(
        interpreter: interpreter,
        imagePath: localPath,
        threshold: threshold
      )
    }

    let asset = try resolvePhotoAsset(from: assetRefOrPath)
    let thumbnail = try requestThumbnailImage(
      asset: asset,
      manager: photoManager,
      thumbnailSize: max(inputWidth, inputHeight)
    )
    return try runSingleScan(
      interpreter: interpreter,
      cgImage: thumbnail,
      frameIdentity: assetRefOrPath,
      threshold: threshold
    )
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
    var dataPathError: Error?
    do {
      if let imageData = try requestImageData(for: asset),
         let dataThumbnail = IOSNsfwScanner.decodeThumbnailFromImageData(
           imageData,
           targetMaxPixelSize: thumbnailSize
         ) {
        return dataThumbnail
      }
    } catch {
      // Some iCloud/restricted assets fail on direct data access.
      // Keep going and try UIImage fallback before giving up.
      dataPathError = error
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
    var wasCancelled = false

    manager.requestImage(
      for: asset,
      targetSize: CGSize(width: thumbnailSize, height: thumbnailSize),
      contentMode: .aspectFill,
      options: requestOptions
    ) { image, info in
      if let error = info?[PHImageErrorKey] as? Error {
        requestError = error
      }
      let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
      if cancelled {
        wasCancelled = true
      }
      let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
      if let image, !degraded {
        requestedImage = image
      } else if requestedImage == nil, let image {
        requestedImage = image
      }
      if !degraded || cancelled {
        semaphore.signal()
      }
    }
    semaphore.wait()

    if let requestError {
      if let dataPathError {
        throw ScannerError.invalidArgument(
          "Unable to fetch thumbnail for asset \(asset.localIdentifier): data path failed (\((dataPathError as NSError).localizedDescription)); image request failed (\((requestError as NSError).localizedDescription))"
        )
      }
      throw requestError
    }
    if wasCancelled, requestedImage == nil {
      throw ScannerError.invalidArgument(
        "Unable to fetch thumbnail for asset \(asset.localIdentifier): request cancelled"
      )
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
    if let dataPathError {
      throw ScannerError.invalidArgument(
        "Unable to fetch thumbnail for asset \(asset.localIdentifier): \((dataPathError as NSError).localizedDescription)"
      )
    }
    throw ScannerError.invalidArgument(
      "Unable to fetch thumbnail for asset \(asset.localIdentifier)"
    )
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
    var wasCancelled = false

    manager.requestImage(
      for: asset,
      targetSize: CGSize(width: safeWidth, height: safeHeight),
      contentMode: .aspectFit,
      options: requestOptions
    ) { image, info in
      if let error = info?[PHImageErrorKey] as? Error {
        requestError = error
      }
      let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
      if cancelled {
        wasCancelled = true
      }
      let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
      if let image, !degraded {
        requestedImage = image
      } else if requestedImage == nil, let image {
        requestedImage = image
      }
      if !degraded || cancelled {
        semaphore.signal()
      }
    }
    semaphore.wait()

    if let requestError {
      throw requestError
    }
    if wasCancelled, requestedImage == nil {
      throw ScannerError.invalidArgument(
        "Unable to fetch image for asset \(asset.localIdentifier): request cancelled"
      )
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
    var isInCloud = false

    PHImageManager.default().requestImageDataAndOrientation(for: asset, options: requestOptions) { data, _, _, info in
      if let error = info?[PHImageErrorKey] as? Error {
        requestError = error
      }
      if (info?[PHImageResultIsInCloudKey] as? Bool) == true {
        isInCloud = true
      }
      resolvedData = data
      semaphore.signal()
    }
    semaphore.wait()

    if let requestError {
      throw requestError
    }
    if (resolvedData == nil || resolvedData?.isEmpty == true), isInCloud {
      throw ScannerError.invalidArgument(
        "Unable to read image data for asset \(asset.localIdentifier): iCloud asset not yet materialized"
      )
    }
    return resolvedData
  }

  private func resolveImageAssetPath(asset: PHAsset) throws -> String {
    if let directPath = try resolveImageAssetPathUsingImageData(asset: asset) {
      return directPath
    }
    if let resourcePath = try resolveImageAssetPathUsingResourceDownload(asset: asset) {
      return resourcePath
    }
    if let renderedPath = try resolveImageAssetPathUsingRenderedImage(asset: asset) {
      return renderedPath
    }
    throw ScannerError.invalidArgument(
      "Unable to read image data for asset \(asset.localIdentifier). The asset may be unavailable, cloud-only, or restricted."
    )
  }

  private func resolveImageAssetPathUsingImageData(asset: PHAsset) throws -> String? {
    guard let data = try requestImageData(for: asset), !data.isEmpty else {
      return nil
    }
    let ext = preferredImageExtension(for: asset, fallbackPathExtension: "jpg")
    return try writeAssetDataToTemp(data: data, preferredExtension: ext)
  }

  private func resolveImageAssetPathUsingResourceDownload(asset: PHAsset) throws -> String? {
    let resources = PHAssetResource.assetResources(for: asset)
    guard let resource = preferredImageResource(for: asset, resources: resources) ?? resources.first else {
      return nil
    }

    let options = PHAssetResourceRequestOptions()
    options.isNetworkAccessAllowed = true

    let semaphore = DispatchSemaphore(value: 0)
    var collectedData = Data()
    PHAssetResourceManager.default().requestData(
      for: resource,
      options: options,
      dataReceivedHandler: { chunk in
        collectedData.append(chunk)
      },
      completionHandler: { _ in
        semaphore.signal()
      }
    )
    semaphore.wait()

    guard !collectedData.isEmpty else {
      return nil
    }

    let ext = preferredImageExtension(
      for: asset,
      resourceFilename: resource.originalFilename,
      fallbackPathExtension: (resource.originalFilename as NSString).pathExtension
    )
    return try writeAssetDataToTemp(
      data: collectedData,
      preferredExtension: ext
    )
  }

  private func resolveImageAssetPathUsingRenderedImage(asset: PHAsset) throws -> String? {
    let options = PHImageRequestOptions()
    options.deliveryMode = .highQualityFormat
    options.resizeMode = .exact
    options.isSynchronous = false
    options.isNetworkAccessAllowed = true
    options.version = .current

    let targetWidth = max(64, min(asset.pixelWidth, 4096))
    let targetHeight = max(64, min(asset.pixelHeight, 4096))

    let semaphore = DispatchSemaphore(value: 0)
    var requestedImage: UIImage?
    var wasCancelled = false

    PHImageManager.default().requestImage(
      for: asset,
      targetSize: CGSize(width: targetWidth, height: targetHeight),
      contentMode: .aspectFit,
      options: options
    ) { image, info in
      let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
      let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
      if cancelled {
        wasCancelled = true
      }
      if let image, !degraded {
        requestedImage = image
      } else if requestedImage == nil, let image {
        requestedImage = image
      }
      if !degraded || cancelled {
        semaphore.signal()
      }
    }
    semaphore.wait()

    if wasCancelled, requestedImage == nil {
      return nil
    }
    guard let image = requestedImage,
          let data = image.jpegData(compressionQuality: 1.0),
          !data.isEmpty else {
      return nil
    }
    return try writeAssetDataToTemp(data: data, preferredExtension: "jpg")
  }

  private func preferredImageResource(
    for asset: PHAsset,
    resources: [PHAssetResource]
  ) -> PHAssetResource? {
    if asset.mediaSubtypes.contains(.photoLive) {
      return resources.first(where: { $0.type == .photo || $0.type == .fullSizePhoto })
    }
    return resources.first(where: { $0.type == .photo || $0.type == .fullSizePhoto })
  }

  private func preferredImageExtension(
    for asset: PHAsset,
    resourceFilename: String? = nil,
    fallbackPathExtension: String
  ) -> String {
    if asset.mediaSubtypes.contains(.photoLive) {
      return "jpg"
    }
    let rawExtension = ((resourceFilename ?? "") as NSString).pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
    if !rawExtension.isEmpty {
      return rawExtension.lowercased()
    }
    let fallback = fallbackPathExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return fallback.isEmpty ? "jpg" : fallback
  }

  private func writeAssetDataToTemp(data: Data, preferredExtension: String) throws -> String {
    let outDir = try ensureCacheDirectory(named: "asset_cache")
    let normalizedExt = preferredExtension.trimmingCharacters(in: .whitespacesAndNewlines)
    let ext = normalizedExt.isEmpty ? "jpg" : normalizedExt
    let out = outDir.appendingPathComponent("asset_\(UUID().uuidString).\(ext)")
    try data.write(to: out, options: .atomic)
    return out.path
  }

  private func resolveVideoAssetPath(asset: PHAsset) throws -> String {
    let resources = PHAssetResource.assetResources(for: asset)
    guard let resource = resources.first(where: { $0.type == .video || $0.type == .fullSizeVideo }) ?? resources.first else {
      throw ScannerError.invalidArgument(
        "Unable to read video resource for asset \(asset.localIdentifier)"
      )
    }
    let outDir = FileManager.default.temporaryDirectory.appendingPathComponent(
      "asset_cache",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: outDir,
      withIntermediateDirectories: true
    )
    let ext = (resource.originalFilename as NSString).pathExtension
    let out = outDir.appendingPathComponent(
      "asset_\(UUID().uuidString).\(ext.isEmpty ? "mov" : ext)"
    )
    let semaphore = DispatchSemaphore(value: 0)
    var writeError: Error?
    let requestOptions = PHAssetResourceRequestOptions()
    requestOptions.isNetworkAccessAllowed = true
    PHAssetResourceManager.default().writeData(
      for: resource,
      toFile: out,
      options: requestOptions
    ) { error in
      writeError = error
      semaphore.signal()
    }
    semaphore.wait()
    if let writeError {
      throw writeError
    }
    return out.path
  }

  private func resolveVideoPath(for asset: PHAsset) throws -> String? {
    let options = PHVideoRequestOptions()
    options.deliveryMode = .highQualityFormat
    options.isNetworkAccessAllowed = true

    let semaphore = DispatchSemaphore(value: 0)
    var resolvedAsset: AVAsset?
    var resolvedPath: String?
    var requestError: Error?
    photoManager.requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
      if let error = info?[PHImageErrorKey] as? Error {
        requestError = error
      }
      resolvedAsset = avAsset
      if let urlAsset = avAsset as? AVURLAsset {
        resolvedPath = urlAsset.url.path
      }
      semaphore.signal()
    }
    semaphore.wait()
    if let resolvedPath,
       !resolvedPath.isEmpty,
       FileManager.default.fileExists(atPath: resolvedPath) {
      return resolvedPath
    }
    if let resolvedAsset {
      return try exportVideoAssetToTempFile(
        asset: resolvedAsset,
        preferredExtension: "mov"
      )
    }
    if let requestError {
      throw requestError
    }
    return nil
  }

  private func exportVideoAssetToTempFile(
    asset: AVAsset,
    preferredExtension: String
  ) throws -> String {
    let compatiblePresets = AVAssetExportSession.exportPresets(compatibleWith: asset)
    let preferredPresets = [
      AVAssetExportPresetPassthrough,
      AVAssetExportPresetHighestQuality,
      AVAssetExportPresetMediumQuality,
    ]
    guard let preset = preferredPresets.first(where: { compatiblePresets.contains($0) }),
          let session = AVAssetExportSession(asset: asset, presetName: preset) else {
      throw ScannerError.invalidArgument("Unable to export video asset.")
    }

    let supportedTypes = session.supportedFileTypes
    let fileType: AVFileType
    let fileExtension: String
    if supportedTypes.contains(.mp4) {
      fileType = .mp4
      fileExtension = "mp4"
    } else if supportedTypes.contains(.mov) {
      fileType = .mov
      fileExtension = "mov"
    } else if let first = supportedTypes.first {
      fileType = first
      fileExtension = preferredExtension
    } else {
      throw ScannerError.invalidArgument("Unable to determine exported video file type.")
    }

    let outDir = try ensureCacheDirectory(named: "asset_cache")
    let out = outDir.appendingPathComponent("asset_\(UUID().uuidString).\(fileExtension)")
    if FileManager.default.fileExists(atPath: out.path) {
      try FileManager.default.removeItem(at: out)
    }

    session.outputURL = out
    session.outputFileType = fileType
    session.shouldOptimizeForNetworkUse = true

    let semaphore = DispatchSemaphore(value: 0)
    session.exportAsynchronously {
      semaphore.signal()
    }
    semaphore.wait()

    if let error = session.error {
      throw error
    }
    guard session.status == .completed, FileManager.default.fileExists(atPath: out.path) else {
      throw ScannerError.invalidArgument("Video export did not complete successfully.")
    }
    return out.path
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

  private func resolveVideoDurationSeconds(asset: AVURLAsset) -> Double? {
    let cacheKey = asset.url.path
    videoDurationCacheLock.lock()
    if let cached = videoDurationCache[cacheKey] {
      videoDurationCacheLock.unlock()
      return cached
    }
    videoDurationCacheLock.unlock()

    let directDuration = CMTimeGetSeconds(asset.duration)
    if directDuration.isFinite && directDuration > 0 {
      videoDurationCacheLock.lock()
      videoDurationCache[cacheKey] = directDuration
      videoDurationCacheLock.unlock()
      return directDuration
    }

    if let videoTrack = asset.tracks(withMediaType: .video).first {
      let trackDuration = CMTimeGetSeconds(videoTrack.timeRange.duration)
      if trackDuration.isFinite && trackDuration > 0 {
        videoDurationCacheLock.lock()
        videoDurationCache[cacheKey] = trackDuration
        videoDurationCacheLock.unlock()
        return trackDuration
      }
    }

    let keys = ["duration"]
    let semaphore = DispatchSemaphore(value: 0)
    asset.loadValuesAsynchronously(forKeys: keys) {
      semaphore.signal()
    }
    let waitResult = semaphore.wait(timeout: .now() + 0.2)
    if waitResult == .timedOut {
      return nil
    }

    let status = asset.statusOfValue(forKey: "duration", error: nil)
    guard status == .loaded else {
      return nil
    }

    let loadedDuration = CMTimeGetSeconds(asset.duration)
    if loadedDuration.isFinite && loadedDuration > 0 {
      videoDurationCacheLock.lock()
      videoDurationCache[cacheKey] = loadedDuration
      videoDurationCacheLock.unlock()
      return loadedDuration
    }

    return nil
  }

  private func scanVideoWithThumbnailFallback(
    asset: PHAsset,
    assetId: String,
    threshold: Float,
    thumbnailSize: Int
  ) throws -> [String: Any] {
    let manager = PHCachingImageManager()
    let image = try requestThumbnailImage(
      asset: asset,
      manager: manager,
      thumbnailSize: thumbnailSize
    )
    let interpreter = try IOSNsfwScanner.createInterpreter(modelData: modelData, numThreads: numThreads)
    try interpreter.allocateTensors()
    let frameIdentity = "ph://\(assetId)#thumb"
    let frameResult = try runSingleScan(
      interpreter: interpreter,
      cgImage: image,
      frameIdentity: frameIdentity,
      threshold: threshold
    )

    let nsfwScore = frameResult["nsfwScore"] as? Double ?? 0
    let safeScore = frameResult["safeScore"] as? Double ?? 0
    let isNsfw = frameResult["isNsfw"] as? Bool ?? false
    let topLabel = frameResult["topLabel"] as? String ?? ""
    let topScore = frameResult["topScore"] as? Double ?? 0
    let scores = frameResult["scores"] as? [String: Double] ?? [:]

    return [
      "videoPath": "ph://\(assetId)",
      "sampleRateFps": 0.0,
      "sampledFrames": 1,
      "flaggedFrames": isNsfw ? 1 : 0,
      "flaggedRatio": isNsfw ? 1.0 : 0.0,
      "maxNsfwScore": nsfwScore,
      "isNsfw": isNsfw,
      "requiredNsfwFrames": 1,
      "fallbackMode": "thumbnail",
      "frames": [[
        "timestampMs": 0.0,
        "nsfwScore": nsfwScore,
        "safeScore": safeScore,
        "isNsfw": isNsfw,
        "topLabel": topLabel,
        "topScore": topScore,
        "scores": scores,
        "error": NSNull(),
      ]],
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

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private extension NSLock {
  func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}
