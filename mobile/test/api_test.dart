import 'package:flutter/material.dart' show Color;
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omza_queue/api.dart';
import 'package:omza_queue/kiosk_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('normalizeServerUrl complète schéma et port', () {
    expect(normalizeServerUrl('192.168.1.10'), 'http://192.168.1.10:3000');
    expect(normalizeServerUrl(' http://srv:8080/ '), 'http://srv:8080');
    expect(normalizeServerUrl(''), '');
  });

  test('parseColor', () {
    expect(parseColor('#43a047'), const Color(0xFF43A047));
    expect(parseColor(null), const Color(0xFF1E5EFF));
  });

  test('login réussi puis appel API authentifié', () async {
    SharedPreferences.setMockInitialValues({});
    final client = MockClient((req) async {
      if (req.url.path == '/api/auth/login') {
        expect(jsonDecode(req.body)['username'], 'agent1');
        return http.Response(
            jsonEncode({'token': 'tok', 'user': {'name': 'Agent 1', 'role': 'agent'}}), 200,
            headers: {'content-type': 'application/json'});
      }
      expect(req.headers['authorization'], 'Bearer tok');
      return http.Response(jsonEncode({'waiting': 3}), 200);
    });
    final s = await Api.login('10.0.0.5', 'agent1', 'x', client: client);
    expect(s.server, 'http://10.0.0.5:3000');
    expect(s.role, 'agent');
    final r = await Api(s, client: client).get('/agent/state');
    expect(r['waiting'], 3);
    expect((await Api.restore())!.token, 'tok');
  });

  test('erreurs : mauvais identifiants et serveur injoignable', () async {
    SharedPreferences.setMockInitialValues({});
    final bad = MockClient((_) async => http.Response(jsonEncode({'error': 'bad_credentials'}), 401));
    await expectLater(Api.login('h', 'u', 'p', client: bad),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'bad_credentials')));
    final down = MockClient((_) async => throw Exception('no route'));
    await expectLater(Api.login('h', 'u', 'p', client: down),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'server_unreachable')));
    expect(errorText(ApiException(409, 'ticket_in_progress')), contains('Terminez'));
  });
}
