import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';
import 'dart:math' as math;
import 'package:sensors_plus/sensors_plus.dart'; // Import sensors_plus

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  runApp(const RCControllerApp());
}

class RCControllerApp extends StatelessWidget {
  const RCControllerApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'RC Controller',
      theme: ThemeData(
        colorScheme: ColorScheme.dark(
          primary: const Color(0xFF00E5FF),
          secondary: const Color(0xFFFF9100),
          surface: const Color(0xFF1A1A2E),
          background: const Color(0xFF0F0F1A),
          error: const Color(0xFFF44336),
        ),
        scaffoldBackgroundColor: const Color(0xFF0F0F1A),
        textTheme: const TextTheme(
          displayLarge: TextStyle(fontFamily: 'Montserrat', fontWeight: FontWeight.w700),
          displayMedium: TextStyle(fontFamily: 'Montserrat', fontWeight: FontWeight.w700),
          displaySmall: TextStyle(fontFamily: 'Montserrat', fontWeight: FontWeight.w700),
          headlineMedium: TextStyle(fontFamily: 'Montserrat', fontWeight: FontWeight.w600),
          headlineSmall: TextStyle(fontFamily: 'Montserrat', fontWeight: FontWeight.w600),
          titleLarge: TextStyle(fontFamily: 'Montserrat', fontWeight: FontWeight.w600),
          bodyLarge: TextStyle(fontFamily: 'Montserrat'),
          bodyMedium: TextStyle(fontFamily: 'Montserrat'),
        ),
        useMaterial3: true,
      ),
      home: const ControllerScreen(),
    );
  }
}

class ControllerScreen extends StatefulWidget {
  const ControllerScreen({Key? key}) : super(key: key);

  @override
  State<ControllerScreen> createState() => _ControllerScreenState();
}

class _ControllerScreenState extends State<ControllerScreen> with SingleTickerProviderStateMixin {
  String serverAddress = 'http://10.40.0.1:8080'; // Standard-IP
  String connectionStatus = 'Initialisierung...'; // Angepasster Startwert
  bool isConnected = false;

  // Control parameters
  int speed = 0;
  int direction = 0;
  bool headlightsOn = false;
  bool hornOn = false;
  bool turboMode = false;
  bool calibrationMode = false;

  // Tilt Control parameters
  bool _useTiltControl = false;
  StreamSubscription? _accelerometerSubscription;
  Timer? _tiltUpdateTimer;
  final Duration _tiltUpdateInterval = const Duration(milliseconds: 100);

  final double _tiltSensitivitySteering = 8.0;
  final double _tiltDeadzone = 0.5;

  late AnimationController _animationController;

  // --- Automatic Reconnection Parameters ---
  bool _isManuallyDisconnected = false;
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  static const int _maxReconnectAttempts = 5;
  static const Duration _initialReconnectDelay = Duration(seconds: 3);
  static const Duration _maxReconnectDelay = Duration(seconds: 60);
  // --- End Automatic Reconnection Parameters ---

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    // Versuche, sofort eine Verbindung herzustellen nach dem ersten Frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _attemptInitialConnection();
      }
    });
  }

  void _attemptInitialConnection() {
    // Wird beim Start aufgerufen
    _testConnection(isManualAttempt: true);
  }

  @override
  void dispose() {
    _animationController.dispose();
    _stopTiltControl();
    _reconnectTimer?.cancel(); // Wichtig!
    super.dispose();
  }

  // --- Automatic Reconnection Logic ---
  void _stopAnyReconnectTimersAndResetAttempts() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempts = 0;
  }

  void _handleConnectionLoss() {
    if (_isManuallyDisconnected || !mounted) {
      return; // Nicht wiederverbinden, wenn manuell getrennt oder Widget nicht mehr da
    }
    // Wenn schon ein Timer läuft, wird er durch den nächsten _scheduleNextReconnectAttempt abgebrochen und neu gestartet.
    // Starte eine neue Sequenz von Versuchen, wenn kein aktiver Timer läuft.
    if (_reconnectTimer == null || !_reconnectTimer!.isActive) {
      _reconnectAttempts = 0;
    }
    _scheduleNextReconnectAttempt();
  }

  void _scheduleNextReconnectAttempt() {
    _reconnectTimer?.cancel(); // Bestehenden Timer abbrechen

    if (isConnected || _isManuallyDisconnected || !mounted) {
      _stopAnyReconnectTimersAndResetAttempts(); // Aufräumen
      return;
    }

    _reconnectAttempts++;

    if (_reconnectAttempts > _maxReconnectAttempts) {
      if (mounted) {
        setState(() {
          connectionStatus = 'Autom. Wiederverbindung fehlgeschlagen.';
        });
      }
      _stopAnyReconnectTimersAndResetAttempts(); // Versuche beenden
      return;
    }

    int delaySeconds = (_initialReconnectDelay.inSeconds * math.pow(2, _reconnectAttempts - 1)).toInt();
    delaySeconds = math.min(delaySeconds, _maxReconnectDelay.inSeconds);

    if (mounted) {
      setState(() {
        connectionStatus = 'Verbindung verloren. Nächster Versuch (${_reconnectAttempts}/${_maxReconnectAttempts}) in ${delaySeconds}s...';
      });
    }

    _reconnectTimer = Timer(Duration(seconds: delaySeconds), () {
      if (!isConnected && !_isManuallyDisconnected && mounted) {
        _testConnection(); // Nächster Versuch, NICHT als manuell markieren
      }
    });
  }
  // --- End Automatic Reconnection Logic ---

  // --- Tilt Control Logic (unverändert) ---
  void _startTiltControl() {
    if (_accelerometerSubscription != null) return;
    _accelerometerSubscription = accelerometerEvents.listen(_handleAccelerometerEvent);
    if (isConnected) {
      _startTiltUpdateTimer();
    }
  }

  void _stopTiltControl() {
    _accelerometerSubscription?.cancel();
    _accelerometerSubscription = null;
    _stopTiltUpdateTimer();
  }

  void _handleAccelerometerEvent(AccelerometerEvent event) {
    if (!_useTiltControl || !mounted) return;
    double roll = event.y;
    if (roll.abs() < _tiltDeadzone) roll = 0;
    int newDirection = (roll * _tiltSensitivitySteering).clamp(-100, 100).toInt();
    if (newDirection != direction) {
      if (mounted) {
        setState(() {
          direction = newDirection;
        });
      }
    }
  }

  void _startTiltUpdateTimer() {
    _tiltUpdateTimer?.cancel();
    if (_useTiltControl && isConnected) {
      _tiltUpdateTimer = Timer.periodic(_tiltUpdateInterval, (_) {
        _sendTiltCommands();
      });
    }
  }

  void _stopTiltUpdateTimer() {
    _tiltUpdateTimer?.cancel();
    _tiltUpdateTimer = null;
  }

  void _sendTiltCommands() {
    if (_useTiltControl && isConnected) {
      _sendCommand('direction', direction);
    } else {
      _stopTiltUpdateTimer();
    }
  }
  // --- End Tilt Control Logic ---

  Future<void> _sendCommand(String command, dynamic value) async {
    if (!isConnected) return;

    try {
      final response = await http.post(
        Uri.parse('$serverAddress/command'),
        headers: {
          'Content-Type': 'application/json',
          'User-Agent': 'Roboter App/1.0 (Von Jonte Puschmann)'
        },
        body: jsonEncode({'command': command, 'value': value}),
      ).timeout(const Duration(milliseconds: 800)); // Leicht erhöhter Timeout

      if (response.statusCode == 200) {
        // Erfolg
      } else {
        if (mounted) {
          bool wasConnected = isConnected; // Zustand vor dem Fehler merken
          setState(() {
            connectionStatus = 'Befehl: Fehler ${response.statusCode}';
            isConnected = false;
            _stopTiltUpdateTimer();
          });
          if (wasConnected && !_isManuallyDisconnected) { // Nur wenn vorher verbunden und nicht manuell getrennt
            _handleConnectionLoss(); // Startet Wiederverbindungslogik
          }
        }
      }
    } catch (e) {
      if (mounted) {
        bool wasConnected = isConnected;
        setState(() {
          connectionStatus = 'Befehl: Verbindungsfehler';
          isConnected = false;
          _stopTiltUpdateTimer();
        });
        if (wasConnected && !_isManuallyDisconnected) {
          _handleConnectionLoss();
        }
      }
    }
  }

  Future<void> _testConnection({bool isManualAttempt = false}) async {
    if (isManualAttempt) {
      _isManuallyDisconnected = false; // Ein manueller Versuch hebt manuelle Trennung auf
      _stopAnyReconnectTimersAndResetAttempts(); // Beendet laufende automatische Versuche
    }

    if (mounted) {
      setState(() {
        if (isManualAttempt) {
          connectionStatus = 'Verbindung wird hergestellt...';
        } else {
          // Dies ist ein automatischer Wiederverbindungsversuch
          connectionStatus = 'Wiederverbindungsversuch ${_reconnectAttempts}/${_maxReconnectAttempts}...';
        }
        if (isManualAttempt) isConnected = false; // Bei manuellem Versuch explizit
        _stopTiltUpdateTimer(); // Sicherstellen, dass Tilt-Updates pausieren
      });
    }

    try {
      final response = await http.get(
        Uri.parse('$serverAddress/status'),
      ).timeout(const Duration(seconds: 3));

      if (mounted) {
        setState(() {
          if (response.statusCode == 200) {
            connectionStatus = 'Verbunden';
            isConnected = true;
            _isManuallyDisconnected = false; // Wichtig für Reconnect-Logik
            _stopAnyReconnectTimersAndResetAttempts(); // Erfolgreich, automatische Versuche stoppen
            if (_useTiltControl) {
              _startTiltUpdateTimer();
            }
          } else {
            connectionStatus = 'Serverfehler: ${response.statusCode}';
            isConnected = false;
            if (!_isManuallyDisconnected) {
              _scheduleNextReconnectAttempt(); // Nächsten Versuch planen
            }
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          connectionStatus = 'Keine Verbindung (Host nicht erreichbar)';
          isConnected = false;
        });
        if (!_isManuallyDisconnected) {
          _scheduleNextReconnectAttempt(); // Nächsten Versuch planen
        }
      }
    }
  }

  void _disconnectManually() {
    if (mounted) {
      setState(() {
        isConnected = false;
        _isManuallyDisconnected = true;
        connectionStatus = 'Manuell getrennt';
        _stopTiltControl(); // Stoppt Sensoren und Tilt-Timer
        _stopAnyReconnectTimersAndResetAttempts(); // Stoppt auch alle Wiederverbindungsversuche
      });
      print("Manually disconnected by user.");
    }
  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Theme.of(context).colorScheme.background,
              const Color(0xFF16213E),
            ],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 12.0),
            child: Column(
              children: [
                _buildHeader(),
                const SizedBox(height: 16),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        flex: 3,
                        child: _buildControlPanel(),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        flex: 2,
                        child: _buildExtraControls(),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final primary = Theme.of(context).colorScheme.primary;

    return Row(
      children: [
        Container(
          width: 60,
          height: 60,
          margin: const EdgeInsets.only(right: 16),
          decoration: BoxDecoration(
            color: Colors.black26,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: primary.withOpacity(0.5), width: 2),
          ),
          child: Center(child: Icon(Icons.directions_car, color: primary, size: 32)),
        ),
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.black12,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isConnected ? Colors.greenAccent.withOpacity(0.5) : Colors.redAccent.withOpacity(0.5),
                width: 1.5,
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('RC CONTROLLER', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, letterSpacing: 1.5, color: primary)),
                Flexible( // Damit der Status nicht überläuft
                  child: Row(
                    mainAxisSize: MainAxisSize.min, // Nimmt nur so viel Platz wie nötig
                    children: [
                      Container(
                        width: 10, height: 10,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: isConnected ? Colors.greenAccent : Colors.redAccent,
                          boxShadow: [BoxShadow(color: (isConnected ? Colors.greenAccent : Colors.redAccent).withOpacity(0.6), blurRadius: 6, spreadRadius: 1)],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Flexible( // Für lange Statusnachrichten
                        child: Text(
                          connectionStatus,
                          style: TextStyle(color: isConnected ? Colors.greenAccent : Colors.redAccent, fontWeight: FontWeight.w500),
                          overflow: TextOverflow.ellipsis, // Bei Überlauf ... anzeigen
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 10),
        // --- NEUER "Verbindung trennen / herstellen"-Knopf ---
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          transitionBuilder: (Widget child, Animation<double> animation) {
            return ScaleTransition(scale: animation, child: child);
          },
          child: isConnected
              ? IconButton(
            key: const ValueKey('disconnect_btn'), // Wichtig für AnimatedSwitcher
            onPressed: _disconnectManually,
            icon: const Icon(Icons.link_off),
            tooltip: 'Verbindung trennen',
            style: IconButton.styleFrom(
              backgroundColor: Colors.redAccent.withOpacity(0.15),
              foregroundColor: Colors.redAccent,
              padding: const EdgeInsets.all(16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: Colors.redAccent.withOpacity(0.4), width: 1.5),
              ),
            ),
          )
              : IconButton(
            key: const ValueKey('connect_btn'),
            onPressed: () { // Öffnet den Dialog zum Verbinden/Einstellungen
              showDialog(
                context: context,
                builder: (context) => _buildConnectionDialog(),
              );
            },
            icon: const Icon(Icons.wifi_off, color: Colors.orangeAccent),
            tooltip: 'Verbindung herstellen / Einstellungen',
            style: IconButton.styleFrom(
              backgroundColor: Colors.orangeAccent.withOpacity(0.15),
              foregroundColor: Colors.orangeAccent,
              padding: const EdgeInsets.all(16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: Colors.orangeAccent.withOpacity(0.4), width: 1.5),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8), // Immer Abstand zum Settings-Knopf
        // Settings button (existierend)
        IconButton(
          onPressed: () {
            showDialog(
              context: context,
              builder: (context) => _buildConnectionDialog(),
            );
          },
          icon: Icon(Icons.settings, color: primary),
          style: IconButton.styleFrom(
            backgroundColor: Colors.black26,
            padding: const EdgeInsets.all(16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: primary.withOpacity(0.5), width: 1.5),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildControlPanel() {
    final primary = Theme.of(context).colorScheme.primary;
    return Container(
      decoration: BoxDecoration(
        color: Colors.black12,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: primary.withOpacity(0.3), width: 1.5),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _useTiltControl ? 'STEUERUNG (KIPPEN/TOUCH)' : 'STEUERUNG (TOUCH)',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, letterSpacing: 2, color: primary),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black26,
                    borderRadius: BorderRadius.circular(30),
                    border: Border.all(color: primary.withOpacity(0.3), width: 1),
                  ),
                  child: Row(
                    children: [
                      Text('Status: ', style: TextStyle(fontSize: 12, color: Colors.white.withOpacity(0.7))),
                      Text(
                        speed != 0 || direction != 0 ? 'AKTIV' : 'BEREIT',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: speed != 0 || direction != 0 ? Colors.greenAccent : Colors.white),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Expanded(
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(left: 12.0),
                          child: Text(
                            _useTiltControl ? 'LENKUNG (KIPPEN)' : 'LENKUNG (TOUCH)',
                            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: Colors.white.withOpacity(0.7)),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Expanded(child: _buildSteeringWheel()),
                      ],
                    ),
                  ),
                  const SizedBox(width: 24),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(left: 12.0),
                          child: Text(
                            'GESCHWINDIGKEIT (TOUCH)',
                            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: Colors.white.withOpacity(0.7)),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Expanded(child: _buildSpeedControl()),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSteeringWheel() {
    final primary = Theme.of(context).colorScheme.primary;
    return GestureDetector(
      onPanUpdate: (details) {
        if (_useTiltControl || !isConnected) return; // Auch bei keiner Verbindung deaktivieren
        double dx = details.delta.dx;
        if (dx != 0) {
          setState(() {
            direction = (direction + dx.toInt() * 2).clamp(-100, 100);
          });
          _sendCommand('direction', direction);
        }
      },
      onPanEnd: (_) {
        if (_useTiltControl || !isConnected) return;
        setState(() { direction = 0; });
        _sendCommand('direction', 0);
      },
      onTapDown: (_) {
        if (!_useTiltControl && isConnected) { // Nur wenn Touch aktiv und verbunden
          setState(() { direction = 0; }); // Start bei 0
          // _sendCommand('direction', 0); // Senden erst bei Bewegung
        }
      },
      onTapUp: (_) {
        if (!_useTiltControl && isConnected) { // Nur wenn Touch aktiv und verbunden
          setState(() { direction = 0; });
          _sendCommand('direction', 0);
        }
      },
      child: Opacity(
        opacity: _useTiltControl || !isConnected ? 0.5 : 1.0, // Auch bei keiner Verbindung dimmen
        child: Container(
          decoration: BoxDecoration(
            color: Colors.black26,
            shape: BoxShape.circle,
            border: Border.all(color: primary.withOpacity(0.5), width: 1.5),
            boxShadow: [BoxShadow(color: primary.withOpacity(0.2), blurRadius: 10, spreadRadius: 1)],
          ),
          child: Center(
            child: Stack(
              alignment: Alignment.center,
              children: [
                Container(
                  width: 140, height: 140,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(colors: [primary.withOpacity(0.2), Colors.transparent], stops: const [0.0, 0.7]),
                  ),
                ),
                Transform.rotate(
                  angle: direction * 0.01 * math.pi / 2,
                  child: Container(
                    width: 120, height: 120,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: primary.withOpacity(0.5), width: 2),
                    ),
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Transform.rotate(angle: math.pi / 4, child: Container(width: 100, height: 8, decoration: BoxDecoration(color: primary.withOpacity(0.3), borderRadius: BorderRadius.circular(4)))),
                        Transform.rotate(angle: -math.pi / 4, child: Container(width: 100, height: 8, decoration: BoxDecoration(color: primary.withOpacity(0.3), borderRadius: BorderRadius.circular(4)))),
                        Container(
                          width: 30, height: 30,
                          decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.black45, border: Border.all(color: primary.withOpacity(0.5), width: 1.5)),
                          child: Center(child: Text('$direction', style: TextStyle(color: primary, fontWeight: FontWeight.bold, fontSize: 14))),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSpeedControl() {
    final theme = Theme.of(context);
    return Opacity( // Auch hier Opacity, wenn nicht verbunden
      opacity: !isConnected ? 0.5 : 1.0,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.black26,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: theme.colorScheme.primary.withOpacity(0.5), width: 1.5),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            return GestureDetector(
              onVerticalDragUpdate: (details) {
                if (!isConnected) return; // Deaktivieren, wenn nicht verbunden
                double dy = details.delta.dy;
                if (dy != 0) {
                  setState(() {
                    speed = (speed - dy.toInt()).clamp(-100, 100);
                  });
                  _sendCommand('speed', speed);
                }
              },
              onVerticalDragEnd: (_) {
                if (!isConnected) return;
                setState(() { speed = 0; });
                _sendCommand('speed', 0);
              },
              onTapDown: (_) {
                if (isConnected) { // Nur wenn verbunden
                  setState(() { speed = 0; });
                  // _sendCommand('speed', 0); // Senden erst bei Bewegung
                }
              },
              onTapUp: (_) {
                if (isConnected) { // Nur wenn verbunden
                  setState(() { speed = 0; });
                  _sendCommand('speed', 0);
                }
              },
              child: Stack(
                children: [
                  Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(20),
                      gradient: LinearGradient(
                        begin: Alignment.topCenter, end: Alignment.bottomCenter,
                        colors: [Colors.greenAccent.withOpacity(0.3), Colors.blueGrey.withOpacity(0.05), Colors.redAccent.withOpacity(0.3)],
                        stops: const [0.0, 0.5, 1.0],
                      ),
                    ),
                  ),
                  Positioned(
                    left: 0, right: 0,
                    top: constraints.maxHeight / 2 - (speed / 100 * constraints.maxHeight / 2),
                    child: Container(
                      height: 3,
                      decoration: BoxDecoration(
                        color: speed > 0 ? Colors.greenAccent : (speed < 0 ? Colors.redAccent : theme.colorScheme.primary),
                        boxShadow: [BoxShadow(color: (speed > 0 ? Colors.greenAccent : (speed < 0 ? Colors.redAccent : theme.colorScheme.primary)).withOpacity(0.6), blurRadius: 6, spreadRadius: 1)],
                      ),
                    ),
                  ),
                  Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          speed.abs().toString(),
                          style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: speed > 0 ? Colors.greenAccent : (speed < 0 ? Colors.redAccent : Colors.white)),
                        ),
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                          decoration: BoxDecoration(color: speed != 0 ? Colors.black38 : Colors.transparent, borderRadius: BorderRadius.circular(12)),
                          child: Text(
                            speed > 0 ? 'VORWÄRTS' : (speed < 0 ? 'RÜCKWÄRTS' : 'NEUTRAL'),
                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: speed > 0 ? Colors.greenAccent : (speed < 0 ? Colors.redAccent : Colors.white70)),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildExtraControls() {
    final primary = Theme.of(context).colorScheme.primary;
    final secondary = Theme.of(context).colorScheme.secondary;
    return Opacity( // Auch hier Opacity, wenn nicht verbunden
      opacity: !isConnected ? 0.5 : 1.0,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.black12,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: primary.withOpacity(0.3), width: 1.5),
        ),
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('ZUSATZFUNKTIONEN', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, letterSpacing: 2, color: primary)),
              const SizedBox(height: 20),
              Expanded(
                child: GridView.count(
                  crossAxisCount: 2, mainAxisSpacing: 16, crossAxisSpacing: 16,
                  children: [
                    _buildFeatureButton(
                      icon: Icons.lightbulb_outline, label: 'LICHT', isActive: headlightsOn, color: secondary,
                      onPressed: () {
                        if (!isConnected) return;
                        setState(() { headlightsOn = !headlightsOn; });
                        _sendCommand('headlights', headlightsOn);
                      },
                    ),
                    _buildFeatureButton(
                      icon: Icons.volume_up, label: 'HUPE', isActive: hornOn, color: secondary,
                      onPressed: () {
                        if (!isConnected || hornOn) return;
                        setState(() { hornOn = true; });
                        _sendCommand('horn', true);
                        Future.delayed(const Duration(milliseconds: 500), () {
                          if (mounted && hornOn) { // Nur ausschalten, wenn noch aktiv
                            setState(() { hornOn = false; });
                            _sendCommand('horn', false);
                          }
                        });
                      },
                    ),
                    _buildFeatureButton(
                      icon: Icons.speed, label: 'TURBO', isActive: turboMode, color: secondary,
                      onPressed: () {
                        if (!isConnected || turboMode) return;
                        setState(() { turboMode = true; });
                        _sendCommand('turbo', true);
                        Future.delayed(const Duration(seconds: 2), () {
                          if (mounted && turboMode) {
                            setState(() { turboMode = false; });
                            _sendCommand('turbo', false);
                          }
                        });
                      },
                    ),
                    _buildFeatureButton(
                      icon: Icons.settings_backup_restore, label: 'KALIBRIEREN', isActive: calibrationMode, color: secondary,
                      onPressed: () {
                        if (!isConnected || calibrationMode) return;
                        setState(() { calibrationMode = true; });
                        _sendCommand('calibrate', true);
                        Future.delayed(const Duration(seconds: 1), () {
                          if (mounted && calibrationMode) {
                            setState(() { calibrationMode = false; });
                          }
                        });
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.black26,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: primary.withOpacity(0.3), width: 1),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.battery_charging_full, color: primary, size: 18),
                        const SizedBox(width: 8),
                        Text('BATTERIE', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: Colors.white.withOpacity(0.7))),
                      ],
                    ),
                    Row(
                      children: [
                        Container(
                          width: 100, height: 6,
                          decoration: BoxDecoration(color: Colors.black45, borderRadius: BorderRadius.circular(3)),
                          child: Row(children: [
                            Container(width: 75, decoration: BoxDecoration(color: Colors.greenAccent, borderRadius: BorderRadius.circular(3), boxShadow: [BoxShadow(color: Colors.greenAccent.withOpacity(0.6), blurRadius: 4, spreadRadius: 0)])),
                          ]),
                        ),
                        const SizedBox(width: 8),
                        const Text('75%', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.greenAccent)),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFeatureButton({
    required IconData icon, required String label, required bool isActive,
    required Color color, required VoidCallback onPressed,
  }) {
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        decoration: BoxDecoration(
          color: isActive ? color.withOpacity(0.15) : Colors.black26,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: isActive ? color : color.withOpacity(0.3), width: 1.5),
          boxShadow: isActive ? [BoxShadow(color: color.withOpacity(0.3), blurRadius: 8, spreadRadius: 0)] : null,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: isActive ? color : Colors.white70, size: 28),
            const SizedBox(height: 8),
            Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1, color: isActive ? color : Colors.white70)),
          ],
        ),
      ),
    );
  }

  Widget _buildConnectionDialog() {
    final TextEditingController serverController = TextEditingController(text: serverAddress);
    final theme = Theme.of(context);

    return StatefulBuilder(
      builder: (context, setDialogState) {
        return Dialog(
          backgroundColor: const Color(0xFF16213E),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.wifi, color: theme.colorScheme.primary),
                      const SizedBox(width: 12),
                      const Text('Verbindung & Steuerung', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
                    ],
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    controller: serverController,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: 'Server-Adresse',
                      labelStyle: const TextStyle(color: Colors.white70),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: theme.colorScheme.primary.withOpacity(0.5))),
                      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: theme.colorScheme.primary)),
                      prefixIcon: Icon(Icons.link, color: theme.colorScheme.primary),
                    ),
                  ),
                  const SizedBox(height: 16),
                  SwitchListTile(
                    title: const Text('Kipp-Steuerung aktivieren', style: TextStyle(color: Colors.white)),
                    subtitle: Text('Nur Lenkung über Handybewegung', style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 12)),
                    value: _useTiltControl,
                    onChanged: (bool value) {
                      setState(() { // Haupt-State aktualisieren
                        _useTiltControl = value;
                        if (_useTiltControl) {
                          _startTiltControl();
                        } else {
                          _stopTiltControl();
                        }
                      });
                      setDialogState(() {}); // Dialog-State für Switch-Anzeige
                    },
                    activeColor: theme.colorScheme.primary,
                    secondary: Icon(Icons.screen_rotation_alt, color: theme.colorScheme.primary),
                    contentPadding: EdgeInsets.zero,
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      const Text('Status: ', style: TextStyle(color: Colors.white70)),
                      Flexible( // Um Überlauf zu verhindern
                        child: Text(
                          connectionStatus,
                          style: TextStyle(color: isConnected ? Colors.greenAccent : Colors.redAccent, fontWeight: FontWeight.bold),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  const Center(child: Text('E-Mail bei Problemen: jonte.puschmann.mail@gmail.com', style: TextStyle(color: Colors.white54, fontSize: 10))),
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('Schließen', style: TextStyle(color: Colors.white70)),
                      ),
                      const SizedBox(width: 16),
                      ElevatedButton.icon(
                        icon: const Icon(Icons.wifi_tethering),
                        label: const Text('Testen & Speichern', style: TextStyle(fontWeight: FontWeight.bold)),
                        onPressed: () {
                          final newAddress = serverController.text;
                          if (mounted) {
                            setState(() {
                              serverAddress = newAddress;
                            });
                          }
                          Navigator.of(context).pop();
                          _testConnection(isManualAttempt: true); // Wichtig: Als manuellen Versuch markieren
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: theme.colorScheme.primary,
                          foregroundColor: Colors.black,
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}