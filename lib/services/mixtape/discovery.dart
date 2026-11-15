import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'http_transport.dart';

const _query = 'beats-me?';
const _answer = 'beats-me';

/// A phone running beats-me that answered a discovery broadcast.
class DiscoveredPhone {
  DiscoveredPhone(this.name, this.id, this.host, this.port);
  final String name, id, host;
  final int port;

  Uri get uri => Uri.parse('http://$host:$port');
}

/// Phone side: answers "who's there?" broadcasts on the LAN with this
/// phone's name and push port. Android needs a Wi-Fi multicast lock held
/// while this runs, or broadcasts are filtered out.
class DiscoveryResponder {
  DiscoveryResponder({
    required this.name,
    required this.id,
    required this.port,
    this.listenPort = discoveryPort,
  });

  final String name, id;
  final int Function() port;
  final int listenPort;
  RawDatagramSocket? _socket;

  bool get running => _socket != null;
  int? get boundPort => _socket?.port;

  Future<void> start() async {
    final s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, listenPort, reuseAddress: true);
    _socket = s;
    s.listen((ev) {
      if (ev != RawSocketEvent.read) return;
      final d = s.receive();
      if (d == null || d.data.length > 512 || !isLanPeer(d.address)) return;
      try {
        final j = jsonDecode(utf8.decode(d.data)) as Map;
        if (j['t'] != _query) return;
        s.send(
            utf8.encode(jsonEncode(
                {'t': _answer, 'v': protocolVersion, 'name': name, 'id': id, 'port': port()})),
            d.address,
            d.port);
      } catch (_) {}
    });
  }

  void stop() {
    _socket?.close();
    _socket = null;
  }
}

/// PC side: broadcasts a query and collects the phones that answer within
/// [wait]. Only outbound traffic plus replies, so Windows Firewall allows it.
Future<List<DiscoveredPhone>> discoverPhones({
  Duration wait = const Duration(milliseconds: 1500),
  int port = discoveryPort,
  List<String> extraHosts = const [],
}) async {
  final s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  s.broadcastEnabled = true;
  final found = <String, DiscoveredPhone>{};
  final sub = s.listen((ev) {
    if (ev != RawSocketEvent.read) return;
    final d = s.receive();
    if (d == null || d.data.length > 2048 || !isLanPeer(d.address)) return;
    try {
      final j = (jsonDecode(utf8.decode(d.data)) as Map).cast<String, dynamic>();
      if (j['t'] != _answer) return;
      String short(Object? v, String fallback) {
        final s = v == null ? fallback : '$v';
        return s.length > 100 ? s.substring(0, 100) : s;
      }

      final port = (j['port'] as num?)?.toInt() ?? pushPort;
      if (port < 1 || port > 65535) return;
      final id = short(j['id'], d.address.address);
      found[id] = DiscoveredPhone(short(j['name'], 'phone'), id, d.address.address, port);
    } catch (_) {}
  });
  final targets = <String>{
    '255.255.255.255',
    for (final ip in await lanAddresses()) '${ip.substring(0, ip.lastIndexOf('.'))}.255',
    ...extraHosts,
  };
  final msg = utf8.encode(jsonEncode({'t': _query, 'v': protocolVersion}));
  final step = wait ~/ 3;
  for (var i = 0; i < 3; i++) {
    for (final t in targets) {
      try {
        s.send(msg, InternetAddress(t), port);
      } catch (_) {}
    }
    await Future<void>.delayed(step);
  }
  await sub.cancel();
  s.close();
  return found.values.toList();
}
