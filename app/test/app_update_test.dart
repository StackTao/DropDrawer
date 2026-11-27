import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dropdrawer_app/services/app_update_service.dart';
import 'package:dropdrawer_app/services/drawer_window_service.dart';
import 'package:dropdrawer_app/state/app_update_controller.dart';
import 'package:dropdrawer_app/ui/update_banner.dart';
import 'package:dropdrawer_app/ui/update_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, Object?> _asset(String name, String contents) => {
      'name': name,
      'size': utf8.encode(contents).length,
      'digest': 'sha256:${sha256.convert(utf8.encode(contents))}',
    };

Map<String, Object?> _release(
  String tag,
  List<Map<String, Object?>> assets, {
  bool draft = false,
}) =>
    {'tag_name': tag, 'draft': draft, 'assets': assets};

PackageInfo _package(String version) => PackageInfo(
      appName: 'DropDrawer',
      packageName: 'test.dropdrawer',
      version: version,
      buildNumber: '4',
      buildSignature: '',
    );

AppUpdate _update(String version) => AppUpdate(
      Version.parse(version),
      Uri.parse('https://github.com/StackTao/DropDrawer/releases/tag/v$version'),
      ReleaseAsset(
        'DropDrawer-macOS-arm64.dmg',
        Uri.parse('https://github.com/StackTao/DropDrawer/releases/download/v$version/x.dmg'),
        30 * 1048576,
        'a' * 64,
      ),
    );

class _FakeService extends AppUpdateService {
  _FakeService({this.result, this.checkError, this.downloadError});

  UpdateCheck? result;
  UpdateException? checkError;
  UpdateException? downloadError;
  int checks = 0;
  File? downloaded;

  @override
  Future<UpdateCheck> check(Version installed, UpdatePlatform platform) async {
    checks++;
    if (checkError != null) throw checkError!;
    return result!;
  }

  @override
  Future<void> clearDownloads() async {}

  @override
  Future<File> download(
    AppUpdate update, {
    required void Function(int received, int total) onProgress,
  }) async {
    if (downloadError != null) throw downloadError!;
    onProgress(update.package.size ~/ 2, update.package.size);
    onProgress(update.package.size, update.package.size);
    final dir = await Directory.systemTemp.createTemp('dropdrawer-update-test-');
    addTearDown(() => dir.delete(recursive: true));
    return downloaded = File('${dir.path}/${update.package.name}')..writeAsStringSync('dmg');
  }
}

class _FakeWindow extends DrawerWindowService {
  _FakeWindow({this.mobile = false});

  final bool mobile;
  UpdateInstallResult installResult = UpdateInstallResult.installing;
  final List<String> installed = [];
  final List<String> opened = [];

  @override
  bool get isMobile => mobile;
  @override
  bool get isIOS => false;
  @override
  bool get isAndroid => mobile;
  @override
  bool get isWindows => false;
  @override
  bool get supportsEdgeDrawer => !mobile;

  @override
  Future<UpdateInstallResult> installUpdate(String path) async {
    installed.add(path);
    return installResult;
  }

  @override
  Future<bool> openUpdatePackage(String path) async {
    opened.add(path);
    return true;
  }

  @override
  Future<bool> openExternalUrl(String url) async => true;
}

Future<AppUpdateController> _controller({
  required _FakeService service,
  _FakeWindow? window,
  String version = '0.1.0',
  String tag = 'v0.1.0-preview.1',
  UpdatePlatform platform = UpdatePlatform.macosArm64,
  Duration firstCheckDelay = const Duration(hours: 1),
}) async {
  final controller = AppUpdateController(
    window: window ?? _FakeWindow(),
    service: service,
    platform: platform,
    packageInfo: () async => _package(version),
    firstCheckDelay: firstCheckDelay,
  );
  // The build's tag comes from a compile-time define; set it the same way.
  controller.installed = InstalledBuild.fromPackage(_package(version), releaseTag: tag);
  return controller;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('AppUpdateService', () {
    test('picks the newest compatible package and skips drafts and downgrades', () async {
      final service = AppUpdateService(
        client: MockClient(
          (request) async => http.Response(
            jsonEncode([
              _release('v9.0.0', [_asset('DropDrawer-Android-universal.apk', 'x')], draft: true),
              _release('v0.20.0', [_asset('DropDrawer-Windows-x64-Setup.exe', 'x')]),
              _release('v0.10.0-preview.2', [_asset('DropDrawer-Android-arm64.apk', 'x')]),
              _release('v0.9.0', [_asset('DropDrawer-Android-universal.apk', 'x')]),
              _release('v1.0.0;rm', [_asset('DropDrawer-macOS-arm64.dmg', 'x')]),
            ]),
            200,
          ),
        ),
      );
      addTearDown(service.close);
      final from = Version.parse('0.9.0');
      expect((await service.check(from, UpdatePlatform.windowsX64)).update?.version.toString(), '0.20.0');
      expect(
        (await service.check(from, UpdatePlatform.androidArm64)).update?.version.toString(),
        '0.10.0-preview.2',
      );
      expect(await service.check(from, UpdatePlatform.androidArm), (update: null, hasNewerRelease: true));
      expect(
        await service.check(Version.parse('0.20.0'), UpdatePlatform.macosArm64),
        (update: null, hasNewerRelease: false),
      );
    });

    test('tells offline, rate limited and unavailable apart', () async {
      Future<UpdateFailure> failure(MockClient client) async {
        final service = AppUpdateService(client: client);
        addTearDown(service.close);
        try {
          await service.check(Version.parse('0.1.0'), UpdatePlatform.macosArm64);
        } on UpdateException catch (error) {
          return error.reason;
        }
        fail('expected an UpdateException');
      }

      expect(await failure(MockClient((_) async => throw const SocketException('down'))), UpdateFailure.offline);
      expect(
        await failure(MockClient((_) async => http.Response('', 403, headers: {'x-ratelimit-reset': '1900000000'}))),
        UpdateFailure.rateLimited,
      );
      expect(await failure(MockClient((_) async => http.Response('', 502))), UpdateFailure.unavailable);
      expect(await failure(MockClient((_) async => http.Response('not json', 200))), UpdateFailure.unavailable);
    });

    test('uses the mirror first and falls back when it is missing or corrupt', () async {
      final temp = await Directory.systemTemp.createTemp('dropdrawer-mirror-test-');
      addTearDown(() => temp.delete(recursive: true));
      const name = 'DropDrawer-macOS-arm64.dmg';
      const body = 'valid installer bytes';
      for (final mirrorResponse in [
        http.Response(body, 200),
        http.Response('', 404),
        http.Response('bad installer bytes!!', 200),
      ]) {
        final downloads = <Uri>[];
        final service = AppUpdateService(
          client: MockClient((request) async {
            if (request.url.host == 'api.github.com') {
              return http.Response(jsonEncode([_release('v0.2.0', [_asset(name, body)])]), 200);
            }
            downloads.add(request.url);
            return request.url.host == 'drop.stacktao.cn'
                ? mirrorResponse
                : http.Response(body, 200);
          }),
          tempDir: () async => temp,
        );
        addTearDown(service.close);
        final found = await service.check(Version.parse('0.1.0'), UpdatePlatform.macosArm64);
        final file = await service.download(found.update!, onProgress: (_, _) {});
        expect(await file.readAsString(), body);
        expect(downloads, [
          Uri.https('drop.stacktao.cn', '/api/updates/download/v0.2.0/$name'),
          if (mirrorResponse.body != body)
            Uri.https('github.com', '/StackTao/DropDrawer/releases/download/v0.2.0/$name'),
        ]);
      }
    });

    test('downloads only an intact package and keeps just the latest one', () async {
      final temp = await Directory.systemTemp.createTemp('dropdrawer-updates-root-');
      addTearDown(() => temp.delete(recursive: true));
      const body = 'installer bytes';
      Future<File> fetch(String served) {
        final service = AppUpdateService(
          client: MockClient((request) async => http.Response(served, 200)),
          tempDir: () async => temp,
        );
        addTearDown(service.close);
        final asset = _asset('DropDrawer-macOS-arm64.dmg', body);
        return service.download(
          AppUpdate(
            Version.parse('0.2.0'),
            Uri.parse('https://github.com/StackTao/DropDrawer/releases/tag/v0.2.0'),
            ReleaseAsset(
              'DropDrawer-macOS-arm64.dmg',
              Uri.https('github.com', '/StackTao/DropDrawer/releases/download/v0.2.0/DropDrawer-macOS-arm64.dmg'),
              asset['size']! as int,
              (asset['digest']! as String).substring('sha256:'.length),
            ),
          ),
          onProgress: (_, _) {},
        );
      }

      final first = await fetch(body);
      expect(first.readAsStringSync(), body);
      final second = await fetch(body);
      expect(first.existsSync(), isFalse, reason: 'old packages are cleared');
      expect(second.existsSync(), isTrue);
      await expectLater(
        fetch('tampered bytes!'),
        throwsA(isA<UpdateException>().having((e) => e.reason, 'reason', UpdateFailure.corrupted)),
      );
    });
  });

  test('only tagged builds of the same version take part in updates', () {
    final untagged = InstalledBuild.fromPackage(_package('0.1.0'), releaseTag: '');
    expect(untagged.isRelease, isFalse);
    expect(untagged.version.toString(), '0.1.0');
    final preview = InstalledBuild.fromPackage(_package('0.1.0'), releaseTag: 'v0.1.0-preview.2');
    expect(preview.isRelease, isTrue);
    expect(preview.version.toString(), '0.1.0-preview.2');
    final mismatched = InstalledBuild.fromPackage(_package('0.1.0'), releaseTag: 'v0.3.0');
    expect(mismatched.isRelease, isFalse);
  });

  group('AppUpdateController', () {
    test('development builds never check', () async {
      final service = _FakeService(result: (update: _update('0.2.0'), hasNewerRelease: true));
      final c = await _controller(service: service, tag: '');
      addTearDown(c.dispose);
      expect(c.canUpdate, isFalse);
      await c.check();
      expect(service.checks, 0);
      expect(c.showBanner, isFalse);
    });

    test('found update shows the banner; dismissing hides it for that version', () async {
      final service = _FakeService(result: (update: _update('0.2.0'), hasNewerRelease: true));
      final c = await _controller(service: service);
      addTearDown(c.dispose);
      await c.check(quiet: true);
      expect(c.phase, UpdatePhase.available);
      expect(c.showBanner, isTrue);
      await c.dismiss();
      expect(c.showBanner, isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('update_dismissed_version'), '0.2.0');

      service.result = (update: _update('0.3.0'), hasNewerRelease: true);
      await c.check(quiet: true);
      expect(c.showBanner, isTrue, reason: 'a newer version shows again');
    });

    test('one click downloads and hands the package to the platform', () async {
      final window = _FakeWindow();
      final service = _FakeService(result: (update: _update('0.2.0'), hasNewerRelease: true));
      final c = await _controller(service: service, window: window);
      addTearDown(c.dispose);
      final phases = <UpdatePhase>[];
      c.addListener(() => phases.add(c.phase));
      await c.check();
      await c.install();
      expect(window.installed, [service.downloaded!.path]);
      expect(c.phase, UpdatePhase.installing);
      expect(phases, containsAllInOrder([UpdatePhase.available, UpdatePhase.downloading, UpdatePhase.installing]));
    });

    test('a damaged download is reported and nothing is installed', () async {
      final window = _FakeWindow();
      final service = _FakeService(
        result: (update: _update('0.2.0'), hasNewerRelease: true),
        downloadError: const UpdateException(UpdateFailure.corrupted),
      );
      final c = await _controller(service: service, window: window);
      addTearDown(c.dispose);
      await c.check();
      await c.install();
      expect(c.phase, UpdatePhase.failed);
      expect(c.message, contains('重新下载'));
      expect(window.installed, isEmpty);
      expect(c.showBanner, isTrue, reason: 'the banner offers a retry');
    });

    test('an installer that never finishes lets the update be retried', () async {
      final service = _FakeService(result: (update: _update('0.2.0'), hasNewerRelease: true));
      final c = AppUpdateController(
        window: _FakeWindow(),
        service: service,
        platform: UpdatePlatform.windowsX64,
        packageInfo: () async => _package('0.1.0'),
        installTimeout: const Duration(milliseconds: 10),
      );
      addTearDown(c.dispose);
      c.installed = InstalledBuild.fromPackage(_package('0.1.0'), releaseTag: 'v0.1.0');
      await c.check();
      await c.install();
      expect(c.phase, UpdatePhase.installing);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(c.phase, UpdatePhase.failed);
      expect(c.showBanner, isTrue);
    });

    test('macOS signature mismatch falls back to a manual install', () async {
      final window = _FakeWindow()..installResult = UpdateInstallResult.signatureMismatch;
      final service = _FakeService(result: (update: _update('0.2.0'), hasNewerRelease: true));
      final c = await _controller(service: service, window: window);
      addTearDown(c.dispose);
      await c.check();
      await c.install();
      expect(c.phase, UpdatePhase.failed);
      expect(c.message, contains('签名'));
      expect(c.manualPackage, isNotNull);
      await c.openManualPackage();
      expect(window.opened, [c.manualPackage!.path]);
    });

    test('Android signature mismatch explains reinstalling', () async {
      final window = _FakeWindow(mobile: true)..installResult = UpdateInstallResult.signatureMismatch;
      final service = _FakeService(result: (update: _update('0.2.0'), hasNewerRelease: true));
      final c = await _controller(service: service, window: window, platform: UpdatePlatform.androidArm64);
      addTearDown(c.dispose);
      await c.check();
      await c.install();
      expect(c.message, contains('卸载'));
      expect(c.manualPackage, isNull);
    });

    test('automatic checks stay quiet on failure; manual checks explain it', () async {
      final service = _FakeService(checkError: const UpdateException(UpdateFailure.offline));
      final c = await _controller(service: service);
      addTearDown(c.dispose);
      await c.check(quiet: true);
      expect(c.phase, UpdatePhase.idle);
      expect(c.message, isNull);
      await c.check();
      expect(c.phase, UpdatePhase.failed);
      expect(c.message, contains('网络'));
    });

    test('start checks once after the delay and respects the auto-check switch', () async {
      final service = _FakeService(result: (update: null, hasNewerRelease: false));
      final c = AppUpdateController(
        window: _FakeWindow(),
        service: service,
        platform: UpdatePlatform.macosArm64,
        packageInfo: () async => _package('0.1.0'),
        firstCheckDelay: Duration.zero,
      );
      addTearDown(c.dispose);
      await c.start();
      // start() reads the version itself; give this build a release tag.
      c.installed = InstalledBuild.fromPackage(_package('0.1.0'), releaseTag: 'v0.1.0');
      await c.setAutoCheck(true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(service.checks, 1);
      expect(c.phase, UpdatePhase.upToDate);

      await c.setAutoCheck(false);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('update_auto_check'), isFalse);
    });

    test('failure messages say what to do', () {
      expect(AppUpdateController.describeFailure(const UpdateException(UpdateFailure.offline)), contains('网络'));
      expect(
        AppUpdateController.describeFailure(
          UpdateException(UpdateFailure.rateLimited, retryAfter: DateTime(2026, 1, 1, 9, 5)),
        ),
        contains('之后再试'),
      );
      expect(AppUpdateController.describeFailure(const UpdateException(UpdateFailure.corrupted)), contains('重新下载'));
    });
  });

  group('update UI', () {
    for (final mobile in [false, true]) {
      testWidgets('banner and settings fit and install with one tap (mobile=$mobile)', (tester) async {
        tester.view.physicalSize = Size(mobile ? 360 : 368, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final window = _FakeWindow(mobile: mobile);
        final service = _FakeService(result: (update: _update('0.2.0'), hasNewerRelease: true));
        final c = await _controller(
          service: service,
          window: window,
          platform: mobile ? UpdatePlatform.androidArm64 : UpdatePlatform.macosArm64,
        );
        await tester.runAsync(() => c.check(quiet: true));
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ListView(
                children: [
                  UpdateBanner(updates: c, mobile: mobile),
                  UpdateSettings(updates: c, mobile: mobile),
                ],
              ),
            ),
          ),
        );
        expect(tester.takeException(), isNull);
        expect(find.text('新版本 0.2.0 可用'), findsOneWidget);
        expect(find.textContaining(mobile ? '更新到 0.2.0（30.0 MB）' : '并重启'), findsOneWidget);

        await tester.tap(find.text('更新'));
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
        expect(window.installed, hasLength(1));
        expect(tester.takeException(), isNull);
        // Cancels the install watchdog before the test's pending-timer check.
        c.dispose();
      });
    }

    testWidgets('development builds say why they do not update', (tester) async {
      final c = await _controller(service: _FakeService(), tag: '');
      addTearDown(c.dispose);
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: UpdateSettings(updates: c, mobile: false))),
      );
      expect(find.textContaining('开发版本'), findsOneWidget);
      expect(find.text('检查更新'), findsNothing);
      expect(find.text('发布页'), findsOneWidget);
    });
  });
}
