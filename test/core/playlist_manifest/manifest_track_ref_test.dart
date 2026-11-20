import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/playlist_manifest/manifest_track_ref.dart';

void main() {
  group('ManifestTrackRef.toJson', () {
    test('sans id : la clé id est absente (manifestes partagés inchangés)', () {
      const ManifestTrackRef ref = ManifestTrackRef(title: 'Halo', artist: 'Beyoncé', album: 'I Am');

      final Map<String, dynamic> json = ref.toJson();

      expect(json.containsKey('id'), isFalse);
      expect(json, {'title': 'Halo', 'artist': 'Beyoncé', 'album': 'I Am'});
    });

    test('avec id : la clé id est écrite', () {
      const ManifestTrackRef ref = ManifestTrackRef(title: 'Halo', artist: 'Beyoncé', id: 'halo-beyonce');

      expect(ref.toJson()['id'], 'halo-beyonce');
    });
  });

  group('ManifestTrackRef.fromJson', () {
    test('relit id', () {
      final ManifestTrackRef ref = ManifestTrackRef.fromJson({'title': 'Halo', 'artist': 'Beyoncé', 'id': 'halo-beyonce'});

      expect(ref.id, 'halo-beyonce');
    });

    test('id absent, vide ou blanc, ou non textuel : null', () {
      expect(ManifestTrackRef.fromJson({'title': 'Halo', 'artist': 'B'}).id, isNull);
      expect(ManifestTrackRef.fromJson({'title': 'Halo', 'artist': 'B', 'id': ''}).id, isNull);
      expect(ManifestTrackRef.fromJson({'title': 'Halo', 'artist': 'B', 'id': '   '}).id, isNull);
      expect(ManifestTrackRef.fromJson({'title': 'Halo', 'artist': 'B', 'id': 42}).id, isNull);
    });

    test('id est nettoyé des espaces autour', () {
      final ManifestTrackRef ref = ManifestTrackRef.fromJson({'title': 'Halo', 'artist': 'B', 'id': '  halo-b  '});

      expect(ref.id, 'halo-b');
    });

    test('aller-retour : id conservé', () {
      const ManifestTrackRef ref = ManifestTrackRef(title: 'Halo', artist: 'B', id: 'halo-b');

      expect(ManifestTrackRef.fromJson(ref.toJson()).id, 'halo-b');
    });
  });
}
