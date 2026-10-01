import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/networking/spotify/spotify_credentials.dart';
import 'discovery_repository.dart';

final Provider<DiscoveryRepository> discoveryRepositoryProvider = Provider<DiscoveryRepository>((ref) {
  return DefaultDiscoveryRepository();
});

final Provider<SpotifyCredentialsStorage> spotifyCredentialsStorageProvider =
    Provider<SpotifyCredentialsStorage>((ref) {
  return SpotifyCredentialsStorage();
});

final FutureProvider<SpotifyCredentials?> spotifyCredentialsProvider = FutureProvider<SpotifyCredentials?>((ref) {
  return ref.watch(spotifyCredentialsStorageProvider).load();
});
