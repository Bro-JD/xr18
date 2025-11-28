import 'package:flutter/material.dart';
import 'package:udp/udp.dart';
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
  TextEditingController _ipController = TextEditingController(text: '192.168.1.100');
  TextEditingController _portController = TextEditingController(text: '10024');

  double _masterFader = 0.5;
  double _aux1Fader = 0.5;
  double _aux2Fader = 0.5;
  List<double> _channelFaders = List.generate(16, (index) => 0.5); // List for channels 01-16

  bool _isConnected = false;
  String _connectButtonText = "Connect";
  Color _connectButtonColor = Colors.blue;

  Future<void> _sendFaderUpdate(String channel, double value) async {
    final ip = _ipController.text;
    final port = int.tryParse(_portController.text) ?? 10024;
    var endpoint = Endpoint.unicast(InternetAddress(ip), port: Port(port));

    // OSC command format for channel fader control
    final message = "/$channel/mix/fader $value";

    var socket = await UDP.bind(Endpoint.any());
    socket.send(message.codeUnits, endpoint);
    socket.close();
  }

  // Function to attempt connection and check success
  Future<void> _connectToMixer() async {
    final ip = _ipController.text;
    final port = int.tryParse(_portController.text) ?? 10024;

    try {
      // Try sending a simple test message to the mixer
      var endpoint = Endpoint.unicast(InternetAddress(ip), port: Port(port));
      var socket = await UDP.bind(Endpoint.any());

      // Send a simple connection message to check the connection
      final testMessage = "ping";
      socket.send(testMessage.codeUnits, endpoint);

      // If no exception occurs, assume the connection is successful
      setState(() {
        _isConnected = true;
        _connectButtonText = "Connected";
        _connectButtonColor = Colors.green;
      });

      socket.close();
    } catch (e) {
      // If there is an error, update the button to show connection failure
      setState(() {
        _isConnected = false;
        _connectButtonText = "Failed to Connect";
        _connectButtonColor = Colors.red;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('XR18 Mixer Control'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: SingleChildScrollView(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              // Mixer IP & Port Inputs
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
              
              // Connect Button
              SizedBox(height: 20),
              ElevatedButton(
                onPressed: _connectToMixer,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _connectButtonColor, // Set the button color dynamically
                ),
                child: Text(
                  _connectButtonText,
                  style: TextStyle(color: Colors.white),
                ),
              ),

              // Master Fader Slider
              SizedBox(height: 20),
              Text('Master Fader: ${(_masterFader * 100).toStringAsFixed(0)}%'),
              Slider(
                value: _masterFader,
                onChanged: (value) {
                  setState(() {
                    _masterFader = value;
                  });
                  _sendFaderUpdate("lr", _masterFader);  // Corrected OSC path for Master
                },
                min: 0.0,
                max: 1.0,
              ),

              // Aux 1 Fader Slider
              SizedBox(height: 20),
              Text('Aux 1 Fader: ${(_aux1Fader * 100).toStringAsFixed(0)}%'),
              Slider(
                value: _aux1Fader,
                onChanged: (value) {
                  setState(() {
                    _aux1Fader = value;
                  });
                  _sendFaderUpdate("bus/1", _aux1Fader);  // Corrected OSC path for Aux 1
                },
                min: 0.0,
                max: 1.0,
              ),

              // Aux 2 Fader Slider
              SizedBox(height: 20),
              Text('Aux 2 Fader: ${(_aux2Fader * 100).toStringAsFixed(0)}%'),
              Slider(
                value: _aux2Fader,
                onChanged: (value) {
                  setState(() {
                    _aux2Fader = value;
                  });
                  _sendFaderUpdate("bus/2", _aux2Fader);  // Corrected OSC path for Aux 2
                },
                min: 0.0,
                max: 1.0,
              ),

              // Channel Faders (01-16)
              SizedBox(height: 20),
              Text('Channel Faders (01 - 16)', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              SizedBox(height: 10),
              Column(
                children: List.generate(16, (index) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Channel ${index + 1 < 10 ? "0${index + 1}" : index + 1} Fader: ${(_channelFaders[index] * 100).toStringAsFixed(0)}%'),
                      Slider(
                        value: _channelFaders[index],
                        onChanged: (value) {
                          setState(() {
                            _channelFaders[index] = value;
                          });
                          _sendFaderUpdate("ch/${index + 1 < 10 ? "0${index + 1}" : index + 1}", _channelFaders[index]);
                        },
                        min: 0.0,
                        max: 1.0,
                      ),
                    ],
                  );
                }),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
