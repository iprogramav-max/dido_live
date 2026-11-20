import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'dido_retro.dart';
import 'super_admin_panel.dart';

const _supabaseUrl = 'https://bgmdndjcwkonqrzttvlb.supabase.co';
const _supabaseAnonKey =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImJnbWRuZGpjd2tvbnFyenR0dmxiIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTQ5Mzc5MzUsImV4cCI6MjExMDUxMzkzNX0.9Y8eFR45p3hZXrDaOzRd-tBrcn8TFQyF6yQIKywCjIs';
const _legacyGeneralConversationId = 'general';
const _freshGeneralConversationId = 'general-v2';
const _profilePhotosBucket = 'profile-photos';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(
    url: _supabaseUrl,
    publishableKey: _supabaseAnonKey,
  );
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Dido Live',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: _background,
        dividerColor: _line,
        colorScheme: const ColorScheme.dark(
          primary: _turquoise,
          onPrimary: _background,
          secondary: _blue,
          surface: _surface,
          onSurface: _ink,
        ),
        navigationBarTheme: NavigationBarThemeData(
          labelTextStyle: WidgetStateProperty.resolveWith(
            (states) => TextStyle(
              color: states.contains(WidgetState.selected) ? _turquoise : _ink,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: _surface,
          hintStyle: const TextStyle(color: _muted),
          prefixIconColor: _muted,
          suffixIconColor: _muted,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 15,
          ),
          border: _fieldBorder(_line),
          enabledBorder: _fieldBorder(_line),
          focusedBorder: _fieldBorder(_turquoise),
        ),
      ),
      home: const _AccessScreen(),
    );
  }
}

typedef MicrophonePermissionRequest = Future<PermissionStatus> Function();

Future<PermissionStatus> _requestMicrophonePermission() {
  return Permission.microphone.request();
}

String accessErrorMessage(Object error) {
  final detail = error.toString().toLowerCase();
  if (error is TimeoutException ||
      detail.contains('socketexception') ||
      detail.contains('clientexception') ||
      detail.contains('handshakeexception') ||
      detail.contains('authretryablefetchexception') ||
      detail.contains('failed host lookup') ||
      detail.contains('connection refused') ||
      detail.contains('network is unreachable') ||
      detail.contains('connection reset') ||
      detail.contains('timed out') ||
      detail.contains('timeout')) {
    return 'No se pudo conectar con Supabase. Revisa la conexión a internet del teléfono y vuelve a intentarlo.';
  }
  if (error is AuthException) {
    final message = error.message.toLowerCase();
    final code = error.code?.toLowerCase() ?? '';
    if (message.contains('invalid login credentials') ||
        message.contains('invalid_credentials') ||
        code == 'invalid_credentials') {
      return 'Correo o contraseña incorrectos, o la cuenta aún no existe. Créala primero con «Crear cuenta».';
    }
    if (message.contains('email not confirmed') ||
        message.contains('email_not_confirmed') ||
        code == 'email_not_confirmed') {
      return 'Confirma tu correo desde el enlace que te envió Supabase y vuelve a iniciar sesión.';
    }
    if (message.contains('anonymous sign-ins are disabled') ||
        message.contains('anonymous sign in is disabled') ||
        message.contains('anonymous_provider_disabled') ||
        code == 'anonymous_provider_disabled') {
      return 'El acceso de invitado está desactivado en Supabase. En Authentication > Sign In / Providers > Anonymous habilita Anonymous Sign-Ins.';
    }
    if (message.contains('user already registered') ||
        message.contains('already registered')) {
      return 'Ese correo ya tiene cuenta. Inicia sesión o usa otra dirección para registrar la segunda cuenta.';
    }
    return 'Supabase rechazó el acceso: ${error.message}';
  }
  return 'No se pudo completar el acceso. Revisa los datos e inténtalo de nuevo. Detalle: $error';
}

class VoiceBusyGrouping {
  VoiceBusyGrouping({this.groupWindow = const Duration(minutes: 5)});

  final Duration groupWindow;
  int _lastNotificationAt = 0;

  bool shouldNotify(int nowMilliseconds) {
    if (_lastNotificationAt != 0 &&
        nowMilliseconds - _lastNotificationAt < groupWindow.inMilliseconds) {
      return false;
    }
    _lastNotificationAt = nowMilliseconds;
    return true;
  }
}

class VoicePttPolicy {
  const VoicePttPolicy._();

  static bool allowsRemotePtt({
    required bool localWalkieMode,
    required bool callFailed,
  }) {
    return !localWalkieMode && !callFailed;
  }
}

String calibrationProgressText(Map<String, String> outcomes) {
  final missing = <String>[
    if (outcomes['L'] != 'Solo izquierdo') 'L',
    if (outcomes['R'] != 'Solo derecho') 'R',
  ];
  return missing.isEmpty
      ? 'L y R aprobadas; puedes repetir cualquiera'
      : 'Falta aprobar ${missing.join(' y ')}';
}

class LocalWalkieRouteGuard {
  const LocalWalkieRouteGuard._();

  static bool canCalibrate(Map<String, dynamic>? probe) {
    final inputs = probe?['inputs'];
    final outputs = probe?['outputs'];
    if (probe?['ready'] != true ||
        inputs is! List ||
        inputs.isEmpty ||
        outputs is! List) {
      return false;
    }
    return outputs.whereType<Map>().any((device) => device['id'] is int);
  }

  static bool canSendToOneSide({
    required int? leftOutputId,
    required int? rightOutputId,
    required Set<String> calibratedOutputSides,
    required Set<int> sharedOutputIds,
  }) {
    if (leftOutputId == null ||
        rightOutputId == null ||
        sharedOutputIds.contains(leftOutputId) ||
        sharedOutputIds.contains(rightOutputId)) {
      return false;
    }
    return calibratedOutputSides.contains('$leftOutputId:L') &&
        calibratedOutputSides.contains('$rightOutputId:R');
  }

  static String routeFunction(int? type, {required bool input}) {
    return switch (type) {
      7 => 'Manos libres / llamada',
      8 => 'Audio multimedia',
      26 => input ? 'Micrófono Bluetooth LE' : 'Auricular Bluetooth LE',
      27 => 'Salida Bluetooth LE',
      _ => input ? 'Entrada Bluetooth' : 'Salida Bluetooth',
    };
  }

  static String routeLabel(
    Map<String, dynamic> device, {
    required bool input,
    required int index,
    required int count,
  }) {
    final name = (device['name'] as String?)?.trim();
    final base = [
      routeFunction(device['type'] as int?, input: input),
      if (name != null && name.isNotEmpty) name,
    ].join(' · ');
    return count > 1 ? '$base · ruta ${index + 1}' : base;
  }
}

class WalkieTalkieScreen extends StatefulWidget {
  const WalkieTalkieScreen({
    super.key,
    this.requestMicrophonePermission = _requestMicrophonePermission,
    this.profileName = 'Ana Torres',
    this.isGuest = false,
  });

  final MicrophonePermissionRequest requestMicrophonePermission;
  final String profileName;
  final bool isGuest;

  @override
  State<WalkieTalkieScreen> createState() => _WalkieTalkieScreenState();
}

class _WalkieTalkieScreenState extends State<WalkieTalkieScreen>
    with WidgetsBindingObserver {
  late final SupabaseClient _supabase = Supabase.instance.client;
  static const _walkieChannel = MethodChannel('dido_live/walkie');
  static const _walkieEvents = EventChannel('dido_live/walkie_events');
  final List<RTCIceCandidate> _pendingLocalCandidates = [];
  final List<Map<String, dynamic>> _pendingRemoteCandidates = [];
  final Set<String> _seenRemoteCandidateIds = {};
  final Set<String> _pendingVoiceCleanupRoomIds = {};

  MediaStream? _localStream;
  MediaStreamTrack? _localAudioTrack;
  RTCPeerConnection? _peerConnection;
  RealtimeChannel? _channel;
  String? _role;
  String _status = 'Solicitando permiso de micrófono...';
  bool _isRequestingPermission = false;
  bool _isTransmitting = false;
  bool _roomIsPublished = false;
  bool _remoteDescriptionIsSet = false;
  bool _answerIsApplied = false;
  bool _isInitializing = false;
  bool _appInForeground = true;
  bool _callFailed = false;
  bool _isConnected = false;
  bool _freshGeneralAvailable = false;
  bool _chatEnhancementsAvailable = false;
  bool _isAppAdmin = false;
  bool _usageTrackingAvailable = true;
  Timer? _usageTimer;
  DateTime? _foregroundStartedAt;
  Future<void>? _connectionAttempt;
  String? _activeRoomId;
  String? _profilePhotoPath;
  RealtimeChannel? _chatChannel;
  RealtimeChannel? _directoryChannel;
  RealtimeChannel? _walkieIntentChannel;
  StreamSubscription<dynamic>? _walkieEventSubscription;
  bool _localWalkieMode = false;
  Map<String, dynamic>? _localWalkieProbe;
  String _localWalkieStatus = 'Comprobando rutas Bluetooth...';
  int? _leftOutputId;
  int? _rightOutputId;
  int? _selectedInputId;
  int? _activeBluetoothOutputId;
  int? _lastEffectiveBluetoothOutputId;
  final Set<String> _calibratedOutputSides = {};
  final Set<int> _sharedOutputIds = {};
  final Map<String, String> _calibrationOutcomes = {};
  String? _pendingCalibrationSide;
  int? _pendingCalibrationOutputId;
  String? _calibrationRouteFingerprint;
  String _localWalkieRouteDiagnostic = 'Aún no se ha probado ninguna ruta.';
  bool _calibrationBusy = false;
  bool _remoteBusyReply = false;
  final _busyGrouping = VoiceBusyGrouping();
  int _conversationSwitch = 0;
  final Set<String> _messageIds = {};
  int _tab = kIsWeb ? 1 : 0;
  late String _profileName = widget.profileName;
  bool _notifications = true;
  bool _pttSound = true;
  int? _pttPointer;
  Uint8List? _profilePhoto;
  final Map<String, Uint8List> _privatePhotoCache = {};
  final Map<String, Map<String, dynamic>> _profilesById = {};
  bool _pickingPhoto = false;
  final _conversations = <_Conversation>[_general];
  final _contacts = <_Contact>[];
  _Conversation _selected = _general;
  final _messages = <String, List<_Message>>{_general.id: <_Message>[]};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_initializeWalkieMode());
    unawaited(_initializeApp());
  }

  Future<void> _initializeApp() async {
    try {
      final freshGeneral = await _supabase
          .from('conversations')
          .select('id')
          .eq('id', _freshGeneralConversationId)
          .maybeSingle();
      _freshGeneralAvailable = freshGeneral != null;
      await _checkChatEnhancements();
      await _loadProfile();
      await _loadAppAdminAccess();
      _startForegroundUsageTracking();
      await _loadContacts();
      await _loadConversations();
      await _selectConversation(_selected, connectVoice: false);
      await _subscribeToDirectory();
      if (mounted && !kIsWeb) _startConnectionAttempt();
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _loadAppAdminAccess() async {
    final user = _supabase.auth.currentUser;
    if (user == null || user.isAnonymous) return;
    try {
      final result = await _supabase.rpc('is_app_admin');
      if (mounted) setState(() => _isAppAdmin = result == true);
    } on PostgrestException catch (error) {
      if (error.code == 'PGRST202' || error.code == '42883') return;
      rethrow;
    }
  }

  void _startForegroundUsageTracking() {
    final user = _supabase.auth.currentUser;
    if (user == null ||
        user.isAnonymous ||
        !_appInForeground ||
        !_usageTrackingAvailable) {
      return;
    }
    _foregroundStartedAt ??= DateTime.now();
    _usageTimer?.cancel();
    _usageTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => unawaited(_flushForegroundUsage()),
    );
  }

  Future<void> _flushForegroundUsage({bool force = false}) async {
    final startedAt = _foregroundStartedAt;
    if (startedAt == null || (!force && !_appInForeground)) return;
    final seconds = DateTime.now().difference(startedAt).inSeconds;
    _foregroundStartedAt = force ? null : DateTime.now();
    if (seconds < 1) return;
    try {
      await _supabase.rpc(
        'record_app_activity',
        params: {'p_foreground_seconds': seconds.clamp(1, 120)},
      );
    } on PostgrestException catch (error) {
      if (error.code == 'PGRST202' || error.code == '42883') {
        _usageTrackingAvailable = false;
        _usageTimer?.cancel();
        _usageTimer = null;
        return;
      }
      if (mounted) _photoNotice('No se pudo guardar el tiempo de uso: $error');
    } catch (error) {
      if (mounted) _photoNotice('No se pudo guardar el tiempo de uso: $error');
    }
  }

  String get _generalConversationId => _freshGeneralAvailable
      ? _freshGeneralConversationId
      : _legacyGeneralConversationId;

  Future<void> _checkChatEnhancements() async {
    try {
      await _supabase
          .from('chat_messages')
          .select('text_color,pinned_at')
          .limit(1);
      _chatEnhancementsAvailable = true;
    } on PostgrestException catch (error) {
      if (error.code == '42703' || error.code == 'PGRST204') {
        _chatEnhancementsAvailable = false;
        return;
      }
      rethrow;
    }
  }

  Future<void> _initializeWalkieMode() async {
    await _subscribeToWalkieIntents();
    if (kIsWeb) {
      if (mounted) {
        setState(() {
          _localWalkieProbe = null;
          _localWalkieStatus =
              'Walkie Talkie local está disponible solo en Android.';
        });
      }
      return;
    }
    _walkieEventSubscription = _walkieEvents.receiveBroadcastStream().listen((
      event,
    ) {
      if (!mounted || event is! Map) return;
      final data = Map<String, dynamic>.from(event);
      if (data['type'] == 'disconnected') {
        unawaited(
          _exitLocalWalkieMode(
            notice:
                data['message'] as String? ??
                'Se desconectó un auricular. El intercomunicador se detuvo.',
          ),
        );
      } else if (data['type'] == 'bluetooth_changed') {
        unawaited(_refreshLocalWalkieProbe());
      } else if (data['type'] == 'calibration_recording') {
        setState(() {
          _localWalkieStatus =
              'Di una frase. Se liberará el micrófono antes de reproducir por Bluetooth.';
          _localWalkieRouteDiagnostic =
              'Entrada efectiva: ${_formatBluetoothRoute(data['effectiveInput'])}\n'
              'Salida solicitada: ${_formatBluetoothRoute(data['requestedOutput'])}\n'
              'Transición: capturando PCM desde el micrófono Bluetooth.';
        });
      } else if (data['type'] == 'calibration_playback_done') {
        final side = data['side'] as String?;
        final outputId = data['outputId'] as int?;
        setState(() {
          _lastEffectiveBluetoothOutputId =
              (data['effectiveOutput'] as Map?)?['id'] as int? ?? outputId;
          _pendingCalibrationSide = side;
          _pendingCalibrationOutputId = outputId;
          _localWalkieStatus =
              'Prueba $side reproducida. Escucha ambos auriculares y elige el resultado.';
          _localWalkieRouteDiagnostic =
              'Entrada efectiva: ${_formatBluetoothRoute(data['effectiveInput'])}\n'
              'Salida solicitada: ${_formatBluetoothRoute(data['requestedOutput'])}\n'
              'Salida efectiva: ${_formatBluetoothRoute(data['effectiveOutput'])}';
        });
      } else if (data['type'] == 'calibration_finished') {
        setState(() => _calibrationBusy = false);
        _resumeVoiceAfterCalibration();
      } else if (data['type'] == 'recording') {
        setState(() {
          _localWalkieStatus =
              'Grabando para ${data['destination']}. Di «Cambio» para enviar o «Cancela mensaje» para descartar.';
        });
      } else if (data['type'] == 'command') {
        final destination = data['destination'] as String? ?? '';
        _localWalkieStatus = switch (data['command']) {
          'left_speaks' => 'Comando aceptado: Izquierdo habla → solo R.',
          'right_speaks' => 'Comando aceptado: Derecho habla → solo L.',
          'change' => 'Cambio aceptado. Reproduciendo el mensaje.',
          'cancel' => 'Mensaje cancelado. Escuchando comandos.',
          _ =>
            'Comando aceptado. ${destination.isEmpty ? '' : 'Destino: $destination.'}',
        };
        if (mounted) setState(() {});
      } else if (data['type'] == 'message_ready') {
        setState(() {
          _localWalkieStatus = data['timedOut'] == true
              ? 'Límite de 30 segundos alcanzado; reproduciendo la grabación.'
              : 'Grabación cerrada; reproduciendo audio PCM.';
          _localWalkieRouteDiagnostic =
              'Entrada efectiva: ${_formatBluetoothRoute(data['effectiveInput'])}\n'
              'Salida solicitada: ${_formatBluetoothRoute(data['requestedOutput'])}\n'
              'Transición: captura liberada antes de abrir AudioTrack.';
        });
      } else if (data['type'] == 'recording_cancelled') {
        setState(
          () => _localWalkieStatus = 'Mensaje descartado. Escuchando comandos.',
        );
      } else if (data['type'] == 'playback_done') {
        setState(() {
          _lastEffectiveBluetoothOutputId =
              (data['effectiveOutput'] as Map?)?['id'] as int? ??
              _lastEffectiveBluetoothOutputId;
          _localWalkieStatus = 'Mensaje enviado. Escuchando comandos.';
          _localWalkieRouteDiagnostic =
              'Entrada efectiva: ${_formatBluetoothRoute(data['effectiveInput'])}\n'
              'Salida solicitada: ${_formatBluetoothRoute(data['requestedOutput'])}\n'
              'Salida efectiva: ${_formatBluetoothRoute(data['effectiveOutput'])}';
        });
      } else if (data['type'] == 'listening') {
        setState(
          () => _localWalkieStatus = 'Escuchando comandos de voz en español.',
        );
      } else if (data['type'] == 'error') {
        setState(() {
          _localWalkieStatus =
              data['message'] as String? ?? 'Error del audio local.';
        });
        if (data['calibration'] == true) {
          _calibrationBusy = false;
          _localWalkieRouteDiagnostic =
              'Entrada efectiva: ${_formatBluetoothRoute(data['effectiveInput'])}\n'
              'Salida solicitada: ${_formatBluetoothRoute(data['requestedOutput'])}\n'
              'Salida real al fallar: ${_formatBluetoothRoute(data['actualOutput'])}';
        }
      } else if (data['type'] == 'route_failure') {
        final message =
            data['message'] as String? ??
            'Android no pudo confirmar la ruta Bluetooth. Walkie Talkie se detuvo.';
        if (_localWalkieMode && data['calibration'] != true) {
          unawaited(_exitLocalWalkieMode(notice: message));
        } else {
          setState(() {
            if (data['calibration'] != true) {
              _calibrationBusy = false;
              _pendingCalibrationSide = null;
            }
            _localWalkieStatus = message;
            _localWalkieRouteDiagnostic =
                'Entrada efectiva: ${_formatBluetoothRoute(data['effectiveInput'])}\n'
                'Salida solicitada: ${_formatBluetoothRoute(data['requestedOutput'])}\n'
                'Salida real al fallar: ${_formatBluetoothRoute(data['actualOutput'])}';
          });
          if (data['calibration'] != true) _resumeVoiceAfterCalibration();
        }
      }
    });
    await _refreshLocalWalkieProbe();
  }

  Future<void> _refreshLocalWalkieProbe() async {
    if (kIsWeb) {
      if (mounted) {
        setState(() {
          _localWalkieProbe = null;
          _localWalkieStatus =
              'Walkie Talkie local está disponible solo en Android.';
        });
      }
      return;
    }
    try {
      final result = await _walkieChannel.invokeMethod<Map<Object?, Object?>>(
        'probe',
      );
      if (!mounted || result == null) return;
      final probe = result.map((key, value) => MapEntry(key.toString(), value));
      final outputs = (probe['outputs'] as List? ?? const [])
          .whereType<Map>()
          .map((device) => Map<String, dynamic>.from(device))
          .toList();
      final outputIds = outputs
          .map((device) => device['id'])
          .whereType<int>()
          .toList();
      final inputs = (probe['inputs'] as List? ?? const [])
          .whereType<Map>()
          .map((device) => Map<String, dynamic>.from(device))
          .toList();
      final inputIds = inputs
          .map((device) => device['id'])
          .whereType<int>()
          .toList();
      final fingerprint = outputs
          .map((device) => '${device['id']}:${device['address']}')
          .join('|');
      setState(() {
        if (_calibrationRouteFingerprint != null &&
            _calibrationRouteFingerprint != fingerprint) {
          _calibratedOutputSides.clear();
          _sharedOutputIds.clear();
          _calibrationOutcomes.clear();
          _pendingCalibrationSide = null;
          _pendingCalibrationOutputId = null;
        }

        _calibrationRouteFingerprint = fingerprint;
        _localWalkieProbe = probe;
        _activeBluetoothOutputId = probe['activeOutputId'] as int?;
        _localWalkieStatus =
            probe['reason'] as String? ??
            'No se pudieron comprobar las rutas Bluetooth.';
        if (!outputIds.contains(_leftOutputId)) {
          _leftOutputId = outputIds.isNotEmpty ? outputIds.first : null;
        }
        if (!outputIds.contains(_rightOutputId) || _rightOutputId == null) {
          _rightOutputId = outputIds.isNotEmpty ? outputIds.first : null;
        }
        if (!inputIds.contains(_selectedInputId)) {
          _selectedInputId = inputIds.isNotEmpty ? inputIds.first : null;
        }
      });
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() {
        _localWalkieProbe = null;
        _localWalkieStatus =
            'No se pudo comprobar Walkie Talkie: ${error.message ?? error.code}';
      });
    }
  }

  String _formatBluetoothRoute(dynamic route) {
    if (route is! Map) return 'No informada por Android';
    final name = route['name']?.toString().trim();
    final function = route['function']?.toString().trim();
    final id = route['id']?.toString();
    return [
      if (name != null && name.isNotEmpty) name,
      if (function != null && function.isNotEmpty) function,
      if (id != null) 'ID $id',
    ].join(' · ');
  }

  Future<void> _prepareLocalWalkieRoutes() async {
    final permissions = await [
      Permission.bluetoothConnect,
      Permission.bluetoothScan,
    ].request();
    if (permissions.values.any((status) => !status.isGranted)) {
      if (mounted) {
        setState(
          () => _localWalkieStatus = 'Concede permisos Bluetooth para detectar el micrófono y la salida del casco.',
        );
      }
      return;
    }
    await _refreshLocalWalkieProbe();
  }

  Future<void> _subscribeToWalkieIntents() async {
    final channel = _supabase.channel('dido-voice-intents');
    _walkieIntentChannel = channel
      ..onBroadcast(
        event: 'voice_intent',
        callback: (payload) {
          if (payload['target'] != _selected.id &&
              payload['target'] != _generalConversationId &&
              payload['target'] != _userId) {
            return;
          }
          if (payload['sender'] == _userId) return;
          if (_localWalkieMode) {
            unawaited(
              channel.sendBroadcastMessage(
                event: 'voice_busy',
                payload: {
                  'target': payload['sender'],
                  'sender': _userId,
                  'conversation': payload['target'],
                },
              ),
            );
            final now = DateTime.now().millisecondsSinceEpoch;
            if (_busyGrouping.shouldNotify(now)) {
              if (!kIsWeb) {
                unawaited(
                  _walkieChannel.invokeMethod<void>('showBusyNotification', {
                    'sender': payload['senderName'] ?? 'Alguien',
                  }),
                );
              }
            }
          }
        },
      )
      ..onBroadcast(
        event: 'voice_busy',
        callback: (payload) {
          if (payload['target'] != _userId) return;
          if (!_remoteBusyReply) {
            _remoteBusyReply = true;
            if (mounted) {
              setState(
                () => _status = 'Ocupado en Walkie Talkie. Envíale un mensaje',
              );
            }
          }
        },
      )
      ..subscribe();
  }

  Future<void> _enterLocalWalkieMode() async {
    if (kIsWeb) {
      if (mounted) {
        setState(
          () => _localWalkieStatus =
              'Walkie Talkie local está disponible solo en Android.',
        );
      }
      return;
    }
    if (_localWalkieMode) {
      await _exitLocalWalkieMode();
      return;
    }
    final microphoneStatus = await widget.requestMicrophonePermission();
    if (!microphoneStatus.isGranted) {
      if (mounted) {
        setState(
          () => _localWalkieStatus = 'Se requiere permiso de micrófono para reconocer comandos y grabar.',
        );
      }
      return;
    }
    if (await Permission.notification.isDenied) {
      await Permission.notification.request();
    }
    final bluetoothPermissions = await [
      Permission.bluetoothConnect,
      Permission.bluetoothScan,
    ].request();
    if (bluetoothPermissions.values.any((status) => !status.isGranted)) {
      if (mounted) {
        setState(
          () => _localWalkieStatus = 'Concede los permisos Bluetooth para detectar y dirigir las rutas de audio.',
        );
      }
      return;
    }
    await _refreshLocalWalkieProbe();
    final ready = LocalWalkieRouteGuard.canCalibrate(_localWalkieProbe);
    if (!ready) {
      if (mounted) {
        setState(
          () => _localWalkieStatus =
              _localWalkieProbe?['reason'] as String? ??
              'Faltan rutas reales de los dos auriculares.',
        );
      }
      return;
    }
    if (!_canStartSingleSideWalkie) {
      if (mounted) {
        setState(
          () => _localWalkieStatus = _sharedOutputIds.isNotEmpty
              ? 'Salida compartida. No se puede habilitar el envío a un solo lado.'
              : 'Prueba y confirma «Escuchar solo L» y «Escuchar solo R» antes de activar.',
        );
      }
      return;
    }
    try {
      await _releaseRemoteVoiceForLocalAudio();
      _stopTransmission();
      final inputId = _selectedInputId;
      if (inputId == null) {
        throw StateError(
          'Android no detectó un micrófono Bluetooth seleccionado.',
        );
      }
      await _walkieChannel.invokeMethod<void>('start', {
        'leftOutputId': _leftOutputId,
        'rightOutputId': _rightOutputId,
        'inputId': inputId,
      });
      if (!mounted) return;
      setState(() {
        _localWalkieMode = true;
        _callFailed = false;
        _isConnected = false;
        _status = 'Walkie Talkie local activo. PTT remoto bloqueado.';
      });
    } on PlatformException catch (error) {
      if (mounted) {
        setState(
          () => _status = 'No se pudo activar: ${error.message ?? error.code}',
        );
      }
      _connectionAttempt = null;
      _startConnectionAttempt();
    } on Exception catch (error) {
      if (mounted) {
        setState(() => _status = 'No se pudo activar Walkie Talkie: $error');
      }
      _connectionAttempt = null;
      _startConnectionAttempt();
    }
  }

  Future<void> _exitLocalWalkieMode({String? notice}) async {
    if (_localWalkieMode && !kIsWeb) {
      try {
        await _walkieChannel.invokeMethod<void>('stop');
      } on PlatformException {
        // El cierre local puede continuar aunque el canal Android ya se haya detenido.
      }
    }
    if (!mounted) return;
    setState(() {
      _localWalkieMode = false;
      _status = notice ?? 'Walkie Talkie local cerrado.';
    });
    _connectionAttempt = null;
    _startConnectionAttempt();
  }

  Future<void> _testLocalOutput(String side) async {
    if (kIsWeb) return;
    final outputId = side == 'L' ? _leftOutputId : _rightOutputId;
    final inputId = _selectedInputId;
    if (outputId == null ||
        inputId == null ||
        _calibrationBusy ||
        _localWalkieMode) {
      return;
    }
    final microphoneStatus = await widget.requestMicrophonePermission();
    if (!microphoneStatus.isGranted) {
      if (mounted) {
        setState(
          () => _localWalkieStatus =
              'Concede permiso de micrófono para grabar la prueba.',
        );
      }
      return;
    }
    final bluetoothPermissions = await [
      Permission.bluetoothConnect,
      Permission.bluetoothScan,
    ].request();
    if (bluetoothPermissions.values.any((status) => !status.isGranted)) {
      if (mounted) {
        setState(
          () => _localWalkieStatus =
              'Concede permisos Bluetooth para calibrar la ruta.',
        );
      }
      return;
    }
    try {
      await _releaseRemoteVoiceForLocalAudio();
      _stopTransmission();
      if (mounted) {
        setState(() {
          _calibrationBusy = true;
          _pendingCalibrationSide = null;
          _pendingCalibrationOutputId = null;
        });
      }
      await _walkieChannel.invokeMethod<void>('calibrateSide', {
        'side': side,
        'outputId': outputId,
        'inputId': inputId,
      });
      if (mounted) {
        setState(() {
          _localWalkieStatus =
              'Grabando desde el micrófono Bluetooth; después se libera antes de reproducir por la misma salida.';
        });
      }
    } on PlatformException catch (error) {
      if (mounted) {
        setState(() {
          _calibrationBusy = false;
          _localWalkieStatus =
              'Falló la calibración $side: ${error.message ?? error.code}';
        });
      }
      _resumeVoiceAfterCalibration();
    } on Exception catch (error) {
      if (mounted) {
        setState(() {
          _calibrationBusy = false;
          _localWalkieStatus = 'Falló la calibración $side: $error';
        });
      }
      _resumeVoiceAfterCalibration();
    }
  }

  Future<void> _releaseRemoteVoiceForLocalAudio() async {
    final pendingConnection = _connectionAttempt;
    if (pendingConnection != null) await pendingConnection;
    await _endVoiceSession(updateStatus: false);
    final stream = _localStream;
    _localStream = null;
    _localAudioTrack = null;
    if (stream != null) await stream.dispose();
  }

  bool get _canStartSingleSideWalkie {
    return LocalWalkieRouteGuard.canCalibrate(_localWalkieProbe) &&
        LocalWalkieRouteGuard.canSendToOneSide(
          leftOutputId: _leftOutputId,
          rightOutputId: _rightOutputId,
          calibratedOutputSides: _calibratedOutputSides,
          sharedOutputIds: _sharedOutputIds,
        );
  }

  Future<void> _confirmCalibration({required String outcome}) async {
    if (kIsWeb) return;
    final side = _pendingCalibrationSide;
    final outputId = _pendingCalibrationOutputId;
    if (side == null || outputId == null) return;
    try {
      await _walkieChannel.invokeMethod<void>('setCalibrationResult', {
        'side': side,
        'outputId': outputId,
        'outcome': outcome,
      });
      if (!mounted) return;
      setState(() {
        _pendingCalibrationSide = null;
        _pendingCalibrationOutputId = null;
        if (outcome == 'isolated') {
          _calibratedOutputSides.add('$outputId:$side');
          _calibrationOutcomes[side] =
              side == 'L' ? 'Solo izquierdo' : 'Solo derecho';
          _localWalkieStatus =
              'Prueba $side confirmada: se oyó solo en ese auricular.';
        } else if (outcome == 'shared') {
          _sharedOutputIds.add(outputId);
          _calibratedOutputSides.remove('$outputId:L');
          _calibratedOutputSides.remove('$outputId:R');
          _calibrationOutcomes['L'] = 'Ambos';
          _calibrationOutcomes['R'] = 'Ambos';
          _localWalkieStatus = 'Salida compartida: el audio se oyó en ambos auriculares. El envío a un solo lado queda desactivado.';
        } else if (outcome == 'wrong_channel') {
          _calibratedOutputSides.remove('$outputId:$side');
          _calibrationOutcomes[side] =
              side == 'L' ? 'Solo derecho' : 'Solo izquierdo';
          _localWalkieStatus =
              'Canal incorrecto. Repite la prueba; el envío sigue desactivado.';
        } else {
          _calibratedOutputSides.remove('$outputId:$side');
          _calibrationOutcomes[side] = 'No se oyó';
          _localWalkieStatus = 'No se oyó la grabación completa. Revisa la ruta y vuelve a probar.';
        }
      });
    } on PlatformException catch (error) {
      if (mounted) {
        setState(
          () => _localWalkieStatus =
              'No se pudo guardar la calibración: ${error.message ?? error.code}',
        );
      }
    }
  }

  void _resumeVoiceAfterCalibration() {
    if (!mounted || _localWalkieMode) return;
    _connectionAttempt = null;
    _startConnectionAttempt();
  }

  void _clearCalibrationForOutputChange() {
    _calibratedOutputSides.clear();
    _sharedOutputIds.clear();
    _calibrationOutcomes.clear();
    _pendingCalibrationSide = null;
    _pendingCalibrationOutputId = null;
  }

  String get _userId {
    final id = _supabase.auth.currentUser?.id;
    if (id == null) throw StateError('Inicia sesión para continuar.');
    return id;
  }

  Future<void> _loadProfile() async {
    final user = _supabase.auth.currentUser;
    if (user == null) throw StateError('La sesión de Supabase no está activa.');

    final row = await _supabase
        .from('profiles')
        .select('display_name, avatar_url')
        .eq('id', user.id)
        .maybeSingle();
    final fallbackName = user.isAnonymous
        ? 'Invitado'
        : (user.email?.split('@').first ?? 'Usuario');

    if (row == null) {
      _profileName =
          user.userMetadata?['display_name'] as String? ?? fallbackName;
      await _supabase.from('profiles').insert({
        'id': user.id,
        'display_name': _profileName,
      });
    } else {
      _profileName = row['display_name'] as String? ?? fallbackName;
      _profilePhotoPath = row['avatar_url'] as String?;
      _profilePhoto = await _loadPrivatePhoto(_profilePhotoPath);
    }
  }

  Future<void> _loadContacts() async {
    final ownMemberships = await _supabase
        .from('conversation_members')
        .select('conversation_id')
        .eq('user_id', _userId);
    final conversationIds = <String>{
      _generalConversationId,
      for (final row in ownMemberships) row['conversation_id'] as String,
    };
    final members = await _supabase
        .from('conversation_members')
        .select('user_id')
        .inFilter('conversation_id', conversationIds.toList());
    final userIds = <String>{
      for (final row in members)
        if (row['user_id'] != _userId) row['user_id'] as String,
    };
    if (userIds.isEmpty) {
      _contacts.clear();
      return;
    }
    final rows = await _supabase
        .from('profiles')
        .select('id, display_name, avatar_url')
        .inFilter('id', userIds.toList())
        .order('display_name');
    final contacts = <_Contact>[];
    for (final row in rows) {
      final profile = Map<String, dynamic>.from(row);
      _profilesById[profile['id'] as String] = profile;
      contacts.add(
        _Contact(
          profile['id'] as String,
          profile['display_name'] as String? ?? 'Usuario',
          0,
          profile['avatar_url'] as String?,
          await _loadPrivatePhoto(profile['avatar_url'] as String?),
        ),
      );
    }
    _contacts
      ..clear()
      ..addAll(contacts);
  }

  Future<Uint8List?> _loadPrivatePhoto(String? path) async {
    if (path == null || path.isEmpty) return null;
    final cached = _privatePhotoCache[path];
    if (cached != null) return cached;

    final bytes = Uint8List.fromList(
      await _supabase.storage.from(_profilePhotosBucket).download(path),
    );
    _privatePhotoCache[path] = bytes;
    return bytes;
  }

  Future<void> _loadConversations() async {
    final memberships = await _supabase
        .from('conversation_members')
        .select('conversation_id')
        .eq('user_id', _userId);
    final ids = <String>{
      _generalConversationId,
      for (final row in memberships) row['conversation_id'] as String,
    };
    final rows = await _supabase
        .from('conversations')
        .select('id, name, kind')
        .inFilter('id', ids.toList());
    final memberRows = await _supabase
        .from('conversation_members')
        .select('conversation_id, user_id')
        .inFilter('conversation_id', ids.toList());
    final memberIds = <String>{
      for (final row in memberRows) row['user_id'] as String,
    };
    final profiles = memberIds.isEmpty
        ? <Map<String, dynamic>>[]
        : (await _supabase
                  .from('profiles')
                  .select('id, display_name, avatar_url')
                  .inFilter('id', memberIds.toList()))
              .map((row) => Map<String, dynamic>.from(row))
              .toList();
    final profilesById = {
      for (final profile in profiles) profile['id'] as String: profile,
    };
    _profilesById.addAll(profilesById);
    final membersByConversation = <String, List<_Contact>>{};
    for (final row in memberRows) {
      if (row['user_id'] == _userId) continue;
      final profile = profilesById[row['user_id']];
      if (profile == null) continue;
      final conversationId = row['conversation_id'] as String;
      final avatarPath = profile['avatar_url'] as String?;
      membersByConversation
          .putIfAbsent(conversationId, () => [])
          .add(
            _Contact(
              profile['id'] as String,
              profile['display_name'] as String? ?? 'Usuario',
              0,
              avatarPath,
              await _loadPrivatePhoto(avatarPath),
            ),
          );
    }
    for (final members in membersByConversation.values) {
      for (final member in members) {
        final index = _contacts.indexWhere(
          (contact) => contact.id == member.id,
        );
        if (index >= 0) _contacts[index] = member;
      }
    }

    final loaded = rows.map((row) {
      final kind = switch (row['kind']) {
        'general' => _Scope.general,
        'group' => _Scope.group,
        'personal' => _Scope.personal,
        _ => throw FormatException('Tipo de conversación no reconocido.'),
      };
      final id = row['id'] as String;
      final members = membersByConversation[id] ?? const <_Contact>[];
      final name = kind == _Scope.personal && members.isNotEmpty
          ? members.first.name
          : row['name'] as String;
      return _Conversation(id, name, kind, members);
    }).toList();
    loaded.sort((a, b) {
      if (a.id == _generalConversationId) return -1;
      if (b.id == _generalConversationId) return 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });

    _selected = loaded.firstWhere(
      (conversation) => conversation.id == _selected.id,
      orElse: () => loaded.firstWhere(
        (conversation) => conversation.id == _generalConversationId,
      ),
    );
    _conversations
      ..clear()
      ..addAll(loaded);
    if (mounted) setState(() {});
  }

  Future<void> _subscribeToDirectory() async {
    final ready = Completer<void>();
    final channel = _supabase.channel('directory-$_userId');
    _directoryChannel = channel
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'conversation_members',
        callback: (_) {
          unawaited(_runSafely(_loadConversations));
        },
      )
      ..subscribe((status, error) {
        if (status == RealtimeSubscribeStatus.subscribed &&
            !ready.isCompleted) {
          ready.complete();
        } else if ((status == RealtimeSubscribeStatus.channelError ||
                status == RealtimeSubscribeStatus.timedOut) &&
            !ready.isCompleted) {
          ready.completeError(
            error ?? StateError('No se pudo sincronizar el directorio.'),
          );
        }
      });
    await ready.future.timeout(const Duration(seconds: 20));
  }

  Future<void> _subscribeToChat(_Conversation conversation) async {
    final oldChannel = _chatChannel;
    if (oldChannel != null) await _supabase.removeChannel(oldChannel);

    final ready = Completer<void>();
    final channel = _supabase.channel('chat-${conversation.id}');
    _chatChannel = channel
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'chat_messages',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'conversation_id',
          value: conversation.id,
        ),
        callback: (payload) {
          if (payload.eventType == PostgresChangeEvent.delete) {
            final id = payload.oldRecord['id']?.toString();
            if (id == null || !mounted) return;
            _messageIds.remove(id);
            setState(() {
              _messages[conversation.id]?.removeWhere(
                (message) => message.id == id,
              );
            });
            return;
          }
          if (payload.newRecord['conversation_id'] != _selected.id) return;
          if (payload.eventType == PostgresChangeEvent.update) {
            final updated = _messageFromRow(payload.newRecord);
            final messages = _messages[conversation.id];
            final index = messages?.indexWhere(
              (message) => message.id == updated.id,
            );
            if (messages != null && index != null && index >= 0) {
              setState(() => messages[index] = updated);
            }
          } else {
            unawaited(_addMessage(payload.newRecord));
          }
        },
      )
      ..subscribe((status, error) {
        if (status == RealtimeSubscribeStatus.subscribed &&
            !ready.isCompleted) {
          ready.complete();
        } else if ((status == RealtimeSubscribeStatus.channelError ||
                status == RealtimeSubscribeStatus.timedOut) &&
            !ready.isCompleted) {
          ready.completeError(
            error ?? StateError('No se pudo sincronizar el chat.'),
          );
        }
      });
    await ready.future.timeout(const Duration(seconds: 20));
  }

  Future<void> _loadMessages(String conversationId) async {
    final rows = await _supabase
        .from('chat_messages')
        .select(
          _chatEnhancementsAvailable
              ? 'id, conversation_id, sender_id, body, created_at, text_color, pinned_at'
              : 'id, conversation_id, sender_id, body, created_at',
        )
        .eq('conversation_id', conversationId)
        .order('created_at');
    if (!mounted || _selected.id != conversationId) return;
    final senderIds = <String>{
      for (final row in rows) row['sender_id'] as String,
    };
    if (senderIds.isNotEmpty) {
      final profiles = await _supabase
          .from('profiles')
          .select('id, display_name, avatar_url')
          .inFilter('id', senderIds.toList());
      for (final profile in profiles) {
        _profilesById[profile['id'] as String] = Map<String, dynamic>.from(
          profile,
        );
      }
    }
    final messages = rows.map((row) => _messageFromRow(row)).toList();
    _messageIds.addAll(messages.map((message) => message.id));
    setState(() => _messages[conversationId] = messages);
  }

  _Message _messageFromRow(Map<String, dynamic> row) {
    final senderId = row['sender_id'] as String;
    _Contact? contact;
    for (final item in _contacts) {
      if (item.id == senderId) {
        contact = item;
        break;
      }
    }
    final data = _profilesById[senderId] ?? const <String, dynamic>{};
    final createdAt = DateTime.parse(row['created_at'] as String).toLocal();
    return _Message(
      id: row['id'] as String,
      senderId: senderId,
      sender:
          data['display_name'] as String? ??
          (senderId == _userId ? _profileName : contact?.name ?? 'Usuario'),
      text: row['body'] as String,
      time: TimeOfDay.fromDateTime(createdAt).format(context),
      avatarBytes:
          contact?.avatarBytes ??
          _privatePhotoCache[data['avatar_url'] as String?],
      isMine: senderId == _userId,
      textColor: row['text_color'] as String? ?? '#E8EDF2',
      isPinned: row['pinned_at'] != null,
    );
  }

  Future<void> _addMessage(Map<String, dynamic> row) async {
    final id = row['id']?.toString();
    if (id == null || !_messageIds.add(id) || !mounted) return;
    final senderId = row['sender_id'] as String?;
    if (senderId != null && !_profilesById.containsKey(senderId)) {
      final profile = await _supabase
          .from('profiles')
          .select('id, display_name, avatar_url')
          .eq('id', senderId)
          .maybeSingle();
      if (profile != null) {
        _profilesById[senderId] = Map<String, dynamic>.from(profile);
      }
    }
    if (!mounted) return;
    final message = _messageFromRow(row);
    setState(() {
      final conversationId = messageConversationId(row);
      _messages[conversationId] = [...?_messages[conversationId], message];
    });
  }

  String messageConversationId(Map<String, dynamic> row) =>
      row['conversation_id'] as String;

  void _startConnectionAttempt() {
    if (_isInitializing || _callFailed || !_appInForeground || _localWalkieMode) {
      return;
    }
    _connectionAttempt = _requestPermissionAndConnect();
  }

  Future<void> _requestPermissionAndConnect() async {
    if (_isRequestingPermission ||
        _isInitializing ||
        _callFailed ||
        !_appInForeground ||
        _localWalkieMode) {
      return;
    }
    _isRequestingPermission = true;
    _isInitializing = true;

    try {
      final permission = await widget.requestMicrophonePermission();
      if (!mounted || !_appInForeground || _localWalkieMode) return;
      if (!permission.isGranted) {
        setState(() {
          _isTransmitting = false;
          _status = permission.isPermanentlyDenied
              ? 'Permiso bloqueado. Habilítalo en Ajustes.'
              : 'Se necesita permiso de micrófono para conectarse.';
        });
        return;
      }

      await _endPendingVoiceRooms();
      setState(() => _status = 'Conectando a ${_selected.name}...');
      await _connectToConversation();
    } catch (error) {
      _showError(error);
    } finally {
      _isRequestingPermission = false;
      _isInitializing = false;
    }
  }

  Future<void> _connectToConversation() async {
    _localStream ??= await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': false,
    });
    if (!_appInForeground || _localWalkieMode) {
      final stream = _localStream;
      _localStream = null;
      _localAudioTrack = null;
      if (stream != null) await stream.dispose();
      return;
    }
    final audioTracks = _localStream!.getAudioTracks();
    if (audioTracks.isEmpty) {
      throw StateError('No se pudo obtener una pista de audio del micrófono.');
    }
    _localAudioTrack = audioTracks.first..enabled = _pttPointer != null;

    await _createPeerConnection();
    if (!_appInForeground || _localWalkieMode) {
      await _endVoiceSession(updateStatus: false);
      return;
    }
    final offer = await _peerConnection!.createOffer({
      'offerToReceiveAudio': true,
    });

    final response = await _supabase.rpc(
      'start_or_join_voice_call',
      params: {'p_conversation_id': _selected.id, 'p_offer': offer.toMap()},
    );
    if (response is! Map) {
      throw const FormatException('Supabase devolvió una sesión no válida.');
    }
    final room = Map<String, dynamic>.from(response);
    final role = room['role'];
    if (role != 'caller' && role != 'callee') {
      throw const FormatException('La sesión no asignó un rol válido.');
    }
    _role = role as String;
    _activeRoomId = room['id'] as String;
    _roomIsPublished = true;
    if (!_appInForeground || _localWalkieMode) {
      await _endVoiceSession(updateStatus: false);
      return;
    }

    if (_role == 'callee') {
      await _subscribeToRoom();
      final remoteOffer = _descriptionFromJson(room['offer'], 'offer');
      await _peerConnection!.setRemoteDescription(remoteOffer);
      _remoteDescriptionIsSet = true;
      await _loadExistingRemoteCandidates();
      await _flushRemoteCandidates();

      final savedAnswer = room['answer'];
      if (savedAnswer != null) {
        await _peerConnection!.setLocalDescription(
          _descriptionFromJson(savedAnswer, 'answer'),
        );
      } else {
        final answer = await _peerConnection!.createAnswer({
          'offerToReceiveAudio': true,
        });
        await _peerConnection!.setLocalDescription(answer);
        final localAnswer = await _peerConnection!.getLocalDescription();
        if (localAnswer == null) {
          throw StateError('WebRTC no generó la respuesta local.');
        }

        await _supabase.rpc(
          'answer_voice_call',
          params: {'p_room_id': _activeRoomId, 'p_answer': localAnswer.toMap()},
        );
      }

      await _flushLocalCandidates();
      if (mounted && !_isConnected) {
        setState(() => _status = 'Respuesta enviada; conectando...');
      }
      return;
    }

    await _peerConnection!.setLocalDescription(
      _descriptionFromJson(room['offer'], 'offer'),
    );
    await _subscribeToRoom();
    await _flushLocalCandidates();
    final latestRoom = await _supabase
        .from('webrtc_rooms')
        .select('id, offer, answer, status')
        .eq('id', _activeRoomId!)
        .single();
    await _handleRoomChange(Map<String, dynamic>.from(latestRoom));
    if (mounted && !_isConnected && latestRoom['answer'] == null) {
      setState(() => _status = 'Esperando a alguien en ${_selected.name}...');
    }
  }

  Future<void> _createPeerConnection() async {
    final connection = await createPeerConnection({
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
      ],
    });
    _peerConnection = connection;
    await connection.addTrack(_localAudioTrack!, _localStream!);
    connection.onTrack = (event) {
      if (event.track.kind == 'audio') event.track.enabled = true;
    };
    connection.onIceCandidate = (candidate) {
      unawaited(_runSafely(() => _handleLocalCandidate(connection, candidate)));
    };
    connection.onConnectionState = (state) {
      if (!mounted) return;
      final connectionState = state.toString().split('.').last;
      if (connectionState == 'RTCPeerConnectionStateConnected' ||
          connectionState == 'connected') {
        setState(() {
          _isConnected = true;
          _status = 'Conectado · ${_selected.name}';
        });
      } else if (connectionState == 'RTCPeerConnectionStateFailed' ||
          connectionState == 'failed') {
        _stopTransmission();
        setState(() {
          _callFailed = true;
          _isConnected = false;
          _status = 'Falló la conexión WebRTC. El micrófono se liberó.';
        });
        unawaited(_endVoiceSession(updateStatus: false));
      } else if (connectionState == 'RTCPeerConnectionStateDisconnected' ||
          connectionState == 'disconnected') {
        _stopTransmission();
        setState(() {
          _callFailed = true;
          _isConnected = false;
          _status = 'Conexión perdida. Micrófono liberado; puedes reintentar.';
        });
        unawaited(_endVoiceSession(updateStatus: false));
      }
    };
  }

  Future<void> _subscribeToRoom() async {
    final conversationId = _selected.id;
    final ready = Completer<void>();
    final channel = _supabase.channel('voice-$conversationId');
    _channel = channel
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'webrtc_rooms',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'conversation_id',
          value: conversationId,
        ),
        callback: (payload) {
          unawaited(_runSafely(() => _handleRoomChange(payload.newRecord)));
        },
      )
      ..onPostgresChanges(
        event: PostgresChangeEvent.insert,
        schema: 'public',
        table: 'webrtc_ice_candidates',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'conversation_id',
          value: conversationId,
        ),
        callback: (payload) {
          unawaited(
            _runSafely(() => _handleRemoteCandidate(payload.newRecord)),
          );
        },
      )
      ..subscribe((status, error) {
        if (status == RealtimeSubscribeStatus.subscribed &&
            !ready.isCompleted) {
          ready.complete();
        } else if ((status == RealtimeSubscribeStatus.channelError ||
                status == RealtimeSubscribeStatus.timedOut) &&
            !ready.isCompleted) {
          ready.completeError(
            error ?? StateError('No se pudo suscribir a Supabase Realtime.'),
          );
        }
      });

    await ready.future.timeout(const Duration(seconds: 20));
  }

  Future<void> _handleRoomChange(Map<String, dynamic> record) async {
    if (record['id'] != _activeRoomId) return;
    if (record['status'] == 'ended') {
      await _endVoiceSession(updateStatus: false);
      if (mounted) {
        setState(() {
          _isConnected = false;
          _isTransmitting = false;
          _status = 'Sesión terminada · mantén presionado para reiniciar.';
        });
      }
      return;
    }
    if (_role != 'caller' || record['answer'] == null || _answerIsApplied) {
      return;
    }

    final answer = _descriptionFromJson(record['answer'], 'answer');
    await _peerConnection!.setRemoteDescription(answer);
    _remoteDescriptionIsSet = true;
    _answerIsApplied = true;
    await _loadExistingRemoteCandidates();
    await _flushRemoteCandidates();
    if (mounted && !_isConnected) {
      setState(() => _status = 'Respuesta recibida; conectando...');
    }
  }

  RTCSessionDescription _descriptionFromJson(dynamic value, String label) {
    if (value is! Map) {
      throw FormatException('La $label recibida no tiene un formato válido.');
    }
    final map = Map<String, dynamic>.from(value);
    final sdp = map['sdp'];
    final type = map['type'];
    if (sdp is! String || type is! String) {
      throw FormatException('La $label debe contener "sdp" y "type".');
    }
    return RTCSessionDescription(sdp, type);
  }

  Future<void> _handleLocalCandidate(
    RTCPeerConnection connection,
    RTCIceCandidate candidate,
  ) async {
    if (!identical(connection, _peerConnection) ||
        candidate.candidate == null ||
        candidate.candidate!.isEmpty) {
      return;
    }

    if (_role == null || !_roomIsPublished || _activeRoomId == null) {
      _pendingLocalCandidates.add(candidate);
      return;
    }
    await _insertLocalCandidate(candidate);
  }

  Future<void> _insertLocalCandidate(RTCIceCandidate candidate) async {
    final role = _role;
    final roomId = _activeRoomId;
    if (role == null || roomId == null) return;
    await _supabase.from('webrtc_ice_candidates').insert({
      'room_id': roomId,
      'conversation_id': _selected.id,
      'sender': role,
      'candidate': candidate.toMap(),
    });
  }

  Future<void> _flushLocalCandidates() async {
    final candidates = List<RTCIceCandidate>.of(_pendingLocalCandidates);
    _pendingLocalCandidates.clear();
    for (final candidate in candidates) {
      await _insertLocalCandidate(candidate);
    }
  }

  Future<void> _handleRemoteCandidate(Map<String, dynamic> record) async {
    final id = record['id']?.toString();
    if (id != null && !_seenRemoteCandidateIds.add(id)) return;
    if (record['room_id'] != _activeRoomId ||
        (_role != null && record['sender'] == _role)) {
      return;
    }

    if (_role == null || !_remoteDescriptionIsSet) {
      _pendingRemoteCandidates.add(record);
      return;
    }
    await _addRemoteCandidate(record);
  }

  Future<void> _loadExistingRemoteCandidates() async {
    final role = _role;
    final roomId = _activeRoomId;
    if (role == null || roomId == null) return;
    final candidates = await _supabase
        .from('webrtc_ice_candidates')
        .select()
        .eq('room_id', roomId)
        .neq('sender', role);
    for (final row in candidates) {
      final record = Map<String, dynamic>.from(row);
      final id = record['id']?.toString();
      if (id != null && !_seenRemoteCandidateIds.add(id)) continue;
      _pendingRemoteCandidates.add(record);
    }
  }

  Future<void> _flushRemoteCandidates() async {
    if (!_remoteDescriptionIsSet) return;
    final candidates = List<Map<String, dynamic>>.of(_pendingRemoteCandidates);
    _pendingRemoteCandidates.clear();
    for (final candidate in candidates) {
      await _addRemoteCandidate(candidate);
    }
  }

  Future<void> _addRemoteCandidate(Map<String, dynamic> record) async {
    final value = record['candidate'];
    if (value is! Map) {
      throw const FormatException('El candidato ICE recibido no es válido.');
    }
    final candidate = Map<String, dynamic>.from(value);
    final candidateValue = candidate['candidate'];
    if (candidateValue is! String || candidateValue.isEmpty) return;

    final sdpMLineIndex = candidate['sdpMLineIndex'];
    await _peerConnection!.addCandidate(
      RTCIceCandidate(
        candidateValue,
        candidate['sdpMid'] as String?,
        sdpMLineIndex is num ? sdpMLineIndex.toInt() : null,
      ),
    );
  }

  Future<void> _runSafely(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      _showError(error);
    }
  }

  void _showError(Object error) {
    if (!mounted) return;
    _stopTransmission();
    setState(() {
      _callFailed = true;
      _isConnected = false;
      _status = 'Error: $error';
    });
    unawaited(_endVoiceSession(updateStatus: false));
  }

  Future<void> _startTransmission() async {
    if (!VoicePttPolicy.allowsRemotePtt(
      localWalkieMode: _localWalkieMode,
      callFailed: _callFailed,
    )) {
      if (_localWalkieMode && mounted) {
        setState(
          () => _status = 'Modo local activo; el PTT remoto está bloqueado.',
        );
      }
      return;
    }
    if (_localAudioTrack == null || _peerConnection == null) {
      if (mounted) {
        setState(() => _status = 'Conectando el audio remoto; todavía no se transmite.');
      }
      _startConnectionAttempt();
      return;
    }

    _remoteBusyReply = false;
    if (_walkieIntentChannel != null) {
      await _walkieIntentChannel!.sendBroadcastMessage(
        event: 'voice_intent',
        payload: {
          'sender': _userId,
          'senderName': _profileName,
          'target': _selected.id,
        },
      );
      await Future<void>.delayed(const Duration(milliseconds: 700));
      if (_remoteBusyReply || _pttPointer == null || !mounted) return;
    }

    if (_pttPointer == null || !mounted) return;
    _localAudioTrack!.enabled = true;
    setState(() => _isTransmitting = true);
  }

  void _stopTransmission() {
    final wasPressed = _pttPointer != null;
    _pttPointer = null;
    _localAudioTrack?.enabled = false;
    if (mounted && (wasPressed || _isTransmitting)) {
      setState(() => _isTransmitting = false);
    }
  }

  Future<void> _endVoiceSession({bool updateStatus = true}) async {
    _pttPointer = null;
    _isTransmitting = false;
    _localAudioTrack?.enabled = false;
    final roomId = _activeRoomId;
    final role = _role;
    final roomIsPublished = _roomIsPublished;
    final channel = _channel;
    final connection = _peerConnection;
    final stream = _localStream;

    _activeRoomId = null;
    _role = null;
    _roomIsPublished = false;
    _channel = null;
    _peerConnection = null;
    _localStream = null;
    _localAudioTrack = null;
    _remoteDescriptionIsSet = false;
    _answerIsApplied = false;
    _pendingLocalCandidates.clear();
    _pendingRemoteCandidates.clear();
    _seenRemoteCandidateIds.clear();
    _isConnected = false;
    if (roomId != null && role != null && roomIsPublished) {
      _pendingVoiceCleanupRoomIds.add(roomId);
    }
    try {
      await _endPendingVoiceRooms();
    } finally {
      try {
        if (channel != null) await _supabase.removeChannel(channel);
      } finally {
        try {
          if (connection != null) await connection.close();
        } finally {
          try {
            if (connection != null) await connection.dispose();
          } finally {
            try {
              if (stream != null) {
                try {
                  for (final track in stream.getTracks()) {
                    await track.stop();
                  }
                } finally {
                  await stream.dispose();
                }
              }
            } finally {
              if (!kIsWeb) {
                try {
                  await _walkieChannel.invokeMethod<void>(
                    'releaseAudioResources',
                  );
                } on PlatformException {
                  // The Android activity may already be shutting down.
                }
              }
              if (updateStatus && mounted) {
                setState(() => _status = 'Listo · ${_selected.name}');
              }
            }
          }
        }
      }
    }
  }

  Future<void> _endPendingVoiceRooms() async {
    for (final roomId in List<String>.of(_pendingVoiceCleanupRoomIds)) {
      await _supabase.rpc('end_voice_call', params: {'p_room_id': roomId});
      _pendingVoiceCleanupRoomIds.remove(roomId);
    }
  }

  Future<void> _retryVoiceConnection() async {
    await _endVoiceSession(updateStatus: false);
    if (!mounted) return;
    setState(() {
      _callFailed = false;
      _status = 'Reintentando conexión...';
    });
    _startConnectionAttempt();
  }

  Future<void> _disposeCall() async {
    final pending = _connectionAttempt;
    if (pending != null) await pending;
    if (_localWalkieMode && !kIsWeb) {
      try {
        await _walkieChannel.invokeMethod<void>('stop');
      } on PlatformException {
        // La aplicación ya está cerrando el audio local.
      }
    }
    await _walkieEventSubscription?.cancel();
    _walkieEventSubscription = null;
    final walkieIntentChannel = _walkieIntentChannel;
    if (walkieIntentChannel != null) {
      await _supabase.removeChannel(walkieIntentChannel);
    }
    _walkieIntentChannel = null;
    await _endVoiceSession(updateStatus: false);
    final chatChannel = _chatChannel;
    if (chatChannel != null) {
      await _supabase.removeChannel(chatChannel);
    }
    final directoryChannel = _directoryChannel;
    if (directoryChannel != null) {
      await _supabase.removeChannel(directoryChannel);
    }
    final stream = _localStream;
    if (stream != null) await stream.dispose();
    _localStream = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final wasInForeground = _appInForeground;
    _appInForeground = state == AppLifecycleState.resumed;
    if (!_appInForeground) {
      _usageTimer?.cancel();
      _usageTimer = null;
      unawaited(_flushForegroundUsage(force: true));
      _stopTransmission();
      if (state == AppLifecycleState.inactive ||
          state == AppLifecycleState.paused ||
          state == AppLifecycleState.hidden ||
          state == AppLifecycleState.detached) {
        unawaited(_releaseAudioWhenBackgrounded());
      }
    } else if (!wasInForeground && !_localWalkieMode) {
      _startForegroundUsageTracking();
      _connectionAttempt = null;
      _startConnectionAttempt();
    }
  }

  Future<void> _releaseAudioWhenBackgrounded() async {
    _stopTransmission();
    if (_localWalkieMode && !kIsWeb) {
      try {
        await _walkieChannel.invokeMethod<void>('stop');
      } on PlatformException {
        // Audio cleanup continues below if the native channel is unavailable.
      }
      if (mounted) {
        setState(() {
          _localWalkieMode = false;
          _localWalkieStatus = 'Walkie Talkie detenido al salir de Dido Live.';
        });
      } else {
        _localWalkieMode = false;
      }
    }
    try {
      await _endVoiceSession(updateStatus: false);
    } catch (error) {
      if (mounted) {
        setState(() {
          _callFailed = true;
          _status =
              'Audio del dispositivo liberado; Supabase no confirmó el cierre remoto: $error';
        });
      }
      return;
    }
    if (mounted) {
      setState(() {
        _callFailed = false;
        _status = 'Audio liberado en segundo plano. Vuelve a Dido para reconectar.';
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _usageTimer?.cancel();
    unawaited(_flushForegroundUsage(force: true));
    _localAudioTrack?.enabled = false;
    unawaited(_disposeCall());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const titles = ['Dido Live', 'Chat', 'Mi perfil'];

    return Scaffold(
      appBar: AppBar(
        backgroundColor: _panel,
        surfaceTintColor: Colors.transparent,
        toolbarHeight: 64,
        titleSpacing: 0,
        centerTitle: true,
        automaticallyImplyLeading: false,
        title: _AppWidth(
          child: Container(
            height: 64,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            alignment: Alignment.centerLeft,
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: _line)),
            ),
            child: Row(
              children: [
                if (_tab == 0) ...[
                  const _DidoLogo(size: 38),
                  const SizedBox(width: 12),
                ],
                Text(
                  titles[_tab],
                  style: const TextStyle(
                    fontSize: 23,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      body: SafeArea(
        top: false,
        bottom: false,
        child: _AppWidth(
          child: IndexedStack(
            index: _tab,
            sizing: StackFit.expand,
            children: [
              _buildVoice(),
              Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                    child: _channelSelector(),
                  ),
                  Expanded(
                    child: _ChannelChat(
                      key: ValueKey(_selected.id),
                      messages: _messages[_selected.id] ?? const <_Message>[],
                      onSend: (text, color) =>
                          unawaited(_sendChatMessage(text, color: color)),
                      onDelete: (messageId) =>
                          unawaited(_deleteChatMessage(messageId)),
                      onPin: (messageId, pin) =>
                          unawaited(_pinChatMessage(messageId, pin)),
                    ),
                  ),
                ],
              ),
              _buildProfile(),
            ],
          ),
        ),
      ),
      bottomNavigationBar: _AppWidth(
        child: Container(
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: _line)),
          ),
          child: NavigationBar(
            height: 72,
            backgroundColor: _panel,
            indicatorColor: const Color(0xFF253B40),
            selectedIndex: _tab,
            onDestinationSelected: (index) {
              if (_tab == index) return;
              _stopTransmission();
              FocusManager.instance.primaryFocus?.unfocus();
              setState(() => _tab = index);
              if (index == 0 && kIsWeb) _startConnectionAttempt();
            },
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.mic_none_rounded),
                selectedIcon: Icon(Icons.mic_rounded, color: _turquoise),
                label: 'Voz',
              ),
              NavigationDestination(
                icon: Icon(Icons.chat_bubble_outline_rounded),
                selectedIcon: Icon(
                  Icons.chat_bubble_rounded,
                  color: _turquoise,
                ),
                label: 'Chat',
              ),
              NavigationDestination(
                icon: Icon(Icons.person_outline_rounded),
                selectedIcon: Icon(Icons.person_rounded, color: _turquoise),
                label: 'Perfil',
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVoice() {
    final permissionBlocked = _status.startsWith('Permiso bloqueado');
    final status = _isTransmitting
        ? 'Transmitiendo · ${_selected.name}'
        : _pttPointer != null
        ? 'Solicitando turno · ${_selected.name}'
        : _status;
    final localInputs = (_localWalkieProbe?['inputs'] as List? ?? const [])
        .whereType<Map>()
        .map((device) => Map<String, dynamic>.from(device))
        .where((device) => device['id'] is int)
        .toList();
    final localOutputs = (_localWalkieProbe?['outputs'] as List? ?? const [])
        .whereType<Map>()
        .map((device) => Map<String, dynamic>.from(device))
        .where((device) => device['id'] is int)
        .toList();

    return LayoutBuilder(
      builder: (context, constraints) {
        final buttonSize = (constraints.maxWidth * 0.44)
            .clamp(110.0, 182.0)
            .toDouble();
        return ListView(
          padding: const EdgeInsets.fromLTRB(20, 15, 20, 14),
          children: [
            _channelSelector(),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: _StatusDot(
                    active: _localWalkieMode || _isConnected || _isTransmitting,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    status,
                    style: const TextStyle(color: _muted, fontSize: 14),
                  ),
                ),
              ],
            ),
            if (_callFailed)
              TextButton.icon(
                onPressed: _retryVoiceConnection,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Reintentar conexión'),
              ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: _panelDecoration(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        _localWalkieMode
                            ? Icons.bluetooth_connected_rounded
                            : Icons.bluetooth_searching_rounded,
                        color: _localWalkieMode ? _accent : _muted,
                      ),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          'Walkie Talkie local',
                          style: _sectionHeading,
                        ),
                      ),
                      Switch.adaptive(
                        value: _localWalkieMode,
                        activeThumbColor: _accent,
                        onChanged: _localWalkieMode || _canStartSingleSideWalkie
                            ? (_) => unawaited(_enterLocalWalkieMode())
                            : null,
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _localWalkieStatus,
                    style: const TextStyle(color: _muted, fontSize: 12),
                  ),
                  if (localOutputs.isNotEmpty && !_localWalkieMode) ...[
                    const SizedBox(height: 10),
                    DropdownButtonFormField<int>(
                      key: ValueKey('walkie-output-$_leftOutputId'),
                      initialValue: _leftOutputId,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'HTC NE79 · salida para ambas pruebas',
                        isDense: true,
                      ),
                      items: localOutputs.indexed.map((entry) {
                        final index = entry.$1;
                        final device = entry.$2;
                        final id = device['id'] as int;
                        final routeStatus = id == _activeBluetoothOutputId
                            ? ' · Android la usa'
                            : id == _lastEffectiveBluetoothOutputId
                            ? ' · última salida comprobada'
                            : '';
                        return DropdownMenuItem(
                          value: id,
                          child: Text(
                            '${LocalWalkieRouteGuard.routeLabel(device, input: false, index: index, count: localOutputs.length)}$routeStatus',
                          ),
                        );
                      }).toList(),
                      onChanged: (id) => setState(() {
                        _leftOutputId = id;
                        _rightOutputId = id;
                        _clearCalibrationForOutputChange();
                      }),
                    ),
                  ],
                  if (kIsWeb)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text(
                        'La calibración Bluetooth L/R y el Walkie Talkie local solo están disponibles en Android. En web puedes usar el chat y el PTT remoto.',
                        style: TextStyle(color: _muted, fontSize: 11),
                      ),
                    ),
                  if (localInputs.length > 1 && !_localWalkieMode) ...[
                    const SizedBox(height: 8),
                    DropdownButtonFormField<int>(
                      key: ValueKey('walkie-input-$_selectedInputId'),
                      initialValue: _selectedInputId,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Micrófono que usa Android',
                        isDense: true,
                      ),
                      items: localInputs.indexed.map((entry) {
                        final index = entry.$1;
                        final device = entry.$2;
                        final id = device['id'] as int;
                        return DropdownMenuItem(
                          value: id,
                          child: Text(
                            LocalWalkieRouteGuard.routeLabel(
                              device,
                              input: true,
                              index: index,
                              count: localInputs.length,
                            ),
                          ),
                        );
                      }).toList(),
                      onChanged: (id) => setState(() {
                        _selectedInputId = id;
                        _clearCalibrationForOutputChange();
                      }),
                    ),
                  ],
                  if (!_localWalkieMode &&
                      LocalWalkieRouteGuard.canCalibrate(
                        _localWalkieProbe,
                      )) ...[
                    const SizedBox(height: 10),
                    Text(
                      'Conecta el par → Prueba L → Prueba R → Activar. Cada prueba vuelve a abrir la captura y la libera antes de reproducir por la salida elegida.',
                      style: const TextStyle(color: _muted, fontSize: 11),
                    ),
                    if (localOutputs.length == 1)
                      const Padding(
                        padding: EdgeInsets.only(top: 5),
                        child: Text(
                          'Una sola salida HTC NE79 sirve para calibrar ambos lados.',
                          style: TextStyle(color: _muted, fontSize: 11),
                        ),
                      ),
                    const SizedBox(height: 8),
                    Text(
                      calibrationProgressText(_calibrationOutcomes),
                      style: const TextStyle(
                        color: _ink,
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Prueba L: ${_calibrationOutcomes['L'] ?? 'pendiente'}  ·  Prueba R: ${_calibrationOutcomes['R'] ?? 'pendiente'}',
                      style: const TextStyle(color: _muted, fontSize: 11),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: [
                        OutlinedButton.icon(
                          onPressed:
                              _calibrationBusy ||
                                  _pendingCalibrationSide != null
                              ? null
                              : () => unawaited(_testLocalOutput('L')),
                          icon: const Icon(Icons.hearing, size: 16),
                          label: const Text('Escuchar solo L'),
                        ),
                        OutlinedButton.icon(
                          onPressed:
                              _calibrationBusy ||
                                  _pendingCalibrationSide != null
                              ? null
                              : () => unawaited(_testLocalOutput('R')),
                          icon: const Icon(Icons.hearing, size: 16),
                          label: const Text('Escuchar solo R'),
                        ),
                      ],
                    ),
                    if (_calibrationBusy)
                      const Padding(
                        padding: EdgeInsets.only(top: 6),
                        child: LinearProgressIndicator(),
                      ),
                    if (_pendingCalibrationSide case final side?)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '¿Dónde escuchaste toda la frase de la prueba $side?',
                              style: const TextStyle(
                                color: _ink,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const Text(
                              'Comprueba ambos auriculares, no solo el lado elegido.',
                              style: TextStyle(color: _muted, fontSize: 11),
                            ),
                            Wrap(
                              spacing: 8,
                              children: [
                                TextButton(
                                  onPressed: () => unawaited(
                                    _confirmCalibration(outcome: 'isolated'),
                                  ),
                                  child: Text('Solo $side'),
                                ),
                                TextButton(
                                  onPressed: () => unawaited(
                                    _confirmCalibration(
                                      outcome: 'wrong_channel',
                                    ),
                                  ),
                                  child: Text(
                                    'Solo ${side == 'L' ? 'R' : 'L'}',
                                  ),
                                ),
                                TextButton(
                                  onPressed: () => unawaited(
                                    _confirmCalibration(outcome: 'shared'),
                                  ),
                                  child: const Text('Ambos'),
                                ),
                                TextButton(
                                  onPressed: () => unawaited(
                                    _confirmCalibration(outcome: 'silent'),
                                  ),
                                  child: const Text('No se oyó'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    if (_sharedOutputIds.isNotEmpty)
                      const Padding(
                        padding: EdgeInsets.only(top: 6),
                        child: Text(
                          'Salida compartida. El envío a un solo lado está desactivado.',
                          style: TextStyle(
                            color: _accent,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    if (_calibratedOutputSides.isNotEmpty &&
                        _sharedOutputIds.isEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          'Calibradas: ${_calibratedOutputSides.map((entry) => entry.split(':').last).join(', ')}',
                          style: const TextStyle(color: _muted, fontSize: 11),
                        ),
                      ),
                  ],
                  if (!kIsWeb &&
                      !_localWalkieMode &&
                      !LocalWalkieRouteGuard.canCalibrate(_localWalkieProbe))
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: OutlinedButton.icon(
                        onPressed: _prepareLocalWalkieRoutes,
                        icon: const Icon(Icons.bluetooth_searching_rounded),
                        label: const Text('Buscar auriculares Bluetooth'),
                      ),
                    ),
                  if (_localWalkieRouteDiagnostic.isNotEmpty)
                    ExpansionTile(
                        tilePadding: EdgeInsets.zero,
                        childrenPadding: const EdgeInsets.only(bottom: 6),
                        title: const Text(
                          'Diagnóstico Bluetooth',
                          style: TextStyle(fontSize: 12),
                        ),
                        children: [
                          Text(
                            _localWalkieRouteDiagnostic,
                            style: const TextStyle(color: _muted, fontSize: 11),
                          ),
                          for (final (kind, devices) in [
                            ('Entradas', localInputs),
                            ('Salidas', localOutputs),
                          ])
                            for (final (index, device) in devices.indexed)
                              Align(
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  '$kind · ${LocalWalkieRouteGuard.routeLabel(device, input: kind == 'Entradas', index: index, count: devices.length)} · ID ${device['id']} · canales ${device['channels'] ?? 'no reportados'}',
                                  style: const TextStyle(
                                    color: _muted,
                                    fontSize: 10,
                                  ),
                                ),
                              ),
                        ],
                      ),
                  if (_localWalkieMode) ...[
                    const SizedBox(height: 8),
                    const Text(
                      'Di «Izquierdo habla» o «Dido 1 habla» para grabar y enviar solo a R. Di «Derecho habla» o «Dido 2 habla» para enviar solo a L. «Cambio» envía; «Cancela mensaje» descarta. Máximo: 30 s.',
                      style: TextStyle(color: _muted, fontSize: 11),
                    ),
                    const SizedBox(height: 8),
                  ],
                  if (!_localWalkieMode)
                    const Padding(
                      padding: EdgeInsets.only(top: 6),
                      child: Text(
                        'El envío por lado requiere aprobar las dos pruebas escuchando ambos auriculares.',
                        style: TextStyle(color: _muted, fontSize: 11),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Center(
              child: Semantics(
                button: true,
                label: 'Mantén presionado para hablar',
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (event) {
                    if (_pttPointer != null ||
                        event.buttons != 1 ||
                        _callFailed ||
                        _localWalkieMode) {
                      return;
                    }
                    _pttPointer = event.pointer;
                    setState(() {});
                    unawaited(_startTransmission());
                  },
                  onPointerUp: (event) {
                    if (_pttPointer == event.pointer) _stopTransmission();
                  },
                  onPointerCancel: (event) {
                    if (_pttPointer == event.pointer) _stopTransmission();
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    width: buttonSize,
                    height: buttonSize,
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: _isTransmitting ? _accent : _turquoise,
                        width: 2.5,
                      ),
                      boxShadow: [
                        if (_isTransmitting)
                          const BoxShadow(
                            color: Color(0x40FF9F67),
                            blurRadius: 22,
                          ),
                      ],
                    ),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: _isTransmitting
                              ? const [Color(0xFFFFBE83), _accent]
                              : const [Color(0xFF3DF7E5), Color(0xFF19CECB)],
                        ),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.mic_rounded,
                            size: buttonSize * 0.36,
                            color: _background,
                          ),
                          Text(
                            'PTT',
                            style: TextStyle(
                              color: _background,
                              fontSize: buttonSize * 0.15,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 1,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              _localWalkieMode
                  ? 'PTT remoto deshabilitado durante Walkie Talkie'
                  : _callFailed
                  ? 'PTT deshabilitado: revisa la conexión'
                  : _isTransmitting
                  ? 'Suelta para escuchar'
                  : _pttPointer != null
                  ? 'Solicitando turno; suelta para cancelar'
                  : !_isConnected
                  ? 'PTT no disponible: conectando con Supabase'
                  : 'Mantén presionado para hablar',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            if (permissionBlocked)
              TextButton(
                onPressed: openAppSettings,
                child: const Text('Abrir Ajustes'),
              ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
              decoration: _panelDecoration(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Participantes', style: _sectionHeading),
                  for (final contact in _selected.contacts)
                    _UserRow(
                      name: contact.name,
                      image: contact.avatar,
                      imageBytes: contact.avatarBytes,
                      subtitle: 'Integrante del canal',
                    ),
                  _UserRow(
                    name: _profileName,
                    image: 2,
                    avatar: _profileAvatar(size: 40),
                    subtitle: _isTransmitting
                        ? 'Tú · Está hablando'
                        : _isConnected
                        ? 'Tú · En voz'
                        : 'Tú · Integrante${widget.isGuest ? ' · Invitado' : ''}',
                    active: _isTransmitting,
                    transmitting: _isTransmitting,
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildProfile() {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      children: [
        const SizedBox(height: 29),
        Row(
          children: [
            _profileAvatar(size: 83),
            const SizedBox(width: 18),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_profileName, style: _screenHeading),
                  const SizedBox(height: 6),
                  Text(
                    widget.isGuest ? 'Invitado' : 'Perfil de prueba',
                    style: const TextStyle(color: _muted),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        const Divider(height: 1),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.edit_outlined),
          title: const Text('Editar perfil'),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: _editProfile,
        ),
        const Divider(height: 1),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.add_a_photo_outlined),
          title: Text(
            _profilePhoto == null
                ? 'Elegir foto de perfil'
                : 'Cambiar foto de perfil',
          ),
          subtitle: const Text('Disponible durante esta sesión'),
          onTap: _pickingPhoto ? null : _pickPhoto,
        ),
        if (_profilePhoto != null) ...[
          const Divider(height: 1),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.account_circle_outlined),
            title: Text(
              widget.isGuest
                  ? 'Usar logo de Dido Live'
                  : 'Usar avatar predeterminado',
            ),
            onTap: _pickingPhoto ? null : _removeProfilePhoto,
          ),
        ],
        const Divider(height: 1),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: const Icon(Icons.notifications_none_rounded),
          title: const Text('Notificaciones'),
          value: _notifications,
          onChanged: (value) => setState(() => _notifications = value),
        ),
        const Divider(height: 1),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: const Icon(Icons.volume_up_outlined),
          title: const Text('Sonido PTT'),
          value: _pttSound,
          onChanged: (value) => setState(() => _pttSound = value),
        ),
        const Divider(height: 1),
        if (_isAppAdmin) ...[
          SuperAdminPanel(client: _supabase, key: ValueKey(_userId)),
          const SizedBox(height: 18),
        ],
        const SizedBox(height: 12),
        const Align(
          alignment: Alignment.centerLeft,
          child: Text(
            'Ajustes de muestra',
            style: TextStyle(color: _muted, fontSize: 12),
          ),
        ),
        const SizedBox(height: 24),
        if (Navigator.of(context).canPop()) ...[
          const Divider(height: 1),
          TextButton.icon(
            onPressed: () {
              _stopTransmission();
              unawaited(_supabase.auth.signOut());
              Navigator.of(context).pop();
            },
            icon: const Icon(Icons.logout_rounded),
            label: const Text('Cerrar sesión'),
            style: TextButton.styleFrom(
              foregroundColor: _ink,
              minimumSize: const Size.fromHeight(55),
            ),
          ),
        ],
        const SizedBox(height: 9),
      ],
    );
  }

  Widget _channelSelector() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 7,
          runSpacing: 4,
          children: [
            for (final scope in _Scope.values)
              ChoiceChip(
                label: Text(scope.label),
                selected: _selected.scope == scope,
                backgroundColor: _panel,
                selectedColor: const Color(0xFF253B40),
                side: BorderSide(
                  color: _selected.scope == scope ? _turquoise : _line,
                ),
                labelStyle: TextStyle(
                  color: _selected.scope == scope ? _turquoise : _ink,
                  fontWeight: FontWeight.w600,
                ),
                onSelected: (_) => _chooseScope(scope),
              ),
          ],
        ),
        const SizedBox(height: 5),
        Material(
          color: _surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(13),
            side: const BorderSide(color: _line),
          ),
          child: ListTile(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(13),
            ),
            dense: true,
            minVerticalPadding: 8,
            leading: Icon(_selected.scope.icon, color: _turquoise),
            title: Text(_selected.name, style: _sectionHeading),
            subtitle: Text(
              _selected.scope == _Scope.general
                  ? 'Para toda la comunidad'
                  : '${_selected.contacts.length + 1} participantes',
              style: const TextStyle(color: _muted, fontSize: 12),
            ),
            trailing: _selected.scope == _Scope.general
                ? null
                : const Icon(Icons.unfold_more_rounded),
            onTap: _selected.scope == _Scope.general
                ? null
                : () => _chooseScope(_selected.scope),
          ),
        ),
      ],
    );
  }

  Future<void> _chooseScope(_Scope scope) async {
    if (scope == _Scope.general) {
      final general = _conversations.firstWhere(
        (conversation) => conversation.id == _generalConversationId,
      );
      await _selectConversation(general);
      return;
    }
    final personal = scope == _Scope.personal;
    final options = personal
        ? [
            for (final contact in _contacts)
              _Conversation(contact.id, contact.name, scope, [contact]),
          ]
        : _conversations.where((room) => room.scope == scope).toList();
    final choice = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(personal ? 'Elegir contacto' : 'Grupos'),
        scrollable: true,
        contentPadding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (options.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    personal
                        ? 'Aún no hay otros perfiles. Pide a alguien que cree una cuenta o entre como invitado.'
                        : 'Agrega al menos otro perfil para crear un grupo.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: _muted),
                  ),
                ),
              for (final option in options)
                ListTile(
                  leading: personal
                      ? _Avatar(
                          image: option.contacts.single.avatar,
                          imageBytes: option.contacts.single.avatarBytes,
                          size: 34,
                        )
                      : const Icon(Icons.groups_outlined),
                  title: Text(option.name),
                  subtitle: personal
                      ? null
                      : Text('${option.contacts.length + 1} participantes'),
                  trailing: personal
                      ? (_selected.scope == _Scope.personal &&
                                _selected.contacts.any(
                                  (member) => member.id == option.id,
                                )
                            ? const Icon(Icons.check, color: _turquoise)
                            : const Icon(Icons.chevron_right_rounded))
                      : option.id == _selected.id
                      ? const Icon(Icons.check, color: _turquoise)
                      : const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.of(dialogContext).pop(option.id),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancelar'),
          ),
          if (!personal)
            FilledButton.icon(
              onPressed: () => Navigator.of(dialogContext).pop('new-group'),
              icon: const Icon(Icons.add),
              label: const Text('Crear grupo'),
            ),
        ],
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == 'new-group') {
      final group = await showDialog<_Conversation>(
        context: context,
        builder: (_) => _CreateGroupDialog(id: _newUuid(), contacts: _contacts),
      );
      if (!mounted || group == null) return;
      await _supabase.from('conversations').insert({
        'id': group.id,
        'kind': 'group',
        'name': group.name,
        'created_by': _userId,
      });
      await _supabase.from('conversation_members').insert([
        {'conversation_id': group.id, 'user_id': _userId, 'role': 'admin'},
        for (final member in group.contacts)
          {'conversation_id': group.id, 'user_id': member.id, 'role': 'member'},
      ]);
      await _loadConversations();
      final createdGroup = _conversations.firstWhere(
        (conversation) => conversation.id == group.id,
      );
      await _selectConversation(createdGroup);
      return;
    }
    if (personal) {
      final contact = _contacts.firstWhere((option) => option.id == choice);
      final conversation = await _openDirectConversation(contact);
      await _selectConversation(conversation);
    } else {
      await _selectConversation(
        options.firstWhere((option) => option.id == choice),
      );
    }
  }

  Future<_Conversation> _openDirectConversation(_Contact contact) async {
    final id = await _supabase.rpc(
      'open_direct_conversation',
      params: {'p_peer_id': contact.id},
    );
    await _loadConversations();
    return _conversations.firstWhere((conversation) => conversation.id == id);
  }

  Future<void> _selectConversation(
    _Conversation conversation, {
    bool connectVoice = true,
  }) async {
    if (_selected.id == conversation.id && _chatChannel != null) return;
    final switchId = ++_conversationSwitch;
    _stopTransmission();
    FocusManager.instance.primaryFocus?.unfocus();
    final pendingConnection = _connectionAttempt;
    if (pendingConnection != null) await pendingConnection;
    await _endVoiceSession(updateStatus: false);
    if (!mounted || switchId != _conversationSwitch) return;
    setState(() {
      _selected = conversation;
      _isConnected = false;
      _callFailed = false;
      _status = 'Sincronizando ${conversation.name}...';
    });
    await _subscribeToChat(conversation);
    await _loadMessages(conversation.id);
    if (connectVoice &&
        !kIsWeb &&
        mounted &&
        switchId == _conversationSwitch) {
      _startConnectionAttempt();
    }
  }

  Future<void> _sendChatMessage(
    String text, {
    String color = '#E8EDF2',
  }) async {
    final body = text.trim();
    if (body.isEmpty) return;
    try {
      final message = <String, dynamic>{
        'conversation_id': _selected.id,
        'sender_id': _userId,
        'body': body,
      };
      if (_chatEnhancementsAvailable) message['text_color'] = color;
      await _supabase.from('chat_messages').insert(message);
    } catch (error) {
      _photoNotice('No se pudo enviar el mensaje: $error');
    }
  }

  Future<void> _deleteChatMessage(String messageId) async {
    try {
      await _supabase.from('chat_messages').delete().eq('id', messageId);
      if (!mounted) return;
      setState(() {
        _messages[_selected.id]?.removeWhere((message) => message.id == messageId);
        _messageIds.remove(messageId);
      });
    } catch (error) {
      _photoNotice('No se pudo eliminar el mensaje: $error');
    }
  }

  Future<void> _pinChatMessage(String messageId, bool pin) async {
    try {
      await _supabase.rpc(
        'pin_chat_message',
        params: {'p_message_id': messageId, 'p_pin': pin},
      );
      if (!mounted) return;
      setState(() {
        final messages = _messages[_selected.id];
        if (messages == null) return;
        final index = messages.indexWhere((message) => message.id == messageId);
        if (index >= 0) messages[index] = messages[index].copyWith(isPinned: pin);
      });
    } catch (error) {
      _photoNotice('No se pudo fijar el mensaje: $error');
    }
  }

  Widget _profileAvatar({required double size}) {
    final fallback = widget.isGuest
        ? _DidoLogo(size: size)
        : _Avatar(image: 2, size: size);
    final photo = _profilePhoto ?? _privatePhotoCache[_profilePhotoPath];
    if (photo == null) {
      return fallback;
    }
    return ClipOval(
      child: Image.memory(
        photo,
        width: size,
        height: size,
        fit: BoxFit.cover,
        semanticLabel: 'Foto de perfil',
        errorBuilder: (context, error, stackTrace) => fallback,
      ),
    );
  }

  Future<void> _pickPhoto() async {
    if (_pickingPhoto) return;
    setState(() => _pickingPhoto = true);
    try {
      final file = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 600,
        maxHeight: 600,
        imageQuality: 85,
        requestFullMetadata: false,
      );
      if (!mounted || file == null) return;
      if (await file.length() > 5 * 1024 * 1024) {
        if (mounted) _photoNotice('Elige una imagen de hasta 5 MB.');
        return;
      }
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: 200);
      try {
        final frame = await codec.getNextFrame();
        frame.image.dispose();
      } finally {
        codec.dispose();
      }
      final extension = file.name.split('.').last.toLowerCase();
      final safeExtension = {'jpg', 'jpeg', 'png', 'webp'}.contains(extension)
          ? extension
          : 'jpg';
      final contentType = switch (safeExtension) {
        'png' => 'image/png',
        'webp' => 'image/webp',
        _ => 'image/jpeg',
      };
      final path =
          '$_userId/${DateTime.now().millisecondsSinceEpoch}.$safeExtension';
      await _supabase.storage
          .from(_profilePhotosBucket)
          .uploadBinary(
            path,
            bytes,
            fileOptions: FileOptions(upsert: true, contentType: contentType),
          );
      await _supabase
          .from('profiles')
          .update({'avatar_url': path})
          .eq('id', _userId);
      _privatePhotoCache[path] = bytes;
      if (mounted) {
        setState(() {
          _profilePhoto = bytes;
          _profilePhotoPath = path;
        });
      }
    } catch (error) {
      if (mounted) _photoNotice('No se pudo guardar la foto: $error');
    } finally {
      if (mounted) setState(() => _pickingPhoto = false);
    }
  }

  void _photoNotice(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _editProfile() async {
    var draft = _profileName;
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Editar perfil'),
        content: TextFormField(
          initialValue: draft,
          autofocus: true,
          maxLength: 32,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Nombre'),
          onChanged: (value) => draft = value,
          onFieldSubmitted: (value) =>
              Navigator.of(dialogContext).pop(value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(draft.trim()),
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
    if (mounted && name != null && name.isNotEmpty) {
      try {
        await _supabase
            .from('profiles')
            .update({'display_name': name})
            .eq('id', _userId);
        if (mounted) setState(() => _profileName = name);
        await _loadContacts();
        await _loadConversations();
      } catch (error) {
        _photoNotice('No se pudo actualizar el perfil: $error');
      }
    }
  }

  Future<void> _removeProfilePhoto() async {
    try {
      final path = _profilePhotoPath;
      if (path != null && path.isNotEmpty) {
        await _supabase.storage.from(_profilePhotosBucket).remove([path]);
        _privatePhotoCache.remove(path);
      }
      await _supabase
          .from('profiles')
          .update({'avatar_url': null})
          .eq('id', _userId);
      if (mounted) {
        setState(() {
          _profilePhoto = null;
          _profilePhotoPath = null;
        });
      }
    } catch (error) {
      _photoNotice('No se pudo quitar la foto: $error');
    }
  }
}

const _background = Color(0xFF14171C);
const _panel = Color(0xFF1C2128);
const _surface = Color(0xFF282F38);
const _line = Color(0xFF3B4551);
const _turquoise = Color(0xFF28E3D8);
const _accent = Color(0xFFFF9F67);
const _blue = Color(0xFF69AEFF);
const _ink = Color(0xFFF4F6FA);
const _muted = Color(0xFFB9C3CF);

const _screenHeading = TextStyle(fontSize: 23, fontWeight: FontWeight.w800);
const _sectionHeading = TextStyle(fontSize: 17, fontWeight: FontWeight.w800);

OutlineInputBorder _fieldBorder(Color color) => OutlineInputBorder(
  borderRadius: BorderRadius.circular(13),
  borderSide: BorderSide(color: color),
);

class _AppWidth extends StatelessWidget {
  const _AppWidth({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Align(
      widthFactor: 1,
      heightFactor: 1,
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: SizedBox(width: double.infinity, child: child),
      ),
    );
  }
}

class _AccessScreen extends StatefulWidget {
  const _AccessScreen();

  @override
  State<_AccessScreen> createState() => _AccessScreenState();
}

class _AccessScreenState extends State<_AccessScreen> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _hidePassword = true;
  bool _openingRoom = false;
  String? _accessMessage;
  bool _accessMessageIsError = false;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _enter({
    required bool asGuest,
    bool createAccount = false,
  }) async {
    if (_openingRoom) return;
    if (!asGuest && !_form.currentState!.validate()) return;
    setState(() {
      _openingRoom = true;
      _accessMessage = 'Conectando con Supabase…';
      _accessMessageIsError = false;
    });
    FocusManager.instance.primaryFocus?.unfocus();
    try {
      final auth = Supabase.instance.client.auth;
      if (asGuest) {
        if (auth.currentUser?.isAnonymous != true) {
          if (auth.currentSession != null) await auth.signOut();
          await auth.signInAnonymously(
            data: const {'display_name': 'Invitado'},
          );
        }
      } else {
        if (auth.currentSession != null) await auth.signOut();
        final email = _email.text.trim();
        final password = _password.text;
        if (createAccount) {
          final response = await auth.signUp(
            email: email,
            password: password,
            data: {'display_name': email.split('@').first},
          );
          if (response.session == null) {
            _setAccessMessage(
              'Cuenta creada. Confirma el correo desde el enlace enviado y después inicia sesión.',
            );
            return;
          }
        } else {
          await auth.signInWithPassword(email: email, password: password);
        }
      }

      final user = auth.currentUser!;
      if (!mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (context) => WalkieTalkieScreen(
            profileName:
                user.userMetadata?['display_name'] as String? ??
                (user.isAnonymous
                    ? 'Invitado'
                    : user.email?.split('@').first ?? 'Usuario'),
            isGuest: user.isAnonymous,
          ),
        ),
      );
    } on AuthException catch (error) {
      _setAccessMessage(accessErrorMessage(error), isError: true);
    } catch (error) {
      _setAccessMessage(accessErrorMessage(error), isError: true);
    } finally {
      if (mounted) {
        setState(() {
          _openingRoom = false;
          if (_accessMessage == 'Conectando con Supabase…') {
            _accessMessage = null;
          }
        });
      }
    }
  }

  void _setAccessMessage(String message, {bool isError = false}) {
    if (!mounted) return;
    setState(() {
      _accessMessage = message;
      _accessMessageIsError = isError;
    });
  }

  @override
  Widget build(BuildContext context) {
    const shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(13)),
    );
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: _AppWidth(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(22, 24, 22, 24),
              child: Form(
                key: _form,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Center(child: _DidoLogo(size: 138)),
                    const SizedBox(height: 12),
                    const Text(
                      'Dido Live',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 39,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 38),
                    TextFormField(
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        hintText: 'Correo electrónico',
                        prefixIcon: Icon(Icons.mail_outline_rounded),
                      ),
                      validator: (value) {
                        final email = value?.trim() ?? '';
                        return RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$')
                                .hasMatch(email)
                            ? null
                            : 'Escribe un correo de prueba válido.';
                      },
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _password,
                      obscureText: _hidePassword,
                      autocorrect: false,
                      enableSuggestions: false,
                      textInputAction: TextInputAction.done,
                      onFieldSubmitted: (_) => _enter(asGuest: false),
                      decoration: InputDecoration(
                        hintText: 'Contraseña',
                        prefixIcon: const Icon(Icons.lock_outline_rounded),
                        suffixIcon: IconButton(
                          tooltip: _hidePassword
                              ? 'Mostrar contraseña'
                              : 'Ocultar contraseña',
                          icon: Icon(
                            _hidePassword
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                          ),
                          onPressed: () =>
                              setState(() => _hidePassword = !_hidePassword),
                        ),
                      ),
                      validator: (value) => value == null || value.isEmpty
                          ? 'Escribe una contraseña de prueba.'
                          : null,
                    ),
                    const SizedBox(height: 25),
                    FilledButton(
                      onPressed: _openingRoom
                          ? null
                          : () => _enter(asGuest: false),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(53),
                        shape: shape,
                        textStyle: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      child: Text(
                        _openingRoom ? 'Conectando…' : 'Iniciar sesión',
                      ),
                    ),
                    const SizedBox(height: 14),
                    OutlinedButton(
                      onPressed: _openingRoom
                          ? null
                          : () => _enter(asGuest: true),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(50),
                        foregroundColor: _ink,
                        side: const BorderSide(color: _muted),
                        shape: shape,
                        textStyle: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      child: Text(
                        _openingRoom ? 'Conectando…' : 'Entrar como invitado',
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: _openingRoom
                          ? null
                          : () => _enter(asGuest: false, createAccount: true),
                      child: const Text('Crear cuenta'),
                    ),
                    if (_accessMessage != null) ...[
                      const SizedBox(height: 12),
                      if (_openingRoom) const LinearProgressIndicator(),
                      const SizedBox(height: 8),
                      Text(
                        _accessMessage!,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: _accessMessageIsError ? _accent : _muted,
                          fontSize: 13,
                        ),
                      ),
                    ],
                    const SizedBox(height: 14),
                    const Text(
                      'Acceso de prueba. Usa datos ficticios.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: _muted, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DidoLogo extends StatelessWidget {
  const _DidoLogo({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      image: true,
      label: 'Logotipo de Dido Live',
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(size * 0.22),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF252C35), Color(0xFF191E25)],
          ),
          border: Border.all(color: const Color(0xFF2A3039)),
        ),
        padding: EdgeInsets.all(size * 0.19),
        child: const CustomPaint(painter: _DidoMark()),
      ),
    );
  }
}

class _DidoMark extends CustomPainter {
  const _DidoMark();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 100, size.height / 100);
    final letter = Path()
      ..moveTo(5, 4)
      ..lineTo(44, 4)
      ..cubicTo(72, 4, 94, 24, 94, 50)
      ..cubicTo(94, 76, 72, 96, 44, 96)
      ..lineTo(5, 96)
      ..close();
    canvas.drawPath(letter, Paint()..color = _turquoise);
    const bars = [14.0, 24.0, 35.0, 48.0, 35.0, 24.0, 14.0];
    final wave = Paint()
      ..color = _background
      ..strokeWidth = 5.4
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < bars.length; i++) {
      final x = 18 + 9.0 * i;
      final half = bars[i] / 2;
      canvas.drawLine(Offset(x, 50 - half), Offset(x, 50 + half), wave);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _DidoMark oldDelegate) => false;
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.active});

  final bool active;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: active ? _turquoise : _muted,
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.image, this.imageBytes, this.size = 40});

  final int image;
  final Uint8List? imageBytes;
  final double size;

  static final _images = _avatarPhotos
      .map(base64Decode)
      .toList(growable: false);

  @override
  Widget build(BuildContext context) {
    final bytes = imageBytes;
    if (bytes != null) {
      return ClipOval(
        child: Image.memory(
          bytes,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) => _fallbackAvatar(),
        ),
      );
    }
    return _fallbackAvatar();
  }

  Widget _fallbackAvatar() {
    return ClipOval(
      child: Image.memory(
        _images[image],
        width: size,
        height: size,
        fit: BoxFit.cover,
        excludeFromSemantics: true,
      ),
    );
  }
}

class _UserRow extends StatelessWidget {
  const _UserRow({
    required this.name,
    required this.image,
    required this.subtitle,
    this.imageBytes,
    this.avatar,
    this.active = false,
    this.transmitting = false,
  });

  final String name;
  final int image;
  final String subtitle;
  final Uint8List? imageBytes;
  final Widget? avatar;
  final bool active;
  final bool transmitting;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 7),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: _line)),
      ),
      child: Row(
        children: [
          avatar ?? _Avatar(image: image, imageBytes: imageBytes),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: const TextStyle(fontWeight: FontWeight.w700)),
                Row(
                  children: [
                    _StatusDot(active: active),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        subtitle,
                        style: const TextStyle(color: _muted, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Icon(
            transmitting ? Icons.graphic_eq_rounded : Icons.mic_none_rounded,
            color: transmitting ? _turquoise : _muted,
            semanticLabel: transmitting ? 'Transmitiendo' : null,
            size: 20,
          ),
        ],
      ),
    );
  }
}

enum _Scope {
  general('General', Icons.public_rounded),
  group('Grupos', Icons.groups_outlined),
  personal('Personales', Icons.person_outline_rounded);

  const _Scope(this.label, this.icon);

  final String label;
  final IconData icon;
}

class _Contact {
  const _Contact(
    this.id,
    this.name,
    this.avatar, [
    this.avatarPath,
    this.avatarBytes,
  ]);

  final String id;
  final String name;
  final int avatar;
  final String? avatarPath;
  final Uint8List? avatarBytes;
}

class _Conversation {
  const _Conversation(this.id, this.name, this.scope, this.contacts);

  final String id;
  final String name;
  final _Scope scope;
  // La persona que inició sesión está incluida de forma implícita.
  final List<_Contact> contacts;
}

const _general = _Conversation('general', 'Canal general', _Scope.general, []);

BoxDecoration _panelDecoration() => BoxDecoration(
  color: _panel,
  borderRadius: BorderRadius.circular(13),
  border: Border.all(color: _line),
);

String _newUuid() {
  final bytes = List<int>.generate(16, (_) => Random.secure().nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

class _CreateGroupDialog extends StatefulWidget {
  const _CreateGroupDialog({required this.id, required this.contacts});

  final String id;
  final List<_Contact> contacts;

  @override
  State<_CreateGroupDialog> createState() => _CreateGroupDialogState();
}

class _CreateGroupDialogState extends State<_CreateGroupDialog> {
  String _name = '';
  final _members = <_Contact>{};

  @override
  Widget build(BuildContext context) {
    final ready = _name.isNotEmpty && _members.isNotEmpty;
    return AlertDialog(
      title: const Text('Nuevo grupo'),
      scrollable: true,
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              textCapitalization: TextCapitalization.sentences,
              maxLength: 40,
              decoration: const InputDecoration(labelText: 'Nombre del grupo'),
              onChanged: (value) => setState(() => _name = value.trim()),
            ),
            const Text(
              'Tú ya estás incluido. Agrega al menos un contacto.',
              style: TextStyle(color: _muted, fontSize: 13),
            ),
            for (final contact in widget.contacts)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(contact.name),
                secondary: _Avatar(
                  image: contact.avatar,
                  imageBytes: contact.avatarBytes,
                  size: 34,
                ),
                value: _members.contains(contact),
                onChanged: (checked) => setState(() {
                  if (checked == true) {
                    _members.add(contact);
                  } else {
                    _members.remove(contact);
                  }
                }),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: ready
              ? () => Navigator.of(context).pop(
                  _Conversation(
                    widget.id,
                    _name,
                    _Scope.group,
                    List.unmodifiable(_members),
                  ),
                )
              : null,
          child: const Text('Crear'),
        ),
      ],
    );
  }
}

class _Message {
  const _Message({
    required this.id,
    required this.senderId,
    required this.sender,
    required this.text,
    required this.time,
    required this.isMine,
    this.textColor = '#E8EDF2',
    this.isPinned = false,
    this.avatarBytes,
  });

  final String id;
  final String senderId;
  final String sender;
  final String text;
  final String time;
  final Uint8List? avatarBytes;
  final bool isMine;
  final String textColor;
  final bool isPinned;

  _Message copyWith({bool? isPinned}) => _Message(
    id: id,
    senderId: senderId,
    sender: sender,
    text: text,
    time: time,
    isMine: isMine,
    avatarBytes: avatarBytes,
    textColor: textColor,
    isPinned: isPinned ?? this.isPinned,
  );
}

class _ChannelChat extends StatefulWidget {
  const _ChannelChat({
    super.key,
    required this.messages,
    required this.onSend,
    required this.onDelete,
    required this.onPin,
  });

  final List<_Message> messages;
  final void Function(String text, String color) onSend;
  final ValueChanged<String> onDelete;
  final void Function(String id, bool pin) onPin;

  @override
  State<_ChannelChat> createState() => _ChannelChatState();
}

class _ChannelChatState extends State<_ChannelChat> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  String _textColor = '#E8EDF2';

  static const _colors = <String, String>{
    '#E8EDF2': 'Blanco',
    '#50E3D2': 'Turquesa',
    '#FFB86B': 'Naranja',
    '#A9C6FF': 'Azul',
    '#E6A8FF': 'Lila',
  };

  void _send() {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    widget.onSend(text, _textColor);
    _input.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _insertEmoji() async {
    final token = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Align(
                alignment: Alignment.centerLeft,
                child: Text('Dido Retro', style: _sectionHeading),
              ),
              const SizedBox(height: 12),
              Flexible(
                child: GridView.builder(
                  shrinkWrap: true,
                  itemCount: DidoRetro.emojis.length,
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 3,
                        childAspectRatio: 2.5,
                        crossAxisSpacing: 8,
                        mainAxisSpacing: 8,
                      ),
                  itemBuilder: (context, index) {
                    final emoji = DidoRetro.emojis[index];
                    return InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => Navigator.pop(context, emoji.token),
                      child: Container(
                        decoration: BoxDecoration(
                          color: _surface,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: _line),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: Row(
                          children: [
                            DidoRetro.image(emoji, size: 31),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                emoji.label,
                                maxLines: 2,
                                style: const TextStyle(fontSize: 10),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || token == null) return;
    final value = _input.value;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : value.text.length;
    final end = selection.isValid ? selection.end : value.text.length;
    final nextText = value.text.replaceRange(start, end, token);
    _input.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: start + token.length),
    );
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _Message? pinned;
    for (final message in widget.messages) {
      if (message.isPinned) {
        pinned = message;
        break;
      }
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Mensajes sincronizados · ${widget.messages.length}',
              style: TextStyle(color: _muted, fontSize: 12),
            ),
          ),
        ),
        if (pinned != null)
          Container(
            margin: const EdgeInsets.fromLTRB(20, 8, 20, 0),
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(
              color: const Color(0xFF2C353F),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                const Icon(Icons.push_pin_rounded, color: _accent, size: 16),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    pinned.text,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        Expanded(
          child: widget.messages.isEmpty
              ? const Center(
                  child: Text(
                    'Aún no hay mensajes.',
                    style: TextStyle(color: _muted),
                  ),
                )
              : ListView.separated(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(20, 13, 20, 16),
                  itemCount: widget.messages.length,
                  separatorBuilder: (context, index) =>
                      const SizedBox(height: 15),
                  itemBuilder: (context, index) => _ChatBubble(
                    message: widget.messages[index],
                    onDelete: widget.onDelete,
                    onPin: widget.onPin,
                  ),
                ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 14),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Dido Retro',
                onPressed: _insertEmoji,
                icon: const Icon(Icons.emoji_emotions_outlined),
              ),
              PopupMenuButton<String>(
                tooltip: 'Color de letra',
                initialValue: _textColor,
                onSelected: (color) => setState(() => _textColor = color),
                itemBuilder: (context) => [
                  for (final entry in _colors.entries)
                    PopupMenuItem(
                      value: entry.key,
                      child: Row(
                        children: [
                          Container(
                            width: 15,
                            height: 15,
                            decoration: BoxDecoration(
                              color: _colorFromHex(entry.key),
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(entry.value),
                        ],
                      ),
                    ),
                ],
                icon: Icon(
                  Icons.format_color_text_rounded,
                  color: _colorFromHex(_textColor),
                ),
              ),
              Expanded(
                child: TextField(
                  controller: _input,
                  textInputAction: TextInputAction.send,
                  maxLength: 500,
                  onSubmitted: (_) => _send(),
                  decoration: const InputDecoration(
                    hintText: 'Escribe un mensaje',
                    counterText: '',
                  ),
                ),
              ),
              const SizedBox(width: 10),
              IconButton.filled(
                tooltip: 'Enviar mensaje',
                onPressed: _send,
                style: IconButton.styleFrom(
                  minimumSize: const Size(48, 48),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                icon: const Icon(Icons.send_rounded),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ChatBubble extends StatelessWidget {
  const _ChatBubble({
    required this.message,
    required this.onDelete,
    required this.onPin,
  });

  final _Message message;
  final ValueChanged<String> onDelete;
  final void Function(String id, bool pin) onPin;

  @override
  Widget build(BuildContext context) {
    final mine = message.isMine;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!mine) ...[
          _Avatar(image: 0, imageBytes: message.avatarBytes),
          const SizedBox(width: 11),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: mine
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.start,
            children: [
              Text(
                message.sender,
                style: TextStyle(
                  color: mine ? _turquoise : _ink,
                  fontWeight: FontWeight.w800,
                  fontSize: 13,
                ),
              ),
              if (message.isPinned)
                const Padding(
                  padding: EdgeInsets.only(top: 2),
                  child: Text(
                    'Aviso fijado',
                    style: TextStyle(color: _accent, fontSize: 10),
                  ),
                ),
              const SizedBox(height: 5),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 330),
                child: Container(
                  padding: const EdgeInsets.fromLTRB(13, 10, 13, 7),
                  decoration: BoxDecoration(
                    gradient: mine
                        ? const LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [Color(0xFF174653), Color(0xFF12343F)],
                          )
                        : null,
                    color: mine ? null : _surface,
                    borderRadius: BorderRadius.only(
                      topLeft: const Radius.circular(16),
                      topRight: const Radius.circular(16),
                      bottomLeft: Radius.circular(mine ? 16 : 5),
                      bottomRight: Radius.circular(mine ? 5 : 16),
                    ),
                    border: Border.all(
                      color: mine
                          ? _turquoise.withValues(alpha: 0.26)
                          : _line,
                    ),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x16000000),
                        blurRadius: 8,
                        offset: Offset(0, 3),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text.rich(
                        TextSpan(
                          children: DidoRetro.messageSpans(
                            message.text,
                            style: TextStyle(
                              color: _colorFromHex(message.textColor),
                              height: 1.32,
                            ),
                          ),
                        ),
                        style: const TextStyle(fontSize: 15),
                      ),
                      const SizedBox(height: 5),
                      Align(
                        alignment: Alignment.centerRight,
                        child: Text(
                          message.time,
                          style: const TextStyle(
                            color: _muted,
                            fontSize: 10,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        if (mine)
          PopupMenuButton<String>(
            tooltip: 'Acciones del mensaje',
            onSelected: (action) {
              if (action == 'delete') onDelete(message.id);
              if (action == 'pin') onPin(message.id, !message.isPinned);
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'pin',
                child: Text(message.isPinned ? 'Desfijar' : 'Fijar mensaje'),
              ),
              const PopupMenuItem(
                value: 'delete',
                child: Text('Eliminar mensaje'),
              ),
            ],
            icon: const Icon(Icons.more_vert, color: _muted, size: 19),
          ),
      ],
    );
  }
}

Color _colorFromHex(String value) =>
    Color(int.parse(value.substring(1), radix: 16) | 0xFF000000);

// Retratos de muestra incluidos para poder pegar este archivo sin assets.
const _avatarPhotos = [
  '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'
      'R+0pB4PWtMVmsVfCB//Z',
];
