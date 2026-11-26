import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dropdrawer_app/services/api_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final direct in [false, true]) {
    test(
      'upload waits for the ${direct ? 'direct upload confirmation' : 'storage response'}',
      () async {
        const deadline = Duration(seconds: 5);
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final dir = await Directory.systemTemp.createTemp('dropdrawer-upload-');
        final acknowledge = Completer<void>();
        final bodyReceived = Completer<int>();
        final waiting = Completer<void>();
        final baseUrl = 'http://127.0.0.1:${server.port}';
        var completed = false;
        final file = File('${dir.path}/sample.bin');
        const size = 256 * 1024;
        try {
          await file.writeAsBytes(List.filled(size, 42));
          server.listen((request) async {
            final response = request.response;
            final count = await request.fold<int>(
              0,
              (n, bytes) => n + bytes.length,
            );
            switch (request.uri.path) {
              case '/api/drawer/items/item/upload-plan':
                response.write(
                  jsonEncode({
                    'strategy': direct
                        ? 'direct_presigned_put'
                        : 'server_stream_put',
                    'url': direct
                        ? '$baseUrl/storage-upload'
                        : '/storage-upload',
                    'storage_backend_id': 'drive',
                    'remote_key': 'file',
                  }),
                );
              case '/storage-upload':
                bodyReceived.complete(count);
                if (!direct) {
                  await acknowledge.future;
                  response.write(_confirmedItem);
                }
              case '/api/drawer/items/item/confirm-upload':
                await acknowledge.future;
                response.write(_confirmedItem);
              default:
                response.statusCode = HttpStatus.notFound;
            }
            await response.close();
          });

          final result = ApiClient(baseUrl: baseUrl)
              .uploadItemFile(
                itemId: 'item',
                file: file,
                onProgress: (sent, total) => expect(sent, lessThan(total)),
                onAwaitingConfirmation: waiting.complete,
              )
              .then((item) {
                completed = true;
                return item;
              });
          final confirmed = expectLater(
            result.then((item) => item.cloudReady).timeout(deadline),
            completion(isTrue),
          );

          await waiting.future.timeout(deadline);
          expect(await bodyReceived.future.timeout(deadline), size);
          expect(completed, isFalse);
          acknowledge.complete();
          await confirmed;
        } finally {
          if (!acknowledge.isCompleted) acknowledge.complete();
          await server.close(force: true);
          await dir.delete(recursive: true);
        }
      },
    );
  }

  test(
    'upload sends content_sha256 and short-circuits on already_cached',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final dir = await Directory.systemTemp.createTemp('dropdrawer-dedup-');
      final baseUrl = 'http://127.0.0.1:${server.port}';
      final payload = utf8.encode('hello-dedup-world');
      final expectedHash = sha256.convert(payload).toString();
      final file = File('${dir.path}/sample.bin');
      Map<String, dynamic>? receivedPlanReq;
      var putCount = 0;

      try {
        await file.writeAsBytes(payload);
        server.listen((request) async {
          final body = await utf8.decoder.bind(request).join();
          final response = request.response;
          if (request.uri.path == '/api/drawer/items/item/upload-plan') {
            receivedPlanReq = jsonDecode(body) as Map<String, dynamic>;
            response.write(
              jsonEncode({
                'strategy': 'already_cached',
                'item': jsonDecode(_confirmedItem),
              }),
            );
          } else {
            putCount++;
            response.statusCode = HttpStatus.internalServerError;
          }
          await response.close();
        });

        final item = await ApiClient(baseUrl: baseUrl).uploadItemFile(
          itemId: 'item',
          file: file,
        );
        expect(item.cloudReady, isTrue);
        expect(item.id, 'item');
        expect(putCount, 0);
        expect(receivedPlanReq?['content_sha256'], expectedHash);
        expect(receivedPlanReq?['size'], payload.length);
      } finally {
        await server.close(force: true);
        await dir.delete(recursive: true);
      }
    },
  );
}

final _confirmedItem = jsonEncode({
  'id': 'item',
  'user_id': 'user',
  'owner_device_id': 'device',
  'name': 'sample.bin',
  'cloud_ready': true,
});
