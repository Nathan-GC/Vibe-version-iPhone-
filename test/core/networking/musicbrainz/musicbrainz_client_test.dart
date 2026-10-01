import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/networking/musicbrainz/musicbrainz_client.dart';

/// Faux réseau : réponse de recherche MusicBrainz + HEAD Cover Art Archive
/// (307 pour `rg-with-cover`, 404 sinon), en mémorisant les requêtes reçues.
class _FakeMusicBrainz implements HttpClientAdapter {
  final List<RequestOptions> requests = [];

  static final Map<String, dynamic> searchResponse = {
    'recordings': [
      {
        'id': 'rec-1',
        'score': 100,
        'title': 'One More Time',
        'artist-credit': [
          {'name': 'Daft Punk', 'joinphrase': ' feat. '},
          {'name': 'Romanthony', 'joinphrase': ''},
        ],
        'first-release-date': '2000-11-30',
        'releases': [
          {
            'id': 'rel-1',
            'title': 'Discovery',
            'release-group': {'id': 'rg-with-cover'},
          },
        ],
        'tags': [
          {'count': 1, 'name': 'french'},
          {'count': 5, 'name': 'house'},
        ],
      },
      {
        'id': 'rec-2',
        'title': 'One More Time (Live)',
        'artist-credit': [
          {'name': 'Daft Punk'},
        ],
        'releases': [
          {
            'id': 'rel-2',
            'title': 'Alive 2007',
            'release-group': {'id': 'rg-no-cover'},
          },
        ],
      },
    ],
  };

  @override
  Future<ResponseBody> fetch(
      RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    if (options.uri.host == 'coverartarchive.org') {
      return ResponseBody.fromString('', options.uri.path.contains('rg-with-cover') ? 307 : 404);
    }
    return ResponseBody.fromString(
      jsonEncode(searchResponse),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test('searches recordings with the documented query, User-Agent and JSON format', () async {
    final fake = _FakeMusicBrainz();
    final client = MusicBrainzClient(dio: Dio()..httpClientAdapter = fake);

    await client.searchRecordings(artist: 'Daft Punk', title: 'One More Time');

    final RequestOptions search = fake.requests.firstWhere((r) => r.uri.host == 'musicbrainz.org');
    expect(search.uri.path, '/ws/2/recording');
    expect(search.uri.queryParameters['query'], 'recording:"One More Time" AND artist:"Daft Punk"');
    expect(search.uri.queryParameters['fmt'], 'json');
    expect(search.headers['User-Agent'], startsWith('Vibe/'));
    expect(search.headers['User-Agent'], contains('('), reason: 'MusicBrainz exige un contact dans le User-Agent');
  });

  test('maps credits, release, year and top-voted tag, and keeps only verified covers', () async {
    final client = MusicBrainzClient(dio: Dio()..httpClientAdapter = _FakeMusicBrainz());

    final results = await client.searchRecordings(artist: 'Daft Punk', title: 'One More Time');

    expect(results, hasLength(2));
    final first = results.first;
    expect(first.title, 'One More Time');
    expect(first.artist, 'Daft Punk feat. Romanthony');
    expect(first.album, 'Discovery');
    expect(first.releaseYear, 2000);
    expect(first.genre, 'house');
    expect(first.coverArtUrl, 'https://coverartarchive.org/release-group/rg-with-cover/front-500');
    expect(results[1].coverArtUrl, isNull, reason: 'HEAD 404 : aucune pochette choisie sur le Cover Art Archive');
  });

  test('escapes quotes so a title cannot break the Lucene query', () async {
    final fake = _FakeMusicBrainz();
    final client = MusicBrainzClient(dio: Dio()..httpClientAdapter = fake);

    await client.searchRecordings(artist: '', title: 'Say "Hello"');

    final String query = fake.requests.first.uri.queryParameters['query']!;
    expect(query, r'recording:"Say \"Hello\""');
  });

  test('an empty query makes no request', () async {
    final fake = _FakeMusicBrainz();
    final client = MusicBrainzClient(dio: Dio()..httpClientAdapter = fake);

    expect(await client.searchRecordings(artist: 'Unknown', title: '  '), isEmpty);
    expect(fake.requests, isEmpty);
  });
}
