## 1.1.5

- Stabilized upload state persistence so upload queues and staged files now use a durable application-support directory instead of temporary storage.
- Ensured upload state directory is initialized during scanner startup, so uploads resumed on app relaunch/reinstall boundaries are more reliable for TestFlight/build-update flows.
- Added a fallback legacy path for older installs when the app-support directory is unavailable.

## 1.1.4

- Added `NsfwBackgroundProcessingConfig` with default-enabled long-running background safeguards for uploads and whole-gallery scans.
- Added `NsfwBackgroundController` plus public helpers (`getBackgroundJobs`, `resumePendingBackgroundJobs`, `resumeWholeGalleryScan`, `pauseWholeGalleryScan`, `cancelWholeGalleryScan`, `clearFinishedBackgroundJobs`, `isWholeGalleryScanRunning`, `waitForBackgroundTasks`).
- Added a persisted whole-gallery scan coordinator in Dart that tracks job metadata, prevents concurrent whole-gallery scans by default, and auto-resumes interrupted gallery jobs on the next `initialize(...)`.
- Kept upload queue persistence build-scoped and extended the long-running flow so staged uploads and whole-gallery jobs now share the same background-oriented lifecycle model.
- Updated the example app to demonstrate background-processing defaults, waiting for pending uploads, and manual background job controls.

## 1.1.3

- Improved iOS whole-gallery scan performance by reusing the image interpreter pool across gallery batches instead of rebuilding interpreters for every batch.
- Improved iOS whole-gallery cache performance by loading gallery scan history into memory once per run and writing successful asset ids back in batched SQLite transactions.
- Improved auto Normani/Harami upload device folder resolution: when no explicit `deviceFolder` or `NSFW_DEVICE_ID` is provided, the plugin now creates and reuses a persistent random device id across app restarts for the current app installation.

## 1.1.2

- Added optional native SQLite-backed whole-gallery scan history, configured via `initialize(..., galleryScanCachePrefix:, galleryScanCacheTableName:)`, so previously scanned assets can be skipped on later `scanWholeGallery` / `scanGallery` runs.
- Added `resetGalleryScanCache()` to clear the configured whole-gallery scan history for the current scanner instance.
- Added `skippedCount` to `NsfwMediaBatchResult` for whole-gallery runs that skip already-cached assets.
- Added bounded whole-gallery result retention via `maxRetainedResultItems` plus `didTruncateItems`, so very large libraries do not keep unbounded result lists in memory.
- Removed native whole-gallery result caps that previously truncated large iOS/Android result lists.
- Expanded iOS whole-gallery asset discovery to explicitly include hidden assets and burst assets.

## 1.1.1

- Improved iOS cloud-image materialization in whole-gallery scanning: image resolve now uses a full fallback chain (`requestImageDataAndOrientation` -> `PHAssetResourceManager` download -> rendered image export) instead of failing after a single data read path.
- Hardened iOS PhotoKit image requests for cloud assets by handling cancelled/degraded callbacks more safely, reducing missed scans for temporarily unavailable iCloud photos.

## 1.1.0

- Added robust large-scan defaults across multi-asset flows: adaptive chunk sizing/backpressure is now applied in Dart for `scanMediaInChunks` and `scanMultipleMedia`.
- Added multi-pass retry for asset reference resolution in `scanMultipleMedia` to better recover temporarily unavailable cloud assets before emitting final errors.
- Added native gallery range handling (`pageSize`, `startPage`, `maxPages`) for both iOS and Android `scanGallery`, so large gallery scans can run in bounded windows instead of always starting from the full dataset.
- Kept whole-gallery cloud fallback behavior in place (retry queue + final fallback paths), now with range-scoped scanning support.

## 1.0.14

- Extended iOS whole-gallery retry handling for cloud/unavailable assets with configurable retry phase defaults (`retryPasses=2`, `retryDelayMs=1400`), so assets can be retried after background materialization.
- Added iOS video last-resort fallback: when full video resolve/scan fails, scanner now attempts a thumbnail-frame scan for the same asset instead of returning an immediate item error.
- Retry/defer behavior now consistently applies to both images and videos in whole-gallery mode.

## 1.0.13

- Improved iOS whole-gallery video scanning resilience: duration probing now uses async asset/track fallbacks and no longer hard-fails assets when duration is temporarily unavailable.
- Added safe single-frame fallback scan (`t=0`) for cloud/mutated videos when duration cannot be resolved, reducing per-item video errors during large gallery scans.

## 1.0.12

- Added graceful handling for native `SCAN_CANCELLED` in Dart `scanMediaBatch`, returning controlled empty/partial-compatible batch payloads instead of throwing hard `PlatformException`.

## 1.0.11

- Handled native `SCAN_CANCELLED` in Dart `scanWholeGallery` as a graceful partial result instead of throwing a hard `PlatformException`.

## 1.0.10

- Improved iOS whole-gallery hit stability with thumbnail-first scanning and automatic full-asset fallback when thumbnail extraction/materialization fails.

## 1.0.9

- Fixed iOS compile error by adding missing `resolveImageAssetPath` and `resolveVideoAssetPath` implementations to `IOSNsfwScanner` used by whole-gallery fallback scanning.

## 1.0.8

- Improved iOS whole-gallery media materialization: if direct thumbnail/AVAsset access fails, scanner now falls back to local cached asset extraction before scan.
- This aligns native whole-gallery behavior closer to `photo_manager`-style flows for cloud-backed assets.

## 1.0.7

- Fixed gallery auto-upload queue handling for iOS `ph://` assets by resolving to local file paths before upload.
- Prevented a single failed auto-upload task from stopping the entire queue, improving whole-gallery stability and throughput.

## 1.0.6

- Fixed iOS native whole-gallery thumbnail scanning fallback so PhotoKit data-read failures no longer abort alternative image-request paths for existing assets.
- Added an iOS native deferred retry pass for temporarily unavailable gallery assets: failed items are queued to the end and retried before final completion.
- Added iOS media permission status API and limited-library expansion API (`getMediaPermissionStatus`, `presentLimitedLibraryPicker`) and wired optional limited-access expansion into `scanWholeGallery`/`scanGallery`.

## 1.0.5

- Added `onChunkResult` callback support to `scanMultipleMedia(...)`, aligned with chunked scan workflows.

## 1.0.4

- Fixed `scanMultipleMedia(assetRefs: ...)` to skip unresolved iOS PhotoKit assets and continue scanning instead of aborting the full run.
- Added per-asset error entries for failed asset resolution (for example iCloud/restricted/unresolvable assets, including common `PHPhotosErrorDomain` cases like `3164`).
- Improved iOS asset resolution fallback chain to better materialize cloud-backed images (`requestImageDataAndOrientation` -> `PHAssetResourceManager` download -> rendered `UIImage` export).
- Enabled network-backed export options for iOS video asset resource materialization to improve real-device iCloud retrieval reliability.

## 1.0.2

- Added ThemeData-aware defaults for UI kit widgets (`NsfwScanWizardStepHeader`, `NsfwBottomActionBar`, `NsfwBatchProgressCard`, `NsfwGalleryLoadCard`, `NsfwResultStatusChip`) so they adapt to host app color schemes out of the box.
- Kept explicit color overrides fully supported for existing integrations.

## 1.0.1

- Fixed iOS CocoaPods integration for host apps by marking the plugin as a static framework (`s.static_framework = true`) to avoid transitive static binary linkage errors with TensorFlow Lite.
- Removed unused `encrypt` import in the example app.
- Removed unused internal crypto helper method to keep `dart analyze` clean for publish validation.

## 1.0.0

- Added full gallery scanning with streaming progress and chunk result events.
- Added mixed media batch APIs (`scanMediaBatch`, `scanMediaInChunks`, `scanMultipleMedia`).
- Added URL media scan API (`scanMediaFromUrl`) with optional file persistence.
- Added on-demand image preview helpers (`loadImageThumbnail`, `loadImageAsset`).
- Added cancellation support across scan flows via `cancelScan`.
- Added optional UI widget kit for scan progress/results navigation.
- Improved Android and iOS native scanner implementations and background execution.
- Improved example app with scan wizard and picker-based workflows.
