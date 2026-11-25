import 'dart:io';

import 'package:dropdrawer_app/state/drawer_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('safeDownloadFileName', () {
    for (final windows in [false, true]) {
      final platform = windows ? 'Windows' : 'POSIX';

      test('$platform: server-provided names cannot leave the download folder', () {
        const downloads = '/home/user/Downloads';
        for (final name in [
          '/Users/victim/.zshrc',
          '../../.ssh/authorized_keys',
          r'..\..\AppData\evil.exe',
          'a/b/../../c.txt',
          '..',
          '.',
          '',
          '   ',
          '/',
        ]) {
          final safe = safeDownloadFileName(name, windows: windows);
          expect(safe, isNot(contains('/')), reason: name);
          expect(safe, isNot(contains(r'\')), reason: name);
          expect(safe, isNot(anyOf('.', '..', '')), reason: name);
          final dest = p.posix.normalize(p.posix.join(downloads, safe));
          expect(p.posix.dirname(dest), downloads, reason: name);
        }
      });

      test('$platform: ordinary names are kept', () {
        expect(safeDownloadFileName('报告 v2.pdf', windows: windows), '报告 v2.pdf');
        expect(safeDownloadFileName('.env.example', windows: windows), '.env.example');
        expect(safeDownloadFileName('dir/photo.png', windows: windows), 'photo.png');
      });
    }

    test('availableDownloadPath never replaces an unrelated file', () async {
      final dir = await Directory.systemTemp.createTemp('dropdrawer-names-');
      try {
        final first = p.join(dir.path, 'photo.png');
        expect(availableDownloadPath(dir.path, 'photo.png'), first);

        // An unfinished partial does not claim the name, so resume keeps it.
        File('$first.dropdrawer.part').writeAsStringSync('partial');
        expect(availableDownloadPath(dir.path, 'photo.png'), first);

        File(first).writeAsStringSync('someone else');
        final second = p.join(dir.path, 'photo (1).png');
        expect(availableDownloadPath(dir.path, 'photo.png'), second);
        // Re-downloading the same item may replace its own earlier copy.
        expect(
          availableDownloadPath(dir.path, 'photo.png', previousPath: first),
          first,
        );

        File(second).writeAsStringSync('another');
        expect(
          availableDownloadPath(dir.path, 'photo.png'),
          p.join(dir.path, 'photo (2).png'),
        );
        expect(
          availableDownloadPath(dir.path, 'photo.png', previousPath: second),
          second,
        );
        Directory(p.join(dir.path, 'notes')).createSync();
        expect(
          availableDownloadPath(dir.path, 'notes'),
          p.join(dir.path, 'notes (1)'),
        );
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('Windows: reserved device names and illegal characters are escaped', () {
      expect(safeDownloadFileName('CON.txt', windows: true), '_CON.txt');
      expect(safeDownloadFileName('a:b?.txt', windows: true), 'a_b_.txt');
      expect(safeDownloadFileName('trailing. ', windows: true), 'trailing');
    });
  });
}
