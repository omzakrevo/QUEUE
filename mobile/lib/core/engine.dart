import 'dart:async';
import 'dart:math';

import 'package:sqflite_common/sqlite_api.dart';
import 'package:sqflite_common/utils/utils.dart';

typedef Json = Map<String, Object?>;

/// Erreur métier ; `code` reprend les codes de l'API du serveur Windows
/// (queue_empty, counter_paused, ticket_in_progress, ...).
class EngineException implements Exception {
  EngineException(this.code, [this.status = 409]);
  final String code;
  final int status;
  @override
  String toString() => code;
}

class EngineEvent {
  EngineEvent(this.name, this.payload, [this.serviceId]);
  final String name;
  final Object? payload;
  final int? serviceId;
}

const defaultSettings = <String, String>{
  'reset_mode': 'daily', // daily | manual
  'counter_epoch': '0',
  'default_service_minutes': '5',
  'ticket_message': 'Merci de votre patience.',
  'voice_enabled': 'true',
  'voice_repeat': '1',
  'voice_volume': '1',
  'announce_template': 'Numéro {ticket}, veuillez vous présenter au guichet numéro {counter}.',
  'ticker_message': 'Bienvenue',
  'org_name': 'OMZA QUEUE',
};

const _schema = <String>[
  '''create table if not exists services(
    id integer primary key autoincrement, name text not null, code text not null unique,
    description text, color text not null default '#1e88e5', priority integer not null default 0,
    active integer not null default 1)''',
  '''create table if not exists counters(
    id integer primary key autoincrement, name text not null, number integer not null unique,
    status text not null default 'closed')''',
  '''create table if not exists counter_services(
    counter_id integer not null references counters(id) on delete cascade,
    service_id integer not null references services(id) on delete cascade,
    primary key(counter_id, service_id))''',
  '''create table if not exists ticket_counters(
    service_id integer not null, scope_key text not null, last_number integer not null default 0,
    primary key(service_id, scope_key))''',
  '''create table if not exists tickets(
    id integer primary key autoincrement, ticket_number text not null,
    origin_service_id integer not null, scope_key text not null, seq integer not null,
    service_id integer not null, counter_id integer, status text not null default 'waiting',
    priority integer not null default 0, access_token text not null unique,
    created_at integer not null, queue_at integer not null,
    called_at integer, started_at integer, completed_at integer,
    unique(origin_service_id, scope_key, seq))''',
  'create index if not exists tickets_queue_idx on tickets(service_id, status, priority desc, queue_at, id)',
  'create index if not exists tickets_created_idx on tickets(created_at)',
  '''create table if not exists ticket_events(
    id integer primary key autoincrement, ticket_id integer not null, event_type text not null,
    user_id integer, created_at integer not null, details text)''',
  'create table if not exists settings(setting_key text primary key, setting_value text)',
  '''create table if not exists users(
    id integer primary key autoincrement, name text not null, username text not null unique,
    password_hash text not null, role text not null, status text not null default 'active')''',
  'create table if not exists agents(user_id integer primary key, counter_id integer)',
  'create table if not exists sessions(token text primary key, user_id integer not null, expires_at integer not null)',
];

/// Moteur de files d'attente embarqué : mêmes règles que le serveur Node/PostgreSQL.
/// Dart n'exécute qu'une tâche à la fois et chaque opération est sérialisée par un verrou :
/// deux demandes simultanées ne peuvent jamais recevoir le même numéro.
class QueueEngine {
  QueueEngine._(this.db, this._now);
  final Database db;
  final DateTime Function() _now;
  final _events = StreamController<EngineEvent>.broadcast();
  Stream<EngineEvent> get events => _events.stream;
  Future<void> _tail = Future.value();

  static Future<QueueEngine> open(Database db, {DateTime Function()? clock}) async {
    await db.execute('pragma foreign_keys = on');
    for (final s in _schema) {
      await db.execute(s);
    }
    final e = QueueEngine._(db, clock ?? DateTime.now);
    await e._seedIfEmpty();
    return e;
  }

  Future<void> close() async {
    await _events.close();
    await db.close();
  }

  /// Sérialise les opérations (exclusion mutuelle).
  Future<T> _locked<T>(Future<T> Function() f) {
    final c = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        c.complete(await f());
      } catch (e, st) {
        c.completeError(e, st);
      }
    });
    return c.future;
  }

  int get _ms => _now().millisecondsSinceEpoch;
  static String _iso(Object? ms) =>
      ms == null ? '' : DateTime.fromMillisecondsSinceEpoch(ms as int).toIso8601String();

  void _emit(String name, Object? payload, [int? serviceId]) => _events.add(EngineEvent(name, payload, serviceId));

  Future<void> _seedIfEmpty() async {
    final n = firstIntValue(await db.rawQuery('select count(*) from services')) ?? 0;
    if (n > 0) return;
    await db.transaction((t) async {
      final s = await t.insert('services', {'name': 'Accueil', 'code': 'A', 'color': '#1e88e5'});
      final c = await t.insert('counters', {'name': 'Guichet 1', 'number': 1});
      await t.insert('counter_services', {'counter_id': c, 'service_id': s});
    });
  }

  // ------------------------------------------------------------ Réglages
  Future<Map<String, String>> settings() async {
    final rows = await db.query('settings');
    return {...defaultSettings, for (final r in rows) r['setting_key'] as String: (r['setting_value'] ?? '') as String};
  }

  Future<String> setting(String key, [DatabaseExecutor? ex]) async {
    final r = await (ex ?? db).query('settings', where: 'setting_key=?', whereArgs: [key]);
    return r.isEmpty ? (defaultSettings[key] ?? '') : (r.first['setting_value'] ?? '') as String;
  }

  Future<void> setSettings(Map<String, String> values) async {
    for (final e in values.entries) {
      if (!defaultSettings.containsKey(e.key) || e.key == 'counter_epoch') {
        throw EngineException('unknown_setting:${e.key}', 400);
      }
      await db.insert('settings', {'setting_key': e.key, 'setting_value': e.value},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  // ------------------------------------------------------------ Services et guichets
  Future<List<Json>> services({bool activeOnly = false}) async {
    final rows = await db.query('services', where: activeOnly ? 'active=1' : null, orderBy: 'priority desc, id');
    return [for (final r in rows) {...r, 'active': r['active'] == 1}];
  }

  Future<Json> saveService({int? id, required String name, required String code, String color = '#1e88e5', int priority = 0, bool active = true}) async {
    final c = code.trim().toUpperCase();
    if (name.trim().isEmpty || c.isEmpty || c.length > 4) throw EngineException('invalid_service', 400);
    if (!RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(color)) color = '#1e88e5';
    final v = {'name': name.trim(), 'code': c, 'color': color, 'priority': priority, 'active': active ? 1 : 0};
    try {
      if (id == null) {
        id = await db.insert('services', v);
        // un nouveau service est rattaché au premier guichet pour être servi tout de suite
        final first = await db.query('counters', orderBy: 'number', limit: 1);
        if (first.isNotEmpty) {
          await db.insert('counter_services', {'counter_id': first.first['id'], 'service_id': id},
              conflictAlgorithm: ConflictAlgorithm.ignore);
        }
      } else {
        await db.update('services', v, where: 'id=?', whereArgs: [id]);
      }
    } on DatabaseException catch (e) {
      if (e.isUniqueConstraintError()) throw EngineException('already_exists');
      rethrow;
    }
    _emit('queue.updated', {'service_id': id}, id);
    return (await services()).firstWhere((s) => s['id'] == id);
  }

  Future<List<Json>> counters() async {
    final rows = await db.query('counters', orderBy: 'number');
    final links = await db.query('counter_services');
    return [
      for (final r in rows)
        {...r, 'service_ids': [for (final l in links) if (l['counter_id'] == r['id']) l['service_id']]}
    ];
  }

  Future<Json> addCounter() async {
    final max = firstIntValue(await db.rawQuery('select coalesce(max(number),0) from counters')) ?? 0;
    final id = await db.insert('counters', {'name': 'Guichet ${max + 1}', 'number': max + 1});
    final svc = await db.query('services', where: 'active=1');
    for (final s in svc) {
      await db.insert('counter_services', {'counter_id': id, 'service_id': s['id']});
    }
    return (await counters()).firstWhere((c) => c['id'] == id);
  }

  Future<int> firstCounterId() async =>
      firstIntValue(await db.rawQuery('select id from counters order by number limit 1')) ??
      (throw EngineException('counter_not_found', 404));

  // ------------------------------------------------------------ Tickets
  Future<String> _scopeKey(DatabaseExecutor t) async {
    if (await setting('reset_mode', t) == 'daily') {
      final n = _now();
      return 'd:${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
    }
    return 'e:${await setting('counter_epoch', t)}';
  }

  static String _newToken() {
    final r = Random.secure();
    return List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  Future<Json> createTicket(int serviceId, {int priority = 0, int? userId}) async {
    final id = await _locked(() => db.transaction((t) async {
          final s = await t.query('services', where: 'id=?', whereArgs: [serviceId]);
          if (s.isEmpty) throw EngineException('service_not_found', 404);
          if (s.first['active'] != 1) throw EngineException('service_inactive');
          final scope = await _scopeKey(t);
          await t.rawInsert(
              'insert into ticket_counters(service_id, scope_key, last_number) values (?,?,1) '
              'on conflict(service_id, scope_key) do update set last_number = last_number + 1',
              [serviceId, scope]);
          final seq = firstIntValue(await t.rawQuery(
              'select last_number from ticket_counters where service_id=? and scope_key=?', [serviceId, scope]))!;
          final now = _ms;
          final tid = await t.insert('tickets', {
            'ticket_number': '${s.first['code']}${seq.toString().padLeft(3, '0')}',
            'origin_service_id': serviceId, 'service_id': serviceId, 'scope_key': scope, 'seq': seq,
            'priority': priority, 'access_token': _newToken(), 'created_at': now, 'queue_at': now,
          });
          await _log(t, tid, 'created', userId);
          return tid;
        }));
    final snap = await snapshot(id);
    _emit('ticket.created', snap, snap['service_id'] as int);
    await _publishQueue(snap['service_id'] as int);
    return snap;
  }

  Future<void> _log(DatabaseExecutor t, int ticketId, String type, int? userId, [String? details]) =>
      t.insert('ticket_events', {
        'ticket_id': ticketId, 'event_type': type, 'user_id': userId, 'created_at': _ms, 'details': details,
      });

  Future<Json> snapshot(int ticketId) async {
    final r = await db.rawQuery(
        'select t.*, s.name service_name, s.code service_code, s.color service_color, k.number counter_number, k.name counter_name '
        'from tickets t join services s on s.id=t.service_id left join counters k on k.id=t.counter_id where t.id=?',
        [ticketId]);
    if (r.isEmpty) throw EngineException('ticket_not_found', 404);
    final t = Map<String, Object?>.of(r.first);
    var ahead = 0;
    int? estimate;
    if (t['status'] == 'waiting') {
      ahead = firstIntValue(await db.rawQuery(
              "select count(*) from tickets where service_id=? and status='waiting' and id<>? and "
              '(priority > ? or (priority=? and (queue_at < ? or (queue_at=? and id < ?))))',
              [t['service_id'], t['id'], t['priority'], t['priority'], t['queue_at'], t['queue_at'], t['id']])) ??
          0;
      estimate = await _estimate(t['service_id'] as int, ahead);
    }
    for (final k in ['created_at', 'queue_at', 'called_at', 'started_at', 'completed_at']) {
      t[k] = t[k] == null ? null : _iso(t[k]);
    }
    return {...t, 'ahead': ahead, 'position': t['status'] == 'waiting' ? ahead + 1 : null, 'estimate_minutes': estimate};
  }

  Future<int> _estimate(int serviceId, int ahead) async {
    final avg = await db.rawQuery(
        "select avg(completed_at - coalesce(started_at, called_at)) a from tickets where service_id=? and status='done' "
        'and completed_at > ? and completed_at > coalesce(started_at, called_at)',
        [serviceId, _ms - 7 * 86400000]);
    final a = avg.first['a'] as num?;
    final perTicket = a != null ? a / 60000 : double.parse(await setting('default_service_minutes'));
    final open = firstIntValue(await db.rawQuery(
            "select count(*) from counters k join counter_services cs on cs.counter_id=k.id where cs.service_id=? and k.status='open'",
            [serviceId])) ??
        0;
    return max(1, ((ahead + 1) * perTicket / max(open, 1)).round());
  }

  Future<List<Json>> queueCounts() async {
    final rows = await db.rawQuery(
        "select s.id service_id, s.name, s.code, s.color, (select count(*) from tickets t where t.service_id=s.id and t.status='waiting') waiting "
        'from services s where s.active=1 order by s.id');
    return rows;
  }

  Future<void> _publishQueue(int serviceId) async =>
      _emit('queue.updated', {'service_id': serviceId, 'services': await queueCounts()}, serviceId);

  // ------------------------------------------------------------ Guichets
  Future<Json> _counter(DatabaseExecutor t, int id) async {
    final r = await t.query('counters', where: 'id=?', whereArgs: [id]);
    if (r.isEmpty) throw EngineException('counter_not_found', 404);
    return r.first;
  }

  Future<Json?> _active(DatabaseExecutor t, int counterId) async {
    final r = await t.query('tickets',
        where: "counter_id=? and status in ('called','serving')", whereArgs: [counterId], orderBy: 'called_at desc', limit: 1);
    return r.isEmpty ? null : r.first;
  }

  Future<void> setCounterStatus(int counterId, String status) => _locked(() async {
        await db.transaction((t) async {
          await _counter(t, counterId);
          if (status == 'closed' && await _active(t, counterId) != null) throw EngineException('ticket_in_progress');
          await t.update('counters', {'status': status}, where: 'id=?', whereArgs: [counterId]);
        });
        _emit(status == 'paused' ? 'counter.paused' : status == 'open' ? 'counter.resumed' : 'counter.closed',
            {'counter_id': counterId, 'status': status});
        _emit('queue.updated', {'service_id': null, 'services': await queueCounts()});
      });

  /// Priorité du ticket, puis du service, puis ancienneté.
  Future<Json> callNext(int counterId, {int? userId}) async {
    final id = await _locked(() => db.transaction((t) async {
          final k = await _counter(t, counterId);
          if (k['status'] != 'open') throw EngineException(k['status'] == 'paused' ? 'counter_paused' : 'counter_closed');
          if (await _active(t, counterId) != null) throw EngineException('ticket_in_progress');
          final n = await t.rawQuery(
              "select t.id from tickets t join counter_services cs on cs.service_id=t.service_id and cs.counter_id=? "
              "join services s on s.id=t.service_id where t.status='waiting' "
              'order by t.priority desc, s.priority desc, t.queue_at, t.id limit 1',
              [counterId]);
          if (n.isEmpty) throw EngineException('queue_empty', 404);
          final tid = n.first['id'] as int;
          await t.update('tickets', {'status': 'called', 'counter_id': counterId, 'called_at': _ms}, where: 'id=?', whereArgs: [tid]);
          await _log(t, tid, 'called', userId, '{"counter_id":$counterId}');
          return tid;
        }));
    return _emitTicket('ticket.called', id);
  }

  Future<Json> _emitTicket(String event, int id) async {
    final snap = await snapshot(id);
    _emit(event, snap, snap['service_id'] as int);
    await _publishQueue(snap['service_id'] as int);
    return snap;
  }

  Future<Json> _own(DatabaseExecutor t, int ticketId, int counterId, List<String> allowed) async {
    final r = await t.query('tickets', where: 'id=?', whereArgs: [ticketId]);
    if (r.isEmpty) throw EngineException('ticket_not_found', 404);
    if (r.first['counter_id'] != counterId) throw EngineException('not_your_ticket', 403);
    if (!allowed.contains(r.first['status'])) throw EngineException('invalid_state:${r.first['status']}');
    return r.first;
  }

  Future<Json> _transition(String event, int ticketId, int counterId, List<String> allowed, Map<String, Object?> Function() change,
      String logType, int? userId, {String? details}) async {
    await _locked(() => db.transaction((t) async {
          await _own(t, ticketId, counterId, allowed);
          await t.update('tickets', change(), where: 'id=?', whereArgs: [ticketId]);
          await _log(t, ticketId, logType, userId, details);
        }));
    return _emitTicket(event, ticketId);
  }

  Future<Json> recall(int id, int counter, {int? userId}) =>
      _transition('ticket.recalled', id, counter, ['called', 'serving'], () => {'called_at': _ms}, 'recalled', userId);
  Future<Json> start(int id, int counter, {int? userId}) =>
      _transition('ticket.started', id, counter, ['called'], () => {'status': 'serving', 'started_at': _ms}, 'started', userId);
  Future<Json> complete(int id, int counter, {int? userId}) => _transition(
      'ticket.completed', id, counter, ['called', 'serving'], () => {'status': 'done', 'completed_at': _ms}, 'completed', userId);
  Future<Json> markAbsent(int id, int counter, {int? userId}) => _transition(
      'ticket.absent', id, counter, ['called'], () => {'status': 'absent', 'completed_at': _ms}, 'absent', userId);

  /// « Ignorer » : le ticket retourne en file derrière les autres de même priorité.
  Future<Json> skip(int id, int counter, {int? userId}) => _transition('ticket.skipped', id, counter, ['called'],
      () => {'status': 'waiting', 'counter_id': null, 'queue_at': _ms, 'called_at': null}, 'skipped', userId);

  Future<Json> transfer(int id, int counter, int toService, {int? userId}) async {
    final s = await db.query('services', where: 'id=? and active=1', whereArgs: [toService]);
    if (s.isEmpty) throw EngineException('service_not_found', 404);
    return _transition(
        'ticket.transferred', id, counter, ['called', 'serving'],
        () => {'status': 'waiting', 'service_id': toService, 'counter_id': null, 'queue_at': _ms, 'called_at': null, 'started_at': null},
        'transferred', userId, details: '{"to_service":$toService}');
  }

  Future<Json> cancel(int id, {int? userId}) async {
    await _locked(() => db.transaction((t) async {
          final r = await t.query('tickets', where: 'id=?', whereArgs: [id]);
          if (r.isEmpty) throw EngineException('ticket_not_found', 404);
          if (!['waiting', 'called'].contains(r.first['status'])) throw EngineException('invalid_state:${r.first['status']}');
          await t.update('tickets', {'status': 'cancelled', 'completed_at': _ms}, where: 'id=?', whereArgs: [id]);
          await _log(t, id, 'cancelled', userId);
        }));
    return _emitTicket('ticket.cancelled', id);
  }

  Future<Json> setPriority(int id, int priority, {int? userId}) async {
    await _locked(() => db.transaction((t) async {
          final r = await t.query('tickets', where: 'id=?', whereArgs: [id]);
          if (r.isEmpty) throw EngineException('ticket_not_found', 404);
          if (r.first['status'] != 'waiting') throw EngineException('invalid_state:${r.first['status']}');
          await t.update('tickets', {'priority': priority}, where: 'id=?', whereArgs: [id]);
          await _log(t, id, 'priority_changed', userId, '{"from":${r.first['priority']},"to":$priority}');
        }));
    return _emitTicket('ticket.priority', id);
  }

  /// Remise à zéro manuelle : nouvelle époque, numérotation à 001 (mode `manual`).
  Future<void> resetNumbering() async {
    final epoch = (int.parse(await setting('counter_epoch')) + 1).toString();
    await db.insert('settings', {'setting_key': 'counter_epoch', 'setting_value': epoch},
        conflictAlgorithm: ConflictAlgorithm.replace);
    // en mode quotidien, la remise à zéro manuelle passe en mode « manual » pour être effective
    await db.insert('settings', {'setting_key': 'reset_mode', 'setting_value': 'manual'},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Json> agentState(int counterId) async {
    final k = await _counter(db, counterId);
    final cur = await _active(db, counterId);
    final d = _now();
    final dayStart = DateTime(d.year, d.month, d.day).millisecondsSinceEpoch;
    final st = await db.rawQuery(
        "select count(*) served, avg(completed_at - coalesce(started_at, called_at)) a from tickets where counter_id=? and status='done' and created_at>=?",
        [counterId, dayStart]);
    final waiting = firstIntValue(await db.rawQuery(
            "select count(*) from tickets t join counter_services cs on cs.service_id=t.service_id and cs.counter_id=? where t.status='waiting'",
            [counterId])) ??
        0;
    final a = st.first['a'] as num?;
    return {
      'counter': k,
      'current': cur == null ? null : await snapshot(cur['id'] as int),
      'waiting': waiting,
      'served': st.first['served'],
      'avg_handling_seconds': a == null ? null : (a / 1000).round(),
    };
  }

  // ------------------------------------------------------------ Affichage, suivi public, stats
  Future<Json> displayState({List<int>? serviceIds}) async {
    final filter = serviceIds == null || serviceIds.isEmpty ? '' : ' and t.service_id in (${serviceIds.join(',')})';
    const base = 'select t.id, t.ticket_number, t.status, t.called_at, s.name service_name, s.color service_color, k.number counter_number '
        'from tickets t join services s on s.id=t.service_id join counters k on k.id=t.counter_id where t.called_at is not null';
    Json fix(Json r) => {...r, 'called_at': _iso(r['called_at'])};
    final cur = await db.rawQuery("$base and t.status in ('called','serving')$filter order by t.called_at desc");
    final rec = await db.rawQuery('$base and t.called_at > ?$filter order by t.called_at desc limit 8', [_ms - 3 * 3600000]);
    final counts = (await queueCounts()).where((s) => serviceIds == null || serviceIds.isEmpty || serviceIds.contains(s['service_id'])).toList();
    return {'current': cur.map(fix).toList(), 'recent': rec.map(fix).toList(), 'services': counts, 'settings': await settings()};
  }

  static String publicStatus(String status, int ahead) => switch (status) {
        'waiting' => ahead <= 2 ? 'soon' : 'waiting',
        'called' => 'called',
        'serving' => 'serving',
        'done' => 'done',
        _ => 'cancelled',
      };

  /// Données du suivi QR : strictement celles de l'API publique du serveur Windows.
  Future<Json?> publicTicket(String token) async {
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(token)) return null;
    final r = await db.query('tickets', columns: ['id'], where: 'access_token=?', whereArgs: [token]);
    if (r.isEmpty) return null;
    final t = await snapshot(r.first['id'] as int);
    return {
      'ticket_number': t['ticket_number'], 'service': t['service_name'], 'color': t['service_color'],
      'status': publicStatus(t['status'] as String, t['ahead'] as int), 'position': t['position'], 'ahead': t['ahead'],
      'estimate_minutes': t['estimate_minutes'], 'counter': t['counter_number'], 'org': await setting('org_name'),
    };
  }

  /// Statistiques de la journée (ou de [from, to[ en millisecondes).
  Future<Json> summary({DateTime? from, DateTime? to}) async {
    final d = _now();
    final f = (from ?? DateTime(d.year, d.month, d.day)).millisecondsSinceEpoch;
    final t = (to ?? DateTime(d.year, d.month, d.day + 1)).millisecondsSinceEpoch;
    final tot = (await db.rawQuery(
            "select count(*) total, sum(status='done') served, sum(status='absent') absent, sum(status='cancelled') cancelled, "
            "avg(case when called_at is not null then called_at - created_at end) w, "
            "avg(case when status='done' then completed_at - coalesce(started_at, called_at) end) h "
            'from tickets where created_at>=? and created_at<?',
            [f, t]))
        .first;
    int? sec(Object? ms) => ms == null ? null : ((ms as num) / 1000).round();
    final byService = await db.rawQuery(
        "select s.id, s.name, s.code, count(t.id) total, coalesce(sum(t.status='done'),0) served from services s "
        'left join tickets t on t.origin_service_id=s.id and t.created_at>=? and t.created_at<? group by s.id order by s.id',
        [f, t]);
    return {
      'totals': {
        'total': tot['total'], 'served': tot['served'] ?? 0, 'absent': tot['absent'] ?? 0, 'cancelled': tot['cancelled'] ?? 0,
        'avg_wait_s': sec(tot['w']), 'avg_handling_s': sec(tot['h']),
      },
      'by_service': byService,
    };
  }
}
