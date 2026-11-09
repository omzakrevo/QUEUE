import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'core/engine.dart';
import 'kiosk_screen.dart' show parseColor;
import 'local_host.dart';

const _palette = ['#1e88e5', '#43a047', '#e53935', '#8e24aa', '#fb8c00', '#00897b', '#6d4c41', '#546e7a'];

/// Réglages de l'application autonome : services, voix, partage (serveur), statistiques.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.host, required this.onResetMode});
  final LocalHost host;
  final Future<void> Function() onResetMode;
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  List<Map<String, Object?>> _services = [];
  Map<String, String> _settings = {};
  Map<String, Object?> _stats = {};
  final _org = TextEditingController();

  LocalHost get h => widget.host;
  QueueEngine get e => h.engine;

  @override
  void initState() {
    super.initState();
    h.addListener(_rebuild);
    _load();
  }

  @override
  void dispose() {
    h.removeListener(_rebuild);
    _org.dispose();
    super.dispose();
  }

  void _rebuild() => mounted ? setState(() {}) : null;

  Future<void> _load() async {
    final s = await e.services();
    final cfg = await e.settings();
    final st = await e.summary();
    if (!mounted) return;
    setState(() {
      _services = s;
      _settings = cfg;
      _stats = st;
      if (_org.text.isEmpty) _org.text = cfg['org_name'] ?? '';
    });
  }

  Future<void> _set(Map<String, String> v) async {
    await e.setSettings(v);
    await _load();
  }

  Future<void> _editService([Map<String, Object?>? s]) async {
    final name = TextEditingController(text: s?['name'] as String? ?? '');
    final code = TextEditingController(text: s?['code'] as String? ?? '');
    var color = s?['color'] as String? ?? _palette[_services.length % _palette.length];
    var active = s?['active'] as bool? ?? true;
    String? err;
    await showDialog<void>(
        context: context,
        builder: (c) => StatefulBuilder(
            builder: (c, set) => AlertDialog(
                  title: Text(s == null ? 'Nouveau service' : 'Modifier le service'),
                  content: SingleChildScrollView(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      TextField(controller: name, decoration: const InputDecoration(labelText: 'Nom (ex. Caisse)')),
                      TextField(
                          controller: code,
                          maxLength: 4,
                          textCapitalization: TextCapitalization.characters,
                          decoration: const InputDecoration(labelText: 'Code (ex. B)', helperText: 'Les tickets seront B001, B002…')),
                      Wrap(spacing: 8, children: [
                        for (final p in _palette)
                          GestureDetector(
                            onTap: () => set(() => color = p),
                            child: CircleAvatar(
                                radius: 16, backgroundColor: parseColor(p), child: color == p ? const Icon(Icons.check, color: Colors.white, size: 18) : null),
                          ),
                      ]),
                      SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Actif'), value: active, onChanged: (v) => set(() => active = v)),
                      if (err != null) Text(err!, style: TextStyle(color: Theme.of(c).colorScheme.error)),
                    ]),
                  ),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(c), child: const Text('Annuler')),
                    FilledButton(
                        onPressed: () async {
                          try {
                            await e.saveService(id: s?['id'] as int?, name: name.text, code: code.text, color: color, active: active);
                            if (c.mounted) Navigator.pop(c);
                          } on EngineException catch (x) {
                            set(() => err = x.code == 'already_exists' ? 'Ce code existe déjà.' : 'Nom et code (4 caractères max) requis.');
                          }
                        },
                        child: const Text('Enregistrer')),
                  ],
                )));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final tot = (_stats['totals'] as Map?) ?? {};
    return Scaffold(
      appBar: AppBar(title: const Text('Réglages')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        _title('Établissement'),
        TextField(
            controller: _org,
            decoration: const InputDecoration(labelText: 'Nom affiché sur la borne', border: OutlineInputBorder()),
            onSubmitted: (v) => _set({'org_name': v.trim().isEmpty ? 'OMZA QUEUE' : v.trim()})),
        const SizedBox(height: 8),
        _title('Services'),
        for (final s in _services)
          ListTile(
            leading: CircleAvatar(backgroundColor: parseColor(s['color'] as String?), child: Text('${s['code']}', style: const TextStyle(color: Colors.white))),
            title: Text('${s['name']}'),
            subtitle: Text((s['active'] as bool) ? 'Actif' : 'Désactivé'),
            trailing: const Icon(Icons.edit_outlined),
            onTap: () => _editService(s),
          ),
        Align(alignment: Alignment.centerLeft, child: TextButton.icon(onPressed: _editService, icon: const Icon(Icons.add), label: const Text('Ajouter un service'))),
        _title('Annonces vocales'),
        SwitchListTile(
            title: const Text('Annoncer les appels à voix haute'),
            subtitle: const Text('Voix du téléphone, sans Internet. Pensez à monter le volume.'),
            value: _settings['voice_enabled'] != 'false',
            onChanged: (v) => _set({'voice_enabled': '$v'})),
        ListTile(
          title: const Text('Répétitions'),
          trailing: SegmentedButton<String>(
            segments: [for (final n in ['1', '2', '3']) ButtonSegment(value: n, label: Text(n))],
            selected: {_settings['voice_repeat'] ?? '1'},
            onSelectionChanged: (v) => _set({'voice_repeat': v.first}),
          ),
        ),
        Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
                onPressed: () => h.announcer.say('Numéro A 25, veuillez vous présenter au guichet numéro 1.'),
                icon: const Icon(Icons.volume_up),
                label: const Text('Tester la voix'))),
        _title('Partager ce téléphone (serveur)'),
        SwitchListTile(
          title: const Text('Servir d’autres appareils'),
          subtitle: const Text('Active le suivi par QR Code, un écran TV (navigateur) et d’autres postes. '
              'Les appareils doivent être sur le même Wi-Fi, ou sur le point d’accès de ce téléphone.'),
          value: h.sharing,
          onChanged: (v) => h.setSharing(v),
        ),
        if (h.error != null) Text(h.error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        if (h.sharing) ..._sharing(context),
        _title('Aujourd’hui'),
        Wrap(spacing: 8, children: [
          _chip('Tickets', '${tot['total'] ?? 0}'),
          _chip('Servis', '${tot['served'] ?? 0}'),
          _chip('Absents', '${tot['absent'] ?? 0}'),
          _chip('Annulés', '${tot['cancelled'] ?? 0}'),
          _chip('Attente moy.', _fmt(tot['avg_wait_s'])),
        ]),
        TextButton(onPressed: _load, child: const Text('Actualiser')),
        _title('Numérotation'),
        Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
                onPressed: () async {
                  final ok = await _confirm('Remettre les numéros à zéro ?', 'Le prochain ticket de chaque service sera 001.');
                  if (ok) {
                    await e.resetNumbering();
                    await _load();
                  }
                },
                child: const Text('Remettre les compteurs à zéro'))),
        const SizedBox(height: 16),
        const Divider(),
        TextButton(
            onPressed: () async {
              if (await _confirm('Changer de mode ?', 'Les données de ce téléphone sont conservées.')) await widget.onResetMode();
            },
            child: const Text('Changer de mode d’utilisation')),
      ]),
    );
  }

  List<Widget> _sharing(BuildContext context) {
    final codes = h.newCodes;
    return [
      if (h.addresses.isEmpty)
        const ListTile(leading: Icon(Icons.wifi_off), title: Text('Aucune adresse réseau trouvée'), subtitle: Text('Connectez ce téléphone à un Wi-Fi ou activez son point d’accès.')),
      for (final a in h.addresses)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(children: [
              SelectableText(a, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Container(color: Colors.white, padding: const EdgeInsets.all(6), child: QrImageView(data: a, size: 140)),
              Text('Pages : $a/tv · $a/kiosk · $a/agent', textAlign: TextAlign.center),
              TextButton(onPressed: () => Clipboard.setData(ClipboardData(text: a)), child: const Text('Copier')),
            ]),
          ),
        ),
      if (codes != null)
        Card(
          color: Theme.of(context).colorScheme.tertiaryContainer,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Codes d’accès — notez-les maintenant, ils ne seront plus affichés :', style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              for (final c in codes.entries) SelectableText('${c.key} : ${c.value}', style: const TextStyle(fontSize: 18, fontFamily: 'monospace')),
              Align(alignment: Alignment.centerRight, child: TextButton(onPressed: h.dismissCodes, child: const Text('J’ai noté'))),
            ]),
          ),
        ),
      Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton(
              onPressed: () async {
                if (await _confirm('Générer de nouveaux codes ?', 'Les appareils connectés devront se reconnecter avec les nouveaux codes.')) {
                  await h.regenerateCodes();
                }
              },
              child: const Text('Générer de nouveaux codes d’accès'))),
    ];
  }

  Future<bool> _confirm(String title, String text) async =>
      await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(title: Text(title), content: Text(text), actions: [
                TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Annuler')),
                FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Confirmer')),
              ])) ??
      false;

  Widget _title(String t) => Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 6), child: Text(t, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)));

  Widget _chip(String l, String v) => Chip(label: Text('$l : $v'));

  static String _fmt(Object? s) => s == null ? '—' : (s as int) < 60 ? '$s s' : '${(s / 60).round()} min';
}
