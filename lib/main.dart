import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:crop_your_image/crop_your_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SmartImageToolApp());
}

class SmartImageToolApp extends StatelessWidget {
  const SmartImageToolApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Smart Image Tool',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF6A1B9A),
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF9C27B0),
        brightness: Brightness.dark,
      ),
      home: const HomeScreen(),
    );
  }
}

enum ToolMode { compress, increase, resize, crop }

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Uint8List? _originalBytes;
  Uint8List? _processedBytes;
  int _origWidth = 0;
  int _origHeight = 0;
  int _outWidth = 0;
  int _outHeight = 0;
  bool _isBusy = false;

  final ImagePicker _picker = ImagePicker();

  Future<void> _pickImage([ToolMode? autoOpenTool]) async {
    try {
      final XFile? file = await _picker.pickImage(source: ImageSource.gallery);
      if (file == null) return;

      setState(() => _isBusy = true);
      final bytes = await file.readAsBytes();
      final decoded = await compute(_decodeDimensions, bytes);

      setState(() {
        _originalBytes = bytes;
        _processedBytes = null;
        _origWidth = decoded.$1;
        _origHeight = decoded.$2;
        _outWidth = decoded.$1;
        _outHeight = decoded.$2;
        _isBusy = false;
      });

      if (autoOpenTool != null && mounted) {
        _openToolSheet(autoOpenTool);
      }
    } catch (e) {
      setState(() => _isBusy = false);
      _showSnack('Photo load karne me error: $e');
    }
  }

  static (int, int) _decodeDimensions(Uint8List bytes) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return (0, 0);
    return (decoded.width, decoded.height);
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
    final mb = kb / 1024;
    return '${mb.toStringAsFixed(2)} MB';
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _saveToGallery() async {
    final bytes = _processedBytes;
    if (bytes == null) return;
    try {
      setState(() => _isBusy = true);
      final tempDir = await getTemporaryDirectory();
      final fileName =
          'SmartImage_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final filePath = '${tempDir.path}/$fileName';
      final file = File(filePath);
      await file.writeAsBytes(bytes, flush: true);

      await Gal.putImage(filePath, album: 'SmartImageTool');
      setState(() => _isBusy = false);
      _showSnack('Saved to Gallery (Album: SmartImageTool)!');
    } catch (e) {
      setState(() => _isBusy = false);
      _showSnack('Save error: $e');
    }
  }

  Future<void> _shareImage() async {
    final bytes = _processedBytes;
    if (bytes == null) return;
    try {
      final tempDir = await getTemporaryDirectory();
      final filePath =
          '${tempDir.path}/SmartImage_${DateTime.now().millisecondsSinceEpoch}.jpg';
      await File(filePath).writeAsBytes(bytes, flush: true);
      await Share.shareXFiles([XFile(filePath)], text: 'Smart Image Tool JPG');
    } catch (e) {
      _showSnack('Share error: $e');
    }
  }

  void _openToolSheet(ToolMode mode) {
    if (_originalBytes == null) {
      _pickImage(mode);
      return;
    }

    if (mode == ToolMode.crop) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => CropScreen(
            imageBytes: _processedBytes ?? _originalBytes!,
            onCropped: (Uint8List croppedBytes) async {
              setState(() => _isBusy = true);
              final result = await compute(_encodeCleanJpg, croppedBytes);
              setState(() {
                _processedBytes = result.$1;
                _outWidth = result.$2;
                _outHeight = result.$3;
                _isBusy = false;
              });
            },
          ),
        ),
      );
      return;
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) {
        switch (mode) {
          case ToolMode.compress:
            return TargetSizeSheet(
              isIncrease: false,
              currentSizeBytes: (_processedBytes ?? _originalBytes!).length,
              onApply: (int targetBytes) => _runTargetSize(targetBytes, false),
            );
          case ToolMode.increase:
            return TargetSizeSheet(
              isIncrease: true,
              currentSizeBytes: (_processedBytes ?? _originalBytes!).length,
              onApply: (int targetBytes) => _runTargetSize(targetBytes, true),
            );
          case ToolMode.resize:
            return ResizeSheet(
              origWidth: _outWidth > 0 ? _outWidth : _origWidth,
              origHeight: _outHeight > 0 ? _outHeight : _origHeight,
              onApply: (int w, int h) => _runResize(w, h),
            );
          case ToolMode.crop:
            return const SizedBox.shrink();
        }
      },
    );
  }

  static (Uint8List, int, int) _encodeCleanJpg(Uint8List rawBytes) {
    final decoded = img.decodeImage(rawBytes);
    if (decoded == null) return (rawBytes, 0, 0);
    final jpg = Uint8List.fromList(img.encodeJpg(decoded, quality: 92));
    return (jpg, decoded.width, decoded.height);
  }

  Future<void> _runTargetSize(int targetBytes, bool isIncrease) async {
    if (_originalBytes == null) return;
    setState(() => _isBusy = true);
    try {
      final source = _processedBytes ?? _originalBytes!;
      final result = await compute(
        isIncrease ? _increaseSizeIsolate : _compressSizeIsolate,
        (source, targetBytes),
      );
      setState(() {
        _processedBytes = result.$1;
        _outWidth = result.$2;
        _outHeight = result.$3;
        _isBusy = false;
      });
      _showSnack('Done! New size: ${_formatBytes(result.$1.length)}');
    } catch (e) {
      setState(() => _isBusy = false);
      _showSnack('Error processing image: $e');
    }
  }

  Future<void> _runResize(int targetW, int targetH) async {
    if (_originalBytes == null) return;
    setState(() => _isBusy = true);
    try {
      final source = _processedBytes ?? _originalBytes!;
      final result = await compute(
        _resizeIsolate,
        (source, targetW, targetH),
      );
      setState(() {
        _processedBytes = result.$1;
        _outWidth = result.$2;
        _outHeight = result.$3;
        _isBusy = false;
      });
      _showSnack('Resized to ${result.$2} x ${result.$3} px');
    } catch (e) {
      setState(() => _isBusy = false);
      _showSnack('Resize error: $e');
    }
  }

  // Isolate: Compress to target bytes
  static (Uint8List, int, int) _compressSizeIsolate((Uint8List, int) args) {
    final Uint8List srcBytes = args.$1;
    final int targetBytes = args.$2;
    img.Image? baseImage = img.decodeImage(srcBytes);
    if (baseImage == null) return (srcBytes, 0, 0);

    Uint8List? bestFit;
    int bestW = baseImage.width;
    int bestH = baseImage.height;

    double scale = 1.0;
    for (int step = 0; step < 8; step++) {
      final img.Image working = scale == 1.0
          ? baseImage
          : img.copyResize(
              baseImage,
              width: math.max(32, (baseImage.width * scale).round()),
              height: math.max(32, (baseImage.height * scale).round()),
              interpolation: img.Interpolation.average,
            );

      int low = 5;
      int high = 95;
      Uint8List? candidateUnderTarget;

      while (low <= high) {
        final int mid = (low + high) ~/ 2;
        final Uint8List encoded =
            Uint8List.fromList(img.encodeJpg(working, quality: mid));
        if (encoded.length <= targetBytes) {
          candidateUnderTarget = encoded;
          low = mid + 1;
        } else {
          high = mid - 1;
        }
      }

      if (candidateUnderTarget != null) {
        bestFit = candidateUnderTarget;
        bestW = working.width;
        bestH = working.height;
        break;
      }

      scale *= 0.72;
    }

    if (bestFit == null) {
      final tiny = img.copyResize(baseImage, width: 120);
      bestFit = Uint8List.fromList(img.encodeJpg(tiny, quality: 5));
      bestW = tiny.width;
      bestH = tiny.height;
    }

    // Pad with safe trailing bytes if user needs exact close match (within 1%)
    if (bestFit.length < targetBytes && (targetBytes - bestFit.length) > 512) {
      final padded = Uint8List(targetBytes);
      padded.setRange(0, bestFit.length, bestFit);
      bestFit = padded;
    }

    return (bestFit, bestW, bestH);
  }

  // Isolate: Increase size to target bytes
  static (Uint8List, int, int) _increaseSizeIsolate((Uint8List, int) args) {
    final Uint8List srcBytes = args.$1;
    final int targetBytes = args.$2;
    img.Image? baseImage = img.decodeImage(srcBytes);
    if (baseImage == null) return (srcBytes, 0, 0);

    Uint8List encoded =
        Uint8List.fromList(img.encodeJpg(baseImage, quality: 100));
    int outW = baseImage.width;
    int outH = baseImage.height;

    // Upscale modestly if way below target size
    if (encoded.length < targetBytes ~/ 2 &&
        baseImage.width * baseImage.height < 4000 * 4000) {
      final up = img.copyResize(
        baseImage,
        width: (baseImage.width * 1.5).round(),
        height: (baseImage.height * 1.5).round(),
        interpolation: img.Interpolation.cubic,
      );
      final upEncoded = Uint8List.fromList(img.encodeJpg(up, quality: 100));
      if (upEncoded.length <= targetBytes) {
        encoded = upEncoded;
        outW = up.width;
        outH = up.height;
      }
    }

    if (encoded.length < targetBytes) {
      final padded = Uint8List(targetBytes);
      padded.setRange(0, encoded.length, encoded);
      return (padded, outW, outH);
    } else if (encoded.length > targetBytes) {
      return _compressSizeIsolate((srcBytes, targetBytes));
    }
    return (encoded, outW, outH);
  }

  // Isolate: Resize to exact pixel width & height
  static (Uint8List, int, int) _resizeIsolate((Uint8List, int, int) args) {
    final Uint8List srcBytes = args.$1;
    final int targetW = math.max(1, math.min(8000, args.$2));
    final int targetH = math.max(1, math.min(8000, args.$3));
    final img.Image? decoded = img.decodeImage(srcBytes);
    if (decoded == null) return (srcBytes, 0, 0);

    final resized = img.copyResize(
      decoded,
      width: targetW,
      height: targetH,
      interpolation: img.Interpolation.cubic,
    );
    final jpg = Uint8List.fromList(img.encodeJpg(resized, quality: 92));
    return (jpg, resized.width, resized.height);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final activeBytes = _processedBytes ?? _originalBytes;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Smart Image Tool',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        centerTitle: true,
        actions: [
          if (_originalBytes != null)
            IconButton(
              tooltip: 'New Image',
              onPressed: () => _pickImage(),
              icon: const Icon(Icons.add_photo_alternate_outlined),
            ),
        ],
      ),
      body: Stack(
        children: [
          SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Preview Card
                GestureDetector(
                  onTap: _originalBytes == null ? () => _pickImage() : null,
                  child: Container(
                    height: 240,
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHighest.withOpacity(0.55),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: colorScheme.primary.withOpacity(0.25),
                        width: 1.5,
                      ),
                    ),
                    child: activeBytes == null
                        ? Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.add_a_photo_rounded,
                                size: 52,
                                color: colorScheme.primary,
                              ),
                              const SizedBox(height: 12),
                              Text(
                                'Tap to Select Photo',
                                style: Theme.of(context)
                                    .textTheme
                                    .titleMedium
                                    ?.copyWith(fontWeight: FontWeight.w600),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Supports JPG, PNG, WEBP -> Exports Clean JPG',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          )
                        : ClipRRect(
                            borderRadius: BorderRadius.circular(18),
                            child: Image.memory(
                              activeBytes,
                              fit: BoxFit.contain,
                            ),
                          ),
                  ),
                ),
                const SizedBox(height: 14),

                // Before vs After Info Banner
                if (_originalBytes != null)
                  Card(
                    elevation: 0,
                    color: colorScheme.secondaryContainer.withOpacity(0.55),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          _StatColumn(
                            label: 'ORIGINAL',
                            sizeText: _formatBytes(_originalBytes!.length),
                            dimText: '$_origWidth × $_origHeight px',
                          ),
                          const Icon(Icons.arrow_forward_rounded),
                          _StatColumn(
                            label: _processedBytes == null ? 'CURRENT' : 'OUTPUT (JPG)',
                            sizeText: _formatBytes(activeBytes!.length),
                            dimText: '$_outWidth × $_outHeight px',
                            highlight: _processedBytes != null,
                          ),
                        ],
                      ),
                    ),
                  ),

                if (_processedBytes != null) ...[
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _saveToGallery,
                          icon: const Icon(Icons.download_rounded),
                          label: const Text('Save JPG'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _shareImage,
                          icon: const Icon(Icons.share_rounded),
                          label: const Text('Share'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filledTonal(
                        tooltip: 'Reset to Original',
                        onPressed: () {
                          setState(() {
                            _processedBytes = null;
                            _outWidth = _origWidth;
                            _outHeight = _origHeight;
                          });
                        },
                        icon: const Icon(Icons.restart_alt_rounded),
                      ),
                    ],
                  ),
                ],

                const SizedBox(height: 20),
                Text(
                  'Choose Action',
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),

                // 4 Main Feature Grid
                GridView.count(
                  crossAxisCount: 2,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 1.15,
                  children: [
                    _ToolCard(
                      icon: Icons.compress_rounded,
                      title: 'Compress Size',
                      subtitle: 'Reduce to exact KB / MB (e.g. 50 KB)',
                      onTap: () => _openToolSheet(ToolMode.compress),
                    ),
                    _ToolCard(
                      icon: Icons.expand_rounded,
                      title: 'Increase Size',
                      subtitle: 'Boost file size to exact KB / MB',
                      onTap: () => _openToolSheet(ToolMode.increase),
                    ),
                    _ToolCard(
                      icon: Icons.photo_size_select_large_rounded,
                      title: 'Resize Image',
                      subtitle: 'By Pixel, %, Inch, or CM (with DPI)',
                      onTap: () => _openToolSheet(ToolMode.resize),
                    ),
                    _ToolCard(
                      icon: Icons.crop_rotate_rounded,
                      title: 'Crop Image',
                      subtitle: 'Freehand, 1:1, 4:3, 16:9 & Passport',
                      onTap: () => _openToolSheet(ToolMode.crop),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (_isBusy)
            Container(
              color: Colors.black45,
              child: const Center(
                child: Card(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 14),
                        Text('Processing JPG...'),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _StatColumn extends StatelessWidget {
  final String label;
  final String sizeText;
  final String dimText;
  final bool highlight;

  const _StatColumn({
    required this.label,
    required this.sizeText,
    required this.dimText,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: highlight ? cs.primary : null,
              ),
        ),
        const SizedBox(height: 2),
        Text(
          sizeText,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
                color: highlight ? cs.primary : null,
              ),
        ),
        Text(dimText, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

class _ToolCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _ToolCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Ink(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          color: cs.surfaceContainerHigh,
          border: Border.all(color: cs.outlineVariant.withOpacity(0.5)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            CircleAvatar(
              backgroundColor: cs.primaryContainer,
              foregroundColor: cs.onPrimaryContainer,
              child: Icon(icon),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: Theme.of(context).textTheme.bodySmall,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// Bottom Sheet 1 & 2: Compress or Increase by Exact KB / MB
class TargetSizeSheet extends StatefulWidget {
  final bool isIncrease;
  final int currentSizeBytes;
  final ValueChanged<int> onApply;

  const TargetSizeSheet({
    super.key,
    required this.isIncrease,
    required this.currentSizeBytes,
    required this.onApply,
  });

  @override
  State<TargetSizeSheet> createState() => _TargetSizeSheetState();
}

class _TargetSizeSheetState extends State<TargetSizeSheet> {
  final TextEditingController _controller = TextEditingController(text: '50');
  bool _isMb = false;

  @override
  void initState() {
    super.initState();
    if (widget.isIncrease) {
      final suggestedKb = ((widget.currentSizeBytes / 1024) * 1.5).round();
      _controller.text = math.max(100, suggestedKb).toString();
    }
  }

  @override
  Widget build(BuildContext context) {
    final presetsKb = widget.isIncrease
        ? [100, 200, 500, 1024, 2048]
        : [20, 50, 100, 200, 500];

    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.isIncrease
                ? 'Increase Image Size (Target KB/MB)'
                : 'Compress Image Size (Target KB/MB)',
            style: Theme.of(context)
                .textTheme
                .titleLarge
                ?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          Text(
            widget.isIncrease
                ? 'Enter the exact larger file size you want (e.g. 200 KB or 2 MB).'
                : 'Enter the maximum file size you need (e.g. 50 KB).',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Enter Target Value',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('KB')),
                  ButtonSegment(value: true, label: Text('MB')),
                ],
                selected: {_isMb},
                onSelectionChanged: (s) => setState(() => _isMb = s.first),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: presetsKb.map((kb) {
              final label = kb >= 1024 ? '${kb ~/ 1024} MB' : '$kb KB';
              return ActionChip(
                label: Text(label),
                onPressed: () {
                  setState(() {
                    _isMb = false;
                    _controller.text = kb.toString();
                  });
                },
              );
            }).toList(),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: () {
              final val = double.tryParse(_controller.text.trim()) ?? 0;
              if (val <= 0) return;
              final int bytes = _isMb
                  ? (val * 1024 * 1024).round()
                  : (val * 1024).round();
              Navigator.pop(context);
              widget.onApply(bytes);
            },
            child: const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('Apply Now'),
            ),
          ),
        ],
      ),
    );
  }
}

// Bottom Sheet 3: Resize by Pixel, Percentage, Inch, CM
enum ResizeUnit { px, percent, inch, cm }

class ResizeSheet extends StatefulWidget {
  final int origWidth;
  final int origHeight;
  final void Function(int width, int height) onApply;

  const ResizeSheet({
    super.key,
    required this.origWidth,
    required this.origHeight,
    required this.onApply,
  });

  @override
  State<ResizeSheet> createState() => _ResizeSheetState();
}

class _ResizeSheetState extends State<ResizeSheet> {
  ResizeUnit _unit = ResizeUnit.px;
  bool _lockAspect = true;
  late TextEditingController _wCtrl;
  late TextEditingController _hCtrl;
  final TextEditingController _dpiCtrl = TextEditingController(text: '300');
  bool _updatingFields = false;

  @override
  void initState() {
    super.initState();
    _wCtrl = TextEditingController(text: widget.origWidth.toString());
    _hCtrl = TextEditingController(text: widget.origHeight.toString());
  }

  void _onUnitChanged(ResizeUnit newUnit) {
    setState(() {
      _unit = newUnit;
      _updatingFields = true;
      final dpi = double.tryParse(_dpiCtrl.text) ?? 300;
      switch (newUnit) {
        case ResizeUnit.px:
          _wCtrl.text = widget.origWidth.toString();
          _hCtrl.text = widget.origHeight.toString();
          break;
        case ResizeUnit.percent:
          _wCtrl.text = '50';
          _hCtrl.text = '50';
          break;
        case ResizeUnit.inch:
          _wCtrl.text = (widget.origWidth / dpi).toStringAsFixed(2);
          _hCtrl.text = (widget.origHeight / dpi).toStringAsFixed(2);
          break;
        case ResizeUnit.cm:
          _wCtrl.text = ((widget.origWidth / dpi) * 2.54).toStringAsFixed(2);
          _hCtrl.text = ((widget.origHeight / dpi) * 2.54).toStringAsFixed(2);
          break;
      }
      _updatingFields = false;
    });
  }

  void _onWidthChanged(String value) {
    if (!_lockAspect || _updatingFields) return;
    final w = double.tryParse(value);
    if (w == null || w <= 0) return;
    _updatingFields = true;
    if (_unit == ResizeUnit.percent) {
      _hCtrl.text = value;
    } else {
      final ratio = widget.origHeight / widget.origWidth;
      final h = w * ratio;
      _hCtrl.text =
          _unit == ResizeUnit.px ? h.round().toString() : h.toStringAsFixed(2);
    }
    _updatingFields = false;
  }

  void _onHeightChanged(String value) {
    if (!_lockAspect || _updatingFields) return;
    final h = double.tryParse(value);
    if (h == null || h <= 0) return;
    _updatingFields = true;
    if (_unit == ResizeUnit.percent) {
      _wCtrl.text = value;
    } else {
      final ratio = widget.origWidth / widget.origHeight;
      final w = h * ratio;
      _wCtrl.text =
          _unit == ResizeUnit.px ? w.round().toString() : w.toStringAsFixed(2);
    }
    _updatingFields = false;
  }

  (int, int) _computeTargetPixels() {
    final wVal = double.tryParse(_wCtrl.text.trim()) ?? 0;
    final hVal = double.tryParse(_hCtrl.text.trim()) ?? 0;
    final dpi = double.tryParse(_dpiCtrl.text.trim()) ?? 300;
    switch (_unit) {
      case ResizeUnit.px:
        return (wVal.round(), hVal.round());
      case ResizeUnit.percent:
        return (
          ((widget.origWidth * wVal) / 100).round(),
          ((widget.origHeight * hVal) / 100).round(),
        );
      case ResizeUnit.inch:
        return ((wVal * dpi).round(), (hVal * dpi).round());
      case ResizeUnit.cm:
        return (
          ((wVal / 2.54) * dpi).round(),
          ((hVal / 2.54) * dpi).round(),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final unitSuffix = switch (_unit) {
      ResizeUnit.px => 'px',
      ResizeUnit.percent => '%',
      ResizeUnit.inch => 'in',
      ResizeUnit.cm => 'cm',
    };

    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Resize Image',
            style: Theme.of(context)
                .textTheme
                .titleLarge
                ?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          SegmentedButton<ResizeUnit>(
            segments: const [
              ButtonSegment(value: ResizeUnit.px, label: Text('Pixels')),
              ButtonSegment(value: ResizeUnit.percent, label: Text('%')),
              ButtonSegment(value: ResizeUnit.inch, label: Text('Inch')),
              ButtonSegment(value: ResizeUnit.cm, label: Text('CM')),
            ],
            selected: {_unit},
            onSelectionChanged: (s) => _onUnitChanged(s.first),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _wCtrl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  onChanged: _onWidthChanged,
                  decoration: InputDecoration(
                    labelText: 'Width ($unitSuffix)',
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _hCtrl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  onChanged: _onHeightChanged,
                  decoration: InputDecoration(
                    labelText: 'Height ($unitSuffix)',
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
            ],
          ),
          if (_unit == ResizeUnit.inch || _unit == ResizeUnit.cm) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _dpiCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Print Resolution (DPI - Default 300)',
                border: OutlineInputBorder(),
              ),
            ),
          ],
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Lock Aspect Ratio'),
            value: _lockAspect,
            onChanged: (v) => setState(() => _lockAspect = v),
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: () {
              final (w, h) = _computeTargetPixels();
              if (w <= 0 || h <= 0) return;
              Navigator.pop(context);
              widget.onApply(w, h);
            },
            child: const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('Resize Now'),
            ),
          ),
        ],
      ),
    );
  }
}

// Screen 4: Pure Flutter Interactive Crop Screen
class CropScreen extends StatefulWidget {
  final Uint8List imageBytes;
  final ValueChanged<Uint8List> onCropped;

  const CropScreen({
    super.key,
    required this.imageBytes,
    required this.onCropped,
  });

  @override
  State<CropScreen> createState() => _CropScreenState();
}

class _CropScreenState extends State<CropScreen> {
  final CropController _cropController = CropController();
  double? _aspectRatio;
  bool _isCropping = false;

  void _setRatio(double? r) {
    setState(() => _aspectRatio = r);
    _cropController.aspectRatio = r;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Crop Image'),
        actions: [
          TextButton.icon(
            onPressed: _isCropping
                ? null
                : () {
                    setState(() => _isCropping = true);
                    _cropController.crop();
                  },
            icon: const Icon(Icons.check_rounded),
            label: const Text('Done'),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Crop(
                image: widget.imageBytes,
                controller: _cropController,
                aspectRatio: _aspectRatio,
                onCropped: (Uint8List croppedData) {
                  Navigator.pop(context);
                  widget.onCropped(croppedData);
                },
              ),
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            child: Row(
              children: [
                _RatioChip(
                  label: 'Free',
                  selected: _aspectRatio == null,
                  onTap: () => _setRatio(null),
                ),
                _RatioChip(
                  label: '1:1 Square',
                  selected: _aspectRatio == 1.0,
                  onTap: () => _setRatio(1.0),
                ),
                _RatioChip(
                  label: 'Passport (3.5:4.5)',
                  selected: _aspectRatio == 3.5 / 4.5,
                  onTap: () => _setRatio(3.5 / 4.5),
                ),
                _RatioChip(
                  label: '4:3',
                  selected: _aspectRatio == 4 / 3,
                  onTap: () => _setRatio(4 / 3),
                ),
                _RatioChip(
                  label: '16:9',
                  selected: _aspectRatio == 16 / 9,
                  onTap: () => _setRatio(16 / 9),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RatioChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _RatioChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => onTap(),
      ),
    );
  }
}
