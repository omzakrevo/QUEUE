import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'api.dart';

Color parseColor(String? hex) {
  final h = (hex ?? '').replaceFirst('#', '');
  final v = int.tryParse(h.length == 6 ? 'FF$h' : h, radix: 16);
  return Color(v ?? 0xFF1E5EFF);
}

/// Borne : plein écran, une grande touche par service, ticket + QR de suivi.
class KioskScreen extends StatefulWidget {
  const KioskScreen({super.key, required this.api, required this.onLogout});
  final Api api;
  final Future<void> Function() onLogout;
  @override
  State<KioskScreen> createState() => _KioskScreenState();
}

class _KioskScreenState extends State<KioskScreen> {
  List<dynamic> _services = [];
  String _org = 'Bienvenue';
  String? _error;
  bool _busy = false;
  Map<String, dynamic>? _ticket;
  String? _qrUrl;
  String? _printStatus;
  Timer? _hide;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _load();
  }

  @override
  void dispose() {
    _hide?.cancel();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final s = await widget.api.get('/services') as List;
      final cfg = await widget.api.get('/settings') as Map;
      setState(() {
        _services = s.where((x) => x['active'] == true).toList();
        _org = (cfg['org_name'] ?? 'Bienvenue').toString();
        _error = null;
      });
    } catch (e) {
      setState(() => _error = errorText(e));
      Timer(const Duration(seconds: 5), () => mounted ? _load() : null);
    }
  }

  Future<void> _take(Map service) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await widget.api.post('/tickets', {
        'service_id': service['id'],
        if (widget.api.session.terminalId != null) 'terminal_id': widget.api.session.terminalId,
      }) as Map<String, dynamic>;
      setState(() {
        _ticket = r['ticket'] as Map<String, dynamic>;
        _qrUrl = r['qr_url'] as String;
        _printStatus = (r['print'] as Map)['status'] as String;
      });
      _hide?.cancel();
      _hide = Timer(Duration(seconds: _printStatus == 'failed' ? 30 : 8), () => setState(() => _ticket = null));
    } catch (e) {
      setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reprint() async {
    try {
      final r = await widget.api.post('/tickets/${_ticket!['id']}/reprint',
          {if (widget.api.session.terminalId != null) 'terminal_id': widget.api.session.terminalId}) as Map;
      setState(() => _printStatus = (r['print'] as Map)['status'] as String);
    } catch (_) {
      setState(() => _printStatus = 'failed');
    }
  }

  Future<void> _exit() async {
    final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
              title: const Text('Quitter le mode borne ?'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Annuler')),
                FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Déconnecter')),
              ],
            ));
    if (ok == true) await widget.onLogout();
  }

  @override
  Widget build(BuildContext context) {
    final t = _ticket;
    return Scaffold(
      body: SafeArea(
        child: Stack(children: [
          Padding(
            padding: const EdgeInsets.all(24),
            child: Column(children: [
              Text(_org, style: Theme.of(context).textTheme.displaySmall, textAlign: TextAlign.center),
              const SizedBox(height: 8),
              Text('Touchez votre service pour obtenir un ticket', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 24),
              Expanded(
                child: LayoutBuilder(builder: (context, c) {
                  final cols = c.maxWidth > 900 ? 3 : c.maxWidth > 560 ? 2 : 1;
                  return GridView.count(
                    crossAxisCount: cols,
                    mainAxisSpacing: 16,
                    crossAxisSpacing: 16,
                    childAspectRatio: 2.4,
                    children: [
                      for (final s in _services)
                        FilledButton(
                          style: FilledButton.styleFrom(
                              backgroundColor: parseColor(s['color'] as String?),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22))),
                          onPressed: _busy ? null : () => _take(s as Map),
                          child: Text(s['name'].toString(),
                              style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700)),
                        ),
                    ],
                  );
                }),
              ),
              if (_error != null)
                Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 20)),
            ]),
          ),
          Positioned(right: 0, bottom: 0, child: IconButton(onPressed: _exit, icon: const Icon(Icons.lock_outline, size: 18), color: Colors.grey.withValues(alpha: .4))),
          if (t != null)
            Positioned.fill(
              child: ColoredBox(
                color: Theme.of(context).colorScheme.surface,
                child: Center(
                  child: SingleChildScrollView(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(t['service_name'].toString(), style: Theme.of(context).textTheme.headlineMedium),
                      Text(t['ticket_number'].toString(),
                          style: const TextStyle(fontSize: 120, fontWeight: FontWeight.w800, height: 1.1)),
                      Text(t['ahead'] == 0 ? 'Vous êtes le prochain' : 'Personnes devant vous : ${t['ahead']}',
                          style: Theme.of(context).textTheme.headlineSmall),
                      const SizedBox(height: 16),
                      Container(
                          color: Colors.white,
                          padding: const EdgeInsets.all(8),
                          child: QrImageView(data: _qrUrl!, size: 200)),
                      const SizedBox(height: 8),
                      const Text('Scannez pour suivre votre attente (Wi-Fi de l’établissement)'),
                      if (_printStatus == 'failed') ...[
                        const SizedBox(height: 12),
                        const Text('Impression impossible : notez votre numéro ou demandez de l’aide.',
                            style: TextStyle(color: Colors.orange, fontSize: 18)),
                        const SizedBox(height: 8),
                        OutlinedButton(onPressed: _reprint, child: const Text('Réimprimer')),
                      ],
                      const SizedBox(height: 16),
                      TextButton(onPressed: () => setState(() => _ticket = null), child: const Text('Fermer')),
                    ]),
                  ),
                ),
              ),
            ),
        ]),
      ),
    );
  }
}
