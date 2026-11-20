import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/storage/database/quick_rename_change.dart';
import 'package:playlist_app/features/library/data/library_providers.dart';
import 'package:playlist_app/features/library/data/quick_rename_service.dart';
import 'package:playlist_app/features/library/presentation/quick_rename/quick_rename_preview_screen.dart';

/// Faux service : enregistre le plan reçu, sans base.
class _FakeQuickRenameService implements QuickRenameService {
  QuickRenamePlan? applied;

  @override
  Future<int> apply(QuickRenamePlan plan) async {
    applied = plan;
    return plan.changes.length;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

QuickRenamePlan _plan(int count, {int unchanged = 0}) => QuickRenamePlan(
      items: [
        for (int i = 0; i < count; i++)
          QuickRenameItem(
            trackId: 't$i',
            oldTitle: 'vieux titre $i',
            oldArtist: 'vieil artiste',
            newTitle: 'Nouveau titre $i',
            newArtist: 'Nouvel Artiste feat. Invité',
          ),
      ],
      changes: [
        for (int i = 0; i < count; i++)
          QuickRenameChange(trackId: 't$i', title: 'Nouveau titre $i', artists: const ['Nouvel Artiste', 'Invité']),
      ],
      unchangedCount: unchanged,
    );

void main() {
  testWidgets('affiche l\'en-tête, le rappel et les lignes ancien / nouveau', (tester) async {
    final _FakeQuickRenameService fake = _FakeQuickRenameService();
    await tester.pumpWidget(ProviderScope(
      overrides: [quickRenameServiceProvider.overrideWithValue(fake)],
      child: MaterialApp(home: QuickRenamePreviewScreen(plan: _plan(2, unchanged: 1))),
    ));

    expect(find.text('2 titres renommés · 1 inchangé'), findsOneWidget);
    expect(find.textContaining('Pas d\'annulation'), findsOneWidget);
    expect(find.text('vieux titre 0 — vieil artiste'), findsOneWidget);
    expect(find.text('Nouveau titre 0 — Nouvel Artiste feat. Invité'), findsOneWidget);
    expect(find.text('Nouveau titre 1 — Nouvel Artiste feat. Invité'), findsOneWidget);
  });

  testWidgets('singulier pour un seul titre renommé', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [quickRenameServiceProvider.overrideWithValue(_FakeQuickRenameService())],
      child: MaterialApp(home: QuickRenamePreviewScreen(plan: _plan(1, unchanged: 5))),
    ));
    expect(find.text('1 titre renommé · 5 inchangés'), findsOneWidget);
  });

  testWidgets('« Appliquer » appelle le service et renvoie le nombre modifié', (tester) async {
    final _FakeQuickRenameService fake = _FakeQuickRenameService();
    final QuickRenamePlan plan = _plan(3);
    int? result;
    await tester.pumpWidget(ProviderScope(
      overrides: [quickRenameServiceProvider.overrideWithValue(fake)],
      child: MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await Navigator.of(context).push<int>(
              MaterialPageRoute<int>(builder: (_) => QuickRenamePreviewScreen(plan: plan)),
            ),
            child: const Text('ouvrir'),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('ouvrir'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Appliquer'));
    await tester.pumpAndSettle();

    expect(fake.applied, same(plan));
    expect(result, 3);
    expect(find.text('Appliquer'), findsNothing); // Aperçu fermé.
  });

  testWidgets('« Annuler » ferme sans appeler le service', (tester) async {
    final _FakeQuickRenameService fake = _FakeQuickRenameService();
    await tester.pumpWidget(ProviderScope(
      overrides: [quickRenameServiceProvider.overrideWithValue(fake)],
      child: MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push<int>(
              MaterialPageRoute<int>(builder: (_) => QuickRenamePreviewScreen(plan: _plan(1))),
            ),
            child: const Text('ouvrir'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('ouvrir'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Annuler'));
    await tester.pumpAndSettle();

    expect(fake.applied, isNull);
    expect(find.text('Appliquer'), findsNothing);
  });

  test('requête « Enrichir tout » : posée, consommée une seule fois', () {
    final ProviderContainer container = ProviderContainer();
    addTearDown(container.dispose);
    final EnrichAllRequestController controller = container.read(enrichAllRequestProvider.notifier);

    expect(controller.consume(), isFalse);
    controller.request();
    expect(container.read(enrichAllRequestProvider), isTrue);
    expect(controller.consume(), isTrue);
    expect(controller.consume(), isFalse);
    expect(container.read(enrichAllRequestProvider), isFalse);
  });
}
