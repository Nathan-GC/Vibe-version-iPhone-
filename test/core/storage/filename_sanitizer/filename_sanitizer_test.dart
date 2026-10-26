import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/storage/filename_sanitizer/filename_sanitizer.dart';

void main() {
  final sanitizer = FilenameSanitizer();

  group('happy path', () {
    test('splits a simple "Artist - Title.ext" filename', () {
      final r = sanitizer.sanitizeFilename('Daft Punk - One More Time.mp3');
      expect(r.artist, 'Daft Punk');
      expect(r.title, 'One More Time');
      expect(r.requiresUserReview, isFalse);
    });

    test('keeps a leading number that is part of the artist name (21 Savage)', () {
      final r = sanitizer.sanitizeFilename('21 Savage - A Lot.mp3');
      expect(r.artist, '21 Savage');
      expect(r.title, 'A Lot');
      expect(r.requiresUserReview, isFalse);
    });

    test('strips a genuine track-number prefix', () {
      final r = sanitizer.sanitizeFilename('03. Daft Punk - Harder Better Faster Stronger.mp3');
      expect(r.artist, 'Daft Punk');
      expect(r.title, 'Harder Better Faster Stronger');
    });
  });

  group('track-number regressions', () {
    test('does not mistake a repeated disc-track prefix for the artist (bug fixed)', () {
      // Auparavant : artist="01" (numéro de piste pris pour l'artiste).
      final r = sanitizer.sanitizeFilename('01-01- Give Life Back to Music.mp3');
      expect(r.artist, 'Unknown');
      expect(r.title, 'Give Life Back to Music');
      expect(r.requiresUserReview, isTrue);
    });

    test('does not strip a decimal number glued to text as a track prefix', () {
      // "104.5" est une fréquence radio, pas un numéro de piste.
      final r = sanitizer.sanitizeFilename('104.5SkyFM-skychaser(edit).m4a');
      expect(r.artist, isNot('5'));
      expect(r.artist, contains('104'));
    });
  });

  group('trailing ids and noise', () {
    test('strips a long epoch-timestamp id', () {
      final r = sanitizer.sanitizeFilename('Rihanna - Umbrella_1741206796902.mp3');
      expect(r.title, 'Umbrella');
    });

    test('strips a short underscore-prefixed id from a compact filename', () {
      final r = sanitizer.sanitizeFilename('ArcticMonkeys-505(Lyrics)_733.m4a');
      expect(r.artist, 'Arctic Monkeys');
      expect(r.title, '505');
    });

    test('does not strip a space-separated number that is part of a real title', () {
      final r = sanitizer.sanitizeFilename('Blink 182 - Song.mp3');
      expect(r.artist, 'Blink 182');
    });

    test('cleans a compound bracket noise tag not previously recognized', () {
      final r = sanitizer.sanitizeFilename('Abba - Dancing Queen (Official Music Video Remastered).mp3');
      expect(r.title, 'Dancing Queen');
    });

    test('strips a bare (non-bracketed) trailing noise word', () {
      final r = sanitizer.sanitizeFilename('SnoopDogg-WhoAmI(What\'smyname)-HQ_828.m4a');
      expect(r.artist, 'Snoop Dogg');
      expect(r.requiresUserReview, isFalse);
    });
  });

  group('bracket-aware artist/title split', () {
    test('ignores a dash inside a parenthesis when splitting', () {
      final r = sanitizer.sanitizeFilename(
        'Tame Impala, JENNIE - Dracula (JENNIE Remix - Official Lyric Video).mp3',
      );
      expect(r.artist, 'Tame Impala');
      expect(r.featuringArtists, ['JENNIE']);
      expect(r.title, 'Dracula (JENNIE Remix - Official Lyric Video)');
      expect(r.requiresUserReview, isFalse);
    });

    test('flags for review when the only dash is inside brackets (no real separator)', () {
      final r =
          sanitizer.sanitizeFilename('VladimirCauchemar&6IX9INEAulosReloaded(WSHHExclusive-OfficialMusicVideo).m4a');
      expect(r.artist, 'Unknown');
      expect(r.requiresUserReview, isTrue);
    });
  });

  group('download-id noise (hashes, GUIDs, query fragments)', () {
    test('strips an MD5-like hash glued to the end with a double dash', () {
      // Cas réel : le titre entier finissait par tomber sur le hash brut.
      final r = sanitizer.sanitizeFilename(
        'David Guetta   Memories (Lyrics) (tiktok) ft. Kid Cudi--5d77f56839a0bb9fa2743892f8241dd5.mp3',
      );
      expect(r.title, isNot(contains('5d77f56839a0bb9fa2743892f8241dd5')));
      expect(r.artist, isNot(contains('5d77f56839a0bb9fa2743892f8241dd5')));
    });

    test('strips a GUID without leaving a dangling separator', () {
      final r = sanitizer.sanitizeFilename('Daft Punk - One More Time-a1b2c3d4-e5f6-4890-abcd-ef1234567890.mp3');
      expect(r.artist, 'Daft Punk');
      expect(r.title, 'One More Time');
    });

    test('strips a yt_v= query fragment', () {
      final r = sanitizer.sanitizeFilename('Rick Astley - Never Gonna Give You Up-yt_v=dQw4w9WgXcQ.mp3');
      expect(r.artist, 'Rick Astley');
      expect(r.title, 'Never Gonna Give You Up');
    });

    test('strips a bracketed id without leaving an empty bracket shell', () {
      final r = sanitizer.sanitizeFilename('Rick Astley - Never Gonna Give You Up [yt_v=dQw4w9WgXcQ].mp3');
      expect(r.title, 'Never Gonna Give You Up');
      expect(r.title, isNot(contains('[')));
    });

    test('strips a short mixed alphanumeric CDN-style id', () {
      final r = sanitizer.sanitizeFilename('Some Artist - Track-001a4f9b8c2.mp3');
      expect(r.artist, 'Some Artist');
      expect(r.title, 'Track');
    });

    test('does not strip real numeric titles ("Song 2", "Waltz No. 2", "Mambo No. 5")', () {
      expect(sanitizer.sanitizeFilename('Blink 182 - Song 2.mp3').title, 'Song 2');
      expect(sanitizer.sanitizeFilename('Ludovico Einaudi - Waltz No. 2.mp3').title, 'Waltz No. 2');
      expect(sanitizer.sanitizeFilename('Lou Bega - Mambo No. 5.mp3').title, 'Mambo No. 5');
    });

    test('does not strip a real artist name made only of hex-range letters (no digit mixed in)', () {
      final r = sanitizer.sanitizeFilename('Deadmau5 - Strobe.mp3');
      expect(r.artist, 'Deadmau5');
      expect(r.title, 'Strobe');
    });

    test('flags for review instead of guessing when a redundant re-attribution tag remains after the hash is removed',
        () {
      // Cas réel : convention "Titre (tags)-NomChaîne-<hash>.mp3" — une fois
      // le hash seul retiré, "-Eurythmics" ne doit pas être pris pour un vrai
      // titre puisqu'il ne fait que répéter le début de l'artiste.
      final r = sanitizer.sanitizeFilename(
        'Eurythmics, Annie Lennox, Dave Stewart   Sweet Dreams (Are Made Of This) (Official Video)-Eurythmics-d0185932043d3000b48d310a26e5e8d2.mp3',
      );
      expect(r.title, isNot('Eurythmics'));
      expect(r.requiresUserReview, isTrue);
    });
  });

  group('multi-artist splitting (primary + featuring)', () {
    test('splits on "&" into primary artist and one featuring', () {
      final r = sanitizer.sanitizeFilename('Alesso & Ellie Goulding - Playground.mp3');
      expect(r.artist, 'Alesso');
      expect(r.featuringArtists, ['Ellie Goulding']);
    });

    test('splits on a standalone "x" without swallowing an artist starting with "X"', () {
      final withX = sanitizer.sanitizeFilename('Alesso x Ellie Goulding - Playground.mp3');
      expect(withX.artist, 'Alesso');
      expect(withX.featuringArtists, ['Ellie Goulding']);

      final startsWithX = sanitizer.sanitizeFilename('X Ambassadors - Renegades.mp3');
      expect(startsWithX.artist, 'X Ambassadors');
      expect(startsWithX.featuringArtists, isEmpty);
    });

    test('splits on "vs" and "feat."/"ft." within the artist segment', () {
      final vs = sanitizer.sanitizeFilename('Ali vs Kevin Marques - Blade.mp3');
      expect(vs.artist, 'Ali');
      expect(vs.featuringArtists, ['Kevin Marques']);

      final feat = sanitizer.sanitizeFilename('David Guetta feat. Sia - Titanium.mp3');
      expect(feat.artist, 'David Guetta');
      expect(feat.featuringArtists, ['Sia']);

      final ft = sanitizer.sanitizeFilename('Alan Walker ft. Sabrina Carpenter - Faded.mp3');
      expect(ft.artist, 'Alan Walker');
      expect(ft.featuringArtists, ['Sabrina Carpenter']);
    });

    test('keeps a single artist without featurings unaffected', () {
      final r = sanitizer.sanitizeFilename('Daft Punk - One More Time.mp3');
      expect(r.artist, 'Daft Punk');
      expect(r.featuringArtists, isEmpty);
    });
  });

  group('protected artist names with special punctuation', () {
    test('keeps "Fred again.." intact instead of losing its trailing dots', () {
      final r = sanitizer.sanitizeFilename('Fred again.. - Delilah (pull me out of this).mp3');
      expect(r.artist, 'Fred again..');
      expect(r.title, 'Delilah (pull me out of this)');
      expect(r.featuringArtists, isEmpty);
    });

    test('keeps "AC/DC" intact on disk variants without a false artist/title split', () {
      final dash = sanitizer.sanitizeFilename('AC-DC - Thunderstruck.mp3');
      expect(dash.artist, 'AC/DC');
      expect(dash.title, 'Thunderstruck');
      expect(dash.requiresUserReview, isFalse);
    });

    test('does not split "Earth, Wind & Fire" on the comma/ampersand as if it were multiple artists', () {
      final r = sanitizer.sanitizeFilename('Earth, Wind & Fire - September.mp3');
      expect(r.artist, 'Earth, Wind & Fire');
      expect(r.featuringArtists, isEmpty);
    });
  });

  group('manual-review traps (do not guess)', () {
    test('flags a filename with no separator and no artist for manual review', () {
      final r = sanitizer.sanitizeFilename('Sounds.mp3');
      expect(r.artist, 'Unknown');
      expect(r.title, 'Sounds');
      expect(r.requiresUserReview, isTrue);
    });

    test('flags multiple top-level separators as ambiguous rather than guessing', () {
      final r = sanitizer.sanitizeFilename('Artist - Album - Song.mp3');
      expect(r.requiresUserReview, isTrue);
    });
  });

  group('protected names with separators or hyphens (real library files)', () {
    ({String artist, List<String> feat, String title}) parse(String name) {
      final r = sanitizer.sanitizeFilename(name);
      return (artist: r.artist, feat: r.featuringArtists, title: r.title);
    }

    test('"Tyler, The Creator" stays a single artist', () {
      final r = parse('Tyler, The Creator - Sugar On My Tongue (Lyrics)_1759923948611.mp3');
      expect(r.artist, 'Tyler, The Creator');
      expect(r.feat, isEmpty);
      expect(r.title, 'Sugar On My Tongue');
    });

    test('"by Tyler, The Creator" suffix is not split into two artists', () {
      final r = parse('GONE, GONE  THANK YOU by Tyler, The Creator lyrics_1750283457001.mp3');
      expect(r.feat, isEmpty);
      expect(r.title, contains('Tyler, The Creator'));
    });

    test('"Jay-Z" hyphen is not taken for the artist/title separator', () {
      final r = parse('Beyoncé ft. Jay-Z - Crazy in love [Lyrics]_1748454868166.mp3');
      expect(r.artist, 'Beyoncé');
      expect(r.feat, ['Jay-Z']);
      expect(r.title, 'Crazy in love');
    });

    test('"JAY-Z" at the end keeps its hyphen', () {
      final r = parse('Nias In Paris (Lyrics) JAY-Z_1716328040086.mp3');
      expect(r.artist, 'Unknown');
      expect(r.title, contains('Jay-Z'));
    });

    test('"Ne-Yo" is kept whole among several featurings', () {
      final r = parse('Pitbull - Give Me Everything (Lyrics) Ft. Ne-Yo, Afrojack, Nayer_1717096919460.mp3');
      expect(r.artist, 'Pitbull');
      expect(r.title, contains('Ne-Yo'));
    });

    test('"Selena Gomez & The Scene" stays ONE artist', () {
      final r = parse('Selena Gomez & The Scene - Love You Like A Love Song (Lyrics).m4a');
      expect(r.artist, 'Selena Gomez & The Scene');
      expect(r.feat, isEmpty);
      expect(r.title, 'Love You Like A Love Song');
    });

    test('compact "TheMamas&ThePapas" is recognised and spaced', () {
      final r = parse("TheMamas&ThePapas-CaliforniaDreamin'_401.m4a");
      expect(r.artist, 'The Mamas & The Papas');
      expect(r.feat, isEmpty);
      expect(r.title, "California Dreamin'");
    });

    test('"Hunter X Hunter" is never split into two "Hunter"', () {
      final r = parse('Hunter X Hunter - Opening 1 _ Departure!_1670707661361.mp3');
      expect(r.artist, 'Hunter x Hunter');
      expect(r.feat, isEmpty);
      expect(r.title, 'Opening 1 Departure!');
    });

    test('compact "HunterxHunter" and the "×" sign are protected too', () {
      final compact = parse('HunterxHunter2011OST-RestrictionandPledge[extended]_346.m4a');
      expect(compact.feat, isEmpty);
      expect(compact.artist, startsWith('Hunter x Hunter'));
      final sign = parse('Hunter×Hunter(2011)-PhantomTroupeSoundtracks_934.m4a');
      expect(sign.feat, isEmpty);
      expect(sign.artist, startsWith('Hunter x Hunter'));
    });

    test('"Earth, Wind & Fire" keeps working', () {
      final r = parse('Earth, Wind & Fire - Boogie Wonderland (Lyrics)_1749836887015.mp3');
      expect(r.artist, 'Earth, Wind & Fire');
      expect(r.feat, isEmpty);
      expect(r.title, 'Boogie Wonderland');
    });

    test('no protected pattern fires inside "Daft Punk" or "ThePixies"', () {
      final daft = parse('Daft Punk - One More Time (Official Video)_1725636997429.mp3');
      expect(daft.artist, 'Daft Punk');
      expect(daft.feat, isEmpty);
      expect(daft.title, 'One More Time');
      final pixies = parse('ThePixies-Whereismymind{lyrics}_976.m4a');
      expect(pixies.artist, 'The Pixies');
      expect(pixies.feat, isEmpty);
    });

    test('"Kool & The Gang", "Years & Years" and "Mumford & Sons" are single artists', () {
      for (final name in ['Kool & The Gang', 'Years & Years', 'Mumford & Sons']) {
        final r = parse('$name - Some Song.mp3');
        expect(r.artist, name);
        expect(r.feat, isEmpty);
      }
    });
  });

  group('noise words (directed by, letra, lyrics, tiktok, slowed, sped up, free download, ??)', () {
    String title(String f) => sanitizer.sanitizeFilename(f).title;

    test('removes the "Directed by" credit bracket', () {
      final r = sanitizer.sanitizeFilename('Eminem - Godzilla ft. Juice WRLD (Directed by Cole Bennett).m4a');
      expect(r.artist, 'Eminem');
      expect(r.title, 'Godzilla ft. Juice WRLD');
      expect(title('Juice WRLD - Lucid Dreams (Directed by Cole Bennett).m4a'), 'Lucid Dreams');
    });

    test('removes corrupted emojis ("??") and trailing ids', () {
      expect(title('Alejandro - Lady Gaga (Lyrics) ??_1744731232522.mp3'), 'Lady Gaga');
      expect(title('CallMeMaybe-CarlyRaeJepsen(Lyrics)??_218.m4a'), 'Carly Rae Jepsen');
    });

    test('keeps a single "?" or "?!" and never returns an empty title', () {
      expect(title('Syko - BrooklynBloodPop?! (Lyrics)_1717176542219.mp3'), contains('?!'));
      final r = sanitizer.sanitizeFilename('MIA BOYKA - ???????? (Official Audio)_1780734355759.mp3');
      expect(r.title, isNotEmpty);
    });

    test('removes TikTok / Lyrics / Letra in and out of brackets', () {
      expect(title('Creeds - Push Up (Lyrics)  Tiktok_1761643521373.mp3'), 'Push Up');
      final kim = title(
        "Kim - Confidence (Lyrics) _Je le sens c'est lui l'homme de ma vie_ [Tiktok Song]_1780134074139.mp3",
      );
      expect(kim.toLowerCase(), isNot(contains('tiktok')));
      expect(title('Yo Voy - Zion Y Lennox Ft Daddy Letra (Lyrics)_1741300714498.mp3').toLowerCase(),
          isNot(contains('letra')));
      expect(
        title('David Guetta   Memories (Lyrics) (tiktok) ft. Kid Cudi--5d77f56839a0bb9fa2743892f8241dd5.mp3')
            .toLowerCase(),
        isNot(contains('tiktok')),
      );
      expect(title('Till I Collapse Lyrics by Eminem.m4a'), isNot(contains('Lyrics')));
      expect(title('ROSALÍA - DESPECHA (LetraLyrics)_1746905542269.mp3'), 'DESPECHA');
    });

    test('mixed brackets keep the version marker and drop only the noise', () {
      expect(title('Cool for the Summer (hardstyle remix + SLOWED)_1771860545993.mp3'), contains('(hardstyle remix)'));
      expect(title('Cool for the Summer (hardstyle remix + SLOWED)_1771860545993.mp3'), isNot(contains('SLOWED')));
      expect(title('JVSTIN - CLANDESTINA (TikTok Remix)_1670150722766.mp3'), 'CLANDESTINA (Remix)');
      expect(title('AaronSmith-Dancin(KRONORemix)-Lyrics_111.m4a'), contains('(KRONO Remix)'));
      expect(title('AaronSmith-Dancin(KRONORemix)-Lyrics_111.m4a'), isNot(contains('Lyrics')));
    });

    test('removes sped up / slowed / visualizer / remastered / free download', () {
      final sped = title('KillEva&ENCASSATOR-PsychoDreams(SpedUp)EnglishLyrics_361.m4a');
      expect(sped, isNot(contains('Sped')));
      expect(sped, isNot(contains('Lyrics')));
      expect(title('SUICIDAL-IDOL-ecstacy(slowed)_827.m4a').toLowerCase(), isNot(contains('slowed')));
      // "slowed + reverb" retiré d'un bloc, sans laisser "Reverb" seul.
      final String mareux = title('Mareux - The Perfect Girl (Retrowave_Synthwave cover) Slowed Reverb - '
          'SEAMLESS 16 MINUTE LOOP.m4a');
      expect(mareux, isNot(contains('Slowed')));
      expect(mareux, isNot(contains('Reverb')));
      expect(mareux, contains('cover'), reason: 'marqueur de version conservé');
      expect(title('ascendant vierge - Lotus Noir (Visualizer)_1752779624730.mp3'), 'Lotus Noir');
      expect(title('Abba - Dancing Queen (Official Music Video Remastered)_1717097183324.mp3'), 'Dancing Queen');
      final roi = sanitizer.sanitizeFilename(
        'VIDEOCLUB - ROI  INSTRUMENTAL ( + paroles  letra) FREE DOWNLOAD IN DESCRIPTION_1717703931030.mp3',
      );
      expect(roi.artist, 'VIDEOCLUB');
      expect(roi.title, 'ROI INSTRUMENTAL');
    });

    test('regression guards: real numeric titles and word boundaries survive', () {
      expect(title('ArcticMonkeys-505(Lyrics)_733.m4a'), '505');
      expect(title('Vivaldi-Summer,RV315_837.m4a'), 'Summer,RV315');
      expect(title('Some Artist - Lyricist Tiktoker.mp3'), 'Lyricist Tiktoker');
    });
  });
}
