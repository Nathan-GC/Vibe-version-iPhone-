import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/core/networking/metadata_api_client/online_track_result.dart';
import 'package:playlist_app/core/networking/metadata_api_client/track_match_confidence.dart';

OnlineTrackResult _track(String artist, String title, {int? durationMs}) =>
    OnlineTrackResult(artist: artist, title: title, durationMs: durationMs);

bool _reliable(String localTitle, String localArtist, OnlineTrackResult candidate) =>
    TrackMatchConfidence.isReliableMatch(localTitle: localTitle, localArtists: [localArtist], candidate: candidate);

void main() {
  group('isReliableMatch', () {
    test('accepts an exact title+artist match', () {
      expect(
        TrackMatchConfidence.isReliableMatch(
          localTitle: 'Only Girl (In The World)',
          localArtists: const ['Rihanna'],
          candidate: _track('Rihanna', 'Only Girl (In The World)'),
        ),
        isTrue,
      );
    });

    test('rejects a different song by the same artist (bad "pochette" risk)', () {
      // Cas réel observé : recherche libre "Charlotte Cardin Feel Good" qui
      // renvoyait "Confetti" du même artiste comme premier résultat.
      expect(
        TrackMatchConfidence.isReliableMatch(
          localTitle: 'Feel Good',
          localArtists: const ['Charlotte Cardin'],
          candidate: _track('Charlotte Cardin', 'Confetti'),
        ),
        isFalse,
      );
    });

    test('rejects a matching title from an unrelated artist', () {
      // Cas réel observé : "Dmitri Shostakovich Waltz No. 2" matchait en
      // premier une reprise violon d'un artiste turc sans rapport.
      expect(
        TrackMatchConfidence.isReliableMatch(
          localTitle: 'Waltz No. 2',
          localArtists: const ['Dmitri Shostakovich'],
          candidate: _track('Cihat Aşkın', 'Waltz No.2'),
        ),
        isFalse,
      );
    });

    test('requires an exact title when the local artist is unknown', () {
      expect(
        TrackMatchConfidence.isReliableMatch(
          localTitle: '4 Raws',
          localArtists: const ['Unknown'],
          candidate: _track('prodbyryan', '4 Raws (slowed)'),
        ),
        isFalse,
      );
      expect(
        TrackMatchConfidence.isReliableMatch(
          localTitle: 'Beto’s Horns (fred remix)',
          localArtists: const ['Unknown'],
          candidate: _track('Fred again.. & CA7RIEL & Paco Amoroso', 'Beto’s Horns (fred remix)'),
        ),
        isTrue,
      );
    });
  });

  group('composite score (titre cœur + artiste local)', () {
    test('accepts a title with a trailing feat. clause (same core title)', () {
      expect(_reliable('Godzilla', 'Eminem', _track('Eminem', 'Godzilla (feat. Juice WRLD)')), isTrue);
    });

    test('accepts a candidate artist listing collaborators of the local artist', () {
      expect(_reliable('Nightcall', 'Kavinsky', _track('Kavinsky, Angèle & Phoenix', 'Nightcall')), isTrue);
    });

    test('rejects a different title by the same artist', () {
      expect(_reliable('Feel Good', 'Charlotte Cardin', _track('Charlotte Cardin', 'Confetti')), isFalse);
    });

    test('rejects a close-but-different title (score below 0.8)', () {
      // Dice du titre = 4/7 (≈ 0,57), artiste = 1 : composite ≈ 0,79 < 0,8.
      expect(_reliable('Dancing Queen', 'ABBA', _track('ABBA', 'Dancing Queen Medley Of Hits')), isFalse);
    });
  });

  group('parité des mots-clés de version', () {
    test('a remix local never matches the standard candidate, and vice versa', () {
      expect(_reliable('Dancin (KRONO Remix)', 'Aaron Smith', _track('Aaron Smith', 'Dancin')), isFalse);
      expect(_reliable('Dancin', 'Aaron Smith', _track('Aaron Smith', 'Dancin (KRONO Remix)')), isFalse);
    });

    test('an instrumental candidate is rejected for a standard local title', () {
      expect(_reliable('Roi', 'Isaac Delusion', _track('Isaac Delusion', 'Roi (Instrumental)')), isFalse);
    });

    test('instrumental in the local title (no brackets, any case) matches a bracketed candidate', () {
      expect(_reliable('Roi INSTRUMENTAL', 'Isaac Delusion', _track('Isaac Delusion', 'Roi (Instrumental)')), isTrue);
      expect(_reliable('Roi instrumentale', 'Isaac Delusion', _track('Isaac Delusion', 'Roi (Instrumental)')), isTrue);
    });

    test('a keyword inside the title itself matches the same title', () {
      expect(_reliable('Live Your Life', 'T.I.', _track('T.I.', 'Live Your Life')), isTrue);
    });

    test('applies without a local artist too', () {
      expect(
        TrackMatchConfidence.pickBestMatch(
          localTitle: 'Roi',
          localArtists: const ['Unknown'],
          candidates: [_track('Isaac Delusion', 'Roi (Instrumental)')],
        ),
        isNull,
      );
    });
  });

  group('Unicode', () {
    test('matches an unaccented local artist with the accented candidate', () {
      expect(_reliable('Halo', 'Beyonce', _track('Beyoncé', 'Halo')), isTrue);
    });

    test('matches the same Cyrillic title and rejects two different ones', () {
      expect(_reliable('Группа крови', 'Кино', _track('Кино', 'Группа крови')), isTrue);
      expect(_reliable('Группа крови', 'Кино', _track('Кино', 'Звезда по имени Солнце')), isFalse);
    });
  });

  group('garde-fou de durée', () {
    bool reliable(OnlineTrackResult candidate, {int? localMs, bool skip = false}) =>
        TrackMatchConfidence.isReliableMatch(
          localTitle: 'One More Time',
          localArtists: const ['Daft Punk'],
          candidate: candidate,
          localDurationMs: localMs,
          skipDurationCheck: skip,
        );

    test('rejects an undecorated candidate 45 s away (> 40 s), accepts one 12 s away', () {
      expect(reliable(_track('Daft Punk', 'One More Time', durationMs: 225000), localMs: 180000), isFalse);
      expect(reliable(_track('Daft Punk', 'One More Time', durationMs: 192000), localMs: 180000), isTrue);
    });

    test('no check when the local duration is unknown or the candidate has none', () {
      expect(reliable(_track('Daft Punk', 'One More Time', durationMs: 400000)), isTrue);
      expect(reliable(_track('Daft Punk', 'One More Time', durationMs: 400000), localMs: 0), isTrue);
      expect(reliable(_track('Daft Punk', 'One More Time'), localMs: 180000), isTrue);
    });

    test('no check when skipDurationCheck is set (video file name)', () {
      expect(reliable(_track('Daft Punk', 'One More Time', durationMs: 400000), localMs: 180000, skip: true), isTrue);
    });

    test('also filters candidates in pickBestMatch when the artist is unknown', () {
      expect(
        TrackMatchConfidence.pickBestMatch(
          localTitle: 'One More Time',
          localArtists: const ['Unknown'],
          candidates: [_track('Daft Punk', 'One More Time', durationMs: 400000)],
          localDurationMs: 180000,
        ),
        isNull,
      );
    });
  });

  group('classement des candidats fiables (artiste connu)', () {
    OnlineTrackResult? pick(
      String title,
      String artist,
      List<OnlineTrackResult> candidates, {
      int? localMs,
      bool skip = false,
    }) =>
        TrackMatchConfidence.pickBestMatch(
          localTitle: title,
          localArtists: [artist],
          candidates: candidates,
          localDurationMs: localMs,
          skipDurationCheck: skip,
        );

    test('isDecorated ignores feat. clauses but flags version suffixes', () {
      expect(TrackMatchConfidence.isDecorated('Poker Face', 'Poker Face (Glam As You Radio Mix)'), isTrue);
      expect(TrackMatchConfidence.isDecorated('Poker Face', 'Poker Face'), isFalse);
      expect(TrackMatchConfidence.isDecorated('The Way I Are', 'The Way I Are (feat. Keri Hilson & D.O.E.)'), isFalse);
      expect(TrackMatchConfidence.isDecorated('Godzilla', 'Godzilla [ft. Juice WRLD]'), isFalse);
      expect(TrackMatchConfidence.isDecorated('Godzilla', 'Godzilla feat. Juice WRLD'), isFalse);
    });

    test('E1: prefers the undecorated candidate over an earlier decorated one', () {
      // Cas réel : « Poker Face » (Lady Gaga) — iTunes listait le Glam As You Radio Mix en premier.
      final best = pick(
          'Poker Face',
          'Lady Gaga',
          [
            _track('Lady Gaga', 'Poker Face (Glam As You Radio Mix)', durationMs: 229000),
            _track('Lady Gaga', 'Poker Face', durationMs: 237000),
          ],
          localMs: 237000);
      expect(best?.title, 'Poker Face');
    });

    test('E1: with skipDurationCheck, the closest duration wins among equals', () {
      // Cas réel : clip « Nightcall » — la version à 179 s colle à la durée du fichier.
      final best = pick(
          'Nightcall',
          'Kavinsky',
          [
            _track('Kavinsky', 'Nightcall (Kavinsky)', durationMs: 258000),
            _track('Kavinsky, Angèle & Phoenix', 'Nightcall (Kavinsky, Angèle & Phoenix)', durationMs: 179000),
          ],
          localMs: 179000,
          skip: true);
      expect(best?.durationMs, 179000);
    });

    test('E1: a candidate inside the 15 s window beats one outside it (<= 40 s), then iTunes order', () {
      final candidates = [
        _track('Eminem', 'Lose Yourself', durationMs: 260000), // 30 s : hors fenêtre de 15 s, dans les 40 s
        const OnlineTrackResult(artist: 'Eminem', title: 'Lose Yourself', album: 'B', durationMs: 235000),
        const OnlineTrackResult(artist: 'Eminem', title: 'Lose Yourself', album: 'C', durationMs: 240000),
      ];
      expect(pick('Lose Yourself', 'Eminem', candidates, localMs: 230000)?.album, 'B');
      // Sans candidat dans la fenêtre, le hors-fenêtre fiable reste accepté.
      expect(pick('Lose Yourself', 'Eminem', candidates.take(1).toList(), localMs: 230000)?.durationMs, 260000);
    });

    test('E2: the undecorated original beats the demo', () {
      final best = pick(
          'Starman',
          'David Bowie',
          [
            _track('David Bowie', 'Starman (Demo 2)', durationMs: 234000),
            _track('David Bowie', 'Starman', durationMs: 254000),
          ],
          localMs: 220000);
      expect(best?.title, 'Starman');
    });

    test('E2: a lone decorated candidate within 15 s is still accepted (no undecorated rejected)', () {
      final best = pick(
          'Starman',
          'David Bowie',
          [
            _track('David Bowie', 'Starman (Demo 2)', durationMs: 234000),
          ],
          localMs: 220000);
      expect(best?.title, 'Starman (Demo 2)');
    });

    test('E2: refuses the demo when the original only fails on duration', () {
      final best = pick(
          'Starman',
          'David Bowie',
          [
            _track('David Bowie', 'Starman (Demo 2)', durationMs: 234000),
            _track('David Bowie', 'Starman', durationMs: 300000), // 80 s d'écart : hors des 40 s
          ],
          localMs: 220000);
      expect(best, isNull);
    });

    test('E2: an undecorated candidate 36 s away is accepted, a decorated one 20 s away is refused', () {
      expect(
        pick('The Look', 'Roxette', [_track('Roxette', 'The Look', durationMs: 277000)], localMs: 241000)?.title,
        'The Look',
      );
      expect(
        pick('Starman', 'David Bowie', [_track('David Bowie', 'Starman (Demo 2)', durationMs: 240000)],
            localMs: 220000),
        isNull,
      );
    });

    test('E2: isReliableMatch applies the same decoration-dependent tolerance', () {
      bool reliable(OnlineTrackResult c) => TrackMatchConfidence.isReliableMatch(
            localTitle: 'Starman',
            localArtists: const ['David Bowie'],
            candidate: c,
            localDurationMs: 220000,
          );
      expect(reliable(_track('David Bowie', 'Starman', durationMs: 254000)), isTrue); // 34 s, non décoré
      expect(reliable(_track('David Bowie', 'Starman', durationMs: 262000)), isFalse); // 42 s
      expect(reliable(_track('David Bowie', 'Starman (Demo 2)', durationMs: 254000)), isFalse); // 34 s, décoré
    });
  });

  group('AN-18 : invité étranger classé après les autres (identité avec invités)', () {
    OnlineTrackResult c(String title, String artist, String album, int durationMs) =>
        OnlineTrackResult(title: title, artist: artist, album: album, durationMs: durationMs);

    // Les 11 candidats US+FR de la décision #421, dans l'ordre iTunes.
    final List<OnlineTrackResult> wayIAre = <OnlineTrackResult>[
      c('The Way I Are (feat. Keri Hilson & D.O.E.)', 'Timbaland', 'Shock Value', 179147),
      c('The Way I Are (feat. Keri Hilson & D.O.E.) [OneRepublic Remix Version]', 'Timbaland', 'Shock Value', 212280),
      c('The Way I Are (feat. Keri Hilson & D.O.E.)', 'Timbaland', 'Shock Value', 179120),
      c('The Way I Are (feat. Keri Hilson & D.O.E.) [Instrumental Version]', 'Timbaland',
          'Shock Value (Instrumental Version)', 214000),
      c('The Way I Are', 'Timbaland, Keri Hilson & D.O.E.', 'In a Perfect World...', 179293),
      c('The Way I Are (feat. Keri Hilson & D.O.E.) [Steve Aoki Pimpin Remix]', 'Timbaland', 'Shock Value', 251468),
      c('The Way I Are (feat. Keri Hilson & D.O.E.)', 'Timbaland', 'Shock Value', 179280),
      c('The Way I Are (feat. Tyssem) [France Only Version]', 'Timbaland featuring Tyssem',
          'The Way I Are - Single (feat. Tyssem) - Single', 198093),
      c('The Way I Are (feat. Keri Hilson)', 'Timbaland featuring Tyssem',
          'The Way I Are - Single (feat. Tyssem) - Single', 201293),
      c('The Way I Are (Remix)', 'Mistaloon & Francisco', 'Remixes', 234707),
      c('The Way I Are (Dance with Somebody) [feat. Lil Wayne]', 'Bebe Rexha', 'Dance', 187787),
    ];

    OnlineTrackResult? pickWith(List<String> artists, List<OnlineTrackResult> candidates,
            {String title = 'The Way I Are', int localMs = 211000}) =>
        TrackMatchConfidence.pickBestMatch(
          localTitle: title,
          localArtists: artists,
          candidates: candidates,
          localDurationMs: localMs,
        );

    test('#421 : identité avec invités -> « Shock Value » (n°0), pas le single France crédité « Tyssem »', () {
      final best = pickWith(const ['Timbaland', 'Keri Hilson', 'D.O.E.', 'Sebastian'], wayIAre);
      expect(best, same(wayIAre[0]));
      expect(best?.album, 'Shock Value');
    });

    test('#421 sans invités dans l identité : comportement inchangé, le n°8 (dans les 15 s) gagne encore', () {
      // Aucun invité local => le critère est inactif : n°8 (non décoré, 9,7 s d'écart) devance
      // les « Shock Value » à ~32 s (hors fenêtre de 15 s). Constat documenté, pas un souhait.
      final best = pickWith(const ['Timbaland'], wayIAre);
      expect(best, same(wayIAre[8]));
    });

    test('une clause feat. dans le titre local suffit à activer le critère', () {
      final best = pickWith(const ['Timbaland'], wayIAre, title: 'The Way I Are (feat. Keri Hilson & D.O.E.)');
      expect(best, same(wayIAre[0]));
    });

    test('Nightcall / Kavinsky sans invités : « Kavinsky, Angèle & Phoenix » reste choisissable', () {
      final best = TrackMatchConfidence.pickBestMatch(
        localTitle: 'Nightcall',
        localArtists: const ['Kavinsky'],
        candidates: <OnlineTrackResult>[
          c('Nightcall (Kavinsky)', 'Kavinsky', 'OutRun', 258000),
          c('Nightcall (Kavinsky, Angèle & Phoenix)', 'Kavinsky, Angèle & Phoenix', 'Nightcall', 179000),
        ],
        localDurationMs: 179000,
        skipDurationCheck: true,
      );
      expect(best?.artist, 'Kavinsky, Angèle & Phoenix');
    });

    test('un invité déjà présent dans l identité n est pas étranger (co-artistes locaux couverts)', () {
      // « Timbaland, Keri Hilson & D.O.E. » (n°4) : tous les invités sont connus localement, donc
      // à égalité de rang de durée il garde sa place iTunes face à un candidat qui crédite « Tyssem ».
      final best = pickWith(
        const ['Timbaland', 'Keri Hilson', 'D.O.E.'],
        <OnlineTrackResult>[wayIAre[8], wayIAre[4]],
        localMs: 190000,
      );
      expect(best, same(wayIAre[4]));
    });

    test('un invité collé dans le nom de fichier (« ColbyO\'Donis ») n est pas étranger', () {
      // Comparaison sans espaces : par mots, « colby o donis » ne retrouvait pas « colbyo donis »
      // et l'original cédait la place à un EP de remixes sans clause feat.
      final original = c('Just Dance (feat. Colby O\'Donis)', 'Lady Gaga', 'The Fame', 241000);
      final remixEp = c('Just Dance', 'Lady Gaga', 'Just Dance (Remixes) - EP [feat. Colby O\'Donis]', 242000);
      final best = TrackMatchConfidence.pickBestMatch(
        localTitle: 'Just Dance',
        localArtists: const ['Lady Gaga', 'ColbyO\'Donis'],
        candidates: <OnlineTrackResult>[original, remixEp],
        localDurationMs: 241000,
      );
      expect(best, same(original));
    });

    test('critère de rang uniquement : un seul candidat à invité étranger reste accepté', () {
      final best = pickWith(const ['Timbaland', 'Keri Hilson'], <OnlineTrackResult>[wayIAre[8]]);
      expect(best, same(wayIAre[8]));
    });
  });

  group('AN-21 : mentions neutres (remaster, mono...) et albums compilation', () {
    OnlineTrackResult c(String title, String album, int durationMs, {String artist = 'David Bowie'}) =>
        OnlineTrackResult(title: title, artist: artist, album: album, durationMs: durationMs);

    OnlineTrackResult? pick(List<OnlineTrackResult> candidates, {String title = 'Starman', int localMs = 220000}) =>
        TrackMatchConfidence.pickBestMatch(
          localTitle: title,
          localArtists: const ['David Bowie'],
          candidates: candidates,
          localDurationMs: localMs,
        );

    test('isDecorated : les mentions neutres ne décorent pas', () {
      expect(TrackMatchConfidence.isDecorated('Song', 'Song (2011 Remastered)'), isFalse);
      expect(TrackMatchConfidence.isDecorated('Song', 'Song (Remastered 2011)'), isFalse);
      expect(TrackMatchConfidence.isDecorated('Song', 'Song [2012 Remaster]'), isFalse);
      expect(TrackMatchConfidence.isDecorated('Song', 'Song - Remastered 2009'), isFalse);
      expect(TrackMatchConfidence.isDecorated('Song', 'Song - 2009 Remaster'), isFalse);
      expect(TrackMatchConfidence.isDecorated('Song', 'Song (Mono)'), isFalse);
      expect(TrackMatchConfidence.isDecorated('Song', 'Song (Stereo)'), isFalse);
      expect(TrackMatchConfidence.isDecorated('Song', 'Song (Single Version)'), isFalse);
      expect(TrackMatchConfidence.isDecorated('Song', 'Song - Single Version'), isFalse);
      expect(TrackMatchConfidence.isDecorated('Song', 'Song (Original Single Mix)'), isFalse);
      // Retrait des DEUX côtés, et combiné à une clause feat.
      expect(TrackMatchConfidence.isDecorated('Song (Remastered 2011)', 'Song'), isFalse);
      expect(TrackMatchConfidence.isDecorated('Song', 'Song (feat. X) - Remastered 2009'), isFalse);
    });

    test('isDecorated : live, demo, remix... restent décorés', () {
      expect(TrackMatchConfidence.isDecorated('Song', 'Song (Live)'), isTrue);
      expect(TrackMatchConfidence.isDecorated('Song', 'Song (Demo)'), isTrue);
      expect(TrackMatchConfidence.isDecorated('Song', 'Song (Radio Edit)'), isTrue);
      expect(TrackMatchConfidence.isDecorated('Song', 'Song (Remastered Live)'), isTrue);
      expect(TrackMatchConfidence.isDecorated('Song', 'Song (Live) - Remastered 2009'), isTrue);
    });

    test('une mention neutre après " - " ne fait pas chuter le score de titre', () {
      expect(_reliable('Heroes', 'David Bowie', _track('David Bowie', 'Heroes - Remastered 2017')), isTrue);
      expect(_reliable('Heroes', 'David Bowie', _track('David Bowie', 'Heroes - 2017 Remaster')), isTrue);
      // Une vraie décoration après " - " reste un autre titre.
      expect(_reliable('Heroes', 'David Bowie', _track('David Bowie', 'Heroes - Live at Wembley')), isFalse);
    });

    test(
        '« Starman (2012 Remaster) » à 34 s est accepté (non décoré => tolérance 40 s) et passe avant par ordre iTunes',
        () {
      final remaster =
          c('Starman (2012 Remaster)', 'The Rise and Fall of Ziggy Stardust and the Spiders from Mars', 254000);
      final changes = c('Starman', 'ChangesTwoBowie', 255000);
      // Avant AN-21, le Remaster (décoré, 34 s > 15 s) était rejeté et ChangesTwoBowie gagnait par défaut.
      expect(pick(<OnlineTrackResult>[remaster, changes]), same(remaster));
    });

    test('ChangesTwoBowie n est pas dans la liste de compilations : l ordre iTunes tranche', () {
      final remaster =
          c('Starman (2012 Remaster)', 'The Rise and Fall of Ziggy Stardust and the Spiders from Mars', 254000);
      final changes = c('Starman', 'ChangesTwoBowie', 255000);
      expect(pick(<OnlineTrackResult>[changes, remaster]), same(changes));
    });

    test('à égalité, un album « Greatest Hits » passe après un album studio', () {
      final greatest = c('Starman', 'The Best Of David Bowie Greatest Hits', 240000);
      final studio = c('Starman', 'Ziggy Stardust', 241000);
      expect(pick(<OnlineTrackResult>[greatest, studio]), same(studio));
    });

    test('mots de compilation : best of, hits, remixes, insensible à la casse, mots entiers', () {
      final studio = c('Starman', 'Ziggy Stardust', 241000);
      for (final String album in <String>['BEST OF Bowie', 'Bowie Hits', 'Starman Remixes', 'greatest']) {
        expect(pick(<OnlineTrackResult>[c('Starman', album, 240000), studio]), same(studio), reason: album);
      }
      // « Hitsville » / « Bestofyou » ne sont pas des mots de compilation : l'ordre iTunes tranche.
      final hitsville = c('Starman', 'Hitsville', 240000);
      expect(pick(<OnlineTrackResult>[hitsville, studio]), same(hitsville));
    });

    test('une bande originale n est pas une compilation : « 8 Mile » reste l album de « Lose Yourself »', () {
      final soundtrack =
          c('Lose Yourself', '8 Mile (Music from and Inspired By the Motion Picture)', 326000, artist: 'Eminem');
      final label = c('Lose Yourself', 'SHADYXV', 327000, artist: 'Eminem');
      final best = TrackMatchConfidence.pickBestMatch(
        localTitle: 'Lose Yourself',
        localArtists: const ['Eminem'],
        candidates: <OnlineTrackResult>[soundtrack, label],
        localDurationMs: 326000,
      );
      expect(best, same(soundtrack));
    });

    test('la compilation ne l emporte pas sur la proximité de durée (rang de durée prioritaire)', () {
      final greatestClose = c('Starman', 'Greatest Hits', 225000); // 5 s : dans la fenêtre
      final studioFar = c('Starman', 'Ziggy Stardust', 254000); // 34 s : hors fenêtre
      expect(pick(<OnlineTrackResult>[studioFar, greatestClose]), same(greatestClose));
    });
  });

  group('artiste local inconnu : titre sans clause feat. + durée serrée', () {
    OnlineTrackResult? pick(String title, List<OnlineTrackResult> candidates, {int? localMs}) =>
        TrackMatchConfidence.pickBestMatch(
          localTitle: title,
          localArtists: const ['Unknown'],
          candidates: candidates,
          localDurationMs: localMs,
        );

    test('E3: a feat. clause does not break title equality; the lullaby 8 s away is out of the 1.5 s window', () {
      final best = pick(
          'tv off',
          [
            _track('Kendrick Lamar', 'tv off (feat. Lefty Gunplay)', durationMs: 220000),
            _track('Lullaby artist', 'tv off', durationMs: 228000),
          ],
          localMs: 220000);
      expect(best?.artist, 'Kendrick Lamar');
    });

    test('E3: a homonym 8 s away is refused', () {
      expect(pick('Vin italien', [_track('Someone', 'Vin italien', durationMs: 188000)], localMs: 196000), isNull);
    });

    test('E3: isReliableMatch uses the same 1.5 s tolerance and feat.-insensitive equality', () {
      bool reliable(OnlineTrackResult c) => TrackMatchConfidence.isReliableMatch(
            localTitle: 'tv off',
            localArtists: const ['Unknown'],
            candidate: c,
            localDurationMs: 220000,
          );
      expect(reliable(_track('Kendrick Lamar', 'tv off (feat. Lefty Gunplay)', durationMs: 221400)), isTrue);
      expect(reliable(_track('Kendrick Lamar', 'tv off', durationMs: 222000)), isFalse);
    });
  });

  group('sameVersionKeywords', () {
    test('compares version keywords of full titles', () {
      expect(TrackMatchConfidence.sameVersionKeywords('Ian Asher (Remix)', 'Desire'), isFalse);
      expect(TrackMatchConfidence.sameVersionKeywords('Ian Asher', 'Desire'), isTrue);
      expect(TrackMatchConfidence.sameVersionKeywords('Roi INSTRUMENTAL', 'Roi (Instrumental)'), isTrue);
    });
  });

  group('pickBestMatch', () {
    test('rejects a generic title covered by several unrelated artists when local artist is unknown', () {
      // Cas réel observé : "Money Trees" sans artiste local matchait une
      // reprise "lullaby" avant l'original Kendrick Lamar.
      final best = TrackMatchConfidence.pickBestMatch(
        localTitle: 'Money Trees',
        localArtists: const ['Unknown'],
        candidates: [
          _track('Twinkle Twinkle Little Rock Star', 'Money Trees'),
          _track('Sladeboyy', 'Money Trees'),
          _track('Les Krills', 'Money Trees'),
        ],
      );
      expect(best, isNull);
    });

    test('picks the first reliable candidate when local artist is known', () {
      final best = TrackMatchConfidence.pickBestMatch(
        localTitle: 'Am I Dreaming',
        localArtists: const ['Metro Boomin', 'A\$AP Rocky', 'Roisee'],
        candidates: [
          _track('Some Karaoke Band', 'Am I Dreaming (Karaoke Version)'),
          _track('Metro Boomin, A\$AP Rocky & Roisee', 'Am I Dreaming'),
        ],
      );
      expect(best?.artist, 'Metro Boomin, A\$AP Rocky & Roisee');
    });

    test('accepts a unique exact title even without a local artist', () {
      final best = TrackMatchConfidence.pickBestMatch(
        localTitle: 'all my exes miss me',
        localArtists: const ['Unknown'],
        candidates: [_track('twoflow & Delaney Jane', 'all my exes miss me')],
      );
      expect(best?.artist, 'twoflow & Delaney Jane');
    });
  });

  group('artistTextForSwap (E6, titre local joué comme artiste en inversion)', () {
    test('removes the feat. clause, glued to the previous word or not', () {
      expect(TrackMatchConfidence.artistTextForSwap("Lady Gaga(Feat.Colby O'Donis)"), 'Lady Gaga');
      expect(TrackMatchConfidence.artistTextForSwap('Lady Gaga (feat. Colby)'), 'Lady Gaga');
      expect(TrackMatchConfidence.artistTextForSwap('Lady Gaga [ft. Colby]'), 'Lady Gaga');
      expect(TrackMatchConfidence.artistTextForSwap('Lady Gaga Featuring Colby'), 'Lady Gaga');
      expect(TrackMatchConfidence.artistTextForSwap('Lady Gaga ft Colby'), 'Lady Gaga');
    });

    test('never cuts inside a word (Daft Punk, Left, Feather)', () {
      expect(TrackMatchConfidence.artistTextForSwap('Daft Punk'), 'Daft Punk');
      expect(TrackMatchConfidence.artistTextForSwap('Left Boy'), 'Left Boy');
      expect(TrackMatchConfidence.artistTextForSwap('Feather'), 'Feather');
    });

    test('keeps the original title when the feat. clause leaves nothing', () {
      expect(TrackMatchConfidence.artistTextForSwap('feat. Colby'), 'feat. Colby');
    });

    test('strips characters foreign to an artist name but keeps . - & \$ , _ and accents', () {
      // Retrait pur, sans réduction des espaces (le score compare des mots, peu importe).
      expect(TrackMatchConfidence.artistTextForSwap('Beyoncé 🔥 "Live" (HD)'), 'Beyoncé  Live HD');
      expect(
          TrackMatchConfidence.artistTextForSwap('A\$AP Rocky & Jay-Z, D.O.E. _x'), 'A\$AP Rocky & Jay-Z, D.O.E. _x');
    });
  });
}
