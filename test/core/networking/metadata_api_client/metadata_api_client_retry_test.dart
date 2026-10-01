import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/networking/metadata_api_client/metadata_api_client.dart';

/// Adaptateur Dio simulé : échoue [failTimes] fois avec [failureType] avant
/// de répondre un JSON vide — permet de tester la reprise automatique sans
/// dépendre du réseau réel.
class _ScriptedAdapter implements HttpClientAdapter {
  _ScriptedAdapter({
    required this.failTimes,
    this.failureType = DioExceptionType.connectionError,
    this.failureStatusCode,
  });

  final int failTimes;
  final DioExceptionType failureType;
  final int? failureStatusCode;
  int callCount = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    callCount++;
    if (callCount <= failTimes) {
      if (failureType == DioExceptionType.badResponse) {
        throw DioException(
          requestOptions: options,
          type: failureType,
          response: Response(requestOptions: options, statusCode: failureStatusCode),
        );
      }
      throw DioException(requestOptions: options, type: failureType);
    }
    return ResponseBody.fromString('{"results":[]}', 200);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test('retries a transient connection error and eventually succeeds', () async {
    final adapter = _ScriptedAdapter(failTimes: 2);
    final dio = Dio()..httpClientAdapter = adapter;
    final client = MetadataApiClient(dio: dio);

    final results = await client.search('some query');

    expect(results, isEmpty);
    expect(adapter.callCount, 3); // 2 échecs + 1 succès
  });

  test('retries a 429 rate-limit response', () async {
    final adapter = _ScriptedAdapter(
      failTimes: 1,
      failureType: DioExceptionType.badResponse,
      failureStatusCode: 429,
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final client = MetadataApiClient(dio: dio);

    final results = await client.search('some query');

    expect(results, isEmpty);
    expect(adapter.callCount, 2);
  });

  test('retries a 403 (iTunes\' actual rate-limit signal, verified empirically) with the long backoff', () async {
    // iTunes ne renvoie pas un 429 standard pour son blocage de débit mais un
    // 403 — vérifié empiriquement en rafale de test réelle contre l'API.
    final adapter = _ScriptedAdapter(
      failTimes: 1,
      failureType: DioExceptionType.badResponse,
      failureStatusCode: 403,
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final client = MetadataApiClient(dio: dio);

    final results = await client.search('some query');

    expect(results, isEmpty);
    expect(adapter.callCount, 2);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('gives up after exhausting all attempts on persistent failures', () async {
    final adapter = _ScriptedAdapter(failTimes: 100);
    final dio = Dio()..httpClientAdapter = adapter;
    final client = MetadataApiClient(dio: dio);

    await expectLater(client.search('some query'), throwsA(isA<DioException>()));
    expect(adapter.callCount, 4); // 1 essai + 3 reprises, jamais plus.
  });

  test('does not retry a genuine client error (400)', () async {
    final adapter = _ScriptedAdapter(
      failTimes: 100,
      failureType: DioExceptionType.badResponse,
      failureStatusCode: 400,
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final client = MetadataApiClient(dio: dio);

    await expectLater(client.search('some query'), throwsA(isA<DioException>()));
    expect(adapter.callCount, 1); // aucune reprise sur une vraie erreur de requête.
  });

  test('retryOnFailure: false gives up immediately on a transient error (scan initial)', () async {
    final adapter = _ScriptedAdapter(failTimes: 100);
    final dio = Dio()..httpClientAdapter = adapter;
    final client = MetadataApiClient(dio: dio);

    await expectLater(client.search('some query', retryOnFailure: false), throwsA(isA<DioException>()));
    expect(adapter.callCount, 1); // une seule requête, aucune des 3 reprises normales.
  });

  test('retryOnFailure: false gives up immediately on an iTunes rate-limit block (scan initial)', () async {
    final adapter = _ScriptedAdapter(
      failTimes: 100,
      failureType: DioExceptionType.badResponse,
      failureStatusCode: 403,
    );
    final dio = Dio()..httpClientAdapter = adapter;
    final client = MetadataApiClient(dio: dio);

    await expectLater(client.search('some query', retryOnFailure: false), throwsA(isA<DioException>()));
    expect(adapter.callCount, 1); // pas d'attente de plusieurs minutes sur le blocage 403.
  });
}
