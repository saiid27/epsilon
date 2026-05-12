import 'package:epsilon/main.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('shows the auth screen', (tester) async {
    SharedPreferences.setMockInitialValues({'epsilon_onboarding_seen': true});

    await tester.pumpWidget(
      const EpsilonApp(firebaseStatus: FirebaseBootstrap(isReady: false)),
    );
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();

    expect(find.text('مرحبا بك مجددا'), findsOneWidget);
    expect(find.text('تسجيل الدخول'), findsOneWidget);
    expect(find.text('البريد الإلكتروني أو رقم هاتفك'), findsOneWidget);
    expect(find.text('Google'), findsNothing);
    expect(find.text('Facebook'), findsNothing);
    expect(find.text('Apple'), findsNothing);
    expect(find.text('إنشاء حساب'), findsOneWidget);
  });
}
