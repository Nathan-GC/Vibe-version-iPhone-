import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/identity/track_key.dart';

String _key(String title, String artist, [String? album]) =>
    buildSanitizedKey(title: title, album: album, primaryArtist: artist);

void main() {
  test('an ASCII key is unchanged', () {
    expect(_key('One More Time', 'Daft Punk', 'Discovery'), 'one-more-time_discovery_daft-punk');
    expect(_key('  AC/DC: Live!! ', 'AC/DC'), 'ac-dc-live__ac-dc');
  });

  test('Latin accents are folded, whether the text is NFC or NFD', () {
    const String nfc = 'Déjà vu';
    const String nfd = 'Déjà vu';

    expect(_key(nfc, 'Céline Dion'), 'deja-vu__celine-dion');
    expect(_key(nfd, 'Céline Dion'), _key(nfc, 'Céline Dion'));
  });

  test('Cyrillic, Asian and Arabic titles keep distinct, non-empty keys', () {
    final Map<String, String> keys = {
      'Группа крови': _key('Группа крови', 'Кино'),
      'Кукушка': _key('Кукушка', 'Кино'),
      '夜に駆ける': _key('夜に駆ける', 'YOASOBI'),
      'アイドル': _key('アイドル', 'YOASOBI'),
      '강남스타일': _key('강남스타일', 'PSY'),
      'تملي معاك': _key('تملي معاك', 'عمرو دياب'),
      'نور العين': _key('نور العين', 'عمرو دياب'),
    };

    expect(keys.values.toSet(), hasLength(keys.length), reason: 'aucune collision : $keys');
    for (final MapEntry<String, String> entry in keys.entries) {
      expect(entry.value.split('_').first, isNotEmpty, reason: entry.key);
    }
    expect(keys['Группа крови'], 'группа-крови__кино');
    expect(keys['تملي معاك'], 'تملي-معاك__عمرو-دياب');
  });
}
