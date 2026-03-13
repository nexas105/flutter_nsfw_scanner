# flutter_nsfw_scaner example

Example app for the plugin with a start hub and multiple test screens.

## Start hub

On app start you can select one of three screens:

1. Aktueller Wizard (bestehende produktive UI)
2. UI Kit Best Practice (2-screen reference flow)
3. UI Kit Playground (widget try page)

## Wizard behavior (bestehend)

- Horizontal step header (not vertical stepper)
- Bottom navigation bar controls (`Zuruck`, `Weiter`, `Scan starten`)
- Result step offers `Von vorne starten`
- Live result list is paginated
- UI updates are polled every ~250ms (buffered updates), not rebuilt per native event
- During gallery scans, page stays stable (no auto-jump to newest page)
- Background processing is enabled in the example configuration:
  - persisted upload queue
  - persisted whole-gallery job state
  - resume/pause/cancel controls for long gallery scans

## Live gallery result previews (Wizard)

For image rows, the example uses plugin-native asset preview APIs:

- Visible rows trigger lazy thumbnail loading (`loadImageThumbnail`)
- Tap on a row loads full image asset (`loadImageAsset`) and opens large preview dialog
- No image byte payloads are streamed through EventChannel

## Scan modes in example

- Single scan (image/video)
- Selection batch scan
- Full gallery scan (native pipeline, streamed chunk results)

## UI Kit reference screens

- 2-screen implementation that demonstrates recommended usage of plugin widgets
- Screen 1: scan/progress focused
- Screen 2: paginated result list with result widgets

## UI Kit playground

- Interactive switches/sliders to try widget states and behavior
- Useful to test labels, statuses, pagination, and control bars quickly

## Run

```bash
cd example
flutter pub get
flutter run
```

## Test

```bash
cd example
flutter analyze
flutter test
```

## Debugging

Gallery scan debugging can be enabled in the wizard preparation step:

- `Debug Logging (nativ)`

Then inspect native logs in Xcode/Android Studio console while scanning.

## Background processing demo

The wizard uses:

- `NsfwBackgroundProcessingConfig(enabled: true, continueUploadsInBackground: true, continueGalleryScanInBackground: true, preventConcurrentWholeGalleryScans: true, autoResumeInterruptedJobs: true)`
- `waitForPendingUploads()` after the scan pipeline
- background job controls in the review/result screens
- foreground-prioritized uploads with background throttling when the app is no longer resumed

This demonstrates the intended `1.1.4` flow for long gallery scans and persisted uploads.

## Permissions

The example includes media/gallery permissions for Android and iOS.
