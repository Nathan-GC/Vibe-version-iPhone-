import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/playlists/data/playlist_providers.dart';
import '../storage/database/app_database.dart';
import 'player_controller.dart';

/// Pont entre PlayerController (moteur `just_audio`, queue, trim de silence,
/// State Retention — logique inchangée) et `audio_service` (notification
/// média, écran verrouillé, boutons casque/Bluetooth). Ne réimplémente aucune
/// logique de lecture : traduit l'état de PlayerController vers
/// `audio_service`, et relaie les commandes entrantes vers PlayerController.
///
/// Construit avec le même [ProviderContainer] que le reste de l'app (voir
/// main.dart — `UncontrolledProviderScope`) pour partager le même
/// PlayerController plutôt que d'en instancier un second moteur audio.
class PlaylistAudioHandler extends BaseAudioHandler with SeekHandler {
  PlaylistAudioHandler(this._container) {
    _container.listen<PlayerSnapshot>(
      playerControllerProvider,
      (previous, next) => _syncState(next),
      fireImmediately: true,
    );
    _container.read(playerControllerProvider.notifier).positionStream.listen((position) {
      playbackState.add(playbackState.value.copyWith(updatePosition: position));
    });
  }

  final ProviderContainer _container;

  void _syncState(PlayerSnapshot snapshot) {
    final track = snapshot.currentTrack;
    mediaItem.add(track == null ? null : _mediaItemFor(track, snapshot.currentPlaylistId));

    final bool isPlaying = snapshot.status == PlaybackStatus.playing;
    playbackState.add(
      playbackState.value.copyWith(
        controls: [
          MediaControl.skipToPrevious,
          isPlaying ? MediaControl.pause : MediaControl.play,
          MediaControl.skipToNext,
        ],
        systemActions: const {MediaAction.seek},
        androidCompactActionIndices: const [0, 1, 2],
        playing: isPlaying,
        processingState: AudioProcessingState.ready,
      ),
    );
  }

  MediaItem _mediaItemFor(Track track, String? playlistId) {
    // Section 3.2 : repli sur la pochette de la playlist en cours (notification
    // média/écran verrouillé, l'équivalent "mini player" hors de l'app) quand
    // le morceau n'a pas de pochette dédiée — même logique que MasterPlayerScreen.
    String coverArtPath = track.coverArtPath;
    if (coverArtPath.isEmpty && playlistId != null) {
      final String? playlistCover = _container.read(playlistByIdProvider(playlistId)).value?.coverImagePath;
      if (playlistCover != null && playlistCover.isNotEmpty) coverArtPath = playlistCover;
    }

    return MediaItem(
      id: track.filePath,
      title: track.title,
      artist: track.artists.join(', '),
      album: track.album.isEmpty ? null : track.album,
      duration: track.effectivePlaybackDuration,
      artUri: _artUri(coverArtPath),
    );
  }

  Uri? _artUri(String path) {
    if (path.isEmpty) return null;
    return path.startsWith('http') ? Uri.tryParse(path) : Uri.file(path);
  }

  @override
  Future<void> play() => _container.read(playerControllerProvider.notifier).play();

  @override
  Future<void> pause() => _container.read(playerControllerProvider.notifier).pause();

  @override
  Future<void> skipToNext() => _container.read(playerControllerProvider.notifier).next();

  @override
  Future<void> skipToPrevious() => _container.read(playerControllerProvider.notifier).previous();

  @override
  Future<void> seek(Duration position) => _container.read(playerControllerProvider.notifier).seek(position);

  @override
  Future<void> stop() async {
    await _container.read(playerControllerProvider.notifier).pause();
    await super.stop();
  }
}
