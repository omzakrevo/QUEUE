import 'dart:async';

import 'package:flutter_tts/flutter_tts.dart';

import 'core/engine.dart';

/// Annonces vocales faites par le téléphone lui-même (synthèse vocale du système, sans Internet) :
/// remplace l'écran TV quand l'application est utilisée seule.
class Announcer {
  Announcer(this.engine) {
    _sub = engine.events.listen(_onEvent);
  }
  final QueueEngine engine;
  final FlutterTts _tts = FlutterTts();
  late final StreamSubscription<EngineEvent> _sub;
  Future<void> _tail = Future.value();
  bool _ready = false;

  /// « Numéro {ticket}, veuillez vous présenter au guichet numéro {counter}. » ; A025 se lit « A 25 ».
  static String sentence(String template, String ticketNumber, Object counter) {
    final spoken = ticketNumber.replaceAllMapped(RegExp(r'^([A-Z]+)0*(\d+)$'), (m) => '${m[1]} ${m[2]}');
    return template.replaceAll('{ticket}', spoken).replaceAll('{counter}', '$counter');
  }

  Future<void> _init() async {
    if (_ready) return;
    await _tts.setLanguage('fr-FR');
    await _tts.awaitSpeakCompletion(true);
    _ready = true;
  }

  Future<void> _onEvent(EngineEvent e) async {
    if (e.name != 'ticket.called' && e.name != 'ticket.recalled') return;
    final s = await engine.settings();
    if (s['voice_enabled'] == 'false') return;
    final p = e.payload as Map;
    final text = sentence(s['announce_template']!, '${p['ticket_number']}', p['counter_number'] ?? '');
    final times = (int.tryParse(s['voice_repeat'] ?? '1') ?? 1).clamp(1, 3);
    await say(text, times: times, volume: double.tryParse(s['voice_volume'] ?? '1') ?? 1);
  }

  Future<void> say(String text, {int times = 1, double volume = 1}) {
    _tail = _tail.then((_) async {
      try {
        await _init();
        await _tts.setVolume(volume.clamp(0, 1));
        for (var i = 0; i < times; i++) {
          await _tts.speak(text);
        }
      } catch (_) {
        // pas de moteur vocal : l'annonce est ignorée, l'application continue
      }
    });
    return _tail;
  }

  void dispose() {
    _sub.cancel();
    _tts.stop();
  }
}
