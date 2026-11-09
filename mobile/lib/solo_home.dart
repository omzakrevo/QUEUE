import 'package:flutter/material.dart';

import 'agent_screen.dart';
import 'kiosk_screen.dart';
import 'local_host.dart';
import 'settings_screen.dart';

/// Application autonome : tickets, guichet et réglages sur le même téléphone.
class SoloHome extends StatefulWidget {
  const SoloHome({super.key, required this.host, required this.onResetMode});
  final LocalHost host;
  final Future<void> Function() onResetMode;
  @override
  State<SoloHome> createState() => _SoloHomeState();
}

class _SoloHomeState extends State<SoloHome> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final h = widget.host;
    return Scaffold(
      body: IndexedStack(index: _tab, children: [
        KioskScreen(backend: h.backend, embedded: true),
        AgentScreen(backend: h.backend, userName: 'Agent'),
        SettingsScreen(host: h, onResetMode: widget.onResetMode),
      ]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.confirmation_number_outlined), label: 'Tickets'),
          NavigationDestination(icon: Icon(Icons.support_agent), label: 'Guichet'),
          NavigationDestination(icon: Icon(Icons.settings_outlined), label: 'Réglages'),
        ],
      ),
    );
  }
}
