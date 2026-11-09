import 'dart:async';

import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/escpos.dart';

class PairedPrinter {
  PairedPrinter(this.name, this.address);
  final String name;
  final String address;
}

/// Liaison vers l'imprimante (Bluetooth sur Android). Abstraite pour pouvoir être testée.
abstract class PrintTransport {
  Future<bool> ensurePermission();
  Future<bool> bluetoothEnabled();
  Future<List<PairedPrinter>> paired();
  Future<bool> isConnected();
  Future<bool> connect(String address);
  Future<bool> write(List<int> bytes);
  Future<void> disconnect();
}

class BluetoothTransport implements PrintTransport {
  @override
  Future<bool> ensurePermission() => PrintBluetoothThermal.isPermissionBluetoothGranted;
  @override
  Future<bool> bluetoothEnabled() => PrintBluetoothThermal.bluetoothEnabled;
  @override
  Future<List<PairedPrinter>> paired() async =>
      [for (final b in await PrintBluetoothThermal.pairedBluetooths) PairedPrinter(b.name, b.macAdress)];
  @override
  Future<bool> isConnected() => PrintBluetoothThermal.connectionStatus;
  @override
  Future<bool> connect(String address) => PrintBluetoothThermal.connect(macPrinterAddress: address);
  @override
  Future<bool> write(List<int> bytes) => PrintBluetoothThermal.writeBytes(bytes);
  @override
  Future<void> disconnect() async {
    await PrintBluetoothThermal.disconnect;
  }
}

/// Contenu imprimé à partir d'un ticket (instantané du moteur ou réponse du serveur).
PrintJob jobFromTicket(Map<String, dynamic> t, {required String org, String message = '', String? qrUrl}) => PrintJob(
    org: org,
    service: '${t['service_name']}',
    number: '${t['ticket_number']}',
    createdAt: DateTime.tryParse('${t['created_at']}') ?? DateTime.now(),
    ahead: (t['ahead'] as num?)?.toInt() ?? 0,
    estimateMinutes: (t['estimate_minutes'] as num?)?.toInt(),
    message: message,
    qrUrl: qrUrl);

/// Réglages de l'imprimante de CET appareil (conservés localement).
class PrinterConfig {
  const PrinterConfig({this.enabled = false, this.name = '', this.address = '', this.width = 58, this.cut = true});
  final bool enabled;
  final String name;
  final String address;
  final int width; // 58 ou 80 mm
  final bool cut;

  bool get ready => enabled && address.isNotEmpty;

  PrinterConfig copyWith({bool? enabled, String? name, String? address, int? width, bool? cut}) => PrinterConfig(
      enabled: enabled ?? this.enabled,
      name: name ?? this.name,
      address: address ?? this.address,
      width: width ?? this.width,
      cut: cut ?? this.cut);

  static Future<PrinterConfig> load() async {
    final p = await SharedPreferences.getInstance();
    return PrinterConfig(
        enabled: p.getBool('printer_enabled') ?? false,
        name: p.getString('printer_name') ?? '',
        address: p.getString('printer_address') ?? '',
        width: p.getInt('printer_width') ?? 58,
        cut: p.getBool('printer_cut') ?? true);
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool('printer_enabled', enabled);
    await p.setString('printer_name', name);
    await p.setString('printer_address', address);
    await p.setInt('printer_width', width);
    await p.setBool('printer_cut', cut);
  }
}

/// Impression des tickets : connexion paresseuse, une impression à la fois, une reconnexion en cas d'échec.
class PrinterService {
  PrinterService(this.transport, {Future<PrinterConfig> Function()? loadConfig, this.chunkDelay = const Duration(milliseconds: 20)})
      : _load = loadConfig ?? PrinterConfig.load;
  final PrintTransport transport;
  final Future<PrinterConfig> Function() _load;
  final Duration chunkDelay;
  Future<void> _tail = Future.value();

  /// Dernier message d'erreur lisible (affiché dans les réglages).
  String? lastError;

  Future<PrinterConfig> config() => _load();

  /// 'printed' | 'failed' | 'none' (impression désactivée ou non configurée).
  Future<String> printTicket(PrintJob job) async {
    final c = await _load();
    if (!c.ready) return 'none';
    return _print(c, buildTicketEscPos(job, width: c.width, cut: c.cut));
  }

  Future<String> printTest() async {
    final c = await _load();
    if (c.address.isEmpty) {
      lastError = 'Choisissez d’abord une imprimante.';
      return 'failed';
    }
    return _print(
        c,
        buildTicketEscPos(
            PrintJob(
                org: 'OMZA QUEUE', service: 'Ticket de test', number: 'A001', createdAt: DateTime.now(), ahead: 2, estimateMinutes: 5,
                message: 'Impression OK'),
            width: c.width,
            cut: c.cut));
  }

  Future<String> _print(PrinterConfig c, List<int> bytes) {
    final done = Completer<String>();
    _tail = _tail.then((_) async {
      done.complete(await _attempt(c, bytes));
    });
    return done.future;
  }

  Future<String> _attempt(PrinterConfig c, List<int> bytes) async {
    try {
      if (!await transport.ensurePermission()) {
        lastError = 'Autorisation Bluetooth refusée : autorisez-la dans les réglages Android.';
        return 'failed';
      }
      if (!await transport.bluetoothEnabled()) {
        lastError = 'Le Bluetooth est désactivé.';
        return 'failed';
      }
      for (var attempt = 0; attempt < 2; attempt++) {
        if (!await transport.isConnected() || attempt == 1) {
          await transport.disconnect();
          if (!await transport.connect(c.address)) continue;
        }
        if (await _writeChunks(bytes)) {
          lastError = null;
          return 'printed';
        }
      }
      lastError = 'Imprimante injoignable : vérifiez qu’elle est allumée, chargée et à portée.';
      return 'failed';
    } catch (e) {
      lastError = 'Erreur d’impression ($e).';
      return 'failed';
    }
  }

  // Les petites imprimantes saturent si on leur envoie tout d'un coup : envoi par blocs.
  Future<bool> _writeChunks(List<int> bytes) async {
    const size = 512;
    for (var i = 0; i < bytes.length; i += size) {
      final end = i + size > bytes.length ? bytes.length : i + size;
      if (!await transport.write(bytes.sublist(i, end))) return false;
      if (chunkDelay > Duration.zero) await Future<void>.delayed(chunkDelay);
    }
    return true;
  }
}
