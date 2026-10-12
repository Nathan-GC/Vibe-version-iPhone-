import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/features/playlists/domain/block_reorder.dart';

void main() {
  // Positions 1 à 12, comme affichées à l'utilisateur.
  final List<int> playlist = [for (int p = 1; p <= 12; p++) p];

  test('spec example: positions 2, 5 and 8 moved to position 10 end up at 10, 11 and 12, in order', () {
    final List<int> result = moveAsBlock(playlist, {1, 4, 7}, 9);

    expect(result.sublist(9), [2, 5, 8]);
    expect(result, [1, 3, 4, 6, 7, 9, 10, 11, 12, 2, 5, 8]);
  });

  test('keeps the original relative order, whatever order the tracks were ticked in', () {
    expect(moveAsBlock(playlist, {7, 1, 4}, 0).take(3), [2, 5, 8]);
  });

  test('groups a block in the middle of the remaining tracks', () {
    expect(moveAsBlock(playlist, {0, 11}, 3), [2, 3, 4, 1, 12, 5, 6, 7, 8, 9, 10, 11]);
  });

  test('a target past the end puts the block last', () {
    expect(moveAsBlock(playlist, {0, 1}, 99).sublist(10), [1, 2]);
  });

  test('never loses or duplicates a track', () {
    final List<int> result = moveAsBlock(playlist, {2, 3, 9}, 5);

    expect(result, hasLength(playlist.length));
    expect(result.toSet(), playlist.toSet());
  });

  test('an empty selection changes nothing', () {
    expect(moveAsBlock(playlist, {}, 4), playlist);
  });
}
