import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'agent_screen.dart';
import 'api.dart';
import 'backend.dart';
import 'kiosk_screen.dart';
import 'local_host.dart';
import 'login_screen.dart';
import 'mode_screen.dart';
import 'solo_home.dart';

void main() => runApp(const OmzaQueueApp());

class OmzaQueueApp extends StatelessWidget {
  const OmzaQueueApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'OMZA QUEUE',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: const Color(0xFF1E5EFF), useMaterial3: true),
        darkTheme: ThemeData(colorSchemeSeed: const Color(0xFF1E5EFF), brightness: Brightness.dark, useMaterial3: true),
        home: const Root(),
      );
}

/// Aiguillage : choix du mode (ce téléphone seul / connexion à un serveur), puis écran selon le rôle.
class Root extends StatefulWidget {
  const Root({super.key});
  @override
  State<Root> createState() => _RootState();
}

class _RootState extends State<Root> {
  bool _loading = true;
  String? _mode; // local | remote
  LocalHost? _host;
  Session? _session;
  RemoteBackend? _remote;
  String? _fatal;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    final mode = prefs.getString('mode');
    if (mode == 'local') {
      await _openLocal();
    } else if (mode == 'remote') {
      await _openRemote();
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _openLocal() async {
    try {
      _host = await LocalHost.open();
      _mode = 'local';
    } catch (e) {
      _fatal = 'Impossible d’ouvrir la base de données locale : $e';
    }
  }

  Future<void> _openRemote() async {
    _mode = 'remote';
    final s = await Api.restore();
    _setSession(s);
  }

  void _setSession(Session? s) {
    _remote?.dispose();
    _remote = null;
    _session = s;
    if (s != null) _remote = RemoteBackend(Api(s));
  }

  Future<void> _choose(String mode) async {
    await (await SharedPreferences.getInstance()).setString('mode', mode);
    setState(() => _loading = true);
    if (mode == 'local') {
      await _openLocal();
    } else {
      await _openRemote();
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _resetMode() async {
    await (await SharedPreferences.getInstance()).remove('mode');
    _host?.dispose();
    _host = null;
    _setSession(null);
    setState(() => _mode = null);
  }

  Future<void> _logout() async {
    await Api.logout();
    setState(() => _setSession(null));
  }

  @override
  void dispose() {
    _host?.dispose();
    _remote?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (_fatal != null) return Scaffold(body: Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_fatal!))));
    if (_mode == null) return ModeScreen(onChoose: _choose);
    if (_mode == 'local') return SoloHome(host: _host!, onResetMode: _resetMode);

    final s = _session;
    if (s == null) {
      return LoginScreen(onLogin: (x) => setState(() => _setSession(x)), onBack: _resetMode);
    }
    switch (s.role) {
      case 'borne':
        return KioskScreen(backend: _remote!, onLogout: _logout);
      case 'agent':
      case 'superviseur':
      case 'administrateur':
        return AgentScreen(backend: _remote!, userName: s.name, onLogout: _logout);
      default:
        return Scaffold(
          appBar: AppBar(title: const Text('OMZA QUEUE')),
          body: Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('Ce compte n’a pas d’interface dans l’application.'),
            const SizedBox(height: 12),
            FilledButton(onPressed: _logout, child: const Text('Changer de compte')),
          ])),
        );
    }
  }
}
