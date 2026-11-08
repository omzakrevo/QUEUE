import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.onLogin});
  final void Function(Session) onLogin;
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _server = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _terminal = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      _server.text = p.getString('server') ?? '';
      final t = p.getInt('terminal');
      if (t != null) _terminal.text = '$t';
    });
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final s = await Api.login(_server.text, _user.text.trim(), _pass.text,
          terminalId: int.tryParse(_terminal.text.trim()));
      widget.onLogin(s);
    } catch (e) {
      setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: ListView(shrinkWrap: true, padding: const EdgeInsets.all(24), children: [
              Text('OMZA QUEUE', style: Theme.of(context).textTheme.headlineMedium, textAlign: TextAlign.center),
              const SizedBox(height: 24),
              TextField(
                  controller: _server,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                      labelText: 'Adresse du serveur', hintText: '192.168.1.10', border: OutlineInputBorder())),
              const SizedBox(height: 12),
              TextField(
                  controller: _user,
                  autocorrect: false,
                  decoration: const InputDecoration(labelText: 'Identifiant', border: OutlineInputBorder())),
              const SizedBox(height: 12),
              TextField(
                  controller: _pass,
                  obscureText: true,
                  onSubmitted: (_) => _submit(),
                  decoration: const InputDecoration(labelText: 'Mot de passe', border: OutlineInputBorder())),
              const SizedBox(height: 12),
              TextField(
                  controller: _terminal,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                      labelText: 'N° de terminal (borne uniquement, facultatif)', border: OutlineInputBorder())),
              if (_error != null)
                Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
              const SizedBox(height: 16),
              FilledButton(
                  onPressed: _busy ? null : _submit,
                  child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: _busy
                          ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Text('Se connecter'))),
            ]),
          ),
        ),
      );
}
