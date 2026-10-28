import 'package:flutter_test/flutter_test.dart';
import 'package:woa_toolbox/app_state.dart';
import 'package:woa_toolbox/main.dart';

void main() {
  testWidgets('アプリが起動してタイトルと検出ボタンを表示する', (tester) async {
    await tester.pumpWidget(WoaToolboxApp(state: AppState()));
    expect(find.text('WoA Toolbox'), findsOneWidget);
    expect(find.text('端末を検出'), findsOneWidget);
  });
}
