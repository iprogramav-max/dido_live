import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _supabaseUrl = 'https://bgmdndjcwkonqrzttvlb.supabase.co';
const _supabaseAnonKey =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImJnbWRuZGpjd2tvbnFyenR0dmxiIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTQ5Mzc5MzUsImV4cCI6MjExMDUxMzkzNX0.9Y8eFR45p3hZXrDaOzRd-tBrcn8TFQyF6yQIKywCjIs';
const _roomId = 'c0a80101-0000-4000-8000-000000000001';

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

class WalkieTalkieScreen extends StatefulWidget {
  const WalkieTalkieScreen({
    super.key,
    this.requestMicrophonePermission = _requestMicrophonePermission,
    this.profileName = 'Ana Torres',
    this.isGuest = false,
    this.legacyOnly = false,
  });

  final MicrophonePermissionRequest requestMicrophonePermission;
  final String profileName;
  final bool isGuest;
  final bool legacyOnly;

  @override
  State<WalkieTalkieScreen> createState() => _WalkieTalkieScreenState();
}

class _WalkieTalkieScreenState extends State<WalkieTalkieScreen>
    with WidgetsBindingObserver {
  late final SupabaseClient _supabase = Supabase.instance.client;
  final List<RTCIceCandidate> _pendingLocalCandidates = [];
  final List<Map<String, dynamic>> _pendingRemoteCandidates = [];
  final Set<String> _seenRemoteCandidateIds = {};

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
  bool _callFailed = false;
  bool _isConnected = false;
  Future<void>? _connectionAttempt;
  int _tab = 0;
  late String _profileName = widget.profileName;
  bool _notifications = true;
  bool _pttSound = true;
  int? _pttPointer;
  Uint8List? _profilePhoto;
  bool _pickingPhoto = false;
  final _conversations = <_Conversation>[
    _general,
    const _Conversation(
      'group-demo',
      'Equipo de operaciones',
      _Scope.group,
      _contacts,
    ),
  ];
  _Conversation _selected = _general;
  int _nextGroup = 1;
  final _messages = <String, List<_Message>>{
    _general.id: const [
      _Message('Lucía Vega', '¿Me escuchan?', '10:20', avatar: 0),
      _Message('Mateo Ruiz', 'Sí, fuerte y claro.', '10:21', avatar: 1),
      _Message('Lucía Vega', 'Seguimos por aquí.', '10:23', avatar: 0),
    ],
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.legacyOnly) _startConnectionAttempt();
  }

  void _startConnectionAttempt() {
    if (_isInitializing || _callFailed) return;
    _connectionAttempt = _requestPermissionAndConnect();
  }

  Future<void> _requestPermissionAndConnect() async {
    if (_isRequestingPermission || _isInitializing || _callFailed) return;
    _isRequestingPermission = true;
    _isInitializing = true;

    try {
      final permission = await widget.requestMicrophonePermission();
      if (!mounted) return;
      if (!permission.isGranted) {
        setState(() {
          _status = permission.isPermanentlyDenied
              ? 'Permiso bloqueado. Habilítalo en Ajustes.'
              : 'Se necesita permiso de micrófono para conectarse.';
        });
        return;
      }

      setState(() => _status = 'Conectando a la sala...');
      await _connectToRoom();
    } catch (error) {
      _showError(error);
    } finally {
      _isRequestingPermission = false;
      _isInitializing = false;
    }
  }

  Future<void> _connectToRoom() async {
    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': false,
    });
    if (!mounted) return;
    final audioTracks = _localStream!.getAudioTracks();
    if (audioTracks.isEmpty) {
      throw StateError('No se pudo obtener una pista de audio del micrófono.');
    }
    _localAudioTrack = audioTracks.first..enabled = false;

    await _createPeerConnection();
    if (!mounted) return;
    await _subscribeToRoom();
    if (!mounted) return;

    final room = await _loadRoom();
    if (!mounted) return;
    if (room == null) {
      await _createRoomAsCaller();
    } else {
      await _joinRoomAsCallee(room);
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
    connection.onIceCandidate = (candidate) {
      unawaited(_handleLocalCandidate(connection, candidate));
    };
    connection.onConnectionState = (state) {
      if (!mounted) return;
      final connectionState = state.toString().split('.').last;
      if (connectionState == 'RTCPeerConnectionStateConnected' ||
          connectionState == 'connected') {
        setState(() {
          _isConnected = true;
          _status = 'Conectado';
        });
      } else if (connectionState == 'RTCPeerConnectionStateFailed' ||
          connectionState == 'failed') {
        setState(() {
          _isConnected = false;
          _status = 'Falló la conexión WebRTC.';
        });
      } else if (connectionState == 'RTCPeerConnectionStateDisconnected' ||
          connectionState == 'disconnected') {
        setState(() {
          _isConnected = false;
          _status = 'Conexión interrumpida; intentando recuperar...';
        });
      }
    };
  }

  Future<void> _subscribeToRoom() async {
    final ready = Completer<void>();
    final channel = _supabase.channel('webrtc-room-$_roomId');
    _channel = channel
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'webrtc_rooms',
        filter: const PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'id',
          value: _roomId,
        ),
        callback: (payload) {
          unawaited(_runSafely(() => _handleRoomChange(payload.newRecord)));
        },
      )
      ..onPostgresChanges(
        event: PostgresChangeEvent.insert,
        schema: 'public',
        table: 'webrtc_ice_candidates',
        filter: const PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'room_id',
          value: _roomId,
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

  Future<Map<String, dynamic>?> _loadRoom() async {
    final room = await _supabase
        .from('webrtc_rooms')
        .select()
        .eq('id', _roomId)
        .maybeSingle();
    return room;
  }

  Future<void> _createRoomAsCaller() async {
    _role = 'caller';
    final offer = await _peerConnection!.createOffer({
      'offerToReceiveAudio': true,
    });
    await _peerConnection!.setLocalDescription(offer);
    final localDescription = await _peerConnection!.getLocalDescription();
    if (localDescription == null) {
      throw StateError('WebRTC no generó la oferta local.');
    }

    try {
      await _supabase.from('webrtc_rooms').insert({
        'id': _roomId,
        'offer': localDescription.toMap(),
        'status': 'waiting',
      });
    } on PostgrestException catch (error) {
      if (error.code != '23505') rethrow;

      await _replacePeerConnection();
      final existingRoom = await _loadRoom();
      if (existingRoom == null) {
        throw StateError('La sala desapareció durante la conexión.');
      }
      await _joinRoomAsCallee(existingRoom);
      return;
    }

    _roomIsPublished = true;
    await _flushLocalCandidates();
    if (mounted) setState(() => _status = 'Esperando al otro dispositivo...');
  }

  Future<void> _joinRoomAsCallee(Map<String, dynamic> room) async {
    if (room['answer'] != null || room['status'] != 'waiting') {
      throw const _LegacyRoomAlreadyUsed();
    }

    _role = 'callee';
    _roomIsPublished = true;
    final offer = _descriptionFromJson(room['offer'], 'offer');
    await _peerConnection!.setRemoteDescription(offer);
    _remoteDescriptionIsSet = true;
    await _loadExistingRemoteCandidates();
    await _flushRemoteCandidates();

    final answer = await _peerConnection!.createAnswer({
      'offerToReceiveAudio': true,
    });
    await _peerConnection!.setLocalDescription(answer);
    final localDescription = await _peerConnection!.getLocalDescription();
    if (localDescription == null) {
      throw StateError('WebRTC no generó la respuesta local.');
    }

    await _supabase
        .from('webrtc_rooms')
        .update({'answer': localDescription.toMap(), 'status': 'answered'})
        .eq('id', _roomId);
    await _flushLocalCandidates();
    if (mounted && !_isConnected) {
      setState(() => _status = 'Respuesta enviada; conectando...');
    }
  }

  Future<void> _replacePeerConnection() async {
    final oldConnection = _peerConnection;
    _peerConnection = null;
    if (oldConnection != null) await oldConnection.close();

    _pendingLocalCandidates.clear();
    _pendingRemoteCandidates.clear();
    _seenRemoteCandidateIds.clear();
    _remoteDescriptionIsSet = false;
    await _createPeerConnection();
    _role = 'callee';
    _roomIsPublished = true;
  }

  Future<void> _handleRoomChange(Map<String, dynamic> record) async {
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

    if (_role == null || !_roomIsPublished) {
      _pendingLocalCandidates.add(candidate);
      return;
    }
    await _insertLocalCandidate(candidate);
  }

  Future<void> _insertLocalCandidate(RTCIceCandidate candidate) async {
    final role = _role;
    if (role == null) return;
    await _supabase.from('webrtc_ice_candidates').insert({
      'room_id': _roomId,
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
    if (_role != null && record['sender'] == _role) return;

    if (_role == null || !_remoteDescriptionIsSet) {
      _pendingRemoteCandidates.add(record);
      return;
    }
    await _addRemoteCandidate(record);
  }

  Future<void> _loadExistingRemoteCandidates() async {
    final role = _role;
    if (role == null) return;
    final candidates = await _supabase
        .from('webrtc_ice_candidates')
        .select()
        .eq('room_id', _roomId)
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
    setState(() {
      _callFailed = true;
      _isConnected = false;
      _isTransmitting = false;
      _localAudioTrack?.enabled = false;
      _status = error is _LegacyRoomAlreadyUsed
          ? 'La sala de pruebas ya se usó. Hace falta iniciar una sesión de voz nueva.'
          : 'Error: $error';
    });
  }

  void _startTransmission() {
    if (_localAudioTrack == null) {
      _startConnectionAttempt();
      return;
    }
    if (_callFailed) return;
    _localAudioTrack!.enabled = true;
    setState(() => _isTransmitting = true);
  }

  void _stopTransmission() {
    _pttPointer = null;
    _localAudioTrack?.enabled = false;
    if (mounted && _isTransmitting) {
      setState(() => _isTransmitting = false);
    }
  }

  Future<void> _disposeCall() async {
    final pending = _connectionAttempt;
    if (pending != null) await pending;
    final channel = _channel;
    if (channel != null) {
      await _supabase.removeChannel(channel);
    }
    final connection = _peerConnection;
    if (connection != null) {
      await connection.close();
      await connection.dispose();
    }
    final stream = _localStream;
    if (stream != null) await stream.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _stopTransmission();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _localAudioTrack?.enabled = false;
    unawaited(_disposeCall());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.legacyOnly) {
      return Scaffold(
        appBar: AppBar(title: const Text('Prueba WebRTC')),
        body: SafeArea(child: _AppWidth(child: _buildVoice())),
      );
    }
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
                if (_tab == 0 && _selected.scope == _Scope.general) ...[
                  const Spacer(),
                  IconButton(
                    tooltip: 'Prueba WebRTC',
                    onPressed: _openLegacyVoiceTest,
                    icon: const Icon(Icons.settings_input_antenna_rounded),
                  ),
                ],
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
                      onSend: _sendChatMessage,
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
    final legacy = widget.legacyOnly;
    final permissionBlocked = legacy && _status.startsWith('Permiso bloqueado');
    final status = legacy
        ? (_isTransmitting ? 'Transmitiendo…' : _status)
        : (_isTransmitting
              ? 'Transmitiendo · Simulación'
              : 'Voz de prueba · Simulación local');

    return LayoutBuilder(
      builder: (context, constraints) {
        final buttonSize = (constraints.maxWidth * 0.44)
            .clamp(110.0, 182.0)
            .toDouble();
        return ListView(
          padding: const EdgeInsets.fromLTRB(20, 15, 20, 14),
          children: [
            if (legacy)
              const Text(
                'Sala de pruebas de dos dispositivos',
                style: _screenHeading,
              )
            else
              _channelSelector(),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: _StatusDot(active: _isConnected || _isTransmitting),
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
                        (legacy && _callFailed)) {
                      return;
                    }
                    _pttPointer = event.pointer;
                    if (legacy) {
                      _startTransmission();
                    } else {
                      setState(() => _isTransmitting = true);
                    }
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
                      border: Border.all(color: _turquoise, width: 2.5),
                      boxShadow: [
                        if (_isTransmitting)
                          const BoxShadow(
                            color: Color(0x4034E5D3),
                            blurRadius: 20,
                          ),
                      ],
                    ),
                    child: DecoratedBox(
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [Color(0xFF3DF7E5), Color(0xFF19CECB)],
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
              _isTransmitting
                  ? 'Suelta para escuchar'
                  : 'Mantén presionado para hablar',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            if (permissionBlocked)
              TextButton(
                onPressed: openAppSettings,
                child: const Text('Abrir Ajustes'),
              ),
            if (!legacy) ...[
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                decoration: _panelDecoration(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Participantes de muestra',
                      style: _sectionHeading,
                    ),
                    for (final contact in _selected.contacts)
                      _UserRow(
                        name: contact.name,
                        image: contact.avatar,
                        subtitle: 'Contacto de muestra',
                      ),
                    _UserRow(
                      name: _profileName,
                      image: 2,
                      avatar: _profileAvatar(size: 40),
                      subtitle: widget.isGuest ? 'Invitado · Tú' : 'Tú',
                      active: _isTransmitting,
                      transmitting: _isTransmitting,
                    ),
                  ],
                ),
              ),
            ],
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
            onTap: _pickingPhoto
                ? null
                : () => setState(() => _profilePhoto = null),
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
      _selectConversation(_general);
      return;
    }
    final personal = scope == _Scope.personal;
    final options = personal
        ? [
            for (final contact in _contacts)
              _Conversation('personal-${contact.id}', contact.name, scope, [
                contact,
              ]),
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
              for (final option in options)
                ListTile(
                  leading: personal
                      ? _Avatar(image: option.contacts.single.avatar, size: 34)
                      : const Icon(Icons.groups_outlined),
                  title: Text(option.name),
                  subtitle: personal
                      ? null
                      : Text('${option.contacts.length + 1} participantes'),
                  trailing: option.id == _selected.id
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
        builder: (_) => _CreateGroupDialog(id: 'group-$_nextGroup'),
      );
      if (!mounted || group == null) return;
      _nextGroup++;
      _conversations.add(group);
      _selectConversation(group);
      return;
    }
    _selectConversation(options.firstWhere((option) => option.id == choice));
  }

  void _selectConversation(_Conversation conversation) {
    if (_selected.id == conversation.id) return;
    _stopTransmission();
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _selected = conversation);
  }

  void _sendChatMessage(String text) {
    final time = TimeOfDay.now().format(context);
    final id = _selected.id;
    setState(() {
      _messages[id] = [...?_messages[id], _Message(_profileName, text, time)];
    });
  }

  Future<void> _openLegacyVoiceTest() async {
    _stopTransmission();
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => WalkieTalkieScreen(
          requestMicrophonePermission: widget.requestMicrophonePermission,
          legacyOnly: true,
        ),
      ),
    );
  }

  Widget _profileAvatar({required double size}) {
    final fallback = widget.isGuest
        ? _DidoLogo(size: size)
        : _Avatar(image: 2, size: size);
    final photo = _profilePhoto;
    if (photo == null) return fallback;
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
      if (mounted) setState(() => _profilePhoto = bytes);
    } catch (_) {
      if (mounted)
        _photoNotice(
          'No se pudo abrir la imagen. Prueba con una foto JPG o PNG.',
        );
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
      setState(() => _profileName = name);
    }
  }
}

const _background = Color(0xFF14171C);
const _panel = Color(0xFF1C2128);
const _surface = Color(0xFF282F38);
const _line = Color(0xFF3B4551);
const _turquoise = Color(0xFF28E3D8);
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
  bool _hidePassword = true;
  bool _openingRoom = false;

  Future<void> _enter({required bool asGuest}) async {
    if (_openingRoom) return;
    if (!asGuest && !_form.currentState!.validate()) return;
    _openingRoom = true;
    _form.currentState!.reset();
    FocusManager.instance.primaryFocus?.unfocus();
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (context) => WalkieTalkieScreen(
            profileName: asGuest ? 'Invitado' : 'Ana Torres',
            isGuest: asGuest,
          ),
        ),
      );
    } finally {
      _openingRoom = false;
    }
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
                      onPressed: () => _enter(asGuest: false),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(53),
                        shape: shape,
                        textStyle: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      child: const Text('Iniciar sesión'),
                    ),
                    const SizedBox(height: 14),
                    OutlinedButton(
                      onPressed: () => _enter(asGuest: true),
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
                      child: const Text('Entrar como invitado'),
                    ),
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
  const _Avatar({required this.image, this.size = 40});

  final int image;
  final double size;

  static final _images = _avatarPhotos
      .map(base64Decode)
      .toList(growable: false);

  @override
  Widget build(BuildContext context) {
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
    this.avatar,
    this.active = false,
    this.transmitting = false,
  });

  final String name;
  final int image;
  final String subtitle;
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
          avatar ?? _Avatar(image: image),
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
  const _Contact(this.id, this.name, this.avatar);

  final String id;
  final String name;
  final int avatar;
}

const _contacts = [
  _Contact('lucia', 'Lucía Vega', 0),
  _Contact('mateo', 'Mateo Ruiz', 1),
];

class _Conversation {
  const _Conversation(this.id, this.name, this.scope, this.contacts);

  final String id;
  final String name;
  final _Scope scope;
  // La persona que inició sesión está incluida de forma implícita.
  final List<_Contact> contacts;
}

const _general = _Conversation(
  'general',
  'Canal general',
  _Scope.general,
  _contacts,
);

class _LegacyRoomAlreadyUsed implements Exception {
  const _LegacyRoomAlreadyUsed();
}

BoxDecoration _panelDecoration() => BoxDecoration(
  color: _panel,
  borderRadius: BorderRadius.circular(13),
  border: Border.all(color: _line),
);

class _CreateGroupDialog extends StatefulWidget {
  const _CreateGroupDialog({required this.id});

  final String id;

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
            for (final contact in _contacts)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(contact.name),
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
  const _Message(this.sender, this.text, this.time, {this.avatar});

  final String sender;
  final String text;
  final String time;
  final int? avatar;
}

class _ChannelChat extends StatefulWidget {
  const _ChannelChat({super.key, required this.messages, required this.onSend});

  final List<_Message> messages;
  final ValueChanged<String> onSend;

  @override
  State<_ChannelChat> createState() => _ChannelChatState();
}

class _ChannelChatState extends State<_ChannelChat> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  void _send() {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    widget.onSend(text);
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

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 12, 20, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Chat de prueba · Solo en este dispositivo',
              style: TextStyle(color: _muted, fontSize: 12),
            ),
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
                  itemBuilder: (context, index) =>
                      _ChatBubble(message: widget.messages[index]),
                ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 14),
          child: Row(
            children: [
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
  const _ChatBubble({required this.message});

  final _Message message;

  @override
  Widget build(BuildContext context) {
    final avatar = message.avatar;
    final mine = avatar == null;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!mine) ...[_Avatar(image: avatar), const SizedBox(width: 11)],
        Expanded(
          child: Column(
            crossAxisAlignment: mine
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.start,
            children: [
              Text(
                message.sender,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 5),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: mine ? const Color(0xFF153A47) : _surface,
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Text.rich(
                  TextSpan(
                    text: message.text,
                    children: [
                      TextSpan(
                        text: '  ${message.time}',
                        style: const TextStyle(color: _muted, fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// Retratos de muestra incluidos para poder pegar este archivo sin assets.
const _avatarPhotos = [
  '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'
      'R+0pB4PWtMVmsVfCB//Z',
];
