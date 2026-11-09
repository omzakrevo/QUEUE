import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' as sqf;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'announcer.dart';
import 'core/auth.dart';
import 'core/engine.dart';
import 'core/server.dart';
import 'local_backend.dart';
import 'printer.dart';

/// Ce téléphone : moteur de files + voix + (en option) serveur pour les autres appareils.
class LocalHost extends ChangeNotifier {
  LocalHost._(this.engine, this.auth, this.counterId, this.printer) {
    server = LocalServer(engine, auth, _loadAsset, port: port);
    announcer = Announcer(engine);
    backend = LocalBackend(engine, counterId, printer: printer, qrBase: () => sharing && addresses.isNotEmpty ? addresses.first : null);
  }

  static const port = 3000;
  final QueueEngine engine;
  final Auth auth;
  final int counterId;
  final PrinterService printer;
  late final LocalServer server;
  late final Announcer announcer;
  late final LocalBackend backend;

  bool sharing = false;
  List<String> addresses = [];
  String? error;

  /// Codes d'accès générés, affichés une seule fois (seuls les hachages sont conservés).
  Map<String, String>? newCodes;

  static Future<LocalHost> open(PrinterService printer) async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    final path = p.join(dir.path, 'omza_queue.db');
    final db = (Platform.isWindows || Platform.isLinux)
        ? await (() async {
            sqfliteFfiInit();
            return databaseFactoryFfi.openDatabase(path);
          })()
        : await sqf.openDatabase(path);
    final engine = await QueueEngine.open(db);
    // Utilisation seule : le guichet est ouvert d'office pour que l'appel fonctionne tout de suite.
    final counter = await engine.firstCounterId();
    await engine.setCounterStatus(counter, 'open');
    final h = LocalHost._(engine, Auth(engine), counter, printer);
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('share') ?? false) await h.setSharing(true);
    return h;
  }

  static Future<List<int>?> _loadAsset(String path) async {
    try {
      return (await rootBundle.load('assets/web/$path')).buffer.asUint8List();
    } catch (_) {
      return null;
    }
  }

  Future<void> refreshAddresses() async {
    try {
      final ifs = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false);
      addresses = [for (final i in ifs) for (final a in i.addresses) 'http://${a.address}:${server.boundPort}'];
    } catch (_) {
      addresses = [];
    }
    notifyListeners();
  }

  Future<void> setSharing(bool on) async {
    error = null;
    try {
      if (on) {
        if (!await auth.hasAccounts()) newCodes = await auth.provisionDevices();
        await server.start();
        await refreshAddresses();
        await WakelockPlus.enable(); // le téléphone ne doit pas se mettre en veille : il sert les autres appareils
      } else {
        await server.stop();
        addresses = [];
        await WakelockPlus.disable();
      }
      sharing = on;
      await (await SharedPreferences.getInstance()).setBool('share', on);
    } on SocketException catch (e) {
      error = 'Impossible de démarrer le serveur sur le port $port (${e.osError?.message ?? e.message}).';
      sharing = false;
    }
    notifyListeners();
  }

  Future<void> regenerateCodes() async {
    newCodes = await auth.provisionDevices();
    notifyListeners();
  }

  void dismissCodes() {
    newCodes = null;
    notifyListeners();
  }

  @override
  void dispose() {
    announcer.dispose();
    backend.dispose();
    server.stop();
    WakelockPlus.disable();
    engine.close();
    super.dispose();
  }
}
