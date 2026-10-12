import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../storage/database/app_database.dart';
import '../storage/database/track_repository.dart';
import 'audio_interruption_policy.dart';
import 'player_state_storage.dart';
import 'queue_controller.dart';

part 'player_controller.g.dart';

enum PlaybackStatus { idle, playing, paused }

/// 3 modes de lecture de la Queue (bouton dédié du Player) : `playlistOrder`
/// suit l'ordre affiché dans l'onglet Queue, `shuffle` le mélange (voir
/// QueueController.shuffle), `repeatOne` reboucle indéfiniment le morceau
/// courant à sa fin plutôt que d'avancer — un "suivant"/"précédent" manuel
/// reste toujours possible dans les 3 modes.
enum PlayerRepeatMode { playlistOrder, shuffle, repeatOne }

class PlayerSnapshot {
  const PlayerSnapshot({
    required this.status,
    this.currentTrack,
    this.currentPlaylistId,
    this.repeatMode = PlayerRepeatMode.playlistOrder,
  });

  final PlaybackStatus status;
  final Track? currentTrack;
  final String? currentPlaylistId;
  final PlayerRepeatMode repeatMode;

  PlayerSnapshot copyWith({
    PlaybackStatus? status,
    Track? currentTrack,
    String? currentPlaylistId,
    PlayerRepeatMode? repeatMode,
  }) {
    return PlayerSnapshot(
      status: status ?? this.status,
      currentTrack: currentTrack ?? this.currentTrack,
      currentPlaylistId: currentPlaylistId ?? this.currentPlaylistId,
      repeatMode: repeatMode ?? this.repeatMode,
    );
  }
}

/// Moteur audio natif unique de l'app, isolé dans son propre provider pour
/// pouvoir être remplacé par un faux lecteur dans les tests du
/// [PlayerController].
///
/// `handleInterruptions: false` (Lot 1.2) : le focus audio est géré par le
/// seul [PlayerController] (voir [AudioInterruptionPolicy]). Laissés actifs,
/// les deux écouteurs se marchaient dessus — selon leur ordre d'appel, la
/// pause de l'un effaçait la reprise automatique prévue par l'autre.
final Provider<AudioPlayer> audioPlayerProvider = Provider<AudioPlayer>((ref) {
  final AudioPlayer player = AudioPlayer(handleInterruptions: false);
  ref.onDispose(player.dispose);
  return player;
});

/// Couche B de l'état global (lecteur natif) : joue la Queue en respectant le
/// découpage de silence (trim_start_ms/trim_end_ms, Étape 2), avance
/// automatiquement en fin de piste, et persiste la dernière piste active pour
/// reprendre à son début au prochain lancement (State Retention).
/// Isolée de la DB (lue en lecture seule) et du ticker d'animation tempo
/// (Couche C) — seule la position, exposée en Stream, est partagée.
@riverpod
class PlayerController extends _$PlayerController {
  late final AudioPlayer _player = ref.read(audioPlayerProvider);
  final PlayerStateStorage _storage = PlayerStateStorage();
  StreamSubscription<PlayerState>? _completionSub;
  StreamSubscription<AudioInterruptionEvent>? _interruptionSub;
  StreamSubscription<void>? _becomingNoisySub;
  final AudioInterruptionPolicy _interruptionPolicy = AudioInterruptionPolicy();
  int _currentIndex = -1;
  int _loadToken = 0;

  /// Volume pendant qu'une autre app parle par-dessus (notification, GPS).
  static const double duckVolume = 0.3;

  /// Durée du fondu d'entrée à la reprise après une interruption.
  static const Duration resumeFadeIn = Duration(milliseconds: 600);

  /// "Précédent" au-delà de cette position relance le titre (Lot 2.1).
  static const Duration restartThreshold = Duration(seconds: 3);

  /// Volume normal du moment : [duckVolume] pendant un duck, sinon plein.
  double _baseVolume = 1.0;

  /// Jeton du fondu en cours : tout autre réglage de volume l'annule.
  int _fadeToken = 0;

  /// Dernière piste DEMANDÉE, mise à jour de façon synchrone — en avance sur
  /// [_currentIndex] (piste réellement chargée) pendant un chargement : un
  /// zap rapide cumule ses pas depuis cette cible, jamais depuis une piste
  /// encore en cours de chargement (bug : 3 × "Précédent" ne reculaient que
  /// d'un titre).
  int _targetIndex = -1;

  /// Anti-rebond de Suivant/Précédent : un seul chargement audio une fois les
  /// appuis stabilisés.
  Timer? _skipDebounce;
  static const Duration skipDebounce = Duration(milliseconds: 200);

  @override
  PlayerSnapshot build() {
    // Source unique de vérité pour `status` : `playerStateStream` reflète le
    // "playing" voulu de just_audio en direct (mis à jour de façon synchrone
    // dès l'appel à `_player.play()/pause()`, avant même la confirmation de
    // la plateforme native — voir just_audio.dart `AudioPlayer.play()`), donc
    // plus fiable que d'attendre la résolution du Future retourné par
    // `_player.play()`/`pause()` pour mettre à jour `state`. Bug réel observé
    // en conditions réelles (Tab 2) : après pause puis reprise, le son
    // repartait bien mais l'icône restait figée sur "Play" et les animations
    // de fond (TempoSyncController) ne redémarraient pas tant que
    // `state.status` n'avait pas été réconcilié par un second tap.
    _completionSub = _player.playerStateStream.listen((playerState) {
      if (playerState.processingState == ProcessingState.completed) {
        _onTrackCompleted();
        return;
      }
      if (state.currentTrack == null) return;
      final PlaybackStatus mapped = playerState.playing ? PlaybackStatus.playing : PlaybackStatus.paused;
      if (mapped != state.status) state = state.copyWith(status: mapped);
    });
    ref.onDispose(() {
      _completionSub?.cancel();
      _interruptionSub?.cancel();
      _becomingNoisySub?.cancel();
      _skipDebounce?.cancel();
    });

    Future.microtask(_restoreLastSession);
    unawaited(_configureAudioSession());
    return const PlayerSnapshot(status: PlaybackStatus.idle);
  }

  /// Audio Focus (Étape 5, Lot 1.2) : `music()` = focus `gain` + usage media
  /// (Android), catégorie `playback` (iOS). Baisse le volume sous une
  /// notification, met en pause pendant un appel puis reprend en fondu (voir
  /// [AudioInterruptionPolicy]) — la reprise automatique après une
  /// interruption transitoire EST le comportement officiel de Vibe Player
  /// (QA, batterie Robustesse Système, Section 1), contrairement à une pause
  /// manuelle qui reste silencieuse. Casque débranché : pause, sans reprise.
  ///
  /// iOS : AVFoundation ne reprend jamais seul, la reprise passe par la même
  /// règle (fin d'interruption avec `shouldResume`) ; lecture écran verrouillé
  /// et interrupteur silencieux via `UIBackgroundModes: audio` (Info.plist).
  ///
  /// `androidWillPauseWhenDucked` reste à `false` (défaut de `music()`,
  /// arbitrage v1.3.5) : Android 8+ baisse puis remonte lui-même le volume
  /// sous une notification, sans couper la lecture. À `true`, `audio_session`
  /// transforme ce signal en PAUSE : coupure à chaque notification.
  Future<void> _configureAudioSession() async {
    final AudioSession session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());

    _interruptionSub = session.interruptionEventStream.listen(onAudioInterruption);
    _becomingNoisySub = session.becomingNoisyEventStream.listen((_) => pause());
  }

  @visibleForTesting
  void onAudioInterruption(AudioInterruptionEvent event) {
    switch (_interruptionPolicy.onEvent(event, isPlaying: _player.playing)) {
      case InterruptionAction.duck:
        _baseVolume = duckVolume;
        _restoreVolume();
      case InterruptionAction.unduck:
        _baseVolume = 1.0;
        _restoreVolume();
      case InterruptionAction.pause:
        unawaited(_player.pause());
        _restoreVolume();
      case InterruptionAction.resume:
        unawaited(_resumeWithFadeIn());
      case InterruptionAction.none:
        break;
    }
  }

  /// Reprise "fluide" : repart du silence jusqu'à [_baseVolume] en
  /// [resumeFadeIn] plutôt que de revenir d'un coup à plein volume.
  Future<void> _resumeWithFadeIn() async {
    if (state.currentTrack == null || _player.playing) return;
    final int token = ++_fadeToken;
    await _player.setVolume(0);
    // Play/Pause de l'utilisateur pendant ce court délai : il a repris la
    // main (et [_restoreVolume] a déjà rétabli le volume).
    if (token != _fadeToken || !ref.mounted) return;
    unawaited(_player.play());
    const int steps = 10;
    for (int step = 1; step <= steps; step++) {
      await Future<void>.delayed(resumeFadeIn ~/ steps);
      if (token != _fadeToken || !ref.mounted) return;
      await _player.setVolume(_baseVolume * step / steps);
    }
  }

  /// Annule un fondu en cours et remet aussitôt le volume normal — sans quoi
  /// un Play/Pause pendant le fondu pourrait laisser le lecteur muet.
  void _restoreVolume() {
    _fadeToken++;
    if (_player.volume != _baseVolume) unawaited(_player.setVolume(_baseVolume));
  }

  Stream<Duration> get positionStream => _player.positionStream;
  Stream<Duration?> get durationStream => _player.durationStream;

  /// Déplacement manuel sur la barre de progression (Étape 3).
  Future<void> seek(Duration position) => _player.seek(position);

  /// Charge [tracks] dans la Queue et démarre la lecture à [startIndex]. Si le
  /// mode Aléatoire est actif, la nouvelle queue est immédiatement mélangée
  /// (le morceau de départ reste en tête) plutôt que jouée dans l'ordre
  /// affiché puis mélangée après coup.
  Future<void> playPlaylist(String playlistId, List<Track> tracks, {int startIndex = 0}) async {
    // Lot 1.1 : changement de playlist — `stop()` détruit l'instance native
    // (ExoPlayer/AVPlayer) et, avec elle, le cache de sources de just_audio,
    // qui garde sinon en mémoire chaque piste chargée depuis le lancement
    // (vidé seulement à la destruction du lecteur). Recréée au chargement
    // suivant, en ~100 ms.
    final String? previousPlaylistId = state.currentPlaylistId;
    if (previousPlaylistId != null && previousPlaylistId != playlistId) await _player.stop();

    final List<String> ids = tracks.map((t) => t.id).toList();
    ref.read(queueControllerProvider.notifier).restore(ids);

    int effectiveStartIndex = startIndex;
    if (state.repeatMode == PlayerRepeatMode.shuffle && ids.isNotEmpty) {
      final String keepFirstId = ids[startIndex.clamp(0, ids.length - 1)];
      ref.read(queueControllerProvider.notifier).shuffle(keepFirst: keepFirstId);
      effectiveStartIndex = 0;
    }

    await playTrackAt(effectiveStartIndex, playlistId: playlistId);
  }

  /// Fait avancer cycliquement le mode de lecture : ordre de la playlist ->
  /// aléatoire -> répétition du titre -> ordre de la playlist. Bascule
  /// immédiatement l'ordre réel de la Queue à l'activation/désactivation du
  /// mode Aléatoire pour que la Queue affichée (Tab 2, page 2) corresponde
  /// toujours à l'ordre de lecture réel.
  Future<void> cycleRepeatMode() async {
    final PlayerRepeatMode next = switch (state.repeatMode) {
      PlayerRepeatMode.playlistOrder => PlayerRepeatMode.shuffle,
      PlayerRepeatMode.shuffle => PlayerRepeatMode.repeatOne,
      PlayerRepeatMode.repeatOne => PlayerRepeatMode.playlistOrder,
    };
    await _applyRepeatMode(next);
  }

  Future<void> _applyRepeatMode(PlayerRepeatMode mode) async {
    final bool enteringShuffle = mode == PlayerRepeatMode.shuffle && state.repeatMode != PlayerRepeatMode.shuffle;
    final bool leavingShuffle = mode != PlayerRepeatMode.shuffle && state.repeatMode == PlayerRepeatMode.shuffle;

    if (enteringShuffle) {
      ref.read(queueControllerProvider.notifier).shuffle(keepFirst: state.currentTrack?.id);
      _currentIndex = _targetIndex = 0;
    } else if (leavingShuffle) {
      ref.read(queueControllerProvider.notifier).unshuffle();
      final String? currentId = state.currentTrack?.id;
      if (currentId != null) {
        final List<Track> tracks = await ref.read(queueTracksProvider.future);
        final int restoredIndex = tracks.indexWhere((t) => t.id == currentId);
        if (restoredIndex >= 0) _currentIndex = _targetIndex = restoredIndex;
      }
    }

    state = state.copyWith(repeatMode: mode);
  }

  Future<void> playTrackAt(int startIndex, {String? playlistId}) async {
    // Jeton de génération, pris AVANT tout `await` (ordre des appels
    // garanti) : un autre appel (tap rapide sur "suivant", changement de
    // playlist, complétion naturelle qui se chevauche avec un swap manuel)
    // peut démarrer pendant le chargement et devenir le véritable état
    // courant. Sans ce garde, celui qui finit en second écraserait
    // inconditionnellement `_currentIndex`/`state` même s'il est périmé — un
    // bug réel observé en testant l'auto-avance (Vibe Engine) : la Vibe
    // affichée pouvait brièvement correspondre à une ancienne playlist.
    final int token = ++_loadToken;
    // Tout chargement explicite remplace un zap encore en attente.
    _skipDebounce?.cancel();
    _targetIndex = startIndex;

    final List<Track> tracks = await ref.read(queueTracksProvider.future);
    if (token != _loadToken || startIndex < 0 || startIndex >= tracks.length) return;

    // Boucle (et non un simple appel unique) : un fichier référencé en base
    // peut avoir été supprimé/déplacé/corrompu hors de l'app (nettoyage
    // manuel du stockage, éjection de carte SD...). `setAudioSource` lève
    // alors une exception (`PlatformException`/`ExoPlaybackException`) —
    // bug réel reproduit : laissée non interceptée, elle remontait en
    // "Unhandled Exception" et figeait silencieusement le lecteur sur ce
    // morceau, sans jamais avancer. On tente donc chaque morceau suivant de
    // la Queue jusqu'au premier qui charge, plutôt que de s'arrêter net.
    for (int index = startIndex; index < tracks.length; index++) {
      final Track track = tracks[index];
      final int endMs = track.durationSeconds * 1000 - track.trimEndMs;

      try {
        await _player.setAudioSource(
          ClippingAudioSource(
            child: AudioSource.uri(Uri.file(track.filePath)),
            start: Duration(milliseconds: track.trimStartMs),
            end: track.trimEndMs > 0 ? Duration(milliseconds: endMs) : null,
          ),
        );
      } catch (_) {
        // Chargement interrompu par un plus récent (just_audio annule le
        // précédent) : ce n'est PAS un fichier illisible. Enchaîner sur le
        // morceau suivant relancerait un chargement qui interromprait à son
        // tour celui voulu — cascade réelle jusqu'à la fin de la Queue lors
        // d'un zap rapide.
        if (token != _loadToken) return;
        continue;
      }

      if (token != _loadToken) return;

      _currentIndex = _targetIndex = index;
      // `copyWith` plutôt qu'un nouveau `PlayerSnapshot(...)` : préserve
      // `repeatMode` d'un changement de piste à l'autre (suivant/précédent,
      // auto-avance...) — sans quoi le mode Aléatoire/Répétition reviendrait
      // silencieusement à "ordre de la playlist" à chaque piste.
      //
      // `currentTrack` posé ICI, avant `_player.play()` plutôt qu'après sa
      // résolution : au tout premier appel natif suivant un cold start (warm-up
      // du plugin/service audio), la Future de `play()` peut mettre plusieurs
      // dizaines de secondes à se résoudre côté Dart alors que la lecture
      // native a déjà démarré. Tant que `currentTrack` restait null, le Lecteur
      // (titre, pochette, icône Play/Pause, fond Vibe) restait figé sur
      // "Aucune lecture" tout ce temps — le listener de `playerStateStream`
      // ci-dessus se tait lui aussi tant que `currentTrack == null` — jusqu'à
      // ce qu'un tap manuel force une resynchronisation. Bug réel observé lors
      // d'un retest QA (Vibe Neon "sans effet" au premier lancement d'une
      // playlist après ouverture de l'app).
      state = state.copyWith(status: PlaybackStatus.playing, currentTrack: track, currentPlaylistId: playlistId);
      unawaited(_player.play());

      unawaited(_storage.save(
        queueTrackIds: tracks.map((t) => t.id).toList(),
        currentIndex: index,
        currentPlaylistId: state.currentPlaylistId,
      ));
      unawaited(ref.read(trackRepositoryProvider).recordPlay(track.id));
      return;
    }

    // Plus aucun morceau lisible à partir de `startIndex` : rien à jouer.
    if (token == _loadToken) state = state.copyWith(status: PlaybackStatus.idle);
  }

  /// Séparés de [togglePlayPause] pour la notification média (Étape 5) :
  /// `audio_service` appelle `play`/`pause` distinctement selon le bouton
  /// pressé, jamais un simple bascule. `state.status` n'est volontairement
  /// plus assigné ici : le listener de `playerStateStream` dans [build] s'en
  /// charge en continu (voir son commentaire) — se fier à cette unique source
  /// plutôt que de dupliquer l'assignation ici évite tout risque de
  /// désynchronisation entre les deux.
  ///
  /// Commandes de l'utilisateur : annulent toute reprise automatique après
  /// interruption, et tout fondu en cours (voir [onAudioInterruption]).
  Future<void> play() async {
    _interruptionPolicy.onUserCommand();
    _restoreVolume();
    if (state.currentTrack == null || _player.playing) return;
    await _player.play();
  }

  Future<void> pause() async {
    _interruptionPolicy.onUserCommand();
    _restoreVolume();
    if (!_player.playing) return;
    await _player.pause();
  }

  Future<void> togglePlayPause() => _player.playing ? pause() : play();

  Future<void> next() async => _skip(1);

  /// Lot 2.1 : lecture entamée depuis plus de [restartThreshold] → relance
  /// le titre au début ; sinon titre précédent, et du premier titre on boucle
  /// sur le dernier de la file. Pendant un zap (piste visée pas encore
  /// démarrée), chaque appui recule d'un titre.
  Future<void> previous() async {
    final bool zapping = (_skipDebounce?.isActive ?? false) || _targetIndex != _currentIndex;
    if (!zapping && _player.position > restartThreshold) return seek(Duration.zero);
    _skip(-1);
  }

  /// Suivant/Précédent — boutons du Lecteur ET notification/écran verrouillé
  /// (PlaylistAudioHandler appelle ces mêmes méthodes). Chaque appui décale
  /// la cible de façon synchrone depuis la dernière cible demandée, affiche
  /// aussitôt le morceau visé, et un seul chargement audio part une fois les
  /// appuis stabilisés ([skipDebounce]). "Précédent" depuis le premier titre
  /// boucle sur le dernier (Lot 2.1) ; "Suivant" s'arrête au dernier.
  void _skip(int delta) {
    final List<Track>? tracks = ref.read(queueTracksProvider).value;
    if (tracks == null || tracks.isEmpty) return;
    final int target = (delta < 0 && _targetIndex == 0) ? tracks.length - 1 : _targetIndex + delta;
    if (target < 0 || target >= tracks.length) return;

    _targetIndex = target;
    state = state.copyWith(currentTrack: tracks[target]);
    _skipDebounce?.cancel();
    _skipDebounce = Timer(skipDebounce, () => playTrackAt(target));
  }

  Future<void> _onTrackCompleted() async {
    // Zap en attente : c'est lui qui décide de la prochaine piste.
    if (_skipDebounce?.isActive ?? false) return;
    // Un swap de source (`playTrackAt`) en cours peut émettre un événement
    // `completed` fantôme pour l'ancienne source qu'il est en train de
    // remplacer — capturer le jeton avant l'`await` puis le revérifier permet
    // de distinguer cet artefact d'une vraie fin de piste et d'ignorer le
    // premier, plutôt que d'avancer `_currentIndex` sur la base d'un état déjà
    // périmé.
    final int tokenAtCompletion = _loadToken;
    final List<Track> tracks = await ref.read(queueTracksProvider.future);
    if (tokenAtCompletion != _loadToken) return;

    if (state.repeatMode == PlayerRepeatMode.repeatOne && _currentIndex >= 0 && _currentIndex < tracks.length) {
      await playTrackAt(_currentIndex);
    } else if (_currentIndex + 1 < tracks.length) {
      await playTrackAt(_currentIndex + 1);
    } else if (tracks.isNotEmpty) {
      // Section 3.1 : fin du dernier morceau de la playlist -> relance
      // automatique au premier plutôt que de s'arrêter (`playlistId` omis,
      // comme la branche "morceau suivant" ci-dessus : `playTrackAt` retombe
      // alors sur `currentPlaylistId` déjà en cours via `copyWith`).
      await playTrackAt(0);
    } else {
      state = state.copyWith(status: PlaybackStatus.idle);
    }
  }

  Future<void> _restoreLastSession() async {
    final PersistedPlayerState? persisted = await _storage.load();
    if (persisted == null) return;

    ref.read(queueControllerProvider.notifier).restore(persisted.queueTrackIds);
    final List<Track> tracks = await ref.read(queueTracksProvider.future);
    if (tracks.isEmpty) return;

    final int index = persisted.currentIndex.clamp(0, tracks.length - 1);
    final Track track = tracks[index];

    try {
      await _player.setAudioSource(
        ClippingAudioSource(
          child: AudioSource.uri(Uri.file(track.filePath)),
          start: Duration(milliseconds: track.trimStartMs),
        ),
      );
    } catch (_) {
      // Fichier de la dernière session introuvable (supprimé/déplacé hors de
      // l'app entre deux lancements) : rien à restaurer plutôt que de faire
      // planter le démarrage — l'utilisateur relance une lecture normalement,
      // `state` reste `idle` (valeur par défaut de [build]).
      return;
    }
    // Chargé en pause au début du morceau — pas de lecture automatique au lancement.
    // `ref.mounted` : ce provider peut avoir été disposé pendant les `await`
    // ci-dessus si l'app a déjà navigué ailleurs (ex. redirection vers
    // l'onboarding du premier lancement, Étape 8) — écrire `state` après coup
    // lèverait sinon une exception.
    if (!ref.mounted) return;
    _currentIndex = _targetIndex = index;
    // `currentPlaylistId` restauré ici (Bug critique QA, cold restart) : sans
    // lui, MasterPlayerScreen/activeVibeProvider ne retrouvaient jamais la
    // playlist active après un force-stop/relance et retombaient
    // indéfiniment sur leur repli neutre (dégradé gris, accentColor black87)
    // au lieu de la Vibe réellement configurée.
    state = PlayerSnapshot(
        status: PlaybackStatus.paused, currentTrack: track, currentPlaylistId: persisted.currentPlaylistId);
  }
}

/// Durée réellement lisible d'une piste, silences coupés déduits (voir
/// `ClippingAudioSource` dans `playTrackAt`) — partagée par la barre de
/// progression du Player et le `MediaItem` de la notification système, pour
/// qu'aucun des deux n'affiche la durée brute du fichier.
extension TrackPlaybackDuration on Track {
  Duration get effectivePlaybackDuration {
    final int playableMs = (durationSeconds * 1000 - trimStartMs - trimEndMs).clamp(0, 1 << 31).toInt();
    return Duration(milliseconds: playableMs);
  }
}

/// Position courante pour la barre de progression (Étape 3) — `autoDispose`
/// car inutile hors de l'écran Player affiché.
final positionStreamProvider = StreamProvider.autoDispose<Duration>((ref) {
  return ref.watch(playerControllerProvider.notifier).positionStream;
});

final durationStreamProvider = StreamProvider.autoDispose<Duration?>((ref) {
  return ref.watch(playerControllerProvider.notifier).durationStream;
});
