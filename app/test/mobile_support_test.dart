import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dropdrawer_app/models/models.dart';
import 'package:dropdrawer_app/services/drawer_window_service.dart';
import 'package:dropdrawer_app/state/drawer_controller.dart';
import 'package:dropdrawer_app/ui/drawer_screen.dart';
import 'package:dropdrawer_app/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeMobileWindowService extends DrawerWindowService {
  final bool ios;
  _FakeMobileWindowService({this.ios = true});

  @override
  bool get isWindows => false;

  @override
  bool get isIOS => ios;

  @override
  bool get isAndroid => !ios;

  @override
  bool get supportsEdgeDrawer => false;
}

class _MobileTestController extends DropDrawerController {
  final DrawerWindowService _mobileWindow;
  @override
  DrawerWindowService get windowService => _mobileWindow;

  final List<String> addedFiles = [];
  final List<String> addedTexts = [];

  _MobileTestController({bool ios = true})
      : _mobileWindow = _FakeMobileWindowService(ios: ios);

  @override
  Future<void> addFilesToDrawer(List<String> filePaths) async {
    addedFiles.addAll(filePaths);
  }

  @override
  Future<void> addTextToDrawer(String text) async {
    addedTexts.add(text);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Mobile thumbnail generation returns valid PNG without double-dispose', () async {
    final dir = await Directory.systemTemp.createTemp('dropdrawer-mobile-thumb-');
    try {
      final rec = ui.PictureRecorder();
      ui.Canvas(rec).drawColor(const ui.Color(0xff00aa88), ui.BlendMode.src);
      final pic = rec.endRecording();
      final img = await pic.toImage(6, 6);
      final png = await img.toByteData(format: ui.ImageByteFormat.png);
      img.dispose();
      pic.dispose();

      final file = File('${dir.path}/photo.png');
      await file.writeAsBytes(png!.buffer.asUint8List());

      final thumb = await _FakeMobileWindowService().generateThumbnailBase64(file.path);
      expect(thumb, isNotNull);
      expect(base64Decode(thumb!).take(4), [137, 80, 78, 71]);
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('Incoming mobile share payload queues while logged out and reports banner', () async {
    final ctrl = _MobileTestController();
    await ctrl.handleIncomingSharePayload(['/tmp/a.png'], ['hello mobile']);
    expect(ctrl.addedFiles, isEmpty);
    expect(ctrl.addedTexts, isEmpty);
    expect(ctrl.statusBanner, contains('登录后将自动同步'));
    ctrl.dispose();
  });

  test('Mobile consumePendingShares parses files and texts from method channel', () async {
    const channel = MethodChannel('com.dropdrawer/mobile');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'consumePendingShares') {
        return {
          'files': ['/tmp/shared.jpg'],
          'texts': ['https://example.com'],
        };
      }
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    final service = _FakeMobileWindowService(ios: false);
    final payload = await service.consumePendingShares();
    expect(payload['files'], ['/tmp/shared.jpg']);
    expect(payload['texts'], ['https://example.com']);
  });

  test('Android pickMediaNative uses native com.dropdrawer/mobile photo picker', () async {
    const channel = MethodChannel('com.dropdrawer/mobile');
    String? invokedMethod;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      invokedMethod = call.method;
      if (call.method == 'pickMedia') {
        return ['/tmp/photo_1.jpg', '/tmp/video_2.mp4'];
      }
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    final service = _FakeMobileWindowService(ios: false);
    final paths = await service.pickMediaNative();
    expect(invokedMethod, 'pickMedia');
    expect(paths, ['/tmp/photo_1.jpg', '/tmp/video_2.mp4']);
  });

  testWidgets('Mobile DrawerScreen renders touch quick actions and mobile empty copy', (tester) async {
    final ctrl = _MobileTestController();
    ctrl.user = UserProfile(id: 'u1', username: 'alice');
    ctrl.token = 'tok';

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true).copyWith(
          scaffoldBackgroundColor: const Color(0xFF141417),
          dividerColor: MacPalette.hairline,
        ),
        home: DrawerScreen(controller: ctrl),
      ),
    );
    await tester.pump();

    expect(find.text('选文件'), findsOneWidget);
    expect(find.text('选相册'), findsOneWidget);
    expect(find.text('粘贴'), findsOneWidget);
    expect(find.textContaining('分享 → DropDrawer'), findsOneWidget);
    ctrl.dispose();
  });
}
