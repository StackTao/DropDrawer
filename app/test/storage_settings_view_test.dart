import 'package:dropdrawer_app/models/models.dart';
import 'package:dropdrawer_app/state/drawer_controller.dart';
import 'package:dropdrawer_app/ui/storage_settings_view.dart';
import 'package:dropdrawer_app/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _StorageController extends DropDrawerController {
  String? selectedBackend;
  String? editedBackend;
  Map<String, dynamic>? savedConfig;

  _StorageController() {
    storageBackends = [
      StorageBackendSummary(
        id: 'local',
        name: 'Server Local Disk',
        kind: 'local',
        isDefault: true,
        displayTarget: '/data',
      ),
      StorageBackendSummary(
        id: 'drive',
        name: 'Google Drive',
        kind: 'google_drive',
        isDefault: false,
        displayTarget: 'root',
      ),
    ];
  }

  @override
  Future<void> refreshStorageBackends() async {}

  @override
  Future<void> setDefaultStorageBackend(String id) async {
    selectedBackend = id;
    storageBackends = [
      for (final backend in storageBackends)
        StorageBackendSummary(
          id: backend.id,
          name: backend.name,
          kind: backend.kind,
          isDefault: backend.id == id,
          displayTarget: backend.displayTarget,
        ),
    ];
    notifyListeners();
  }

  @override
  Future<int?> getStorageCapacity(String id) async => 1024;

  @override
  Future<void> updateStorageBackend(
    String id, {
    required String name,
    required Map<String, dynamic> config,
  }) async {
    editedBackend = id;
    savedConfig = config;
    final index = storageBackends.indexWhere((backend) => backend.id == id);
    final previous = storageBackends[index];
    storageBackends[index] = StorageBackendSummary(
      id: id,
      name: name,
      kind: previous.kind,
      isDefault: previous.isDefault,
      displayTarget: previous.displayTarget,
    );
    notifyListeners();
  }
}

void main() {
  for (final platform in [
    TargetPlatform.macOS,
    TargetPlatform.android,
    TargetPlatform.iOS,
  ]) {
    testWidgets(
      'switches default and edits the local disk on ${platform.name}',
      (tester) async {
        final phone = platform != TargetPlatform.macOS;
        tester.view.physicalSize = Size(phone ? 360 : 340, 700);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final controller = _StorageController();
        addTearDown(controller.dispose);

        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(
              mobile: phone,
              android: platform == TargetPlatform.android,
            ).copyWith(platform: platform),
            home: UiDensity(
              touch: phone,
              child: Scaffold(
                body: ListenableBuilder(
                  listenable: controller,
                  builder: (_, _) =>
                      StorageSettingsView(controller: controller, onBack: () {}),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.text('设为默认'));
        await tester.pumpAndSettle();
        expect(controller.selectedBackend, 'drive');
        expect(find.text('默认'), findsOneWidget);

        if (phone) {
          await tester.tap(find.text('Server Local Disk'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('编辑'));
        } else {
          await tester.tap(find.byTooltip('编辑').first);
        }
        await tester.pumpAndSettle();
        expect(find.text('1024'), findsOneWidget);
        await tester.enterText(find.byType(TextField).first, '本地归档');
        await tester.enterText(find.byType(TextField).last, '');
        await tester.tap(find.text('保存修改'));
        await tester.pumpAndSettle();

        expect(controller.editedBackend, 'local');
        expect(controller.savedConfig, {'max_bytes': null});
        expect(find.text('本地归档'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final phone in [false, true]) {
    testWidgets('hides storage kinds the administrator disabled (phone=$phone)', (tester) async {
      tester.view.physicalSize = Size(phone ? 390 : 340, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = _StorageController();
      addTearDown(controller.dispose);
      controller.clientConfig = const ClientConfig(
        features: ClientFeatures(disabledStorageKinds: ['google_drive', 'web_dav', 's3']),
      );
      final platform = phone ? TargetPlatform.iOS : TargetPlatform.macOS;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(mobile: phone, android: false).copyWith(platform: platform),
          home: UiDensity(
            touch: phone,
            child: Scaffold(
              body: ListenableBuilder(
                listenable: controller,
                builder: (_, _) => StorageSettingsView(controller: controller, onBack: () {}),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text(phone ? '添加云盘' : '添加原生云盘'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      // The default selection (Google Drive) moves to the first allowed kind.
      expect(find.text('夸克网盘'), findsWidgets);
      if (phone) {
        await tester.tap(find.text('类型'));
        await tester.pumpAndSettle();
      }
      expect(find.text('WebDAV'), findsNothing);
      expect(find.text('S3 / R2'), findsNothing);
      expect(find.text('百度网盘'), findsWidgets);
    });
  }

  testWidgets('explains when every storage kind is disabled', (tester) async {
    tester.view.physicalSize = const Size(340, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = _StorageController();
    addTearDown(controller.dispose);
    controller.clientConfig = const ClientConfig(
      features: ClientFeatures(
        disabledStorageKinds: ['google_drive', 'quark', 'baidu_netdisk', 'web_dav', 's3', 'local'],
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListenableBuilder(
            listenable: controller,
            builder: (_, _) => StorageSettingsView(controller: controller, onBack: () {}),
          ),
        ),
      ),
    );
    await tester.tap(find.text('添加原生云盘'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已停用所有可添加的存储类型'), findsOneWidget);
  });
}
