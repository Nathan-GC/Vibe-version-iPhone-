import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/features/player/widgets/vibe_video_background.dart';
import 'package:video_player/video_player.dart';

void main() {
  const VideoPlayerValue base = VideoPlayerValue(duration: Duration(seconds: 5), isInitialized: true);

  test('a completed, stopped video must be restarted to keep looping', () {
    expect(videoNeedsLoopRestart(base.copyWith(isCompleted: true, isPlaying: false)), isTrue);
  });

  test('a playing, paused-midway or uninitialised video is left alone', () {
    expect(videoNeedsLoopRestart(base.copyWith(isPlaying: true)), isFalse);
    expect(videoNeedsLoopRestart(base), isFalse);
    expect(videoNeedsLoopRestart(const VideoPlayerValue.uninitialized()), isFalse);
  });
}
