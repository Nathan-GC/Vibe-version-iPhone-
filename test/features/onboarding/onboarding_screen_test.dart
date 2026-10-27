import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:playlist_app/core/purge/local_notification_service.dart';
import 'package:playlist_app/core/storage/cover_art/remote_cover_auto_trigger.dart';
import 'package:playlist_app/core/storage/database/app_database.dart';
import 'package:playlist_app/core/storage/database/database_provider.dart';
import 'package:playlist_app/core/storage/database/track_repository.dart';
import 'package:playlist_app/core/storage/scanner/full_device_scan_service.dart';
import 'package:playlist_app/core/storage/scanner/scanned_track.dart';
import 'package:playlist_app/features/onboarding/data/onboarding_providers.dart';
import 'package:playlist_app/features/onboarding/presentation/onboarding_screen.dart';
import 'package:playlist_app/features/settings/data/auto_enrich_preference.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Journal partagé des demandes système et du scan, dans l'ordre d'appel.
final List<String> _log = [];

class _FakePermissions implements OnboardingPermissions {
  _FakePermissions({required this.audioGranted});

  final bool audioGranted;

  @override
  Future<void> requestNotifications({required void Function() onTap}) async => _log.add('notifications');

  @override
  Future<bool> requestAudio() async {
    _log.add('audio');
    return audioGranted;
  }
}

/// Déclencheur de rapatriement des pochettes factice : pas de flux Drift (qui
/// laisserait un timer en attente à la fermeture) ni de réseau ; journalise
/// seulement la passe lancée à la fin de l'onboarding.
class _FakeCoverTrigger implements RemoteCoverAutoTrigger {
  @override
  Future<int> runPass() async {
    _log.add('cover-pass');
    return 0;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeScan implements FullDeviceScanService {
  /// Réglage d'enrichissement tel qu'enregistré au moment où le scan démarre.
  bool? enrichPreferenceAtScan;

  /// Si défini, le scan reste en cours d'indexation jusqu'à sa complétion.
  Completer<void>? hold;

  @override
  Future<List<ScannedTrack>> scan({
    required TrackRepository trackRepository,
    void Function(FullDeviceScanProgress progress)? onProgress,
  }) async {
    _log.add('scan');
    enrichPreferenceAtScan = await AutoEnrichPreference.isEnabled();
    onProgress?.call(const FullDeviceScanProgress(phase: FullDeviceScanPhase.indexing, processed: 1, total: 2));
    await hold?.future;
    return const [];
  }
}

void main() {
  late AppDatabase db;
  late _FakeScan scan;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    _log.clear();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    scan = _FakeScan();
  });
  tearDown(() => db.close());

  /// Onboarding tel qu'ouvert après l'écran de consentement (voir
  /// runLegalConsentGate, testé à part) : il démarre seul à l'étape 2.
  Future<void> open(WidgetTester tester, {bool audioGranted = true}) async {
    final GoRouter router = GoRouter(
      initialLocation: '/onboarding',
      routes: [
        GoRoute(path: '/onboarding', builder: (context, state) => const OnboardingScreen()),
        GoRoute(path: '/player', builder: (context, state) => const Scaffold(body: Text('PLAYER'))),
      ],
    );
    await tester.pumpWidget(ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        remoteCoverAutoTriggerProvider.overrideWithValue(_FakeCoverTrigger()),
        fullDeviceScanServiceProvider.overrideWithValue(scan),
        onboardingPermissionsProvider.overrideWithValue(_FakePermissions(audioGranted: audioGranted)),
      ],
      child: MaterialApp.router(routerConfig: router),
    ));
    await tester.pumpAndSettle();
  }

  Future<SharedPreferences> prefs() => SharedPreferences.getInstance();

  Future<void> answer(WidgetTester tester, String button) async {
    await tester.tap(find.text(button));
    await tester.pumpAndSettle();
  }

  testWidgets('steps 2 then 3 are requested on opening, then the import question, nothing scanned yet', (
    tester,
  ) async {
    await open(tester);

    expect(_log, ['notifications', 'audio']);
    expect(find.textContaining('importer automatiquement tous les titres audio'), findsOneWidget);
    // Rien d'autre à l'écran sous la modale (ancien « B » parasite, début de
    // « Bienvenue » décalé à gauche).
    expect(find.textContaining('Bienvenue'), findsNothing);
  });

  testWidgets('step 4 "Refuser": no scan, onboarding done, later manual imports stay offline', (tester) async {
    await open(tester);

    await answer(tester, 'Refuser');

    expect(find.textContaining('renommer et enrichir'), findsNothing);
    expect(_log, isNot(contains('scan')));
    expect(find.text('PLAYER'), findsOneWidget);
    expect((await prefs()).getBool('onboarding.full_scan_completed'), isTrue);
    // Installation neuve : le nouveau scan post-mise-à-jour est marqué fait (rien à rescanner).
    expect((await prefs()).getInt('library.rescan_done_version'), 1);
    // Interrupteur Paramètres > Confidentialité basculé sur OFF.
    expect((await prefs()).getBool('privacy.auto_enrich_on_import'), isFalse);
    // Android : aucune synchronisation de dossier à désactiver.
    expect((await prefs()).getBool('library.documents_auto_sync'), isNull);
  });

  testWidgets('steps 4 "Importer" + 5 "Non merci": choice saved before the scan, which then runs offline', (
    tester,
  ) async {
    await open(tester);

    await answer(tester, 'Importer');
    expect(_log, isNot(contains('scan')), reason: 'no scan before step 5 is answered');
    expect(find.textContaining('renommer et enrichir automatiquement'), findsOneWidget);

    await answer(tester, 'Non merci');

    // Fin de l'onboarding : une passe de rapatriement des pochettes est lancée
    // (le localiseur ne fera rien interrupteur OFF, voir son propre test).
    expect(_log, ['notifications', 'audio', 'scan', 'cover-pass']);
    expect(scan.enrichPreferenceAtScan, isFalse);
    expect((await prefs()).getBool('privacy.auto_enrich_on_import'), isFalse);
    expect(find.text('PLAYER'), findsOneWidget);
    expect((await prefs()).getBool('onboarding.full_scan_completed'), isTrue);
    // Installation neuve : le nouveau scan post-mise-à-jour est marqué fait (rien à rescanner).
    expect((await prefs()).getInt('library.rescan_done_version'), 1);
  });

  testWidgets('step 5 "Activer" turns the Privacy switch on before the scan', (tester) async {
    await open(tester);

    await answer(tester, 'Importer');
    await answer(tester, 'Activer');

    expect(scan.enrichPreferenceAtScan, isTrue);
    expect((await prefs()).getBool('privacy.auto_enrich_on_import'), isTrue);
  });

  testWidgets('audio denied at step 3: no question, no scan, auto-enrichment OFF, import place named', (
    tester,
  ) async {
    await open(tester, audioGranted: false);

    expect(find.textContaining('importer automatiquement'), findsNothing);
    expect(_log, ['notifications', 'audio']);
    expect(find.text('PLAYER'), findsOneWidget);
    expect(find.textContaining('vous pourrez importer vos morceaux manuellement depuis Espace → Bibliothèque'),
        findsOneWidget);
    expect((await prefs()).getBool('onboarding.full_scan_completed'), isTrue);
    // Installation neuve : le nouveau scan post-mise-à-jour est marqué fait (rien à rescanner).
    expect((await prefs()).getInt('library.rescan_done_version'), 1);
    expect((await prefs()).getBool('privacy.auto_enrich_on_import'), isFalse);
  });

  testWidgets('scan progress addresses the user formally (vouvoiement)', (tester) async {
    scan.hold = Completer<void>();
    await open(tester);
    await answer(tester, 'Importer');
    await answer(tester, 'Non merci');

    expect(find.text('Indexation de votre bibliothèque...'), findsOneWidget);
    expect(find.textContaining(RegExp(r'\b(tu|ta|ton|tes)\b', caseSensitive: false)), findsNothing);

    scan.hold!.complete();
    await tester.pumpAndSettle();
  });

  group('iOS', () {
    testWidgets('step 4 "Refuser" also stops the automatic Files folder sync', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      await open(tester);

      await answer(tester, 'Refuser');

      expect(_log, isNot(contains('scan')));
      expect((await prefs()).getBool('privacy.auto_enrich_on_import'), isFalse);
      expect((await prefs()).getBool('library.documents_auto_sync'), isFalse);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('the import question names the only folder iOS lets Vibe read', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      await open(tester);

      expect(find.textContaining('Fichiers › Sur mon iPhone › Vibe ?'), findsOneWidget);
      expect(find.textContaining('sur votre appareil'), findsNothing);
      debugDefaultTargetPlatformOverride = null;
    });

    test('step 3 grants access without any system prompt (no READ_MEDIA_AUDIO on iOS)', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      // Sur iOS, permission_handler n'est jamais appelé : aucun canal de
      // plateforme n'existe en test, un appel lèverait MissingPluginException.
      expect(await OnboardingPermissions(LocalNotificationService()).requestAudio(), isTrue);
    });

    test('step 2 asks iOS through the notifications plugin itself, not permission_handler', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final _RecordingNotifications notifications = _RecordingNotifications();

      await OnboardingPermissions(notifications).requestNotifications(onTap: () {});

      expect(notifications.requestedIOSPermission, [true]);
    });
  });
}

class _RecordingNotifications implements LocalNotificationService {
  final List<bool> requestedIOSPermission = [];

  @override
  Future<void> initialize({void Function()? onNotificationTap, bool requestIOSPermission = false}) async =>
      requestedIOSPermission.add(requestIOSPermission);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
