import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'api.dart';
import 'backend.dart';

Color parseColor(String? hex) {
  final h = (hex ?? '').replaceFirst('#', '');
  final v = int.tryParse(h.length == 6 ? 'FF$h' : h, radix: 16);
  return Color(v ?? 0xFF1E5EFF);
}

/// Borne : une grande touche par service, ticket affiché (avec QR de suivi si disponible).
/// [embedded] : intégrée à l'application autonome (pas de plein écran, pas de bouton de sortie).
class KioskScreen extends StatefulWidget {
  const KioskScreen({super.key, required this.backend, this.onLogout, this.embedded = false});
  final Backend backend;
  final Future<void> Function()? onLogout;
  final bool embedded;
  @override
  State<KioskScreen> createState() => _KioskScreenState();
}

class _KioskScreenState extends State<KioskScreen> {
  List<Js> _services = [];
  String _org = 'Bienvenue';
  String? _error;
  bool _busy = false;
  TicketResult? _result;
  String? _printStatus;
  Js? _last;
  Timer? _hide;
  StreamSubscription<void>? _sub;

  @override
  void initState() {
    super.initState();
    if (!widget.embedded) SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _load();
    _sub = widget.backend.changes.listen((_) => _refreshLast());
  }

  @override
  void dispose() {
    _hide?.cancel();
    _sub?.cancel();
    if (!widget.embedded) SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final s = await widget.backend.services();
      final cfg = await widget.backend.settings();
      if (!mounted) return;
      setState(() {
        _services = s.where((x) => x['active'] != false).toList();
        _org = (cfg['org_name'] ?? 'Bienvenue').toString();
        _error = null;
      });
      await _refreshLast();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = errorText(e));
      Timer(const Duration(seconds: 5), () => mounted ? _load() : null);
    }
  }

  Future<void> _refreshLast() async {
    try {
      final l = await widget.backend.lastCall();
      if (mounted) setState(() => _last = l);
    } catch (_) {}
  }

  Future<void> _take(Js service) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await widget.backend.createTicket(service['id'] as int);
      setState(() {
        _result = r;
        _printStatus = r.printStatus;
      });
      _hide?.cancel();
      _hide = Timer(Duration(seconds: _printStatus == 'failed' ? 30 : 10), () => setState(() => _result = null));
    } catch (e) {
      setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reprint() async {
    try {
      await widget.backend.reprint(_result!.ticket['id'] as int);
      setState(() => _printStatus = 'printed');
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
    if (ok == true) await widget.onLogout!();
  }

  @override
  Widget build(BuildContext context) {
    final r = _result;
    final t = r?.ticket;
    return Scaffold(
      body: SafeArea(
        child: Stack(children: [
          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(children: [
              Text(_org, style: Theme.of(context).textTheme.headlineMedium, textAlign: TextAlign.center),
              const SizedBox(height: 6),
              Text('Touchez votre service pour obtenir un ticket', style: Theme.of(context).textTheme.titleMedium, textAlign: TextAlign.center),
              if (_last != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Card(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      child: Text('Dernier appel : ${_last!['ticket_number']} → guichet ${_last!['counter_number']}',
                          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              Expanded(
                child: _services.isEmpty && _error == null
                    ? const Center(child: Text('Aucun service. Ajoutez-en dans les réglages.'))
                    : LayoutBuilder(builder: (context, c) {
                        final cols = c.maxWidth > 900 ? 3 : c.maxWidth > 560 ? 2 : 1;
                        return GridView.count(
                          crossAxisCount: cols,
                          mainAxisSpacing: 14,
                          crossAxisSpacing: 14,
                          childAspectRatio: cols == 1 ? 3.2 : 2.4,
                          children: [
                            for (final s in _services)
                              FilledButton(
                                style: FilledButton.styleFrom(
                                    backgroundColor: parseColor(s['color'] as String?),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22))),
                                onPressed: _busy ? null : () => _take(s),
                                child: Text(s['name'].toString(), style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700)),
                              ),
                          ],
                        );
                      }),
              ),
              if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 18)),
            ]),
          ),
          if (widget.onLogout != null)
            Positioned(
                right: 0,
                bottom: 0,
                child: IconButton(onPressed: _exit, icon: const Icon(Icons.lock_outline, size: 18), color: Colors.grey.withValues(alpha: .4))),
          if (t != null)
            Positioned.fill(
              child: ColoredBox(
                color: Theme.of(context).colorScheme.surface,
                child: Center(
                  child: SingleChildScrollView(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(t['service_name'].toString(), style: Theme.of(context).textTheme.headlineMedium),
                      Text(t['ticket_number'].toString(), style: const TextStyle(fontSize: 120, fontWeight: FontWeight.w800, height: 1.1)),
                      Text(t['ahead'] == 0 ? 'Vous êtes le prochain' : 'Personnes devant vous : ${t['ahead']}',
                          style: Theme.of(context).textTheme.headlineSmall),
                      if (t['estimate_minutes'] != null) Text('Attente estimée : ~${t['estimate_minutes']} min'),
                      if (r!.qrUrl != null) ...[
                        const SizedBox(height: 16),
                        Container(color: Colors.white, padding: const EdgeInsets.all(8), child: QrImageView(data: r.qrUrl!, size: 190)),
                        const SizedBox(height: 8),
                        const Text('Scannez pour suivre votre attente (Wi-Fi de l’établissement)'),
                      ] else
                        const Padding(padding: EdgeInsets.only(top: 12), child: Text('Gardez votre numéro et attendez l’appel.')),
                      if (_printStatus == 'failed') ...[
                        const SizedBox(height: 12),
                        const Text('Impression impossible : notez votre numéro ou demandez de l’aide.',
                            style: TextStyle(color: Colors.orange, fontSize: 18)),
                        const SizedBox(height: 8),
                        OutlinedButton(onPressed: _reprint, child: const Text('Réimprimer')),
                      ],
                      const SizedBox(height: 16),
                      FilledButton.tonal(onPressed: () => setState(() => _result = null), child: const Text('Fermer')),
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
