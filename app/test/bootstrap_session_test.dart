import 'dart:convert';
import 'dart:io';

import 'package:dropdrawer_app/state/drawer_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.dropdrawer/drawer_window'),
          (_) async => null,
        );
  });

  test('constructor restores persisted session synchronously on frame 0', () async {
    SharedPreferences.setMockInitialValues({
      'server_url': 'https://drop.example.com',
      'auth_token': 'saved-jwt',
      'username': 'alice',
      'user_id': 'u-1',
      'device_id.u-1': 'dev-1',
    });
    final prefs = await SharedPreferences.getInstance();
    final controller = DropDrawerController(initialPrefs: prefs);
    // Already logged in before bootstrap() even runs -> zero login-screen flash.
    expect(controller.isLoggedIn, isTrue);
    expect(controller.user?.username, 'alice');
    expect(controller.deviceId, 'dev-1');
    controller.dispose();
  });

  test('bootstrap keeps session on transient offline error', () async {
    SharedPreferences.setMockInitialValues({
      'server_url': 'http://127.0.0.1:1',
      'auth_token': 'saved-jwt',
      'username': 'alice',
      'user_id': 'u-1',
      'device_id.u-1': 'dev-1',
    });

    final controller = DropDrawerController();
    var becameLoggedInDuringBootstrap = false;
    controller.addListener(() {
      if (controller.isLoggedIn && !controller.isBootstrapping) {
        becameLoggedInDuringBootstrap = true;
      }
    });

    await controller.bootstrap();
    expect(becameLoggedInDuringBootstrap, isTrue);
    expect(controller.isBootstrapping, isFalse);
    expect(controller.isLoggedIn, isTrue);
    expect(controller.user?.username, 'alice');
    controller.dispose();
  });

  test('bootstrap clears session and returns to login when server rejects token with 401', () async {
    final prevOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = prevOverrides);

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((req) async {
      req.response.statusCode = HttpStatus.unauthorized;
      req.response.write('invalid token');
      await req.response.close();
    });

    SharedPreferences.setMockInitialValues({
      'server_url': 'http://${server.address.address}:${server.port}',
      'auth_token': 'expired-jwt',
      'username': 'alice',
      'user_id': 'u-1',
    });

    final controller = DropDrawerController();
    await controller.bootstrap();
    expect(controller.isBootstrapping, isFalse);
    expect(controller.isLoggedIn, isFalse);
    expect(controller.statusBanner, contains('失效'));
    controller.dispose();
  });

  test('persisted pending cloud uploads are restored on relaunch and pruned when file is missing', () async {
    final tmpDir = await Directory.systemTemp.createTemp('dd-pending-test-');
    addTearDown(() => tmpDir.delete(recursive: true));
    final existingFile = File('${tmpDir.path}/video.mp4');
    await existingFile.writeAsString('payload');

    SharedPreferences.setMockInitialValues({
      'server_url': 'https://drop.example.com',
      'auth_token': 'saved-jwt',
      'username': 'alice',
      'user_id': 'u-1',
      'pending_cloud_uploads': jsonEncode({
        'item-live': {'path': existingFile.path, 'storage_backend_id': 'b1'},
        'item-missing': {'path': '${tmpDir.path}/deleted.mp4'},
      }),
    });

    final prefs = await SharedPreferences.getInstance();
    final controller = DropDrawerController(initialPrefs: prefs);
    expect(controller.pendingCloudUploadCount, 1);
    controller.dispose();
  });
}
