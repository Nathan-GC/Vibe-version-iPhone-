import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/purge/orphan_purge_service.dart';
import 'package:playlist_app/core/storage/database/app_database.dart';
import 'package:playlist_app/core/storage/database/library_category.dart';
import 'package:playlist_app/core/storage/database/track_enricher.dart';
import 'package:playlist_app/core/storage/database/track_repository.dart';
import 'package:playlist_app/core/storage/scanner/scanned_track.dart';
import 'package:playlist_app/features/library/data/library_providers.dart';

Track _track(
  String id, {
  EnrichmentStatus status = EnrichmentStatus.pending,
  bool requiresUserReview = false,
}) {
  return Track(
    id: id,
    title: 'Title $id',
    album: '',
    releaseYear: 0,
    artists: const ['Artist'],
    durationSeconds: 180,
    bpm: 120,
    trimStartMs: 0,
    trimEndMs: 0,
    filePath: '/music/$id.mp3',
    coverArtPath: '',
    tags: const [],
    createdAt: DateTime(2026),
    requiresUserReview: requiresUserReview,
    playCount: 0,
    lastModifiedEpochMs: 0,
    trackNumber: 0,
    discNumber: 0,
    trackCount: 0,
    enrichmentAttempts: 0,
    enrichmentStatus: status,
  );
}

void main() {
  group('libraryCategoryOf', () {
    test('an ambiguous filename is "À renommer", whatever its enrichment status', () {
      expect(libraryCategoryOf(_track('a', requiresUserReview: true)), LibraryCategory.toRename);
      expect(libraryCategoryOf(_track('b', status: EnrichmentStatus.requiresReview)), LibraryCategory.toRename);
      expect(
        libraryCategoryOf(_track('c', status: EnrichmentStatus.enrichedAutoItunes, requiresUserReview: true)),
        LibraryCategory.toRename,
      );
    });

    test('pending and exhausted auto attempts are "À enrichir"', () {
      expect(libraryCategoryOf(_track('a')), LibraryCategory.toEnrich);
      expect(libraryCategoryOf(_track('b', status: EnrichmentStatus.needsManualReview)), LibraryCategory.toEnrich);
    });

    test('every enriched provenance is "Renommé et enrichi"', () {
      for (final status in kEnrichedStatuses) {
        expect(libraryCategoryOf(_track('a', status: status)), LibraryCategory.done, reason: '$status');
      }
    });

    test('the three categories partition every possible status', () {
      for (final status in EnrichmentStatus.values) {
        final LibraryCategory category = libraryCategoryOf(_track('a', status: status));
        expect(LibraryCategory.values, contains(category));
      }
    });
  });

  group('filterLibraryTracks', () {
    final List<Track> library = [
      _track('rename', requiresUserReview: true, status: EnrichmentStatus.requiresReview),
      _track('pending'),
      _track('failed', status: EnrichmentStatus.needsManualReview),
      _track('mbManual', status: EnrichmentStatus.enrichedManualMusicBrainz),
      _track('itManual', status: EnrichmentStatus.enrichedManualItunes),
      _track('fullManual', status: EnrichmentStatus.enrichedManualEdit),
      _track('mbAuto', status: EnrichmentStatus.enrichedAutoMusicBrainz),
      _track('itAuto', status: EnrichmentStatus.enrichedAutoItunes),
    ];
    List<String> ids(List<Track> tracks) => tracks.map((t) => t.id).toList();

    test('no filter returns the whole library', () {
      expect(filterLibraryTracks(library, const LibraryFilterState()), library);
    });

    test('a main category keeps only its tracks', () {
      expect(
          ids(filterLibraryTracks(library, const LibraryFilterState(category: LibraryCategory.toRename))), ['rename']);
      expect(ids(filterLibraryTracks(library, const LibraryFilterState(category: LibraryCategory.toEnrich))),
          ['pending', 'failed']);
      expect(
        ids(filterLibraryTracks(library, const LibraryFilterState(category: LibraryCategory.done))),
        ['mbManual', 'itManual', 'fullManual', 'mbAuto', 'itAuto'],
      );
    });

    test('provenance sub-categories combine with OR inside their category', () {
      const filter = LibraryFilterState(
        category: LibraryCategory.done,
        provenances: {EnrichmentProvenanceFilter.musicBrainzAuto, EnrichmentProvenanceFilter.fullyManual},
      );
      expect(ids(filterLibraryTracks(library, filter)), ['fullManual', 'mbAuto']);
    });

    test('"Enrichi totalement manuellement" no longer includes the iTunes/MusicBrainz manual variants', () {
      const filter = LibraryFilterState(
        category: LibraryCategory.done,
        provenances: {EnrichmentProvenanceFilter.fullyManual},
      );
      expect(ids(filterLibraryTracks(library, filter)), ['fullManual']);
    });

    test('"Enrichir tout" targets only "À enrichir" tracks not yet circuit-broken', () {
      expect(ids(library.where(trackNeedsEnrichment).toList()), ['pending']);
    });
  });

  group('LibraryFilterController', () {
    late ProviderContainer container;

    setUp(() => container = ProviderContainer());
    tearDown(() => container.dispose());

    LibraryFilterController controller() => container.read(libraryFilterProvider.notifier);
    LibraryFilterState state() => container.read(libraryFilterProvider);

    test('switching main category clears the provenance sub-filters', () {
      controller().toggleProvenance(EnrichmentProvenanceFilter.itunesAuto);
      expect(state().category, LibraryCategory.done);
      expect(state().provenances, {EnrichmentProvenanceFilter.itunesAuto});

      controller().toggleCategory(LibraryCategory.toEnrich);
      expect(state().category, LibraryCategory.toEnrich);
      expect(state().provenances, isEmpty);
    });

    test('toggling the selected category again clears the filter', () {
      controller().toggleCategory(LibraryCategory.toRename);
      controller().toggleCategory(LibraryCategory.toRename);
      expect(state().isActive, isFalse);
    });
  });

  group('TrackRepository.forceLibraryCategory', () {
    late AppDatabase db;
    late TrackRepository repository;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      repository = TrackRepository(db);
    });
    tearDown(() => db.close());

    Future<Track> insert(String id, {bool requiresUserReview = false}) async {
      await repository.upsertTrack(ScannedTrack(
        id: id,
        title: 'Title $id',
        album: '',
        primaryArtist: 'Artist',
        artists: const ['Artist'],
        filePath: '/music/$id.mp3',
        durationMs: 180000,
        requiresUserReview: requiresUserReview,
        trimStartMs: 0,
        trimEndMs: 0,
      ));
      return (await repository.findById(id))!;
    }

    test('moves a track to "À renommer" and out of the auto-enrichment queue', () async {
      await insert('t1');
      await repository.forceLibraryCategory('t1', LibraryCategory.toRename);

      final Track track = (await repository.findById('t1'))!;
      expect(libraryCategoryOf(track), LibraryCategory.toRename);
      expect(track.requiresUserReview, isTrue);
      expect(await repository.shouldAttemptEnrichment('t1'), isFalse);
    });

    test('moves an ambiguous track to "À enrichir" with a fresh attempt counter', () async {
      await insert('t1', requiresUserReview: true);
      await repository.recordEnrichmentOutcome('t1', success: false, source: EnrichmentSource.itunes);
      await repository.forceLibraryCategory('t1', LibraryCategory.toEnrich);

      final Track track = (await repository.findById('t1'))!;
      expect(libraryCategoryOf(track), LibraryCategory.toEnrich);
      expect(track.requiresUserReview, isFalse);
      expect(track.enrichmentStatus, EnrichmentStatus.pending);
      expect(track.enrichmentAttempts, 0);
      expect(trackNeedsEnrichment(track), isTrue);
    });

    test('a never-enriched track forced to done lands in "Enrichi totalement manuellement" (choix 1-A)', () async {
      await insert('t1');
      await repository.forceLibraryCategory('t1', LibraryCategory.done);

      final Track track = (await repository.findById('t1'))!;
      expect(libraryCategoryOf(track), LibraryCategory.done);
      expect(track.enrichmentStatus, EnrichmentStatus.enrichedManualEdit);
      expect(trackNeedsEnrichment(track), isFalse);

      const filter = LibraryFilterState(
        category: LibraryCategory.done,
        provenances: {EnrichmentProvenanceFilter.fullyManual},
      );
      expect(filterLibraryTracks([track], filter), [track], reason: 'visible sous sa sous-catégorie');
    });

    test('forcing an "Échec auto" track to "À enrichir" makes it eligible again for "Enrichir tout"', () async {
      await insert('t1');
      for (int i = 0; i < TrackRepository.maxEnrichmentAttempts; i++) {
        await repository.recordEnrichmentOutcome('t1', success: false, source: EnrichmentSource.musicBrainz);
      }
      final Track failed = (await repository.findById('t1'))!;
      expect(failed.enrichmentStatus, EnrichmentStatus.needsManualReview, reason: 'Échec auto');
      expect(trackNeedsEnrichment(failed), isFalse);
      expect(await repository.shouldAttemptEnrichment('t1'), isFalse);

      await repository.forceLibraryCategory('t1', LibraryCategory.toEnrich);

      final Track reset = (await repository.findById('t1'))!;
      expect(reset.enrichmentStatus, EnrichmentStatus.pending);
      expect(reset.enrichmentAttempts, 0);
      expect(trackNeedsEnrichment(reset), isTrue);
      expect(await repository.shouldAttemptEnrichment('t1'), isTrue);
    });

    test('keeps the real provenance of an already-enriched track moved back to done', () async {
      await insert('t1', requiresUserReview: true);
      await repository.recordEnrichmentOutcome('t1', success: true, source: EnrichmentSource.musicBrainz);
      await repository.forceLibraryCategory('t1', LibraryCategory.done);

      final Track track = (await repository.findById('t1'))!;
      expect(track.enrichmentStatus, EnrichmentStatus.enrichedAutoMusicBrainz);
      expect(track.requiresUserReview, isFalse);
      expect(libraryCategoryOf(track), LibraryCategory.done);
    });
  });

  group('OrphanPurgeService.deleteTracks', () {
    late AppDatabase db;

    setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
    tearDown(() => db.close());

    test('deletes the file and removes the track from every playlist (no ghost row)', () async {
      final Directory dir = await Directory.systemTemp.createTemp('vibe_purge_test');
      addTearDown(() => dir.delete(recursive: true));
      final File file = File('${dir.path}/dup.mp3')..writeAsBytesSync([0, 1, 2]);

      await TrackRepository(db).upsertTrack(ScannedTrack(
        id: 'dup',
        title: 'Dup',
        album: '',
        primaryArtist: 'Artist',
        artists: const ['Artist'],
        filePath: file.path,
        durationMs: 180000,
        requiresUserReview: false,
        trimStartMs: 0,
        trimEndMs: 0,
      ));
      expect(await db.select(db.playlistTracks).get(), hasLength(1), reason: 'linked to "Tous les titres importés"');

      final Track track = await db.select(db.tracks).getSingle();
      await OrphanPurgeService(db).deleteTracks([track]);

      expect(file.existsSync(), isFalse);
      expect(await db.select(db.tracks).get(), isEmpty);
      expect(await db.select(db.trackArtists).get(), isEmpty);
      expect(await db.select(db.playlistTracks).get(), isEmpty);
    });
  });
}
