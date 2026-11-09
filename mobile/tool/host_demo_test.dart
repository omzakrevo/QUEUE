// Serveur embarqué lançable sans appareil (vérification dans un navigateur) :
//   flutter test tool/host_demo_test.dart --dart-define=PORT=3100
// Il tourne jusqu'à la création du fichier /tmp/omza_host_stop.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omza_queue/core/auth.dart';
import 'package:omza_queue/core/engine.dart';
import 'package:omza_queue/core/server.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  test('serveur de démonstration', () async {
    sqfliteFfiInit();
    final engine = await QueueEngine.open(await databaseFactoryFfi.openDatabase(inMemoryDatabasePath));
    await engine.saveService(name: 'Caisse', code: 'B', color: '#43a047');
    await engine.setSettings({'org_name': 'Boutique Démo'});
    final auth = Auth(engine);
    final codes = await auth.provisionDevices();
    final server = LocalServer(engine, auth, (p) async {
      final f = File('../server/public/$p');
      return f.existsSync() ? f.readAsBytes() : null;
    }, port: const int.fromEnvironment('PORT', defaultValue: 3100));
    await server.start();
    stdout.writeln('CODES ${codes.entries.map((e) => '${e.key}=${e.value}').join(' ')}');
    stdout.writeln('READY ${server.boundPort}');
    final stop = File('/tmp/omza_host_stop');
    while (!stop.existsSync()) {
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    await server.stop();
  }, timeout: const Timeout(Duration(minutes: 15)));
}
