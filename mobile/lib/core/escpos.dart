import 'dart:convert';
import 'dart:typed_data';

/// Contenu d'un ticket à imprimer.
class PrintJob {
  PrintJob({
    required this.org,
    required this.service,
    required this.number,
    required this.createdAt,
    required this.ahead,
    this.estimateMinutes,
    this.message = '',
    this.qrUrl,
  });
  final String org;
  final String service;
  final String number;
  final DateTime createdAt;
  final int ahead;
  final int? estimateMinutes;
  final String message;
  final String? qrUrl;
}

// Page de codes CP858 : accents français.
const _cp858 = <String, int>{
  'é': 0x82, 'è': 0x8a, 'ê': 0x88, 'ë': 0x89, 'à': 0x85, 'â': 0x83, 'ä': 0x84, 'ç': 0x87,
  'ô': 0x93, 'ö': 0x94, 'û': 0x96, 'ù': 0x97, 'ü': 0x81, 'î': 0x8c, 'ï': 0x8b,
  'É': 0x90, 'È': 0xd4, 'Ê': 0xd2, 'À': 0xb7, 'Â': 0xb6, 'Ç': 0x80, 'Ô': 0xe2, 'Î': 0xd7, 'Û': 0xea,
  '€': 0xd5, '°': 0xf8, '’': 0x27, '→': 0x3e,
};

List<int> _enc(String s) => [for (final r in s.runes) r < 0x80 ? r : (_cp858[String.fromCharCode(r)] ?? 0x3f)];

String two(int n) => n.toString().padLeft(2, '0');

/// Ticket ESC/POS pour imprimante thermique 58 mm (32 colonnes) ou 80 mm (48 colonnes).
/// [cut] : envoie la commande de coupe ; sinon fait avancer le papier pour pouvoir l'arracher.
Uint8List buildTicketEscPos(PrintJob j, {int width = 58, bool cut = true}) {
  final cols = width == 80 ? 48 : 32;
  final b = BytesBuilder();
  void raw(List<int> x) => b.add(x);
  void line([String s = '']) {
    raw(_enc(s));
    raw([0x0a]);
  }

  raw([0x1b, 0x40]); // initialisation
  raw([0x1b, 0x74, 19]); // CP858
  raw([0x1b, 0x61, 1]); // centré
  raw([0x1b, 0x45, 1]);
  line(j.org);
  raw([0x1b, 0x45, 0]);
  line('-' * cols);
  line(j.service);
  raw([0x1d, 0x21, 0x22]); // 3x3
  raw([0x1b, 0x45, 1]);
  line(j.number);
  raw([0x1b, 0x45, 0]);
  raw([0x1d, 0x21, 0x00]);
  line();
  final d = j.createdAt;
  line('${two(d.day)}/${two(d.month)}/${d.year} ${two(d.hour)}:${two(d.minute)}');
  line(j.ahead == 0 ? 'Vous êtes le prochain' : 'Personnes devant vous : ${j.ahead}');
  if (j.estimateMinutes != null) line('Attente estimée : ~${j.estimateMinutes} min');
  line();
  final url = j.qrUrl;
  if (url != null) {
    final data = utf8.encode(url);
    raw([0x1d, 0x28, 0x6b, 0x04, 0x00, 0x31, 0x41, 0x32, 0x00]); // modèle 2
    raw([0x1d, 0x28, 0x6b, 0x03, 0x00, 0x31, 0x43, width == 80 ? 6 : 5]); // taille du module
    raw([0x1d, 0x28, 0x6b, 0x03, 0x00, 0x31, 0x45, 0x30]); // correction L
    final len = data.length + 3;
    raw([0x1d, 0x28, 0x6b, len & 0xff, len >> 8, 0x31, 0x50, 0x30]);
    raw(data);
    raw([0x1d, 0x28, 0x6b, 0x03, 0x00, 0x31, 0x51, 0x30]); // impression
    line();
    line('Scannez pour suivre votre attente');
  }
  if (j.message.isNotEmpty) line(j.message);
  if (cut) {
    line();
    line();
    raw([0x1d, 0x56, 0x41, 0x10]); // avance puis coupe partielle
  } else {
    for (var i = 0; i < 5; i++) {
      line();
    }
  }
  return b.toBytes();
}
