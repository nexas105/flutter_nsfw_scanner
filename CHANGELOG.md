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
