import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart' show LicenseEntryWithLineBreaks, LicenseRegistry, kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import 'app/app.dart';
import 'app/bootstrap.dart';
import 'core/audio_engine/playlist_audio_handler.dart';
import 'core/networking/dev_http_overrides.dart';
import 'core/platform/app_platform.dart';
import 'core/storage/database/database_provider.dart';
import 'core/storage/database/sandbox_path_relocator.dart';
import 'features/onboarding/presentation/legal_consent.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kDebugMode) {
    HttpOverrides.global = DevHttpOverrides();
  }

  // Police Outfit embarquée (assets/fonts/) : aucun appel à Google Fonts au
  // lancement. Sa licence SIL OFL 1.1 doit accompagner les fichiers.
  GoogleFonts.config.allowRuntimeFetching = false;
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(['Outfit (police)'], await rootBundle.loadString('assets/fonts/OFL.txt'));
  });

  // Un seul conteneur, partagé entre le handler audio_service (créé ici, hors
  // de l'arbre de widgets) et le reste de l'app (voir UncontrolledProviderScope
  // ci-dessous) — le handler pilote ainsi le même PlayerController que l'UI,
  // sans second moteur `just_audio` ni duplication de la logique de Queue.
  final ProviderContainer container = ProviderContainer();

  // Conditions en vigueur acceptées avant tout le reste (premier lancement ou
  // mise à jour) : lecteur, notification média et réseau attendent jusque-là.
  await runLegalConsentGate(container);

  await bootstrap();

  // iOS : chemins absolus de la base réalignés sur le conteneur courant de
  // l'app (son UUID change à chaque mise à jour, voir SandboxPathRelocator)
  // AVANT qu'AudioService.init ne construise le lecteur, qui restaure aussitôt
  // la dernière session à partir de ces chemins.
  if (AppPlatform.isIOS) {
    try {
      await SandboxPathRelocator(container.read(appDatabaseProvider)).relocateToCurrentContainer();
    } catch (_) {
      // Jamais bloquant au démarrage : au pire, les morceaux concernés
      // restent signalés introuvables comme un fichier supprimé.
    }
  }

  // iOS : les champs `android*`/`notificationColor` ci-dessous y sont sans
  // effet — titre, artiste, pochette et progression remontent dans le
  // Centre de contrôle et l'écran verrouillé (MPNowPlayingInfoCenter), et
  // les commandes lecture/pause/suivant/précédent/seek en reviennent
  // (MPRemoteCommandCenter), via le même PlaylistAudioHandler ; la lecture
  // en arrière-plan repose sur `UIBackgroundModes: audio` (Info.plist).
  //
  // Notification média persistante (lecture en fond, écran verrouillé) —
  // Attention, `notificationColor` est fixé une fois pour toutes ici : l'API
  // Android ne permet pas de la reteindre dynamiquement selon la Vibe active
  // en cours de lecture (voir PlaylistAudioHandler).
  //
  // Stabilité en arrière-plan sur les morceaux longs (Section 5) :
  // `androidNotificationOngoing: true` est ce qui garde le service audio de
  // premier plan (et son wakelock, voir AndroidManifest.xml — WAKE_LOCK,
  // FOREGROUND_SERVICE, FOREGROUND_SERVICE_MEDIA_PLAYBACK) actif pendant une
  // pause plutôt que de le laisser passer en priorité basse, où Android peut
  // le tuer en Doze. `androidStopForegroundOnPause` reste volontairement à
  // sa valeur par défaut (`true`) : `audio_service` lève une assertion dès
  // la construction si `androidNotificationOngoing: true` est combiné à
  // `androidStopForegroundOnPause: false` (le premier n'a d'effet que si le
  // second reste `true` — voir AudioServiceConfigMessage), donc les deux ne
  // peuvent pas être ajustés indépendamment ici.
  await AudioService.init(
    builder: () => PlaylistAudioHandler(container),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.example.playlist_app.channel.audio',
      androidNotificationChannelName: 'Lecture audio',
      androidNotificationOngoing: true,
      notificationColor: Color(0xFF673AB7),
    ),
  );

  runApp(UncontrolledProviderScope(container: container, child: const PlaylistApp()));
}
