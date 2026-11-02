import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Cadence de l'enveloppe des basses : un octet toutes les 40 ms.
const double kBassEnvelopeRateHz = 25;

// Montée rapide pour suivre l'attaque d'un kick, descente lente pour qu'un
// scintillement s'éteigne au lieu de clignoter.
const double _bassRiseTau = 0.03;
const double _bassFallTau = 0.3;

/// Niveau des basses (0..1) à l'instant [seconds] : lecture de [envelope]
/// interpolée linéairement entre deux octets, bornée aux deux extrémités.
/// Fonction pure — le ticker ne fait que l'appeler.
double bassLevelAt(Uint8List envelope, double seconds) {
  if (envelope.isEmpty) return 0;
  final double index = seconds * kBassEnvelopeRateHz;
  if (index <= 0) return envelope.first / 255;
  if (index >= envelope.length - 1) return envelope.last / 255;
  final int lower = index.floor();
  final double fraction = index - lower;
  return (envelope[lower] + (envelope[lower + 1] - envelope[lower]) * fraction) / 255;
}

/// Lissage exponentiel indépendant de la cadence d'images : le même temps écoulé
/// donne le même résultat à 30, 60 ou 120 images par seconde, ce qu'un
/// coefficient fixe par image ne garantit pas.
double smoothBassLevel(double previous, double target, double dtSeconds) {
  if (dtSeconds <= 0) return previous;
  final double tau = target > previous ? _bassRiseTau : _bassFallTau;
  return previous + (target - previous) * (1 - math.exp(-dtSeconds / tau));
}

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

  // Réactivité aux basses (Vibe "Behind the window") : enveloppe 25 Hz du
  // morceau et dernière position connue du lecteur. Le flux de position de
  // just_audio n'émet pas à chaque image : entre deux synchros, la position est
  // extrapolée avec l'horloge du ticker (`elapsedSeconds`) tant que ça joue.
  Uint8List? _bassEnvelope;
  double _syncedPositionSeconds = 0;
  double _syncedAtElapsedSeconds = 0;
  bool _playing = false;

  /// Niveau des basses lissé (0..1), recalculé à chaque tick. Null sans
  /// enveloppe : l'effet retombe alors sur la pulsation du tempo.
  double? bassLevel;

  double get bpm => _bpm;

  bool get isRunning => _ticker.isActive;

  void updateBpm(double bpm) => _bpm = bpm;

  /// Appelé à chaque build de l'écran avec la même enveloppe : ne fait rien si
  /// elle n'a pas changé. Ne notifie pas (le prochain tick republie le niveau).
  void setBassEnvelope(Uint8List? envelope) {
    if (identical(envelope, _bassEnvelope)) return;
    _bassEnvelope = envelope;
    // Un niveau lissé hérité de l'ancien morceau ferait un à-coup au départ.
    bassLevel = envelope == null ? null : 0;
  }

  /// Recale l'horloge de lecture sur la position annoncée par le lecteur.
  void syncPosition(Duration position, {required bool playing}) {
    _syncedPositionSeconds = position.inMicroseconds / 1e6;
    _syncedAtElapsedSeconds = elapsedSeconds;
    _playing = playing;
  }

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
    final double previousSeconds = elapsedSeconds;
    elapsedSeconds = total.inMicroseconds / 1e6;
    final Uint8List? envelope = _bassEnvelope;
    if (envelope != null) {
      final double position = _syncedPositionSeconds + (elapsedSeconds - _syncedAtElapsedSeconds);
      // En pause, la cible est 0 : le niveau décroît au lieu de se figer.
      final double target = _playing ? bassLevelAt(envelope, position) : 0;
      bassLevel = smoothBassLevel(bassLevel ?? 0, target, elapsedSeconds - previousSeconds);
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }
}
