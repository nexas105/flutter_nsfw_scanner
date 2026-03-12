import 'package:flutter/material.dart';
import 'package:flutter_nsfw_scaner/flutter_nsfw_scaner.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget wrap(Widget child) {
    return MaterialApp(home: Scaffold(body: child));
  }

  testWidgets('renders progress widgets', (tester) async {
    await tester.pumpWidget(
      wrap(
        Column(
          children: const [
            NsfwBatchProgressCard(
              processed: 20,
              total: 100,
              phase: 'Galerie-Scan lauft',
              running: true,
            ),
            NsfwGalleryLoadCard(
              progress: NsfwGalleryLoadProgress(
                page: 0,
                scannedAssets: 120,
                imageCount: 90,
                videoCount: 30,
                targetCount: 300,
                isCompleted: false,
              ),
            ),
          ],
        ),
      ),
    );

    expect(find.text('Scan lauft'), findsOneWidget);
    expect(find.text('Galerie laden'), findsOneWidget);
  });

  testWidgets('renders result widgets', (tester) async {
    await tester.pumpWidget(
      wrap(
        const Column(
          children: [
            NsfwResultStatusChip(isNsfw: true),
            NsfwResultTile(
              path: 'ph://asset-id',
              type: NsfwMediaType.image,
              score: 0.83,
              isNsfw: true,
            ),
          ],
        ),
      ),
    );

    expect(find.text('NSFW'), findsNWidgets(2));
    expect(find.textContaining('Score 0.830'), findsOneWidget);
  });

  testWidgets('renders navigation and control widgets', (tester) async {
    await tester.pumpWidget(
      wrap(
        Column(
          children: [
            const NsfwScanWizardStepHeader(
              stepLabels: ['1. Modus', '2. Vorbereitung', '3. Start'],
              currentStep: 1,
            ),
            NsfwPaginationControls(
              pageIndex: 0,
              pageCount: 5,
              onPrevious: () {},
              onNext: () {},
            ),
            NsfwBottomActionBar(
              showWizardControls: true,
              onBack: () {},
              onForward: () {},
              onRestart: () {},
            ),
          ],
        ),
      ),
    );

    expect(find.text('2. Vorbereitung'), findsOneWidget);
    expect(find.text('Seite 1 / 5'), findsOneWidget);
    expect(find.text('Weiter'), findsOneWidget);
  });
}
