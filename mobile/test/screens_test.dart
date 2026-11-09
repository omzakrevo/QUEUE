import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omza_queue/agent_screen.dart';
import 'package:omza_queue/announcer.dart';
import 'package:omza_queue/core/engine.dart';
import 'package:omza_queue/kiosk_screen.dart';
import 'package:omza_queue/local_backend.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Les accès base de données tournent dans le temps réel, l'interface dans le temps simulé :
/// on alterne donc attente réelle et rafraîchissement jusqu'à ce que tout soit terminé.
Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 12; i++) {
    await t.pump();
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
  }
  await t.pump();
}

void main() {
  sqfliteFfiInit();

  test('phrase d\'annonce : A025 se lit « A 25 »', () {
    expect(Announcer.sentence(defaultSettings['announce_template']!, 'A025', 1),
        'Numéro A 25, veuillez vous présenter au guichet numéro 1.');
    expect(Announcer.sentence('{ticket} / {counter}', 'B100', 3), 'B 100 / 3');
  });

  testWidgets('application autonome : le visiteur prend un ticket, l\'agent l\'appelle et le termine', (tester) async {
    late QueueEngine engine;
    late LocalBackend backend;
    await tester.runAsync(() async {
      engine = await QueueEngine.open(await databaseFactoryFfi.openDatabase(inMemoryDatabasePath));
      final counter = await engine.firstCounterId();
      await engine.setCounterStatus(counter, 'open');
      backend = LocalBackend(engine, counter);
    });

    // --- Borne
    await tester.pumpWidget(MaterialApp(home: KioskScreen(backend: backend, embedded: true)));
    await settle(tester);
    expect(find.text('Accueil'), findsOneWidget);
    await tester.tap(find.text('Accueil'));
    await settle(tester);
    expect(find.text('A001'), findsOneWidget, reason: 'le ticket est affiché');
    expect(find.textContaining('Gardez votre numéro'), findsOneWidget, reason: 'sans serveur partagé : pas de QR');
    await tester.tap(find.text('Fermer'));
    await tester.pump();

    // --- Agent
    await tester.pumpWidget(MaterialApp(home: AgentScreen(backend: backend, userName: 'Agent')));
    await settle(tester);
    expect(find.text('APPELER LE SUIVANT'), findsOneWidget);
    await tester.tap(find.text('APPELER LE SUIVANT'));
    await settle(tester);
    expect(find.text('A001'), findsOneWidget);
    await tester.tap(find.text('Terminer'));
    await settle(tester);
    expect(find.text('Aucun client en cours'), findsOneWidget);

    await tester.runAsync(() async {
      final s = await engine.summary();
      expect((s['totals'] as Map)['served'], 1);
      backend.dispose();
      await engine.close();
    });
  });
}
