import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

void main() => runApp(const MyApp());

// ────────── Design tokens ──────────
const _bg = Color(0xFF0D1117);
const _surface = Color(0xFF161B22);
const _surfaceHi = Color(0xFF21262D);
const _border = Color(0xFF30363D);
const _accent = Color(0xFF00D4FF);
const _green = Color(0xFF3FB950);
const _red = Color(0xFFF85149);
const _amber = Color(0xFFD29922);
const _blue = Color(0xFF58A6FF);
const _magenta = Color(0xFFDB61A2);
const _textPri = Color(0xFFE6EDF3);
const _textSec = Color(0xFF8B949E);

const _mono = TextStyle(fontFeatures: [FontFeature.tabularFigures()]);

// XR18 scribble-strip colours (index % 8; 8–15 are the inverted variants)
const _xairColors = [
  _border,
  _red,
  _green,
  _amber,
  _blue,
  _magenta,
  _accent,
  _textPri
];

/// Fader position for 0 dB.
const _unity = 0.75;

// /meters/1 layout: 16 ch, 10 aux/fx returns (L/R), 6 bus, 4 fx send, main L/R, monitor L/R
const _meterCount = 40;
const _meterFloor = -128.0;
const _meterMainL = 36;
const _meterMainR = 37;
int _meterBus(int bus) => 25 + bus;

String _two(int n) => n.toString().padLeft(2, '0');

/// X-Air fader law (0..1 → dB).
double faderToDb(double f) {
  if (f <= 0) return double.negativeInfinity;
  if (f >= 0.5) return f * 40 - 30;
  if (f >= 0.25) return f * 80 - 50;
  if (f >= 0.0625) return f * 160 - 70;
  return f * 480 - 90;
}

String formatDb(double f) {
  final db = faderToDb(f);
  if (db.isInfinite) return '-∞';
  if (db.abs() < 0.05) return '0.0';
  final s = db.toStringAsFixed(1);
  return db > 0 ? '+$s' : s;
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'XR18 Control',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: _bg,
        colorScheme: const ColorScheme.dark(
            primary: _accent, secondary: _green, surface: _surface),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: _accent,
            foregroundColor: _bg,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            textStyle: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: _accent,
            side: const BorderSide(color: _border),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
        inputDecorationTheme: const InputDecorationTheme(
          filled: true,
          fillColor: _bg,
          border: OutlineInputBorder(borderSide: BorderSide(color: _border)),
          enabledBorder:
              OutlineInputBorder(borderSide: BorderSide(color: _border)),
          focusedBorder:
              OutlineInputBorder(borderSide: BorderSide(color: _accent)),
          labelStyle: TextStyle(color: _textSec),
          isDense: true,
          contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        ),
      ),
      home: const XR18ControlPage(),
    );
  }
}

/// index == bus number (0 = main L/R).
enum MixTarget { lr, aux1, aux2, aux3, aux4 }

enum ConnStatus { idle, discovering, connected, failed }

/// What the XR18's USB outputs carry, as read back from the mixer.
enum UsbMode { unknown, individual, mainMix, custom }

// /routing/usb/NN = [source, tap]. Sources (XR18 fw 1.26): 0-15 Ch01-16,
// 16-17 Aux in L/R, 18-25 FX 1-4 L/R, 26-31 Bus 1-6, 32-35 Send 1-4, 36-37 Main L/R.
// Taps: 0 AIN, 1 IN, 2 PREEQ, 3 POSTEQ, 4 PRE, 5 POST.
const _usbOutputs = 18;
const _usbSrcMainL = 36;
const _usbSrcMainR = 37;
const _usbTapAnalogIn = 0;
const _usbTapPost = 5;

final _mixCount = MixTarget.values.length;

class XR18ControlPage extends StatefulWidget {
  const XR18ControlPage({super.key});

  @override
  State<XR18ControlPage> createState() => _XR18ControlPageState();
}

class _XR18ControlPageState extends State<XR18ControlPage> {
  final _ipController = TextEditingController(text: '192.168.0.2');
  final _portController = TextEditingController(text: '10024');

  RawDatagramSocket? _socket;
  Future<RawDatagramSocket>? _socketFuture;
  StreamSubscription<RawSocketEvent>? _socketSub;
  Timer? _keepAliveTimer;
  DateTime _lastMeterAt = DateTime.fromMillisecondsSinceEpoch(0);

  ConnStatus _connStatus = ConnStatus.idle;
  String _statusMsg = 'Not connected';
  MixTarget _selectedMix = MixTarget.lr;

  /// _levels[0][ch] = main fader, _levels[n][ch] = send level to aux n.
  final List<List<double>> _levels =
      List.generate(_mixCount, (_) => List.filled(16, 0.0));
  final List<double> _busFader = List.filled(_mixCount, 0.0);
  final List<bool> _busMute = List.filled(_mixCount, false);
  final List<String> _busName = List.filled(_mixCount, '');
  final List<bool> _channelMute = List.filled(16, false);
  final List<String> _channelName = List.filled(16, '');
  final List<int> _channelColor = List.filled(16, 0);
  final List<bool> _muteGroup = List.filled(4, false);

  /// Meter levels in dB, updated ~20x/s without rebuilding the whole page.
  final _meters =
      ValueNotifier<List<double>>(List.filled(_meterCount, _meterFloor));

  /// USB output routing as reported by the mixer (null = not reported yet).
  final List<int?> _usbSrc = List.filled(_usbOutputs, null);
  final List<int?> _usbTap = List.filled(_usbOutputs, null);
  bool _usbApplying = false;

  /// Bumped on every setState so the open Settings sheet shows live state.
  final _uiTick = ValueNotifier<int>(0);

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    _uiTick.value++;
  }

  @override
  void initState() {
    super.initState();
    _discoverMixer();
  }

  /* ─── OSC encoding ─── */

  Uint8List _oscStr(String s) {
    final List<int> b = [...utf8.encode(s), 0];
    while (b.length % 4 != 0) {
      b.add(0);
    }
    return Uint8List.fromList(b);
  }

  Uint8List _oscFloat(String addr, double v) {
    final d = ByteData(4)..setFloat32(0, v, Endian.big);
    return Uint8List.fromList(
        [..._oscStr(addr), ..._oscStr(',f'), ...d.buffer.asUint8List()]);
  }

  Uint8List _oscInt(String addr, int v) {
    final d = ByteData(4)..setInt32(0, v, Endian.big);
    return Uint8List.fromList(
        [..._oscStr(addr), ..._oscStr(',i'), ...d.buffer.asUint8List()]);
  }

  Uint8List _oscInts(String addr, List<int> values) {
    final d = ByteData(4 * values.length);
    for (int i = 0; i < values.length; i++) {
      d.setInt32(i * 4, values[i], Endian.big);
    }
    return Uint8List.fromList([
      ..._oscStr(addr),
      ..._oscStr(',${'i' * values.length}'),
      ...d.buffer.asUint8List(),
    ]);
  }

  Uint8List _oscStrArg(String addr, String v) =>
      Uint8List.fromList([..._oscStr(addr), ..._oscStr(',s'), ..._oscStr(v)]);

  /* ─── Transport ─── */

  // Cache the bind future so concurrent sends share ONE socket.
  Future<RawDatagramSocket> _ensureSocket() {
    return _socketFuture ??= RawDatagramSocket.bind(InternetAddress.anyIPv4, 0)
        .then((s) => _socket = s);
  }

  void _send(Uint8List data) async {
    final sock = await _ensureSocket();
    try {
      sock.send(data, InternetAddress(_ipController.text.trim()),
          int.tryParse(_portController.text) ?? 10024);
    } catch (_) {
      // invalid IP typed in the field — ignore
    }
  }

  void _sendFloat(String path, double value) => _send(_oscFloat(path, value));
  void _sendInt(String path, int value) => _send(_oscInt(path, value));

  /// Sends many queries with short pauses so the mixer doesn't drop packets.
  Future<void> _sendBurst(List<String> queries) async {
    for (int i = 0; i < queries.length; i++) {
      _send(_oscStr(queries[i]));
      if (i % 8 == 7) await Future.delayed(const Duration(milliseconds: 5));
    }
  }

  // XR18 (X-Air) bus/group indices are NOT zero-padded: /bus/1, /config/mute/1
  String _busBase(int bus) => bus == 0 ? '/lr' : '/bus/$bus';

  String _levelPath(int bus, int ch) => bus == 0
      ? '/ch/${_two(ch + 1)}/mix/fader'
      : '/ch/${_two(ch + 1)}/mix/${_two(bus)}/level';

  /* ─── Auto-Discovery ─── */

  Future<void> _discoverMixer() async {
    setState(() {
      _connStatus = ConnStatus.discovering;
      _statusMsg = 'Searching…';
    });

    try {
      final sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      sock.broadcastEnabled = true;
      sock.send(_oscStr('/xinfo'), InternetAddress('255.255.255.255'), 10024);

      final completer = Completer<String?>();
      Timer(const Duration(seconds: 3), () {
        if (!completer.isCompleted) completer.complete(null);
      });

      sock.listen((event) {
        if (event == RawSocketEvent.read) {
          final dg = sock.receive();
          if (dg != null && !completer.isCompleted) {
            final end = dg.data.indexOf(0);
            if (end > 0 && utf8.decode(dg.data.sublist(0, end)) == '/xinfo') {
              completer.complete(dg.address.address);
            }
          }
        }
      });

      final ip = await completer.future;
      sock.close();
      if (!mounted) return;

      if (ip != null) {
        _ipController.text = ip;
        _connectToMixer();
      } else {
        setState(() {
          _connStatus = ConnStatus.failed;
          _statusMsg = 'Mixer not found';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _connStatus = ConnStatus.failed;
        _statusMsg = 'Discovery error';
      });
    }
  }

  /* ─── Connect / keep-alive ─── */

  Future<void> _connectToMixer() async {
    setState(() {
      _connStatus = ConnStatus.connected;
      _statusMsg = _ipController.text.trim();
    });
    await _startListening();
    _startKeepAlive();
    _requestInitialState();
  }

  void _startKeepAlive() {
    void tick() {
      _send(_oscStr('/xremotenfb'));
      // Meter subscription lasts ~10 s on X-Air, so renew it every 5 s.
      _send(_oscStrArg('/meters', '/meters/1'));
      if (DateTime.now().difference(_lastMeterAt) >
          const Duration(seconds: 3)) {
        _meters.value = List.filled(
            _meterCount, _meterFloor); // no data → don't show stale levels
      }
    }

    tick();
    _keepAliveTimer?.cancel();
    _keepAliveTimer = Timer.periodic(const Duration(seconds: 5), (_) => tick());
  }

  Future<void> _startListening() async {
    final sock = await _ensureSocket();
    if (_socketSub != null)
      return; // a socket stream can only be listened to once
    _socketSub = sock.listen((RawSocketEvent e) {
      if (e == RawSocketEvent.read) {
        final dg = sock.receive();
        if (dg != null) _handleOscMessage(dg.data);
      }
    });
  }

  List<String> _mixQueries(MixTarget mix) {
    final b = mix.index;
    return [
      for (int ch = 0; ch < 16; ch++) _levelPath(b, ch),
      '${_busBase(b)}/mix/fader',
      '${_busBase(b)}/mix/on',
    ];
  }

  void _requestInitialState() {
    _sendBurst([
      for (int ch = 1; ch <= 16; ch++) ...[
        '/ch/${_two(ch)}/config/name',
        '/ch/${_two(ch)}/config/color',
        '/ch/${_two(ch)}/mix/on',
      ],
      for (final m in MixTarget.values) ...[
        ..._mixQueries(m),
        '${_busBase(m.index)}/config/name',
      ],
      for (int g = 1; g <= 4; g++) '/config/mute/$g',
      ..._usbQueries,
    ]);
  }

  List<String> get _usbQueries =>
      [for (int n = 1; n <= _usbOutputs; n++) '/routing/usb/${_two(n)}'];

  /* ─── Incoming OSC ─── */

  void _handleOscMessage(Uint8List data) {
    int pos = 0;
    String? readStr() {
      final end = data.indexOf(0, pos);
      if (end < 0) return null;
      final s = utf8.decode(data.sublist(pos, end), allowMalformed: true);
      pos = (end + 4) & ~3;
      return s;
    }

    final address = readStr();
    if (address == null || address.isEmpty) return;

    final args = <Object>[];
    if (pos < data.length && data[pos] == 0x2C /* , */) {
      final tags = readStr() ?? ',';
      final bd = ByteData.sublistView(data);
      for (final t in tags.substring(1).codeUnits) {
        if (t == 0x66 /* f */ || t == 0x69 /* i */) {
          if (pos + 4 > data.length) break;
          args.add(t == 0x66
              ? bd.getFloat32(pos, Endian.big)
              : bd.getInt32(pos, Endian.big));
          pos += 4;
        } else if (t == 0x73 /* s */) {
          final s = readStr();
          if (s == null) break;
          args.add(s);
        } else if (t == 0x62 /* b */) {
          if (pos + 4 > data.length) break;
          final len = bd.getInt32(pos, Endian.big);
          pos += 4;
          if (len < 0 || pos + len > data.length) break;
          args.add(Uint8List.sublistView(data, pos, pos + len));
          pos += (len + 3) & ~3;
        } else {
          break;
        }
      }
    }

    if (!mounted || args.isEmpty) return;
    if (address == '/meters/1') {
      _onMeters(args.first);
    } else if (address.startsWith('/routing/usb/')) {
      _onUsbRouting(address, args);
    } else {
      _updateFromOsc(address, args.first);
    }
  }

  /// X-Air meter blob: int32 LE count, then int16 LE values in 1/256 dB.
  void _onMeters(Object arg) {
    if (arg is! Uint8List || arg.length < 4) return;
    final bd = ByteData.sublistView(arg);
    final max = (arg.length - 4) ~/ 2;
    var n = bd.getInt32(0, Endian.little);
    if (n <= 0 || n > max) n = max;

    final prev = _meters.value;
    final out = List<double>.filled(_meterCount, _meterFloor);
    for (int i = 0; i < n && i < _meterCount; i++) {
      final raw = bd.getInt16(4 + i * 2, Endian.little) / 256.0;
      out[i] = math.max(raw, prev[i] - 1.5); // smooth fall-off
    }
    _lastMeterAt = DateTime.now();
    _meters.value = out;
  }

  static final _reCh = RegExp(r'^/ch/(\d{2})/(.+)$');
  static final _reSend = RegExp(r'^mix/(\d{2})/level$');
  static final _reBus = RegExp(r'^/(?:bus/0?(\d)|lr)/(.+)$');
  static final _reMuteGroup = RegExp(r'^/config/mute/(\d)$');
  static final _reUsb = RegExp(r'^/routing/usb/(\d{2})(/src)?$');

  /// `/routing/usb/NN` answers [source, tap]; `/routing/usb/NN/src` just the source.
  void _onUsbRouting(String path, List<Object> args) {
    final m = _reUsb.firstMatch(path);
    if (m == null || args.first is! num) return;
    final i = int.parse(m.group(1)!) - 1;
    if (i < 0 || i >= _usbOutputs) return;
    setState(() {
      _usbSrc[i] = (args.first as num).toInt();
      if (m.group(2) == null && args.length > 1 && args[1] is num) {
        _usbTap[i] = (args[1] as num).toInt();
      }
    });
  }

  UsbMode get _usbMode {
    if (_usbSrc[0] == null || _usbSrc[1] == null) return UsbMode.unknown;
    if (_usbSrc[0] == _usbSrcMainL && _usbSrc[1] == _usbSrcMainR) {
      return UsbMode.mainMix;
    }
    for (int i = 0; i < 16; i++) {
      final s = _usbSrc[i];
      if (s != null && s != i) return UsbMode.custom;
    }
    return UsbMode.individual;
  }

  /// Individual: all 18 USB outputs back to the XR18 default (USB n = Ch n,
  /// 17-18 = Aux in), keeping each output's tap unless it came from main mode.
  /// Main mix: only USB 1-2 change, to Main L/R post-fader.
  Future<void> _setUsbMode(UsbMode mode) async {
    if (_connStatus != ConnStatus.connected || _usbApplying) return;
    setState(() => _usbApplying = true);

    final outputs = mode == UsbMode.mainMix ? 2 : _usbOutputs;
    for (int i = 0; i < outputs; i++) {
      int src;
      int tap;
      if (mode == UsbMode.mainMix) {
        src = i == 0 ? _usbSrcMainL : _usbSrcMainR;
        tap = _usbTapPost;
      } else {
        final wasMain =
            _usbSrc[i] == _usbSrcMainL || _usbSrc[i] == _usbSrcMainR;
        src = i;
        tap = (wasMain ? null : _usbTap[i]) ?? _usbTapAnalogIn;
      }
      final addr = '/routing/usb/${_two(i + 1)}';
      _send(_oscInts(addr, [src, tap]));
      _sendInt(
          '$addr/src', src); // leaf form, for firmware that only takes that
      if (i % 4 == 3) await Future.delayed(const Duration(milliseconds: 5));
    }

    // Read back what the mixer actually did, so the UI shows its real state.
    await Future.delayed(const Duration(milliseconds: 300));
    await _sendBurst(_usbQueries);
    await Future.delayed(const Duration(milliseconds: 400));
    if (mounted) setState(() => _usbApplying = false);
  }

  void _updateFromOsc(String path, Object arg) {
    final v = arg is num ? arg.toDouble() : null;
    final str = arg is String ? arg : null;

    final ch = _reCh.firstMatch(path);
    if (ch != null) {
      final i = int.parse(ch.group(1)!) - 1;
      if (i < 0 || i >= 16) return;
      final rest = ch.group(2)!;
      setState(() {
        if (rest == 'mix/fader' && v != null) {
          _levels[0][i] = v;
        } else if (rest == 'mix/on' && v != null) {
          _channelMute[i] = v == 0;
        } else if (rest == 'config/name' && str != null) {
          _channelName[i] = str;
        } else if (rest == 'config/color' && v != null) {
          _channelColor[i] = v.toInt();
        } else {
          final send = _reSend.firstMatch(rest);
          if (send != null && v != null) {
            final b = int.parse(send.group(1)!);
            if (b >= 1 && b < _mixCount) _levels[b][i] = v;
          }
        }
      });
      return;
    }

    final bus = _reBus.firstMatch(path);
    if (bus != null) {
      final b = bus.group(1) == null ? 0 : int.parse(bus.group(1)!);
      if (b >= _mixCount) return;
      final rest = bus.group(2)!;
      setState(() {
        if (rest == 'mix/fader' && v != null) {
          _busFader[b] = v;
        } else if (rest == 'mix/on' && v != null) {
          _busMute[b] = v == 0;
        } else if (rest == 'config/name' && str != null) {
          _busName[b] = str;
        }
      });
      return;
    }

    final mg = _reMuteGroup.firstMatch(path);
    if (mg != null && v != null) {
      final g = int.parse(mg.group(1)!) - 1;
      if (g >= 0 && g < 4)
        setState(() => _muteGroup[g] = v != 0); // 1 = engaged
    }
  }

  /* ─── Actions ─── */

  void _selectMix(MixTarget m) {
    setState(() => _selectedMix = m);
    if (_connStatus == ConnStatus.connected) _sendBurst(_mixQueries(m));
  }

  void _setLevel(int ch, double v) {
    final b = _selectedMix.index;
    setState(() => _levels[b][ch] = v);
    _sendFloat(_levelPath(b, ch), v);
  }

  // X-Air has no per-send mute, so this is the channel's real mute in every view.
  void _toggleChannelMute(int ch) {
    setState(() => _channelMute[ch] = !_channelMute[ch]);
    _sendInt('/ch/${_two(ch + 1)}/mix/on', _channelMute[ch] ? 0 : 1);
  }

  void _setBusFader(double v) {
    final b = _selectedMix.index;
    setState(() => _busFader[b] = v);
    _sendFloat('${_busBase(b)}/mix/fader', v);
  }

  void _toggleBusMute() {
    final b = _selectedMix.index;
    setState(() => _busMute[b] = !_busMute[b]);
    _sendInt('${_busBase(b)}/mix/on', _busMute[b] ? 0 : 1);
  }

  void _toggleMuteGroup(int g) {
    setState(() => _muteGroup[g] = !_muteGroup[g]);
    _sendInt('/config/mute/${g + 1}', _muteGroup[g] ? 1 : 0);
  }

  /* ─── Labels ─── */

  Color get _mixAccent => _selectedMix == MixTarget.lr ? _accent : _amber;

  String _mixLabel(MixTarget m) {
    final n = _busName[m.index].trim();
    if (n.isNotEmpty) return n;
    return m == MixTarget.lr ? 'Main' : 'Aux ${m.index}';
  }

  String get _masterTitle {
    if (_selectedMix == MixTarget.lr) {
      final n = _busName[0].trim();
      return n.isEmpty ? 'Main L/R' : n;
    }
    return '${_mixLabel(_selectedMix)} master';
  }

  List<int> get _masterMeters => _selectedMix == MixTarget.lr
      ? const [_meterMainL, _meterMainR]
      : [_meterBus(_selectedMix.index)];

  String _chLabel(int i) {
    final n = _channelName[i].trim();
    return n.isNotEmpty ? n : 'Ch ${_two(i + 1)}';
  }

  Color _chColor(int i) => _xairColors[_channelColor[i] % 8];

  /* ─── UI ─── */

  @override
  Widget build(BuildContext context) {
    final landscape =
        MediaQuery.of(context).orientation == Orientation.landscape;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
              12, landscape ? 6 : 4, 12, landscape ? 6 : 10),
          child: landscape ? _buildLandscape() : _buildPortrait(),
        ),
      ),
    );
  }

  Widget _buildPortrait() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildHeader(),
        const SizedBox(height: 4),
        _buildMixTabs(),
        _sectionLabel('Mute groups'),
        _buildMuteGroups(),
        _sectionLabel(
          'Channels',
          trailing: _selectedMix == MixTarget.lr
              ? 'Main mix'
              : 'Sends to ${_mixLabel(_selectedMix)}',
        ),
        // Strips take all remaining height → faders grow with the screen.
        Expanded(child: _buildStrips()),
        const SizedBox(height: 10),
        _buildMasterBar(),
      ],
    );
  }

  /// Landscape: everything above the strips collapses into one 38 px bar,
  /// so the strips get nearly the full screen height.
  Widget _buildLandscape() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 38,
          child: Row(children: [
            _statusDot(),
            const SizedBox(width: 8),
            const Text('XR18',
                style: TextStyle(
                    color: _textPri,
                    fontWeight: FontWeight.bold,
                    fontSize: 15)),
            const SizedBox(width: 12),
            Expanded(flex: 5, child: _buildMixTabs()),
            const SizedBox(width: 10),
            Expanded(flex: 3, child: _buildMuteGroups(compact: true)),
            const SizedBox(width: 4),
            _settingsButton(),
          ]),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: _buildStrips(compact: true)),
              const SizedBox(width: 8),
              SizedBox(width: 72, child: _buildMasterStrip(compact: true)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _card(Widget child, {EdgeInsets padding = const EdgeInsets.all(12)}) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _border),
      ),
      child: child,
    );
  }

  Color get _statusColor {
    switch (_connStatus) {
      case ConnStatus.discovering:
        return _amber;
      case ConnStatus.connected:
        return _green;
      case ConnStatus.failed:
        return _red;
      case ConnStatus.idle:
        return _textSec;
    }
  }

  Widget _statusDot() {
    if (_connStatus == ConnStatus.discovering) {
      return SizedBox(
        width: 10,
        height: 10,
        child: CircularProgressIndicator(strokeWidth: 1.5, color: _statusColor),
      );
    }
    return Container(
      width: 9,
      height: 9,
      decoration: BoxDecoration(color: _statusColor, shape: BoxShape.circle),
    );
  }

  Widget _settingsButton() {
    return IconButton(
      tooltip: 'Connection settings',
      visualDensity: VisualDensity.compact,
      onPressed: _openConnectionSheet,
      icon: const Icon(Icons.settings, color: _textSec, size: 20),
    );
  }

  Widget _buildHeader() {
    final failed = _connStatus == ConnStatus.failed;
    return Row(
      children: [
        _statusDot(),
        const SizedBox(width: 8),
        const Text('XR18',
            style: TextStyle(
                color: _textPri, fontWeight: FontWeight.bold, fontSize: 16)),
        const SizedBox(width: 8),
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _openConnectionSheet,
            child: Text(
              failed ? '$_statusMsg · tap to set IP' : _statusMsg,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: _connStatus == ConnStatus.connected
                    ? _textSec
                    : _statusColor,
                fontSize: 12,
              ),
            ),
          ),
        ),
        _settingsButton(),
      ],
    );
  }

  Widget _buildConnectionForm({VoidCallback? onDone}) {
    final ip = TextField(
      controller: _ipController,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: const InputDecoration(
        labelText: 'Mixer IP',
        prefixIcon: Icon(Icons.router, color: _textSec, size: 18),
      ),
      style: const TextStyle(color: _textPri, fontSize: 14),
    );
    final port = TextField(
      controller: _portController,
      keyboardType: TextInputType.number,
      decoration: const InputDecoration(labelText: 'Port'),
      style: const TextStyle(color: _textPri, fontSize: 14),
    );
    final discover = OutlinedButton.icon(
      onPressed: _connStatus == ConnStatus.discovering
          ? null
          : () {
              onDone?.call();
              _discoverMixer();
            },
      icon: const Icon(Icons.search, size: 16),
      label: const Text('Discover', style: TextStyle(fontSize: 13)),
    );
    final connect = ElevatedButton.icon(
      onPressed: () {
        onDone?.call();
        _connectToMixer();
      },
      icon: const Icon(Icons.link, size: 16),
      label: const Text('Connect', style: TextStyle(fontSize: 13)),
    );

    return LayoutBuilder(builder: (context, c) {
      if (c.maxWidth > 560) {
        return Row(children: [
          Expanded(child: ip),
          const SizedBox(width: 8),
          SizedBox(width: 90, child: port),
          const SizedBox(width: 8),
          discover,
          const SizedBox(width: 8),
          connect,
        ]);
      }
      return Column(children: [
        Row(children: [
          Expanded(flex: 3, child: ip),
          const SizedBox(width: 8),
          Expanded(child: port),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: discover),
          const SizedBox(width: 8),
          Expanded(child: connect),
        ]),
      ]);
    });
  }

  /// Draggable Settings sheet: opens at 75 % height, drag up to expand, down to close.
  void _openConnectionSheet() {
    if (_connStatus == ConnStatus.connected) _sendBurst(_usbQueries);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: _surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        builder: (ctx, scroll) => ValueListenableBuilder<int>(
          valueListenable: _uiTick,
          builder: (ctx, _, __) {
            final mq = MediaQuery.of(ctx);
            return ListView(
              controller: scroll,
              // keep content clear of the Android nav bar and the keyboard
              padding: EdgeInsets.fromLTRB(
                  16, 0, 16, 24 + mq.padding.bottom + mq.viewInsets.bottom),
              children: [
                Row(children: [
                  const Text('Settings',
                      style: TextStyle(
                          color: _textPri,
                          fontWeight: FontWeight.bold,
                          fontSize: 17)),
                  const Spacer(),
                  _statusDot(),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      _connStatus == ConnStatus.connected
                          ? 'Connected · $_statusMsg'
                          : _statusMsg,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: _statusColor, fontSize: 12),
                    ),
                  ),
                ]),
                _settingsHeading('Connection'),
                _buildConnectionForm(onDone: () => Navigator.pop(ctx)),
                _settingsHeading('USB audio out (recording)'),
                _buildUsbSection(),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _settingsHeading(String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 22, bottom: 10),
      child: Text(text,
          style: const TextStyle(
              color: _textSec,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3)),
    );
  }

  Widget _buildUsbSection() {
    final connected = _connStatus == ConnStatus.connected;
    String status;
    switch (_usbMode) {
      case UsbMode.unknown:
        status = connected
            ? "The mixer hasn't reported its USB routing yet."
            : 'Connect to the mixer to change this.';
        break;
      case UsbMode.individual:
        status = 'Mixer reports: individual channels.';
        break;
      case UsbMode.mainMix:
        status = 'Mixer reports: main mix on USB 1–2.';
        break;
      case UsbMode.custom:
        status = 'Mixer reports: custom routing (set elsewhere).';
        break;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _usbOption(
          UsbMode.individual,
          Icons.view_week,
          'Individual channels',
          'USB 1–16 = channels 1–16, USB 17–18 = Aux in. '
              'For multitrack recording.',
        ),
        const SizedBox(height: 8),
        _usbOption(
          UsbMode.mainMix,
          Icons.speaker,
          'Main mix',
          'USB 1–2 = Main L/R, post-fader. For stereo recording.',
        ),
        const SizedBox(height: 10),
        Row(children: [
          if (_usbApplying) ...[
            const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 1.5)),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Text(_usbApplying ? 'Applying…' : status,
                style: const TextStyle(color: _textSec, fontSize: 12)),
          ),
        ]),
      ],
    );
  }

  Widget _usbOption(UsbMode mode, IconData icon, String title, String desc) {
    final selected = _usbMode == mode;
    final enabled = _connStatus == ConnStatus.connected && !_usbApplying;
    return Semantics(
      button: true,
      selected: selected,
      child: Opacity(
        opacity: enabled ? 1 : 0.5,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: enabled ? () => _setUsbMode(mode) : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: selected ? _accent.withValues(alpha: 0.10) : _bg,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: selected ? _accent : _border),
            ),
            child: Row(children: [
              Icon(icon, size: 20, color: selected ? _accent : _textSec),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: const TextStyle(
                            color: _textPri,
                            fontWeight: FontWeight.bold,
                            fontSize: 14)),
                    const SizedBox(height: 2),
                    Text(desc,
                        style: const TextStyle(color: _textSec, fontSize: 12)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                selected ? Icons.radio_button_checked : Icons.radio_button_off,
                size: 20,
                color: selected ? _accent : _textSec,
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _sectionLabel(String text, {String? trailing}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 12, 2, 6),
      child: Row(children: [
        Text(text,
            style: const TextStyle(
                color: _textSec,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.3)),
        const Spacer(),
        if (trailing != null) ...[
          Text(trailing, style: TextStyle(color: _mixAccent, fontSize: 11)),
          const SizedBox(width: 4),
          const Icon(Icons.swap_horiz, size: 13, color: _textSec),
        ],
      ]),
    );
  }

  Widget _buildMixTabs() {
    return Container(
      height: 38,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: _border),
      ),
      child: Row(children: [
        for (final m in MixTarget.values)
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _selectMix(m),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 2),
                decoration: BoxDecoration(
                  color: m == _selectedMix
                      ? (m == MixTarget.lr ? _accent : _amber)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  _mixLabel(m),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: m == _selectedMix ? _bg : _textSec,
                    fontWeight:
                        m == _selectedMix ? FontWeight.bold : FontWeight.normal,
                    fontSize: 12,
                  ),
                ),
              ),
            ),
          ),
      ]),
    );
  }

  Widget _buildMuteGroups({bool compact = false}) {
    return Row(children: [
      for (int g = 0; g < 4; g++) ...[
        if (g > 0) const SizedBox(width: 6),
        Expanded(
          child: Semantics(
            button: true,
            toggled: _muteGroup[g],
            label: 'Mute group ${g + 1}',
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _toggleMuteGroup(g),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                height: 38,
                padding: const EdgeInsets.symmetric(horizontal: 2),
                decoration: BoxDecoration(
                  color: _muteGroup[g]
                      ? _red.withValues(alpha: 0.18)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: _muteGroup[g] ? _red : _border),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (!compact) ...[
                      Icon(_muteGroup[g] ? Icons.volume_off : Icons.volume_up,
                          size: 14, color: _muteGroup[g] ? _red : _textSec),
                      const SizedBox(width: 4),
                    ],
                    Flexible(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          compact ? 'MG${g + 1}' : 'MG ${g + 1}',
                          maxLines: 1,
                          style: TextStyle(
                            color: _muteGroup[g] ? _red : _textSec,
                            fontWeight: _muteGroup[g]
                                ? FontWeight.bold
                                : FontWeight.normal,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    ]);
  }

  Widget _buildStrips({bool compact = false}) {
    final b = _selectedMix.index;
    return ListView.separated(
      scrollDirection: Axis.horizontal,
      itemCount: 16,
      separatorBuilder: (context, i) => const SizedBox(width: 6),
      itemBuilder: (context, i) => SizedBox(
        width: 62,
        child: _ChannelStrip(
          name: _chLabel(i),
          number: _channelName[i].trim().isEmpty ? '' : 'CH ${_two(i + 1)}',
          color: _chColor(i),
          level: _levels[b][i],
          muted: _channelMute[i],
          accent: _mixAccent,
          meters: _meters,
          meterIndices: [i],
          onLevel: (v) => _setLevel(i, v),
          onMute: () => _toggleChannelMute(i),
          compact: compact,
        ),
      ),
    );
  }

  Widget _buildMasterStrip({bool compact = false}) {
    final b = _selectedMix.index;
    return _ChannelStrip(
      compact: compact,
      name: _mixLabel(_selectedMix),
      number: b == 0 ? 'MAIN' : 'BUS $b',
      color: _mixAccent,
      level: _busFader[b],
      muted: _busMute[b],
      accent: _mixAccent,
      meters: _meters,
      meterIndices: _masterMeters,
      onLevel: _setBusFader,
      onMute: _toggleBusMute,
    );
  }

  Widget _buildMasterBar() {
    final b = _selectedMix.index;
    return _card(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Container(
              width: 4,
              height: 14,
              decoration: BoxDecoration(
                  color: _mixAccent, borderRadius: BorderRadius.circular(2)),
            ),
            const SizedBox(width: 8),
            Text(_masterTitle,
                style: const TextStyle(
                    color: _textPri,
                    fontWeight: FontWeight.bold,
                    fontSize: 13)),
            const Spacer(),
            Text(formatDb(_busFader[b]),
                style: _mono.copyWith(color: _textPri, fontSize: 12)),
          ]),
          const SizedBox(height: 4),
          Row(children: [
            Expanded(
              child: SizedBox(
                height: 36,
                child: _Fader(
                  value: _busFader[b],
                  onChanged: _setBusFader,
                  axis: Axis.horizontal,
                  accent: _mixAccent,
                  dimmed: _busMute[b],
                ),
              ),
            ),
            const SizedBox(width: 10),
            _MuteButton(muted: _busMute[b], onTap: _toggleBusMute),
          ]),
          const SizedBox(height: 6),
          _Meter(
              levels: _meters,
              indices: _masterMeters,
              axis: Axis.horizontal,
              thickness: 4),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _keepAliveTimer?.cancel();
    _socketSub?.cancel();
    _socket?.close();
    _meters.dispose();
    _uiTick.dispose();
    _ipController.dispose();
    _portController.dispose();
    super.dispose();
  }
}

// ────────── Channel strip ──────────
class _ChannelStrip extends StatelessWidget {
  const _ChannelStrip({
    required this.name,
    required this.number,
    required this.color,
    required this.level,
    required this.muted,
    required this.accent,
    required this.meters,
    required this.meterIndices,
    required this.onLevel,
    required this.onMute,
    this.compact = false,
  });

  /// Landscape: drop the number line and tighten spacing to give the fader more travel.
  final bool compact;
  final String name;
  final String number;
  final Color color;
  final double level;
  final bool muted;
  final Color accent;
  final ValueListenable<List<double>> meters;
  final List<int> meterIndices;
  final ValueChanged<double> onLevel;
  final VoidCallback onMute;

  @override
  Widget build(BuildContext context) {
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _border),
      ),
      child: Column(
        children: [
          Container(height: 4, color: color),
          SizedBox(height: compact ? 4 : 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: _textPri, fontSize: 11, fontWeight: FontWeight.w600),
            ),
          ),
          if (!compact)
            Text(number, style: const TextStyle(color: _textSec, fontSize: 10)),
          SizedBox(height: compact ? 2 : 6),
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 34,
                  child: _Fader(
                    value: level,
                    onChanged: onLevel,
                    axis: Axis.vertical,
                    accent: accent,
                    dimmed: muted,
                  ),
                ),
                const SizedBox(width: 4),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  child: _Meter(
                      levels: meters,
                      indices: meterIndices,
                      axis: Axis.vertical),
                ),
              ],
            ),
          ),
          SizedBox(height: compact ? 2 : 6),
          Text(formatDb(level),
              style: _mono.copyWith(color: _textPri, fontSize: 11)),
          SizedBox(height: compact ? 4 : 6),
          _MuteButton(muted: muted, onTap: onMute),
          SizedBox(height: compact ? 6 : 8),
        ],
      ),
    );
  }
}

// ────────── Fader (relative drag, double-tap = 0 dB) ──────────
class _Fader extends StatefulWidget {
  const _Fader({
    required this.value,
    required this.onChanged,
    required this.axis,
    required this.accent,
    this.dimmed = false,
  });

  final double value;
  final ValueChanged<double> onChanged;
  final Axis axis;
  final Color accent;
  final bool dimmed;

  static const capLen = 18.0;

  @override
  State<_Fader> createState() => _FaderState();
}

class _FaderState extends State<_Fader> {
  // Tracks the value during a drag so several pointer events per frame aren't lost.
  double? _dragValue;

  void _update(double delta, double travel) {
    final v = ((_dragValue ?? widget.value) + delta / travel).clamp(0.0, 1.0);
    _dragValue = v;
    widget.onChanged(v);
  }

  @override
  Widget build(BuildContext context) {
    final vertical = widget.axis == Axis.vertical;
    return LayoutBuilder(builder: (context, c) {
      final travel =
          math.max(1.0, (vertical ? c.maxHeight : c.maxWidth) - _Fader.capLen);
      return Semantics(
        slider: true,
        value: formatDb(widget.value),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragStart:
              vertical ? (_) => _dragValue = widget.value : null,
          onVerticalDragUpdate:
              vertical ? (d) => _update(-d.delta.dy, travel) : null,
          onVerticalDragEnd: vertical ? (_) => _dragValue = null : null,
          onHorizontalDragStart:
              vertical ? null : (_) => _dragValue = widget.value,
          onHorizontalDragUpdate:
              vertical ? null : (d) => _update(d.delta.dx, travel),
          onHorizontalDragEnd: vertical ? null : (_) => _dragValue = null,
          onDoubleTap: () => widget.onChanged(_unity),
          child: CustomPaint(
            size: Size(c.maxWidth, c.maxHeight),
            painter: _FaderPainter(
              value: widget.value,
              vertical: vertical,
              accent: widget.accent,
              dimmed: widget.dimmed,
            ),
          ),
        ),
      );
    });
  }
}

class _FaderPainter extends CustomPainter {
  _FaderPainter(
      {required this.value,
      required this.vertical,
      required this.accent,
      required this.dimmed});

  final double value;
  final bool vertical;
  final Color accent;
  final bool dimmed;

  // +10, 0, -10, -30, -60 dB, -∞
  static const _ticks = [1.0, 0.75, 0.5, 0.25, 0.0625, 0.0];

  @override
  void paint(Canvas canvas, Size size) {
    const cap = _Fader.capLen;
    final len = (vertical ? size.height : size.width) - cap;
    final cross = (vertical ? size.width : size.height) / 2;

    Offset at(double f, double off) => vertical
        ? Offset(cross + off, cap / 2 + (1 - f) * len)
        : Offset(cap / 2 + f * len, cross + off);

    final tick = Paint()..strokeWidth = 1;
    for (final t in _ticks) {
      final unity = t == _unity;
      tick.color = unity ? _textSec : _border;
      final w = unity ? 12.0 : 9.0;
      canvas.drawLine(at(t, -w), at(t, -5), tick);
      canvas.drawLine(at(t, 5), at(t, w), tick);
    }

    RRect bar(double f0, double f1) => RRect.fromRectAndRadius(
        Rect.fromPoints(at(f0, -2), at(f1, 2)), const Radius.circular(2));
    canvas.drawRRect(bar(0, 1), Paint()..color = _border);
    canvas.drawRRect(bar(0, value),
        Paint()..color = dimmed ? accent.withValues(alpha: 0.25) : accent);

    final c = at(value, 0);
    final capRect = vertical
        ? Rect.fromCenter(
            center: c, width: math.min(size.width - 2, 28), height: cap)
        : Rect.fromCenter(
            center: c, width: cap, height: math.min(size.height - 2, 28));
    canvas.drawRRect(
      RRect.fromRectAndRadius(capRect, const Radius.circular(4)),
      Paint()..color = dimmed ? _textSec : _textPri,
    );
    final groove = Paint()
      ..color = _bg
      ..strokeWidth = 2;
    if (vertical) {
      canvas.drawLine(Offset(capRect.left + 4, c.dy),
          Offset(capRect.right - 4, c.dy), groove);
    } else {
      canvas.drawLine(Offset(c.dx, capRect.top + 4),
          Offset(c.dx, capRect.bottom - 4), groove);
    }
  }

  @override
  bool shouldRepaint(_FaderPainter old) =>
      old.value != value ||
      old.accent != accent ||
      old.dimmed != dimmed ||
      old.vertical != vertical;
}

// ────────── Level meter ──────────
class _Meter extends StatelessWidget {
  const _Meter(
      {required this.levels,
      required this.indices,
      required this.axis,
      this.thickness = 5});

  final ValueListenable<List<double>> levels;
  final List<int> indices;
  final Axis axis;
  final double thickness;

  @override
  Widget build(BuildContext context) {
    final vertical = axis == Axis.vertical;
    final extent = indices.length * thickness + (indices.length - 1) * 2.0;
    return SizedBox(
      width: vertical ? extent : null,
      height: vertical ? null : extent,
      child: RepaintBoundary(
        child: ValueListenableBuilder<List<double>>(
          valueListenable: levels,
          builder: (context, v, _) => CustomPaint(
            size: Size.infinite,
            painter: _MeterPainter(
              [for (final i in indices) i < v.length ? v[i] : _meterFloor],
              vertical,
              thickness,
            ),
          ),
        ),
      ),
    );
  }
}

class _MeterPainter extends CustomPainter {
  _MeterPainter(this.db, this.vertical, this.thickness);

  final List<double> db;
  final bool vertical;
  final double thickness;

  // -60 dB … 0 dB, green to -12, amber to -3, red above
  static double _frac(double d) => ((d + 60) / 60).clamp(0.0, 1.0);
  static const _segments = [
    [0.0, 0.8],
    [0.8, 0.95],
    [0.95, 1.0],
  ];
  static const _segColors = [_green, _amber, _red];

  @override
  void paint(Canvas canvas, Size size) {
    for (int k = 0; k < db.length; k++) {
      final off = k * (thickness + 2);
      final lane = vertical
          ? Rect.fromLTWH(off, 0, thickness, size.height)
          : Rect.fromLTWH(0, off, size.width, thickness);
      final rr = RRect.fromRectAndRadius(lane, const Radius.circular(2));
      canvas.drawRRect(rr, Paint()..color = _surfaceHi);

      final f = _frac(db[k]);
      if (f <= 0) continue;
      canvas.save();
      canvas.clipRRect(rr);
      for (int s = 0; s < _segments.length; s++) {
        final a = _segments[s][0];
        final b = math.min(_segments[s][1], f);
        if (b <= a) break;
        final r = vertical
            ? Rect.fromLTRB(lane.left, lane.bottom - b * lane.height,
                lane.right, lane.bottom - a * lane.height)
            : Rect.fromLTRB(lane.left + a * lane.width, lane.top,
                lane.left + b * lane.width, lane.bottom);
        canvas.drawRect(r, Paint()..color = _segColors[s]);
      }
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_MeterPainter old) => true;
}

// ────────── Mute button ──────────
class _MuteButton extends StatelessWidget {
  const _MuteButton({required this.muted, required this.onTap});

  final bool muted;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      toggled: muted,
      label: muted ? 'Unmute' : 'Mute',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: 44,
          height: 30,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: muted ? _red : Colors.transparent,
            borderRadius: BorderRadius.circular(7),
            border: Border.all(color: muted ? _red : _border),
          ),
          child: Text(
            'M',
            style: TextStyle(
                color: muted ? _bg : _textSec,
                fontWeight: FontWeight.w800,
                fontSize: 13),
          ),
        ),
      ),
    );
  }
}
