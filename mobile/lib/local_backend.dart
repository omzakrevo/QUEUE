import 'dart:async';

import 'backend.dart';
import 'core/engine.dart';

/// Backend branché directement sur le moteur embarqué : aucun réseau, aucun serveur.
class LocalBackend implements Backend {
  LocalBackend(this.engine, this.counterId, {this.qrBase}) {
    _sub = engine.events.listen((_) => _changes.add(null));
  }
  final QueueEngine engine;
  final int counterId;

  /// Adresse (http://ip:port) à mettre dans le QR du ticket, si le partage est activé.
  final String? Function()? qrBase;
  late final StreamSubscription<EngineEvent> _sub;
  final _changes = StreamController<void>.broadcast();

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<List<Js>> services() async => [for (final s in await engine.services(activeOnly: true)) Map<String, dynamic>.from(s)];

  @override
  Future<Js> settings() async => Map<String, dynamic>.from(await engine.settings());

  @override
  Future<TicketResult> createTicket(int serviceId) async {
    final t = Map<String, dynamic>.from(await engine.createTicket(serviceId));
    final base = qrBase?.call();
    return TicketResult(t, qrUrl: base == null ? null : '$base/t/${t['access_token']}');
  }

  @override
  Future<void> reprint(int ticketId) async {}

  @override
  Future<Js> agentState() async => Map<String, dynamic>.from(await engine.agentState(counterId));

  @override
  Future<void> counterAction(String action) => engine.setCounterStatus(
      counterId, {'open': 'open', 'pause': 'paused', 'resume': 'open', 'close': 'closed'}[action] ?? (throw EngineException('invalid_action', 400)));

  @override
  Future<void> callNext() => engine.callNext(counterId);

  @override
  Future<void> ticketAction(int id, String action, {int? serviceId}) async {
    switch (action) {
      case 'recall':
        await engine.recall(id, counterId);
      case 'start':
        await engine.start(id, counterId);
      case 'complete':
        await engine.complete(id, counterId);
      case 'absent':
        await engine.markAbsent(id, counterId);
      case 'skip':
        await engine.skip(id, counterId);
      case 'transfer':
        await engine.transfer(id, counterId, serviceId!);
      default:
        throw EngineException('invalid_action', 400);
    }
  }

  @override
  Future<Js?> lastCall() async {
    final cur = (await engine.displayState())['current'] as List;
    return cur.isEmpty ? null : Map<String, dynamic>.from(cur.first as Map);
  }

  @override
  void dispose() {
    _sub.cancel();
    _changes.close();
  }
}
