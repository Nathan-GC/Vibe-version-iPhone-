import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/identity/track_match_key.dart';

void main() {
  test('an ASCII or accented Latin key is unchanged', () {
    expect(
        buildTrackMatchKey(title: 'One More Time (Remastered 2011)', artist: 'Daft Punk'), 'one more time|daft punk');
    expect(buildTrackMatchKey(title: 'Déjà vu feat. Jay-Z', artist: 'Beyoncé'), 'deja vu|beyonce');
  });

  test('non-Latin titles keep their letters: two titles of one artist never share a key', () {
    final Set<String> keys = {
      buildTrackMatchKey(title: '夜に駆ける', artist: 'YOASOBI'),
      buildTrackMatchKey(title: 'アイドル', artist: 'YOASOBI'),
      buildTrackMatchKey(title: 'Группа крови', artist: 'Кино'),
      buildTrackMatchKey(title: 'Кукушка', artist: 'Кино'),
      buildTrackMatchKey(title: 'تملي معاك', artist: 'عمرو دياب'),
      buildTrackMatchKey(title: 'نور العين', artist: 'عمرو دياب'),
    };

    expect(keys, hasLength(6));
    expect(buildTrackMatchKey(title: 'Группа крови (Live)', artist: 'Кино'), 'группа крови|кино');
  });
}
