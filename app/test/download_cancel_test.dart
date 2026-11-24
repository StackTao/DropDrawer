import 'dart:async';
import 'dart:io';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'package:dropdrawer_app/models/models.dart';
import 'package:dropdrawer_app/services/api_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'cancelling a cloud download preserves the existing destination',
    () async {
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
          cloud: CloudDownloadInfo(
            url: url,
            isDirectUrl: true,
            backendName: 'test',
          ),
          destPath: dest.path,
          cancelToken: token,
          onProgress: (_, _) => token.cancel(),
        );
        await expectLater(
          download.timeout(const Duration(seconds: 5)),
          throwsA(isA<TransferCancelledException>()),
        );
        expect(await dest.readAsString(), 'original');
        expect(await dir.list().length, 1);
      } finally {
        finish.complete();
        await server.close(force: true);
        await dir.delete(recursive: true);
      }
    },
  );

  test(
    'Windows preserves the destination when the staged file is locked',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final dir = await Directory.systemTemp.createTemp('dropdrawer-replace-');
      final dest = File('${dir.path}/original.bin');
      final finish = Completer<void>();
      final kernel = DynamicLibrary.open('kernel32.dll');
      final open = kernel
          .lookupFunction<
            IntPtr Function(
              Pointer<Utf16>,
              Uint32,
              Uint32,
              Pointer<Void>,
              Uint32,
              Uint32,
              IntPtr,
            ),
            int Function(Pointer<Utf16>, int, int, Pointer<Void>, int, int, int)
          >('CreateFileW');
      final close = kernel
          .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
            'CloseHandle',
          );
      var handle = -1;
      try {
        await dest.writeAsString('original');
        server.listen((request) async {
          request.response.bufferOutput = false;
          request.response.add(List<int>.filled(16384, 42));
          await request.response.flush();
          await finish.future;
          await request.response.close();
        });
        final url = 'http://127.0.0.1:${server.port}';
        final download = ApiClient(baseUrl: url).downloadFromCloud(
          cloud: CloudDownloadInfo(
            url: url,
            isDirectUrl: true,
            backendName: 'test',
          ),
          destPath: dest.path,
        );
        // Let the receive loop open and write its staging file before denying rename.
        for (var i = 0; i < 200 && handle == -1; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          for (final subdir in dir.listSync().whereType<Directory>()) {
            final file = File('${subdir.path}/download.part');
            if (!await file.exists() || await file.length() == 0) continue;
            final path = file.path.toNativeUtf16();
            try {
              // OPEN_EXISTING, sharing reads and writes but not deletes.
              handle = open(path, 0, 3, nullptr, 3, 0, 0);
            } finally {
              calloc.free(path);
            }
          }
        }
        final result = expectLater(
          download,
          throwsA(isA<FileSystemException>()),
        );
        finish.complete();
        expect(handle, isNot(-1));
        await result;
        expect(await dest.readAsString(), 'original');
      } finally {
        if (handle != -1) close(handle);
        if (!finish.isCompleted) finish.complete();
        await server.close(force: true);
        await dir.delete(recursive: true);
      }
    },
    skip: !Platform.isWindows,
  );

  test(
    'TransferCancelToken invokes every attached listener without overwriting',
    () {
      final token = TransferCancelToken();
      final events = <String>[];
      token.attach(() => events.add('ui_cleanup'));
      token.attach(() => events.add('transport_abort'));
      token.cancel();
      token.cancel(); // idempotent
      token.attach(() => events.add('late_listener'));

      expect(events, ['ui_cleanup', 'transport_abort', 'late_listener']);
    },
  );
}
