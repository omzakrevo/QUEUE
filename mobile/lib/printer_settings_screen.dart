import 'package:flutter/material.dart';

import 'printer.dart';

/// Réglage de l'imprimante Bluetooth de CET appareil.
class PrinterSettingsScreen extends StatefulWidget {
  const PrinterSettingsScreen({super.key, required this.printer});
  final PrinterService printer;
  @override
  State<PrinterSettingsScreen> createState() => _PrinterSettingsScreenState();
}

class _PrinterSettingsScreenState extends State<PrinterSettingsScreen> {
  PrinterConfig _c = const PrinterConfig();
  String? _msg;
  bool _ok = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    widget.printer.config().then((c) => mounted ? setState(() => _c = c) : null);
  }

  Future<void> _update(PrinterConfig c) async {
    await c.save();
    setState(() => _c = c);
  }

  Future<void> _choose() async {
    setState(() {
      _busy = true;
      _msg = null;
    });
    final t = widget.printer.transport;
    try {
      if (!await t.ensurePermission()) {
        return _say('Autorisation Bluetooth refusée : autorisez-la dans les réglages Android.', false);
      }
      if (!await t.bluetoothEnabled()) return _say('Activez le Bluetooth du téléphone.', false);
      final list = await t.paired();
      if (!mounted) return;
      if (list.isEmpty) {
        return _say('Aucun appareil jumelé. Allumez l’imprimante, puis jumelez-la dans Réglages Android → Bluetooth '
            '(code 0000 ou 1234), et revenez ici.', false);
      }
      final p = await showDialog<PairedPrinter>(
          context: context,
          builder: (c) => SimpleDialog(title: const Text('Choisir l’imprimante'), children: [
                for (final d in list)
                  SimpleDialogOption(onPressed: () => Navigator.pop(c, d), child: ListTile(title: Text(d.name), subtitle: Text(d.address))),
              ]));
      if (p != null) {
        await _update(_c.copyWith(name: p.name, address: p.address, enabled: true));
        _say('Imprimante « ${p.name} » enregistrée. Faites un ticket test.', true);
      }
    } catch (e) {
      _say('Erreur Bluetooth ($e).', false);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _say(String m, bool ok) {
    if (mounted) {
      setState(() {
        _msg = m;
        _ok = ok;
      });
    }
  }

  Future<void> _test() async {
    setState(() {
      _busy = true;
      _msg = null;
    });
    final s = await widget.printer.printTest();
    _say(s == 'printed' ? 'Ticket test envoyé à l’imprimante.' : (widget.printer.lastError ?? 'Échec de l’impression.'), s == 'printed');
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Imprimante de tickets')),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          SwitchListTile(
            title: const Text('Imprimer les tickets'),
            subtitle: const Text('Un ticket papier est imprimé dès qu’un visiteur en prend un.'),
            value: _c.enabled,
            onChanged: _c.address.isEmpty ? null : (v) => _update(_c.copyWith(enabled: v)),
          ),
          ListTile(
            leading: const Icon(Icons.print_outlined),
            title: Text(_c.address.isEmpty ? 'Aucune imprimante choisie' : _c.name),
            subtitle: Text(_c.address.isEmpty
                ? 'Jumelez d’abord l’imprimante dans les réglages Bluetooth d’Android.'
                : _c.address),
            trailing: FilledButton.tonal(onPressed: _busy ? null : _choose, child: const Text('Choisir')),
          ),
          ListTile(
            title: const Text('Largeur du papier'),
            trailing: SegmentedButton<int>(
              segments: const [ButtonSegment(value: 58, label: Text('58 mm')), ButtonSegment(value: 80, label: Text('80 mm'))],
              selected: {_c.width},
              onSelectionChanged: (v) => _update(_c.copyWith(width: v.first)),
            ),
          ),
          SwitchListTile(
            title: const Text('Coupe automatique'),
            subtitle: const Text('Coupe le papier après chaque ticket. Si votre imprimante n’a pas de couteau, désactivez : '
                'le papier avance simplement pour être arraché.'),
            value: _c.cut,
            onChanged: (v) => _update(_c.copyWith(cut: v)),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
              onPressed: _busy || _c.address.isEmpty ? null : _test, icon: const Icon(Icons.receipt_long), label: const Text('Imprimer un ticket test')),
          if (_busy) const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator())),
          if (_msg != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(_msg!, style: TextStyle(color: _ok ? Colors.green.shade700 : Theme.of(context).colorScheme.error, fontSize: 16)),
            ),
        ]),
      );
}
