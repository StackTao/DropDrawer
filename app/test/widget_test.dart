import 'package:flutter_test/flutter_test.dart';

import 'package:dropdrawer_app/main.dart';

void main() {
  testWidgets('DropDrawer renders login screen on initial launch',
      (WidgetTester tester) async {
    await tester.pumpWidget(const DropDrawerApp());
    expect(find.text('DropDrawer'), findsOneWidget);
    expect(find.text('使用 Google 登录'), findsOneWidget);
  });
}
