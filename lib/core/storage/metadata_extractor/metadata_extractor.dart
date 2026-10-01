import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_min/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/media_information.dart';
import 'package:ffmpeg_kit_flutter_new_min/media_information_session.dart';

import '../../shared/text/title_cleaner.dart';
import 'artist_name_normalizer.dart';
import 'raw_track_metadata.dart';

/// Lit les tags (Title, Artist, Album, Genre, Durée) via `ffprobe` — réutilise
/// ffmpeg_kit_flutter_new_min, déjà intégré pour le découpage de silence (Étape 2),
/// plutôt que flutter_media_metadata (abandonné : son android/build.gradle
/// cible AGP 3.5.0 et `jcenter()`, retiré des versions récentes de Gradle).
/// Un tag Artist combiné ("Daft Punk feat. Justice") est éclaté en artists[],
/// jamais conservé aplati (voir core/identity/track_key.dart).
class MetadataExtractor {
  // \b avant feat/ft/x : sans frontière de mot, "ft" matchait aussi à
  // l'intérieur de "Daft" et coupait "Daft Punk" en ["Da", "Punk"] même sans
  // featuring — bug réel découvert en testant avec de vrais morceaux Daft Punk.
  static final RegExp _artistSplitPattern = RegExp(r'\s*(\bfeat\.?|\bft\.?|,|&|\bx\b)\s*', caseSensitive: false);

  Future<RawTrackMetadata> extract(File file) async {
    final MediaInformationSession session = await FFprobeKit.getMediaInformation(file.path);
    final MediaInformation? info = session.getMediaInformation();
    if (info == null) return const RawTrackMetadata();

    final Map<dynamic, dynamic> tags = info.getTags() ?? const {};
    String? tag(String key) => (tags[key] ?? tags[key.toUpperCase()]) as String?;

    final String? rawArtist = tag('artist');
    final List<String> artists =
        rawArtist == null ? const [] : ArtistNameNormalizer.splitAndNormalize(rawArtist, _artistSplitPattern);

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
    );
  }
}
