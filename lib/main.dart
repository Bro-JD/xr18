import 'package:flutter/material.dart';
import 'dart:typed_data';
import 'dart:convert';
import 'dart:io';
import 'dart:async';

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'XR18 Control',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: XR18ControlPage(),
    );
  }
}

class XR18ControlPage extends StatefulWidget {
  @override
  _XR18ControlPageState createState() => _XR18ControlPageState();
}

class _XR18ControlPageState extends State<XR18ControlPage> {
  final TextEditingController _ipController =
      TextEditingController(text: '192.168.0.2');
  final TextEditingController _portController =
      TextEditingController(text: '10024');

  RawDatagramSocket? _socket;
  Timer? _xremoteTimer;

  double _masterFader = 0.5;
  double _aux1Fader = 0.5;
  double _aux2Fader = 0.5;
  double _aux3Fader = 0.5;
  double _aux4Fader = 0.5;

  bool _masterMute = false;
  bool _aux1Mute = false;
  bool _aux2Mute = false;
  bool _aux3Mute = false;
  bool _aux4Mute = false;

  List<double> _channelFaders = List.generate(16, (_) => 0.5);
  List<bool> _channelMute = List.generate(16, (_) => false);

  bool _isConnected = false;
  String _connectButtonText = "Connect";
  Color _connectButtonColor = Colors.blue;

  // ================= OSC BUILDERS =================

  Uint8List _oscString(String s) {
    final bytes = utf8.encode(s).toList()..add(0);
    while (bytes.length % 4 != 0) bytes.add(0);
    return Uint8List.fromList(bytes);
  }

  Uint8List buildOscMessage(String address, double value) {
    final addressBytes = _oscString(address);
    final typeBytes = _oscString(",f");
    final floatBytes = ByteData(4)..setFloat32(0, value, Endian.big);
    return Uint8List.fromList(addressBytes + typeBytes + floatBytes.buffer.asUint8List());
  }

  // ================= SOCKET =================

  Future<void> _ensureSocket() async {
    _socket ??= await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      0,
    );
  }

  void _sendRaw(Uint8List data) async {
    await _ensureSocket();
    _socket!.send(
      data,
      InternetAddress(_ipController.text),
      int.tryParse(_portController.text) ?? 10024,
    );
  }

  // ================= OSC COMMANDS =================

  void _sendOscInfo() {
    _sendRaw(_oscString("/info"));
  }

  void _sendOscFloat(String path, double value) {
    _sendRaw(buildOscMessage(path, value));
  }

  void _sendMute(int chIndex, bool isMuted) {
    final ch = (chIndex + 1).toString().padLeft(2, '0');
    _sendOscFloat("/ch/$ch/mix/on", isMuted ? 0.0 : 1.0);
  }

  void _sendBusMute(String path, bool isMuted) {
    _sendOscFloat(path, isMuted ? 0.0 : 1.0);
  }

  // ================= XR18 KEEP-ALIVE =================

  void _startXRemote() {
    _sendRaw(_oscString("/xremote")); // initial

    _xremoteTimer?.cancel();
    _xremoteTimer = Timer.periodic(
      const Duration(seconds: 7),
      (_) => _sendRaw(_oscString("/xremote")),
    );
  }

  // ================= CONNECT BUTTON =================

  void _connectToMixer() {
    _startXRemote();
    _sendOscInfo();

    setState(() {
      _isConnected = true;
      _connectButtonText = "Connected";
      _connectButtonColor = Colors.green;
    });
  }

  String twoDigit(int n) => n < 10 ? "0$n" : "$n";

  @override
  void dispose() {
    _xremoteTimer?.cancel();
    _socket?.close();
    super.dispose();
  }

  // ================= UI =================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('XR18 Mixer Control')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // IP + Port
              TextField(
                controller: _ipController,
                decoration: InputDecoration(labelText: "Mixer IP Address"),
              ),
              TextField(
                controller: _portController,
                decoration: InputDecoration(labelText: "UDP Port"),
              ),
              SizedBox(height: 20),

              // Connect button
              ElevatedButton(
                onPressed: _connectToMixer,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _connectButtonColor,
                ),
                child: Text(
                  _connectButtonText,
                  style: TextStyle(color: Colors.white),
                ),
              ),
              SizedBox(height: 20),

              // Master Fader + Mute
              Text('Master Fader: ${(_masterFader * 100).toStringAsFixed(0)}%'),
              Row(
                children: [
                  Expanded(
                    child: Slider(
                      value: _masterFader,
                      onChanged: (v) {
                        setState(() => _masterFader = v);
                        _sendOscFloat("/lr/mix/fader", v);
                      },
                      min: 0.0,
                      max: 1.0,
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                      _masterMute ? Icons.volume_off : Icons.volume_up,
                      color: _masterMute ? Colors.red : Colors.green,
                    ),
                    onPressed: () {
                      setState(() => _masterMute = !_masterMute);
                      _sendBusMute("/lr/mix/on", _masterMute);
                    },
                  ),
                ],
              ),

              SizedBox(height: 20),

              // Aux 1-4 Faders + Mute
              for (int i = 1; i <= 4; i++)
                _buildAuxSlider(i),

              SizedBox(height: 20),

              // Channel Faders 01-16 + Mute
              Text(
                'Channel Faders (01 - 16)',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              Column(
                children: List.generate(16, (i) {
                  final ch = twoDigit(i + 1);
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        SizedBox(width: 50, child: Text('CH $ch')),
                        Expanded(
                          child: Slider(
                            value: _channelFaders[i],
                            onChanged: (v) {
                              setState(() => _channelFaders[i] = v);
                              _sendOscFloat("/ch/$ch/mix/fader", v);
                            },
                            min: 0.0,
                            max: 1.0,
                          ),
                        ),
                        IconButton(
                          icon: Icon(
                            _channelMute[i] ? Icons.volume_off : Icons.volume_up,
                            color: _channelMute[i] ? Colors.red : Colors.green,
                          ),
                          onPressed: () {
                            setState(() => _channelMute[i] = !_channelMute[i]);
                            _sendMute(i, _channelMute[i]);
                          },
                        ),
                      ],
                    ),
                  );
                }),
              ),
              SizedBox(height: 100),
            ],
          ),
        ),
      ),
    );
  }

  // ================= AUX BUILDER =================

  Widget _buildAuxSlider(int auxNumber) {
    double faderValue;
    bool muteValue;
    switch (auxNumber) {
      case 1:
        faderValue = _aux1Fader;
        muteValue = _aux1Mute;
        break;
      case 2:
        faderValue = _aux2Fader;
        muteValue = _aux2Mute;
        break;
      case 3:
        faderValue = _aux3Fader;
        muteValue = _aux3Mute;
        break;
      case 4:
        faderValue = _aux4Fader;
        muteValue = _aux4Mute;
        break;
      default:
        faderValue = 0.5;
        muteValue = false;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Aux $auxNumber Fader: ${(faderValue * 100).toStringAsFixed(0)}%'),
        Row(
          children: [
            Expanded(
              child: Slider(
                value: faderValue,
                min: 0.0,
                max: 1.0,
                onChanged: (v) {
                  setState(() {
                    switch (auxNumber) {
                      case 1:
                        _aux1Fader = v;
                        break;
                      case 2:
                        _aux2Fader = v;
                        break;
                      case 3:
                        _aux3Fader = v;
                        break;
                      case 4:
                        _aux4Fader = v;
                        break;
                    }
                  });
                  _sendOscFloat("/bus/$auxNumber/mix/fader", v);
                },
              ),
            ),
            IconButton(
              icon: Icon(
                muteValue ? Icons.volume_off : Icons.volume_up,
                color: muteValue ? Colors.red : Colors.green,
              ),
              onPressed: () {
                setState(() {
                  switch (auxNumber) {
                    case 1:
                      _aux1Mute = !_aux1Mute;
                      break;
                    case 2:
                      _aux2Mute = !_aux2Mute;
                      break;
                    case 3:
                      _aux3Mute = !_aux3Mute;
                      break;
                    case 4:
                      _aux4Mute = !_aux4Mute;
                      break;
                  }
                });

                // ✅ Send from authoritative state
                final isMuted = () {
                  switch (auxNumber) {
                    case 1:
                      return _aux1Mute;
                    case 2:
                      return _aux2Mute;
                    case 3:
                      return _aux3Mute;
                    case 4:
                      return _aux4Mute;
                    default:
                      return false;
                  }
                }();

                _sendBusMute("/bus/$auxNumber/mix/on", isMuted);
              },
            )

          ],
        ),
        SizedBox(height: 20),
      ],
    );
  }
}
