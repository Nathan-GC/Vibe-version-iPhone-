import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/networking/metadata_api_client/online_result_ranker.dart';
import 'package:playlist_app/core/networking/metadata_api_client/online_track_result.dart';

OnlineTrackResult _track(String artist, String title) => OnlineTrackResult(artist: artist, title: title);

void main() {
  group('rankByRelevance', () {
    test('moves an artist+title match to the top even if iTunes ranked it lower', () {
      final ranked = OnlineResultRanker.rankByRelevance(
        [
          _track('The Weeknd', 'Starboy (feat. Daft Punk)'),
          _track('Pentatonix', 'Daft Punk'),
          _track('Daft Punk', 'One More Time'),
        ],
        artist: 'Daft Punk',
        title: 'One More Time',
      );

      expect(ranked.first.artist, 'Daft Punk');
      expect(ranked.first.title, 'One More Time');
    });

    test('keeps the original relative order within the same score (stable sort)', () {
      final ranked = OnlineResultRanker.rankByRelevance(
        [
          _track('Metronomy', 'The Look'),
          _track('Metronomy', 'The Bay'),
          _track('Metronomy', 'Everything Goes My Way'),
        ],
        artist: 'Metronomy',
        title: '',
      );

      // Les trois matchent l'artiste (même score) : ordre d'origine préservé.
      expect(ranked.map((r) => r.title).toList(), ['The Look', 'The Bay', 'Everything Goes My Way']);
    });

    test('ranks a partial match (artist only) above a match on neither field', () {
      final ranked = OnlineResultRanker.rankByRelevance(
        [
          _track('Random Cover Band', 'Some Unrelated Song'),
          _track('Angèle', 'Bruxelles je t\'aime'),
        ],
        artist: 'Angèle',
        title: 'Balance ton quoi',
      );

      expect(ranked.first.artist, 'Angèle');
    });

    test('is tolerant to punctuation/case differences when matching', () {
      final ranked = OnlineResultRanker.rankByRelevance(
        [
          _track('Rockabye Baby!', 'Some Unrelated Lullaby Cover'),
          // Casse et apostrophe différentes du champ recherché, mais mêmes mots.
          _track('AC/DC', "ROCK AND ROLL AIN'T NOISE POLLUTION"),
        ],
        artist: 'ac/dc',
        title: "Rock and Roll Ain't Noise Pollution",
      );

      expect(ranked.first.artist, 'AC/DC');
    });

    test('returns the list unchanged when both artist and title are empty', () {
      final input = [_track('A', 'B'), _track('C', 'D')];
      final ranked = OnlineResultRanker.rankByRelevance(input, artist: '', title: '');
      expect(ranked, input);
    });
  });
}
