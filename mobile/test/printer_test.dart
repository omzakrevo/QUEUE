import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omza_queue/core/engine.dart';
import 'package:omza_queue/core/escpos.dart';
import 'package:omza_queue/kiosk_screen.dart';
import 'package:omza_queue/local_backend.dart';
import 'package:omza_queue/printer.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class FakeTransport implements PrintTransport {
  bool permission = true, enabled = true, connected = false, connectOk = true, writeOk = true;
  int connects = 0;
  final written = <List<int>>[];
  @override
  Future<bool> ensurePermission() async => permission;
  @override
  Future<bool> bluetoothEnabled() async => enabled;
  @override
  Future<List<PairedPrinter>> paired() async => [PairedPrinter('PT-210', 'AA:BB')];
  @override
  Future<bool> isConnected() async => connected;
  @override
  Future<bool> connect(String address) async {
    connects++;
    connected = connectOk;
    return connectOk;
  }

  @override
  Future<bool> write(List<int> bytes) async {
    if (!writeOk) return false;
    written.add(bytes);
    return true;
  }

  @override
  Future<void> disconnect() async => connected = false;
  List<int> get all => [for (final w in written) ...w];
}

bool hasBytes(List<int> hay, List<int> needle) {
  for (var i = 0; i <= hay.length - needle.length; i++) {
    var ok = true;
    for (var j = 0; j < needle.length; j++) {
      if (hay[i + j] != needle[j]) {
        ok = false;
        break;
      }
    }
    if (ok) return true;
  }
  return false;
}

PrintJob job({String? qr}) => PrintJob(
    org: 'Pharmacie Générale', service: 'Caisse', number: 'B012', createdAt: DateTime(2026, 11, 9, 8, 5), ahead: 3,
    estimateMinutes: 12, message: 'Merci de votre patience.', qrUrl: qr);

Future<PrinterService> service(FakeTransport t, {bool cut = true, int width = 58}) async =>
    PrinterService(t, loadConfig: () async => PrinterConfig(enabled: true, name: 'PT-210', address: 'AA:BB', width: width, cut: cut), chunkDelay: Duration.zero);

void main() {
  sqfliteFfiInit();

  group('contenu du ticket (ESC/POS)', () {
    test('initialisation, accents CP858, numéro, date, coupe', () {
      final b = buildTicketEscPos(job(), cut: true);
      expect(b.sublist(0, 2), [0x1b, 0x40]);
      expect(hasBytes(b, [0x1b, 0x74, 19]), isTrue, reason: 'page de codes CP858');
      expect(hasBytes(b, ascii.encode('B012')), isTrue);
      expect(hasBytes(b, ascii.encode('09/11/2026 08:05')), isTrue);
      expect(hasBytes(b, ascii.encode('Personnes devant vous : 3')), isTrue);
      expect(hasBytes(b, [...ascii.encode('Pharmacie G'), 0x82, ...ascii.encode('n'), 0x82, ...ascii.encode('rale')]), isTrue,
          reason: 'é encodé 0x82');
      expect(b.sublist(b.length - 4), [0x1d, 0x56, 0x41, 0x10], reason: 'coupe en fin de ticket');
    });

    test('sans coupe : le papier avance mais aucune commande de coupe', () {
      final b = buildTicketEscPos(job(), cut: false);
      expect(hasBytes(b, [0x1d, 0x56]), isFalse);
      expect(b.sublist(b.length - 5), List.filled(5, 0x0a));
    });

    test('QR natif avec l\'adresse de suivi, seulement quand elle existe', () {
      const url = 'http://192.168.1.20:3000/t/0123456789abcdef0123456789abcdef';
      final withQr = buildTicketEscPos(job(qr: url));
      expect(hasBytes(withQr, ascii.encode(url)), isTrue);
      expect(hasBytes(withQr, [0x1d, 0x28, 0x6b, url.length + 3, 0x00, 0x31, 0x50, 0x30]), isTrue, reason: 'stockage des données');
      expect(hasBytes(withQr, ascii.encode('Scannez pour suivre')), isTrue);
      expect(hasBytes(buildTicketEscPos(job()), [0x1d, 0x28, 0x6b]), isFalse);
    });

    test('largeur 80 mm : traits de séparation plus longs', () {
      expect(hasBytes(buildTicketEscPos(job(), width: 80), ascii.encode('-' * 48)), isTrue);
      expect(hasBytes(buildTicketEscPos(job(), width: 58), ascii.encode('-' * 48)), isFalse);
    });
  });

  group('service d\'impression', () {
    test('imprime et se connecte une seule fois pour plusieurs tickets', () async {
      final t = FakeTransport();
      final s = await service(t);
      expect(await s.printTicket(job()), 'printed');
      expect(await s.printTicket(job()), 'printed');
      expect(t.connects, 1);
      expect(hasBytes(t.all, ascii.encode('B012')), isTrue);
    });

    test('désactivée ou sans imprimante choisie : rien n\'est envoyé', () async {
      final t = FakeTransport();
      final off = PrinterService(t, loadConfig: () async => const PrinterConfig(enabled: false, address: 'AA:BB'));
      expect(await off.printTicket(job()), 'none');
      final none = PrinterService(t, loadConfig: () async => const PrinterConfig(enabled: true));
      expect(await none.printTicket(job()), 'none');
      expect(t.written, isEmpty);
    });

    test('envoi par blocs de 512 octets', () async {
      final t = FakeTransport();
      final s = await service(t);
      await s.printTicket(job(qr: 'http://192.168.1.20:3000/t/${'a' * 32}'));
      expect(t.written.every((w) => w.length <= 512), isTrue);
      expect(t.all.length, buildTicketEscPos(job(qr: 'http://192.168.1.20:3000/t/${'a' * 32}')).length);
    });

    test('échecs : permission, Bluetooth éteint, imprimante injoignable, écriture refusée', () async {
      var t = FakeTransport()..permission = false;
      var s = await service(t);
      expect(await s.printTicket(job()), 'failed');
      expect(s.lastError, contains('Autorisation'));
      t = FakeTransport()..enabled = false;
      s = await service(t);
      expect(await s.printTicket(job()), 'failed');
      expect(s.lastError, contains('Bluetooth est désactivé'));
      t = FakeTransport()..connectOk = false;
      s = await service(t);
      expect(await s.printTicket(job()), 'failed');
      expect(s.lastError, contains('injoignable'));
      t = FakeTransport()..writeOk = false;
      s = await service(t);
      expect(await s.printTicket(job()), 'failed');
    });

    test('perte de connexion : une reconnexion puis la réimpression réussit', () async {
      final t = FakeTransport();
      final s = await service(t);
      expect(await s.printTicket(job()), 'printed');
      t.connected = false; // l'imprimante s'est éteinte puis rallumée
      expect(await s.printTicket(job()), 'printed');
      expect(t.connects, 2);
    });

    test('plusieurs impressions simultanées : sérialisées, sans mélange', () async {
      final t = FakeTransport();
      final s = await service(t, cut: true);
      PrintJob j(String n) => PrintJob(org: 'X', service: 'S', number: n, createdAt: DateTime(2026), ahead: 0);
      await Future.wait([for (var i = 1; i <= 5; i++) s.printTicket(j('A00$i'))]);
      final txt = latin1.decode(t.all, allowInvalid: true);
      final order = RegExp(r'A00\d').allMatches(txt).map((m) => m[0]).toList();
      expect(order, ['A001', 'A002', 'A003', 'A004', 'A005']);
    });

    test('ticket test', () async {
      final t = FakeTransport();
      final s = await service(t);
      expect(await s.printTest(), 'printed');
      expect(hasBytes(t.all, ascii.encode('Impression OK')), isTrue);
    });
  });

  testWidgets('borne autonome : le ticket s\'affiche puis passe à « Ticket imprimé. » ; échec → réimpression', (tester) async {
    final transport = FakeTransport();
    late QueueEngine engine;
    late LocalBackend backend;
    late PrinterService printer;
    await tester.runAsync(() async {
      engine = await QueueEngine.open(await databaseFactoryFfi.openDatabase(inMemoryDatabasePath));
      await engine.setSettings({'org_name': 'Boutique Test'});
      printer = await service(transport);
      backend = LocalBackend(engine, await engine.firstCounterId(), printer: printer);
    });
    Future<void> settle() async {
      for (var i = 0; i < 12; i++) {
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
      }
      await tester.pump();
    }

    transport.connectOk = false; // l'imprimante est éteinte au moment du premier ticket
    await tester.pumpWidget(MaterialApp(home: KioskScreen(backend: backend, embedded: true)));
    await settle();
    await tester.tap(find.text('Accueil'));
    await settle();
    expect(find.text('A001'), findsOneWidget, reason: 'le ticket s\'affiche même si l\'impression échoue');
    expect(find.textContaining('Impression impossible'), findsOneWidget);
    expect(find.text('Réimprimer'), findsOneWidget);

    transport.connectOk = true; // on allume l'imprimante
    await tester.tap(find.text('Réimprimer'));
    await settle();
    expect(find.text('Ticket imprimé.'), findsOneWidget);
    expect(hasBytes(transport.all, ascii.encode('Boutique Test')), isTrue);
    expect(hasBytes(transport.all, ascii.encode('A001')), isTrue);

    await tester.runAsync(() async {
      final ev = await engine.db.query('ticket_events', where: "event_type='reprinted'");
      expect(ev.length, 1, reason: 'la réimpression est tracée, sans nouveau numéro');
      expect((await engine.summary())['totals'], containsPair('total', 1));
      backend.dispose();
      await engine.close();
    });
  });
}
