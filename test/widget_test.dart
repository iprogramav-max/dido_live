import 'package:flutter_test/flutter_test.dart';

import 'package:dido_live/main.dart';

void main() {
  testWidgets('shows the Dido Live sign-in screen', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const MyApp());

    expect(find.text('Dido Live'), findsOneWidget);
    expect(find.text('Iniciar sesión'), findsOneWidget);
    expect(find.text('Entrar como invitado'), findsOneWidget);
  });
}
