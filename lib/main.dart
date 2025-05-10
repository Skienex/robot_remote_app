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
  String serverAddress = 'http://192.168.1.100:8080'; // <-- Standard-IP, ggf. anpassen
  String connectionStatus = 'Nicht verbunden';
  bool isConnected = false;

  // Control parameters
  int speed = 0; // Speed wird NICHT mehr durch Kippen beeinflusst
  int direction = 0;
  bool headlightsOn = false;
  bool hornOn = false;
  bool turboMode = false;
  bool calibrationMode = false;

  // Tilt Control parameters
  bool _useTiltControl = false; // Switch for tilt control
  StreamSubscription? _accelerometerSubscription;
  Timer? _tiltUpdateTimer;
  final Duration _tiltUpdateInterval = const Duration(milliseconds: 100); // Send updates every 100ms

  // --- Sensitivity and Deadzone for Tilt ---
  // NEUER WERT: Niedriger = weniger empfindlich (mehr kippen nötig)
  final double _tiltSensitivitySteering = 8.0; // Vorher 15.0, jetzt WENIGER empfindlich
  // final double _tiltSensitivitySpeed = 18.0; // WIRD NICHT MEHR BENÖTIGT
  final double _tiltDeadzone = 0.5; // Ignoriert kleine Bewegungen um die Mitte

  // Animation controller for effects
  late AnimationController _animationController;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    // Startet nicht sofort, wartet auf Aktivierung
  }

  @override
  void dispose() {
    _animationController.dispose();
    _stopTiltControl(); // Stellt sicher, dass Sensoren und Timer gestoppt sind
    super.dispose();
  }

  // --- Tilt Control Logic ---

  void _startTiltControl() {
    if (_accelerometerSubscription != null) return; // Läuft bereits

    _accelerometerSubscription = accelerometerEvents.listen(_handleAccelerometerEvent);

    // Startet den Timer nur, wenn verbunden, sonst beim Verbindungsaufbau
    if (isConnected) {
      _startTiltUpdateTimer();
    }
  }

  void _stopTiltControl() {
    _accelerometerSubscription?.cancel();
    _accelerometerSubscription = null;
    _stopTiltUpdateTimer();
    // Optional: Richtung beim Stoppen der Kippsteuerung zurücksetzen
    // if (direction != 0) {
    //   setState(() { direction = 0; });
    //   _sendCommand('direction', 0);
    // }
    // Speed wird NICHT zurückgesetzt, da sie vom Slider kommt
  }

  void _handleAccelerometerEvent(AccelerometerEvent event) {
    if (!_useTiltControl || !mounted) return;

    // Orientierung für korrekte Achsenzuordnung bestimmen
    // final orientation = MediaQuery.of(context).orientation; // Wird nicht unbedingt benötigt
    double pitch = 0; // Vorwärts/Rückwärts-Neigung (nicht mehr für Speed verwendet)
    double roll = 0;  // Seitwärts-Neigung für Lenkung

    // Grundlegende Achsenzuordnung für Querformat
    // Annahme: Y ist Roll (Kippen über kurze Kante), X ist Pitch (Kippen über lange Kante)
    // Kann zwischen landscapeLeft und landscapeRight wechseln.
    // Bei Problemen evtl. gyroscope nutzen oder Orientierung prüfen.
    pitch = -event.x; // Wird aktuell nicht verwendet
    roll = event.y;   // Y-Achse für die Lenkung (Seitwärtskippen)

    // Deadzone anwenden
    // if (pitch.abs() < _tiltDeadzone) pitch = 0; // Nicht mehr nötig für Speed
    if (roll.abs() < _tiltDeadzone) roll = 0;

    // --- ÄNDERUNG: Speed wird NICHT mehr durch Pitch gesteuert ---
    // int newSpeed = (pitch * _tiltSensitivitySpeed).clamp(-100, 100).toInt();

    // Roll auf Richtung mappen (-100 bis 100) mit angepasster Sensitivität
    int newDirection = (roll * _tiltSensitivitySteering).clamp(-100, 100).toInt();

    // Zustand nur aktualisieren, wenn sich die Richtung geändert hat
    // --- ÄNDERUNG: Nur noch 'direction' prüfen ---
    if (newDirection != direction) {
      if (mounted) { // Prüfen, ob das Widget noch im Baum ist
        setState(() {
          // --- ÄNDERUNG: Nur 'direction' setzen ---
          direction = newDirection;
          // speed wird NICHT geändert
        });
      }
    }
  }


  void _startTiltUpdateTimer() {
    _tiltUpdateTimer?.cancel(); // Bestehenden Timer abbrechen
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
    // Diese Funktion wird periodisch vom Timer aufgerufen
    if (_useTiltControl && isConnected) {
      // --- ÄNDERUNG: Nur noch den 'direction'-Befehl senden ---
      // _sendCommand('speed', speed); // Speed wird nicht mehr vom Timer gesendet
      _sendCommand('direction', direction); // Nur die aktuelle Richtung senden
    } else {
      _stopTiltUpdateTimer(); // Stoppen, wenn Bedingungen nicht mehr erfüllt
    }
  }

  // --- End Tilt Control Logic ---


  Future<void> _sendCommand(String command, dynamic value) async {
    if (!isConnected) return;

    // Nur zum Debuggen, in Produktion entfernen
    // print('Sending: $command = $value');

    try {
      final response = await http.post(
        Uri.parse('$serverAddress/command'),
        headers: {
          'Content-Type': 'application/json',
          'User-Agent': 'Roboter App/1.0 (Von Jonte Puschmann)'
        },
        body: jsonEncode({
          'command': command,
          'value': value,
        }),
      ).timeout(const Duration(milliseconds: 500)); // Kürzerer Timeout für häufige Befehle

      if (response.statusCode == 200) {
        // Nicht für häufige Kippbefehle animieren, evtl. nur für Tastendrücke?
        // _animationController.forward(from: 0.0);
      } else {
        if (mounted){
          setState(() {
            connectionStatus = 'Fehler: ${response.statusCode}';
            // Verbindung trennen, wenn Befehle wiederholt fehlschlagen?
          });
        }
      }
    } catch (e) {
      if (mounted){
        setState(() {
          connectionStatus = 'Verbindungsfehler';
          isConnected = false;
          _stopTiltUpdateTimer(); // Timer bei Verbindungsverlust stoppen
        });
      }
    }
  }

  Future<void> _testConnection() async {
    if (mounted) {
      setState(() {
        connectionStatus = 'Verbindung wird getestet...';
        isConnected = false; // Annahme: getrennt während des Tests
        _stopTiltUpdateTimer(); // Timer während des Tests stoppen
      });
    }

    try {
      final response = await http.get(
        Uri.parse('$serverAddress/status'),
      ).timeout(const Duration(seconds: 3));

      if (mounted) { // Erneut prüfen, ob Widget nach await noch gemountet ist
        setState(() {
          if (response.statusCode == 200) {
            connectionStatus = 'Verbunden';
            isConnected = true;
            if (_useTiltControl) {
              _startTiltUpdateTimer(); // Timer starten, wenn Kippsteuerung aktiv ist
            }
          } else {
            connectionStatus = 'Fehler: ${response.statusCode}';
            isConnected = false;
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          connectionStatus = 'Keine Verbindung möglich';
          isConnected = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Haupt-Build-Methode bleibt weitgehend gleich
    return Scaffold(
      body: Container(
        // ... Rest der Dekoration ...
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
    // Header Build-Methode bleibt gleich
    final primary = Theme.of(context).colorScheme.primary;

    return Row(
      children: [
        // Logo area
        Container(
          width: 60,
          height: 60,
          margin: const EdgeInsets.only(right: 16),
          decoration: BoxDecoration(
            color: Colors.black26,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: primary.withOpacity(0.5),
              width: 2,
            ),
          ),
          child: Center(
            child: Icon(
              Icons.directions_car,
              color: primary,
              size: 32,
            ),
          ),
        ),
        // Title and status
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
                Text(
                  'RC CONTROLLER',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.5,
                    color: primary,
                  ),
                ),
                Row(
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isConnected ? Colors.greenAccent : Colors.redAccent,
                        boxShadow: [
                          BoxShadow(
                            color: isConnected
                                ? Colors.greenAccent.withOpacity(0.6)
                                : Colors.redAccent.withOpacity(0.6),
                            blurRadius: 6,
                            spreadRadius: 1,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      connectionStatus,
                      style: TextStyle(
                        color: isConnected ? Colors.greenAccent : Colors.redAccent,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 16),
        // Settings button
        IconButton(
          onPressed: () {
            showDialog(
              context: context,
              builder: (context) => _buildConnectionDialog(),
            ).then((_) {
              // Hier müssen wir nichts extra tun, da der Switch im Dialog
              // direkt den State (_useTiltControl) und die Listener aktualisiert.
            });
          },
          icon: Icon(
            Icons.settings,
            color: primary,
          ),
          style: IconButton.styleFrom(
            backgroundColor: Colors.black26,
            padding: const EdgeInsets.all(16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(
                color: primary.withOpacity(0.5),
                width: 1.5,
              ),
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
        border: Border.all(
          color: primary.withOpacity(0.3),
          width: 1.5,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Control panel header
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _useTiltControl ? 'STEUERUNG (KIPPEN/TOUCH)' : 'STEUERUNG (TOUCH)', // Angepasster Text
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 2,
                    color: primary,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black26,
                    borderRadius: BorderRadius.circular(30),
                    border: Border.all(
                      color: primary.withOpacity(0.3),
                      width: 1,
                    ),
                  ),
                  child: Row(
                    children: [
                      Text(
                        'Status: ',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.white.withOpacity(0.7),
                        ),
                      ),
                      Text(
                        // Status basiert jetzt auf Speed ODER Direction
                        speed != 0 || direction != 0 ? 'AKTIV' : 'BEREIT',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: speed != 0 || direction != 0 ? Colors.greenAccent : Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            // Control elements
            Expanded(
              child: Row(
                children: [
                  // Steering control
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(left: 12.0),
                          child: Text(
                            // Info, ob Kippen oder Touch aktiv ist
                            _useTiltControl ? 'LENKUNG (KIPPEN)' : 'LENKUNG (TOUCH)',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: Colors.white.withOpacity(0.7),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Expanded(
                          child: _buildSteeringWheel(), // Visuell gedimmt, wenn Kippen aktiv
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 24),
                  // Speed control
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(left: 12.0),
                          child: Text(
                            'GESCHWINDIGKEIT (TOUCH)', // Immer Touch
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: Colors.white.withOpacity(0.7),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Expanded(
                          child: _buildSpeedControl(), // Immer aktiv
                        ),
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
    // Visuelle Darstellung bleibt gleich, wird durch 'direction' gesteuert
    // Interaktion ist deaktiviert, wenn Kippsteuerung aktiv ist
    return GestureDetector(
      onPanUpdate: (details) {
        // --- ÄNDERUNG: Touch ignorieren, wenn Kippsteuerung aktiv ist ---
        if (_useTiltControl) return;
        double dx = details.delta.dx;
        if (dx != 0) {
          setState(() {
            direction = (direction + dx.toInt()*2).clamp(-100, 100); // Empfindlichkeit ggf. anpassen
          });
          _sendCommand('direction', direction);
        }
      },
      onPanEnd: (_) {
        // --- ÄNDERUNG: Touch ignorieren, wenn Kippsteuerung aktiv ist ---
        if (_useTiltControl) return;
        // Nur zur Mitte zurückkehren, wenn Touch losgelassen wird
        setState(() {
          direction = 0;
        });
        _sendCommand('direction', 0);
      },
      onTapDown: (_) {
        // --- ÄNDERUNG: Touch ignorieren, wenn Kippsteuerung aktiv ist ---
        if (!_useTiltControl) {
          setState(() { direction = 0; });
          _sendCommand('direction', 0);
        }
      },
      onTapUp: (_) {
        // --- ÄNDERUNG: Touch ignorieren, wenn Kippsteuerung aktiv ist ---
        if (!_useTiltControl) {
          setState(() { direction = 0; });
          _sendCommand('direction', 0);
        }
      },
      child: Opacity( // Visuell andeuten, dass es inaktiv ist bei Kippsteuerung
        opacity: _useTiltControl ? 0.5 : 1.0,
        child: Container(
          // ... Dekoration bleibt gleich ...
          decoration: BoxDecoration(
            color: Colors.black26, // Farbe nicht mehr basierend auf _useTiltControl ändern
            shape: BoxShape.circle,
            border: Border.all(
              color: primary.withOpacity(0.5),
              width: 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: primary.withOpacity(0.2),
                blurRadius: 10,
                spreadRadius: 1,
              ),
            ],
          ),
          child: Center(
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Lenkradbasis
                Container(
                  width: 140,
                  height: 140,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        primary.withOpacity(0.2),
                        Colors.transparent,
                      ],
                      stops: const [0.0, 0.7],
                    ),
                  ),
                ),
                // Drehender Teil - rotiert basierend auf 'direction'
                Transform.rotate(
                  angle: direction * 0.01 * math.pi / 2, // Mappt -100..100 auf -pi/2..pi/2
                  child: Container(
                    width: 120,
                    height: 120,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: primary.withOpacity(0.5),
                        width: 2,
                      ),
                    ),
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        // Speichen
                        Transform.rotate(
                          angle: math.pi / 4,
                          child: Container(
                            width: 100,
                            height: 8,
                            decoration: BoxDecoration(
                              color: primary.withOpacity(0.3),
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                        ),
                        Transform.rotate(
                          angle: -math.pi / 4,
                          child: Container(
                            width: 100,
                            height: 8,
                            decoration: BoxDecoration(
                              color: primary.withOpacity(0.3),
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                        ),
                        // Mitte
                        Container(
                          width: 30,
                          height: 30,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.black45,
                            border: Border.all(
                              color: primary.withOpacity(0.5),
                              width: 1.5,
                            ),
                          ),
                          child: Center(
                            child: Text(
                              '$direction', // Zeigt immer aktuelle Richtung
                              style: TextStyle(
                                color: primary,
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                              ),
                            ),
                          ),
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
    // Visuelle Darstellung bleibt gleich, wird durch 'speed' gesteuert
    // --- ÄNDERUNG: Immer aktiv, unabhängig von _useTiltControl ---
    return Container(
      decoration: BoxDecoration(
        color: Colors.black26, // Farbe nicht mehr basierend auf _useTiltControl ändern
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: theme.colorScheme.primary.withOpacity(0.5),
          width: 1.5,
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          return GestureDetector(
            onVerticalDragUpdate: (details) {
              // --- KEINE Prüfung mehr auf _useTiltControl ---
              double dy = details.delta.dy;
              if (dy != 0) {
                setState(() {
                  // Empfindlichkeit ggf. anpassen
                  speed = (speed - dy.toInt()).clamp(-100, 100);
                });
                _sendCommand('speed', speed);
              }
            },
            onVerticalDragEnd: (_) {
              // --- KEINE Prüfung mehr auf _useTiltControl ---
              // Zurück auf 0, wenn Touch losgelassen wird
              setState(() {
                speed = 0;
              });
              _sendCommand('speed', 0);
            },
            onTapDown: (_) {
              // --- KEINE Prüfung mehr auf _useTiltControl ---
              setState(() { speed = 0; });
              _sendCommand('speed', 0);
            },
            onTapUp: (_) {
              // --- KEINE Prüfung mehr auf _useTiltControl ---
              setState(() { speed = 0; });
              _sendCommand('speed', 0);
            },
            child: Stack(
              children: [
                // Geschwindigkeitsmesser-Hintergrund
                Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.greenAccent.withOpacity(0.3),
                        Colors.blueGrey.withOpacity(0.05),
                        Colors.redAccent.withOpacity(0.3),
                      ],
                      stops: const [0.0, 0.5, 1.0],
                    ),
                  ),
                ),
                // Geschwindigkeitsindikator-Linie - aktualisiert basierend auf 'speed'
                Positioned(
                  left: 0,
                  right: 0,
                  // Position basierend auf aktuellem Speed berechnen
                  top: constraints.maxHeight / 2 - (speed / 100 * constraints.maxHeight / 2),
                  child: Container(
                    height: 3,
                    decoration: BoxDecoration(
                      color: speed > 0
                          ? Colors.greenAccent
                          : (speed < 0 ? Colors.redAccent : theme.colorScheme.primary),
                      boxShadow: [
                        BoxShadow(
                          color: (speed > 0
                              ? Colors.greenAccent
                              : (speed < 0 ? Colors.redAccent : theme.colorScheme.primary)).withOpacity(0.6),
                          blurRadius: 6,
                          spreadRadius: 1,
                        ),
                      ],
                    ),
                  ),
                ),
                // Geschwindigkeitswert und Label - aktualisiert basierend auf 'speed'
                Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        speed.abs().toString(), // Zeigt immer den Absolutwert der Geschwindigkeit
                        style: TextStyle(
                          fontSize: 32,
                          fontWeight: FontWeight.bold,
                          color: speed > 0
                              ? Colors.greenAccent
                              : (speed < 0 ? Colors.redAccent : Colors.white),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        decoration: BoxDecoration(
                          color: speed != 0 ? Colors.black38 : Colors.transparent,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          speed > 0
                              ? 'VORWÄRTS'
                              : (speed < 0 ? 'RÜCKWÄRTS' : 'NEUTRAL'), // Zeigt NEUTRAL bei 0
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: speed > 0
                                ? Colors.greenAccent
                                : (speed < 0 ? Colors.redAccent : Colors.white70),
                          ),
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
    );
  }


  Widget _buildExtraControls() {
    // Extra-Steuerelemente bleiben unverändert, immer nutzbar
    final primary = Theme.of(context).colorScheme.primary;
    final secondary = Theme.of(context).colorScheme.secondary;

    return Container(
      decoration: BoxDecoration(
        color: Colors.black12,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: primary.withOpacity(0.3),
          width: 1.5,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'ZUSATZFUNKTIONEN',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                letterSpacing: 2,
                color: primary,
              ),
            ),
            const SizedBox(height: 20),
            // Features grid
            Expanded(
              child: GridView.count(
                crossAxisCount: 2,
                mainAxisSpacing: 16,
                crossAxisSpacing: 16,
                children: [
                  _buildFeatureButton(
                    icon: Icons.lightbulb_outline,
                    label: 'LICHT',
                    isActive: headlightsOn,
                    color: secondary,
                    onPressed: () {
                      setState(() {
                        headlightsOn = !headlightsOn;
                      });
                      _sendCommand('headlights', headlightsOn);
                    },
                  ),
                  _buildFeatureButton(
                    icon: Icons.volume_up,
                    label: 'HUPE',
                    isActive: hornOn,
                    color: secondary,
                    onPressed: () {
                      if (hornOn) return; // Verhindert Dauerhupe
                      setState(() { hornOn = true; });
                      _sendCommand('horn', true);
                      Future.delayed(const Duration(milliseconds: 500), () {
                        if (mounted) {
                          setState(() { hornOn = false; });
                          _sendCommand('horn', false);
                        }
                      });
                    },
                  ),
                  _buildFeatureButton(
                    icon: Icons.speed,
                    label: 'TURBO',
                    isActive: turboMode,
                    color: secondary,
                    onPressed: () {
                      if (turboMode) return; // Verhindert erneutes Auslösen
                      setState(() { turboMode = true; });
                      _sendCommand('turbo', true);
                      Future.delayed(const Duration(seconds: 2), () {
                        if (mounted) {
                          setState(() { turboMode = false; });
                          _sendCommand('turbo', false);
                        }
                      });
                    },
                  ),
                  _buildFeatureButton(
                    icon: Icons.settings_backup_restore,
                    label: 'KALIBRIEREN',
                    isActive: calibrationMode,
                    color: secondary,
                    onPressed: () {
                      if (calibrationMode) return; // Verhindert erneutes Auslösen
                      setState(() { calibrationMode = true; });
                      _sendCommand('calibrate', true);
                      Future.delayed(const Duration(seconds: 1), () { // Kürzere Verzögerung?
                        if (mounted) {
                          setState(() { calibrationMode = false; });
                          // 'calibrate false' muss normalerweise nicht gesendet werden
                        }
                      });
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            // Batteriestatus (Beispiel)
            Container(
              // ... Batterie-Status-Dekoration ...
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.black26,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: primary.withOpacity(0.3),
                  width: 1,
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.battery_charging_full,
                        color: primary,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'BATTERIE',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: Colors.white.withOpacity(0.7),
                        ),
                      ),
                    ],
                  ),
                  // Beispiel statische Batterieanzeige
                  Row(
                    children: [
                      Container(
                        width: 100, height: 6,
                        decoration: BoxDecoration( color: Colors.black45, borderRadius: BorderRadius.circular(3),),
                        child: Row( children: [
                          Container( width: 75, decoration: BoxDecoration( color: Colors.greenAccent, borderRadius: BorderRadius.circular(3), boxShadow: [ BoxShadow( color: Colors.greenAccent.withOpacity(0.6), blurRadius: 4, spreadRadius: 0,) ],),),
                        ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Text('75%', style: TextStyle( fontSize: 12, fontWeight: FontWeight.bold, color: Colors.greenAccent,),),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFeatureButton({
    required IconData icon,
    required String label,
    required bool isActive,
    required Color color,
    required VoidCallback onPressed,
  }) {
    // Feature-Button bleibt gleich
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        decoration: BoxDecoration(
          color: isActive ? color.withOpacity(0.15) : Colors.black26,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: isActive ? color : color.withOpacity(0.3),
            width: 1.5,
          ),
          boxShadow: isActive
              ? [ BoxShadow( color: color.withOpacity(0.3), blurRadius: 8, spreadRadius: 0, ),] : null,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon( icon, color: isActive ? color : Colors.white70, size: 28,),
            const SizedBox(height: 8),
            Text( label, style: TextStyle( fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1, color: isActive ? color : Colors.white70,),),
          ],
        ),
      ),
    );
  }

  Widget _buildConnectionDialog() {
    final TextEditingController serverController = TextEditingController(text: serverAddress);
    final theme = Theme.of(context);

    // StatefulBuilder verwenden, um den Zustand des Switches im Dialog zu verwalten
    return StatefulBuilder(
      builder: (context, setDialogState) {
        return Dialog(
          backgroundColor: const Color(0xFF16213E),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: SingleChildScrollView( // Hinzugefügt für kleinere Bildschirme
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.wifi, color: theme.colorScheme.primary),
                      const SizedBox(width: 12),
                      Text(
                        'Verbindung & Steuerung', // Aktualisierter Titel
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    controller: serverController,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: 'Server-Adresse',
                      labelStyle: const TextStyle(color: Colors.white70),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: theme.colorScheme.primary.withOpacity(0.5)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: theme.colorScheme.primary),
                      ),
                      prefixIcon: Icon(Icons.link, color: theme.colorScheme.primary),
                    ),
                  ),
                  const SizedBox(height: 16), // Reduzierter Abstand
                  // --- Tilt Control Switch ---
                  SwitchListTile(
                    title: const Text('Kipp-Steuerung aktivieren', style: TextStyle(color: Colors.white)),
                    subtitle: Text(
                      'Nur Lenkung über Handybewegung', // Angepasster Text
                      style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 12),
                    ),
                    value: _useTiltControl, // Haupt-Zustandsvariable verwenden
                    onChanged: (bool value) {
                      // --- WICHTIG: Hauptbildschirm-Zustand direkt aktualisieren ---
                      // Dies stellt sicher, dass die Änderung sofort wirksam wird
                      // und die Listener gestartet/gestoppt werden.
                      setState(() { // Zustand von ControllerScreen aktualisieren
                        _useTiltControl = value;
                        if (_useTiltControl) {
                          _startTiltControl(); // Sofort starten
                          // Richtung auf 0 setzen, wenn Kippsteuerung aktiviert wird? Optional.
                          // direction = 0;
                          // _sendCommand('direction', 0);
                        } else {
                          _stopTiltControl(); // Sofort stoppen
                          // Richtung auf 0 setzen, wenn Kippsteuerung deaktiviert wird? Optional.
                          // direction = 0;
                          // _sendCommand('direction', 0);
                        }
                      });
                      // Den Dialog-Zustand auch aktualisieren, damit der Switch visuell umschaltet
                      setDialogState(() {});
                    },
                    activeColor: theme.colorScheme.primary,
                    secondary: Icon(Icons.screen_rotation_alt, color: theme.colorScheme.primary),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 0), // Padding anpassen
                  ),
                  // --- End Tilt Control Switch ---
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      const Text('Status: ', style: TextStyle(color: Colors.white70)),
                      Text(
                        connectionStatus,
                        style: TextStyle(
                          color: isConnected ? Colors.greenAccent : Colors.redAccent,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16), // Etwas Abstand
                  const Center(
                    child: Text(
                      'E-Mail bei Problemen: jonte.puschmann01@gmail.com',
                      style: TextStyle(
                        color: Colors.white54,
                        fontSize: 10,
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () {
                          Navigator.of(context).pop();
                          // Falls Änderungen nur temporär waren, hier ggf. zurücksetzen
                        },
                        child: const Text('Schließen', style: TextStyle(color: Colors.white70)),
                      ),
                      const SizedBox(width: 16),
                      ElevatedButton.icon( // Geändert zu Icon-Button
                        icon: const Icon(Icons.wifi_tethering),
                        label: const Text( 'Testen & Speichern', style: TextStyle(fontWeight: FontWeight.bold),),
                        onPressed: () {
                          // Serveradresse aus Textfeld aktualisieren
                          final newAddress = serverController.text;
                          bool addressChanged = newAddress != serverAddress;
                          setState(() {
                            serverAddress = newAddress;
                            // _useTiltControl wurde bereits durch onChanged des Switches aktualisiert
                          });

                          Navigator.of(context).pop(); // Dialog zuerst schließen

                          // Verbindung nur testen, wenn Adresse geändert wurde oder nicht verbunden
                          if (addressChanged || !isConnected) {
                            _testConnection();
                          } else {
                            // Wenn bereits verbunden und Adresse nicht geändert,
                            // sicherstellen, dass der Kipp-Timer korrekt gestartet/gestoppt ist
                            if(_useTiltControl && isConnected && _tiltUpdateTimer == null) {
                              _startTiltUpdateTimer();
                            } else if (!_useTiltControl) {
                              _stopTiltUpdateTimer(); // Sicherstellen, dass er aus ist
                            }
                          }

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