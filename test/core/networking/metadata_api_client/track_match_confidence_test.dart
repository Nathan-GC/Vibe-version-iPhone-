import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/networking/metadata_api_client/online_track_result.dart';
import 'package:playlist_app/core/networking/metadata_api_client/track_match_confidence.dart';

OnlineTrackResult _track(String artist, String title, {int? durationMs}) =>
    OnlineTrackResult(artist: artist, title: title, durationMs: durationMs);

bool _reliable(String localTitle, String localArtist, OnlineTrackResult candidate) =>
    TrackMatchConfidence.isReliableMatch(localTitle: localTitle, localArtists: [localArtist], candidate: candidate);

void main() {
  group('isReliableMatch', () {
    test('accepts an exact title+artist match', () {
      expect(
        TrackMatchConfidence.isReliableMatch(
          localTitle: 'Only Girl (In The World)',
          localArtists: const ['Rihanna'],
          candidate: _track('Rihanna', 'Only Girl (In The World)'),
        ),
        isTrue,
      );
    });

    test('rejects a different song by the same artist (bad "pochette" risk)', () {
      // Cas réel observé : recherche libre "Charlotte Cardin Feel Good" qui
      // renvoyait "Confetti" du même artiste comme premier résultat.
      expect(
        TrackMatchConfidence.isReliableMatch(
          localTitle: 'Feel Good',
          localArtists: const ['Charlotte Cardin'],
          candidate: _track('Charlotte Cardin', 'Confetti'),
        ),
        isFalse,
      );
    });

    test('rejects a matching title from an unrelated artist', () {
      // Cas réel observé : "Dmitri Shostakovich Waltz No. 2" matchait en
      // premier une reprise violon d'un artiste turc sans rapport.
      expect(
        TrackMatchConfidence.isReliableMatch(
          localTitle: 'Waltz No. 2',
          localArtists: const ['Dmitri Shostakovich'],
          candidate: _track('Cihat Aşkın', 'Waltz No.2'),
        ),
        isFalse,
      );
    });

    test('requires an exact title when the local artist is unknown', () {
      expect(
        TrackMatchConfidence.isReliableMatch(
          localTitle: '4 Raws',
          localArtists: const ['Unknown'],
          candidate: _track('prodbyryan', '4 Raws (slowed)'),
        ),
        isFalse,
      );
      expect(
        TrackMatchConfidence.isReliableMatch(
          localTitle: 'Beto’s Horns (fred remix)',
          localArtists: const ['Unknown'],
          candidate: _track('Fred again.. & CA7RIEL & Paco Amoroso', 'Beto’s Horns (fred remix)'),
        ),
        isTrue,
      );
    });
  });

  group('composite score (titre cœur + artiste local)', () {
    test('accepts a title with a trailing feat. clause (same core title)', () {
      expect(_reliable('Godzilla', 'Eminem', _track('Eminem', 'Godzilla (feat. Juice WRLD)')), isTrue);
    });

    test('accepts a candidate artist listing collaborators of the local artist', () {
      expect(_reliable('Nightcall', 'Kavinsky', _track('Kavinsky, Angèle & Phoenix', 'Nightcall')), isTrue);
    });

    test('rejects a different title by the same artist', () {
      expect(_reliable('Feel Good', 'Charlotte Cardin', _track('Charlotte Cardin', 'Confetti')), isFalse);
    });

    test('rejects a close-but-different title (score below 0.8)', () {
      // Dice du titre = 4/7 (≈ 0,57), artiste = 1 : composite ≈ 0,79 < 0,8.
      expect(_reliable('Dancing Queen', 'ABBA', _track('ABBA', 'Dancing Queen Medley Of Hits')), isFalse);
    });
  });

  group('parité des mots-clés de version', () {
    test('a remix local never matches the standard candidate, and vice versa', () {
      expect(_reliable('Dancin (KRONO Remix)', 'Aaron Smith', _track('Aaron Smith', 'Dancin')), isFalse);
      expect(_reliable('Dancin', 'Aaron Smith', _track('Aaron Smith', 'Dancin (KRONO Remix)')), isFalse);
    });

    test('an instrumental candidate is rejected for a standard local title', () {
      expect(_reliable('Roi', 'Isaac Delusion', _track('Isaac Delusion', 'Roi (Instrumental)')), isFalse);
    });

    test('instrumental in the local title (no brackets, any case) matches a bracketed candidate', () {
      expect(_reliable('Roi INSTRUMENTAL', 'Isaac Delusion', _track('Isaac Delusion', 'Roi (Instrumental)')), isTrue);
      expect(_reliable('Roi instrumentale', 'Isaac Delusion', _track('Isaac Delusion', 'Roi (Instrumental)')), isTrue);
    });

    test('a keyword inside the title itself matches the same title', () {
      expect(_reliable('Live Your Life', 'T.I.', _track('T.I.', 'Live Your Life')), isTrue);
    });

    test('applies without a local artist too', () {
      expect(
        TrackMatchConfidence.pickBestMatch(
          localTitle: 'Roi',
          localArtists: const ['Unknown'],
          candidates: [_track('Isaac Delusion', 'Roi (Instrumental)')],
        ),
        isNull,
      );
    });
  });

  group('Unicode', () {
    test('matches an unaccented local artist with the accented candidate', () {
      expect(_reliable('Halo', 'Beyonce', _track('Beyoncé', 'Halo')), isTrue);
    });

    test('matches the same Cyrillic title and rejects two different ones', () {
      expect(_reliable('Группа крови', 'Кино', _track('Кино', 'Группа крови')), isTrue);
      expect(_reliable('Группа крови', 'Кино', _track('Кино', 'Звезда по имени Солнце')), isFalse);
    });
  });

  group('garde-fou de durée', () {
    bool reliable(OnlineTrackResult candidate, {int? localMs, bool skip = false}) =>
        TrackMatchConfidence.isReliableMatch(
          localTitle: 'One More Time',
          localArtists: const ['Daft Punk'],
          candidate: candidate,
          localDurationMs: localMs,
          skipDurationCheck: skip,
        );

    test('rejects a candidate 20 s away, accepts one 12 s away', () {
      expect(reliable(_track('Daft Punk', 'One More Time', durationMs: 200000), localMs: 180000), isFalse);
      expect(reliable(_track('Daft Punk', 'One More Time', durationMs: 192000), localMs: 180000), isTrue);
    });

    test('no check when the local duration is unknown or the candidate has none', () {
      expect(reliable(_track('Daft Punk', 'One More Time', durationMs: 400000)), isTrue);
      expect(reliable(_track('Daft Punk', 'One More Time', durationMs: 400000), localMs: 0), isTrue);
      expect(reliable(_track('Daft Punk', 'One More Time'), localMs: 180000), isTrue);
    });

    test('no check when skipDurationCheck is set (video file name)', () {
      expect(reliable(_track('Daft Punk', 'One More Time', durationMs: 400000), localMs: 180000, skip: true), isTrue);
    });

    test('also filters candidates in pickBestMatch when the artist is unknown', () {
      expect(
        TrackMatchConfidence.pickBestMatch(
          localTitle: 'One More Time',
          localArtists: const ['Unknown'],
          candidates: [_track('Daft Punk', 'One More Time', durationMs: 400000)],
          localDurationMs: 180000,
        ),
        isNull,
      );
    });
  });

  group('pickBestMatch', () {
    test('rejects a generic title covered by several unrelated artists when local artist is unknown', () {
      // Cas réel observé : "Money Trees" sans artiste local matchait une
      // reprise "lullaby" avant l'original Kendrick Lamar.
      final best = TrackMatchConfidence.pickBestMatch(
        localTitle: 'Money Trees',
        localArtists: const ['Unknown'],
        candidates: [
          _track('Twinkle Twinkle Little Rock Star', 'Money Trees'),
          _track('Sladeboyy', 'Money Trees'),
          _track('Les Krills', 'Money Trees'),
        ],
      );
      expect(best, isNull);
    });

    test('picks the first reliable candidate when local artist is known', () {
      final best = TrackMatchConfidence.pickBestMatch(
        localTitle: 'Am I Dreaming',
        localArtists: const ['Metro Boomin', 'A\$AP Rocky', 'Roisee'],
        candidates: [
          _track('Some Karaoke Band', 'Am I Dreaming (Karaoke Version)'),
          _track('Metro Boomin, A\$AP Rocky & Roisee', 'Am I Dreaming'),
        ],
      );
      expect(best?.artist, 'Metro Boomin, A\$AP Rocky & Roisee');
    });

    test('accepts a unique exact title even without a local artist', () {
      final best = TrackMatchConfidence.pickBestMatch(
        localTitle: 'all my exes miss me',
        localArtists: const ['Unknown'],
        candidates: [_track('twoflow & Delaney Jane', 'all my exes miss me')],
      );
      expect(best?.artist, 'twoflow & Delaney Jane');
    });
  });
}
