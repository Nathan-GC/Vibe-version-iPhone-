import 'package:audio_session/audio_session.dart';

/// Ce que le lecteur doit faire face à un événement de focus audio.
enum InterruptionAction { none, duck, unduck, pause, resume }

/// Focus audio (Lot 1.2) — règle unique Android/iOS, appliquée par
/// PlayerController (seul propriétaire : `just_audio` est créé avec
/// `handleInterruptions: false`, voir audioPlayerProvider).
///
///  - Notification, guidage GPS... (Android `lossTransientCanDuck`) : volume
///    baissé le temps du son, jamais de pause. Ancien bug : notre écouteur
///    mettait en pause sur CE signal aussi, sans jamais reprendre — la musique
///    se coupait à chaque notification.
///  - Appel, alarme, Siri (Android `lossTransient`, iOS début
///    d'interruption) : pause, puis reprise automatique à la fin SI la lecture
///    était en cours au début ET si le système l'autorise (iOS
///    `shouldResume`, exposé en [AudioInterruptionType.pause]).
///  - Perte définitive (autre app musicale) : pause, sans reprise.
///  - Play/Pause de l'utilisateur entre-temps : la reprise est annulée.
class AudioInterruptionPolicy {
  bool _resumeOnEnd = false;

  InterruptionAction onEvent(AudioInterruptionEvent event, {required bool isPlaying}) {
    if (event.begin) {
      if (event.type == AudioInterruptionType.duck) return InterruptionAction.duck;
      // Lecture déjà arrêtée (pause manuelle, interruption imbriquée) : rien
      // à suspendre, et une reprise déjà promise reste due.
      if (!isPlaying) return InterruptionAction.none;
      _resumeOnEnd = true;
      return InterruptionAction.pause;
    }
    switch (event.type) {
      case AudioInterruptionType.duck:
        return InterruptionAction.unduck;
      case AudioInterruptionType.pause:
        final bool resume = _resumeOnEnd;
        _resumeOnEnd = false;
        return resume ? InterruptionAction.resume : InterruptionAction.none;
      case AudioInterruptionType.unknown:
        _resumeOnEnd = false;
        return InterruptionAction.none;
    }
  }

  /// Play/Pause explicite (bouton, casque, notification, casque débranché) :
  /// l'utilisateur a repris la main, plus de reprise automatique.
  void onUserCommand() => _resumeOnEnd = false;
}
