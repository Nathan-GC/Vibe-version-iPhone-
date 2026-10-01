import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/audio_engine/preview_player_controller.dart';
import 'package:playlist_app/core/shared/widgets/library_category_picker.dart';
import 'package:playlist_app/core/shared/widgets/track_actions_sheet.dart';
import 'package:playlist_app/core/storage/database/app_database.dart';
import 'package:playlist_app/core/storage/database/database_provider.dart';
import 'package:playlist_app/core/storage/database/library_category.dart';
import 'package:playlist_app/core/storage/database/track_enricher.dart';
import 'package:playlist_app/core/storage/database/track_repository.dart';
import 'package:playlist_app/core/storage/scanner/scanned_track.dart';
import 'package:playlist_app/features/library/data/library_providers.dart';

void main() {
  late AppDatabase db;
  late TrackRepository repository;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repository = TrackRepository(db);
  });
  tearDown(() => db.close());

  /// Titre en "Échec auto" : tentatives automatiques épuisées
  /// (`needsManualReview`), donc déjà rangé sous "À enrichir".
  Future<Track> insertAutoFailedTrack(WidgetTester tester) async {
    return (await tester.runAsync(() async {
      await repository.upsertTrack(const ScannedTrack(
        id: 't1',
        title: 'Bootleg Mix',
        album: '',
        primaryArtist: 'Some DJ',
        artists: ['Some DJ'],
        filePath: '/music/t1.mp3',
        durationMs: 180000,
        requiresUserReview: false,
        trimStartMs: 0,
        trimEndMs: 0,
      ));
      for (int i = 0; i < TrackRepository.maxEnrichmentAttempts; i++) {
        await repository.recordEnrichmentOutcome('t1', success: false, source: EnrichmentSource.musicBrainz);
      }
      return repository.findById('t1');
    }))!;
  }

  Future<Track> reload(WidgetTester tester) async => (await tester.runAsync(() => repository.findById('t1')))!;

  /// Bibliothèque minimale : un bouton ouvre la vraie feuille d'appui long
  /// ([TrackActionsSheet], comme LibraryScreen) — base en mémoire, lecteur
  /// d'extraits neutralisé (aucun AudioPlayer natif en test).
  Widget harness(Track track) {
    return ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        previewPlayerControllerProvider.overrideWithValue(null),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => TrackActionsSheet.show(context, track, showChangeCategory: true),
              child: const Text('appui long'),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('tapping "À enrichir" on an "Échec auto" track resets it through the picker (bogue QA 4c)',
      (tester) async {
    final Track failed = await insertAutoFailedTrack(tester);
    expect(failed.enrichmentStatus, EnrichmentStatus.needsManualReview);
    expect(libraryCategoryOf(failed), LibraryCategory.toEnrich, reason: 'déjà dans la catégorie visée');
    expect(trackNeedsEnrichment(failed), isFalse, reason: 'exclu d\'"Enrichir tout" avant la réinitialisation');

    await tester.pumpWidget(harness(failed));
    await tester.tap(find.text('appui long'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Changer de catégorie'));
    await tester.pumpAndSettle();
    expect(find.byType(SimpleDialog), findsOneWidget);
    expect(find.textContaining('Échec auto : réinitialise les tentatives'), findsOneWidget);

    await tester.tap(find.descendant(of: find.byType(SimpleDialog), matching: find.text('À enrichir')));
    // L'écriture Drift se termine hors de l'horloge simulée du test.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();

    expect(find.byType(SimpleDialog), findsNothing);
    expect(find.textContaining('Échec auto réinitialisé'), findsOneWidget, reason: 'confirmation visuelle');

    final Track reset = await reload(tester);
    expect(reset.enrichmentStatus, EnrichmentStatus.pending);
    expect(reset.enrichmentAttempts, 0);
    expect(trackNeedsEnrichment(reset), isTrue, reason: 'de nouveau éligible à "Enrichir tout"');
  });

  testWidgets('dismissing the picker changes nothing', (tester) async {
    final Track failed = await insertAutoFailedTrack(tester);

    await tester.pumpWidget(harness(failed));
    await tester.tap(find.text('appui long'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Changer de catégorie'));
    await tester.pumpAndSettle();

    await tester.tapAt(const Offset(5, 5)); // hors de la boîte de dialogue
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();

    expect(find.byType(SimpleDialog), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
    final Track unchanged = await reload(tester);
    expect(unchanged.enrichmentStatus, EnrichmentStatus.needsManualReview);
  });

  testWidgets('the picker returns the current category instead of null when it is tapped', (tester) async {
    LibraryCategory? result;
    bool completed = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showLibraryCategoryPicker(context, current: LibraryCategory.toEnrich);
              completed = true;
            },
            child: const Text('ouvrir'),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('ouvrir'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('À enrichir'));
    await tester.pumpAndSettle();

    expect(completed, isTrue);
    expect(result, LibraryCategory.toEnrich);
  });
}
