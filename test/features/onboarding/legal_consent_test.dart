import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/features/onboarding/presentation/legal_consent.dart';
import 'package:playlist_app/features/settings/presentation/legal_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late ProviderContainer container;

  setUp(() => container = ProviderContainer());
  tearDown(() => container.dispose());

  /// Lance l'écran de consentement comme main.dart, et l'affiche s'il est
  /// requis ; [done] passe à `true` quand le démarrage de l'app peut suivre.
  Future<({Widget? shown, bool Function() done})> startGate(WidgetTester tester) async {
    Widget? shown;
    bool done = false;
    unawaited(runLegalConsentGate(container, show: (app) => shown = app).then((_) => done = true));
    await tester.pump(); // lecture des préférences
    if (shown != null) await tester.pumpWidget(shown!);
    return (shown: shown, done: () => done);
  }

  testWidgets('update from a version without consent: full-screen gate, the app waits until accepted', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'onboarding.full_scan_completed': true});
    final gate = await startGate(tester);

    expect(gate.shown, isNotNull);
    expect(find.text('Conditions mises à jour'), findsOneWidget);
    expect(find.textContaining('version du ${LegalScreen.lastUpdated}'), findsOneWidget);
    expect(gate.done(), isFalse);

    // Ni le bouton retour ni la lecture des textes ne valent acceptation.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    for (final String document in const [LegalScreen.terms, LegalScreen.privacy]) {
      await tester.tap(find.widgetWithText(TextButton, document));
      await tester.pumpAndSettle();
      expect(find.byType(SelectableText), findsOneWidget, reason: '$document should open expanded');
      await tester.pageBack();
      await tester.pumpAndSettle();
    }
    expect(gate.done(), isFalse);
    expect((await SharedPreferences.getInstance()).getString('legal.accepted_version'), isNull);

    await tester.tap(find.text('Accepter et continuer'));
    await tester.pumpAndSettle();

    expect(gate.done(), isTrue);
    expect((await SharedPreferences.getInstance()).getString('legal.accepted_version'), LegalScreen.lastUpdated);
  });

  testWidgets('first launch: the same gate welcomes the user before the onboarding', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final gate = await startGate(tester);

    expect(find.text('Bienvenue sur Vibe'), findsOneWidget);
    expect(gate.done(), isFalse);
  });

  testWidgets('consent given to older texts is asked again', (tester) async {
    SharedPreferences.setMockInitialValues({
      'onboarding.full_scan_completed': true,
      'legal.accepted_version': '1er octobre 2026',
    });
    final gate = await startGate(tester);

    expect(find.text('Accepter et continuer'), findsOneWidget);
    expect(gate.done(), isFalse);
  });

  testWidgets('consent to the current texts: nothing shown, the app starts right away', (tester) async {
    SharedPreferences.setMockInitialValues({
      'onboarding.full_scan_completed': true,
      'legal.accepted_version': LegalScreen.lastUpdated,
    });
    final gate = await startGate(tester);

    expect(gate.shown, isNull);
    expect(gate.done(), isTrue);
  });
}
