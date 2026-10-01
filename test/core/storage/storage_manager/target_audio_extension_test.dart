import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/storage/storage_manager/storage_manager_service.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('Android: imported files are always renamed to .mp3 (historical behaviour)', () {
    expect(StorageManagerService.targetAudioExtensionFor('/cache/file_picker/Song.m4a'), '.mp3');
    expect(StorageManagerService.targetAudioExtensionFor('/cache/file_picker/Song.FLAC'), '.mp3');
  });

  test('iOS: keeps the original extension so AVFoundation picks the right decoder', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

    expect(StorageManagerService.targetAudioExtensionFor('/tmp/Song.m4a'), '.m4a');
    expect(StorageManagerService.targetAudioExtensionFor('/tmp/Song.FLAC'), '.flac');
    expect(StorageManagerService.targetAudioExtensionFor('/tmp/Song.mp3'), '.mp3');
  });

  test('iOS: falls back to .mp3 when the picked file has no extension', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

    expect(StorageManagerService.targetAudioExtensionFor('/tmp/Song'), '.mp3');
  });
}
