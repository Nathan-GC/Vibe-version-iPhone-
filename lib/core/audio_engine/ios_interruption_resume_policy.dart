import 'package:audio_session/audio_session.dart';

/// iOS : reprise automatique de la lecture à la fin d'une interruption
/// transitoire (appel raccroché, Siri, alarme, autre app audio).
///
/// Sur Android, cette reprise — comportement officiel de Vibe Player, voir
/// PlayerController._configureAudioSession — est assurée nativement par la
/// négociation de focus audio d'ExoPlayer. AVFoundation, lui, ne relance
/// JAMAIS la lecture : le système signale seulement, en fin
/// d'interruption, si la reprise est appropriée
/// (`AVAudioSessionInterruptionOptionShouldResume`, exposé par
/// `audio_session` comme [AudioInterruptionType.pause]). Cette règle
/// reproduit donc le comportement Android : reprise uniquement si la lecture
/// était réellement en cours au début de l'interruption (jamais après une
/// pause manuelle) ET si iOS l'autorise.
class IosInterruptionResumePolicy {
  bool _resumeOnEnd = false;

  /// Début d'interruption : [wasPlaying] = lecture en cours à cet instant.
  void onInterruptionBegin({required bool wasPlaying}) => _resumeOnEnd = wasPlaying;

  /// Fin d'interruption : `true` s'il faut relancer la lecture. Consomme
  /// l'état — une seule reprise par interruption.
  bool shouldResumeOnInterruptionEnd(AudioInterruptionType type) {
    final bool resume = _resumeOnEnd && type == AudioInterruptionType.pause;
    _resumeOnEnd = false;
    return resume;
  }
}
