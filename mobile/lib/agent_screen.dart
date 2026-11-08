import 'dart:async';

import 'package:flutter/material.dart';

import 'api.dart';

/// Poste agent : gros bouton « APPELER LE SUIVANT » et actions sur le ticket en cours.
class AgentScreen extends StatefulWidget {
  const AgentScreen({super.key, required this.api, required this.onLogout});
  final Api api;
  final Future<void> Function() onLogout;
  @override
  State<AgentScreen> createState() => _AgentScreenState();
}

class _AgentScreenState extends State<AgentScreen> {
  Map<String, dynamic>? _st;
  String? _error;
  bool _busy = false;
  Timer? _poll;
  dynamic _socket;

  Map<String, dynamic>? get _counter => _st?['counter'] as Map<String, dynamic>?;
  Map<String, dynamic>? get _current => _st?['current'] as Map<String, dynamic>?;

  @override
  void initState() {
    super.initState();
    _refresh();
    _socket = widget.api.socket()
      ..on('queue.updated', (_) => _refresh())
      ..on('connect', (_) => _refresh());
    // Filet de sécurité si le temps réel est coupé.
    _poll = Timer.periodic(const Duration(seconds: 20), (_) => _refresh());
  }

  @override
  void dispose() {
    _poll?.cancel();
    _socket?.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final s = await widget.api.get('/agent/state') as Map<String, dynamic>;
      if (mounted) setState(() => _st = s);
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    }
  }

  Future<void> _act(String path, [Map<String, dynamic>? body]) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.api.post(path, body);
    } catch (e) {
      _error = errorText(e);
    }
    await _refresh();
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _transfer() async {
    final all = (await widget.api.get('/services') as List)
        .where((s) => s['active'] == true && s['id'] != _current!['service_id'])
        .toList();
    if (!mounted) return;
    final id = await showDialog<int>(
        context: context,
        builder: (c) => SimpleDialog(title: const Text('Transférer vers'), children: [
              for (final s in all)
                SimpleDialogOption(
                    onPressed: () => Navigator.pop(c, s['id'] as int), child: Text(s['name'].toString())),
            ]));
    if (id != null) await _act('/agent/tickets/${_current!['id']}/transfer', {'service_id': id});
  }

  @override
  Widget build(BuildContext context) {
    final k = _counter, t = _current;
    final status = k?['status'] as String? ?? 'closed';
    final label = {'open': 'ouvert', 'paused': 'en pause', 'closed': 'fermé'}[status];
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.api.session.name} · ${k?['name'] ?? ''} ($label)'),
        actions: [
          if (k != null && status != 'closed')
            TextButton(
                onPressed: () => _act('/agent/counter/${status == 'paused' ? 'resume' : 'pause'}'),
                child: Text(status == 'paused' ? 'Reprendre' : 'Pause')),
          IconButton(onPressed: widget.onLogout, icon: const Icon(Icons.logout)),
        ],
      ),
      body: _st == null
          ? Center(child: _error != null ? Text(_error!) : const CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(16), children: [
              Row(children: [
                _stat('En attente', '${_st!['waiting']}'),
                _stat('Servis', '${_st!['served']}'),
                _stat('Temps moyen', _fmt(_st!['avg_handling_seconds'])),
              ]),
              const SizedBox(height: 16),
              SizedBox(
                height: 96,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                      backgroundColor: Colors.green.shade700,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))),
                  onPressed: (_busy || t != null || status != 'open') ? null : () => _act('/agent/call-next'),
                  child: const Text('APPELER LE SUIVANT', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
                ),
              ),
              const SizedBox(height: 16),
              Center(
                  child: t == null
                      ? Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(status == 'open' ? 'Aucun client en cours' : 'Ouvrez le guichet pour commencer'))
                      : Column(children: [
                          Text('${t['service_name']} · ${t['status'] == 'serving' ? 'en cours de traitement' : 'appelé'}'),
                          Text(t['ticket_number'].toString(),
                              style: const TextStyle(fontSize: 96, fontWeight: FontWeight.w800)),
                        ])),
              if (_error != null)
                Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: scheme.error))),
              Wrap(spacing: 10, runSpacing: 10, alignment: WrapAlignment.center, children: [
                if (status == 'closed') FilledButton(onPressed: () => _act('/agent/counter/open'), child: const Text('Ouvrir le guichet')),
                if (t != null) ...[
                  OutlinedButton(onPressed: () => _act('/agent/tickets/${t['id']}/recall'), child: const Text('Rappeler')),
                  if (t['status'] == 'called')
                    OutlinedButton(onPressed: () => _act('/agent/tickets/${t['id']}/start'), child: const Text('Début du traitement')),
                  FilledButton(
                      style: FilledButton.styleFrom(backgroundColor: Colors.green.shade700),
                      onPressed: () => _act('/agent/tickets/${t['id']}/complete'),
                      child: const Text('Terminer')),
                  if (t['status'] == 'called') ...[
                    FilledButton(
                        style: FilledButton.styleFrom(backgroundColor: scheme.error),
                        onPressed: () => _act('/agent/tickets/${t['id']}/absent'),
                        child: const Text('Absent')),
                    OutlinedButton(onPressed: () => _act('/agent/tickets/${t['id']}/skip'), child: const Text('Ignorer')),
                  ],
                  OutlinedButton(onPressed: _transfer, child: const Text('Transférer')),
                ],
                if (t == null && status != 'closed')
                  OutlinedButton(onPressed: () => _act('/agent/counter/close'), child: const Text('Fermer le guichet')),
              ]),
            ]),
    );
  }

  Widget _stat(String label, String value) => Expanded(
          child: Card(
        child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Column(children: [
              Text(value, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
              Text(label, style: const TextStyle(fontSize: 12)),
            ])),
      ));
}

String _fmt(Object? s) {
  if (s == null) return '—';
  final n = (s as num).toInt();
  return n < 60 ? '$n s' : '${(n / 60).round()} min';
}
