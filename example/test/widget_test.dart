// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_nsfw_scaner_example/main.dart';

void main() {
  testWidgets('Renders example start hub', (WidgetTester tester) async {
    await tester.pumpWidget(const NsfwWizardApp());
    await tester.pump();

    expect(find.text('NSFW Scanner Example Hub'), findsOneWidget);
    expect(find.textContaining('Aktueller Wizard'), findsOneWidget);
    expect(find.textContaining('UI Kit Best Practice'), findsOneWidget);
    expect(find.textContaining('UI Kit Playground'), findsOneWidget);
  });
}
