import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/playlist_manifest/manifest_track_ref.dart';
import 'package:playlist_app/features/diff/domain/diff_result.dart';
import 'package:playlist_app/features/diff/presentation/diff_modal.dart';

void main() {
  const ManifestTrackRef a = ManifestTrackRef(title: 'Teardrop', artist: 'Massive Attack');
  const ManifestTrackRef b = ManifestTrackRef(title: 'Intro', artist: 'The xx');

  Future<void> show(WidgetTester tester, DiffResult diff) {
    return tester.pumpWidget(MaterialApp(home: Scaffold(body: DiffModal(diff: diff, onAccept: () {}))));
  }

  DiffResult diff({
    int local = 1,
    int incoming = 1,
    List<ManifestTrackRef> added = const [],
    List<ManifestTrackRef> removed = const [],
    bool contentChanged = false,
    bool orderChanged = false,
  }) =>
      DiffResult(
        localVersion: local,
        incomingVersion: incoming,
        added: added,
        removed: removed,
        contentChanged: contentChanged,
        orderChanged: orderChanged,
      );

  testWidgets('title shows both versions when they differ', (tester) async {
    await show(tester, diff(local: 2, incoming: 3, added: [a], contentChanged: true));
    expect(find.text('Mise à jour disponible (v2 → v3)'), findsOneWidget);
  });

  testWidgets('title shows a single version when equal', (tester) async {
    await show(tester, diff(local: 2, incoming: 2, contentChanged: true, orderChanged: true));
    expect(find.text('Mise à jour disponible (v2)'), findsOneWidget);
  });

  testWidgets('same tracks in a new order: dedicated sentence, no columns', (tester) async {
    await show(tester, diff(contentChanged: true, orderChanged: true));
    expect(find.text('Mêmes morceaux, dans un nouvel ordre.'), findsOneWidget);
    expect(find.text('+ Ajoutés'), findsNothing);
  });

  testWidgets('added/removed and reordered: columns plus the order line', (tester) async {
    await show(tester, diff(added: [a], removed: [b], contentChanged: true, orderChanged: true));
    expect(find.text('+ Ajoutés'), findsOneWidget);
    expect(find.text('- Retirés'), findsOneWidget);
    expect(find.text("L'ordre des titres change aussi."), findsOneWidget);
  });

  testWidgets('added/removed without reordering: no order line', (tester) async {
    await show(tester, diff(local: 1, incoming: 2, added: [a], contentChanged: true));
    expect(find.text("L'ordre des titres change aussi."), findsNothing);
    expect(find.text('Mêmes morceaux, dans un nouvel ordre.'), findsNothing);
  });

  testWidgets('nothing changes: historical text', (tester) async {
    await show(tester, diff(local: 1, incoming: 2));
    expect(find.text('Aucun changement de morceaux, seule la version a été mise à jour.'), findsOneWidget);
  });

  testWidgets('"Accepter la mise à jour" calls onAccept', (tester) async {
    bool accepted = false;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => showDialog<void>(
            context: context,
            builder: (_) => DiffModal(diff: diff(added: [a], contentChanged: true), onAccept: () => accepted = true),
          ),
          child: const Text('ouvrir'),
        ),
      ),
    ));
    await tester.tap(find.text('ouvrir'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Accepter la mise à jour'));
    await tester.pumpAndSettle();
    expect(accepted, isTrue);
  });
}
