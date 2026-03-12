# LLM.md - flutter_nsfw_scaner

This file explains the plugin for other LLMs/agents.

## What this plugin does

`flutter_nsfw_scaner` is a Flutter plugin for NSFW detection on device:

- Image inference (TFLite)
- Video frame sampling + inference
- Mixed media batch scanning
- Full gallery scanning with streaming progress and chunked result events
- Native thumbnail/full-image asset loading helpers for gallery result UIs

Targets:
- Android (Kotlin)
- iOS (Swift)

## High-level architecture

- Dart API layer: `/lib/flutter_nsfw_scaner.dart`
- Platform interface: `/lib/flutter_nsfw_scaner_platform_interface.dart`
- Method/Event channel adapter: `/lib/flutter_nsfw_scaner_method_channel.dart`
- Reusable UI widgets: `/lib/nsfw_widgets.dart`
- Android native implementation: `/android/src/main/kotlin/.../FlutterNsfwScanerPlugin.kt`
- iOS native implementation: `/ios/Classes/FlutterNsfwScanerPlugin.swift`

Channels:
- `MethodChannel("flutter_nsfw_scaner")`
- `EventChannel("flutter_nsfw_scaner/progress")`

## Main Dart APIs

- `initialize(...)`
- `scanImage(...)`
- `scanBatch(...)`
- `scanVideo(...)`
- `scanMediaBatch(...)`
- `scanMediaInChunks(...)`
- `scanWholeGallery(...)`
- `scanGallery(...)`
- `cancelScan(...)`
- `dispose()`

UI widgets (optional):
- `NsfwBatchProgressCard`, `NsfwGalleryLoadCard`
- `NsfwResultStatusChip`, `NsfwResultTile`
- `NsfwPaginationControls`, `NsfwBottomActionBar`, `NsfwScanWizardStepHeader`

Asset preview helpers:
- `loadImageThumbnail(assetRef, width, height, quality)`
- `loadImageAsset(assetRef)`
- Aliases:
  - `loadImageThumnbail(...)`
  - `loadImageAssets(...)`

## Result model notes

`NsfwMediaBatchItemResult` contains:
- `path`
- `type`
- `assetId` (optional)
- `uri` (optional)
- `imageResult` / `videoResult`
- `error`

Use `assetId`/`uri` when possible for later thumbnail/full-asset loading.

## Streaming event types

From `progressStream`, gallery scan emits:

1. `gallery_load_progress`
- discovery/loading progress
- fields include `scannedAssets`, `imageCount`, `videoCount`, `targetCount`, `isCompleted`

2. `gallery_scan_progress`
- scan pipeline progress
- fields include `processed`, `total`, `percent`, `status`

3. `gallery_result_batch`
- chunk of result items
- fields include `items`, per-chunk counters, and running totals

## Performance model

Key design goals:
- Flutter UI thread must stay responsive
- Native work happens in background workers
- Avoid huge platform channel payloads

How implemented:
- Gallery work is processed in chunks/batches
- Worker pool parallelism is bounded (`maxConcurrency`, CPU-bound)
- Thumbnail-sized image decode for inference path
- Progress events are throttled
- Stream chunk results (not one method call per asset)

Important:
- Do not transfer raw `Uint8List`/full image bytes across channels for normal scan stream.
- Transfer metadata/results only (`assetId`, `uri`, `path`, scores, flags, errors).

## Asset reference conventions

`assetRef` accepted by native loaders can be:

- iOS:
  - `ph://<localIdentifier>`
  - `<localIdentifier>`
  - local file path (`/var/...`)
  - `file://...`

- Android:
  - `content://...`
  - `file://...`
  - `/storage/...`
  - `image:<id>` or `video:<id>` (MediaStore id style)

Returned values are local file paths suitable for `Image.file`.

## Example integration pattern

Recommended UI pattern (used in example app):

- Buffer stream updates and apply to UI on timer (e.g. 200-300ms)
- Keep pagination stable while new items arrive
- Lazy load thumbnails only for currently visible rows
- On tap, load full image asset and show detail dialog

## Dependencies and scope

Current pub dependencies include:
- `image_picker`
- `photo_manager`

Core scanning and gallery pipelines are native (Kotlin/Swift).

## Operational hints for maintainers/agents

When modifying scan performance:
- preserve background-only heavy work
- preserve bounded worker parallelism
- keep event throughput throttled
- keep result batching intact
- avoid new channel byte-heavy payloads

When modifying UI example:
- avoid rebuilding on each native event
- keep polling/buffer mechanism for live updates
- maintain pagination stability for long scans
