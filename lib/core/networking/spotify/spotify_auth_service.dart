import 'dart:convert';

import 'package:dio/dio.dart';

import '../app_dio.dart';
import 'spotify_credentials.dart';

/// Flow OAuth "Client Credentials" de Spotify (accès public en lecture seule,
/// aucune donnée utilisateur) — jeton mis en cache jusqu'à expiration.
class SpotifyAuthService {
  SpotifyAuthService({Dio? dio}) : _dio = dio ?? createAppDio();

  final Dio _dio;
  String? _cachedToken;
  DateTime? _expiresAt;

  Future<String> getAccessToken(SpotifyCredentials credentials) async {
    if (_cachedToken != null && _expiresAt != null && DateTime.now().isBefore(_expiresAt!)) {
      return _cachedToken!;
    }

    final String basicAuth = base64Encode(utf8.encode('${credentials.clientId}:${credentials.clientSecret}'));
    final Response<Map<String, dynamic>> response = await _dio.post<Map<String, dynamic>>(
      'https://accounts.spotify.com/api/token',
      data: {'grant_type': 'client_credentials'},
      options: Options(contentType: Headers.formUrlEncodedContentType, headers: {'Authorization': 'Basic $basicAuth'}),
    );

    final String token = response.data!['access_token'] as String;
    final int expiresInSec = response.data!['expires_in'] as int;
    _cachedToken = token;
    _expiresAt = DateTime.now().add(Duration(seconds: expiresInSec - 30));
    return token;
  }
}
