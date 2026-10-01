import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/networking/spotify/spotify_credentials.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const FlutterSecureStorage secure = FlutterSecureStorage();

  test('saves credentials in encrypted storage only, never in plain preferences', () async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});

    await SpotifyCredentialsStorage().save(const SpotifyCredentials(clientId: 'id', clientSecret: 'secret'));

    expect(await secure.read(key: 'spotify.client_secret'), 'secret');
    expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
  });

  test('moves plaintext credentials from v1.2 into encrypted storage and erases the plain copy', () async {
    SharedPreferences.setMockInitialValues({'spotify.client_id': 'old-id', 'spotify.client_secret': 'old-secret'});
    FlutterSecureStorage.setMockInitialValues({});

    final SpotifyCredentials? loaded = await SpotifyCredentialsStorage().load();

    expect(loaded?.clientId, 'old-id');
    expect(loaded?.clientSecret, 'old-secret');
    expect(await secure.read(key: 'spotify.client_secret'), 'old-secret');
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('spotify.client_id'), isNull);
    expect(prefs.getString('spotify.client_secret'), isNull);
  });

  test('no credentials anywhere returns null', () async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});

    expect(await SpotifyCredentialsStorage().load(), isNull);
  });

  group('iOS (the keychain outlives an uninstall)', () {
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.iOS);
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('credentials left by a previous install are erased on first access', () async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({'spotify.client_id': 'old-id', 'spotify.client_secret': 'old-secret'});

      expect(await SpotifyCredentialsStorage().load(), isNull);
      expect(await secure.read(key: 'spotify.client_secret'), isNull);
    });

    test('credentials saved by this install are kept', () async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});

      await SpotifyCredentialsStorage().save(const SpotifyCredentials(clientId: 'id', clientSecret: 'secret'));

      expect((await SpotifyCredentialsStorage().load())?.clientSecret, 'secret');
    });
  });
}
