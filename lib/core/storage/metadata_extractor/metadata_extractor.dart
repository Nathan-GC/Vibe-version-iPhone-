import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_min/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/media_information.dart';
import 'package:ffmpeg_kit_flutter_new_min/media_information_session.dart';
import 'package:flutter/foundation.dart';

import '../../shared/text/title_cleaner.dart';
import '../protected_artist_names.dart';
import 'artist_name_normalizer.dart';
import 'raw_track_metadata.dart';

/// Lit les tags (Title, Artist, Album, Genre, Durée) via `ffprobe` — réutilise
/// ffmpeg_kit_flutter_new_min, déjà intégré pour le découpage de silence (Étape 2),
/// plutôt que flutter_media_metadata (abandonné : son android/build.gradle
/// cible AGP 3.5.0 et `jcenter()`, retiré des versions récentes de Gradle).
/// Un tag Artist combiné ("Daft Punk feat. Justice") est éclaté en artists[],
/// jamais conservé aplati (voir core/identity/track_key.dart).
class MetadataExtractor {
  // \b avant feat/ft : sans frontière de mot, "ft" matchait aussi à
  // l'intérieur de "Daft" et coupait "Daft Punk" en ["Da", "Punk"] même sans
  // featuring — bug réel découvert en testant avec de vrais morceaux Daft Punk.
  // Frontière aussi APRÈS (`(?:\.|\b)`, même technique que le parseur de noms
  // de fichiers) : sans elle "Feather Wilson" était coupé sur "feat". Le "x"
  // exige des espaces des deux côtés pour ne pas couper "X Ambassadors".
  static final RegExp _artistSplitPattern = RegExp(
    r'\s*(\bfeat(?:\.|\b)|\bft(?:\.|\b)|,|&|\s+x\s+)\s*',
    caseSensitive: false,
  );

  /// Éclate un tag Artist combiné en artistes distincts, en protégeant d'abord
  /// les noms connus contenant un séparateur ("Tyler, The Creator").
  @visibleForTesting
  static List<String> splitArtistTag(String rawArtist) {
    final protection = ProtectedArtistNames.protect(rawArtist);
    return ArtistNameNormalizer.splitAndNormalize(protection.text, _artistSplitPattern)
        .map(protection.restore)
        .toList();
  }

  /// Codec de la pochette intégrée, d'après les propriétés ffprobe de chaque
  /// flux : une pochette est un flux vidéo dont la disposition `attached_pic`
  /// vaut 1 (ID3 APIC en MP3, `covr` en M4A, PICTURE en FLAC). Un vrai flux
  /// vidéo (clip) n'est pas marqué ainsi et reste ignoré. `null` sans pochette.
  @visibleForTesting
  static String? embeddedCoverCodecOf(Iterable<Map<dynamic, dynamic>?> streams) {
    for (final stream in streams) {
      if (stream == null || stream['codec_type'] != 'video') continue;
      final Object? disposition = stream['disposition'];
      final Object? attachedPic = disposition is Map ? disposition['attached_pic'] : null;
      if (attachedPic.toString() != '1') continue;
      final Object? codec = stream['codec_name'];
      return codec is String && codec.isNotEmpty ? codec : 'mjpeg';
    }
    return null;
  }

  Future<RawTrackMetadata> extract(File file) async {
    final MediaInformationSession session = await FFprobeKit.getMediaInformation(file.path);
    final MediaInformation? info = session.getMediaInformation();
    if (info == null) return const RawTrackMetadata();

    final Map<dynamic, dynamic> tags = info.getTags() ?? const {};
    String? tag(String key) => (tags[key] ?? tags[key.toUpperCase()]) as String?;

    final String? rawArtist = tag('artist');
    final List<String> artists = rawArtist == null ? const [] : splitArtistTag(rawArtist);

    final double? durationSeconds = double.tryParse(info.getDuration() ?? '');
    // TBPM (ID3v2) : ffprobe l'expose tel quel, parfois en décimal
    // ("128.00") — on tronque au BPM entier le plus proche.
    final double? rawBpm = double.tryParse(tag('TBPM') ?? tag('bpm') ?? '');

    final String? rawTitle = tag('title');

    return RawTrackMetadata(
      // Fichiers mal tagués (souvent issus de convertisseurs en ligne) : le
      // tag "title" lui-même peut contenir "(Official Video)"/"(Lyrics)"...
      title: rawTitle == null ? null : TitleCleaner.clean(rawTitle),
      artists: artists,
      album: tag('album'),
      genre: tag('genre'),
      durationMs: durationSeconds == null ? null : (durationSeconds * 1000).round(),
      bpm: rawBpm?.round(),
      embeddedCoverCodec: embeddedCoverCodecOf(info.getStreams().map((s) => s.getAllProperties())),
    );
  }
}
