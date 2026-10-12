import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/identity/track_match_key.dart';
import 'package:playlist_app/core/storage/metadata_extractor/artist_name_normalizer.dart';

void main() {
  // Même nom à l'écran, deux encodages Unicode : "é" précomposé (NFC, la
  // norme) ou "e" + accent aigu combinant U+0301 (NFD, ex. fichiers macOS).
  const String celineNfc = 'Céline Dion';
  const String celineNfd = 'Céline Dion';

  String key(String name) => ArtistNameNormalizer.normalizeForGrouping(name);

  group('normalizeForGrouping (Lot 2.2)', () {
    test('NFC and NFD spellings of "Céline Dion" give the same key', () {
      expect(celineNfd, isNot(celineNfc), reason: 'deux chaînes Dart différentes');

      expect(key(celineNfd), key(celineNfc));
    });

    test('accented, unaccented and capitalised spellings all give "celinedion"', () {
      for (final String name in [celineNfc, celineNfd, 'Celine Dion', 'CÉLINE DION', 'celine-dion']) {
        expect(key(name), 'celinedion', reason: name);
      }
    });

    test('folds every Latin diacritic in both forms, not only French ones', () {
      expect(key('Dvořák'), 'dvorak'); // ř, á précomposés
      expect(key('Dvořák'), 'dvorak'); // mêmes lettres décomposées
      expect(key('Sơn Tùng M-TP'), 'sontungmtp');
    });

    test('keeps non-Latin scripts intact and distinct', () {
      expect(key('宇多田ヒカル'), '宇多田ヒカル');
      expect(key('아이유'), '아이유');
      expect(key('아이유'), '아이유', reason: 'hangûl décomposé (NFD) recomposé');
      expect(key('バンド'), isNot(key('ハンド')), reason: 'le dakuten distingue deux mots japonais');
    });

    test('a merge keeps the accented spelling as the canonical name', () {
      expect(ArtistNameNormalizer.pickCanonical({'Celine Dion', celineNfc}), celineNfc);
      expect(ArtistNameNormalizer.pickCanonical({celineNfd, 'Celine Dion'}), celineNfc, reason: 'recomposé en NFC');
    });
  });

  test('the import match key (JSON playlists, greyed tracks) ignores the Unicode form too', () {
    expect(
      buildTrackMatchKey(title: 'Déjà vu', artist: celineNfc),
      buildTrackMatchKey(title: 'Déjà vu', artist: celineNfd),
    );
  });
}
