import 'dart:async';

import 'package:just_audio/just_audio.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'player_controller.dart';

part 'preview_player_controller.g.dart';

/// Lecteur de previews (20-30s, streaming direct depuis `preview_url`, sans
/// téléchargement). Volontairement séparé du PlayerController principal :
/// une preview ne doit jamais interrompre/altérer l'état de la Queue en cours.
/// `state` = URL de la preview active, ou null si aucune ne joue.
///
/// `keepAlive: true` — sans ça, ce Notifier est auto-dispose et n'est gardé
/// en vie que tant qu'un widget le `watch` en continu ; les seuls watchers
/// sont des `OnlineTrackCard` imbriqués dans des listes issues de providers
/// réseau (résultats de recherche, top titres d'artiste...) qui se
/// reconstruisent fréquemment, au risque de faire tomber brièvement le
/// nombre d'abonnés à 0 et déclencher un dispose en plein chargement.
@Riverpod(keepAlive: true)
class PreviewPlayerController extends _$PreviewPlayerController {
  final AudioPlayer _player = AudioPlayer();
  Timer? _autoStopTimer;
  StreamSubscription<PlayerState>? _completionSub;
  // Vrai uniquement si le lecteur principal jouait réellement au moment où
  // cette preview a démarré — ne jamais le relancer s'il était déjà en pause.
  bool _resumeMainPlayerOnStop = false;

  @override
  String? build() {
    _completionSub = _player.playerStateStream.listen((playerState) {
      if (playerState.processingState == ProcessingState.completed) {
        stop();
      }
    });
    ref.onDispose(() {
      _autoStopTimer?.cancel();
      _completionSub?.cancel();
      _player.dispose();
    });
    return null;
  }

  /// [urlOrPath] : URL distante (previews iTunes 20-30s, [OnlineTrackCard])
  /// ou chemin de fichier local (extrait d'un morceau déjà téléchargé,
  /// Section 6.1, voir TrackActionsSheet) — distingués par le même critère
  /// "http" que partout ailleurs dans l'app (ex. Tracks.coverArtPath).
  /// [startAt] ne s'applique qu'aux fichiers locaux : démarre après le
  /// silence de tête déjà détecté (`trimStartMs`) plutôt qu'au tout début.
  Future<void> togglePreview(String urlOrPath, {Duration startAt = Duration.zero}) async {
    if (state == urlOrPath) {
      await stop();
      return;
    }
    await _player.stop();
    _autoStopTimer?.cancel();

    // Coupe le lecteur principal pendant l'extrait (jamais s'il était déjà en
    // pause) — `stop()` le relance automatiquement à la fin de la preview.
    final PlayerController mainPlayer = ref.read(playerControllerProvider.notifier);
    if (ref.read(playerControllerProvider).status == PlaybackStatus.playing) {
      _resumeMainPlayerOnStop = true;
      await mainPlayer.pause();
    }

    if (urlOrPath.startsWith('http')) {
      await _player.setUrl(urlOrPath);
    } else {
      await _player.setFilePath(urlOrPath);
      if (startAt > Duration.zero) await _player.seek(startAt);
    }
    // Ne PAS `await` ici : le Future de `play()` de just_audio ne se résout
    // qu'à l'arrêt de la lecture (pause/fin de piste), pas à son démarrage.
    // L'attendre retardait `state = url` jusqu'à la fin de la preview —
    // bug réel observé : l'extrait jouait bel et bien, mais aucune carte
    // n'affichait jamais l'icône "en lecture" pendant les ~30s d'écoute.
    unawaited(_player.play());
    state = urlOrPath;

    _autoStopTimer = Timer(const Duration(seconds: 30), stop);
  }

  Future<void> stop() async {
    _autoStopTimer?.cancel();
    await _player.stop();
    state = null;

    if (_resumeMainPlayerOnStop) {
      _resumeMainPlayerOnStop = false;
      await ref.read(playerControllerProvider.notifier).play();
    }
  }
}
