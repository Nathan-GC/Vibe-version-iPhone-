import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/features/settings/presentation/legal_screen.dart';

void main() {
  testWidgets('every legal document expands and the licences entry opens the licence page', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: LegalScreen()));

    for (final String title in const [
      'Mentions légales',
      'Politique de confidentialité',
      'Conditions d\'utilisation',
      'Tarifs et remboursement',
      'Cookies et traceurs',
      'Âge minimum',
      'Suppression de vos données',
      'Crédits',
    ]) {
      await tester.scrollUntilVisible(find.text(title), 100);
      await tester.tap(find.text(title));
      await tester.pumpAndSettle();
      expect(find.byType(SelectableText), findsWidgets, reason: '$title should reveal its text');
      await tester.tap(find.text(title)); // referme pour garder la liste courte
      await tester.pumpAndSettle();
    }

    await tester.scrollUntilVisible(find.text('Licences open source'), 100);
    await tester.tap(find.text('Licences open source'));
    await tester.pumpAndSettle();
    expect(find.byType(LicensePage), findsOneWidget);
  });

  testWidgets('iOS: the privacy and erasure texts describe iOS, not Android', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await tester.pumpWidget(const MaterialApp(home: LegalScreen()));

    for (final String title in const ['Politique de confidentialité', 'Suppression de vos données']) {
      await tester.scrollUntilVisible(find.text(title), 100);
      await tester.tap(find.text(title));
      await tester.pumpAndSettle();
      final String body = tester.widget<SelectableText>(find.byType(SelectableText)).data!;
      expect(body, isNot(contains('Android')), reason: title);
      expect(body, contains('iOS'), reason: title);
      await tester.tap(find.text(title));
      await tester.pumpAndSettle();
    }
    debugDefaultTargetPlatformOverride = null;
  });
}
