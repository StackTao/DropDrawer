import 'dart:async';
import 'dart:io';

import 'package:dropdrawer_app/models/models.dart';
import 'package:dropdrawer_app/services/api_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('cancelling a cloud download preserves the existing destination', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final dir = await Directory.systemTemp.createTemp('dropdrawer-cancel-');
    final dest = File('${dir.path}/file.bin');
    final finish = Completer<void>();
    try {
      await dest.writeAsString('original');
      server.listen((request) async {
        request.response.bufferOutput = false;
        request.response.add(List<int>.filled(8192, 42));
        await request.response.flush();
        await finish.future;
        await request.response.close();
      });
      final url = 'http://127.0.0.1:${server.port}';
      final token = TransferCancelToken();
      final download = ApiClient(baseUrl: url).downloadFromCloud(
        cloud: CloudDownloadInfo(url: url, isDirectUrl: true, backendName: 'test'),
        destPath: dest.path,
        cancelToken: token,
        onProgress: (_, _) => token.cancel(),
      );
      await expectLater(download.timeout(const Duration(seconds: 5)), throwsA(isA<TransferCancelledException>()));
      expect(await dest.readAsString(), 'original');
      expect(await dir.list().length, 1);
    } finally {
      finish.complete();
      await server.close(force: true);
      await dir.delete(recursive: true);
    }
  });

  test('TransferCancelToken invokes every attached listener without overwriting', () {
    final token = TransferCancelToken();
    final events = <String>[];
    token.attach(() => events.add('ui_cleanup'));
    token.attach(() => events.add('transport_abort'));
    token.cancel();
    token.cancel(); // idempotent
    token.attach(() => events.add('late_listener'));

    expect(events, ['ui_cleanup', 'transport_abort', 'late_listener']);
  });
}
