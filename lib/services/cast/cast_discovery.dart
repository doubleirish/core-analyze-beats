import 'dart:async';
import 'dart:io';

import 'package:multicast_dns/multicast_dns.dart';

class CastDevice {
  const CastDevice({required this.id, required this.name, required this.host, this.port = 8009, this.model});

  final String id, name, host;
  final int port;
  final String? model;

  @override
  bool operator ==(Object other) => other is CastDevice && other.id == id;
  @override
  int get hashCode => id.hashCode;
}

/// Parses the `key=value` lines of a Cast device's mDNS TXT record.
Map<String, String> parseCastTxt(String txt) {
  final out = <String, String>{};
  for (final line in txt.split(RegExp(r'[\r\n]+'))) {
    final i = line.indexOf('=');
    if (i > 0) out[line.substring(0, i)] = line.substring(i + 1);
  }
  return out;
}

/// Network interfaces that accept an mDNS multicast join; virtual adapters
/// (VPN, WSL, Hyper-V) often don't, and one failure would abort the search.
Future<Iterable<NetworkInterface>> _multicastInterfaces(InternetAddressType type) async {
  final all = await NetworkInterface.list(includeLinkLocal: true, type: type);
  final group = InternetAddress('224.0.0.251');
  final ok = <NetworkInterface>[];
  for (final i in all) {
    RawDatagramSocket? s;
    try {
      s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      s.joinMulticast(group, i);
      s.leaveMulticast(group, i);
      ok.add(i);
    } catch (_) {
      // Skip this interface.
    } finally {
      s?.close();
    }
  }
  return ok;
}

Future<RawDatagramSocket> _bindSocket(dynamic host, int port, {bool reuseAddress = true, bool reusePort = false, int ttl = 1}) =>
    RawDatagramSocket.bind(host, port, reuseAddress: reuseAddress, reusePort: false, ttl: ttl);

/// Finds Chromecast / Google Cast devices on the local network over mDNS.
Future<List<CastDevice>> discoverCastDevices({Duration timeout = const Duration(seconds: 4)}) async {
  final client = MDnsClient(rawDatagramSocketFactory: _bindSocket);
  final found = <String, CastDevice>{};
  await client.start(interfacesFactory: _multicastInterfaces);
  try {
    final work = <Future<void>>[];
    await for (final ptr in client.lookup<PtrResourceRecord>(
        ResourceRecordQuery.serverPointer('_googlecast._tcp.local'),
        timeout: timeout)) {
      work.add(_resolve(client, ptr.domainName, timeout).then((d) {
        if (d != null) found[d.id] = d;
      }));
    }
    await Future.wait(work);
  } finally {
    client.stop();
  }
  final list = found.values.toList()..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return list;
}

Future<CastDevice?> _resolve(MDnsClient client, String domain, Duration timeout) async {
  SrvResourceRecord? srv;
  await for (final r in client.lookup<SrvResourceRecord>(ResourceRecordQuery.service(domain), timeout: timeout)) {
    srv = r;
    break;
  }
  if (srv == null) return null;
  String? host;
  await for (final r in client.lookup<IPAddressResourceRecord>(ResourceRecordQuery.addressIPv4(srv.target),
      timeout: timeout)) {
    host = r.address.address;
    break;
  }
  if (host == null) return null;
  var txt = <String, String>{};
  await for (final r in client.lookup<TxtResourceRecord>(ResourceRecordQuery.text(domain), timeout: timeout)) {
    txt = parseCastTxt(r.text);
    break;
  }
  final id = txt['id'] ?? domain;
  final name = txt['fn'] ?? domain.split('._').first;
  return CastDevice(id: id, name: name, host: host, port: srv.port, model: txt['md']);
}
