import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dropdrawer_app/services/app_update_service.dart';
import 'package:dropdrawer_app/services/drawer_window_service.dart';
import 'package:dropdrawer_app/ui/update_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:pub_semver/pub_semver.dart';

Map<String, Object?> _asset(String name, String contents) => {
  'name': name,
  'size': utf8.encode(contents).length,
  'digest': 'sha256:${sha256.convert(utf8.encode(contents))}',
};

Map<String, Object?> _release(
  String tag,
  List<Map<String, Object?>> assets, {
  bool draft = false,
}) => {'tag_name': tag, 'draft': draft, 'assets': assets};

class _TempPathProvider extends PathProviderPlatform {
  _TempPathProvider(this.path);
  final String path;

  @override
  Future<String?> getTemporaryPath() async => path;
}

class _TestWindowService extends DrawerWindowService {
  _TestWindowService({required this.mobile});

  final bool mobile;
  String? openedUrl;

  @override
  bool get isMobile => mobile;

  @override
  bool get supportsEdgeDrawer => !mobile;

  @override
  Future<bool> openExternalUrl(String url) async {
    openedUrl = url;
    return true;
  }
}

class _ReadyUpdateService extends AppUpdateService {
  _ReadyUpdateService(this.result);

  final UpdateCheck result;

  @override
  Future<UpdateCheck> check(
    Version installed,
    UpdatePlatform platform, {
    String? iosInstaller,
  }) async => result;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'platform selection skips drafts, downgrades and incompatible assets',
    () async {
      final service = AppUpdateService(
        client: MockClient(
          (request) async => http.Response(
            jsonEncode([
              _release('v9.0.0', [
                _asset('DropDrawer-Android-universal.apk', 'test'),
              ], draft: true),
              _release('v0.20.0', [
                _asset('DropDrawer-Windows-x64-Setup.exe', 'test'),
              ]),
              _release('v0.10.0-preview.2', [
                _asset('DropDrawer-Android-arm64.apk', 'test'),
              ]),
              _release('v0.9.0', [
                _asset('DropDrawer-Android-universal.apk', 'test'),
              ]),
            ]),
            200,
          ),
        ),
      );
      addTearDown(service.close);

      final from = Version.parse('0.9.0');
      final windows = await service.check(from, UpdatePlatform.windowsX64);
      expect(windows.update?.version.toString(), '0.20.0');
      final android64 = await service.check(from, UpdatePlatform.androidArm64);
      expect(android64.update?.version.toString(), '0.10.0-preview.2');
      final android32 = await service.check(from, UpdatePlatform.androidArm);
      expect(android32, (update: null, hasNewerRelease: true));
      final macLatest = await service.check(
        Version.parse('0.20.0'),
        UpdatePlatform.macosArm64,
      );
      expect(macLatest, (update: null, hasNewerRelease: false));
    },
  );

  test('release tag differentiates preview and final builds', () {
    final info = PackageInfo(
      appName: 'DropDrawer',
      packageName: 'test.dropdrawer',
      version: '0.10.0',
      buildNumber: '4',
      buildSignature: '',
    );
    expect(
      AppUpdateService.installedVersion(info, releaseTag: 'v0.10.0-preview.2'),
      Version.parse('0.10.0-preview.2'),
    );
    expect(
      AppUpdateService.installedVersion(info, releaseTag: 'v9.0.0'),
      Version.parse('0.10.0'),
    );
  });

  test('serves only the matching signed iOS update channel', () async {
    const metadata =
        '{"appStoreUrl":"https://apps.apple.com/app/id12345",'
        '"testFlightUrl":"https://testflight.apple.com/join/TestLink"}';
    final service = AppUpdateService(
      client: MockClient((request) async {
        if (request.url.host == 'api.github.com') {
          return http.Response(
            jsonEncode([
              _release('v0.2.0', [
                _asset('DropDrawer-iOS-update.json', metadata),
              ]),
            ]),
            200,
          );
        }
        return http.Response(metadata, 200);
      }),
    );
    addTearDown(service.close);

    final appStore = await service.check(
      Version.parse('0.1.0'),
      UpdatePlatform.ios,
      iosInstaller: 'com.apple',
    );
    expect(appStore.update?.storeUrl?.host, 'apps.apple.com');
    final testFlight = await service.check(
      Version.parse('0.1.0'),
      UpdatePlatform.ios,
      iosInstaller: 'com.apple.testflight',
    );
    expect(testFlight.update?.storeUrl?.host, 'testflight.apple.com');
  });

  test(
    'verifies installer downloads and removes failed partial packages',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'dropdrawer-update-test',
      );
      final previous = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _TempPathProvider(temp.path);
      addTearDown(() async {
        PathProviderPlatform.instance = previous;
        await temp.delete(recursive: true);
      });

      var content = 'authentic payload';
      final service = AppUpdateService(
        client: MockClient((request) async {
          if (request.url.host == 'api.github.com') {
            return http.Response(
              jsonEncode([
                _release('v0.2.0', [
                  _asset(
                    'DropDrawer-Windows-x64-Setup.exe',
                    'authentic payload',
                  ),
                ]),
              ]),
              200,
            );
          }
          if (request.url.host == 'github.com') {
            return http.Response(
              '',
              302,
              headers: {
                'location':
                    'https://release-assets.githubusercontent.com/test-install',
              },
            );
          }
          return http.Response(content, 200);
        }),
      );
      addTearDown(service.close);
      final result = await service.check(
        Version.parse('0.1.0'),
        UpdatePlatform.windowsX64,
      );
      final update = result.update!;
      final file = await service.download(
        update,
        onProgress: (received, total) {
          expect(received, lessThanOrEqualTo(total));
        },
      );
      expect(await file.readAsString(), 'authentic payload');

      content = 'modified! payload';
      await expectLater(
        service.download(update, onProgress: (_, _) {}),
        throwsFormatException,
      );
      expect(await file.parent.parent.list().length, 1);
    },
  );

  for (final mobile in [false, true]) {
    testWidgets('update settings fit at small width (mobile=$mobile)', (
      tester,
    ) async {
      PackageInfo.setMockInitialValues(
        appName: 'DropDrawer',
        packageName: 'test.dropdrawer',
        version: '0.1.0',
        buildNumber: '1',
        buildSignature: '',
      );
      final window = _TestWindowService(mobile: mobile);
      final updateService = AppUpdateService(
        client: MockClient((request) async {
          const metadata =
              '{"testFlightUrl":"https://testflight.apple.com/join/TestLink"}';
          if (request.url.host != 'api.github.com') {
            return http.Response(metadata, 200);
          }
          return http.Response(
            jsonEncode([
              _release('v0.2.0', [
                _asset('DropDrawer-Windows-x64-Setup.exe', 'content'),
                _asset('DropDrawer-iOS-update.json', metadata),
              ]),
            ]),
            200,
          );
        }),
      );
      addTearDown(updateService.close);
      final platform = mobile ? UpdatePlatform.ios : UpdatePlatform.windowsX64;
      final check = await tester.runAsync(
        () => updateService.check(Version.parse('0.1.0'), platform),
      );
      final readyService = _ReadyUpdateService(check!);
      addTearDown(readyService.close);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(1.6)),
              child: SizedBox(
                width: 270,
                child: UpdateSettings(
                  windowService: window,
                  platform: platform,
                  updateService: readyService,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('当前版本 0.1.0'), findsOneWidget);
      await tester.tap(find.text('检查更新'));
      await tester.pumpAndSettle();
      expect(find.text('发现版本 0.2.0'), findsOneWidget);
      expect(tester.takeException(), isNull);
      if (mobile) {
        await tester.tap(find.text('打开 TestFlight'));
        await tester.pumpAndSettle();
        expect(window.openedUrl, 'https://testflight.apple.com/join/TestLink');
      } else {
        expect(find.textContaining('下载更新'), findsOneWidget);
      }
    });
  }
}
