import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/identity/track_search.dart';

void main() {
  bool matches(String query, {String title = 'Crazy in Love', List<String> artists = const ['Beyoncé', 'JAY-Z']}) =>
      trackMatchesSearch(title: title, artists: artists, query: query);

  test('matches on the title, ignoring case', () {
    expect(matches('crazy'), isTrue);
    expect(matches('IN LOVE'), isTrue);
  });

  test('matches on any credited artist, featurings included', () {
    expect(matches('jay-z'), isTrue);
    expect(matches('Beyoncé'), isTrue);
  });

  test('ignores accents in both directions', () {
    expect(matches('beyonce'), isTrue);
    expect(matches('Crâzy'), isTrue);
    expect(matches('ete', title: 'Été indien', artists: const ['Joe Dassin']), isTrue);
  });

  test('every word must match, in any order, across title and artists', () {
    expect(matches('love beyonce'), isTrue);
    expect(matches('love adele'), isFalse);
  });

  test('an empty or blank query matches everything', () {
    expect(matches(''), isTrue);
    expect(matches('   '), isTrue);
  });

  test('does not match on unrelated text', () {
    expect(matches('daft punk'), isFalse);
  });
}
