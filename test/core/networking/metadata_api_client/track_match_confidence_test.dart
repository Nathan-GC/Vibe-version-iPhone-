import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/networking/metadata_api_client/online_track_result.dart';
import 'package:playlist_app/core/networking/metadata_api_client/track_match_confidence.dart';

OnlineTrackResult _track(String artist, String title) => OnlineTrackResult(artist: artist, title: title);

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
