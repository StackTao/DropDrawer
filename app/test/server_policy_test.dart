import 'dart:io';

import 'package:dropdrawer_app/models/models.dart';
import 'package:dropdrawer_app/state/drawer_controller.dart';
import 'package:dropdrawer_app/ui/announcement_banner.dart';
import 'package:dropdrawer_app/ui/share_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('ClientConfig parses switches and falls back to permissive defaults', () {
    final cfg = ClientConfig.fromJson({
      'server_version': '0.1.6',
      'features': {
        'share_create_enabled': false,
        'cloud_upload_enabled': false,
        'share_requires_passcode': true,
        'max_share_expires_hours': 72,
      },
      'announcement': {
        'id': '1700000000000',
        'level': 'warning',
        'title': '维护通知',
        'message': '今晚 23:00 升级',
      },
      'min_client_version': '0.1.5',
    });
    expect(cfg.features.shareCreateEnabled, isFalse);
    expect(cfg.features.cloudUploadEnabled, isFalse);
    expect(cfg.features.shareRequiresPasscode, isTrue);
    expect(cfg.features.maxShareExpiresHours, 72);
    expect(cfg.announcement?.level, 'warning');
    expect(cfg.minClientVersion, '0.1.5');

    final sparse = ClientConfig.fromJson({'server_version': '0.1.0'});
    expect(sparse.features.shareCreateEnabled, isTrue);
    expect(sparse.features.cloudUploadEnabled, isTrue);
    expect(sparse.announcement, isNull);
  });

  test('controller exposes switches and remembers dismissed announcements', () async {
    SharedPreferences.setMockInitialValues({});
    final c = DropDrawerController();
    addTearDown(c.dispose);
    // Unknown server policy: nothing is hidden.
    expect(c.canCreateShares, isTrue);
    expect(c.canUploadToCloud, isTrue);
    expect(c.activeAnnouncement, isNull);

    c.clientConfig = const ClientConfig(
      features: ClientFeatures(shareCreateEnabled: false, cloudUploadEnabled: false),
      announcement: ClientAnnouncement(id: 'a1', title: '通知'),
    );
    expect(c.canCreateShares, isFalse);
    expect(c.canUploadToCloud, isFalse);
    expect(c.activeAnnouncement?.id, 'a1');

    await c.dismissAnnouncement();
    expect(c.activeAnnouncement, isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('dismissed_announcement'), 'a1');

    // Editing the announcement on the server produces a new id, so it shows again.
    c.clientConfig = const ClientConfig(
      announcement: ClientAnnouncement(id: 'a2', title: '新的通知'),
    );
    expect(c.activeAnnouncement?.id, 'a2');
  });

  for (final mobile in [false, true]) {
    testWidgets('announcement banner shows and closes (mobile=$mobile)', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final c = DropDrawerController();
      addTearDown(c.dispose);
      c.clientConfig = const ClientConfig(
        announcement: ClientAnnouncement(
          id: 'x',
          level: 'critical',
          title: '紧急维护',
          message: '服务器将在 10 分钟后重启',
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: mobile ? 390 : 320,
              child: ListenableBuilder(
                listenable: c,
                builder: (_, _) => AnnouncementBanner(controller: c, mobile: mobile),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('紧急维护'), findsOneWidget);
      expect(find.text('服务器将在 10 分钟后重启'), findsOneWidget);
      await tester.tap(find.byTooltip('关闭公告'));
      await tester.pump();
      expect(find.text('紧急维护'), findsNothing);
    });
  }

  test('describeError keeps only the server message', () {
    expect(
      describeError(const HttpException('HTTP 426: 客户端版本过低，请更新')),
      '客户端版本过低，请更新',
    );
    expect(describeError(StateError('服务器已关闭外链分享')), '服务器已关闭外链分享');
    expect(describeError(Exception('boom')), 'Exception: boom');
  });

  testWidgets('share options respect the administrator caps', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(380, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = _ShareController();
    addTearDown(c.dispose);
    c.clientConfig = const ClientConfig(
      features: ClientFeatures(
        shareRequiresPasscode: true,
        maxShareExpiresHours: 72,
        maxShareDownloads: 10,
      ),
    );
    final item = DrawerItem.fromJson({
      'id': 'i1',
      'user_id': 'u1',
      'owner_device_id': 'd1',
      'kind': 'text',
      'name': 'note',
      'text_content': 'hello',
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListenableBuilder(
            listenable: c,
            builder: (_, _) => ShareView(controller: c, targetItems: [item], onBack: () {}),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('永久'), findsNothing, reason: 'unlimited lifetime is not offered under a cap');
    expect(find.text('7 天'), findsNothing);
    expect(find.text('3 天（上限）'), findsOneWidget);
    expect(find.text('不限'), findsNothing);
    expect(find.text('10 次（上限）'), findsOneWidget);
    expect(find.text('20 次'), findsNothing);
    expect(find.text('提取码（必填）'), findsOneWidget);
  });
}

class _ShareController extends DropDrawerController {
  @override
  Future<void> refreshShareLinks() async {}
}
