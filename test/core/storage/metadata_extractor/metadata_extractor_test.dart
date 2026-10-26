import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/storage/metadata_extractor/metadata_extractor.dart';

void main() {
  group('splitArtistTag (tag ID3 Artist combiné)', () {
    test('keeps "Tyler, The Creator" as one artist', () {
      expect(MetadataExtractor.splitArtistTag('Tyler, The Creator'), ['Tyler, The Creator']);
    });

    test('splits a featuring after a protected name', () {
      expect(MetadataExtractor.splitArtistTag('Kool & The Gang feat. X'), ['Kool & The Gang', 'X']);
    });

    test('does not cut "Feather Wilson" on "feat"', () {
      expect(MetadataExtractor.splitArtistTag('Feather Wilson'), ['Feather Wilson']);
    });

    test('does not cut "X Ambassadors" on the leading "X"', () {
      expect(MetadataExtractor.splitArtistTag('X Ambassadors'), ['X Ambassadors']);
    });

    test('still splits "Daft Punk feat. Pharrell Williams"', () {
      expect(MetadataExtractor.splitArtistTag('Daft Punk feat. Pharrell Williams'), ['Daft Punk', 'Pharrell Williams']);
    });

    test('splits " x " and "ft." with strict boundaries', () {
      expect(MetadataExtractor.splitArtistTag('Calvin Harris x Rihanna'), ['Calvin Harris', 'Rihanna']);
      expect(MetadataExtractor.splitArtistTag('Beyoncé ft. Jay-Z'), ['Beyoncé', 'Jay-Z']);
      expect(MetadataExtractor.splitArtistTag('Ftx Band'), ['Ftx Band']);
    });
  });

  group('embeddedCoverCodecOf (pochette intégrée, propriétés ffprobe)', () {
    const audio = {'codec_type': 'audio', 'codec_name': 'mp3'};

    test('detects an MP3 cover (mjpeg attached_pic)', () {
      const cover = {
        'codec_type': 'video',
        'codec_name': 'mjpeg',
        'disposition': {'attached_pic': 1},
      };
      expect(MetadataExtractor.embeddedCoverCodecOf([audio, cover]), 'mjpeg');
    });

    test('detects an M4A cover (png attached_pic)', () {
      const cover = {
        'codec_type': 'video',
        'codec_name': 'png',
        'disposition': {'attached_pic': 1},
      };
      expect(MetadataExtractor.embeddedCoverCodecOf([audio, cover]), 'png');
    });

    test('returns null for an audio-only file', () {
      expect(MetadataExtractor.embeddedCoverCodecOf([audio]), isNull);
      expect(MetadataExtractor.embeddedCoverCodecOf([null, audio]), isNull);
    });

    test('ignores a real video stream and a video stream with attached_pic 0', () {
      const clip = {
        'codec_type': 'video',
        'codec_name': 'h264',
        'disposition': {'attached_pic': 0},
      };
      const noDisposition = {'codec_type': 'video', 'codec_name': 'h264'};
      expect(MetadataExtractor.embeddedCoverCodecOf([audio, clip, noDisposition]), isNull);
    });
  });
}
