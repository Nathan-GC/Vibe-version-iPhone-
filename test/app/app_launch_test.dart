import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playlist_app/app/app.dart';
import 'package:playlist_app/core/purge/local_notification_service.dart';
import 'package:playlist_app/core/purge/purge_providers.dart';
import 'package:playlist_app/core/storage/scanner/documents_library_sync.dart';
import 'package:playlist_app/core/storage/scanner/full_device_scan_service.dart';
import 'package:playlist_app/features/library/data/documents_sync_controller.dart';
import 'package:playlist_app/features/settings/presentation/legal_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeNotifications implements LocalNotificationService {
  final List<bool> requestedIOSPermission = [];

  @override
  Future<void> initialize({void Function()? onNotificationTap, bool requestIOSPermission = false}) async =>
      requestedIOSPermission.add(requestIOSPermission);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoopSync implements DocumentsLibrarySync {
  @override
  Future<DocumentsSyncResult> run({void Function(FullDeviceScanProgress progress)? onProgress}) async =>
      const DocumentsSyncResult(added: 0, enriched: 0, skippedIncompleteDownloads: 0);
}

void main() {
  late List<String> permissionCalls;
  late _FakeNotifications notifications;

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'onboarding.full_scan_completed': true,
      'legal.accepted_version': LegalScreen.lastUpdated,
    });
    permissionCalls = [];
    notifications = _FakeNotifications();
  });

  Future<void> launch(WidgetTester tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('flutter.baseflow.com/permissions/methods'),
      (call) async {
        permissionCalls.add(call.method);
        return call.method == 'requestPermissions' ? <int, int>{} : 0;
      },
    );
    await tester.pumpWidget(ProviderScope(
      overrides: [
        localNotificationServiceProvider.overrideWithValue(notifications),
        purgeCheckOnLaunchProvider.overrideWith((ref) async {}),
        documentsLibrarySyncProvider.overrideWithValue(_NoopSync()),
      ],
      child: const PlaylistApp(),
    ));
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('later launches never ask again for system permissions (a refusal at onboarding stands)', (
    tester,
  ) async {
    await launch(tester);

    // Tap sur la notification de nettoyage toujours câblé, sans demande.
    expect(notifications.requestedIOSPermission, [false]);
    expect(permissionCalls, isNot(contains('requestPermissions')));
  });

  testWidgets('iOS: later launches do not ask the notifications plugin for permission either', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await launch(tester);

    expect(notifications.requestedIOSPermission, [false]);
    expect(permissionCalls, isNot(contains('requestPermissions')));
    debugDefaultTargetPlatformOverride = null;
  });
}
