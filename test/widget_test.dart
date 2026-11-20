import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:dido_live/dido_retro.dart';
import 'package:dido_live/main.dart';

void main() {
  testWidgets('shows the Dido Live sign-in screen', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const MyApp());

    expect(find.text('Dido Live'), findsOneWidget);
    expect(find.text('Iniciar sesión'), findsOneWidget);
    expect(find.text('Entrar como invitado'), findsOneWidget);
    final guestButton = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Entrar como invitado'),
    );
    expect(guestButton.onPressed, isNotNull);
  });

  test(
    'authentication errors explain invalid credentials and confirmation',
    () {
      expect(
        accessErrorMessage(const AuthException('Invalid login credentials')),
        contains('Correo o contraseña incorrectos'),
      );
      expect(
        accessErrorMessage(
          const AuthException(
            'Email not confirmed',
            code: 'email_not_confirmed',
          ),
        ),
        contains('Confirma tu correo'),
      );
      expect(
        accessErrorMessage(
          const AuthException(
            'Anonymous sign-ins are disabled',
            code: 'anonymous_provider_disabled',
          ),
        ),
        contains('Anonymous Sign-Ins'),
      );
    },
  );

  test('network failures tell the user to check connectivity', () {
    expect(
      accessErrorMessage(Exception('SocketException: Connection refused')),
      contains('conexión a internet'),
    );
  });

  test('busy voice notifications are grouped within five minutes', () {
    final grouping = VoiceBusyGrouping(groupWindow: const Duration(minutes: 5));

    expect(grouping.shouldNotify(1000), isTrue);
    expect(grouping.shouldNotify(2000), isFalse);
    expect(grouping.shouldNotify(301001), isTrue);
  });

  test('remote PTT is blocked while local mode is active', () {
    expect(
      VoicePttPolicy.allowsRemotePtt(localWalkieMode: true, callFailed: false),
      isFalse,
    );
  });

  test('one Bluetooth address is enough to start L/R calibration', () {
    expect(
      LocalWalkieRouteGuard.canCalibrate({
        'ready': true,
        'inputs': const [
          {'id': 5},
        ],
        'outputs': const [
          {'id': 8, 'address': 'single-htc-ne79-pair'},
        ],
      }),
      isTrue,
    );
    expect(
      LocalWalkieRouteGuard.canCalibrate({
        'ready': true,
        'inputs': const [],
        'outputs': const [
          {'id': 8, 'address': 'single-htc-ne79-pair'},
        ],
      }),
      isFalse,
    );
  });

  test('single-side sending requires both isolated channel checks', () {
    expect(
      LocalWalkieRouteGuard.canSendToOneSide(
        leftOutputId: 8,
        rightOutputId: 8,
        calibratedOutputSides: {'8:L'},
        sharedOutputIds: const {},
      ),
      isFalse,
    );
    expect(
      LocalWalkieRouteGuard.canSendToOneSide(
        leftOutputId: 8,
        rightOutputId: 8,
        calibratedOutputSides: {'8:L', '8:R'},
        sharedOutputIds: const {},
      ),
      isTrue,
    );
    expect(
      LocalWalkieRouteGuard.canSendToOneSide(
        leftOutputId: 8,
        rightOutputId: 8,
        calibratedOutputSides: {'8:L', '8:R'},
        sharedOutputIds: {8},
      ),
      isFalse,
    );
  });

  test('failed listening tests remain pending until both sides pass', () {
    expect(
      calibrationProgressText({'L': 'No se oyó', 'R': 'Ambos'}),
      'Falta aprobar L y R',
    );
    expect(
      calibrationProgressText({'L': 'Solo izquierdo', 'R': 'No se oyó'}),
      'Falta aprobar R',
    );
    expect(
      calibrationProgressText({
        'L': 'Solo izquierdo',
        'R': 'Solo derecho',
      }),
      'L y R aprobadas; puedes repetir cualquiera',
    );
  });

  test('Dido Retro renders stable tokens and preserves unknown ones', () {
    expect(DidoRetro.emojis, hasLength(15));
    final message = DidoRetro.messageSpans(
      'Ya voy :dido_cambio:',
      style: const TextStyle(),
    );
    expect(
      message.whereType<TextSpan>().map((span) => span.text).join(),
      'Ya voy ',
    );
    expect(message.whereType<WidgetSpan>(), hasLength(1));

    final olderVersion = DidoRetro.messageSpans(
      'Ya voy :dido_legacy:',
      style: const TextStyle(),
    );
    expect(
      olderVersion.whereType<TextSpan>().map((span) => span.text).join(),
      'Ya voy :dido_legacy:',
    );
  });
}
