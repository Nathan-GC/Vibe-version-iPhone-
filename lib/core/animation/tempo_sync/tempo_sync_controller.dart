import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Couche C de l'état global : ticker 60fps dérivé du BPM de la piste courante.
/// Volontairement isolée de Riverpod — s'abonne uniquement au `Stream<Duration>`
/// de position du PlayerController + au BPM déjà chargé en mémoire, pour ne
/// jamais déclencher de rebuild lié à la DB ou aux providers audio/thème.
///
/// Continuité des Vibes : le ticker n'est plus arrêté quand la lecture est
/// en pause (voir MasterPlayerScreen) — le fond (nébuleuse, étoiles, shader)
/// continue de s'animer. Le ticker reste muet quand l'onglet Lecteur est
/// masqué (`TickerMode` de l'IndexedStack), sans surcoût batterie hors écran.
class TempoSyncController extends ChangeNotifier {
  TempoSyncController({required TickerProvider vsync}) {
    _ticker = vsync.createTicker(_onTick);
  }

  late final Ticker _ticker;
  double _bpm = 120;
  double pulse = 0;
  // Secondes écoulées depuis le premier tick — sert de `u_time` monotone au
  // shader de particules (Vibe Engine), distinct de `pulse` (0..1 cyclique).
  // Reste monotone même après un stop()/start() : un `Ticker` redémarré
  // repart de `Duration.zero`, ce qui faisait sauter l'animation en arrière.
  double elapsedSeconds = 0;
  Duration _accumulated = Duration.zero;
  Duration _lastElapsed = Duration.zero;

  double get bpm => _bpm;

  bool get isRunning => _ticker.isActive;

  void updateBpm(double bpm) => _bpm = bpm;

  void start() {
    if (!_ticker.isActive) _ticker.start();
  }

  void stop() {
    if (!_ticker.isActive) return;
    _ticker.stop();
    _accumulated += _lastElapsed;
    _lastElapsed = Duration.zero;
  }

  void _onTick(Duration elapsed) {
    _lastElapsed = elapsed;
    final Duration total = _accumulated + elapsed;
    final double beatsPerMs = _bpm / 60000;
    pulse = (total.inMilliseconds * beatsPerMs) % 1.0;
    elapsedSeconds = total.inMicroseconds / 1e6;
    notifyListeners();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }
}
