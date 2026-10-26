import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/audio_engine/playlist_audio_handler.dart';
import 'package:playlist_app/core/shared/widgets/local_cover_image.dart';

void main() {
  test('chemin local -> FileImage', () {
    expect(localCoverImage('/data/cover.jpg'), isA<FileImage>());
  });

  test('vide, http et https -> null (jamais de réseau)', () {
    expect(localCoverImage(''), isNull);
    expect(localCoverImage('http://exemple.test/a.jpg'), isNull);
    expect(localCoverImage('https://exemple.test/a.jpg'), isNull);
  });

  test('artUri de la notification média : http(s) et vide -> null, local -> file://', () {
    expect(PlaylistAudioHandler.artUriFor('https://exemple.test/a.jpg'), isNull);
    expect(PlaylistAudioHandler.artUriFor(''), isNull);
    expect(PlaylistAudioHandler.artUriFor('/data/cover.jpg')?.scheme, 'file');
  });
}
