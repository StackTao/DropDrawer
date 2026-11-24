import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:dropdrawer_app/services/drawer_window_service.dart';
import 'package:dropdrawer_app/models/models.dart';
import 'package:dropdrawer_app/services/p2p_ffi.dart';
import 'package:dropdrawer_app/state/drawer_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

class PlatformPaths extends PathProviderPlatform {
  PlatformPaths(this.dir);
  final String dir;
  @override
  Future<String?> getApplicationSupportPath() async => dir;
}

class LocalHttp extends HttpOverrides {}

class Bridge extends P2pFfiBridge {
  final events = <Map<String, dynamic>>[];
  int sequence = 0;
  @override
  bool loadLibrary() => true;
  @override
  LocalNodeInfo start({
    required String dataDir,
    String? customRelayUrl,
    bool disableRelay = false,
  }) => nodeInfo();
  @override
  LocalNodeInfo nodeInfo() => LocalNodeInfo(nodeId: 'local', directAddrs: []);
  @override
  List<Map<String, dynamic>> pollEvents() {
    final batch = [...events];
    events.clear();
    return batch;
  }

  @override
  String downloadFile({
    required String itemId,
    required String remoteNodeId,
    String? remoteRelayUrl,
    required List<String> remoteDirectAddrs,
    required String transferToken,
    required String destPath,
  }) => '${++sequence}';
  @override
  void cancelTransfer(String id) {}
  @override
  void shutdown() {}
}

class WindowsDrawer extends DrawerWindowService {
  @override
  bool get isWindows => true;
}

class Controller extends DropDrawerController {
  final _bridge = Bridge();
  @override
  Bridge get p2p => _bridge;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'clipboard cleanup preserves registered screenshots and unrelated files',
    () async {
      final root = await Directory.systemTemp.createTemp();
      try {
        PathProviderPlatform.instance = PlatformPaths(root.path);
        final dir = Directory('${root.path}/clipboard');
        await dir.create();
        for (final name in [
          'Screenshot-1.png',
          'Screenshot-2.png',
          'unrelated.png',
        ]) {
          final f = File('${dir.path}/$name');
          await f.writeAsString('fixture');
          await f.setLastModified(
            DateTime.now().subtract(const Duration(days: 2)),
          );
        }
        final retained = File('${dir.path}/Screenshot-1.png');
        await WindowsDrawer().pruneClipboardFiles([retained.path]);
        expect(await retained.exists(), true);
        expect(await File('${dir.path}/Screenshot-2.png').exists(), false);
        expect(await File('${dir.path}/unrelated.png').exists(), true);
      } finally {
        await root.delete(recursive: true);
      }
    },
  );

  test('Windows thumbnail returns valid PNG data', () async {
    final dir = await Directory.systemTemp.createTemp();
    try {
      final rec = ui.PictureRecorder();
      ui.Canvas(rec).drawColor(const ui.Color(0xffff0000), ui.BlendMode.src);
      final pic = rec.endRecording();
      final img = await pic.toImage(4, 4);
      final png = await img.toByteData(format: ui.ImageByteFormat.png);
      img.dispose();
      pic.dispose();
      final file = File('${dir.path}/sample.png');
      await file.writeAsBytes(png!.buffer.asUint8List());
      final thumbnail = await WindowsDrawer().generateThumbnailBase64(
        file.path,
      );
      expect(base64Decode(thumbnail!).take(4), [137, 80, 78, 71]);
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test(
    'a late cancel retains ownership until the native terminal event',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final dir = await Directory.systemTemp.createTemp(
          'dropdrawer-controller-',
        );
        final root = 'http://127.0.0.1:${server.port}';
        var plans = 0;
        WebSocket? socket;
        server.listen((r) async {
          final path = r.uri.path;
          if (path == '/ws') {
            socket = await WebSocketTransformer.upgrade(r);
            socket!.listen((_) {});
            return;
          }
          await r.drain<void>();
          dynamic body;
          if (path == '/api/devices') {
            body = {
              'id': 'rx',
              'user_id': 'u',
              'name': 'test',
              'platform': 'macos',
            };
          } else if (path.endsWith('download-plan')) {
            plans++;
            body = {
              'item_id': 'item',
              'p2p': {
                'device_id': 'src',
                'iroh_node_id': 'fake',
                'transfer_token': 'test',
              },
              'cloud': {
                'url': '/data',
                'is_direct_url': false,
                'backend_name': 'test',
              },
            };
          } else {
            body = [];
          }
          r.response.write(jsonEncode(body));
          await r.response.close();
        });
        final ctrl = Controller();
        try {
          PathProviderPlatform.instance = PlatformPaths(dir.path);
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(
                const MethodChannel('com.dropdrawer/drawer_window'),
                (_) async => null,
              );
          SharedPreferences.setMockInitialValues({
            'server_url': root,
            'auth_token': 'fake',
            'username': 'test',
            'user_id': 'u',
            'custom_download_dir': dir.path,
          });
          await ctrl.bootstrap();
          expect(ctrl.p2pReady, true);
          final item = DrawerItem.fromJson({
            'id': 'item',
            'user_id': 'u',
            'owner_device_id': 'src',
            'name': 'test.bin',
            'cloud_ready': true,
          });
          ctrl.items = [item];
          Future<void> until(bool Function() predicate) async {
            for (var i = 0; i < 100; i++) {
              if (predicate()) return;
              await Future<void>.delayed(const Duration(milliseconds: 30));
            }
            fail('missing expected state');
          }

          await ctrl.downloadItem(item);
          final dest = File('${dir.path}/test.bin');
          await dest.writeAsString('finished');
          ctrl.p2p.events.add({
            'item_id': 'item',
            'transfer_id': '1',
            'finished': true,
            'saved_path': dest.path,
          });
          // Native download has already saved the file, before the next 220 ms UI poll.
          ctrl.cancelTransfer(item.id);
          await ctrl.downloadItem(item);
          expect(plans, 1);
          await until(() => ctrl.p2p.events.isEmpty);
          expect(await dest.exists(), true);
          expect(ctrl.localFilePaths[item.id], dest.path);
          expect(ctrl.activeTransfers[item.id]?.finished, true);
        } finally {
          await ctrl.logout();
          await socket?.close();
          await server.close(force: true);
          await dir.delete(recursive: true);
        }
      }, LocalHttp());
    },
  );
}
