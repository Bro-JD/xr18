import 'package:flutter/material.dart';
import 'dart:typed_data';
import 'dart:convert';
import 'dart:io';
import 'dart:async';

void main() {
  runApp(const MyApp());
}

// ────────── Design tokens ──────────
const _bg       = Color(0xFF0D1117);
const _surface  = Color(0xFF161B22);
const _border   = Color(0xFF30363D);
const _accent   = Color(0xFF00D4FF);
const _green    = Color(0xFF3FB950);
const _red      = Color(0xFFF85149);
const _amber    = Color(0xFFD29922);
const _textPri  = Color(0xFFE6EDF3);
const _textSec  = Color(0xFF8B949E);

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'XR18 Control',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: _bg,
        cardColor: _surface,
        colorScheme: const ColorScheme.dark(
          primary: _accent,
          secondary: _green,
          surface: _surface,
        ),
        sliderTheme: const SliderThemeData(
          activeTrackColor: _accent,
          thumbColor: _accent,
          inactiveTrackColor: _border,
          trackHeight: 3,
          thumbShape: RoundSliderThumbShape(enabledThumbRadius: 7),
          overlayColor: Color(0x2200D4FF),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: _accent,
            foregroundColor: _bg,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            textStyle: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: _accent,
            side: const BorderSide(color: _border),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
        inputDecorationTheme: const InputDecorationTheme(
          filled: true,
          fillColor: _surface,
          border: OutlineInputBorder(borderSide: BorderSide(color: _border)),
          enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: _border)),
          focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: _accent)),
          labelStyle: TextStyle(color: _textSec),
          isDense: true,
          contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        ),
        cardTheme: CardThemeData(
          color: _surface,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: _border),
          ),
        ),
      ),
      home: const XR18ControlPage(),
    );
  }
}

enum MixTarget { lr, aux1, aux2, aux3, aux4 }
enum ConnStatus { idle, discovering, connected, failed }

class XR18ControlPage extends StatefulWidget {
  const XR18ControlPage({super.key});

  @override
  State<XR18ControlPage> createState() => _XR18ControlPageState();
}

class _XR18ControlPageState extends State<XR18ControlPage> {
  final _ipController   = TextEditingController(text: '192.168.0.2');
  final _portController = TextEditingController(text: '10024');

  RawDatagramSocket? _socket;
  Timer?            _xremoteTimer;

  ConnStatus _connStatus = ConnStatus.idle;
  String     _statusMsg  = 'Not connected';

  MixTarget _selectedMix = MixTarget.lr;

  double       _masterFader = 0.75;
  bool         _masterMute  = false;
  List<double> _auxFader    = [0.75, 0.75, 0.75, 0.75];
  List<bool>   _auxMute     = [false, false, false, false];
  List<double> _channelFader = List.generate(16, (_) => 0.5);
  List<bool>   _channelMute  = List.generate(16, (_) => false);

  @override
  void initState() {
    super.initState();
    _discoverMixer();
  }

  /* ─── OSC Helpers ─── */

  Uint8List _oscString(String s) {
    final List<int> b = [...utf8.encode(s), 0];
    while (b.length % 4 != 0) b.add(0);
    return Uint8List.fromList(b);
  }

  Uint8List _oscFloat(String addr, double v) {
    final a = _oscString(addr);
    final t = _oscString(",f");
    final d = ByteData(4)..setFloat32(0, v, Endian.big);
    return Uint8List.fromList([...a, ...t, ...d.buffer.asUint8List()]);
  }

  Future<void> _ensureSocket() async {
    _socket ??= await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  }

  void _send(Uint8List data) async {
    await _ensureSocket();
    _socket!.send(
      data,
      InternetAddress(_ipController.text),
      int.tryParse(_portController.text) ?? 10024,
    );
  }

  void _sendFloat(String path, double value) => _send(_oscFloat(path, value));

  /* ─── Auto-Discovery ─── */

  Future<void> _discoverMixer() async {
    setState(() {
      _connStatus = ConnStatus.discovering;
      _statusMsg  = 'Searching…';
    });

    try {
      final sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      sock.broadcastEnabled = true;
      sock.send(_oscString('/xinfo'), InternetAddress('255.255.255.255'), 10024);

      final completer = Completer<String?>();
      Timer(const Duration(seconds: 3), () {
        if (!completer.isCompleted) completer.complete(null);
      });

      sock.listen((event) {
        if (event == RawSocketEvent.read) {
          final dg = sock.receive();
          if (dg != null && !completer.isCompleted) {
            final end = dg.data.indexOf(0);
            if (end > 0) {
              final addr = utf8.decode(dg.data.sublist(0, end));
              if (addr == '/xinfo') completer.complete(dg.address.address);
            }
          }
        }
      });

      final ip = await completer.future;
      sock.close();

      if (ip != null) {
        setState(() => _ipController.text = ip);
        _connectToMixer();
      } else {
        setState(() {
          _connStatus = ConnStatus.failed;
          _statusMsg  = 'Not found – enter IP manually';
        });
      }
    } catch (e) {
      setState(() {
        _connStatus = ConnStatus.failed;
        _statusMsg  = 'Discovery error';
      });
    }
  }

  /* ─── Request State ─── */

  void _requestActiveMixState() {
    for (int ch = 1; ch <= 16; ch++) {
      final c = _two(ch);
      switch (_selectedMix) {
        case MixTarget.lr:
          _send(_oscString("/ch/$c/mix/fader"));
          _send(_oscString("/ch/$c/mix/on"));
          break;
        case MixTarget.aux1:
          _send(_oscString("/ch/$c/mix/01/level"));
          _send(_oscString("/ch/$c/mix/01/on"));
          break;
        case MixTarget.aux2:
          _send(_oscString("/ch/$c/mix/02/level"));
          _send(_oscString("/ch/$c/mix/02/on"));
          break;
        case MixTarget.aux3:
          _send(_oscString("/ch/$c/mix/03/level"));
          _send(_oscString("/ch/$c/mix/03/on"));
          break;
        case MixTarget.aux4:
          _send(_oscString("/ch/$c/mix/04/level"));
          _send(_oscString("/ch/$c/mix/04/on"));
          break;
      }
    }
    if (_selectedMix == MixTarget.lr) {
      _send(_oscString("/lr/mix/fader"));
      _send(_oscString("/lr/mix/on"));
    } else {
      final busNum = _selectedMix.index;
      _send(_oscString("/bus/${_two(busNum)}/mix/fader"));
      _send(_oscString("/bus/${_two(busNum)}/mix/on"));
    }
  }

  /* ─── Keep-Alive ─── */

  void _startXRemote() {
    _send(_oscString("/xremote"));
    _xremoteTimer?.cancel();
    _xremoteTimer = Timer.periodic(const Duration(seconds: 7), (_) {
      _send(_oscString("/xremote"));
      _requestActiveMixState();
    });
  }

  /* ─── Incoming OSC ─── */

  void _startListening() async {
    await _ensureSocket();
    _socket!.listen((RawSocketEvent e) {
      if (e == RawSocketEvent.read) {
        final dg = _socket!.receive();
        if (dg != null) _handleOscMessage(dg.data);
      }
    });
  }

  void _handleOscMessage(Uint8List data) {
    final end = data.indexOf(0);
    if (end <= 0) return;
    final address = utf8.decode(data.sublist(0, end));

    // Proper OSC 4-byte alignment
    final typeTagStart = ((end + 1) + 3) ~/ 4 * 4;
    if (typeTagStart >= data.length) return;
    final typeTagNullEnd = data.indexOf(0, typeTagStart);
    if (typeTagNullEnd < 0) return;
    final dataStart = ((typeTagNullEnd + 1) + 3) ~/ 4 * 4;
    if (dataStart + 4 > data.length) return;

    final value = ByteData.sublistView(data, dataStart, dataStart + 4)
        .getFloat32(0, Endian.big);
    _updateFromOsc(address, value);
  }

  void _updateFromOsc(String path, double value) {
    setState(() {
      final chFader = RegExp(r'^/ch/(\d{2})/mix/fader$').firstMatch(path);
      final chMute  = RegExp(r'^/ch/(\d{2})/mix/on$').firstMatch(path);

      if (chFader != null) {
        final ch = int.parse(chFader.group(1)!) - 1;
        if (ch >= 0 && ch < 16) _channelFader[ch] = value;
      } else if (chMute != null) {
        final ch = int.parse(chMute.group(1)!) - 1;
        if (ch >= 0 && ch < 16) _channelMute[ch] = value != 0;
      } else if (path == '/lr/mix/fader') {
        _masterFader = value;
      } else if (path == '/lr/mix/on') {
        _masterMute = value == 0;
      } else {
        for (int i = 0; i < 4; i++) {
          if (path == '/bus/${_two(i + 1)}/mix/fader') _auxFader[i] = value;
          if (path == '/bus/${_two(i + 1)}/mix/on')    _auxMute[i]  = value == 0;
        }
      }
    });
  }

  /* ─── Initial State ─── */

  void _requestInitialState() {
    for (int ch = 1; ch <= 16; ch++) {
      _send(_oscString("/ch/${_two(ch)}/mix/fader"));
      _send(_oscString("/ch/${_two(ch)}/mix/on"));
    }
    _send(_oscString("/lr/mix/fader"));
    _send(_oscString("/lr/mix/on"));
    for (int i = 1; i <= 4; i++) {
      _send(_oscString("/bus/${_two(i)}/mix/fader"));
      _send(_oscString("/bus/${_two(i)}/mix/on"));
    }
  }

  /* ─── Connect ─── */

  void _connectToMixer() {
    setState(() {
      _connStatus = ConnStatus.connected;
      _statusMsg  = _ipController.text;
    });
    _startXRemote();
    _startListening();
    _requestInitialState();
  }

  /* ─── Helpers ─── */

  String _two(int n) => n < 10 ? "0$n" : "$n";

  void _sendChannelLevel(int ch, double v) {
    final c = _two(ch + 1);
    switch (_selectedMix) {
      case MixTarget.lr:   _sendFloat("/ch/$c/mix/fader",    v); break;
      case MixTarget.aux1: _sendFloat("/ch/$c/mix/01/level", v); break;
      case MixTarget.aux2: _sendFloat("/ch/$c/mix/02/level", v); break;
      case MixTarget.aux3: _sendFloat("/ch/$c/mix/03/level", v); break;
      case MixTarget.aux4: _sendFloat("/ch/$c/mix/04/level", v); break;
    }
  }

  void _sendChannelMute(int ch, bool mute) {
    final c = _two(ch + 1);
    final v = mute ? 0.0 : 1.0;
    switch (_selectedMix) {
      case MixTarget.lr:   _sendFloat("/ch/$c/mix/on",    v); break;
      case MixTarget.aux1: _sendFloat("/ch/$c/mix/01/on", v); break;
      case MixTarget.aux2: _sendFloat("/ch/$c/mix/02/on", v); break;
      case MixTarget.aux3: _sendFloat("/ch/$c/mix/03/on", v); break;
      case MixTarget.aux4: _sendFloat("/ch/$c/mix/04/on", v); break;
    }
  }

  /* ─── UI ─── */

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _buildAppBar(),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildConnectionCard(),
            const SizedBox(height: 10),
            _buildMixSelector(),
            const SizedBox(height: 10),
            _buildMasterCard(),
            const SizedBox(height: 10),
            _buildChannelsCard(),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    Color statusColor;
    switch (_connStatus) {
      case ConnStatus.discovering: statusColor = _amber; break;
      case ConnStatus.connected:   statusColor = _green; break;
      case ConnStatus.failed:      statusColor = _red;   break;
      case ConnStatus.idle:        statusColor = _textSec; break;
    }

    return AppBar(
      backgroundColor: _surface,
      elevation: 0,
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(1),
        child: Container(height: 1, color: _border),
      ),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'XR18 Control',
            style: TextStyle(color: _textPri, fontWeight: FontWeight.bold, fontSize: 17),
          ),
          Row(
            children: [
              if (_connStatus == ConnStatus.discovering)
                SizedBox(
                  width: 10,
                  height: 10,
                  child: CircularProgressIndicator(strokeWidth: 1.5, color: statusColor),
                )
              else
                Icon(
                  _connStatus == ConnStatus.connected ? Icons.wifi : Icons.wifi_off,
                  size: 10,
                  color: statusColor,
                ),
              const SizedBox(width: 5),
              Text(_statusMsg, style: TextStyle(color: statusColor, fontSize: 11)),
            ],
          ),
        ],
      ),
      actions: [
        IconButton(
          tooltip: 'Re-discover mixer',
          onPressed: _connStatus == ConnStatus.discovering ? null : _discoverMixer,
          icon: const Icon(Icons.search, color: _accent, size: 22),
        ),
      ],
    );
  }

  Widget _buildConnectionCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: _ipController,
                    decoration: const InputDecoration(
                      labelText: 'Mixer IP',
                      prefixIcon: Icon(Icons.router, color: _textSec, size: 18),
                    ),
                    style: const TextStyle(color: _textPri, fontSize: 14),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 1,
                  child: TextField(
                    controller: _portController,
                    decoration: const InputDecoration(labelText: 'Port'),
                    style: const TextStyle(color: _textPri, fontSize: 14),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _connStatus == ConnStatus.discovering ? null : _discoverMixer,
                    icon: const Icon(Icons.search, size: 16),
                    label: const Text('Discover', style: TextStyle(fontSize: 13)),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _connectToMixer,
                    icon: const Icon(Icons.link, size: 16),
                    label: const Text('Connect', style: TextStyle(fontSize: 13)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMixSelector() {
    final labels = {
      MixTarget.lr:   'L/R',
      MixTarget.aux1: 'Aux 1',
      MixTarget.aux2: 'Aux 2',
      MixTarget.aux3: 'Aux 3',
      MixTarget.aux4: 'Aux 4',
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            const Text('Mix', style: TextStyle(color: _textSec, fontSize: 12)),
            const SizedBox(width: 10),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: MixTarget.values.map((m) {
                    final selected = m == _selectedMix;
                    return Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: GestureDetector(
                        onTap: () => setState(() => _selectedMix = m),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 180),
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                          decoration: BoxDecoration(
                            color: selected ? _accent : Colors.transparent,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: selected ? _accent : _border),
                          ),
                          child: Text(
                            labels[m]!,
                            style: TextStyle(
                              color: selected ? _bg : _textSec,
                              fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMasterCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: const [
              Icon(Icons.speaker, size: 14, color: _accent),
              SizedBox(width: 6),
              Text('Outputs', style: TextStyle(color: _textPri, fontWeight: FontWeight.bold, fontSize: 13)),
            ]),
            const SizedBox(height: 6),
            _buildFaderRow("L/R", _masterFader, _masterMute,
              (v) { setState(() => _masterFader = v); _sendFloat("/lr/mix/fader", v); },
              () { setState(() => _masterMute = !_masterMute); _sendFloat("/lr/mix/on", _masterMute ? 0 : 1); },
            ),
            Divider(color: _border.withValues(alpha: 0.6), height: 10),
            for (int i = 0; i < 4; i++)
              _buildFaderRow("Aux ${i + 1}", _auxFader[i], _auxMute[i],
                (v) { setState(() => _auxFader[i] = v); _sendFloat("/bus/${_two(i + 1)}/mix/fader", v); },
                () { setState(() => _auxMute[i] = !_auxMute[i]); _sendFloat("/bus/${_two(i + 1)}/mix/on", _auxMute[i] ? 0 : 1); },
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildChannelsCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: const [
              Icon(Icons.tune, size: 14, color: _accent),
              SizedBox(width: 6),
              Text('Channels', style: TextStyle(color: _textPri, fontWeight: FontWeight.bold, fontSize: 13)),
            ]),
            const SizedBox(height: 6),
            for (int i = 0; i < 16; i++)
              _buildFaderRow(
                _two(i + 1),
                _channelFader[i],
                _channelMute[i],
                (v) { setState(() => _channelFader[i] = v); _sendChannelLevel(i, v); },
                () { setState(() => _channelMute[i] = !_channelMute[i]); _sendChannelMute(i, _channelMute[i]); },
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildFaderRow(String label, double fader, bool mute,
      ValueChanged<double> onFader, VoidCallback onMute) {
    return Row(
      children: [
        SizedBox(
          width: 40,
          child: Text(label, style: const TextStyle(color: _textSec, fontSize: 12)),
        ),
        Expanded(
          child: Slider(value: fader, min: 0, max: 1, onChanged: onFader),
        ),
        SizedBox(
          width: 30,
          child: Text(
            '${(fader * 100).round()}',
            textAlign: TextAlign.right,
            style: const TextStyle(color: _textSec, fontSize: 11),
          ),
        ),
        const SizedBox(width: 6),
        _MuteButton(muted: mute, onTap: onMute),
      ],
    );
  }

  @override
  void dispose() {
    _xremoteTimer?.cancel();
    _socket?.close();
    super.dispose();
  }
}

// ────────── Animated mute button ──────────
class _MuteButton extends StatelessWidget {
  const _MuteButton({required this.muted, required this.onTap});

  final bool muted;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = muted ? _red : _green;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: 34,
        height: 26,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: color.withValues(alpha: muted ? 0.8 : 0.4)),
        ),
        child: Icon(
          muted ? Icons.volume_off : Icons.volume_up,
          size: 15,
          color: color,
        ),
      ),
    );
  }
}
