import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:qr/qr.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import 'auth.dart';
import 'engine.dart';

/// Lecture d'un fichier web embarqué (`tv/index.html`, `shared/common.js`, ...) ou null.
typedef AssetLoader = Future<List<int>?> Function(String path);

const _manage = ['administrateur', 'superviseur'];

/// Serveur HTTP embarqué : même API que le serveur Windows (sous-ensemble utile), mêmes pages web
/// (TV, suivi QR, borne, agent). Le temps réel passe par un petit canal « long polling » :
/// le fichier /socket.io/socket.io.js servi ici est une version légère compatible avec les pages.
class LocalServer {
  LocalServer(this.engine, this.auth, this.assets, {this.port = 3000});
  final QueueEngine engine;
  final Auth auth;
  final AssetLoader assets;
  final int port;

  HttpServer? _http;
  StreamSubscription<EngineEvent>? _sub;
  final _buffer = <({int id, String name, Object? payload, int? serviceId})>[];
  var _seq = 0;

  bool get running => _http != null;
  int get boundPort => _http?.port ?? port;

  Future<void> start({InternetAddress? address}) async {
    if (_http != null) return;
    _sub = engine.events.listen((e) {
      _buffer.add((id: ++_seq, name: e.name, payload: e.payload, serviceId: e.serviceId));
      if (_buffer.length > 300) _buffer.removeRange(0, _buffer.length - 300);
    });
    _http = await shelf_io.serve(_handle, address ?? InternetAddress.anyIPv4, port, shared: true);
  }

  Future<void> stop() async {
    await _sub?.cancel();
    await _http?.close(force: true);
    _sub = null;
    _http = null;
  }

  // ---------------------------------------------------------------- Routage
  Future<Response> _handle(Request req) async {
    try {
      final path = req.url.path; // sans « / » initial
      if (path.startsWith('api/')) return await _api(req, path.substring(4));
      if (path == 'socket.io/socket.io.js') return _bytes(utf8.encode(_shim), 'application/javascript');
      return await _static(req, path);
    } on EngineException catch (e) {
      return _json({'error': e.code}, _status(e));
    } on FormatException {
      return _json({'error': 'invalid_json'}, 400);
    } catch (e) {
      stderr.writeln('LocalServer: $e');
      return _json({'error': 'internal_error'}, 500);
    }
  }

  static int _status(EngineException e) => e.code.startsWith('invalid_state') || e.status == 409 ? 409 : e.status;

  Response _json(Object? body, [int status = 200]) =>
      Response(status, body: jsonEncode(body), headers: {'content-type': 'application/json; charset=utf-8'});
  Response _bytes(List<int> b, String type, [int status = 200]) =>
      Response(status, body: b, headers: {'content-type': type, 'cache-control': 'no-cache'});

  static const _types = {
    'html': 'text/html; charset=utf-8', 'js': 'application/javascript', 'css': 'text/css',
    'webmanifest': 'application/manifest+json', 'svg': 'image/svg+xml', 'png': 'image/png',
  };

  Future<Response> _static(Request req, String path) async {
    String? file;
    if (path == '' || path == 'index.html') {
      return _bytes(utf8.encode(_home), 'text/html; charset=utf-8');
    } else if (const {'tv', 'kiosk', 'agent'}.contains(path)) {
      file = '$path/index.html';
    } else if (path.startsWith('t/')) {
      file = 'ticket/index.html';
    } else if (path.startsWith('shared/') || path == 'ticket/manifest.webmanifest') {
      file = path;
    }
    if (file == null || file.contains('..')) return _json({'error': 'not_found'}, 404);
    final data = await assets(file);
    if (data == null) return _json({'error': 'not_found'}, 404);
    return _bytes(data, _types[file.split('.').last] ?? 'application/octet-stream');
  }

  // ---------------------------------------------------------------- API
  Future<Json> _body(Request r) async {
    final s = await r.readAsString();
    if (s.isEmpty) return {};
    final d = jsonDecode(s);
    return d is Map ? Map<String, Object?>.from(d) : {};
  }

  Future<Json> _user(Request r, [List<String> allowed = const []]) async {
    final h = r.headers['authorization'];
    if (h == null || !h.startsWith('Bearer ')) throw EngineException('unauthorized', 401);
    final u = await auth.verifyToken(h.substring(7));
    if (u == null) throw EngineException('unauthorized', 401);
    if (allowed.isNotEmpty && !allowed.contains(u['role'])) throw EngineException('forbidden', 403);
    return u;
  }

  int _int(Object? v, String name) {
    final n = v is int ? v : int.tryParse('$v');
    if (n == null) throw EngineException('invalid_$name', 400);
    return n;
  }

  Future<int> _counterFor(Json user, Request r, Json body) async {
    if (user['role'] == 'agent') {
      return await auth.counterOf(user['id'] as int) ?? (throw EngineException('no_counter_assigned'));
    }
    return _int(body['counter_id'] ?? r.url.queryParameters['counter_id'], 'counter_id');
  }

  Future<Response> _api(Request r, String p) async {
    final m = r.method;
    final seg = p.split('/');
    switch ('$m ${seg.first}') {
      case 'GET health':
        return _json({'ok': true});
      case 'POST auth':
        if (seg.length == 2 && seg[1] == 'login') {
          final b = await _body(r);
          final ip = (r.context['shelf.io.connection_info'] as HttpConnectionInfo?)?.remoteAddress.address ?? '';
          return _json(await auth.login('${b['username']}', '${b['password']}', ip: ip));
        }
      case 'GET auth':
        if (seg.length == 2 && seg[1] == 'me') return _json(await _user(r));
      case 'GET services':
        await _user(r);
        return _json(await engine.services());
      case 'GET counters':
        await _user(r);
        return _json(await engine.counters());
      case 'GET settings':
        await _user(r);
        return _json(await engine.settings());
      case 'POST tickets':
        if (seg.length == 1) {
          final u = await _user(r, ['borne', ..._manage]);
          final b = await _body(r);
          // une borne ne choisit pas la priorité
          final prio = u['role'] == 'borne' ? 0 : _int(b['priority'] ?? 0, 'priority');
          final t = await engine.createTicket(_int(b['service_id'], 'service_id'), priority: prio, userId: u['id'] as int);
          return _json({'ticket': t, 'qr_url': '${_base(r)}/t/${t['access_token']}', 'print': {'status': 'none'}, 'escpos': ''}, 201);
        }
        if (seg.length == 3 && seg[2] == 'cancel') {
          await _user(r, _manage);
          return _json(await engine.cancel(_int(seg[1], 'id')));
        }
      case 'GET display':
        await _user(r, ['affichage', ..._manage]);
        final ids = r.url.queryParameters['services'];
        return _json(await engine.displayState(
            serviceIds: ids == null || ids.isEmpty ? null : ids.split(',').map((x) => _int(x, 'service')).toList()));
      case 'GET public':
        if (seg.length == 3 && seg[1] == 'ticket') {
          final t = await engine.publicTicket(seg[2]);
          return t == null ? _json({'error': 'ticket_not_found'}, 404) : _json(t);
        }
        if (seg.length == 3 && seg[1] == 'qr') {
          if (await engine.publicTicket(seg[2]) == null) return _json({'error': 'ticket_not_found'}, 404);
          return _bytes(utf8.encode(qrSvg('${_base(r)}/t/${seg[2]}')), 'image/svg+xml');
        }
      case 'GET events':
        return await _events(r);
      case 'GET agent':
        if (seg.length == 2 && seg[1] == 'state') {
          final u = await _user(r, ['agent', ..._manage]);
          return _json(await engine.agentState(await _counterFor(u, r, {})));
        }
      case 'POST agent':
        return await _agentPost(r, seg);
    }
    return _json({'error': 'not_found'}, 404);
  }

  Future<Response> _agentPost(Request r, List<String> seg) async {
    final u = await _user(r, ['agent', ..._manage]);
    final b = await _body(r);
    final uid = u['id'] as int;
    final c = await _counterFor(u, r, b);
    if (seg.length == 3 && seg[1] == 'counter') {
      final status = {'open': 'open', 'pause': 'paused', 'resume': 'open', 'close': 'closed'}[seg[2]];
      if (status == null) return _json({'error': 'not_found'}, 404);
      await engine.setCounterStatus(c, status);
      return _json(await engine.agentState(c));
    }
    if (seg.length == 2 && seg[1] == 'call-next') return _json(await engine.callNext(c, userId: uid));
    if (seg.length == 4 && seg[1] == 'tickets') {
      final id = _int(seg[2], 'id');
      switch (seg[3]) {
        case 'recall':
          return _json(await engine.recall(id, c, userId: uid));
        case 'start':
          return _json(await engine.start(id, c, userId: uid));
        case 'complete':
          return _json(await engine.complete(id, c, userId: uid));
        case 'absent':
          return _json(await engine.markAbsent(id, c, userId: uid));
        case 'skip':
          return _json(await engine.skip(id, c, userId: uid));
        case 'transfer':
          return _json(await engine.transfer(id, c, _int(b['service_id'], 'service_id'), userId: uid));
      }
    }
    return _json({'error': 'not_found'}, 404);
  }

  /// Flux d'événements (remplace Socket.IO). Sans `since` : retourne seulement le dernier identifiant.
  Future<Response> _events(Request r) async {
    final scope = r.url.queryParameters['scope'] ?? 'main';
    if (scope == 'main') await _user(r);
    final since = int.tryParse(r.url.queryParameters['since'] ?? '');
    if (since == null) return _json({'last': _seq, 'events': []});
    final out = <Json>[];
    for (final e in _buffer.where((e) => e.id > since)) {
      if (scope == 'public') {
        // canal public : aucun détail de ticket, uniquement « rafraîchis-toi »
        if (e.name.startsWith('ticket.') || e.name == 'queue.updated') {
          out.add({'name': 'queue.updated', 'payload': {'service_id': e.serviceId}});
        }
      } else {
        out.add({'name': e.name, 'payload': e.payload});
      }
    }
    return _json({'last': _seq, 'events': out});
  }

  static String _base(Request r) => '${r.requestedUri.scheme}://${r.headers['host'] ?? 'localhost'}';

  /// QR Code en SVG (généré localement, sans Internet).
  static String qrSvg(String data) {
    final img = QrImage(QrCode.fromData(data: data, errorCorrectLevel: QrErrorCorrectLevel.M));
    final n = img.moduleCount;
    final b = StringBuffer('<svg xmlns="http://www.w3.org/2000/svg" viewBox="-1 -1 ${n + 2} ${n + 2}" shape-rendering="crispEdges">'
        '<rect x="-1" y="-1" width="${n + 2}" height="${n + 2}" fill="#fff"/><path fill="#000" d="');
    for (var y = 0; y < n; y++) {
      for (var x = 0; x < n; x++) {
        if (img.isDark(y, x)) b.write('M$x,${y}h1v1h-1z');
      }
    }
    b.write('"/></svg>');
    return b.toString();
  }

  static const _home = '<!doctype html><html lang="fr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
      '<title>OMZA QUEUE</title><style>body{font-family:system-ui;margin:0;padding:24px;max-width:560px;margin:auto}'
      'a{display:block;padding:16px;margin:10px 0;border:1px solid #ccd;border-radius:12px;text-decoration:none;color:inherit;font-weight:600}</style></head>'
      '<body><h1>OMZA QUEUE</h1><p>Serveur actif sur ce téléphone.</p><a href="/kiosk">Borne de tickets</a><a href="/agent">Poste agent</a>'
      '<a href="/tv">Affichage TV</a></body></html>';

  // Remplace le client Socket.IO : même interface minimale (on, close, événements connect/disconnect).
  static const _shim = r'''
(function(){
  function io(a,b){
    var scope='main',opts={};
    if(typeof a==='string'){scope=a.indexOf('/public')>=0?'public':'main';opts=b||{};}else{opts=a||{};}
    var handlers={},last=null,closed=false,connected=false,token=(opts.auth&&opts.auth.token)||'';
    var sock={on:function(n,f){(handlers[n]=handlers[n]||[]).push(f);return sock;},close:function(){closed=true;},disconnect:function(){closed=true;}};
    function emit(n,p){(handlers[n]||[]).forEach(function(f){try{f(p);}catch(e){console.error(e);}});}
    function poll(){
      if(closed)return;
      var url='/api/events?scope='+scope+(last===null?'':'&since='+last);
      fetch(url,{headers:token?{authorization:'Bearer '+token}:{}}).then(function(r){
        if(!r.ok)throw new Error(r.status);return r.json();
      }).then(function(d){
        last=d.last;
        if(!connected){connected=true;emit('connect');}
        d.events.forEach(function(e){emit(e.name,e.payload);});
      }).catch(function(){if(connected){connected=false;emit('disconnect');}})
      .then(function(){setTimeout(poll,1200);});
    }
    setTimeout(poll,0);
    return sock;
  }
  window.io=io;
})();
''';
}
