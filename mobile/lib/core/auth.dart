import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:sqflite_common/sqlite_api.dart';

import 'engine.dart';

const roles = ['administrateur', 'superviseur', 'agent', 'responsable', 'borne', 'affichage'];

/// Comptes et sessions du serveur embarqué (utilisés uniquement quand d'autres appareils se connectent).
class Auth {
  Auth(this.engine);
  final QueueEngine engine;
  Database get _db => engine.db;
  final _attempts = <String, ({int n, DateTime until})>{};

  static const _iterations = 20000;

  static Uint8List _pbkdf2(String password, List<int> salt) {
    final hmac = Hmac(sha256, utf8.encode(password));
    var u = hmac.convert([...salt, 0, 0, 0, 1]).bytes;
    final out = List<int>.of(u);
    for (var i = 1; i < _iterations; i++) {
      u = hmac.convert(u).bytes;
      for (var j = 0; j < out.length; j++) {
        out[j] ^= u[j];
      }
    }
    return Uint8List.fromList(out);
  }

  static String _hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  static List<int> _unhex(String s) => [for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)];
  static List<int> _random(int n) {
    final r = Random.secure();
    return List.generate(n, (_) => r.nextInt(256));
  }

  static String hashPassword(String pw) {
    final salt = _random(16);
    return 'pbkdf2\$${_hex(salt)}\$${_hex(_pbkdf2(pw, salt))}';
  }

  static bool verifyPassword(String pw, String stored) {
    final p = stored.split(r'$');
    if (p.length != 3 || p[0] != 'pbkdf2') return false;
    final a = _pbkdf2(pw, _unhex(p[1]));
    final b = _unhex(p[2]);
    var diff = a.length ^ b.length; // comparaison à temps constant
    for (var i = 0; i < a.length && i < b.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  Future<int> createUser(String name, String username, String password, String role, {int? counterId}) async {
    if (!roles.contains(role)) throw EngineException('invalid_role', 400);
    if (password.length < 6) throw EngineException('password_too_short', 400);
    final id = await _db.insert('users', {
      'name': name, 'username': username, 'password_hash': hashPassword(password), 'role': role,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    if (role == 'agent') {
      await _db.insert('agents', {'user_id': id, 'counter_id': counterId}, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    return id;
  }

  /// (Re)crée les comptes d'appareils avec des codes aléatoires à 6 chiffres. Les codes ne sont
  /// conservés que sous forme de hachage : ils ne sont affichés qu'à cet instant.
  Future<Map<String, String>> provisionDevices() async {
    final r = Random.secure();
    String code() => (100000 + r.nextInt(900000)).toString();
    final counter = await engine.firstCounterId();
    final out = <String, String>{};
    for (final (name, user, role) in [
      ('Administrateur', 'admin', 'administrateur'),
      ('Agent 1', 'agent1', 'agent'),
      ('Borne 1', 'borne1', 'borne'),
      ('Écran TV', 'tv1', 'affichage'),
    ]) {
      final c = code();
      await _db.delete('users', where: 'username=?', whereArgs: [user]);
      await createUser(name, user, c, role, counterId: role == 'agent' ? counter : null);
      out[user] = c;
    }
    await _db.delete('sessions'); // les anciennes sessions sont révoquées
    return out;
  }

  Future<bool> hasAccounts() async => ((await _db.rawQuery('select count(*) c from users')).first['c'] as int) > 0;

  /// Retourne {token, user} ou lève EngineException(bad_credentials / too_many_attempts).
  Future<Json> login(String username, String password, {String ip = ''}) async {
    final key = '$ip:$username';
    final a = _attempts[key];
    if (a != null && a.n >= 5 && DateTime.now().isBefore(a.until)) throw EngineException('too_many_attempts', 429);
    final rows = await _db.query('users', where: 'username=?', whereArgs: [username]);
    final ok = rows.isNotEmpty && rows.first['status'] == 'active' && verifyPassword(password, rows.first['password_hash'] as String);
    if (!ok) {
      _attempts[key] = (n: (a?.n ?? 0) + 1, until: DateTime.now().add(const Duration(minutes: 1)));
      throw EngineException('bad_credentials', 401);
    }
    _attempts.remove(key);
    final u = rows.first;
    final device = u['role'] == 'borne' || u['role'] == 'affichage';
    final token = _hex(_random(32));
    await _db.insert('sessions', {
      'token': token, 'user_id': u['id'],
      'expires_at': DateTime.now().add(device ? const Duration(days: 365) : const Duration(hours: 12)).millisecondsSinceEpoch,
    });
    return {'token': token, 'user': {'id': u['id'], 'username': u['username'], 'name': u['name'], 'role': u['role']}};
  }

  Future<Json?> verifyToken(String token) async {
    final r = await _db.rawQuery(
        "select u.id, u.username, u.name, u.role from sessions s join users u on u.id=s.user_id where s.token=? and s.expires_at>? and u.status='active'",
        [token, DateTime.now().millisecondsSinceEpoch]);
    return r.isEmpty ? null : r.first;
  }

  Future<int?> counterOf(int userId) async {
    final r = await _db.query('agents', where: 'user_id=?', whereArgs: [userId]);
    return r.isEmpty ? null : r.first['counter_id'] as int?;
  }
}
