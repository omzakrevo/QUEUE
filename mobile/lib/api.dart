import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as sio;

class ApiException implements Exception {
  ApiException(this.status, this.code);
  final int status;
  final String code;
  @override
  String toString() => code;
}

/// Normalise l'adresse saisie : `192.168.1.10` -> `http://192.168.1.10:3000`.
String normalizeServerUrl(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return s;
  if (!s.startsWith('http://') && !s.startsWith('https://')) s = 'http://$s';
  final uri = Uri.parse(s);
  final withPort = uri.hasPort ? uri : uri.replace(port: 3000);
  return withPort.toString().replaceAll(RegExp(r'/+$'), '');
}

class Session {
  Session({required this.server, required this.token, required this.name, required this.role, this.terminalId});
  final String server;
  final String token;
  final String name;
  final String role;
  final int? terminalId;
}

class Api {
  Api(this.session, {http.Client? client}) : _client = client ?? http.Client();
  final Session session;
  final http.Client _client;

  Map<String, String> get _headers => {
        'content-type': 'application/json',
        'authorization': 'Bearer ${session.token}',
      };

  static Future<Session> login(String server, String username, String password,
      {int? terminalId, http.Client? client}) async {
    final base = normalizeServerUrl(server);
    final c = client ?? http.Client();
    final http.Response r;
    try {
      r = await c
          .post(Uri.parse('$base/api/auth/login'),
              headers: {'content-type': 'application/json'},
              body: jsonEncode({'username': username, 'password': password}))
          .timeout(const Duration(seconds: 8));
    } on TimeoutException {
      throw ApiException(0, 'server_unreachable');
    } catch (_) {
      throw ApiException(0, 'server_unreachable');
    }
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    if (r.statusCode != 200) throw ApiException(r.statusCode, (body['error'] ?? 'error').toString());
    final user = body['user'] as Map<String, dynamic>;
    final s = Session(
        server: base,
        token: body['token'] as String,
        name: user['name'] as String,
        role: user['role'] as String,
        terminalId: terminalId);
    final p = await SharedPreferences.getInstance();
    await p.setString('server', base);
    await p.setString('token', s.token);
    await p.setString('name', s.name);
    await p.setString('role', s.role);
    terminalId == null ? await p.remove('terminal') : await p.setInt('terminal', terminalId);
    return s;
  }

  static Future<Session?> restore() async {
    final p = await SharedPreferences.getInstance();
    final server = p.getString('server'), token = p.getString('token');
    if (server == null || token == null) return null;
    return Session(
        server: server,
        token: token,
        name: p.getString('name') ?? '',
        role: p.getString('role') ?? '',
        terminalId: p.getInt('terminal'));
  }

  static Future<void> logout() async {
    final p = await SharedPreferences.getInstance();
    for (final k in ['token', 'name', 'role']) {
      await p.remove(k);
    }
  }

  Future<dynamic> _send(String method, String path, [Object? body]) async {
    final uri = Uri.parse('${session.server}/api$path');
    final http.Response r;
    try {
      final req = http.Request(method, uri)..headers.addAll(_headers);
      if (body != null) req.body = jsonEncode(body);
      r = await http.Response.fromStream(await _client.send(req).timeout(const Duration(seconds: 8)));
    } catch (_) {
      throw ApiException(0, 'server_unreachable');
    }
    dynamic data;
    try {
      data = r.body.isEmpty ? null : jsonDecode(r.body);
    } catch (_) {
      data = null;
    }
    if (r.statusCode >= 400) {
      throw ApiException(r.statusCode, data is Map ? (data['error'] ?? 'error').toString() : 'error');
    }
    return data;
  }

  Future<dynamic> get(String path) => _send('GET', path);
  Future<dynamic> post(String path, [Object? body]) => _send('POST', path, body ?? {});

  /// Connexion temps réel (Socket.IO) avec le jeton de la session.
  sio.Socket socket() => sio.io(
      session.server,
      sio.OptionBuilder()
          .setTransports(['websocket'])
          .setAuth({'token': session.token})
          .setReconnectionAttempts(5)
          .build());
}

/// Messages d'erreur lisibles en français.
String errorText(Object e) {
  final code = e is ApiException ? e.code : e.toString();
  return switch (code) {
    'server_unreachable' => 'Serveur injoignable. Vérifiez le Wi-Fi et l’adresse.',
    'bad_credentials' => 'Identifiant ou mot de passe incorrect.',
    'too_many_attempts' => 'Trop d’essais, patientez une minute.',
    'queue_empty' => 'Aucun client en attente.',
    'counter_paused' => 'Le guichet est en pause.',
    'counter_closed' => 'Le guichet est fermé.',
    'ticket_in_progress' => 'Terminez d’abord le client en cours.',
    'no_counter_assigned' => 'Aucun guichet n’est affecté à ce compte.',
    'service_closed' => 'Ce service est fermé pour le moment.',
    'service_inactive' => 'Ce service est indisponible.',
    _ => 'Action impossible ($code).',
  };
}
