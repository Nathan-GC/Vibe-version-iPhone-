import 'dart:convert';

import 'package:drift/drift.dart' show OrderingTerm, Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/identity/track_key.dart';
import 'package:playlist_app/core/storage/database/app_database.dart';
import 'package:playlist_app/core/storage/database/track_repository.dart';
import 'package:playlist_app/core/storage/scanner/scanned_track.dart';
import 'package:playlist_app/features/library/data/quick_rename_service.dart';
import 'package:playlist_app/features/playlists/data/playlist_manifest_service.dart';

void main() {
  late AppDatabase db;
  late TrackRepository tracks;
  late PlaylistManifestService manifests;
  late QuickRenameService service;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    tracks = TrackRepository(db);
    manifests = PlaylistManifestService(db);
    service = QuickRenameService(db, tracks);
  });

  tearDown(() => db.close());

  // `upsertTrack` relie déjà chaque morceau à « Tous les titres importés ».
  Future<String> addTrack(String title, List<String> artists) async {
    final String id = buildSanitizedKey(title: title, album: '', primaryArtist: artists.first);
    await tracks.upsertTrack(ScannedTrack(
      id: id,
      title: title,
      album: '',
      primaryArtist: artists.first,
      artists: artists,
      filePath: '/music/$id.mp3',
      durationMs: 200000,
      requiresUserReview: false,
      trimStartMs: 0,
      trimEndMs: 0,
    ));
    return id;
  }

  /// Export réel de « Tous les titres importés », décodé pour être retouché
  /// comme le ferait l'IA.
  Future<Map<String, dynamic>> exported() async {
    final String json = await manifests.exportManifestJson(kAllImportedPlaylistId, author: 'Nathan');
    return (jsonDecode(json) as Map).cast<String, dynamic>();
  }

  List<Map<String, dynamic>> entries(Map<String, dynamic> file) =>
      (file['tracks'] as List<dynamic>).cast<Map<String, dynamic>>();

  Future<QuickRenameAnalysis> analyzeFile(Object file) => service.analyze(jsonEncode(file));

  QuickRenamePlan planOf(QuickRenameAnalysis result) {
    expect(result, isA<QuickRenameSuccess>(), reason: result is QuickRenameFailure ? result.message : null);
    return (result as QuickRenameSuccess).plan;
  }

  String failureOf(QuickRenameAnalysis result) {
    expect(result, isA<QuickRenameFailure>());
    return (result as QuickRenameFailure).message;
  }

  Future<Track> trackOf(String id) => (db.select(db.tracks)..where((t) => t.id.equals(id))).getSingle();

  Future<List<String>> artistRows(String id) async {
    final rows = await (db.select(db.trackArtists)
          ..where((t) => t.trackId.equals(id))
          ..orderBy([(t) => OrderingTerm.asc(t.position)]))
        .get();
    return rows.map((r) => r.artistName).toList();
  }

  group('aller-retour et renommage par id', () {
    test('fichier inchangé : aucun changement, tous comptés comme inchangés', () async {
      await addTrack('Halo', ['Beyoncé']);
      await addTrack('Move', ['Alpha', 'Bravo']);

      final QuickRenamePlan plan = planOf(await analyzeFile(await exported()));

      expect(plan.items, isEmpty);
      expect(plan.changes, isEmpty);
      expect(plan.unchangedCount, 2);
    });

    test('titre seul : artistes inchangés', () async {
      final String id = await addTrack('halo', ['Beyoncé']);
      final Map<String, dynamic> file = await exported();
      entries(file).single['title'] = '  Halo  ';

      final QuickRenamePlan plan = planOf(await analyzeFile(file));

      expect(plan.items, hasLength(1));
      final QuickRenameItem item = plan.items.single;
      expect(item.trackId, id);
      expect(item.oldTitle, 'halo');
      expect(item.newTitle, 'Halo');
      expect(item.oldArtist, 'Beyoncé');
      expect(item.newArtist, 'Beyoncé');
      expect(plan.changes.single.title, 'Halo');
      expect(plan.changes.single.artists, ['Beyoncé']);
      expect(plan.unchangedCount, 0);
    });

    test('artiste seul : le titre reste', () async {
      final String id = await addTrack('Halo', ['beyonce']);
      final Map<String, dynamic> file = await exported();
      entries(file).single['artist'] = 'Beyoncé';

      final QuickRenamePlan plan = planOf(await analyzeFile(file));

      expect(plan.items.single.trackId, id);
      expect(plan.items.single.newTitle, 'Halo');
      expect(plan.items.single.oldArtist, 'beyonce');
      expect(plan.items.single.newArtist, 'Beyoncé');
      expect(plan.changes.single.artists, ['Beyoncé']);
    });

    test('titre et artiste ensemble, l\'album du fichier est ignoré', () async {
      await addTrack('halo', ['beyonce']);
      final Map<String, dynamic> file = await exported();
      entries(file).single
        ..['title'] = 'Halo'
        ..['artist'] = 'Beyoncé'
        ..['album'] = 'Un autre album';

      final QuickRenamePlan plan = planOf(await analyzeFile(file));

      expect(plan.items, hasLength(1));
      expect(plan.changes.single.title, 'Halo');
      expect(plan.changes.single.artists, ['Beyoncé']);
    });

    test('fichier partiel par id : les titres absents ne sont pas touchés', () async {
      await addTrack('Alpha', ['A']);
      final String b = await addTrack('bravo', ['B']);
      await addTrack('Charlie', ['C']);
      final Map<String, dynamic> file = await exported();
      final List<Map<String, dynamic>> all = entries(file);
      file['tracks'] = [all[1]..['title'] = 'Bravo'];

      final QuickRenamePlan plan = planOf(await analyzeFile(file));

      expect(plan.items.map((i) => i.trackId), [b]);
      expect(plan.unchangedCount, 0);
    });

    test('l\'ordre du fichier n\'importe pas quand les id sont là', () async {
      final String a = await addTrack('alpha', ['A']);
      final String b = await addTrack('bravo', ['B']);
      final Map<String, dynamic> file = await exported();
      final List<Map<String, dynamic>> all = entries(file);
      file['tracks'] = [all[1]..['title'] = 'Bravo', all[0]..['title'] = 'Alpha'];

      final QuickRenamePlan plan = planOf(await analyzeFile(file));

      expect(plan.items.map((i) => i.trackId), [b, a]);
    });

    test('id inconnu : refus, position citée', () async {
      await addTrack('Alpha', ['A']);
      final Map<String, dynamic> file = await exported();
      entries(file).first['id'] = 'inconnu-123';

      final String message = failureOf(await analyzeFile(file));

      expect(message, contains('n°1'));
      expect(message, contains('inconnu-123'));
    });

    test('id en double dans le fichier : refus', () async {
      await addTrack('Alpha', ['A']);
      await addTrack('Bravo', ['B']);
      final Map<String, dynamic> file = await exported();
      final List<Map<String, dynamic>> all = entries(file);
      all[1]['id'] = all[0]['id'];

      final String message = failureOf(await analyzeFile(file));

      expect(message, contains('n°2'));
      expect(message, contains('n°1'));
    });

    test('mélange avec / sans id : refus', () async {
      await addTrack('Alpha', ['A']);
      await addTrack('Bravo', ['B']);
      final Map<String, dynamic> file = await exported();
      entries(file).last.remove('id');

      final String message = failureOf(await analyzeFile(file));

      expect(message, contains('id'));
    });
  });

  group('correspondance par position', () {
    Future<Map<String, dynamic>> exportedWithoutIds() async {
      final Map<String, dynamic> file = await exported();
      for (final Map<String, dynamic> e in entries(file)) {
        e.remove('id');
      }
      return file;
    }

    test('même nombre de titres : renommage par position', () async {
      final String a = await addTrack('alpha', ['A']);
      await addTrack('Bravo', ['B']);
      final Map<String, dynamic> file = await exportedWithoutIds();
      entries(file).first['title'] = 'Alpha';

      final QuickRenamePlan plan = planOf(await analyzeFile(file));

      expect(plan.items.map((i) => i.trackId), [a]);
      expect(plan.unchangedCount, 1);
    });

    test('nombre différent : refus, les deux nombres sont donnés', () async {
      await addTrack('Alpha', ['A']);
      await addTrack('Bravo', ['B']);
      final Map<String, dynamic> file = await exportedWithoutIds();
      (file['tracks'] as List<dynamic>).removeLast();

      final String message = failureOf(await analyzeFile(file));

      expect(message, contains('1'));
      expect(message, contains('2'));
    });

    test('manifeste d\'une autre playlist de même longueur : refus', () async {
      await addTrack('Alpha', ['A']);
      final Map<String, dynamic> file = await exportedWithoutIds();
      file['id'] = 'ma-playlist';

      final String message = failureOf(await analyzeFile(file));

      expect(message, contains('Tous les titres importés'));
    });

    test('tableau nu sans id : seule la règle du nombre s\'applique', () async {
      final String a = await addTrack('alpha', ['A']);
      await addTrack('Bravo', ['B']);

      final QuickRenamePlan plan = planOf(await analyzeFile([
        {'title': 'Alpha', 'artist': 'A'},
        {'title': 'Bravo', 'artist': 'B'},
      ]));
      expect(plan.items.map((i) => i.trackId), [a]);

      final String message = failureOf(await analyzeFile([
        {'title': 'Alpha', 'artist': 'A'},
      ]));
      expect(message, contains('2'));
    });

    test('tableau nu avec id : correspondance par id', () async {
      final String a = await addTrack('alpha', ['A']);
      await addTrack('Bravo', ['B']);

      final QuickRenamePlan plan = planOf(await analyzeFile([
        {'id': a, 'title': 'Alpha', 'artist': 'A'},
      ]));

      expect(plan.items.map((i) => i.trackId), [a]);
    });
  });

  group('lecture et validation', () {
    test('JSON invalide', () async {
      await addTrack('Alpha', ['A']);
      expect(failureOf(await service.analyze('{pas du json')), isNotEmpty);
      expect(failureOf(await service.analyze('')), isNotEmpty);
    });

    test('ni objet ni tableau', () async {
      expect(failureOf(await service.analyze('42')), isNotEmpty);
      expect(failureOf(await service.analyze('"texte"')), isNotEmpty);
    });

    test('objet sans liste tracks', () async {
      expect(failureOf(await service.analyze('{"id": "all-imported-tracks"}')), contains('tracks'));
      expect(failureOf(await service.analyze('{"tracks": 3}')), contains('tracks'));
    });

    test('titre vide : refus avec la position', () async {
      await addTrack('Alpha', ['A']);
      await addTrack('Bravo', ['B']);
      final Map<String, dynamic> file = await exported();
      entries(file)[1]['title'] = '   ';

      final String message = failureOf(await analyzeFile(file));

      expect(message, contains('Titre n°2'));
    });

    test('artiste vide ou absent : refus avec la position', () async {
      await addTrack('Alpha', ['A']);
      await addTrack('Bravo', ['B']);
      final Map<String, dynamic> file = await exported();
      entries(file)[0].remove('artist');

      expect(failureOf(await analyzeFile(file)), contains('Titre n°1'));
    });

    test('entrée qui n\'est pas un objet : refus avec la position', () async {
      expect(failureOf(await analyzeFile(['juste du texte'])), contains('Titre n°1'));
    });

    test('un refus n\'écrit rien', () async {
      final String id = await addTrack('alpha', ['A']);
      final Map<String, dynamic> file = await exported();
      entries(file).single['title'] = 'Alpha';
      entries(file).add({'id': 'inconnu', 'title': 'X', 'artist': 'Y'});

      failureOf(await analyzeFile(file));

      expect((await trackOf(id)).title, 'alpha');
      expect((await trackOf(id)).identityLocked, isFalse);
    });
  });

  group('artistes', () {
    test('« A feat. B » devient [A, B]', () async {
      await addTrack('Titre', ['x']);
      final Map<String, dynamic> file = await exported();
      entries(file).single['artist'] = 'A feat. B';

      final QuickRenamePlan plan = planOf(await analyzeFile(file));

      expect(plan.changes.single.artists, ['A', 'B']);
      expect(plan.items.single.newArtist, 'A feat. B');
    });

    /// Un morceau par intitulé de fichier, un seul import : évite de recréer une
    /// base par cas.
    Future<List<List<String>>> splitAll(List<String> fields) async {
      for (int i = 0; i < fields.length; i++) {
        await addTrack('Titre $i', ['x$i']);
      }
      final Map<String, dynamic> file = await exported();
      final List<Map<String, dynamic>> all = entries(file);
      for (int i = 0; i < fields.length; i++) {
        all[i]['artist'] = fields[i];
      }
      return planOf(await analyzeFile(file)).changes.map((c) => c.artists).toList();
    }

    test('variantes de marqueur : (ft. B), [feat B], FT B, Featuring B', () async {
      final List<List<String>> result =
          await splitAll(['A (ft. B)', 'A [feat B]', 'A FT B', 'A Featuring B', 'A  feat.  B ']);

      expect(result, everyElement(['A', 'B']));
    });

    test('« Earth, Wind & Fire » et « Mumford & Sons » restent entiers', () async {
      final List<List<String>> result = await splitAll(['Earth, Wind & Fire', 'Mumford & Sons', 'Simon x Garfunkel']);

      expect(result, [
        ['Earth, Wind & Fire'],
        ['Mumford & Sons'],
        ['Simon x Garfunkel'],
      ]);
    });

    test('« A featuring B & C » : la clause invitée n\'est pas redécoupée', () async {
      await addTrack('Titre', ['x']);
      final Map<String, dynamic> file = await exported();
      entries(file).single['artist'] = 'A featuring B & C';

      final QuickRenamePlan plan = planOf(await analyzeFile(file));

      expect(plan.changes.single.artists, ['A', 'B & C']);
      expect(plan.items.single.newArtist, 'A feat. B & C');
    });

    test('un nom contenant « ft » dans un mot n\'est pas coupé', () async {
      await addTrack('Titre', ['x']);
      final Map<String, dynamic> file = await exported();
      entries(file).single['artist'] = 'Daft Punk';

      expect(planOf(await analyzeFile(file)).changes.single.artists, ['Daft Punk']);
    });

    test('une lettre accentuée devant « ft » compte comme lettre : pas de coupure', () async {
      await addTrack('Titre', ['x']);
      final Map<String, dynamic> file = await exported();
      entries(file).single['artist'] = 'Séft Ëfeat';

      expect(planOf(await analyzeFile(file)).changes.single.artists, ['Séft Ëfeat']);
    });

    test('ancien featuring contenu dans le nouveau nom (mauvais découpage) : non repris', () async {
      await addTrack('September', ['Earth', 'Wind', 'Fire']);
      final Map<String, dynamic> file = await exported();
      entries(file).single['artist'] = 'Earth, Wind & Fire';

      expect(planOf(await analyzeFile(file)).changes.single.artists, ['Earth, Wind & Fire']);
    });

    test('anciens featurings conservés, sans doublon insensible à la casse', () async {
      await addTrack('Titre', ['Old', 'Guest1', 'Guest2']);
      final Map<String, dynamic> file = await exported();
      entries(file).single['artist'] = 'New feat. guest1';

      final QuickRenamePlan plan = planOf(await analyzeFile(file));

      expect(plan.changes.single.artists, ['New', 'guest1', 'Guest2']);
      expect(plan.items.single.oldArtist, 'Old feat. Guest1, Guest2');
      expect(plan.items.single.newArtist, 'New feat. guest1, Guest2');
    });

    test('artiste inchangé : liste d\'artistes inchangée, même avec featurings', () async {
      await addTrack('halo', ['Beyoncé', 'Jay-Z']);
      final Map<String, dynamic> file = await exported();
      entries(file).single['title'] = 'Halo';

      final QuickRenamePlan plan = planOf(await analyzeFile(file));

      expect(plan.changes.single.artists, ['Beyoncé', 'Jay-Z']);
      expect(plan.items.single.oldArtist, 'Beyoncé feat. Jay-Z');
      expect(plan.items.single.newArtist, 'Beyoncé feat. Jay-Z');
    });

    test('artiste principal réécrit à l\'identique après split : titre inchangé', () async {
      // « Beyoncé feat. Jay-Z » est déjà la liste actuelle : pas de modification.
      await addTrack('Halo', ['Beyoncé', 'Jay-Z']);
      final Map<String, dynamic> file = await exported();
      entries(file).single['artist'] = 'Beyoncé feat. Jay-Z';

      final QuickRenamePlan plan = planOf(await analyzeFile(file));

      expect(plan.items, isEmpty);
      expect(plan.unchangedCount, 1);
    });

    test('espaces multiples normalisés', () async {
      await addTrack('Titre', ['x']);
      final Map<String, dynamic> file = await exported();
      entries(file).single['artist'] = 'A   B feat. C   D';

      expect(planOf(await analyzeFile(file)).changes.single.artists, ['A B', 'C D']);
    });

    test('artiste principal vide après découpage : refus pour ce titre', () async {
      await addTrack('Alpha', ['A']);
      await addTrack('Bravo', ['B']);
      final Map<String, dynamic> file = await exported();
      entries(file)[1]['artist'] = 'feat. B';

      final String message = failureOf(await analyzeFile(file));

      expect(message, contains('Titre n°2'));
    });

    test('liste d\'artistes vide : l\'export écrit « Unknown », inchangé', () async {
      // Cas limite : un morceau sans artiste en base (liste vide).
      final String id = await addTrack('Titre', ['x']);
      await (db.update(db.tracks)..where((t) => t.id.equals(id))).write(const TracksCompanion(artists: Value([])));
      final Map<String, dynamic> file = await exported();
      expect(entries(file).single['artist'], 'Unknown');

      expect(planOf(await analyzeFile(file)).items, isEmpty);
    });
  });

  group('apply', () {
    test('écrit titre, track_artists et verrou, renvoie le nombre modifié', () async {
      final String a = await addTrack('alpha', ['old']);
      final String b = await addTrack('Bravo', ['B']);
      final Map<String, dynamic> file = await exported();
      entries(file)[0]
        ..['title'] = 'Alpha'
        ..['artist'] = 'New feat. Guest';

      final QuickRenamePlan plan = planOf(await analyzeFile(file));
      final int modified = await service.apply(plan);

      expect(modified, 1);
      final Track updated = await trackOf(a);
      expect(updated.id, a);
      expect(updated.title, 'Alpha');
      expect(updated.artists, ['New', 'Guest']);
      expect(updated.identityLocked, isTrue);
      expect(await artistRows(a), ['New', 'Guest']);

      final Track untouched = await trackOf(b);
      expect(untouched.title, 'Bravo');
      expect(untouched.identityLocked, isFalse);
    });

    test('plan vide : rien n\'est écrit', () async {
      await addTrack('Alpha', ['A']);
      final QuickRenamePlan plan = planOf(await analyzeFile(await exported()));

      expect(await service.apply(plan), 0);
    });
  });
}
