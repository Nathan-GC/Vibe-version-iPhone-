import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/shared/widgets/blacklisted_import_dialog.dart';
import 'package:playlist_app/core/storage/database/app_database.dart';

void main() {
  final BlacklistedTrack entry = BlacklistedTrack(
    filePath: '/music/a.mp3',
    title: 'Song a',
    artists: const ['Artist'],
    reason: BlacklistReason.manual,
    blacklistedAt: DateTime(2026),
    trackSnapshot: '{}',
  );

  Future<Future<bool>> open(WidgetTester tester) async {
    late Future<bool> answer;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => answer = confirmRestoreBlacklisted(context, entry),
          child: const Text('Importer'),
        ),
      ),
    ));
    await tester.tap(find.text('Importer'));
    await tester.pumpAndSettle();
    return answer;
  }

  testWidgets('asks with the exact wording, "Restaurer" answers true', (tester) async {
    final Future<bool> answer = await open(tester);

    expect(
      find.text('Ce titre figure actuellement dans votre liste noire. '
          'Souhaitez-vous le restaurer dans votre bibliothèque ?'),
      findsOneWidget,
    );
    expect(find.text('« Song a »'), findsOneWidget);
    await tester.tap(find.text('Restaurer'));
    await tester.pumpAndSettle();
    expect(await answer, isTrue);
  });

  testWidgets('"Laisser masqué" (or dismissing) keeps it blacklisted', (tester) async {
    final Future<bool> answer = await open(tester);

    await tester.tap(find.text('Laisser masqué'));
    await tester.pumpAndSettle();
    expect(await answer, isFalse);
  });
}
