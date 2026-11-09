import 'dart:async';

import 'api.dart';
import 'printer.dart';

typedef Js = Map<String, dynamic>;

/// Résultat de la création d'un ticket.
class TicketResult {
  TicketResult(this.ticket, {this.qrUrl, this.printStatus = 'none', this.printing});
  final Js ticket;
  final String? qrUrl;
  final String printStatus; // none | printed | failed | client
  /// Impression locale en cours : se termine par 'printed' | 'failed' | 'none'. Le ticket s'affiche sans l'attendre.
  final Future<String>? printing;
}

/// Ce que les écrans borne/agent utilisent. Deux implémentations : [RemoteBackend] (serveur sur le
/// réseau) et `LocalBackend` (moteur embarqué dans ce téléphone).
abstract class Backend {
  Future<List<Js>> services();
  Future<Js> settings();
  Future<TicketResult> createTicket(int serviceId);
  Future<void> reprint(int ticketId);
  Future<Js> agentState();
  Future<void> counterAction(String action); // open | pause | resume | close
  Future<void> callNext();
  Future<void> ticketAction(int ticketId, String action, {int? serviceId}); // recall|start|complete|absent|skip|transfer
  Future<Js?> lastCall();
  /// Émet à chaque changement de la file (temps réel + filet de sécurité par interrogation).
  Stream<void> get changes;
  void dispose();
}

class RemoteBackend implements Backend {
  RemoteBackend(this.api, {this.printer}) {
    _socket = api.socket()
      ..on('queue.updated', (_) => _ping())
      ..on('ticket.created', (_) => _ping())
      ..on('connect', (_) => _ping());
    // Le serveur embarqué d'un téléphone n'a pas Socket.IO : on interroge aussi régulièrement.
    _poll = Timer.periodic(const Duration(seconds: 4), (_) => _ping());
  }
  final Api api;
  final PrinterService? printer;
  final _recent = <int, TicketResult>{};
  dynamic _socket;
  Timer? _poll;
  final _changes = StreamController<void>.broadcast();

  void _ping() {
    if (!_changes.isClosed) _changes.add(null);
  }

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<List<Js>> services() async => [for (final s in await api.get('/services') as List) Map<String, dynamic>.from(s as Map)];

  @override
  Future<Js> settings() async => Map<String, dynamic>.from(await api.get('/settings') as Map);

  @override
  Future<TicketResult> createTicket(int serviceId) async {
    final r = await api.post('/tickets', {
      'service_id': serviceId,
      if (api.session.terminalId != null) 'terminal_id': api.session.terminalId,
    }) as Map;
    final ticket = Map<String, dynamic>.from(r['ticket'] as Map);
    final qr = r['qr_url'] as String?;
    final serverStatus = (r['print'] as Map)['status'] as String;
    // Si le serveur n'a pas déjà imprimé (imprimante réseau), on imprime sur l'imprimante de cet appareil.
    final printing = (printer == null || serverStatus == 'printed') ? null : _localPrint(ticket, qr);
    final res = TicketResult(ticket, qrUrl: qr, printStatus: serverStatus, printing: printing);
    _recent[ticket['id'] as int] = res;
    if (_recent.length > 20) _recent.remove(_recent.keys.first);
    return res;
  }

  Future<String> _localPrint(Js ticket, String? qr) async {
    try {
      final cfg = await settings();
      return await printer!.printTicket(jobFromTicket(ticket, org: '${cfg['org_name']}', message: '${cfg['ticket_message'] ?? ''}', qrUrl: qr));
    } catch (_) {
      return 'failed';
    }
  }

  @override
  Future<void> reprint(int ticketId) async {
    final r = await api.post('/tickets/$ticketId/reprint',
        {if (api.session.terminalId != null) 'terminal_id': api.session.terminalId}) as Map;
    var status = (r['print'] as Map)['status'] as String;
    final known = _recent[ticketId];
    if (status != 'printed' && printer != null && known != null) status = await _localPrint(known.ticket, known.qrUrl);
    if (status == 'failed') throw ApiException(0, 'print_failed');
  }

  @override
  Future<Js> agentState() async => Map<String, dynamic>.from(await api.get('/agent/state') as Map);

  @override
  Future<void> counterAction(String action) => api.post('/agent/counter/$action');

  @override
  Future<void> callNext() => api.post('/agent/call-next');

  @override
  Future<void> ticketAction(int ticketId, String action, {int? serviceId}) =>
      api.post('/agent/tickets/$ticketId/$action', {if (serviceId != null) 'service_id': serviceId});

  @override
  Future<Js?> lastCall() async => null;

  @override
  void dispose() {
    _poll?.cancel();
    _socket?.dispose();
    _changes.close();
  }
}
