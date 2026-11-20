import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class SuperAdminPanel extends StatefulWidget {
  const SuperAdminPanel({required this.client, super.key});

  final SupabaseClient client;

  @override
  State<SuperAdminPanel> createState() => _SuperAdminPanelState();
}

class _SuperAdminPanelState extends State<SuperAdminPanel> {
  static const _panel = Color(0xFF202833);
  static const _line = Color(0xFF353F4B);
  static const _ink = Color(0xFFE8EDF2);
  static const _muted = Color(0xFF9AA8B5);
  static const _teal = Color(0xFF50E3D2);
  static const _orange = Color(0xFFFFB86B);

  Map<String, dynamic> _dashboard = const {};
  final List<Map<String, dynamic>> _accounts = [];
  int _totalAccounts = 0;
  bool _loading = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool append = false}) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final response = await widget.client.rpc(
        'get_app_admin_dashboard',
        params: {
          'p_limit': 50,
          'p_offset': append ? _accounts.length : 0,
        },
      );
      if (response is! Map) {
        throw const FormatException('Respuesta inválida del panel.');
      }
      final result = Map<String, dynamic>.from(response);
      final page = (result['accounts'] as List? ?? const [])
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList();
      if (!mounted) return;
      setState(() {
        _dashboard = result;
        if (append) {
          _accounts.addAll(page);
        } else {
          _accounts
            ..clear()
            ..addAll(page);
        }
        _totalAccounts = _asInt(result['registered_accounts']);
      });
    } catch (error) {
      if (mounted) setState(() => _error = 'No se pudo cargar el panel: $error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _updateAccess(
    Map<String, dynamic> account, {
    bool? suspended,
    bool? courtesyPremium,
  }) async {
    if (_busy) return;
    final id = account['id'] as String?;
    if (id == null) return;
    final nextSuspended = suspended ?? account['suspended'] == true;
    final nextPremium = courtesyPremium ?? account['courtesy_premium'] == true;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.client.rpc(
        'admin_update_user_access',
        params: {
          'p_target_user_id': id,
          'p_suspended': nextSuspended,
          'p_courtesy_premium': nextPremium,
        },
      );
      await _load();
    } catch (error) {
      if (mounted) setState(() => _error = 'No se guardó el cambio: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  int _asInt(dynamic value) =>
      value is num ? value.toInt() : int.tryParse('$value') ?? 0;

  String _date(dynamic value) {
    if (value is! String || value.isEmpty) return 'Sin registro';
    final parsed = DateTime.tryParse(value);
    if (parsed == null) return 'Sin registro';
    final local = parsed.toLocal();
    return '${local.day.toString().padLeft(2, '0')}/'
        '${local.month.toString().padLeft(2, '0')}/'
        '${local.year} · '
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }

  Widget _metric(String label, String value, IconData icon, Color color) {
    return Container(
      width: 145,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF19212A),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 19, color: color),
          const SizedBox(height: 8),
          Text(
            value,
            style: const TextStyle(
              color: _ink,
              fontSize: 21,
              fontWeight: FontWeight.w800,
            ),
          ),
          Text(label, style: const TextStyle(color: _muted, fontSize: 11)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final activity = (_dashboard['activity_by_day'] as List? ?? const [])
        .whereType<Map>()
        .toList();
    final audit = (_dashboard['recent_audit'] as List? ?? const [])
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList();
    final currentUserId = widget.client.auth.currentUser?.id;

    return Container(
      margin: const EdgeInsets.only(top: 18),
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _line),
      ),
      child: ExpansionTile(
        initiallyExpanded: true,
        tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
        leading: const Icon(Icons.admin_panel_settings, color: _teal),
        title: const Text(
          'Superadministración',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        subtitle: const Text(
          'Acceso validado por Supabase · acciones auditadas',
          style: TextStyle(color: _muted, fontSize: 11),
        ),
        children: [
          if (_error != null)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFF422F29),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(_error!, style: const TextStyle(color: _orange)),
            ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _metric(
                'Cuentas registradas',
                '${_asInt(_dashboard['registered_accounts'])}',
                Icons.people_alt_outlined,
                _teal,
              ),
              _metric(
                'Activos hoy',
                '${_asInt(_dashboard['active_today'])}',
                Icons.today_outlined,
                _teal,
              ),
              _metric(
                'Activos en 7 días',
                '${_asInt(_dashboard['active_last_7_days'])}',
                Icons.calendar_view_week_outlined,
                _teal,
              ),
              _metric(
                'Premium cortesía',
                '${_asInt(_dashboard['courtesy_premium_accounts'])}',
                Icons.workspace_premium_outlined,
                _orange,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(11),
            decoration: BoxDecoration(
              color: const Color(0xFF19212A),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Text(
              'El tiempo en primer plano y el último uso se recopilan sin contenido de chats ni audios. Las instalaciones y bajas se consultan en Play Console; la inactividad no confirma una desinstalación.',
              style: TextStyle(color: _muted, fontSize: 11, height: 1.4),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              const Expanded(
                child: Text('Actividad diaria · 30 días', style: TextStyle(fontWeight: FontWeight.w700)),
              ),
              IconButton(
                tooltip: 'Actualizar panel',
                onPressed: _loading ? null : _load,
                icon: const Icon(Icons.refresh_rounded),
              ),
            ],
          ),
          SizedBox(
            height: 78,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final item in activity)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 1),
                      child: Tooltip(
                        message: '${item['day']}: ${item['active_users']} activos',
                        child: Container(
                          height: (12 + _asInt(item['active_users']) * 7)
                              .clamp(12, 72)
                              .toDouble(),
                          decoration: BoxDecoration(
                            color: _teal.withValues(alpha: 0.75),
                            borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Cuentas · $_totalAccounts',
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
            ),
          ),
          if (_loading && _accounts.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            ),
          for (final account in _accounts)
            _accountCard(account, currentUserId),
          if (_accounts.length < _totalAccounts)
            OutlinedButton.icon(
              onPressed: _loading ? null : () => _load(append: true),
              icon: const Icon(Icons.expand_more),
              label: const Text('Cargar más cuentas'),
            ),
          if (audit.isNotEmpty) ...[
            const SizedBox(height: 14),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text('Cambios recientes', style: TextStyle(fontWeight: FontWeight.w800)),
            ),
            for (final entry in audit.take(10))
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.history, color: _muted, size: 18),
                title: Text(_auditLabel(entry['action'] as String? ?? '')),
                subtitle: Text(
                  '${entry['actor_email'] ?? 'Admin'} → ${entry['target_email'] ?? 'Cuenta'} · ${_date(entry['created_at'])}',
                  style: const TextStyle(color: _muted, fontSize: 11),
                ),
              ),
          ],
          if (_loading && _accounts.isNotEmpty)
            const LinearProgressIndicator(),
        ],
      ),
    );
  }

  String _auditLabel(String action) => switch (action) {
    'suspended' => 'Cuenta suspendida',
    'reactivated' => 'Cuenta reactivada',
    'courtesy_premium_granted' => 'Premium cortesía otorgado',
    'courtesy_premium_removed' => 'Premium cortesía retirado',
    _ => action,
  };

  Widget _accountCard(
    Map<String, dynamic> account,
    String? currentUserId,
  ) {
    final id = account['id'] as String?;
    final suspended = account['suspended'] == true;
    final courtesyPremium = account['courtesy_premium'] == true;
    final isSelf = id != null && id == currentUserId;
    return Container(
      margin: const EdgeInsets.only(top: 9),
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: const Color(0xFF19212A),
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: suspended ? _orange.withValues(alpha: 0.6) : _line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            account['display_name'] as String? ?? 'Usuario',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          Text(
            account['email'] as String? ?? 'Sin correo',
            style: const TextStyle(color: _muted, fontSize: 12),
          ),
          const SizedBox(height: 5),
          Text(
            '${suspended ? 'Suspendida' : 'Activa'} · '
            '${courtesyPremium ? 'Premium cortesía' : 'Sin cortesía'}',
            style: TextStyle(
              color: suspended ? _orange : courtesyPremium ? _teal : _muted,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
          Text(
            'Último uso: ${_date(account['last_used_at'])} · '
            '${_asInt(account['foreground_minutes'])} min en primer plano',
            style: const TextStyle(color: _muted, fontSize: 11),
          ),
          Wrap(
            spacing: 4,
            children: [
              TextButton.icon(
                onPressed: _busy || isSelf
                    ? null
                    : () => _updateAccess(account, suspended: !suspended),
                icon: Icon(suspended ? Icons.check_circle_outline : Icons.block),
                label: Text(suspended ? 'Reactivar' : 'Suspender'),
              ),
              TextButton.icon(
                onPressed: _busy
                    ? null
                    : () => _updateAccess(account, courtesyPremium: !courtesyPremium),
                icon: Icon(courtesyPremium ? Icons.workspace_premium : Icons.card_giftcard),
                label: Text(courtesyPremium ? 'Quitar cortesía' : 'Dar cortesía'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
