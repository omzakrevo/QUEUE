import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:omza_queue/core/auth.dart';
import 'package:omza_queue/core/engine.dart';
import 'package:omza_queue/core/server.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  late QueueEngine engine;
  late Auth auth;
  late LocalServer server;
  late String base;
  late Map<String, String> codes;
  final tokens = <String, String>{};

  Future<http.Response> call(String method, String path, {Object? body, String? who}) {
    final req = http.Request(method, Uri.parse('$base$path'))..headers['content-type'] = 'application/json';
    if (who != null) req.headers['authorization'] = 'Bearer ${tokens[who]}';
    if (body != null) req.body = jsonEncode(body);
    return req.send().then(http.Response.fromStream);
  }

  Map<String, dynamic> j(http.Response r) => jsonDecode(r.body) as Map<String, dynamic>;

  setUpAll(() async {
    engine = await QueueEngine.open(await databaseFactoryFfi.openDatabase(inMemoryDatabasePath));
    await engine.saveService(name: 'Caisse', code: 'B');
    await engine.setSettings({'org_name': 'Boutique Test'});
    auth = Auth(engine);
    codes = await auth.provisionDevices();
    // Les pages web sont celles du serveur Windows (même dossier public).
    server = LocalServer(engine, auth, (path) async {
      final f = File('../server/public/$path');
      return f.existsSync() ? f.readAsBytes() : null;
    }, port: 0);
    await server.start(address: InternetAddress.loopbackIPv4);
    base = 'http://127.0.0.1:${server.boundPort}';
    for (final u in codes.keys) {
      final r = await call('POST', '/api/auth/login', body: {'username': u, 'password': codes[u]});
      expect(r.statusCode, 200, reason: 'login $u');
      tokens[u] = j(r)['token'] as String;
    }
  });

  tearDownAll(() async {
    await server.stop();
    await engine.close();
  });

  test('sécurité : authentification et rôles', () async {
    expect((await call('POST', '/api/tickets', body: {'service_id': 1})).statusCode, 401);
    expect((await call('POST', '/api/agent/call-next', who: 'borne1')).statusCode, 403);
    expect((await call('GET', '/api/display/state', who: 'borne1')).statusCode, 403);
    expect((await call('POST', '/api/auth/login', body: {'username': 'admin', 'password': 'faux'})).statusCode, 401);
    final stored = (await engine.db.query('users', where: "username='admin'")).first['password_hash'] as String;
    expect(stored, startsWith('pbkdf2\$'));
    expect(stored, isNot(contains(codes['admin']!)));
    expect(codes.values.every((c) => RegExp(r'^\d{6}$').hasMatch(c)), isTrue);
  });

  test('parcours complet : borne → agent → TV → suivi QR (API identique au serveur Windows)', () async {
    final tk = j(await call('POST', '/api/tickets', body: {'service_id': 1, 'priority': 9}, who: 'borne1'));
    expect(tk['ticket']['ticket_number'], 'A001');
    expect(tk['ticket']['priority'], 0, reason: 'la borne ne choisit pas la priorité');
    final token = tk['ticket']['access_token'] as String;
    expect(tk['qr_url'], endsWith('/t/$token'));

    var pub = j(await call('GET', '/api/public/ticket/$token'));
    expect(pub['status'], 'soon');
    expect(pub['org'], 'Boutique Test');

    expect((await call('POST', '/api/agent/counter/open', who: 'agent1')).statusCode, 200);
    final called = j(await call('POST', '/api/agent/call-next', who: 'agent1'));
    expect(called['status'], 'called');
    expect(called['counter_number'], 1);

    final tv = j(await call('GET', '/api/display/state', who: 'tv1'));
    expect((tv['current'] as List).first['ticket_number'], 'A001');
    expect((tv['settings'] as Map)['announce_template'], contains('{ticket}'));

    pub = j(await call('GET', '/api/public/ticket/$token'));
    expect(pub['status'], 'called');
    expect(pub['counter'], 1);

    final done = j(await call('POST', '/api/agent/tickets/${called['id']}/complete', who: 'agent1'));
    expect(done['status'], 'done');
    expect(j(await call('GET', '/api/public/ticket/$token'))['status'], 'done');
    expect(j(await call('POST', '/api/agent/call-next', who: 'agent1'))['error'], 'queue_empty');
  });

  test('QR en SVG local et jeton invalide', () async {
    final tk = j(await call('POST', '/api/tickets', body: {'service_id': 2}, who: 'borne1'));
    final r = await call('GET', '/api/public/qr/${tk['ticket']['access_token']}');
    expect(r.statusCode, 200);
    expect(r.headers['content-type'], contains('svg'));
    expect(r.body, contains('<svg'));
    expect((await call('GET', '/api/public/qr/deadbeef')).statusCode, 404);
    expect((await call('GET', '/api/public/ticket/${'0' * 32}')).statusCode, 404);
  });

  test('temps réel : flux d\'événements privé (TV) et public (QR, sans détails)', () async {
    final start = j(await call('GET', '/api/events?scope=main', who: 'tv1'));
    final last = start['last'] as int;
    final pubStart = j(await call('GET', '/api/events?scope=public'));
    await call('POST', '/api/tickets', body: {'service_id': 1}, who: 'borne1');
    final ev = j(await call('GET', '/api/events?scope=main&since=$last', who: 'tv1'));
    expect((ev['events'] as List).map((e) => e['name']), contains('ticket.created'));
    final pub = j(await call('GET', '/api/events?scope=public&since=${pubStart['last']}'));
    for (final e in pub['events'] as List) {
      expect(e['name'], 'queue.updated');
      expect((e['payload'] as Map).keys, ['service_id']);
    }
    expect((await call('GET', '/api/events?scope=main')).statusCode, 401, reason: 'le flux privé exige un jeton');
  });

  test('pages web et client temps réel de remplacement servis localement', () async {
    for (final p in ['/', '/tv', '/kiosk', '/agent', '/t/abc', '/shared/common.js', '/shared/common.css']) {
      expect((await call('GET', p)).statusCode, 200, reason: p);
    }
    final shim = await call('GET', '/socket.io/socket.io.js');
    expect(shim.body, contains('window.io=io'));
    expect((await call('GET', '/shared/../../etc/passwd')).statusCode, 404);
    expect((await call('GET', '/admin')).statusCode, 404, reason: 'pas de page admin sur le téléphone');
  });
}
