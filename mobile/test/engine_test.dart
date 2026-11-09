import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omza_queue/core/engine.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<QueueEngine> memEngine({DateTime Function()? clock}) async {
  final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
  return QueueEngine.open(db, clock: clock);
}

Future<void> expectCode(Future<Object?> f, String code) async {
  try {
    await f;
  } on EngineException catch (e) {
    expect(e.code, code);
    return;
  }
  fail('EngineException($code) attendue');
}

void main() {
  sqfliteFfiInit();

  late QueueEngine e;
  late int a, b, k1, k2;

  setUp(() async {
    e = await memEngine();
    a = (await e.services()).first['id'] as int; // Accueil (A) créé par défaut
    b = (await e.saveService(name: 'Caisse', code: 'B', color: '#43a047'))['id'] as int;
    k1 = await e.firstCounterId();
    k2 = (await e.addCounter())['id'] as int;
    await e.setCounterStatus(k1, 'open');
    await e.setCounterStatus(k2, 'open');
  });
  tearDown(() => e.close());

  test('60 demandes simultanées : aucun doublon, numérotation continue', () async {
    final r = await Future.wait(List.generate(60, (_) => e.createTicket(a)));
    final nums = r.map((t) => t['ticket_number'] as String).toList()..sort();
    expect(nums.toSet().length, 60);
    expect(nums.first, 'A001');
    expect(nums.last, 'A060');
  });

  test('files indépendantes par service, 100 tickets', () async {
    final r = await Future.wait([for (var i = 0; i < 100; i++) e.createTicket(b)]);
    expect(r.map((t) => t['ticket_number']).toSet().length, 100);
    expect((await e.createTicket(a))['ticket_number'], 'A001');
    expect((await e.createTicket(b))['ticket_number'], 'B101');
  });

  test('appel : priorité > ancienneté ; deux guichets ne prennent jamais le même ticket', () async {
    final t1 = await e.createTicket(a);
    final t2 = await e.createTicket(a);
    final t3 = await e.createTicket(a);
    await e.setPriority(t3['id'] as int, 2);
    final r = await Future.wait([e.callNext(k1), e.callNext(k2)]);
    final ids = r.map((t) => t['id']).toSet();
    expect(ids.length, 2);
    expect(ids, containsAll([t3['id'], t1['id']]));
    expect(ids, isNot(contains(t2['id'])));
    await expectCode(e.callNext(k1), 'ticket_in_progress');
  });

  test('cycle agent : rappeler, ignorer, démarrer, transférer, absent, terminer, pause', () async {
    final t1 = (await e.createTicket(a))['id'] as int;
    final t2 = (await e.createTicket(a))['id'] as int;
    expect((await e.callNext(k1))['id'], t1);
    expect((await e.recall(t1, k1))['status'], 'called');
    await expectCode(e.complete(t1, k2), 'not_your_ticket');
    expect((await e.skip(t1, k1))['status'], 'waiting');
    final n = await e.callNext(k1);
    expect(n['id'], t2, reason: 'le ticket ignoré est repassé derrière');
    expect((await e.start(t2, k1))['status'], 'serving');
    final tr = await e.transfer(t2, k1, b);
    expect(tr['service_id'], b);
    expect(tr['ticket_number'], 'A002', reason: 'le numéro est conservé');
    expect((await e.callNext(k1))['id'], t1);
    expect((await e.markAbsent(t1, k1))['status'], 'absent');
    await e.setCounterStatus(k1, 'paused');
    await expectCode(e.callNext(k1), 'counter_paused');
    await e.setCounterStatus(k1, 'open');
    final last = await e.callNext(k1);
    expect((await e.complete(last['id'] as int, k1))['status'], 'done');
    await expectCode(e.callNext(k1), 'queue_empty');
  });

  test('suivi public : statut, position, aucune donnée sensible', () async {
    final tickets = [for (var i = 0; i < 4; i++) await e.createTicket(a)];
    final token = tickets[3]['access_token'] as String;
    var p = (await e.publicTicket(token))!;
    expect(p['status'], 'waiting');
    expect(p['ahead'], 3);
    expect(p['position'], 4);
    expect(p.keys.toSet(), {'ticket_number', 'service', 'color', 'status', 'position', 'ahead', 'estimate_minutes', 'counter', 'org'});
    final c = await e.callNext(k1);
    await e.complete(c['id'] as int, k1);
    p = (await e.publicTicket(token))!;
    expect(p['ahead'], 2);
    expect(p['status'], 'soon');
    expect(await e.publicTicket('deadbeef'), isNull);
  });

  test('événements temps réel émis pour chaque transition', () async {
    final names = <String>[];
    final sub = e.events.listen((ev) => names.add(ev.name));
    final t = (await e.createTicket(a))['id'] as int;
    await e.callNext(k1);
    await e.recall(t, k1);
    await e.complete(t, k1);
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    expect(names, containsAllInOrder(['ticket.created', 'ticket.called', 'ticket.recalled', 'ticket.completed']));
  });

  test('numérotation : quotidienne par défaut, remise à zéro manuelle', () async {
    var now = DateTime(2026, 11, 8, 9);
    final eng = await memEngine(clock: () => now);
    final s = (await eng.services()).first['id'] as int;
    expect((await eng.createTicket(s))['ticket_number'], 'A001');
    expect((await eng.createTicket(s))['ticket_number'], 'A002');
    now = DateTime(2026, 11, 9, 9);
    expect((await eng.createTicket(s))['ticket_number'], 'A001', reason: 'nouveau jour');
    await eng.resetNumbering();
    expect((await eng.createTicket(s))['ticket_number'], 'A001', reason: 'mode manuel, nouvelle époque');
    expect((await eng.createTicket(s))['ticket_number'], 'A002');
    await eng.close();
  });

  test('statistiques de la journée', () async {
    final t = (await e.createTicket(a))['id'] as int;
    await e.callNext(k1);
    await e.complete(t, k1);
    final x = await e.createTicket(a);
    await e.cancel(x['id'] as int);
    final s = await e.summary();
    final tot = s['totals'] as Map;
    expect(tot['total'], 2);
    expect(tot['served'], 1);
    expect(tot['cancelled'], 1);
  });

  test('données conservées après fermeture et réouverture de la base', () async {
    final dir = Directory.systemTemp.createTempSync('omza');
    final path = '${dir.path}/q.db';
    var eng = await QueueEngine.open(await databaseFactoryFfi.openDatabase(path));
    final s = (await eng.services()).first['id'] as int;
    await eng.createTicket(s);
    await eng.createTicket(s);
    await eng.close();
    eng = await QueueEngine.open(await databaseFactoryFfi.openDatabase(path));
    expect((await eng.createTicket(s))['ticket_number'], 'A003');
    expect((await eng.services()).length, 1, reason: 'pas de re-création des données par défaut');
    await eng.close();
    dir.deleteSync(recursive: true);
  });
}
