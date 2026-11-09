import 'package:flutter/material.dart';

/// Premier lancement : ce téléphone fonctionne seul (et peut servir d'autres appareils),
/// ou il se connecte au serveur d'un autre appareil.
class ModeScreen extends StatelessWidget {
  const ModeScreen({super.key, required this.onChoose});
  final void Function(String mode) onChoose;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: ListView(shrinkWrap: true, padding: const EdgeInsets.all(24), children: [
                Text('OMZA QUEUE', style: Theme.of(context).textTheme.headlineMedium, textAlign: TextAlign.center),
                const SizedBox(height: 8),
                const Text('Comment voulez-vous utiliser cette application ?', textAlign: TextAlign.center),
                const SizedBox(height: 24),
                _card(context, Icons.smartphone, 'Ce téléphone seul',
                    'Les visiteurs prennent leur ticket sur ce téléphone, vous appelez depuis ce même téléphone, '
                    'avec annonce vocale. Aucun serveur, aucune TV. Vous pourrez ensuite partager ce téléphone '
                    'comme serveur pour d’autres appareils.',
                    () => onChoose('local')),
                const SizedBox(height: 12),
                _card(context, Icons.lan, 'Se connecter à un serveur',
                    'Cet appareil est une borne ou un poste agent connecté au serveur de l’établissement '
                    '(PC Windows ou un autre téléphone).',
                    () => onChoose('remote')),
              ]),
            ),
          ),
        ),
      );

  Widget _card(BuildContext c, IconData icon, String title, String text, VoidCallback onTap) => Card(
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Row(children: [
              Icon(icon, size: 40),
              const SizedBox(width: 16),
              Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: Theme.of(c).textTheme.titleLarge),
                const SizedBox(height: 4),
                Text(text),
              ])),
            ]),
          ),
        ),
      );
}
