import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_nsfw_scaner/flutter_nsfw_scaner.dart';

void main() {
  runApp(const NsfwWizardApp());
}

class NsfwWizardApp extends StatelessWidget {
  const NsfwWizardApp({super.key});

  @override
  Widget build(BuildContext context) {
    final base = ThemeData(
      colorSchemeSeed: const Color(0xFF0A7A8C),
      brightness: Brightness.light,
      useMaterial3: true,
    );

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'NSFW Scan Wizard',
      theme: base.copyWith(
        scaffoldBackgroundColor: const Color(0xFFF3F7F8),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF0A7A8C),
          foregroundColor: Colors.white,
          centerTitle: false,
        ),
      ),
      home: const ExampleStartPage(),
    );
  }
}

class ExampleStartPage extends StatelessWidget {
  const ExampleStartPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('NSFW Scanner Example Hub')),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFFF3F7F8), Color(0xFFE7F0F2)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _EntryCard(
                title: '1) Aktueller Wizard (bestehend)',
                subtitle:
                    'Dein bisheriger produktiver Scan-Wizard bleibt 1:1 erhalten.',
                icon: Icons.auto_awesome_motion,
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const ScanWizardPage(),
                    ),
                  );
                },
              ),
              const SizedBox(height: 12),
              _EntryCard(
                title: '2) UI Kit Best Practice (2 Screens)',
                subtitle:
                    'Fertiger Referenzfluss: Demo-Scan-Screen und Ergebnis-Screen mit den Plugin-Widgets.',
                icon: Icons.fact_check_outlined,
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const UiKitReferencePage(),
                    ),
                  );
                },
              ),
              const SizedBox(height: 12),
              _EntryCard(
                title: '3) UI Kit Playground (Try Mode)',
                subtitle:
                    'Widget-Vorstellung mit Controls/Slider/Switches zum direkten Testen.',
                icon: Icons.tune,
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const UiKitShowcasePage(),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EntryCard extends StatelessWidget {
  const _EntryCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                backgroundColor: const Color(0xFFE3EFF2),
                child: Icon(icon, color: const Color(0xFF0A7A8C)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: const TextStyle(color: Colors.black87),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}

class UiKitReferencePage extends StatefulWidget {
  const UiKitReferencePage({super.key});

  @override
  State<UiKitReferencePage> createState() => _UiKitReferencePageState();
}

class _UiKitReferencePageState extends State<UiKitReferencePage> {
  static const int _pageSize = 12;

  int _screenIndex = 0;
  bool _running = false;
  bool _completed = false;
  int _processed = 0;
  final int _total = 180;
  int _pageIndex = 0;
  Timer? _demoTimer;
  final List<_ReferenceResultItem> _items = <_ReferenceResultItem>[];

  int get _pageCount => math.max(1, (_items.length / _pageSize).ceil());

  List<_ReferenceResultItem> get _currentPageItems {
    if (_items.isEmpty) {
      return const [];
    }
    final safePage = _pageIndex.clamp(0, _pageCount - 1).toInt();
    final start = safePage * _pageSize;
    final end = math.min(start + _pageSize, _items.length);
    return _items.sublist(start, end);
  }

  @override
  void dispose() {
    _demoTimer?.cancel();
    super.dispose();
  }

  void _startDemoScan() {
    _demoTimer?.cancel();
    setState(() {
      _running = true;
      _completed = false;
      _processed = 0;
      _items.clear();
      _pageIndex = 0;
    });

    _demoTimer = Timer.periodic(const Duration(milliseconds: 90), (timer) {
      if (!mounted) {
        return;
      }
      if (_processed >= _total) {
        timer.cancel();
        setState(() {
          _running = false;
          _completed = true;
          _screenIndex = 1;
        });
        return;
      }

      final nextProcessed = math.min(_total, _processed + 6);
      final newItems = <_ReferenceResultItem>[];
      for (var i = _processed; i < nextProcessed; i += 1) {
        final hasError = i % 29 == 0;
        final isNsfw = !hasError && i % 4 == 0;
        final score = ((i % 100) / 100).clamp(0.0, 0.99);
        newItems.add(
          _ReferenceResultItem(
            path: 'ph://demo-${i + 1}',
            type: i % 5 == 0 ? NsfwMediaType.video : NsfwMediaType.image,
            isNsfw: isNsfw,
            score: score.toDouble(),
            error: hasError ? 'Demo Fehler bei Asset ${i + 1}' : null,
          ),
        );
      }

      setState(() {
        _processed = nextProcessed;
        _items.addAll(newItems.where((item) => item.isNsfw || item.hasError));
        _pageIndex = _pageIndex.clamp(0, _pageCount - 1).toInt();
      });
    });
  }

  void _resetDemo() {
    _demoTimer?.cancel();
    setState(() {
      _screenIndex = 0;
      _running = false;
      _completed = false;
      _processed = 0;
      _items.clear();
      _pageIndex = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final phase = _running
        ? 'Demo-Scan lauft'
        : (_completed ? 'Demo-Scan abgeschlossen' : 'Bereit zum Start');

    return Scaffold(
      appBar: AppBar(
        title: const Text('UI Kit Best Practice'),
        actions: [
          if (_running)
            IconButton(
              tooltip: 'Demo stoppen',
              onPressed: () {
                _demoTimer?.cancel();
                setState(() {
                  _running = false;
                });
              },
              icon: const Icon(Icons.stop_circle_outlined),
            ),
        ],
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFFF3F7F8), Color(0xFFE7F0F2)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              NsfwScanWizardStepHeader(
                stepLabels: const ['1. Demo Scan', '2. Demo Ergebnisse'],
                currentStep: _screenIndex,
                isStepDone: (index) => index < _screenIndex,
              ),
              const Divider(height: 1),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                  child: _screenIndex == 0
                      ? _buildReferenceScanScreen(phase)
                      : _buildReferenceResultScreen(),
                ),
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: _screenIndex == 0
          ? NsfwBottomActionBar(
              showWizardControls: true,
              onBack: null,
              onForward: _completed
                  ? () => setState(() => _screenIndex = 1)
                  : _startDemoScan,
              onRestart: _resetDemo,
              backEnabled: false,
              forwardEnabled: !_running,
              forwardLabel: _completed
                  ? 'Ergebnisse anzeigen'
                  : 'Demo-Scan starten',
            )
          : NsfwBottomActionBar(
              showWizardControls: false,
              onBack: null,
              onForward: null,
              onRestart: _resetDemo,
              restartEnabled: !_running,
            ),
    );
  }

  Widget _buildReferenceScanScreen(String phase) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          NsfwBatchProgressCard(
            processed: _processed,
            total: _total,
            phase: phase,
            running: _running,
            completed: _completed,
            resultCount: _items.length,
            statusText: 'Dieses Screen zeigt die empfohlene Progress-UI.',
          ),
          const SizedBox(height: 8),
          NsfwGalleryLoadCard(
            progress: NsfwGalleryLoadProgress(
              page: (_processed / 60).floor(),
              scannedAssets: _processed,
              imageCount: (_processed * 0.75).round(),
              videoCount: (_processed * 0.25).round(),
              targetCount: _total,
              isCompleted: _completed,
            ),
          ),
          const SizedBox(height: 8),
          const Card(
            child: Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'Best Practice: Progress entkoppelt rendern, Ergebnisse paginieren und erst im Ergebnis-Screen detailliert darstellen.',
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReferenceResultScreen() {
    final currentItems = _currentPageItems;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        NsfwBatchProgressCard(
          processed: _processed,
          total: _total,
          phase: 'Ergebnis-Screen',
          running: false,
          completed: true,
          resultCount: _items.length,
          statusText: 'Gefilterte Items (NSFW oder Fehler) aus dem Stream.',
        ),
        const SizedBox(height: 8),
        NsfwPaginationControls(
          pageIndex: _pageIndex,
          pageCount: _pageCount,
          onPrevious: _pageIndex > 0
              ? () => setState(() => _pageIndex -= 1)
              : null,
          onNext: _pageIndex < _pageCount - 1
              ? () => setState(() => _pageIndex += 1)
              : null,
        ),
        const SizedBox(height: 8),
        Expanded(
          child: currentItems.isEmpty
              ? const Center(child: Text('Noch keine Ergebnisse vorhanden.'))
              : ListView.separated(
                  itemCount: currentItems.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final item = currentItems[index];
                    return NsfwResultTile(
                      path: item.path,
                      type: item.type,
                      score: item.score,
                      isNsfw: item.isNsfw,
                      error: item.error,
                      leading: CircleAvatar(
                        backgroundColor: const Color(0xFFE5EEF0),
                        child: Icon(
                          item.type == NsfwMediaType.video
                              ? Icons.movie
                              : Icons.image,
                          color: const Color(0xFF0A7A8C),
                        ),
                      ),
                      onTap: () => _openReferenceDetail(item),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Future<void> _openReferenceDetail(_ReferenceResultItem item) {
    return showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Demo Detailansicht'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(item.path),
              const SizedBox(height: 8),
              Text('Score: ${item.score.toStringAsFixed(3)}'),
              const SizedBox(height: 8),
              NsfwResultStatusChip(
                isNsfw: item.isNsfw,
                hasError: item.hasError,
              ),
              if (item.hasError) ...[
                const SizedBox(height: 8),
                Text(item.error!),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Schließen'),
            ),
          ],
        );
      },
    );
  }
}

class _ReferenceResultItem {
  const _ReferenceResultItem({
    required this.path,
    required this.type,
    required this.isNsfw,
    required this.score,
    this.error,
  });

  final String path;
  final NsfwMediaType type;
  final bool isNsfw;
  final double score;
  final String? error;

  bool get hasError => error != null;
}

class UiKitShowcasePage extends StatefulWidget {
  const UiKitShowcasePage({super.key});

  @override
  State<UiKitShowcasePage> createState() => _UiKitShowcasePageState();
}

class _UiKitShowcasePageState extends State<UiKitShowcasePage> {
  int _currentStep = 1;
  bool _showWizardControls = true;
  bool _running = true;
  bool _completed = false;
  bool _isNsfw = true;
  bool _hasError = false;
  int _processed = 36;
  final int _total = 120;
  int _pageIndex = 0;
  final int _pageCount = 6;
  double _score = 0.73;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('UI Kit Playground (Try)')),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFFF3F7F8), Color(0xFFE7F0F2)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Flow Widgets',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      NsfwScanWizardStepHeader(
                        stepLabels: const [
                          '1. Modus',
                          '2. Vorbereitung',
                          '3. Review',
                          '4. Results',
                        ],
                        currentStep: _currentStep,
                      ),
                      const SizedBox(height: 12),
                      SwitchListTile.adaptive(
                        value: _showWizardControls,
                        onChanged: (value) {
                          setState(() {
                            _showWizardControls = value;
                          });
                        },
                        title: const Text('Bottom bar im Wizard-Modus'),
                      ),
                      NsfwBottomActionBar(
                        showWizardControls: _showWizardControls,
                        onBack: () {},
                        onForward: () {},
                        onRestart: () {},
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Progress Widgets',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Text('Processed: $_processed / $_total'),
                      Slider(
                        value: _processed.toDouble(),
                        min: 0,
                        max: _total.toDouble(),
                        onChanged: (value) {
                          setState(() {
                            _processed = value.round();
                          });
                        },
                      ),
                      SwitchListTile.adaptive(
                        value: _running,
                        onChanged: (value) {
                          setState(() {
                            _running = value;
                            if (value) {
                              _completed = false;
                            }
                          });
                        },
                        title: const Text('Running'),
                      ),
                      SwitchListTile.adaptive(
                        value: _completed,
                        onChanged: (value) {
                          setState(() {
                            _completed = value;
                            if (value) {
                              _running = false;
                            }
                          });
                        },
                        title: const Text('Completed'),
                      ),
                      NsfwBatchProgressCard(
                        processed: _processed,
                        total: _total,
                        phase: 'Playground Phase',
                        running: _running,
                        completed: _completed,
                        resultCount: 42,
                        statusText: 'Try: Slider + Switches',
                      ),
                      const SizedBox(height: 8),
                      NsfwGalleryLoadCard(
                        progress: NsfwGalleryLoadProgress(
                          page: 2,
                          scannedAssets: _processed,
                          imageCount: (_processed * 0.7).round(),
                          videoCount: (_processed * 0.3).round(),
                          targetCount: _total,
                          isCompleted: _completed,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Result Widgets',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      SwitchListTile.adaptive(
                        value: _isNsfw,
                        onChanged: (value) {
                          setState(() {
                            _isNsfw = value;
                          });
                        },
                        title: const Text('NSFW Status'),
                      ),
                      SwitchListTile.adaptive(
                        value: _hasError,
                        onChanged: (value) {
                          setState(() {
                            _hasError = value;
                          });
                        },
                        title: const Text('Fehler simulieren'),
                      ),
                      Text('Score: ${_score.toStringAsFixed(2)}'),
                      Slider(
                        value: _score,
                        min: 0,
                        max: 1,
                        onChanged: (value) {
                          setState(() {
                            _score = value;
                          });
                        },
                      ),
                      NsfwResultStatusChip(
                        isNsfw: _isNsfw,
                        hasError: _hasError,
                      ),
                      const SizedBox(height: 8),
                      NsfwResultTile(
                        path: 'ph://playground-asset',
                        type: NsfwMediaType.image,
                        score: _score,
                        isNsfw: _isNsfw,
                        error: _hasError ? 'Beispiel Fehlertext' : null,
                        leading: const CircleAvatar(child: Icon(Icons.image)),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Pagination Widget',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      NsfwPaginationControls(
                        pageIndex: _pageIndex,
                        pageCount: _pageCount,
                        onPrevious: _pageIndex > 0
                            ? () => setState(() => _pageIndex -= 1)
                            : null,
                        onNext: _pageIndex < _pageCount - 1
                            ? () => setState(() => _pageIndex += 1)
                            : null,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton(
            onPressed: () {
              setState(() {
                _currentStep = (_currentStep + 1) % 4;
                _pageIndex = (_pageIndex + 1) % _pageCount;
              });
            },
            child: const Text('Try: Werte weiterdrehen'),
          ),
        ),
      ),
    );
  }
}

enum ScanMode { single, selectionBatch, wholeGallery }

class _LiveResultRow {
  const _LiveResultRow({
    required this.path,
    required this.assetRef,
    required this.type,
    required this.isNsfw,
    required this.score,
    this.error,
  });

  final String path;
  final String assetRef;
  final NsfwMediaType type;
  final bool isNsfw;
  final double score;
  final String? error;

  bool get hasError => error != null;
}

class ScanWizardPage extends StatefulWidget {
  const ScanWizardPage({super.key});

  @override
  State<ScanWizardPage> createState() => _ScanWizardPageState();
}

class _ScanWizardPageState extends State<ScanWizardPage> {
  static const Duration _uiPollingInterval = Duration(milliseconds: 250);
  static const int _pageSize = 16;
  static const List<String> _stepLabels = <String>[
    '1. Modus',
    '2. Vorbereitung',
    '3. Prüfen',
    '4. Ergebnisse',
  ];

  final FlutterNsfwScaner _plugin = FlutterNsfwScaner();

  final TextEditingController _singlePathController = TextEditingController();
  final TextEditingController _galleryMaxItemsController =
      TextEditingController(text: '2000');

  ScanMode? _mode;
  int _stepIndex = 0;

  bool _initializing = false;
  bool _initialized = false;
  bool _running = false;

  double _imageThreshold = 0.45;
  double _videoThreshold = 0.45;
  int _maxConcurrency = 2;

  bool _galleryIncludeImages = true;
  bool _galleryIncludeVideos = true;
  bool _galleryDebugLogging = true;

  List<String> _selectedImagePaths = const [];
  List<String> _selectedVideoPaths = const [];

  final List<_LiveResultRow> _liveRows = <_LiveResultRow>[];
  final List<_LiveResultRow> _pendingRows = <_LiveResultRow>[];
  final Map<String, String?> _thumbnailPathByRef = <String, String?>{};
  final Set<String> _thumbnailLoadingRefs = <String>{};
  final Map<String, String> _fullImagePathByRef = <String, String>{};

  int _pageIndex = 0;
  int _processed = 0;
  int _total = 0;
  String _phase = 'Idle';
  String _status = 'Wähle einen Scan-Modus';
  bool _scanDone = false;

  bool _uiDirty = false;
  Timer? _uiTimer;

  @override
  void initState() {
    super.initState();
    unawaited(_initializeScanner());
  }

  @override
  void dispose() {
    _uiTimer?.cancel();
    _singlePathController.dispose();
    _galleryMaxItemsController.dispose();
    unawaited(_plugin.dispose());
    super.dispose();
  }

  Future<void> _initializeScanner() async {
    setState(() {
      _initializing = true;
      _status = 'Scanner wird initialisiert...';
    });

    try {
      await _plugin.initialize(
        modelAssetPath: NsfwBuiltinModels.nsfwMobilenetV2140224,
        labelsAssetPath: NsfwBuiltinModels.nsfwMobilenetV2140224Labels,
        numThreads: 2,
        inputNormalization: NsfwInputNormalization.minusOneToOne,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _initialized = true;
        _status = 'Scanner bereit';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = 'Initialisierung fehlgeschlagen: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _initializing = false;
        });
      }
    }
  }

  Future<void> _pickSingleMedia() async {
    final picked = await _plugin.pickMedia(
      mode: NsfwPickerMode.single,
      allowImages: true,
      allowVideos: false,
    );
    if (picked == null) {
      setState(() {
        _singlePathController.clear();
        _status = 'Auswahl abgebrochen oder keine Datei ausgewählt.';
      });
      return;
    }
    final resolvedPath = picked.imagePaths.isNotEmpty
        ? picked.imagePaths.first
        : picked.videoPaths.first;
    setState(() {
      _singlePathController.text = resolvedPath;
      _status = 'Datei ausgewählt';
    });
  }

  Future<void> _pickBatchMedia() async {
    final picked = await _plugin.pickMedia(
      mode: NsfwPickerMode.multiple,
      allowImages: true,
      allowVideos: false,
    );
    if (picked == null) {
      setState(() {
        _selectedImagePaths = const [];
        _selectedVideoPaths = const [];
        _status = 'Auswahl abgebrochen oder keine Medien ausgewählt.';
      });
      return;
    }
    setState(() {
      _selectedImagePaths = picked.imagePaths;
      _selectedVideoPaths = picked.videoPaths;
      _status =
          'Auswahl: ${picked.imagePaths.length} Bilder, ${picked.videoPaths.length} Videos';
    });
  }

  NsfwMediaBatchSettings get _scanSettings {
    return NsfwMediaBatchSettings(
      imageThreshold: _imageThreshold,
      videoThreshold: _videoThreshold,
      maxConcurrency: _maxConcurrency,
      continueOnError: true,
    );
  }

  bool _isStepReady(int stepIndex) {
    switch (stepIndex) {
      case 0:
        return _mode != null;
      case 1:
        final mode = _mode;
        if (mode == null) {
          return false;
        }
        if (mode == ScanMode.single) {
          return _singlePathController.text.trim().isNotEmpty;
        }
        if (mode == ScanMode.selectionBatch) {
          return _selectedImagePaths.isNotEmpty ||
              _selectedVideoPaths.isNotEmpty;
        }
        if (mode == ScanMode.wholeGallery) {
          return _galleryIncludeImages || _galleryIncludeVideos;
        }
        return false;
      case 2:
        return true;
      default:
        return false;
    }
  }

  void _nextStep() {
    if (_running) {
      return;
    }
    if (_stepIndex < 2) {
      if (!_isStepReady(_stepIndex)) {
        setState(() {
          _status = 'Bitte den aktuellen Schritt zuerst abschließen.';
        });
        return;
      }
      setState(() {
        _stepIndex += 1;
      });
      return;
    }

    if (_stepIndex == 2) {
      unawaited(_runScan());
    }
  }

  void _previousStep() {
    if (_running) {
      return;
    }
    if (_stepIndex == 0) {
      return;
    }
    setState(() {
      _stepIndex -= 1;
    });
  }

  Future<void> _cancelCurrentScan() async {
    await _plugin.cancelScan();
    if (!mounted) {
      return;
    }
    setState(() {
      _status = 'Abbruch angefordert';
    });
  }

  void _restartFromBeginning() {
    if (_running) {
      return;
    }
    _stopUiPolling(flush: false);
    setState(() {
      _stepIndex = 0;
      _mode = null;
      _scanDone = false;
      _phase = 'Idle';
      _status = 'Wähle einen Scan-Modus';
      _processed = 0;
      _total = 0;
      _liveRows.clear();
      _pendingRows.clear();
      _thumbnailPathByRef.clear();
      _thumbnailLoadingRefs.clear();
      _fullImagePathByRef.clear();
      _pageIndex = 0;
      _uiDirty = false;
      _singlePathController.clear();
      _selectedImagePaths = const [];
      _selectedVideoPaths = const [];
    });
  }

  void _startUiPolling() {
    _uiTimer?.cancel();
    _uiTimer = Timer.periodic(_uiPollingInterval, (_) {
      if (!mounted) {
        return;
      }
      if (_pendingRows.isEmpty && !_uiDirty) {
        return;
      }

      final appended = List<_LiveResultRow>.from(_pendingRows);
      _pendingRows.clear();

      setState(() {
        if (appended.isNotEmpty) {
          _liveRows.addAll(appended);
          _pageIndex = _pageIndex.clamp(0, _pageCount - 1).toInt();
        }
        _uiDirty = false;
      });
    });
  }

  void _stopUiPolling({bool flush = true}) {
    _uiTimer?.cancel();
    _uiTimer = null;
    if (!flush || !mounted) {
      return;
    }

    if (_pendingRows.isEmpty && !_uiDirty) {
      return;
    }

    setState(() {
      if (_pendingRows.isNotEmpty) {
        _liveRows.addAll(_pendingRows);
        _pendingRows.clear();
        _pageIndex = _pageIndex.clamp(0, _pageCount - 1).toInt();
      }
      _uiDirty = false;
    });
  }

  void _recordProgress({
    required int processed,
    required int total,
    required String phase,
  }) {
    _processed = processed;
    _total = total;
    _phase = phase;
    _uiDirty = true;
  }

  void _enqueueRows(List<_LiveResultRow> rows) {
    if (rows.isEmpty) {
      return;
    }
    _pendingRows.addAll(rows);
    _uiDirty = true;
  }

  Future<void> _runScan() async {
    if (!_initialized || _mode == null) {
      return;
    }

    setState(() {
      _stepIndex = 3;
      _running = true;
      _scanDone = false;
      _phase = 'Scan startet...';
      _status = 'Scan läuft';
      _processed = 0;
      _total = 0;
      _liveRows.clear();
      _pendingRows.clear();
      _thumbnailPathByRef.clear();
      _thumbnailLoadingRefs.clear();
      _fullImagePathByRef.clear();
      _pageIndex = 0;
    });

    _startUiPolling();

    try {
      switch (_mode!) {
        case ScanMode.single:
          await _runSingleFlow();
          break;
        case ScanMode.selectionBatch:
          await _runSelectionBatchFlow();
          break;
        case ScanMode.wholeGallery:
          await _runWholeGalleryFlow();
          break;
      }
      _status = 'Scan abgeschlossen';
    } catch (error) {
      _status = 'Scan fehlgeschlagen: $error';
    } finally {
      _running = false;
      _scanDone = true;
      _uiDirty = true;
      _stopUiPolling(flush: true);
      if (mounted) {
        setState(() {});
      }
    }
  }

  Future<void> _runSingleFlow() async {
    final path = _singlePathController.text.trim();
    final isVideo = _looksLikeVideo(path);

    _recordProgress(processed: 0, total: 1, phase: 'Einzeldatei wird gescannt');

    if (isVideo) {
      final result = await _plugin.scanVideo(
        videoPath: path,
        threshold: _videoThreshold,
        onProgress: (progress) {
          _recordProgress(
            processed: progress.processed,
            total: progress.total,
            phase: 'Video-Frames werden analysiert',
          );
        },
      );

      _enqueueRows([
        _LiveResultRow(
          path: result.videoPath,
          assetRef: result.videoPath,
          type: NsfwMediaType.video,
          isNsfw: result.isNsfw,
          score: result.maxNsfwScore,
        ),
      ]);
    } else {
      final result = await _plugin.scanImage(
        imagePath: path,
        threshold: _imageThreshold,
      );
      _recordProgress(processed: 1, total: 1, phase: 'Einzelbild analysiert');
      _enqueueRows([
        _LiveResultRow(
          path: result.imagePath,
          assetRef: result.imagePath,
          type: NsfwMediaType.image,
          isNsfw: result.isNsfw,
          score: result.nsfwScore,
        ),
      ]);
    }
  }

  Future<void> _runSelectionBatchFlow() async {
    final media = <NsfwMediaInput>[
      ..._selectedImagePaths.map(NsfwMediaInput.image),
      ..._selectedVideoPaths.map(NsfwMediaInput.video),
    ];
    if (media.isEmpty) {
      throw const FormatException('Keine Medien für Batch-Scan ausgewählt.');
    }

    final total = media.length;
    const chunkSize = 80;
    var processedBase = 0;

    for (var start = 0; start < total; start += chunkSize) {
      final end = math.min(start + chunkSize, total);
      final chunk = media.sublist(start, end);

      final chunkResult = await _plugin.scanMediaBatch(
        media: chunk,
        settings: _scanSettings,
        onProgress: (progress) {
          _recordProgress(
            processed: processedBase + progress.processed,
            total: total,
            phase:
                'Batch-Scan läuft (${processedBase + progress.processed}/$total)',
          );
        },
      );

      processedBase += chunkResult.processed;
      _recordProgress(
        processed: processedBase,
        total: total,
        phase: 'Batch-Chunk abgeschlossen',
      );

      _enqueueRows(_rowsFromBatchItems(chunkResult.items));
    }
  }

  Future<void> _runWholeGalleryFlow() async {
    final parsedMaxItems = int.tryParse(_galleryMaxItemsController.text.trim());

    await _plugin.scanWholeGallery(
      settings: _scanSettings,
      includeImages: _galleryIncludeImages,
      includeVideos: _galleryIncludeVideos,
      maxItems: parsedMaxItems,
      pageSize: 140,
      scanChunkSize: 80,
      loadProgressEvery: 40,
      includeCleanResults: false,
      debugLogging: _galleryDebugLogging,
      onLoadProgress: (progress) {
        if (_galleryDebugLogging) {
          debugPrint(
            '[gallery][load] scanned=${progress.scannedAssets} images=${progress.imageCount} videos=${progress.videoCount} done=${progress.isCompleted}',
          );
        }
        _recordProgress(
          processed: progress.scannedAssets,
          total: progress.targetCount ?? math.max(progress.scannedAssets, 1),
          phase:
              'Galerie laden: ${progress.imageCount} Bilder, ${progress.videoCount} Videos',
        );
      },
      onScanProgress: (progress) {
        if (_galleryDebugLogging &&
            (progress.processed % 100 == 0 ||
                progress.processed == progress.total)) {
          debugPrint(
            '[gallery][scan] ${progress.processed}/${progress.total} percent=${progress.percent.toStringAsFixed(3)}',
          );
        }
        _recordProgress(
          processed: progress.processed,
          total: progress.total,
          phase: 'Galerie-Scan läuft',
        );
      },
      onChunkResult: (chunkResult) {
        if (_galleryDebugLogging) {
          debugPrint(
            '[gallery][chunk] items=${chunkResult.items.length} success=${chunkResult.successCount} errors=${chunkResult.errorCount} flagged=${chunkResult.flaggedCount}',
          );
        }
        _enqueueRows(_rowsFromBatchItems(chunkResult.items));
      },
    );
  }

  List<_LiveResultRow> _rowsFromBatchItems(
    List<NsfwMediaBatchItemResult> items,
  ) {
    final rows = <_LiveResultRow>[];
    for (final item in items) {
      if (!item.isNsfw && !item.hasError) {
        continue;
      }
      if (item.type == NsfwMediaType.video) {
        rows.add(
          _LiveResultRow(
            path: item.path,
            assetRef: _resolveAssetRef(item),
            type: NsfwMediaType.video,
            isNsfw: item.videoResult?.isNsfw ?? false,
            score: item.videoResult?.maxNsfwScore ?? 0,
            error: item.error,
          ),
        );
      } else {
        rows.add(
          _LiveResultRow(
            path: item.path,
            assetRef: _resolveAssetRef(item),
            type: NsfwMediaType.image,
            isNsfw: item.imageResult?.isNsfw ?? false,
            score: item.imageResult?.nsfwScore ?? 0,
            error: item.error,
          ),
        );
      }
    }
    return rows;
  }

  String _resolveAssetRef(NsfwMediaBatchItemResult item) {
    final uri = item.uri?.trim();
    if (uri != null && uri.isNotEmpty) {
      return uri;
    }
    final assetId = item.assetId?.trim();
    if (assetId != null && assetId.isNotEmpty) {
      return assetId;
    }
    return item.path.trim();
  }

  void _scheduleVisibleThumbnailLoads(List<_LiveResultRow> rows) {
    for (final row in rows) {
      if (row.type != NsfwMediaType.image) {
        continue;
      }
      unawaited(_loadVisibleThumbnail(row));
    }
  }

  Future<void> _loadVisibleThumbnail(_LiveResultRow row) async {
    final ref = row.assetRef.trim();
    if (ref.isEmpty || _thumbnailPathByRef.containsKey(ref)) {
      return;
    }
    if (_thumbnailLoadingRefs.contains(ref)) {
      return;
    }
    _thumbnailLoadingRefs.add(ref);
    try {
      final thumbnailPath = await _plugin.loadImageThumbnail(
        assetRef: ref,
        width: 160,
        height: 160,
        quality: 70,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _thumbnailPathByRef[ref] = thumbnailPath;
      });
    } catch (error) {
      if (_galleryDebugLogging) {
        debugPrint('[gallery][thumb] failed ref=$ref error=$error');
      }
      if (mounted) {
        setState(() {
          _thumbnailPathByRef[ref] = null;
        });
      }
    } finally {
      _thumbnailLoadingRefs.remove(ref);
    }
  }

  Future<void> _showFullImagePreview(_LiveResultRow item) async {
    if (item.type != NsfwMediaType.image) {
      return;
    }
    final ref = item.assetRef.trim();
    if (ref.isEmpty) {
      return;
    }

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    String? fullImagePath;
    String? errorMessage;
    try {
      fullImagePath = _fullImagePathByRef[ref];
      fullImagePath ??= await _plugin.loadImageAsset(assetRef: ref);
      if (fullImagePath != null && fullImagePath.isNotEmpty) {
        _fullImagePathByRef[ref] = fullImagePath;
      }
    } catch (error) {
      errorMessage = '$error';
    } finally {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
    }

    if (!mounted) {
      return;
    }

    if (fullImagePath == null || fullImagePath.isEmpty) {
      final message =
          errorMessage ?? 'Originalbild konnte nicht geladen werden.';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
      return;
    }

    final file = File(fullImagePath);
    if (!file.existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Geladenes Bild ist nicht mehr verfügbar.'),
        ),
      );
      return;
    }

    await showDialog<void>(
      context: context,
      builder: (context) {
        return Dialog(
          backgroundColor: Colors.black,
          insetPadding: const EdgeInsets.all(12),
          child: Stack(
            children: [
              InteractiveViewer(
                minScale: 0.6,
                maxScale: 4.0,
                child: Image.file(file, fit: BoxFit.contain),
              ),
              Positioned(
                top: 8,
                right: 8,
                child: IconButton.filled(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  bool _looksLikeVideo(String path) {
    final p = path.toLowerCase();
    return p.endsWith('.mp4') ||
        p.endsWith('.mov') ||
        p.endsWith('.mkv') ||
        p.endsWith('.avi') ||
        p.endsWith('.m4v') ||
        p.endsWith('.webm');
  }

  int get _pageCount => math.max(1, (_liveRows.length / _pageSize).ceil());

  List<_LiveResultRow> get _currentPageRows {
    if (_liveRows.isEmpty) {
      return const [];
    }
    final safePage = _pageIndex.clamp(0, _pageCount - 1);
    final start = safePage * _pageSize;
    final end = math.min(start + _pageSize, _liveRows.length);
    return _liveRows.sublist(start, end);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('NSFW Scan Wizard'),
        actions: [
          if (_running)
            IconButton(
              tooltip: 'Scan abbrechen',
              onPressed: _cancelCurrentScan,
              icon: const Icon(Icons.stop_circle_outlined),
            ),
        ],
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFFF3F7F8), Color(0xFFE7F0F2)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              _buildStepHeader(),
              const Divider(height: 1),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    child: KeyedSubtree(
                      key: ValueKey<int>(_stepIndex),
                      child: _buildStepContent(),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: _buildBottomBar(),
    );
  }

  Widget _buildStepHeader() {
    return SizedBox(
      height: 62,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        scrollDirection: Axis.horizontal,
        itemCount: _stepLabels.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final isCurrent = _stepIndex == index;
          final isDone = index < _stepIndex || (index == 3 && _scanDone);
          final chipColor = isCurrent
              ? const Color(0xFF0A7A8C)
              : (isDone ? const Color(0xFF2E7D32) : Colors.white);
          final textColor = isCurrent || isDone
              ? Colors.white
              : const Color(0xFF33464D);

          return AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: chipColor,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: const Color(0xFFB7C9CD)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isDone
                      ? Icons.check_circle
                      : (isCurrent
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked),
                  size: 16,
                  color: textColor,
                ),
                const SizedBox(width: 8),
                Text(
                  _stepLabels[index],
                  style: TextStyle(
                    color: textColor,
                    fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w600,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildStepContent() {
    if (_stepIndex == 3) {
      return _buildLiveResultsStep();
    }

    final content = switch (_stepIndex) {
      0 => _buildModeStep(),
      1 => _buildPreparationStep(),
      2 => _buildReviewStep(),
      _ => _buildModeStep(),
    };

    return SingleChildScrollView(child: content);
  }

  Widget _buildBottomBar() {
    final canGoBack = !_running && _stepIndex > 0 && _stepIndex < 3;
    final canGoForward = !_running && _stepIndex < 3;

    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        decoration: const BoxDecoration(
          color: Colors.white,
          boxShadow: [
            BoxShadow(
              color: Color(0x22000000),
              blurRadius: 10,
              offset: Offset(0, -2),
            ),
          ],
        ),
        child: Row(
          children: [
            if (_stepIndex < 3) ...[
              OutlinedButton(
                onPressed: canGoBack ? _previousStep : null,
                child: const Text('Zurück'),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                  onPressed: canGoForward ? _nextStep : null,
                  child: Text(_stepIndex >= 2 ? 'Scan starten' : 'Weiter'),
                ),
              ),
            ] else ...[
              Expanded(
                child: FilledButton.icon(
                  onPressed: _running ? null : _restartFromBeginning,
                  icon: const Icon(Icons.restart_alt),
                  label: const Text('Von vorne starten'),
                ),
              ),
              if (_running) ...[
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _cancelCurrentScan,
                  icon: const Icon(Icons.stop_circle_outlined),
                  label: const Text('Abbrechen'),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildModeStep() {
    if (_initializing) {
      return const LinearProgressIndicator(minHeight: 3);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _modeCard(
              mode: ScanMode.single,
              icon: Icons.image_search,
              title: 'Single Scan',
              subtitle: 'Ein Bild/Video schnell prüfen',
            ),
            _modeCard(
              mode: ScanMode.selectionBatch,
              icon: Icons.collections,
              title: 'Batch Scan',
              subtitle: 'Ausgewählte Medien in Chunks scannen',
            ),
            _modeCard(
              mode: ScanMode.wholeGallery,
              icon: Icons.photo_library,
              title: 'Gallery Scan',
              subtitle: 'Komplette Galerie nativ scannen',
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          _status,
          style: const TextStyle(fontSize: 13, color: Colors.black87),
        ),
      ],
    );
  }

  Widget _modeCard({
    required ScanMode mode,
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    final selected = _mode == mode;
    return SizedBox(
      width: 220,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () {
          setState(() {
            _mode = mode;
          });
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            color: selected ? const Color(0xFF0A7A8C) : Colors.white,
            border: Border.all(
              color: selected
                  ? const Color(0xFF0A7A8C)
                  : const Color(0xFFB7C9CD),
              width: selected ? 2 : 1,
            ),
            boxShadow: const [
              BoxShadow(
                color: Color(0x12000000),
                blurRadius: 10,
                offset: Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                icon,
                color: selected ? Colors.white : const Color(0xFF0A7A8C),
              ),
              const SizedBox(height: 8),
              Text(
                title,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: selected ? Colors.white : Colors.black87,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 12,
                  color: selected ? Colors.white70 : Colors.black54,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPreparationStep() {
    final mode = _mode;
    if (mode == null) {
      return const Text('Bitte zuerst einen Scan-Typ wählen.');
    }

    final controls = _buildCommonControls();

    if (mode == ScanMode.single) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          controls,
          const SizedBox(height: 12),
          Row(
            children: [
              FilledButton.icon(
                onPressed: _running ? null : _pickSingleMedia,
                icon: const Icon(Icons.add_photo_alternate_outlined),
                label: const Text('Datei wählen'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _singlePathController,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'Pfad (Bild oder Video)',
            ),
          ),
        ],
      );
    }

    if (mode == ScanMode.selectionBatch) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          controls,
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _running ? null : _pickBatchMedia,
            icon: const Icon(Icons.add_photo_alternate_outlined),
            label: const Text('Mehrere Medien wählen'),
          ),
          const SizedBox(height: 8),
          Text(
            'Auswahl: ${_selectedImagePaths.length} Bilder, ${_selectedVideoPaths.length} Videos',
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        controls,
        const SizedBox(height: 12),
        SwitchListTile.adaptive(
          value: _galleryIncludeImages,
          onChanged: _running
              ? null
              : (value) => setState(() => _galleryIncludeImages = value),
          title: const Text('Bilder scannen'),
        ),
        SwitchListTile.adaptive(
          value: _galleryIncludeVideos,
          onChanged: _running
              ? null
              : (value) => setState(() => _galleryIncludeVideos = value),
          title: const Text('Videos scannen'),
        ),
        SwitchListTile.adaptive(
          value: _galleryDebugLogging,
          onChanged: _running
              ? null
              : (value) => setState(() => _galleryDebugLogging = value),
          title: const Text('Debug Logging (nativ)'),
          subtitle: const Text('Für Simulator/DevTools Analyse aktiv lassen'),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _galleryMaxItemsController,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            labelText: 'Max Items (optional, z.B. 2000)',
          ),
        ),
      ],
    );
  }

  Widget _buildCommonControls() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Image Threshold: ${_imageThreshold.toStringAsFixed(2)}'),
        Slider(
          value: _imageThreshold,
          min: 0.2,
          max: 0.95,
          onChanged: _running
              ? null
              : (value) => setState(() => _imageThreshold = value),
        ),
        Text('Video Threshold: ${_videoThreshold.toStringAsFixed(2)}'),
        Slider(
          value: _videoThreshold,
          min: 0.2,
          max: 0.95,
          onChanged: _running
              ? null
              : (value) => setState(() => _videoThreshold = value),
        ),
        Text('Max Concurrency: $_maxConcurrency'),
        Slider(
          value: _maxConcurrency.toDouble(),
          min: 1,
          max: 8,
          divisions: 7,
          onChanged: _running
              ? null
              : (value) => setState(() => _maxConcurrency = value.round()),
        ),
      ],
    );
  }

  Widget _buildReviewStep() {
    final mode = _mode;
    if (mode == null) {
      return const Text('Bitte Scan-Typ wählen.');
    }

    final modeLabel = switch (mode) {
      ScanMode.single => 'Single Scan',
      ScanMode.selectionBatch => 'Batch Scan',
      ScanMode.wholeGallery => 'Gallery Scan',
    };

    return Card(
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Konfiguration',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text('Modus: $modeLabel'),
            Text('Image threshold: ${_imageThreshold.toStringAsFixed(2)}'),
            Text('Video threshold: ${_videoThreshold.toStringAsFixed(2)}'),
            Text('Concurrency: $_maxConcurrency'),
            if (mode == ScanMode.single)
              Text('Pfad: ${_singlePathController.text.trim()}'),
            if (mode == ScanMode.selectionBatch)
              Text(
                'Auswahl: ${_selectedImagePaths.length} Bilder, ${_selectedVideoPaths.length} Videos',
              ),
            if (mode == ScanMode.wholeGallery)
              Text(
                'Gallery: images=$_galleryIncludeImages, videos=$_galleryIncludeVideos, maxItems=${_galleryMaxItemsController.text.trim().isEmpty ? 'unbegrenzt' : _galleryMaxItemsController.text.trim()}',
              ),
            const SizedBox(height: 8),
            Text(
              'Nach Start werden Ergebnisse live gesammelt und alle ${_uiPollingInterval.inMilliseconds}ms in der UI aktualisiert.',
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLiveResultsStep() {
    final ratio = _total <= 0 ? 0.0 : (_processed / _total).clamp(0.0, 1.0);
    final currentRows = _currentPageRows;
    _scheduleVisibleThumbnailLoads(currentRows);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Card(
          color: Colors.white,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _running
                      ? 'Scan läuft'
                      : (_scanDone ? 'Scan abgeschlossen' : 'Bereit'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 6),
                Text(_phase),
                const SizedBox(height: 6),
                LinearProgressIndicator(
                  value: _running ? ratio : (_scanDone ? 1 : 0),
                ),
                const SizedBox(height: 6),
                Text('Fortschritt: $_processed / $_total'),
                Text('Ergebnisse: ${_liveRows.length}'),
                Text(_status),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: _pageIndex > 0
                  ? () => setState(() => _pageIndex -= 1)
                  : null,
              icon: const Icon(Icons.chevron_left),
              label: const Text('Vorherige'),
            ),
            const SizedBox(width: 8),
            Text('Seite ${_pageIndex + 1} / $_pageCount'),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: _pageIndex < _pageCount - 1
                  ? () => setState(() => _pageIndex += 1)
                  : null,
              icon: const Icon(Icons.chevron_right),
              label: const Text('Nächste'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: currentRows.isEmpty
              ? const Center(child: Text('Noch keine Ergebnisse verfügbar.'))
              : ListView.separated(
                  itemCount: currentRows.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final item = currentRows[index];
                    return ListTile(
                      onTap: item.type == NsfwMediaType.image
                          ? () => _showFullImagePreview(item)
                          : null,
                      leading: _buildPreview(item),
                      title: Text(
                        item.path,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        item.hasError
                            ? 'Fehler: ${item.error}'
                            : '${item.type == NsfwMediaType.video ? 'Video' : 'Bild'} • Score ${item.score.toStringAsFixed(3)}',
                      ),
                      trailing: item.hasError
                          ? const Icon(Icons.error_outline, color: Colors.red)
                          : Icon(
                              item.isNsfw
                                  ? Icons.warning_amber_rounded
                                  : Icons.verified,
                              color: item.isNsfw ? Colors.orange : Colors.green,
                            ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildPreview(_LiveResultRow item) {
    final fallbackIcon = CircleAvatar(
      backgroundColor: const Color(0xFFE5EEF0),
      child: Icon(
        item.type == NsfwMediaType.video ? Icons.movie : Icons.image,
        color: const Color(0xFF0A7A8C),
      ),
    );

    if (item.type != NsfwMediaType.image) {
      return fallbackIcon;
    }

    final ref = item.assetRef.trim();
    final thumbnailPath = _thumbnailPathByRef[ref];
    if (thumbnailPath != null && thumbnailPath.isNotEmpty) {
      final file = File(thumbnailPath);
      if (file.existsSync()) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Image.file(
            file,
            width: 42,
            height: 42,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => fallbackIcon,
          ),
        );
      }
    }

    final path = item.path;
    if (path.startsWith('/')) {
      final file = File(path);
      if (file.existsSync()) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Image.file(
            file,
            width: 42,
            height: 42,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => fallbackIcon,
          ),
        );
      }
    }

    if (_thumbnailLoadingRefs.contains(ref)) {
      return CircleAvatar(
        backgroundColor: const Color(0xFFE5EEF0),
        child: SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: const Color(0xFF0A7A8C),
          ),
        ),
      );
    }
    return fallbackIcon;
  }
}
