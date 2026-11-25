import 'package:dropdrawer_app/services/drawer_window_service.dart';
import 'package:dropdrawer_app/state/drawer_controller.dart';
import 'package:dropdrawer_app/ui/drawer_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _DesktopWindow extends DrawerWindowService {
  @override
  bool get supportsEdgeDrawer => true;
}

class _DesktopController extends DropDrawerController {
  final _desktopWindow = _DesktopWindow();

  @override
  DrawerWindowService get windowService => _desktopWindow;
}

void main() {
  testWidgets('the expanded drawer grip dispatches drag phases', (
    tester,
  ) async {
    const channel = MethodChannel('com.dropdrawer/drawer_window');
    final phases = <String>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'dragExpandedDrawer') {
        phases.add(call.arguments as String);
      }
      return true;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final controller = _DesktopController();
    addTearDown(controller.dispose);
    final window = controller.windowService;
    window.edgeMode = true;
    await tester.pumpWidget(
      MaterialApp(home: DrawerScreen(controller: controller)),
    );

    final grip = find.byTooltip('拖动抽屉');
    expect(grip, findsOneWidget);
    expect(tester.getSize(grip), const Size(64, 14));
    final gripY = tester.getCenter(grip).dy;
    await tester.dragFrom(Offset(12, gripY), const Offset(0, 120));
    expect(phases, isEmpty);

    await tester.drag(grip, const Offset(85, 110));
    await tester.pump();
    expect(phases.first, 'start');
    expect(phases, contains('update'));
    expect(phases.last, 'end');

    phases.clear();
    final gesture = await tester.startGesture(tester.getCenter(grip));
    await gesture.moveBy(const Offset(48, 40));
    await gesture.cancel();
    await tester.pump();
    expect(phases.first, 'start');
    expect(phases.last, 'end');

    window.edgeMode = false;
    await tester.pumpWidget(
      MaterialApp(
        home: DrawerScreen(key: const ValueKey('regular'), controller: controller),
      ),
    );
    expect(grip, findsNothing);
  });
}
