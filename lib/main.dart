import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as img;
import 'package:crop_your_image/crop_your_image.dart';
import 'package:gal/gal.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';

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

/// Exact port & Native Android Channel for the APK's (`com.mobso.photoreducer.lite`)
/// Image Compression Engine:
/// - Mode A: Target File Size (KB / MB) with iterative step-down (-1 above 70, -2 above 45, -3 at/below 45 down to minQuality = 4)
///   and automatic 750px power-of-2 sub-sampling fallback (`B0` method).
/// - Mode B: Direct Quality Slider (1% - 100%, default 80%) (`MainActivity$t`).
class ApkPhotoReducerEngine {
  static const MethodChannel _channel =
      MethodChannel('com.smartimagetool/apk_compressor');

  /// Calls the exact Native Android `BitmapFactory` + `ExifInterface` + `Bitmap.compress`
  /// implementation from `com.mobso.photoreducer.lite.MainActivity` when running on Android,
  /// with a 100% matching Dart fallback.
  static Future<Map<String, dynamic>> compressWithApkAlgorithm({
    required String inputPath,
    required String outputPath,
    required bool useQualitySlider,
    required int sliderQuality,
    required double targetBytes,
  }) async {
    if (!kIsWeb && Platform.isAndroid) {
      try {
        final result = await _channel.invokeMapMethod<String, dynamic>(
          'compressImage',
          {
            'inputPath': inputPath,
            'outputPath': outputPath,
            'useQualitySlider': useQualitySlider,
            'sliderQuality': sliderQuality,
            'targetBytes': targetBytes,
          },
        );
        if (result != null && result['success'] == true) {
          return result;
        }
      } catch (e) {
        debugPrint('Native channel fallback to Dart engine: $e');
      }
    }

    // Pure Dart exact mirror of MainActivity$i, MainActivity$t, B0(), and c1()
    return await compute(_dartApkCompressWorker, {
      'inputPath': inputPath,
      'outputPath': outputPath,
      'useQualitySlider': useQualitySlider,
      'sliderQuality': sliderQuality,
      'targetBytes': targetBytes,
    });
  }

  /// Exact Dart port of `MainActivity.B0(Uri)` + `MainActivity$i.run()` + `MainActivity$t.run()`
  static Map<String, dynamic> _dartApkCompressWorker(Map<String, dynamic> args) {
    final String inputPath = args['inputPath'] as String;
    final String outputPath = args['outputPath'] as String;
    final bool useQualitySlider = args['useQualitySlider'] as bool;
    final int sliderQuality = args['sliderQuality'] as int;
    final double targetBytes = args['targetBytes'] as double;

    final Uint8List sourceBytes = File(inputPath).readAsBytesSync();
    final int originalFileLength = sourceBytes.length;

    img.Image? decoded = img.decodeImage(sourceBytes);
    if (decoded == null) {
      throw Exception('Unable to decode image');
    }
    // Fix EXIF orientation just like MainActivity.Q0(Uri) & S0(Bitmap, float)
    decoded = img.bakeOrientation(decoded);

    if (useQualitySlider) {
      // Exact mirror of MainActivity$t (SeekBar quality mode)
      final int q = sliderQuality.clamp(1, 100);
      final Uint8List jpgBytes = Uint8List.fromList(img.encodeJpg(decoded, quality: q));
      File(outputPath).writeAsBytesSync(jpgBytes, flush: true);
      return {
        'success': true,
        'outputPath': outputPath,
        'finalSize': jpgBytes.length,
        'finalQuality': q,
        'downsampled': false,
        'width': decoded.width,
        'height': decoded.height,
      };
    }

    // Exact mirror of MainActivity$i (Target KB / MB mode):
    // Pass 1: a0 = true (Full resolution Bitmap)
    // Pass 2: a0 = false (B0() sub-sampled Bitmap with 750px reference)
    for (int pass = 0; pass < 2; pass++) {
      final bool isFullResPass = (pass == 0);
      img.Image workingBitmap = decoded;

      if (!isFullResPass) {
        // MainActivity.B0(Uri) exact formula:
        // int maxDim = Math.max(outHeight, outWidth);
        // int inSampleSize = (int) Math.pow(2.0, (double) Math.round(Math.log(750.0 / maxDim) / Math.log(0.5)));
        final int outHeight = decoded.height;
        final int outWidth = decoded.width;
        int inSampleSize = 1;
        if (outHeight > 750 || outWidth > 750) {
          final int maxDim = math.max(outHeight, outWidth);
          final int exp = (math.log(750.0 / maxDim) / math.log(0.5)).round();
          inSampleSize = math.pow(2.0, exp).toInt();
          if (inSampleSize < 1) inSampleSize = 1;
        }
        if (inSampleSize > 1) {
          workingBitmap = img.copyResize(
            decoded,
            width: math.max(1, decoded.width ~/ inSampleSize),
            height: math.max(1, decoded.height ~/ inSampleSize),
            interpolation: img.Interpolation.average,
          );
        }
      }

      // Step 1: Compress at quality = 100 first
      int quality = 100;
      const int minQuality = 4; // MainActivity.f = 4 / MainActivity.m = 4
      Uint8List currentBytes =
          Uint8List.fromList(img.encodeJpg(workingBitmap, quality: quality));
      int currentLength = currentBytes.length;

      bool achieved = false;
      if ((originalFileLength + 1) <= targetBytes ||
          (currentLength + 1) <= targetBytes) {
        achieved = true;
      } else {
        bool keepLooping = true;
        while (keepLooping) {
          if ((currentLength + 1) > targetBytes) {
            achieved = false;
            if (quality > minQuality) {
              if (quality > 70) {
                quality -= 1;
              } else if (quality > 45) {
                quality -= 2;
              } else {
                quality -= 3;
              }
              currentBytes = Uint8List.fromList(
                  img.encodeJpg(workingBitmap, quality: quality));
              currentLength = currentBytes.length;
            } else {
              quality = minQuality;
              currentBytes = Uint8List.fromList(
                  img.encodeJpg(workingBitmap, quality: quality));
              currentLength = currentBytes.length;
              keepLooping = false;
            }
          } else {
            achieved = true;
            keepLooping = false;
          }
        }
      }

      if (achieved && currentLength > 0) {
        File(outputPath).writeAsBytesSync(currentBytes, flush: true);
        return {
          'success': true,
          'outputPath': outputPath,
          'finalSize': currentLength,
          'finalQuality': quality,
          'downsampled': !isFullResPass,
          'width': workingBitmap.width,
          'height': workingBitmap.height,
        };
      }

      // If Pass 2 still couldn't reach ultra-small target at minQuality=4 with B0(),
      // save the best effort or scale down further so the user always gets a valid file.
      if (!isFullResPass) {
        while (currentLength > targetBytes &&
            workingBitmap.width > 120 &&
            workingBitmap.height > 120) {
          workingBitmap = img.copyResize(
            workingBitmap,
            width: (workingBitmap.width * 0.75).round(),
            height: (workingBitmap.height * 0.75).round(),
          );
          currentBytes = Uint8List.fromList(
              img.encodeJpg(workingBitmap, quality: minQuality));
          currentLength = currentBytes.length;
        }
        File(outputPath).writeAsBytesSync(currentBytes, flush: true);
        return {
          'success': true,
          'outputPath': outputPath,
          'finalSize': currentLength,
          'finalQuality': minQuality,
          'downsampled': true,
          'width': workingBitmap.width,
          'height': workingBitmap.height,
        };
      }
    }

    throw Exception('Compression failed');
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _currentTabIndex = 0;
  final ImagePicker _picker = ImagePicker();

  File? _selectedFile;
  Uint8List? _selectedBytes;
  int _originalSizeBytes = 0;
  int _originalWidth = 0;
  int _originalHeight = 0;

  File? _outputFile;
  Uint8List? _outputBytes;
  int _outputSizeBytes = 0;
  int _outputWidth = 0;
  int _outputHeight = 0;
  String _statusMessage = '';
  bool _isProcessing = false;

  // Tab 1: Compress (APK Exact Algorithm)
  bool _useQualitySeek = false; // SwitchCompat f0 in MainActivity
  double _qualitySeekValue = 80; // SeekBar c0 default 80%
  final TextEditingController _compressTargetController =
      TextEditingController(text: '50');
  String _compressUnit = 'KB'; // Spinner W ('KB' or 'MB')

  // Tab 2: Increase Size
  final TextEditingController _increaseTargetController =
      TextEditingController(text: '500');
  String _increaseUnit = 'KB';

  // Tab 3: Resize Image
  String _resizeUnit = 'Pixels'; // Pixels, %, Inch, CM
  final TextEditingController _widthController = TextEditingController();
  final TextEditingController _heightController = TextEditingController();
  final TextEditingController _dpiController =
      TextEditingController(text: '300');
  bool _lockAspectRatio = true;
  bool _updatingDimensions = false;

  // Tab 4: Crop Image
  final CropController _cropController = CropController();
  double? _cropAspectRatio;
  String _selectedCropPreset = 'Free';

  @override
  void dispose() {
    _compressTargetController.dispose();
    _increaseTargetController.dispose();
    _widthController.dispose();
    _heightController.dispose();
    _dpiController.dispose();
    super.dispose();
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      final XFile? picked = await _picker.pickImage(source: source);
      if (picked == null) return;

      setState(() {
        _isProcessing = true;
        _statusMessage = 'Loading image...';
      });

      final File file = File(picked.path);
      final Uint8List bytes = await file.readAsBytes();
      final decoded = await compute(_decodeDimensionsWorker, bytes);

      setState(() {
        _selectedFile = file;
        _selectedBytes = bytes;
        _originalSizeBytes = bytes.length;
        _originalWidth = decoded['width'] ?? 0;
        _originalHeight = decoded['height'] ?? 0;

        _outputFile = null;
        _outputBytes = null;
        _outputSizeBytes = 0;
        _outputWidth = 0;
        _outputHeight = 0;
        _statusMessage = '';
        _isProcessing = false;

        _syncResizeControllersFromOriginal();
      });
    } catch (e) {
      setState(() => _isProcessing = false);
      _showSnack('Error opening image: $e');
    }
  }

  static Map<String, int> _decodeDimensionsWorker(Uint8List bytes) {
    final img.Image? image = img.decodeImage(bytes);
    if (image == null) return {'width': 0, 'height': 0};
    final baked = img.bakeOrientation(image);
    return {'width': baked.width, 'height': baked.height};
  }

  void _syncResizeControllersFromOriginal() {
    if (_originalWidth <= 0 || _originalHeight <= 0) return;
    _updatingDimensions = true;
    final double dpi = double.tryParse(_dpiController.text) ?? 300.0;
    if (_resizeUnit == 'Pixels') {
      _widthController.text = _originalWidth.toString();
      _heightController.text = _originalHeight.toString();
    } else if (_resizeUnit == '%') {
      _widthController.text = '100';
      _heightController.text = '100';
    } else if (_resizeUnit == 'Inch') {
      _widthController.text = (_originalWidth / dpi).toStringAsFixed(2);
      _heightController.text = (_originalHeight / dpi).toStringAsFixed(2);
    } else if (_resizeUnit == 'CM') {
      _widthController.text =
          ((_originalWidth / dpi) * 2.54).toStringAsFixed(2);
      _heightController.text =
          ((_originalHeight / dpi) * 2.54).toStringAsFixed(2);
    }
    _updatingDimensions = false;
  }

  void _onWidthChanged(String val) {
    if (_updatingDimensions || !_lockAspectRatio || _originalWidth <= 0) return;
    final double? w = double.tryParse(val);
    if (w == null || w <= 0) return;
    _updatingDimensions = true;
    if (_resizeUnit == '%') {
      _heightController.text = val;
    } else {
      final double ratio = _originalHeight / _originalWidth;
      final double h = w * ratio;
      _heightController.text =
          _resizeUnit == 'Pixels' ? h.round().toString() : h.toStringAsFixed(2);
    }
    _updatingDimensions = false;
  }

  void _onHeightChanged(String val) {
    if (_updatingDimensions || !_lockAspectRatio || _originalHeight <= 0) return;
    final double? h = double.tryParse(val);
    if (h == null || h <= 0) return;
    _updatingDimensions = true;
    if (_resizeUnit == '%') {
      _widthController.text = val;
    } else {
      final double ratio = _originalWidth / _originalHeight;
      final double w = h * ratio;
      _widthController.text =
          _resizeUnit == 'Pixels' ? w.round().toString() : w.toStringAsFixed(2);
    }
    _updatingDimensions = false;
  }

  String _formatSize(int bytes) {
    if (bytes <= 0) return '0 KB';
    // Matches APK's 1000.0 & 1000000.0 formatting + standard KB/MB display
    final double kb = bytes / 1000.0;
    final double mb = bytes / 1000000.0;
    if (kb < 1000) {
      return '${kb.toStringAsFixed(2)} KB';
    }
    return '${kb.toStringAsFixed(2)} KB (${mb.toStringAsFixed(2)} MB)';
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  // ==================== 1. COMPRESS IMAGE (APK EXACT LOGIC) ====================
  Future<void> _runApkCompress() async {
    if (_selectedFile == null) {
      _showSnack('Please select an image first');
      return;
    }

    double targetBytes = 0;
    if (!_useQualitySeek) {
      final double? val =
          double.tryParse(_compressTargetController.text.trim());
      if (val == null || val <= 0) {
        _showSnack('Please enter a valid target size');
        return;
      }
      // Exact APK multiplier from MainActivity.k():
      // KB -> val * 1000.0, MB -> val * 1000.0 * 1000.0
      targetBytes =
          _compressUnit == 'KB' ? val * 1000.0 : val * 1000.0 * 1000.0;

      if (targetBytes >= _originalSizeBytes) {
        _showSnack(
            'Entered value must be smaller than original image size (${_formatSize(_originalSizeBytes)})');
        return;
      }
    }

    setState(() {
      _isProcessing = true;
      _statusMessage = _useQualitySeek
          ? 'Compressing at ${_qualitySeekValue.round()}% quality...'
          : 'Running APK Iterative Compression (-1/-2/-3 step & 750px B0 fallback)...';
    });

    try {
      final dir = await getTemporaryDirectory();
      final String outPath =
          '${dir.path}/Q_${DateTime.now().millisecondsSinceEpoch}.jpg';

      final result = await ApkPhotoReducerEngine.compressWithApkAlgorithm(
        inputPath: _selectedFile!.path,
        outputPath: outPath,
        useQualitySlider: _useQualitySeek,
        sliderQuality: _qualitySeekValue.round(),
        targetBytes: targetBytes,
      );

      final File outFile = File(outPath);
      final Uint8List outBytes = await outFile.readAsBytes();

      setState(() {
        _outputFile = outFile;
        _outputBytes = outBytes;
        _outputSizeBytes = outBytes.length;
        _outputWidth = (result['width'] as int?) ?? _originalWidth;
        _outputHeight = (result['height'] as int?) ?? _originalHeight;
        final int q = (result['finalQuality'] as int?) ?? _qualitySeekValue.round();
        final bool downsampled = (result['downsampled'] as bool?) ?? false;
        _statusMessage = downsampled
            ? 'Compressed with APK B0(750px) Downsampling + Quality $q%'
            : 'Compressed at Full Resolution (Quality $q%)';
        _isProcessing = false;
      });
    } catch (e) {
      setState(() => _isProcessing = false);
      _showSnack('Compression error: $e');
    }
  }

  // ==================== 2. INCREASE IMAGE SIZE ====================
  Future<void> _runIncreaseSize() async {
    if (_selectedBytes == null) {
      _showSnack('Please select an image first');
      return;
    }
    final double? val = double.tryParse(_increaseTargetController.text.trim());
    if (val == null || val <= 0) {
      _showSnack('Please enter a valid target size');
      return;
    }
    final int targetBytes =
        (_increaseUnit == 'KB' ? val * 1000.0 : val * 1000.0 * 1000.0).round();

    if (targetBytes <= _originalSizeBytes) {
      _showSnack(
          'Target size must be larger than original size (${_formatSize(_originalSizeBytes)})');
      return;
    }

    setState(() {
      _isProcessing = true;
      _statusMessage = 'Increasing image size to ${_formatSize(targetBytes)}...';
    });

    try {
      final Uint8List resultBytes = await compute(_increaseSizeWorker, {
        'bytes': _selectedBytes!,
        'targetBytes': targetBytes,
      });

      final dir = await getTemporaryDirectory();
      final File outFile = File(
          '${dir.path}/INC_${DateTime.now().millisecondsSinceEpoch}.jpg');
      await outFile.writeAsBytes(resultBytes, flush: true);

      setState(() {
        _outputFile = outFile;
        _outputBytes = resultBytes;
        _outputSizeBytes = resultBytes.length;
        _outputWidth = _originalWidth;
        _outputHeight = _originalHeight;
        _statusMessage = 'Size increased to ${_formatSize(resultBytes.length)}';
        _isProcessing = false;
      });
    } catch (e) {
      setState(() => _isProcessing = false);
      _showSnack('Error increasing size: $e');
    }
  }

  static Uint8List _increaseSizeWorker(Map<String, dynamic> args) {
    final Uint8List inputBytes = args['bytes'] as Uint8List;
    final int targetBytes = args['targetBytes'] as int;

    img.Image? decoded = img.decodeImage(inputBytes);
    if (decoded == null) throw Exception('Cannot decode image');
    decoded = img.bakeOrientation(decoded);

    Uint8List baseJpg = Uint8List.fromList(img.encodeJpg(decoded, quality: 100));
    if (baseJpg.length >= targetBytes) {
      return baseJpg;
    }

    // Pad safely inside JPEG COM (0xFF 0xFE) comment segments before EOI (0xFF 0xD9)
    // so every gallery/viewer decodes the JPEG cleanly without corruption.
    final BytesBuilder builder = BytesBuilder();
    final int eoiIndex = (baseJpg.length >= 2 &&
            baseJpg[baseJpg.length - 2] == 0xFF &&
            baseJpg[baseJpg.length - 1] == 0xD9)
        ? baseJpg.length - 2
        : baseJpg.length;

    builder.add(baseJpg.sublist(0, eoiIndex));
    int remaining = targetBytes - eoiIndex - 2;

    while (remaining > 0) {
      if (remaining <= 4) {
        builder.add(Uint8List(remaining));
        remaining = 0;
      } else {
        // JPEG COM marker: FF FE + 2-byte big-endian length (includes the 2 length bytes)
        final int maxPayload = math.min(remaining - 4, 60000);
        final int segLen = maxPayload + 2;
        builder.addByte(0xFF);
        builder.addByte(0xFE);
        builder.addByte((segLen >> 8) & 0xFF);
        builder.addByte(segLen & 0xFF);
        builder.add(Uint8List(maxPayload));
        remaining -= (maxPayload + 4);
      }
    }

    builder.addByte(0xFF);
    builder.addByte(0xD9);
    return builder.toBytes();
  }

  // ==================== 3. RESIZE IMAGE ====================
  Future<void> _runResizeImage() async {
    if (_selectedBytes == null) {
      _showSnack('Please select an image first');
      return;
    }

    final double? wInput = double.tryParse(_widthController.text.trim());
    final double? hInput = double.tryParse(_heightController.text.trim());
    final double dpi = double.tryParse(_dpiController.text.trim()) ?? 300.0;

    if (wInput == null || hInput == null || wInput <= 0 || hInput <= 0) {
      _showSnack('Please enter valid width and height values');
      return;
    }

    int targetW = _originalWidth;
    int targetH = _originalHeight;

    if (_resizeUnit == 'Pixels') {
      targetW = wInput.round();
      targetH = hInput.round();
    } else if (_resizeUnit == '%') {
      targetW = ((_originalWidth * wInput) / 100.0).round();
      targetH = ((_originalHeight * hInput) / 100.0).round();
    } else if (_resizeUnit == 'Inch') {
      targetW = (wInput * dpi).round();
      targetH = (hInput * dpi).round();
    } else if (_resizeUnit == 'CM') {
      targetW = ((wInput / 2.54) * dpi).round();
      targetH = ((hInput / 2.54) * dpi).round();
    }

    targetW = targetW.clamp(1, 10000);
    targetH = targetH.clamp(1, 10000);

    setState(() {
      _isProcessing = true;
      _statusMessage = 'Resizing to ${targetW}x$targetH px...';
    });

    try {
      final Uint8List resizedBytes = await compute(_resizeWorker, {
        'bytes': _selectedBytes!,
        'width': targetW,
        'height': targetH,
      });

      final dir = await getTemporaryDirectory();
      final File outFile = File(
          '${dir.path}/RES_${DateTime.now().millisecondsSinceEpoch}.jpg');
      await outFile.writeAsBytes(resizedBytes, flush: true);

      setState(() {
        _outputFile = outFile;
        _outputBytes = resizedBytes;
        _outputSizeBytes = resizedBytes.length;
        _outputWidth = targetW;
        _outputHeight = targetH;
        _statusMessage = 'Resized to ${targetW}x$targetH px';
        _isProcessing = false;
      });
    } catch (e) {
      setState(() => _isProcessing = false);
      _showSnack('Resize error: $e');
    }
  }

  static Uint8List _resizeWorker(Map<String, dynamic> args) {
    final Uint8List bytes = args['bytes'] as Uint8List;
    final int width = args['width'] as int;
    final int height = args['height'] as int;

    img.Image? decoded = img.decodeImage(bytes);
    if (decoded == null) throw Exception('Cannot decode image');
    decoded = img.bakeOrientation(decoded);

    final img.Image resized = img.copyResize(
      decoded,
      width: width,
      height: height,
      interpolation: img.Interpolation.cubic,
    );
    return Uint8List.fromList(img.encodeJpg(resized, quality: 92));
  }

  // ==================== 4. SAVE & SHARE ====================
  Future<void> _saveToGallery() async {
    if (_outputFile == null) return;
    try {
      await Gal.putImage(_outputFile!.path, album: 'SmartImageTool');
      _showSnack('Saved to Gallery (Album: SmartImageTool)!');
    } catch (e) {
      _showSnack('Could not save to gallery: $e');
    }
  }

  Future<void> _shareOutput() async {
    if (_outputFile == null) return;
    await Share.shareXFiles([XFile(_outputFile!.path)]);
  }

  void _openFullScreenViewer(Uint8List bytes, String title) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => FullScreenPicViewer(imageBytes: bytes, title: title),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Smart Image Tool',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        actions: [
          IconButton(
            tooltip: 'Camera',
            onPressed: _isProcessing ? null : () => _pickImage(ImageSource.camera),
            icon: const Icon(Icons.photo_camera_outlined),
          ),
          IconButton(
            tooltip: 'Pick from Gallery',
            onPressed: _isProcessing ? null : () => _pickImage(ImageSource.gallery),
            icon: const Icon(Icons.photo_library_outlined),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_isProcessing) const LinearProgressIndicator(),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildImagePreviewCard(colorScheme),
                  const SizedBox(height: 16),
                  if (_currentTabIndex == 0) _buildCompressTab(colorScheme),
                  if (_currentTabIndex == 1) _buildIncreaseTab(colorScheme),
                  if (_currentTabIndex == 2) _buildResizeTab(colorScheme),
                  if (_currentTabIndex == 3) _buildCropTab(colorScheme),
                  if (_outputBytes != null) ...[
                    const SizedBox(height: 16),
                    _buildResultCard(colorScheme),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentTabIndex,
        onDestinationSelected: (idx) => setState(() => _currentTabIndex = idx),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.compress),
            label: 'Compress',
          ),
          NavigationDestination(
            icon: Icon(Icons.trending_up),
            label: 'Increase',
          ),
          NavigationDestination(
            icon: Icon(Icons.aspect_ratio),
            label: 'Resize',
          ),
          NavigationDestination(
            icon: Icon(Icons.crop),
            label: 'Crop',
          ),
        ],
      ),
    );
  }

  Widget _buildImagePreviewCard(ColorScheme colorScheme) {
    if (_selectedBytes == null) {
      return InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => _pickImage(ImageSource.gallery),
        child: Container(
          height: 210,
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHighest.withOpacity(0.45),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: colorScheme.outlineVariant),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.add_photo_alternate_rounded,
                  size: 56, color: colorScheme.primary),
              const SizedBox(height: 10),
              Text(
                'Tap to Select Photo from Gallery',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Or use the top camera icon to capture a photo',
                style: TextStyle(
                  fontSize: 13,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );
    }

    final Uint8List previewBytes = _outputBytes ?? _selectedBytes!;
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            GestureDetector(
              onTap: () => _openFullScreenViewer(
                previewBytes,
                _outputBytes != null ? 'Processed Image' : 'Original Image',
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 220),
                  child: Image.memory(
                    previewBytes,
                    fit: BoxFit.contain,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    'Original: ${_formatSize(_originalSizeBytes)} (${_originalWidth}x$_originalHeight)',
                    style: const TextStyle(
                        fontSize: 12.5, fontWeight: FontWeight.w600),
                  ),
                ),
                TextButton.icon(
                  onPressed: () => _pickImage(ImageSource.gallery),
                  icon: const Icon(Icons.swap_horiz, size: 18),
                  label: const Text('Change'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Tab 1: Exact UI & Controls matching `com.mobso.photoreducer.lite.MainActivity`
  Widget _buildCompressTab(ColorScheme colorScheme) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.verified_outlined,
                    size: 20, color: colorScheme.primary),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Compress Image (APK Native Engine)',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'Compress by Quality Slider (%)',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
              ),
              subtitle: Text(
                _useQualitySeek
                    ? 'Direct JPEG quality slider (like APK Switch ON)'
                    : 'Enter exact target size in KB or MB (like APK Switch OFF)',
                style: const TextStyle(fontSize: 12),
              ),
              value: _useQualitySeek,
              onChanged: (val) => setState(() => _useQualitySeek = val),
            ),
            const Divider(),
            if (_useQualitySeek) ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('JPEG Quality:',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  Text(
                    '${_qualitySeekValue.round()}%',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: colorScheme.primary,
                    ),
                  ),
                ],
              ),
              Slider(
                value: _qualitySeekValue,
                min: 1,
                max: 100,
                divisions: 99,
                label: '${_qualitySeekValue.round()}%',
                onChanged: (v) => setState(() => _qualitySeekValue = v),
              ),
            ] else ...[
              const Text(
                'Enter Target File Size:',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: TextField(
                      controller: _compressTargetController,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration: InputDecoration(
                        labelText: 'Target Size (e.g. 50)',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: DropdownButtonFormField<String>(
                      value: _compressUnit,
                      decoration: InputDecoration(
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      items: const [
                        DropdownMenuItem(value: 'KB', child: Text('KB')),
                        DropdownMenuItem(value: 'MB', child: Text('MB')),
                      ],
                      onChanged: (v) {
                        if (v != null) setState(() => _compressUnit = v);
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Uses APK step loop: 100% → -1 (>70) → -2 (>45) → -3 (≤45) + 750px B0() auto-downsampling.',
                style: TextStyle(
                    fontSize: 11.5, color: colorScheme.onSurfaceVariant),
              ),
            ],
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _isProcessing ? null : _runApkCompress,
              icon: const Icon(Icons.compress),
              label: const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('Compress Image',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Tab 2: Increase Image Size
  Widget _buildIncreaseTab(ColorScheme colorScheme) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Increase Image Size (KB / MB)',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              'Safely expands JPG file size to your exact target without corrupting the photo.',
              style:
                  TextStyle(fontSize: 12.5, color: colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: _increaseTargetController,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      labelText: 'Target Size (e.g. 500)',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: DropdownButtonFormField<String>(
                    value: _increaseUnit,
                    decoration: InputDecoration(
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    items: const [
                      DropdownMenuItem(value: 'KB', child: Text('KB')),
                      DropdownMenuItem(value: 'MB', child: Text('MB')),
                    ],
                    onChanged: (v) {
                      if (v != null) setState(() => _increaseUnit = v);
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _isProcessing ? null : _runIncreaseSize,
              icon: const Icon(Icons.trending_up),
              label: const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('Increase Size',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Tab 3: Resize Image (Pixels, %, Inch, CM)
  Widget _buildResizeTab(ColorScheme colorScheme) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Resize Image (Pixels, %, Inch, CM)',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'Pixels', label: Text('Px')),
                ButtonSegment(value: '%', label: Text('%')),
                ButtonSegment(value: 'Inch', label: Text('Inch')),
                ButtonSegment(value: 'CM', label: Text('CM')),
              ],
              selected: {_resizeUnit},
              onSelectionChanged: (set) {
                setState(() {
                  _resizeUnit = set.first;
                  _syncResizeControllersFromOriginal();
                });
              },
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _widthController,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    onChanged: _onWidthChanged,
                    decoration: InputDecoration(
                      labelText: 'Width ($_resizeUnit)',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _heightController,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    onChanged: _onHeightChanged,
                    decoration: InputDecoration(
                      labelText: 'Height ($_resizeUnit)',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            if (_resizeUnit == 'Inch' || _resizeUnit == 'CM') ...[
              const SizedBox(height: 12),
              TextField(
                controller: _dpiController,
                keyboardType: TextInputType.number,
                onChanged: (_) => _syncResizeControllersFromOriginal(),
                decoration: InputDecoration(
                  labelText: 'Print Resolution (DPI)',
                  helperText: 'Standard print resolution is 300 DPI',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ],
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Lock Aspect Ratio',
                  style: TextStyle(fontSize: 14)),
              value: _lockAspectRatio,
              onChanged: (v) {
                if (v != null) {
                  setState(() {
                    _lockAspectRatio = v;
                    if (v) _onWidthChanged(_widthController.text);
                  });
                }
              },
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _isProcessing ? null : _runResizeImage,
              icon: const Icon(Icons.aspect_ratio),
              label: const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('Apply Resize',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Tab 4: Crop Image
  Widget _buildCropTab(ColorScheme colorScheme) {
    if (_selectedBytes == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('Select an image above to start cropping.'),
        ),
      );
    }

    final presets = <String, double?>{
      'Free': null,
      '1:1 Square': 1.0,
      'Passport 3.5:4.5': 3.5 / 4.5,
      '4:3': 4.0 / 3.0,
      '16:9': 16.0 / 9.0,
    };

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Crop Image',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: presets.entries.map((entry) {
                final bool selected = _selectedCropPreset == entry.key;
                return ChoiceChip(
                  label: Text(entry.key),
                  selected: selected,
                  onSelected: (_) {
                    setState(() {
                      _selectedCropPreset = entry.key;
                      _cropAspectRatio = entry.value;
                    });
                    _cropController.aspectRatio = entry.value;
                  },
                );
              }).toList(),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 300,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: Crop(
                  image: _selectedBytes!,
                  controller: _cropController,
                  aspectRatio: _cropAspectRatio,
                  onCropped: (croppedData) async {
                    final decoded =
                        await compute(_decodeDimensionsWorker, croppedData);
                    final dir = await getTemporaryDirectory();
                    final File outFile = File(
                        '${dir.path}/CROP_${DateTime.now().millisecondsSinceEpoch}.jpg');
                    await outFile.writeAsBytes(croppedData, flush: true);

                    setState(() {
                      _outputFile = outFile;
                      _outputBytes = croppedData;
                      _outputSizeBytes = croppedData.length;
                      _outputWidth = decoded['width'] ?? 0;
                      _outputHeight = decoded['height'] ?? 0;
                      _statusMessage =
                          'Cropped (${_outputWidth}x$_outputHeight px)';
                      _isProcessing = false;
                    });
                  },
                ),
              ),
            ),
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: _isProcessing
                  ? null
                  : () {
                      setState(() {
                        _isProcessing = true;
                        _statusMessage = 'Cropping image...';
                      });
                      _cropController.crop();
                    },
              icon: const Icon(Icons.crop),
              label: const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('Crop Image',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResultCard(ColorScheme colorScheme) {
    return Card(
      elevation: 0,
      color: colorScheme.primaryContainer.withOpacity(0.35),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: colorScheme.primary.withOpacity(0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.check_circle, color: colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Compressed / Processed Output',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: colorScheme.onSurface,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'New Size: ${_formatSize(_outputSizeBytes)}  •  Dimensions: ${_outputWidth}x$_outputHeight px',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            if (_statusMessage.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                _statusMessage,
                style: TextStyle(
                    fontSize: 12.5, color: colorScheme.onSurfaceVariant),
              ),
            ],
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _saveToGallery,
                    icon: const Icon(Icons.save_alt),
                    label: const Text('Save to Gallery'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _shareOutput,
                    icon: const Icon(Icons.share),
                    label: const Text('Share'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Equivalent to `com.mobso.photoreducer.lite.PicViewer` for full-screen pinch-to-zoom preview
class FullScreenPicViewer extends StatelessWidget {
  final Uint8List imageBytes;
  final String title;

  const FullScreenPicViewer({
    super.key,
    required this.imageBytes,
    required this.title,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(title),
      ),
      body: Center(
        child: InteractiveViewer(
          minScale: 0.5,
          maxScale: 5.0,
          child: Image.memory(imageBytes),
        ),
      ),
    );
  }
}
