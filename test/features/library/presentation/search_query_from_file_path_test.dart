import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/features/library/presentation/metadata_editor_modal.dart';

void main() {
  test('drops the "Unknown-" prefix added when the artist could not be deduced', () {
    expect(searchQueryFromFilePath('/music/Unknown-Halo Beyonce.mp3', fallbackTitle: 'x'), 'Halo Beyonce');
  });

  test('drops the anti-collision suffix of a second import with the same name', () {
    expect(searchQueryFromFilePath('/music/Unknown-Halo Beyonce (2).mp3', fallbackTitle: 'x'), 'Halo Beyonce');
  });

  test('turns the artist-title separator and underscores into spaces for a free-text search', () {
    expect(
        searchQueryFromFilePath('/music/Daft Punk-One_More_Time.mp3', fallbackTitle: 'x'), 'Daft Punk One More Time');
  });

  test('falls back to the existing title when the filename brings nothing', () {
    expect(searchQueryFromFilePath('/music/Unknown-.mp3', fallbackTitle: ' Sounds '), 'Sounds');
  });
}
