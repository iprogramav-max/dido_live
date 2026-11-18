import 'dart:async';
import 'dart:convert';
import 'dart:math';
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
const _generalConversationId = 'general';
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
  String? _activeRoomId;
  String? _profilePhotoUrl;
  RealtimeChannel? _chatChannel;
  RealtimeChannel? _directoryChannel;
  int _conversationSwitch = 0;
  final Set<String> _messageIds = {};
  int _tab = 0;
  late String _profileName = widget.profileName;
  bool _notifications = true;
  bool _pttSound = true;
  int? _pttPointer;
  Uint8List? _profilePhoto;
  bool _pickingPhoto = false;
  final _conversations = <_Conversation>[_general];
  final _contacts = <_Contact>[];
  _Conversation _selected = _general;
  final _messages = <String, List<_Message>>{_general.id: <_Message>[]};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_initializeApp());
  }

  Future<void> _initializeApp() async {
    try {
      await _loadProfile();
      await _loadContacts();
      await _loadConversations();
      await _selectConversation(_selected, connectVoice: false);
      await _subscribeToDirectory();
      if (mounted) _startConnectionAttempt();
    } catch (error) {
      _showError(error);
    }
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
      _profilePhotoUrl = row['avatar_url'] as String?;
    }
  }

  Future<void> _loadContacts() async {
    final rows = await _supabase
        .from('profiles')
        .select('id, display_name, avatar_url')
        .neq('id', _userId)
        .order('display_name');
    _contacts
      ..clear()
      ..addAll(
        rows.map(
          (row) => _Contact(
            row['id'] as String,
            row['display_name'] as String? ?? 'Usuario',
            0,
            row['avatar_url'] as String?,
          ),
        ),
      );
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
        .select(
          'conversation_id, user_id, profiles(id, display_name, avatar_url)',
        )
        .inFilter('conversation_id', ids.toList());
    final membersByConversation = <String, List<_Contact>>{};
    for (final row in memberRows) {
      if (row['user_id'] == _userId) continue;
      final profile = row['profiles'];
      if (profile is! Map) continue;
      final conversationId = row['conversation_id'] as String;
      membersByConversation
          .putIfAbsent(conversationId, () => [])
          .add(
            _Contact(
              profile['id'] as String,
              profile['display_name'] as String? ?? 'Usuario',
              0,
              profile['avatar_url'] as String?,
            ),
          );
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
        table: 'profiles',
        callback: (_) {
          unawaited(
            _runSafely(() async {
              await _loadContacts();
              await _loadConversations();
            }),
          );
        },
      )
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
        event: PostgresChangeEvent.insert,
        schema: 'public',
        table: 'chat_messages',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'conversation_id',
          value: conversation.id,
        ),
        callback: (payload) {
          if (payload.newRecord['conversation_id'] != _selected.id) return;
          _addMessage(payload.newRecord);
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
          'id, conversation_id, sender_id, body, created_at, profiles(display_name, avatar_url)',
        )
        .eq('conversation_id', conversationId)
        .order('created_at');
    if (!mounted || _selected.id != conversationId) return;
    final messages = rows.map((row) => _messageFromRow(row)).toList();
    _messageIds.addAll(messages.map((message) => message.id));
    setState(() => _messages[conversationId] = messages);
  }

  _Message _messageFromRow(Map<String, dynamic> row) {
    final profile = row['profiles'];
    final senderId = row['sender_id'] as String;
    _Contact? contact;
    for (final item in _contacts) {
      if (item.id == senderId) {
        contact = item;
        break;
      }
    }
    final data = profile is Map ? profile : const <String, dynamic>{};
    final createdAt = DateTime.parse(row['created_at'] as String).toLocal();
    return _Message(
      id: row['id'] as String,
      senderId: senderId,
      sender:
          data['display_name'] as String? ??
          (senderId == _userId ? _profileName : contact?.name ?? 'Usuario'),
      text: row['body'] as String,
      time: TimeOfDay.fromDateTime(createdAt).format(context),
      avatarUrl: data['avatar_url'] as String? ?? contact?.avatarUrl,
      isMine: senderId == _userId,
    );
  }

  void _addMessage(Map<String, dynamic> row) {
    final id = row['id']?.toString();
    if (id == null || !_messageIds.add(id) || !mounted) return;
    final message = _messageFromRow(row);
    setState(() {
      final conversationId = messageConversationId(row);
      _messages[conversationId] = [...?_messages[conversationId], message];
    });
  }

  String messageConversationId(Map<String, dynamic> row) =>
      row['conversation_id'] as String;

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
          _isTransmitting = false;
          _status = permission.isPermanentlyDenied
              ? 'Permiso bloqueado. Habilítalo en Ajustes.'
              : 'Se necesita permiso de micrófono para conectarse.';
        });
        return;
      }

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
    final audioTracks = _localStream!.getAudioTracks();
    if (audioTracks.isEmpty) {
      throw StateError('No se pudo obtener una pista de audio del micrófono.');
    }
    _localAudioTrack = audioTracks.first..enabled = _pttPointer != null;

    await _createPeerConnection();
    await _subscribeToRoom();
    final room = await _loadRoom();
    if (room == null) {
      await _createRoomAsCaller();
    } else if (room['status'] == 'waiting') {
      await _joinRoomAsCallee(room);
    } else {
      throw StateError(
        'Este canal ya tiene una sesión de voz activa. Intenta de nuevo cuando termine.',
      );
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

  Future<Map<String, dynamic>?> _loadRoom() async {
    final rows = await _supabase
        .from('webrtc_rooms')
        .select()
        .eq('conversation_id', _selected.id)
        .inFilter('status', ['waiting', 'answered'])
        .order('created_at', ascending: false)
        .limit(1);
    return rows.isEmpty ? null : Map<String, dynamic>.from(rows.first);
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

    _activeRoomId = _newUuid();
    try {
      await _supabase.from('webrtc_rooms').insert({
        'id': _activeRoomId,
        'conversation_id': _selected.id,
        'created_by': _userId,
        'offer': localDescription.toMap(),
        'status': 'waiting',
      });
    } on PostgrestException catch (error) {
      if (error.code != '23505') rethrow;
      await _replacePeerConnection();
      final existingRoom = await _loadRoom();
      if (existingRoom == null || existingRoom['status'] != 'waiting') {
        throw StateError('No se pudo iniciar una sesión en este canal.');
      }
      await _joinRoomAsCallee(existingRoom);
      return;
    }

    _roomIsPublished = true;
    await _flushLocalCandidates();
    if (mounted) {
      setState(() => _status = 'Esperando a alguien en ${_selected.name}...');
    }
  }

  Future<void> _joinRoomAsCallee(Map<String, dynamic> room) async {
    if (room['status'] != 'waiting' || room['answer'] != null) {
      throw StateError('Esta sesión de voz ya está ocupada.');
    }

    _role = 'callee';
    _activeRoomId = room['id'] as String;
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

    final claimedRoom = await _supabase
        .from('webrtc_rooms')
        .update({'answer': localDescription.toMap(), 'status': 'answered'})
        .eq('id', _activeRoomId!)
        .eq('status', 'waiting')
        .isFilter('answer', null)
        .select('id');
    if (claimedRoom.isEmpty) {
      throw StateError('Otra persona ya respondió a esta sesión de voz.');
    }
    _roomIsPublished = true;
    await _flushLocalCandidates();
    if (mounted && !_isConnected) {
      setState(() => _status = 'Respuesta enviada; conectando...');
    }
  }

  Future<void> _replacePeerConnection() async {
    final oldConnection = _peerConnection;
    _peerConnection = null;
    if (oldConnection != null) {
      await oldConnection.close();
      await oldConnection.dispose();
    }

    _pendingLocalCandidates.clear();
    _pendingRemoteCandidates.clear();
    _seenRemoteCandidateIds.clear();
    _remoteDescriptionIsSet = false;
    _activeRoomId = null;
    await _createPeerConnection();
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
    setState(() {
      _callFailed = true;
      _isConnected = false;
      _isTransmitting = false;
      _localAudioTrack?.enabled = false;
      _status = 'Error: $error';
    });
  }

  void _startTransmission() {
    if (_callFailed) return;
    if (_localAudioTrack == null || _peerConnection == null) {
      setState(() => _isTransmitting = true);
      _startConnectionAttempt();
      return;
    }
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

  Future<void> _endVoiceSession({bool updateStatus = true}) async {
    _localAudioTrack?.enabled = false;
    final roomId = _activeRoomId;
    _activeRoomId = null;
    try {
      if (roomId != null && _role != null && _roomIsPublished) {
        await _supabase
            .from('webrtc_rooms')
            .update({'status': 'ended'})
            .eq('id', roomId)
            .inFilter('status', ['waiting', 'answered']);
      }
    } finally {
      final channel = _channel;
      try {
        if (channel != null) await _supabase.removeChannel(channel);
      } finally {
        _channel = null;
        final connection = _peerConnection;
        try {
          if (connection != null) await connection.close();
        } finally {
          if (connection != null) await connection.dispose();
          _peerConnection = null;
          _activeRoomId = null;
          _role = null;
          _roomIsPublished = false;
          _remoteDescriptionIsSet = false;
          _answerIsApplied = false;
          _pendingLocalCandidates.clear();
          _pendingRemoteCandidates.clear();
          _seenRemoteCandidateIds.clear();
          _isConnected = false;
          if (updateStatus && mounted) {
            setState(() => _status = 'Listo · ${_selected.name}');
          }
        }
      }
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
    final permissionBlocked = _status.startsWith('Permiso bloqueado');
    final status = _isTransmitting
        ? 'Transmitiendo · ${_selected.name}'
        : _status;

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
            if (_callFailed)
              TextButton.icon(
                onPressed: _retryVoiceConnection,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Reintentar conexión'),
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
                        _callFailed) {
                      return;
                    }
                    _pttPointer = event.pointer;
                    _startTransmission();
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
                      imageUrl: contact.avatarUrl,
                      subtitle: 'Integrante del canal',
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
                          imageUrl: option.contacts.single.avatarUrl,
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
    final users = [_userId, contact.id]..sort();
    final directKey = users.join(':');
    var row = await _supabase
        .from('conversations')
        .select('id, name, kind')
        .eq('direct_key', directKey)
        .maybeSingle();
    if (row == null) {
      final id = _newUuid();
      try {
        await _supabase.from('conversations').insert({
          'id': id,
          'kind': 'personal',
          'name': contact.name,
          'direct_key': directKey,
          'created_by': _userId,
        });
        row = {'id': id, 'name': contact.name, 'kind': 'personal'};
        await _supabase.from('conversation_members').insert([
          {'conversation_id': id, 'user_id': _userId, 'role': 'member'},
          {'conversation_id': id, 'user_id': contact.id, 'role': 'member'},
        ]);
      } on PostgrestException catch (error) {
        if (error.code != '23505') rethrow;
        row = await _supabase
            .from('conversations')
            .select('id, name, kind')
            .eq('direct_key', directKey)
            .single();
      }
    }
    await _ensureDirectMembership(row['id'] as String);
    await _loadConversations();
    return _conversations.firstWhere(
      (conversation) => conversation.id == row!['id'],
    );
  }

  Future<void> _ensureDirectMembership(String conversationId) async {
    try {
      await _supabase.from('conversation_members').insert({
        'conversation_id': conversationId,
        'user_id': _userId,
        'role': 'member',
      });
    } on PostgrestException catch (error) {
      if (error.code != '23505') rethrow;
    }
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
    if (connectVoice && mounted && switchId == _conversationSwitch) {
      _startConnectionAttempt();
    }
  }

  Future<void> _sendChatMessage(String text) async {
    final body = text.trim();
    if (body.isEmpty) return;
    try {
      await _supabase.from('chat_messages').insert({
        'conversation_id': _selected.id,
        'sender_id': _userId,
        'body': body,
      });
    } catch (error) {
      _photoNotice('No se pudo enviar el mensaje: $error');
    }
  }

  Widget _profileAvatar({required double size}) {
    final fallback = widget.isGuest
        ? _DidoLogo(size: size)
        : _Avatar(image: 2, size: size);
    final photo = _profilePhoto;
    if (photo == null) {
      final photoUrl = _profilePhotoUrl;
      if (photoUrl == null) return fallback;
      return ClipOval(
        child: Image.network(
          photoUrl,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) => fallback,
        ),
      );
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
      final photoUrl = _supabase.storage
          .from(_profilePhotosBucket)
          .getPublicUrl(path);
      await _supabase
          .from('profiles')
          .update({'avatar_url': photoUrl})
          .eq('id', _userId);
      if (mounted) {
        setState(() {
          _profilePhoto = bytes;
          _profilePhotoUrl = photoUrl;
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
      final segments = _profilePhotoUrl == null
          ? const <String>[]
          : Uri.parse(_profilePhotoUrl!).pathSegments;
      final bucketIndex = segments.indexOf(_profilePhotosBucket);
      final path = bucketIndex < 0
          ? null
          : segments.skip(bucketIndex + 1).join('/');
      if (path != null && path.isNotEmpty) {
        await _supabase.storage.from(_profilePhotosBucket).remove([path]);
      }
      await _supabase
          .from('profiles')
          .update({'avatar_url': null})
          .eq('id', _userId);
      if (mounted) {
        setState(() {
          _profilePhoto = null;
          _profilePhotoUrl = null;
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
    setState(() => _openingRoom = true);
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
            _notice(
              'Revisa tu correo para confirmar la cuenta y luego inicia sesión.',
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
      _notice(error.message);
    } catch (error) {
      _notice('No se pudo iniciar sesión: $error');
    } finally {
      if (mounted) setState(() => _openingRoom = false);
    }
  }

  void _notice(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
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
                      child: const Text('Iniciar sesión'),
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
                      child: const Text('Entrar como invitado'),
                    ),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: _openingRoom
                          ? null
                          : () => _enter(asGuest: false, createAccount: true),
                      child: const Text('Crear cuenta'),
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
  const _Avatar({required this.image, this.imageUrl, this.size = 40});

  final int image;
  final String? imageUrl;
  final double size;

  static final _images = _avatarPhotos
      .map(base64Decode)
      .toList(growable: false);

  @override
  Widget build(BuildContext context) {
    final photoUrl = imageUrl;
    if (photoUrl != null && photoUrl.isNotEmpty) {
      return ClipOval(
        child: Image.network(
          photoUrl,
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
    this.imageUrl,
    this.avatar,
    this.active = false,
    this.transmitting = false,
  });

  final String name;
  final int image;
  final String subtitle;
  final String? imageUrl;
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
          avatar ?? _Avatar(image: image, imageUrl: imageUrl),
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
  const _Contact(this.id, this.name, this.avatar, [this.avatarUrl]);

  final String id;
  final String name;
  final int avatar;
  final String? avatarUrl;
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
                  imageUrl: contact.avatarUrl,
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
    this.avatarUrl,
  });

  final String id;
  final String senderId;
  final String sender;
  final String text;
  final String time;
  final String? avatarUrl;
  final bool isMine;
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
    final mine = message.isMine;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!mine) ...[
          _Avatar(image: 0, imageUrl: message.avatarUrl),
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
