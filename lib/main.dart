import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:network_info_plus/network_info_plus.dart';
import 'package:path_provider/path_provider.dart';

void main() => runApp(const ConnectingApp());

class ConnectingApp extends StatelessWidget {
  const ConnectingApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Connecting',
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: const ScanScreen(),
    );
  }
}

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------

class Device {
  final String ip;
  final String name;

  /// Set only when the device accepts audio over Wi-Fi (DLNA/UPnP AVTransport).
  final String? controlUrl;

  Device({required this.ip, required this.name, this.controlUrl});

  bool get canPlay => controlUrl != null;
}

// ---------------------------------------------------------------------------
// Scanner: finds devices on the Wi-Fi network
// ---------------------------------------------------------------------------

class Scanner {
  static Future<List<Device>> scan() async {
    final devices = <String, Device>{};

    // 1) SSDP: finds speakers that accept audio over Wi-Fi (DLNA/UPnP).
    for (final d in await _ssdp()) {
      devices[d.ip] = d;
    }

    // 2) Subnet sweep: lists other devices on the network that answer on
    //    common ports, so you can see what else is there (e.g. an eSpeaker).
    final myIp = await NetworkInfo().getWifiIP();
    if (myIp != null && myIp.contains('.')) {
      final prefix = myIp.substring(0, myIp.lastIndexOf('.') + 1);
      final jobs = <Future<void>>[];
      for (var i = 1; i < 255; i++) {
        final host = '$prefix$i';
        if (host == myIp || devices.containsKey(host)) continue;
        jobs.add(_probe(host).then((open) {
          if (open) devices[host] = Device(ip: host, name: 'Device $host');
        }));
      }
      await Future.wait(jobs);
    }

    final list = devices.values.toList()
      ..sort((a, b) => (b.canPlay ? 1 : 0) - (a.canPlay ? 1 : 0));
    return list;
  }

  static Future<List<Device>> _ssdp() async {
    final locations = <String>{};
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    final sub = socket.listen((event) {
      if (event == RawSocketEvent.read) {
        final dg = socket.receive();
        if (dg == null) return;
        final text = utf8.decode(dg.data, allowMalformed: true);
        final m = RegExp(r'location:\s*(\S+)', caseSensitive: false)
            .firstMatch(text);
        if (m != null) locations.add(m.group(1)!);
      }
    });

    const msg = 'M-SEARCH * HTTP/1.1\r\n'
        'HOST: 239.255.255.250:1900\r\n'
        'MAN: "ssdp:discover"\r\n'
        'MX: 2\r\n'
        'ST: urn:schemas-upnp-org:service:AVTransport:1\r\n\r\n';
    final target = InternetAddress('239.255.255.250');
    socket.send(utf8.encode(msg), target, 1900);
    await Future.delayed(const Duration(milliseconds: 800));
    socket.send(utf8.encode(msg), target, 1900);
    await Future.delayed(const Duration(seconds: 3));
    await sub.cancel();
    socket.close();

    final found = await Future.wait(locations.map(_describe));
    return found.whereType<Device>().toList();
  }

  static Future<Device?> _describe(String location) async {
    try {
      final res = await http
          .get(Uri.parse(location))
          .timeout(const Duration(seconds: 3));
      final xml = res.body;
      final name = RegExp(r'<friendlyName>(.*?)</friendlyName>', dotAll: true)
              .firstMatch(xml)
              ?.group(1)
              ?.trim() ??
          'Speaker';
      String? control;
      for (final chunk in xml.split('<service>')) {
        if (chunk.contains('AVTransport')) {
          control = RegExp(r'<controlURL>(.*?)</controlURL>')
              .firstMatch(chunk)
              ?.group(1)
              ?.trim();
          break;
        }
      }
      if (control == null) return null;
      final uri = Uri.parse(location);
      return Device(
        ip: uri.host,
        name: name,
        controlUrl: uri.resolve(control).toString(),
      );
    } catch (_) {
      return null;
    }
  }

  static Future<bool> _probe(String host) async {
    for (final port in const [80, 8008, 8009]) {
      try {
        final s = await Socket.connect(host, port,
            timeout: const Duration(milliseconds: 500));
        s.destroy();
        return true;
      } catch (_) {}
    }
    return false;
  }
}

// ---------------------------------------------------------------------------
// Speaker: text -> audio file -> served over Wi-Fi -> played on the speaker
// ---------------------------------------------------------------------------

class Speaker {
  static final FlutterTts _tts = FlutterTts();
  static HttpServer? _server;
  static const int _port = 8765;

  static Future<void> speak(Device device, String text) async {
    final myIp = await NetworkInfo().getWifiIP();
    if (myIp == null) throw 'Phone is not connected to Wi-Fi.';

    final file = await _synthesize(text);
    await _serve(file);

    final url = 'http://$myIp:$_port/${file.uri.pathSegments.last}';
    await _soap(
      device,
      'SetAVTransportURI',
      '<InstanceID>0</InstanceID>'
          '<CurrentURI>${_esc(url)}</CurrentURI>'
          '<CurrentURIMetaData></CurrentURIMetaData>',
    );
    await _soap(device, 'Play', '<InstanceID>0</InstanceID><Speed>1</Speed>');
  }

  static Future<File> _synthesize(String text) async {
    final dir = Platform.isAndroid
        ? (await getExternalStorageDirectory())!
        : await getApplicationDocumentsDirectory();
    final ext = Platform.isAndroid ? 'wav' : 'caf';
    final name = 'speech_${DateTime.now().millisecondsSinceEpoch}.$ext';
    await _tts.awaitSynthCompletion(true);
    await _tts.synthesizeToFile(text, name);
    final file = File('${dir.path}/$name');
    if (!await file.exists()) throw 'Could not create the audio file.';
    return file;
  }

  static Future<void> _serve(File file) async {
    await _server?.close(force: true);
    final server = await HttpServer.bind(InternetAddress.anyIPv4, _port);
    _server = server;
    server.listen((req) async {
      final res = req.response;
      res.headers.contentType = file.path.endsWith('.wav')
          ? ContentType('audio', 'wav')
          : ContentType('audio', 'x-caf');
      res.headers.set('contentFeatures.dlna.org', 'DLNA.ORG_OP=01');
      res.contentLength = await file.length();
      await res.addStream(file.openRead());
      await res.close();
    });
  }

  static Future<void> _soap(Device d, String action, String args) async {
    const ns = 'urn:schemas-upnp-org:service:AVTransport:1';
    final body = '<?xml version="1.0"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
        '<s:Body><u:$action xmlns:u="$ns">$args</u:$action></s:Body>'
        '</s:Envelope>';
    final res = await http
        .post(
          Uri.parse(d.controlUrl!),
          headers: {
            'Content-Type': 'text/xml; charset="utf-8"',
            'SOAPACTION': '"$ns#$action"',
          },
          body: body,
        )
        .timeout(const Duration(seconds: 8));
    if (res.statusCode >= 300) {
      throw 'Speaker refused "$action" (HTTP ${res.statusCode}).';
    }
  }

  static String _esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
}

// ---------------------------------------------------------------------------
// Screen 1: scan and pick a speaker
// ---------------------------------------------------------------------------

class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  List<Device> _devices = [];
  bool _scanning = false;
  String? _wifiName;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan() async {
    setState(() => _scanning = true);
    final ip = await NetworkInfo().getWifiIP();
    final devices = await Scanner.scan();
    if (!mounted) return;
    setState(() {
      _wifiName = ip == null ? 'Not connected to Wi-Fi' : 'Your phone: $ip';
      _devices = devices;
      _scanning = false;
    });
  }

  void _open(Device d) {
    if (!d.canPlay) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text(
            'This device was found, but it does not accept audio over Wi-Fi.'),
      ));
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => MessageScreen(device: d)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Connecting')),
      body: Column(
        children: [
          if (_wifiName != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(_wifiName!),
            ),
          if (_scanning) const LinearProgressIndicator(),
          Expanded(
            child: _devices.isEmpty && !_scanning
                ? const Center(child: Text('No devices found. Tap Scan.'))
                : ListView.builder(
                    itemCount: _devices.length,
                    itemBuilder: (_, i) {
                      final d = _devices[i];
                      return ListTile(
                        leading: Icon(
                          d.canPlay ? Icons.speaker : Icons.devices_other,
                          color: d.canPlay ? Colors.teal : Colors.grey,
                        ),
                        title: Text(d.name),
                        subtitle: Text(d.canPlay
                            ? '${d.ip}  -  ready to speak'
                            : '${d.ip}  -  no audio-over-Wi-Fi support found'),
                        onTap: () => _open(d),
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _scanning ? null : _scan,
        icon: const Icon(Icons.wifi_find),
        label: const Text('Scan'),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Screen 2: type the message and tap Done
// ---------------------------------------------------------------------------

class MessageScreen extends StatefulWidget {
  final Device device;
  const MessageScreen({super.key, required this.device});

  @override
  State<MessageScreen> createState() => _MessageScreenState();
}

class _MessageScreenState extends State<MessageScreen> {
  final _controller = TextEditingController();
  bool _busy = false;
  String _status = '';

  Future<void> _done() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _busy = true;
      _status = 'Sending to speaker...';
    });
    try {
      await Speaker.speak(widget.device, text);
      setState(() => _status = 'Sent. The speaker should be talking now.');
    } catch (e) {
      setState(() => _status = 'Failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.device.name)),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: _controller,
              maxLines: 5,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'Type the message to speak',
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _busy ? null : _done,
                child: Text(_busy ? 'Please wait...' : 'Done'),
              ),
            ),
            const SizedBox(height: 16),
            Text(_status),
          ],
        ),
      ),
    );
  }
}
