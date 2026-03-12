import 'package:flutter/material.dart';

import 'nsfw_gallery_media.dart';
import 'nsfw_media_batch.dart';

typedef NsfwStepIsDone = bool Function(int index);
typedef NsfwPageLabelBuilder = String Function(int pageIndex, int pageCount);

class NsfwScanWizardStepHeader extends StatelessWidget {
  const NsfwScanWizardStepHeader({
    super.key,
    required this.stepLabels,
    required this.currentStep,
    this.isStepDone,
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    this.spacing = 8,
    this.activeColor = const Color(0xFF0A7A8C),
    this.completedColor = const Color(0xFF2E7D32),
    this.idleColor = Colors.white,
    this.idleTextColor = const Color(0xFF33464D),
    this.activeTextColor = Colors.white,
    this.chipBorderColor = const Color(0xFFB7C9CD),
  });

  final List<String> stepLabels;
  final int currentStep;
  final NsfwStepIsDone? isStepDone;
  final EdgeInsets padding;
  final double spacing;
  final Color activeColor;
  final Color completedColor;
  final Color idleColor;
  final Color idleTextColor;
  final Color activeTextColor;
  final Color chipBorderColor;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 62,
      child: ListView.separated(
        padding: padding,
        scrollDirection: Axis.horizontal,
        itemCount: stepLabels.length,
        separatorBuilder: (_, _) => SizedBox(width: spacing),
        itemBuilder: (context, index) {
          final done = isStepDone?.call(index) ?? (index < currentStep);
          final active = index == currentStep;
          final background = active
              ? activeColor
              : (done ? completedColor : idleColor);
          final foreground = (active || done) ? activeTextColor : idleTextColor;

          return AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: chipBorderColor),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  done
                      ? Icons.check_circle
                      : (active
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked),
                  size: 16,
                  color: foreground,
                ),
                const SizedBox(width: 8),
                Text(
                  stepLabels[index],
                  style: TextStyle(
                    color: foreground,
                    fontWeight: active ? FontWeight.w700 : FontWeight.w600,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class NsfwBottomActionBar extends StatelessWidget {
  const NsfwBottomActionBar({
    super.key,
    required this.showWizardControls,
    required this.onBack,
    required this.onForward,
    required this.onRestart,
    this.onCancel,
    this.backEnabled = true,
    this.forwardEnabled = true,
    this.restartEnabled = true,
    this.showCancel = false,
    this.backLabel = 'Zuruck',
    this.forwardLabel = 'Weiter',
    this.restartLabel = 'Von vorne starten',
    this.cancelLabel = 'Abbrechen',
    this.padding = const EdgeInsets.fromLTRB(12, 8, 12, 12),
    this.backgroundColor = Colors.white,
    this.shadowColor = const Color(0x22000000),
  });

  final bool showWizardControls;
  final VoidCallback? onBack;
  final VoidCallback? onForward;
  final VoidCallback? onRestart;
  final VoidCallback? onCancel;
  final bool backEnabled;
  final bool forwardEnabled;
  final bool restartEnabled;
  final bool showCancel;
  final String backLabel;
  final String forwardLabel;
  final String restartLabel;
  final String cancelLabel;
  final EdgeInsets padding;
  final Color backgroundColor;
  final Color shadowColor;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        padding: padding,
        decoration: BoxDecoration(
          color: backgroundColor,
          boxShadow: [
            BoxShadow(
              color: shadowColor,
              blurRadius: 10,
              offset: const Offset(0, -2),
            ),
          ],
        ),
        child: Row(
          children: [
            if (showWizardControls) ...[
              OutlinedButton(
                onPressed: backEnabled ? onBack : null,
                child: Text(backLabel),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                  onPressed: forwardEnabled ? onForward : null,
                  child: Text(forwardLabel),
                ),
              ),
            ] else ...[
              Expanded(
                child: FilledButton.icon(
                  onPressed: restartEnabled ? onRestart : null,
                  icon: const Icon(Icons.restart_alt),
                  label: Text(restartLabel),
                ),
              ),
              if (showCancel) ...[
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: onCancel,
                  icon: const Icon(Icons.stop_circle_outlined),
                  label: Text(cancelLabel),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class NsfwPaginationControls extends StatelessWidget {
  const NsfwPaginationControls({
    super.key,
    required this.pageIndex,
    required this.pageCount,
    required this.onPrevious,
    required this.onNext,
    this.previousLabel = 'Vorherige',
    this.nextLabel = 'Nachste',
    this.pageLabelBuilder,
    this.spacing = 8,
  });

  final int pageIndex;
  final int pageCount;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final String previousLabel;
  final String nextLabel;
  final NsfwPageLabelBuilder? pageLabelBuilder;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    final safeCount = pageCount <= 0 ? 1 : pageCount;
    final safePage = pageIndex.clamp(0, safeCount - 1).toInt();
    final label =
        pageLabelBuilder?.call(safePage, safeCount) ??
        'Seite ${safePage + 1} / $safeCount';

    return Row(
      children: [
        OutlinedButton.icon(
          onPressed: onPrevious,
          icon: const Icon(Icons.chevron_left),
          label: Text(previousLabel),
        ),
        SizedBox(width: spacing),
        Text(label),
        SizedBox(width: spacing),
        OutlinedButton.icon(
          onPressed: onNext,
          icon: const Icon(Icons.chevron_right),
          label: Text(nextLabel),
        ),
      ],
    );
  }
}

class NsfwBatchProgressCard extends StatelessWidget {
  const NsfwBatchProgressCard({
    super.key,
    required this.processed,
    required this.total,
    required this.phase,
    this.statusText,
    this.resultCount,
    this.running = false,
    this.completed = false,
    this.titleBuilder,
    this.cardColor = Colors.white,
    this.progressColor,
    this.padding = const EdgeInsets.all(12),
  });

  final int processed;
  final int total;
  final String phase;
  final String? statusText;
  final int? resultCount;
  final bool running;
  final bool completed;
  final String Function(bool running, bool completed)? titleBuilder;
  final Color cardColor;
  final Color? progressColor;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final ratio = _safeRatio(processed: processed, total: total);
    final title =
        titleBuilder?.call(running, completed) ??
        (running
            ? 'Scan lauft'
            : (completed ? 'Scan abgeschlossen' : 'Bereit'));

    return Card(
      color: cardColor,
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(phase),
            const SizedBox(height: 6),
            LinearProgressIndicator(
              value: running ? ratio : (completed ? 1 : 0),
              color: progressColor,
            ),
            const SizedBox(height: 6),
            Text('Fortschritt: $processed / $total'),
            if (resultCount != null) Text('Ergebnisse: $resultCount'),
            if (statusText != null && statusText!.isNotEmpty) Text(statusText!),
          ],
        ),
      ),
    );
  }
}

class NsfwGalleryLoadCard extends StatelessWidget {
  const NsfwGalleryLoadCard({
    super.key,
    required this.progress,
    this.title = 'Galerie laden',
    this.cardColor = Colors.white,
    this.padding = const EdgeInsets.all(12),
  });

  final NsfwGalleryLoadProgress progress;
  final String title;
  final Color cardColor;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final loadPercent = progress.percent;
    return Card(
      color: cardColor,
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              'Scanned: ${progress.scannedAssets} | Bilder: ${progress.imageCount} | Videos: ${progress.videoCount}',
            ),
            if (loadPercent != null) ...[
              const SizedBox(height: 6),
              LinearProgressIndicator(value: loadPercent),
            ],
            const SizedBox(height: 6),
            Text(progress.isCompleted ? 'Laden abgeschlossen' : 'Laden lauft'),
          ],
        ),
      ),
    );
  }
}

class NsfwResultStatusChip extends StatelessWidget {
  const NsfwResultStatusChip({
    super.key,
    required this.isNsfw,
    this.hasError = false,
    this.errorLabel = 'Fehler',
    this.nsfwLabel = 'NSFW',
    this.safeLabel = 'Safe',
    this.errorColor = Colors.red,
    this.nsfwColor = Colors.orange,
    this.safeColor = Colors.green,
  });

  final bool isNsfw;
  final bool hasError;
  final String errorLabel;
  final String nsfwLabel;
  final String safeLabel;
  final Color errorColor;
  final Color nsfwColor;
  final Color safeColor;

  @override
  Widget build(BuildContext context) {
    final label = hasError ? errorLabel : (isNsfw ? nsfwLabel : safeLabel);
    final color = hasError ? errorColor : (isNsfw ? nsfwColor : safeColor);
    final icon = hasError
        ? Icons.error_outline
        : (isNsfw ? Icons.warning_amber_rounded : Icons.verified);

    return Chip(
      avatar: Icon(icon, size: 18, color: color),
      label: Text(label),
      side: BorderSide(color: color.withValues(alpha: 0.35)),
    );
  }
}

class NsfwResultTile extends StatelessWidget {
  const NsfwResultTile({
    super.key,
    required this.path,
    required this.type,
    required this.score,
    required this.isNsfw,
    this.error,
    this.leading,
    this.onTap,
    this.pathMaxLines = 1,
    this.pathOverflow = TextOverflow.ellipsis,
    this.scoreFormatter,
    this.videoLabel = 'Video',
    this.imageLabel = 'Bild',
  });

  final String path;
  final NsfwMediaType type;
  final double score;
  final bool isNsfw;
  final String? error;
  final Widget? leading;
  final VoidCallback? onTap;
  final int pathMaxLines;
  final TextOverflow pathOverflow;
  final String Function(double score)? scoreFormatter;
  final String videoLabel;
  final String imageLabel;

  bool get _hasError => error != null && error!.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final resolvedScore =
        scoreFormatter?.call(score) ?? score.toStringAsFixed(3);
    final subtitle = _hasError
        ? 'Fehler: $error'
        : '${type == NsfwMediaType.video ? videoLabel : imageLabel} • Score $resolvedScore';

    return ListTile(
      onTap: onTap,
      leading: leading,
      title: Text(path, maxLines: pathMaxLines, overflow: pathOverflow),
      subtitle: Text(subtitle),
      trailing: NsfwResultStatusChip(isNsfw: isNsfw, hasError: _hasError),
    );
  }
}

double _safeRatio({required int processed, required int total}) {
  if (total <= 0) {
    return 0.0;
  }
  return (processed / total).clamp(0.0, 1.0);
}
