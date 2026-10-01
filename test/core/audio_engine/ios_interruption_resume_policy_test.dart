import 'package:audio_session/audio_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/audio_engine/ios_interruption_resume_policy.dart';

void main() {
  late IosInterruptionResumePolicy policy;

  setUp(() => policy = IosInterruptionResumePolicy());

  test('resumes after a transient interruption when iOS allows it (shouldResume)', () {
    policy.onInterruptionBegin(wasPlaying: true);

    expect(policy.shouldResumeOnInterruptionEnd(AudioInterruptionType.pause), isTrue);
  });

  test('never resumes a track that was paused manually before the interruption', () {
    policy.onInterruptionBegin(wasPlaying: false);

    expect(policy.shouldResumeOnInterruptionEnd(AudioInterruptionType.pause), isFalse);
  });

  test('does not resume when iOS does not grant shouldResume', () {
    policy.onInterruptionBegin(wasPlaying: true);

    expect(policy.shouldResumeOnInterruptionEnd(AudioInterruptionType.unknown), isFalse);
  });

  test('resumes at most once per interruption', () {
    policy.onInterruptionBegin(wasPlaying: true);
    policy.shouldResumeOnInterruptionEnd(AudioInterruptionType.pause);

    expect(policy.shouldResumeOnInterruptionEnd(AudioInterruptionType.pause), isFalse);
  });
}
