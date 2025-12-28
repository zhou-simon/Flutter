import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_wifi/main.dart';

void main() {
  testWidgets('App can render initial screen', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());
    expect(find.text('蓝牙配网'), findsWidgets);
    expect(find.text('初始化'), findsOneWidget);
    expect(find.text('扫描'), findsOneWidget);
  });
}
