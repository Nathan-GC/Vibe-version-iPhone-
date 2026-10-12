import 'package:audio_session/audio_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/audio_engine/audio_interruption_policy.dart';

void main() {
  late AudioInterruptionPolicy policy;

  setUp(() => policy = AudioInterruptionPolicy());

  InterruptionAction begin(AudioInterruptionType type, {bool isPlaying = true}) =>
      policy.onEvent(AudioInterruptionEvent(true, type), isPlaying: isPlaying);

  InterruptionAction end(AudioInterruptionType type) =>
      policy.onEvent(AudioInterruptionEvent(false, type), isPlaying: false);

  test('a notification (Android "can duck") lowers the volume, never pauses', () {
    expect(begin(AudioInterruptionType.duck), InterruptionAction.duck);
    expect(end(AudioInterruptionType.duck), InterruptionAction.unduck);
  });

  test('resumes after a transient interruption when the system allows it (Android gain, iOS shouldResume)', () {
    expect(begin(AudioInterruptionType.pause), InterruptionAction.pause);
    expect(end(AudioInterruptionType.pause), InterruptionAction.resume);

    expect(begin(AudioInterruptionType.unknown), InterruptionAction.pause, reason: 'iOS : début toujours sans type');
    expect(end(AudioInterruptionType.pause), InterruptionAction.resume);
  });

  test('never resumes a track that was paused manually before the interruption', () {
    expect(begin(AudioInterruptionType.pause, isPlaying: false), InterruptionAction.none);
    expect(end(AudioInterruptionType.pause), InterruptionAction.none);
  });

  test('does not resume when the system does not grant it (permanent loss, no iOS shouldResume)', () {
    begin(AudioInterruptionType.unknown);

    expect(end(AudioInterruptionType.unknown), InterruptionAction.none);
  });

  test('resumes at most once per interruption', () {
    begin(AudioInterruptionType.pause);
    end(AudioInterruptionType.pause);

    expect(end(AudioInterruptionType.pause), InterruptionAction.none);
  });

  test('a play/pause from the user cancels the pending resume', () {
    begin(AudioInterruptionType.pause);
    policy.onUserCommand();

    expect(end(AudioInterruptionType.pause), InterruptionAction.none);
  });
}
