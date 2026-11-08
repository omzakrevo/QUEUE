import 'package:flutter/material.dart';

import 'agent_screen.dart';
import 'api.dart';
import 'kiosk_screen.dart';
import 'login_screen.dart';

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

/// Choisit l'écran selon le rôle du compte : borne -> distribution, agent -> poste de guichet.
class Root extends StatefulWidget {
  const Root({super.key});
  @override
  State<Root> createState() => _RootState();
}

class _RootState extends State<Root> {
  Session? _session;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    Api.restore().then((s) => setState(() {
          _session = s;
          _loading = false;
        }));
  }

  Future<void> _logout() async {
    await Api.logout();
    setState(() => _session = null);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final s = _session;
    if (s == null) return LoginScreen(onLogin: (x) => setState(() => _session = x));
    final api = Api(s);
    switch (s.role) {
      case 'borne':
        return KioskScreen(api: api, onLogout: _logout);
      case 'agent':
      case 'superviseur':
      case 'administrateur':
        return AgentScreen(api: api, onLogout: _logout);
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
