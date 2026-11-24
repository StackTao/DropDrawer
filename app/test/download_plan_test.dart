import 'package:dropdrawer_app/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final peer = P2pSourceInfo(
    deviceId: 'sender',
    irohNodeId: 'sender-node',
    directAddrs: const [],
    transferToken: 'token',
  );

  for (final direct in [true, false]) {
    final route = direct ? 'direct' : 'proxied';
    test('cloud-first uses the cached copy ($route)', () {
      final plan = DownloadPlan(
        itemId: 'file',
        p2p: peer,
        cloud: CloudDownloadInfo(
          url: direct ? 'https://example.test/file' : '/api/download',
          isDirectUrl: direct,
          backendName: 'Test cache',
        ),
      );

      expect(
        plan.selectPeer(
          requesterDeviceId: 'receiver',
          p2pReady: true,
          preferCloud: true,
        ),
        isNull,
      );
      expect(
        plan.selectPeer(
          requesterDeviceId: 'receiver',
          p2pReady: true,
          preferCloud: false,
        ),
        same(peer),
      );
    });
  }

  test('cloud-first still uses P2P when no cache is available', () {
    final plan = DownloadPlan(itemId: 'file', p2p: peer);

    expect(
      plan.selectPeer(
        requesterDeviceId: 'receiver',
        p2pReady: true,
        preferCloud: true,
      ),
      same(peer),
    );
    expect(
      plan.selectPeer(
        requesterDeviceId: 'sender',
        p2pReady: true,
        preferCloud: true,
      ),
      isNull,
    );
    expect(
      plan.selectPeer(
        requesterDeviceId: 'receiver',
        p2pReady: false,
        preferCloud: true,
      ),
      isNull,
    );
  });
}
