import 'package:flutter/material.dart';
import 'package:udp/udp.dart';
import 'dart:typed_data';
import 'dart:convert';
import 'dart:io';

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'XR18 Control',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: XR18ControlPage(),
    );
  }
}

class XR18ControlPage extends StatefulWidget {
  @override
  _XR18ControlPageState createState() => _XR18ControlPageState();
}

class _XR18ControlPageState extends State<XR18ControlPage> {
  TextEditingController _ipController = TextEditingController(text: '192.168.0.2');
  TextEditingController _portController = TextEditingController(text: '10024');

  double _masterFader = 0.5;
  double _aux1Fader = 0.5;
  double _aux2Fader = 0.5;
  bool _masterMute = false;
  bool _aux1Mute = false;
  bool _aux2Mute = false;

  List<double> _channelFaders = List.generate(16, (_) => 0.5);
  List<bool> _channelMute = List.generate(16, (_) => false); // false = unmuted

  bool _isConnected = false;
  String _connectButtonText = "Connect";
  Color _connectButtonColor = Colors.blue;

  // ========== OSC BUILDERS ==========

  Uint8List _oscString(String s) {
    List<int> bytes = utf8.encode(s);
    bytes.add(0); // null terminator
    while (bytes.length % 4 != 0) {
      bytes.add(0);
    }
    return Uint8List.fromList(bytes);
  }

  Uint8List buildOscMessage(String address, double value) {
    final addressBytes = _oscString(address);
    final typeBytes = _oscString(",f");
    final floatBytes = ByteData(4)..setFloat32(0, value, Endian.big);
    return Uint8List.fromList(
      addressBytes + typeBytes + floatBytes.buffer.asUint8List(),
    );
  }

  Future<void> _sendOsc(String path, double value) async {
    final ip = _ipController.text;
    final port = int.tryParse(_portController.text) ?? 10024;

    final oscPacket = buildOscMessage(path, value);

    final endpoint = Endpoint.unicast(
      InternetAddress(ip),
      port: Port(port),
    );

    final socket = await UDP.bind(Endpoint.any());
    socket.send(oscPacket, endpoint);
    socket.close();
  }


  Future<void> _sendMute(int chIndex, bool isMuted) async {
    String ch = (chIndex + 1).toString().padLeft(2, '0');
    double value = isMuted ? 0.0 : 1.0;  // XR18: 0=muted, 1=unmuted
    await _sendOsc("/ch/$ch/mix/on", value);
  }

  Future<void> _sendBusMute(String path, bool isMuted) async {
    double value = isMuted ? 0.0 : 1.0;
    await _sendOsc(path, value);
  }

  void _connectToMixer() {
    setState(() {
      _isConnected = true;
      _connectButtonText = "Connected";
      _connectButtonColor = Colors.green;
    });
  }

  String twoDigit(int n) => n < 10 ? "0$n" : "$n";

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('XR18 Mixer Control')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              // IP + Port Inputs
              TextField(
                controller: _ipController,
                decoration: InputDecoration(labelText: "Mixer IP Address"),
                keyboardType: TextInputType.number,
              ),
              TextField(
                controller: _portController,
                decoration: InputDecoration(labelText: "UDP Port (default: 10024)"),
                keyboardType: TextInputType.number,
              ),
              SizedBox(height: 20),

              // Connect Button
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

              // -------- MASTER FADER + MUTE --------
              Text('Master Fader: ${(_masterFader * 100).toStringAsFixed(0)}%'),
              Row(
                children: [
                  Expanded(
                    child: Slider(
                      value: _masterFader,
                      onChanged: (value) {
                        setState(() => _masterFader = value);
                        _sendOsc("/lr/mix/fader", value);
                      },
                      min: 0.0,
                      max: 1.0,
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                      _masterMute ? Icons.volume_off : Icons.volume_up,
                      size: 28,
                      color: _masterMute ? Colors.red : Colors.green,
                    ),
                    onPressed: () {
                      setState(() => _masterMute = !_masterMute);
                      _sendBusMute("/lr/mix/on", _masterMute);
                    },
                  )
                ],
              ),
              SizedBox(height: 20),

              // -------- AUX 1 FADER + MUTE --------
              Text('Aux 1 Fader: ${(_aux1Fader * 100).toStringAsFixed(0)}%'),
              Row(
                children: [
                  Expanded(
                    child: Slider(
                      value: _aux1Fader,
                      onChanged: (value) {
                        setState(() => _aux1Fader = value);
                        _sendOsc("/bus/1/mix/fader", value);
                      },
                      min: 0.0,
                      max: 1.0,
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                      _aux1Mute ? Icons.volume_off : Icons.volume_up,
                      size: 28,
                      color: _aux1Mute ? Colors.red : Colors.green,
                    ),
                    onPressed: () {
                      setState(() => _aux1Mute = !_aux1Mute);
                      _sendBusMute("/bus/1/mix/on", _aux1Mute);
                    },
                  )
                ],
              ),
              SizedBox(height: 20),

              // -------- AUX 2 FADER + MUTE --------
              Text('Aux 2 Fader: ${(_aux2Fader * 100).toStringAsFixed(0)}%'),
              Row(
                children: [
                  Expanded(
                    child: Slider(
                      value: _aux2Fader,
                      onChanged: (value) {
                        setState(() => _aux2Fader = value);
                        _sendOsc("/bus/2/mix/fader", value);
                      },
                      min: 0.0,
                      max: 1.0,
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                      _aux2Mute ? Icons.volume_off : Icons.volume_up,
                      size: 28,
                      color: _aux2Mute ? Colors.red : Colors.green,
                    ),
                    onPressed: () {
                      setState(() => _aux2Mute = !_aux2Mute);
                      _sendBusMute("/bus/2/mix/on", _aux2Mute);
                    },
                  )
                ],
              ),
              SizedBox(height: 20),

              // -------- CHANNEL FADERS + MUTE --------
              Text(
                'Channel Faders (01 - 16)',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              Column(
                children: List.generate(16, (index) {
                  final ch = twoDigit(index + 1);
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8.0),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        SizedBox(
                          width: 50,
                          child: Text(
                            'CH $ch',
                            style: TextStyle(fontSize: 16),
                          ),
                        ),
                        Expanded(
                          child: Slider(
                            value: _channelFaders[index],
                            onChanged: (value) {
                              setState(() => _channelFaders[index] = value);
                              _sendOsc("/ch/$ch/mix/fader", value);
                            },
                            min: 0.0,
                            max: 1.0,
                          ),
                        ),
                        IconButton(
                          icon: Icon(
                            _channelMute[index] ? Icons.volume_off : Icons.volume_up,
                            size: 28,
                            color: _channelMute[index] ? Colors.red : Colors.green,
                          ),
                          onPressed: () {
                            setState(() => _channelMute[index] = !_channelMute[index]);
                            _sendMute(index, _channelMute[index]);
                          },
                        )
                      ],
                    ),
                  );
                }),
              ),
                    SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }
}
