import 'dart:convert';
import 'dart:ui' as ui;

import 'package:dropdrawer_app/l10n/l10n.dart';
import 'package:dropdrawer_app/models/models.dart';
import 'package:dropdrawer_app/services/drawer_window_service.dart';
import 'package:dropdrawer_app/state/drawer_controller.dart';
import 'package:dropdrawer_app/ui/drawer_screen.dart';
import 'package:dropdrawer_app/ui/phone_page.dart';
import 'package:dropdrawer_app/ui/preferences_view.dart';
import 'package:dropdrawer_app/ui/storage_settings_view.dart';
import 'package:dropdrawer_app/ui/theme.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';

class _FakeWindowService extends DrawerWindowService {
  final bool mobile;
  final bool windows;

  _FakeWindowService({this.mobile = false, this.windows = false});

  @override
  bool get isIOS => mobile;
  @override
  bool get isAndroid => false;
  @override
  bool get isWindows => windows;
  @override
  bool get supportsEdgeDrawer => windows;
}

class _TestController extends DropDrawerController {
  final DrawerWindowService _window;
  final List<String> deleted = [];
  final List<String> addedTexts = [];

  _TestController(this._window);

  @override
  DrawerWindowService get windowService => _window;

  @override
  Future<String> getEffectiveDownloadDir() async => '/tmp/DropDrawer';

  @override
  Future<void> refreshShareLinks() async {}

  @override
  Future<void> refreshStorageBackends() async {}

  @override
  Future<void> addTextToDrawer(String text) async {
    addedTexts.add(text);
  }

  @override
  Future<void> deleteItem(String itemId) async {
    deleted.add(itemId);
    items.removeWhere((e) => e.id == itemId);
    notifyListeners();
  }
}

class _FakeDropSession extends DropSession {
  @override
  final List<DropItem> items;
  @override
  final Set<DropOperation> allowedOperations;

  _FakeDropSession(
    this.items, {
    this.allowedOperations = const {DropOperation.copy},
  });

  @override
  Listenable get onDisposed => ChangeNotifier();
}

Future<String> _pngBase64() async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(const ui.Color(0xff3366ff), ui.BlendMode.src);
  final image = await recorder.endRecording().toImage(4, 4);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return base64Encode(data!.buffer.asUint8List());
}

DrawerItem _item(
  String id, {
  String kind = 'file',
  String? name,
  String? text,
  String? thumbnail,
  bool online = true,
  bool cloud = false,
}) {
  return DrawerItem(
    id: id,
    userId: 'u1',
    ownerDeviceId: 'other-device',
    ownerDeviceName: 'Studio MacBook Pro.local',
    ownerOnline: online,
    ownerDirectAddrs: const [],
    kind: kind,
    name: name ?? '$id-一个相当长的文件名称用于测试省略效果.pdf',
    size: 123456,
    textContent: text,
    thumbnailBase64: thumbnail,
    transferMode: cloud ? 'hybrid' : 'p2p_only',
    storageBackendName: cloud ? 'Server Local Disk' : null,
    cloudReady: cloud,
    createdAt: DateTime.now().subtract(const Duration(minutes: 5)),
  );
}

Future<_TestController> _pumpPhone(
  WidgetTester tester, {
  List<DrawerItem> items = const [],
  double textScale = 1.0,
  TargetPlatform platform = TargetPlatform.android,
}) async {
  tester.view.physicalSize = const Size(390 * 3, 844 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  final ctrl = _TestController(_FakeWindowService(mobile: true));
  ctrl.user = UserProfile(id: 'u1', username: 'alice');
  ctrl.token = 'tok';
  ctrl.items.addAll(items);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(
        mobile: true,
        android: platform == TargetPlatform.android,
      ).copyWith(platform: platform),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
        ),
        child: child!,
      ),
      home: AnimatedBuilder(
        animation: ctrl,
        builder: (_, _) => ctrl.isLoggedIn
            ? DrawerScreen(controller: ctrl)
            : const Text('signed out'),
      ),
    ),
  );
  await tester.pump();
  addTearDown(ctrl.dispose);
  return ctrl;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('phone layout', () {
    for (final (platform, scale) in [
      (TargetPlatform.android, 1.0),
      (TargetPlatform.android, 1.3),
      (TargetPlatform.iOS, 1.0),
      (TargetPlatform.iOS, 1.3),
    ]) {
      testWidgets('lays out without overflow on ${platform.name} at text scale $scale', (tester) async {
        final thumb = await tester.runAsync(_pngBase64);
        final ctrl = await _pumpPhone(
          tester,
          textScale: scale,
          platform: platform,
          items: [
            _item('img', name: 'Design preview.png', thumbnail: thumb, cloud: true),
            _item('note', kind: 'text', name: 'Meeting notes',
                text: '第一行会议纪要内容\n第二行：下周一前完成移动端适配与拖入动画优化'),
            _item('pdf', online: false),
          ],
        );
        expect(tester.takeException(), isNull);
        // Adding sits behind "+" (iOS) or the floating button (Android); the
        // desktop footer is gone.
        expect(find.byTooltip('添加'), findsOneWidget);
        expect(find.textContaining('iroh P2P'), findsNothing);
        // Meta leads with origin and time; text items preview their content.
        expect(find.textContaining('来自 Studio MacBook Pro'), findsWidgets);
        expect(find.textContaining('5 分钟前'), findsWidgets);
        expect(find.textContaining('第二行'), findsOneWidget);
        expect(find.textContaining('来源离线'), findsOneWidget);
        ctrl.pendingDrops.add(PendingDrop(id: 'p1', name: 'Big video.mov'));
        ctrl.notifyListeners();
        await tester.pump();
        expect(find.text('Big video.mov'), findsOneWidget);
        expect(find.text('正在加入抽屉…'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('long press starts selection with the pressed item', (tester) async {
      await _pumpPhone(tester, items: [_item('a', cloud: true), _item('b', cloud: true)]);
      await tester.longPress(find.text(_item('a').name));
      await tester.pump();
      // The large app bar becomes a selection bar.
      expect(find.text('已选 1 项'), findsWidgets);
      expect(find.text('删除(1)'), findsOneWidget);
    });

    testWidgets('swipe to remove can be undone, otherwise deletes', (tester) async {
      final ctrl = await _pumpPhone(
        tester,
        items: [_item('a', cloud: true), _item('b', cloud: true)],
      );
      // Exact match: the undo toast also mentions the item's name.
      final tileA = find.text(_item('a').name);

      await tester.drag(tileA, const Offset(-500, 0));
      await tester.pumpAndSettle();
      expect(tileA, findsNothing);
      expect(find.text('撤销'), findsOneWidget);
      await tester.tap(find.text('撤销'));
      await tester.pumpAndSettle();
      expect(tileA, findsOneWidget);
      expect(ctrl.deleted, isEmpty);

      await tester.drag(tileA, const Offset(-500, 0));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(ctrl.deleted, ['a']);
      expect(tileA, findsNothing);
    });

    testWidgets('each status message is shown once as a toast', (tester) async {
      final ctrl = await _pumpPhone(tester, items: [_item('a', cloud: true)]);
      ctrl.setBanner('已复制到剪贴板');
      await tester.pump();
      await tester.pump();
      expect(find.text('已复制到剪贴板'), findsOneWidget);
      // Let the entrance finish, then outlast the display duration.
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.text('已复制到剪贴板'), findsNothing);
      // The same text again is a new message and shows again.
      ctrl.setBanner('已复制到剪贴板');
      await tester.pump();
      await tester.pump();
      expect(find.text('已复制到剪贴板'), findsOneWidget);
    });

    testWidgets('thumbnails are decoded once and reused across rebuilds', (tester) async {
      final thumb = await tester.runAsync(_pngBase64);
      final ctrl = await _pumpPhone(
        tester,
        items: [_item('img', name: 'photo.png', thumbnail: thumb, cloud: true)],
      );
      ImageProvider provider() => tester
          .widgetList<Image>(find.byType(Image))
          .firstWhere((image) => image.image is MemoryImage)
          .image;
      final first = provider();
      ctrl.notifyListeners();
      await tester.pump();
      expect(identical(provider(), first), isTrue);
    });

    testWidgets('preferences page fits a phone and offers the drop policy', (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(390 * 3, 844 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final ctrl = _TestController(_FakeWindowService(mobile: true));
      addTearDown(ctrl.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: Scaffold(
            body: UiDensity(
              touch: true,
              child: MediaQuery(
                data: const MediaQueryData(
                  size: Size(390, 844),
                  textScaler: TextScaler.linear(1.15),
                ),
                // Pushed pages rebuild with the controller.
                child: ListenableBuilder(
                  listenable: ctrl,
                  builder: (_, _) => PreferencesView(controller: ctrl, onBack: () {}),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('新文件传输策略'), findsOneWidget);
      // Each choice opens its own list (a dialog on Android).
      await tester.tap(find.text('新文件传输策略'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('纯 P2P'));
      await tester.pumpAndSettle();
      expect(ctrl.defaultDropPolicy, 'p2p_only');
      expect(find.text('纯 P2P'), findsOneWidget); // the row's value
    });

    testWidgets('retention choices respect the administrator maximum', (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(390 * 3, 844 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final ctrl = _TestController(_FakeWindowService(mobile: true));
      addTearDown(ctrl.dispose);
      ctrl.clientConfig = const ClientConfig(features: ClientFeatures(maxItemTtlHours: 72));
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: Scaffold(
            body: UiDensity(
              touch: true,
              child: MediaQuery(
                data: const MediaQueryData(size: Size(390, 844)),
                child: ListenableBuilder(
                  listenable: ctrl,
                  builder: (_, _) => PreferencesView(controller: ctrl, onBack: () {}),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      // The stored default follows server policy, even when there is a cap.
      await tester.scrollUntilVisible(find.text('默认过期时间'), 200);
      expect(find.text('跟随服务器'), findsOneWidget);
      await tester.tap(find.text('默认过期时间'));
      await tester.pumpAndSettle();
      expect(find.text('永不过期'), findsNothing);
      expect(find.text('30 天'), findsNothing);
      expect(find.text('24 小时'), findsOneWidget);
      expect(find.text('3 天（上限）'), findsOneWidget);
    });
  });

  testWidgets('transfer progress updates without rebuilding the drawer', (tester) async {
    final ctrl = _TestController(_FakeWindowService(mobile: true));
    addTearDown(ctrl.dispose);
    ctrl.user = UserProfile(id: 'u1', username: 'alice');
    ctrl.token = 'tok';
    ctrl.items.add(_item('a', cloud: true));
    var drawerBuilds = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: AnimatedBuilder(
          animation: ctrl,
          builder: (_, _) {
            drawerBuilds++;
            return DrawerScreen(controller: ctrl);
          },
        ),
      ),
    );
    await tester.pump();
    final buildsBefore = drawerBuilds;

    TransferProgress progressAt(int done) => TransferProgress(
          itemId: 'a',
          transferred: done,
          total: 100,
          speedBps: 0,
          channel: 'cloud',
          finished: false,
        );
    ctrl.activeTransfers['a'] = progressAt(25);
    ctrl.transferTicks.value++;
    await tester.pump();
    expect(find.text('25%'), findsOneWidget);
    ctrl.activeTransfers['a'] = progressAt(60);
    ctrl.transferTicks.value++;
    await tester.pump();
    expect(find.text('60%'), findsOneWidget);
    expect(drawerBuilds, buildsBefore);
  });

  testWidgets('upload row waits for storage confirmation without showing 100%', (tester) async {
    final ctrl = await _pumpPhone(tester, items: [_item('upload')]);
    TransferProgress progress({required bool awaiting}) => TransferProgress(
      itemId: 'upload',
      transferred: awaiting ? 10000 : 9999,
      total: 10000,
      speedBps: awaiting ? 0 : 1024,
      channel: 'upload',
      finished: false,
      awaitingUploadConfirmation: awaiting,
    );

    ctrl.activeTransfers['upload'] = progress(awaiting: false);
    ctrl.transferTicks.value++;
    await tester.pump();
    expect(find.text('正在发送文件'), findsOneWidget);
    expect(find.text('99% · 1.0 KB/s'), findsOneWidget);

    ctrl.activeTransfers['upload'] = progress(awaiting: true);
    ctrl.transferTicks.value++;
    await tester.pump();
    expect(find.text('等待存储确认…'), findsOneWidget);
    expect(find.text('100%'), findsNothing);
    expect(find.textContaining('KB/s'), findsNothing);
    expect(find.text('取消上传'), findsOneWidget);
    expect(tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).value, isNull);
  });

  testWidgets('desktop edge drawer lays out without overflow', (tester) async {
    tester.view.physicalSize = const Size(410, 645);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final window = _FakeWindowService(windows: true)
      ..edgeMode = true
      ..drawerMode = 'expanded';
    final ctrl = _TestController(window);
    addTearDown(ctrl.dispose);
    ctrl.user = UserProfile(id: 'u1', username: 'alice');
    ctrl.token = 'tok';
    ctrl.items.addAll([
      _item('a', cloud: true),
      _item('t', kind: 'text', name: 'note', text: 'hello'),
    ]);
    ctrl.pendingDrops.add(PendingDrop(id: 'p', name: 'incoming.zip'));
    await tester.pumpWidget(MaterialApp(home: DrawerScreen(controller: ctrl)));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('incoming.zip'), findsOneWidget);
    // Desktop keeps its drop header and status footer.
    expect(find.textContaining('拖入、选取或'), findsOneWidget);
    expect(find.text('选文件'), findsNothing);
  });

  testWidgets('Windows guide pill shows its whole label even with larger text', (tester) async {
    tester.view.physicalSize = const Size(252, 48);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final window = _FakeWindowService(windows: true)
      ..edgeMode = true
      ..drawerMode = 'drag_pill';
    final ctrl = _TestController(window);
    addTearDown(ctrl.dispose);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.25)),
          child: child!,
        ),
        home: DrawerScreen(controller: ctrl),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    final label = tester.widget<Text>(find.text('拖到这儿，放入跨端抽屉'));
    expect(label.overflow, isNot(TextOverflow.ellipsis));
    final labelBox = tester.getRect(find.text('拖到这儿，放入跨端抽屉'));
    expect(labelBox.right, lessThanOrEqualTo(252));
  });

  testWidgets('native window is told when Flutter has drawn a new drawer mode', (tester) async {
    final binding = TestDefaultBinaryMessengerBinding.instance;
    const channel = MethodChannel('com.dropdrawer/drawer_window');
    final calls = <MethodCall>[];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });
    addTearDown(() => binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));

    final service = _FakeWindowService(windows: true);
    await binding.defaultBinaryMessenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(
        const MethodCall('onDrawerStateChanged', {'mode': 'drag_pill', 'edgeMode': true}),
      ),
      (_) {},
    );
    expect(service.drawerMode, 'drag_pill');
    await tester.pump();
    await tester.pump();
    expect(
      calls.where((c) => c.method == 'drawerFrameReady').map((c) => c.arguments),
      [
        {'mode': 'drag_pill'},
      ],
    );
  });

  group('light mode', () {
    tearDown(() => MacPalette.use(Brightness.dark));

    testWidgets('phone screen uses the light palette and fits', (tester) async {
      expect(MacPalette.use(Brightness.light), isTrue);
      expect(MacPalette.use(Brightness.light), isFalse);
      // iOS: white grouped rows on the grey grouped background.
      final ctrl = await _pumpPhone(
        tester,
        items: [_item('a', cloud: true)],
        platform: TargetPlatform.iOS,
      );
      expect(tester.takeException(), isNull);
      final surfaces = [
        ...tester
            .widgetList<AnimatedContainer>(find.byType(AnimatedContainer))
            .map((w) => (w.decoration as BoxDecoration?)?.color),
        ...tester
            .widgetList<DecoratedBox>(find.byType(DecoratedBox))
            .map((w) => w.decoration)
            .whereType<BoxDecoration>()
            .map((d) => d.color),
      ];
      expect(surfaces, contains(const Color(0xFFF2F2F7)));
      expect(surfaces, contains(const Color(0xFFFFFFFF)));
      expect(ctrl.items, hasLength(1));
    });

    testWidgets('Android uses Material 3 tonal colors and a search bar header', (tester) async {
      expect(MacPalette.use(Brightness.light, material: true), isTrue);
      final scheme = materialScheme(Brightness.light);
      expect(MacPalette.background, scheme.surface);
      expect(MacPalette.accent, scheme.primary);
      expect(MacPalette.onAccent, scheme.onPrimary);
      expect(buildAppTheme(mobile: true, android: true).colorScheme.surfaceContainer,
          scheme.surfaceContainer);

      await _pumpPhone(tester, items: [_item('a', cloud: true)]);
      expect(tester.takeException(), isNull);
      // The search bar heads the page and holds the overflow menu; no large title.
      expect(find.byType(SearchBar), findsOneWidget);
      expect(find.text('在 DropDrawer 中搜索'), findsOneWidget);
      expect(
        find.descendant(of: find.byType(SearchBar), matching: find.byTooltip('更多')),
        findsOneWidget,
      );
      expect(find.text('DropDrawer'), findsNothing);
      expect(find.widgetWithText(ActionChip, '正在连接…'), findsOneWidget);
      expect(find.text('1 项'), findsOneWidget);

      // Searching shows filter chips; the back arrow leaves search.
      await tester.tap(find.byType(SearchBar));
      await tester.pump();
      expect(find.widgetWithText(FilterChip, '文本'), findsOneWidget);
      await tester.tap(find.byTooltip('关闭搜索'));
      await tester.pump();
      expect(find.byType(FilterChip), findsNothing);
      expect(find.byTooltip('更多'), findsOneWidget);
    });

    test('theme switches brightness and keeps hairline dividers', () {
      MacPalette.use(Brightness.light);
      final light = buildAppTheme(mobile: true, android: false);
      expect(light.brightness, Brightness.light);
      expect(light.scaffoldBackgroundColor, const Color(0xFFF2F2F7));
      expect(light.colorScheme.outlineVariant, MacPalette.hairline);
      MacPalette.use(Brightness.dark);
      final dark = buildAppTheme(mobile: false, android: false);
      expect(dark.brightness, Brightness.dark);
      expect(dark.colorScheme.outlineVariant, MacPalette.hairline);
      expect(dark.splashFactory, NoSplash.splashFactory);
      expect(buildAppTheme(mobile: true, android: true).splashFactory,
          InkRipple.splashFactory);
    });
  });

  testWidgets('Android back leaves settings and selection before the app', (tester) async {
    await _pumpPhone(tester, items: [_item('a', cloud: true)]);
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('偏好设置'));
    await tester.pumpAndSettle();
    expect(find.text('新文件传输策略'), findsOneWidget);
    // A Material 3 top app bar with a back button.
    expect(find.widgetWithText(AppBar, '偏好设置'), findsOneWidget);
    expect(find.byType(BackButton), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('新文件传输策略'), findsNothing);
    expect(find.byTooltip('添加'), findsOneWidget);

    await tester.longPress(find.text(_item('a').name));
    await tester.pump();
    expect(find.text('已选 1 项'), findsWidgets);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.text('已选 1 项'), findsNothing);
  });

  group('phone navigation', () {
    testWidgets('iOS uses a large title and pushes pages with a back button', (tester) async {
      await _pumpPhone(
        tester,
        items: [_item('a', cloud: true)],
        platform: TargetPlatform.iOS,
      );
      expect(find.byType(CupertinoSliverNavigationBar), findsOneWidget);
      expect(find.textContaining('正在连接'), findsOneWidget);

      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('偏好设置'));
      await tester.pumpAndSettle();
      expect(find.byType(CupertinoNavigationBar), findsOneWidget);
      expect(find.text('新文件传输策略'), findsOneWidget);
      // Right-hand setting values must sit flush against the right edge, not
      // float in the middle of the row.
      final rowRect = tester.getRect(find.ancestor(
        of: find.text('新文件传输策略'),
        matching: find.byType(PhoneRow),
      ));
      final valRect = tester.getRect(find.text('智能'));
      expect(valRect.right, greaterThan(rowRect.left + rowRect.width * 0.72));
      // The back button is titled after the previous page.
      expect(find.widgetWithText(CupertinoNavigationBarBackButton, '返回'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.byType(CupertinoNavigationBarBackButton));
      await tester.pumpAndSettle();
      expect(find.text('新文件传输策略'), findsNothing);
      expect(find.byType(CupertinoSliverNavigationBar), findsOneWidget);
    });

    testWidgets('opening an item pushes its preview, which closes once removed', (tester) async {
      final ctrl = await _pumpPhone(
        tester,
        items: [_item('a', cloud: true)],
        platform: TargetPlatform.iOS,
      );
      await tester.tap(find.text(_item('a').name));
      await tester.pumpAndSettle();
      expect(find.text('文件详情'), findsOneWidget);

      ctrl.items.clear();
      ctrl.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('文件详情'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('signing out closes pushed pages', (tester) async {
      final ctrl = await _pumpPhone(tester, items: [_item('a', cloud: true)]);
      ctrl.wsConnected = true;
      ctrl.notifyListeners();
      await tester.pump();
      await tester.tap(find.textContaining('台设备在线'));
      await tester.pumpAndSettle();
      expect(find.text('设备与 P2P'), findsOneWidget);

      ctrl.user = null;
      ctrl.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('设备与 P2P'), findsNothing);
      expect(find.text('signed out'), findsOneWidget);
    });

    testWidgets('iOS adds from the + menu and keeps menus working once collapsed', (tester) async {
      await _pumpPhone(
        tester,
        items: [for (var i = 0; i < 12; i++) _item('i$i', cloud: true)],
        platform: TargetPlatform.iOS,
      );
      await tester.tap(find.byTooltip('添加'));
      await tester.pumpAndSettle();
      expect(find.text('选取文件'), findsOneWidget);
      expect(find.text('照片图库'), findsOneWidget);
      expect(find.text('粘贴'), findsOneWidget);
      // Pull-down menus render in a PopupRoute outside Scaffold; verify they
      // have an explicit no-underline text style rather than Flutter's yellow
      // debug fallback.
      final menuText = tester.widget<Text>(find.text('选取文件'));
      expect(menuText.style?.decoration, TextDecoration.none);
      expect(
        DefaultTextStyle.of(tester.element(find.text('选取文件'))).style.decoration,
        TextDecoration.none,
      );
      await tester.tapAt(const Offset(20, 600)); // outside: dismiss
      await tester.pumpAndSettle();
      expect(find.text('选取文件'), findsNothing);

      // Collapse the large title, then open the other menu.
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -400));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      expect(find.text('偏好设置'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('iOS swipe reveals 移出, which removes the item', (tester) async {
      final ctrl = await _pumpPhone(
        tester,
        items: [_item('a', cloud: true), _item('b', cloud: true)],
        platform: TargetPlatform.iOS,
      );
      await tester.drag(find.text(_item('a').name), const Offset(-120, 0));
      await tester.pumpAndSettle();
      expect(find.text('移出'), findsOneWidget);
      await tester.tap(find.text('移出'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 50)); // deletion timer
      expect(find.text(_item('a').name), findsNothing);
      expect(ctrl.deleted, ['a']);
      // No undo bar on iOS.
      expect(find.text('撤销'), findsNothing);
    });

    testWidgets('iOS long press shows the item menu', (tester) async {
      await _pumpPhone(
        tester,
        items: [_item('a', cloud: true)],
        platform: TargetPlatform.iOS,
      );
      final gesture =
          await tester.startGesture(tester.getCenter(find.text(_item('a').name)));
      await tester.pump(const Duration(milliseconds: 900));
      await tester.pumpAndSettle();
      expect(find.text('创建外链'), findsOneWidget);
      expect(find.text('移出'), findsOneWidget);
      await gesture.up();
      await tester.pumpAndSettle();
      await tester.tap(find.text('选择'));
      await tester.pumpAndSettle();
      // Selecting: the bar offers select-all and 完成.
      expect(find.text('已选 1 项'), findsWidgets);
      // The only item is selected, so the leading button deselects all.
      expect(find.text('取消全选'), findsOneWidget);
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      expect(find.text('已选 1 项'), findsNothing);
    });

    testWidgets('iOS shows status messages as a capsule, not a snack bar', (tester) async {
      final ctrl = await _pumpPhone(
        tester,
        items: [_item('a', cloud: true)],
        platform: TargetPlatform.iOS,
      );
      ctrl.setBanner('已复制到剪贴板');
      await tester.pump();
      await tester.pump();
      expect(find.text('已复制到剪贴板'), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.text('已复制到剪贴板'), findsNothing);
    });

    test('iOS dark uses a black background with raised rows', () {
      addTearDown(() => MacPalette.use(Brightness.dark));
      MacPalette.use(Brightness.dark, trueBlack: true);
      expect(MacPalette.background, const Color(0xFF000000));
      expect(MacPalette.group(0.22), MacPalette.cardBg);
      MacPalette.use(Brightness.dark);
      expect(MacPalette.background, const Color(0xFF141417));
    });

    testWidgets('iOS share links are rows that offer copy, open and revoke', (tester) async {
      final ctrl = await _pumpPhone(
        tester,
        items: [_item('a', cloud: true)],
        platform: TargetPlatform.iOS,
      );
      ctrl.shareLinks.add(ShareLinkInfo(
        code: 'abc',
        itemId: 'a',
        itemName: '季度报告',
        itemKind: 'file',
        itemSize: 1024,
        itemCount: 1,
        hasPasscode: true,
        downloadCount: 2,
        createdAt: DateTime.now(),
        sharePath: '/s/abc',
      ));
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('外链管理'));
      await tester.pumpAndSettle();
      expect(find.text('季度报告'), findsOneWidget);
      expect(find.textContaining('需提取码'), findsOneWidget);
      await tester.tap(find.text('季度报告'));
      await tester.pumpAndSettle();
      expect(find.byType(CupertinoActionSheet), findsOneWidget);
      expect(find.text('撤销外链'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Android storage page lists backends and adds by kind', (tester) async {
      final ctrl = await _pumpPhone(tester, items: [_item('a', cloud: true)]);
      ctrl.storageBackends.add(StorageBackendSummary(
        id: 'b1',
        name: '家里的 NAS',
        kind: 'web_dav',
        isDefault: true,
        displayTarget: 'https://nas.local/dav',
      ));
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('云盘与存储'));
      await tester.pumpAndSettle();
      expect(find.text('家里的 NAS'), findsOneWidget);
      expect(find.text('默认'), findsOneWidget);

      await tester.tap(find.text('添加云盘'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('类型'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('WebDAV'));
      await tester.pumpAndSettle();
      expect(find.text('地址'), findsOneWidget);
      expect(find.text('密码'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('iOS item page shows the file, its actions and details', (tester) async {
      await _pumpPhone(
        tester,
        items: [_item('a', name: 'Q4-Proposal.pdf', cloud: true)],
        platform: TargetPlatform.iOS,
      );
      await tester.tap(find.text('Q4-Proposal.pdf'));
      await tester.pumpAndSettle();
      expect(find.text('文件详情'), findsOneWidget);
      expect(find.text('从云端下载'), findsOneWidget);
      expect(find.text('信息'), findsOneWidget);
      expect(find.text('来源设备'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    test('phone type ramp maps desktop sizes onto the system scale', () {
      const ios = PhoneTypeScaler(TextScaler.noScaling, material: false);
      expect(ios.scale(10.5), 13);
      expect(ios.scale(12), 16);
      expect(ios.scale(13), 17);
      const android = PhoneTypeScaler(TextScaler.linear(2), material: true);
      expect(android.scale(10.5), 24);
      expect(android.scale(12), 30);
    });
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('switches follow the platform style on ${platform.name}', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: platform),
          home: Scaffold(
            body: UiDensity(
              touch: true,
              child: AdaptiveSwitch(value: true, onChanged: (_) {}),
            ),
          ),
        ),
      );
      expect(find.byType(Switch), platform == TargetPlatform.android ? findsOneWidget : findsNothing);
      expect(find.byType(CupertinoSwitch), platform == TargetPlatform.android ? findsNothing : findsOneWidget);
    });
  }

  testWidgets('Windows drawer is translucent only while the backdrop is applied', (tester) async {
    tester.view.physicalSize = const Size(410, 645);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final window = _FakeWindowService(windows: true)
      ..edgeMode = true
      ..drawerMode = 'expanded';
    final ctrl = _TestController(window);
    addTearDown(ctrl.dispose);
    ctrl.user = UserProfile(id: 'u1', username: 'alice');
    ctrl.token = 'tok';
    Future<Color?> surface() async {
      await tester.pumpWidget(MaterialApp(
        home: AnimatedBuilder(
          animation: ctrl,
          builder: (_, _) => DrawerScreen(controller: ctrl),
        ),
      ));
      await tester.pump();
      return (tester.widget<AnimatedContainer>(find.byType(AnimatedContainer).first).decoration
              as BoxDecoration)
          .color;
    }

    expect(await surface(), const Color(0xFF202020));
    window.windowsBackdrop = true;
    ctrl.notifyListeners();
    expect(await surface(), const Color(0x99202020));
  });

  testWidgets('backdrop state is read from the native window', (tester) async {
    final binding = TestDefaultBinaryMessengerBinding.instance;
    const channel = MethodChannel('com.dropdrawer/drawer_window');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async => true);
    addTearDown(() => binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
    final service = _FakeWindowService(windows: true);
    await binding.defaultBinaryMessenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(const MethodCall('onDrawerStateChanged', {
        'mode': 'expanded',
        'backdrop': true,
        'backdropEnabled': true,
      })),
      (_) {},
    );
    expect(service.windowsBackdrop, isTrue);
    expect(service.windowsBackdropEnabled, isTrue);
    await tester.pump();
  });

  testWidgets('desktop secondary pages accept drops, show glow overlay, and return home on drop', (tester) async {
    final binding = TestDefaultBinaryMessengerBinding.instance;
    const channel = MethodChannel('com.dropdrawer/drawer_window');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (_) async => true);
    addTearDown(() => binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));

    tester.view.physicalSize = const Size(420 * 2, 660 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    final window = _FakeWindowService(windows: true)..edgeMode = true;
    final ctrl = _TestController(window)
      ..user = UserProfile(id: 'u1', username: 'alice')
      ..token = 'tok';
    addTearDown(ctrl.dispose);

    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(mobile: false, android: false),
      home: AnimatedBuilder(
        animation: ctrl,
        builder: (_, _) => DrawerScreen(controller: ctrl),
      ),
    ));
    await tester.pump();

    // Navigate to a secondary page (Storage Settings).
    await tester.tap(find.byTooltip('多云盘与中转存储'));
    await tester.pump();
    expect(find.byType(StorageSettingsView), findsOneWidget);

    // DropRegion must remain active on secondary pages.
    final regionFinder = find.byType(DropRegion);
    expect(regionFinder, findsOneWidget);
    final region = tester.widget<DropRegion>(regionFinder);
    expect(region.formats, containsAll([Formats.fileUri, Formats.plainText]));

    final pos = DropPosition(local: const Offset(100, 100), global: const Offset(100, 100));
    final session = _FakeDropSession(const []);

    // Modal open blocks drag acceptance.
    await window.setModalOpen(true);
    expect(
      await region.onDropOver(DropOverEvent(session: session, position: pos)),
      DropOperation.none,
    );
    await window.setModalOpen(false);

    // Hovering over the secondary page activates the drop overlay + inner glow.
    expect(
      await region.onDropOver(DropOverEvent(session: session, position: pos)),
      DropOperation.copy,
    );
    await tester.pump();
    expect(find.text('松手放入跨端抽屉'), findsOneWidget);

    // Move-only drags (e.g. Windows browser/editor text drags) must negotiate
    // `move` instead of forcing `copy` (which Win32 OLE rejects as NONE).
    final moveOnlySession = _FakeDropSession(
      const [],
      allowedOperations: const {DropOperation.move},
    );
    expect(
      await region.onDropOver(
        DropOverEvent(session: moveOnlySession, position: pos),
      ),
      DropOperation.move,
    );

    // Brief single-frame Win32 OLE DragLeave -> DragEnter jitter must not
    // tear down the hover overlay before the debounce window expires.
    region.onDropLeave?.call(DropEvent(session: moveOnlySession));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('松手放入跨端抽屉'), findsOneWidget);
    expect(
      await region.onDropOver(
        DropOverEvent(session: moveOnlySession, position: pos),
      ),
      DropOperation.move,
    );
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.text('松手放入跨端抽屉'), findsOneWidget);

    // Leaving without dropping dismisses the overlay after the debounce window
    // and keeps the secondary page.
    region.onDropLeave?.call(DropEvent(session: session));
    await tester.pump(const Duration(milliseconds: 160));
    expect(find.text('松手放入跨端抽屉'), findsNothing);
    expect(find.byType(StorageSettingsView), findsOneWidget);

    // Performing a drop switches back to the home drawer immediately.
    await region.onPerformDrop(
      PerformDropEvent(
        session: session,
        position: pos,
        acceptedOperation: DropOperation.copy,
      ),
    );
    await tester.pump();
    expect(find.byType(StorageSettingsView), findsNothing);
    expect(find.textContaining('拖入、选取或'), findsOneWidget);
  });

  test('status messages bump the serial even when the text repeats', () {
    final ctrl = _TestController(_FakeWindowService());
    final start = ctrl.bannerSerial;
    ctrl.setBanner('done');
    ctrl.setBanner('done');
    ctrl.setBanner(null);
    expect(ctrl.bannerSerial, start + 2);
    ctrl.dispose();
  });

  test('relative time labels', () {
    final now = DateTime(2026, 11, 25, 15, 0);
    expect(relativeTimeLabel(now.subtract(const Duration(seconds: 20)), now: now), '刚刚');
    expect(relativeTimeLabel(now.subtract(const Duration(minutes: 7)), now: now), '7 分钟前');
    expect(relativeTimeLabel(now.subtract(const Duration(hours: 3)), now: now), '3 小时前');
    expect(relativeTimeLabel(DateTime(2026, 11, 24, 23, 0), now: now), '昨天');
    expect(relativeTimeLabel(DateTime(2026, 3, 2, 9, 0), now: now), '3月2日');
    expect(relativeTimeLabel(DateTime(2025, 3, 2, 9, 0), now: now), '2025年3月2日');
  });

  test('AuthPublicConfig parses registration mode, email rules and providers', () {
    final cfg = AuthPublicConfig.fromJson({
      'registration_mode': 'invite_only',
      'password_login_enabled': true,
      'email_verification_required': true,
      'email_password_reset_enabled': true,
      'providers': [
        {'id': 'google', 'name': 'Google', 'kind': 'oauth2_oidc', 'enabled': true},
      ],
    });
    expect(cfg.registrationAllowed, isTrue);
    expect(cfg.inviteCodeRequired, isTrue);
    expect(cfg.emailVerificationRequired, isTrue);
    expect(cfg.emailPasswordResetEnabled, isTrue);
    expect(cfg.googleEnabled, isTrue);

    final closed = AuthPublicConfig.fromJson({
      'registration_mode': 'closed',
      'password_login_enabled': false,
      'email_verification_required': false,
      'email_password_reset_enabled': false,
      'providers': const [],
    });
    expect(closed.registrationAllowed, isFalse);
    expect(closed.googleEnabled, isFalse);
  });

  group('English layout', () {
    setUp(() => AppLocale.apply(AppLanguage.english));
    tearDown(() => AppLocale.apply(AppLanguage.chinese));

    TransferProgress progress({required String channel, bool awaiting = false}) =>
        TransferProgress(
          itemId: 'x',
          transferred: 990,
          total: 1000,
          speedBps: 1024 * 1024,
          channel: channel,
          finished: false,
          awaitingUploadConfirmation: awaiting,
        );

    testWidgets('desktop edge drawer with transfers', (tester) async {
      tester.view.physicalSize = const Size(410, 645);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final window = _FakeWindowService(windows: true)
        ..edgeMode = true
        ..drawerMode = 'expanded';
      final ctrl = _TestController(window);
      addTearDown(ctrl.dispose);
      ctrl.user = UserProfile(id: 'u1', username: 'alice');
      ctrl.token = 'tok';
      ctrl.items.addAll([
        _item('a', cloud: true),
        _item('b', name: 'A rather long quarterly report name.pdf'),
        _item('t', kind: 'text', name: 'note', text: 'hello'),
      ]);
      ctrl.activeTransfers['a'] = progress(channel: 'p2p_relay');
      ctrl.activeTransfers['b'] = progress(channel: 'upload', awaiting: true);
      ctrl.pendingDrops.add(PendingDrop(id: 'p', name: 'incoming.zip'));
      await tester.pumpWidget(MaterialApp(home: DrawerScreen(controller: ctrl)));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.textContaining('Drop, choose or paste'), findsOneWidget);
      expect(find.text('Cancel upload'), findsOneWidget);
    });

    testWidgets('Windows guide pill fits with larger text', (tester) async {
      tester.view.physicalSize = const Size(252, 48);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final window = _FakeWindowService(windows: true)
        ..edgeMode = true
        ..drawerMode = 'drag_pill';
      final ctrl = _TestController(window);
      addTearDown(ctrl.dispose);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.25)),
            child: child!,
          ),
          home: DrawerScreen(controller: ctrl),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      final label = find.text(l10n.dragHereToDropIntoThe);
      expect(tester.getRect(label).right, lessThanOrEqualTo(252));
    });

    for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
      testWidgets('phone home on ${platform.name}', (tester) async {
        await _pumpPhone(
          tester,
          platform: platform,
          textScale: 1.3,
          items: [
            _item('a', cloud: true),
            _item('t', kind: 'text', name: 'note', text: 'hello'),
          ],
        );
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('desktop and phone preferences', (tester) async {
      SharedPreferences.setMockInitialValues({});
      for (final mobile in [false, true]) {
        tester.view.physicalSize = mobile ? const Size(390, 844) : const Size(410, 645);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final ctrl = _TestController(_FakeWindowService(mobile: mobile, windows: !mobile));
        addTearDown(ctrl.dispose);
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(mobile: mobile, android: false),
            home: Scaffold(
              body: PreferencesView(controller: ctrl, onBack: () {}),
            ),
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull, reason: 'mobile=$mobile');
        expect(find.text('Language'), findsWidgets);
      }
    });
  });
}
