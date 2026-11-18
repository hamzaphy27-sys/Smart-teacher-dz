import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/theme/app_theme.dart';
import '../../data/local/app_database.dart';
import '../../data/repositories/classroom_repository.dart';
import '../../data/services/ministry_excel_service.dart';
import '../../data/services/ocr_provider.dart';
import '../../domain/models/extraction_models.dart';
import '../verification/verification_screen.dart';

class ScanScreen extends ConsumerStatefulWidget {
  final ClassRoom clazz;

  const ScanScreen({super.key, required this.clazz});

  @override
  ConsumerState<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends ConsumerState<ScanScreen> {
  final ImagePicker _picker = ImagePicker();
  final TextEditingController _apiKeyController = TextEditingController();

  File? _selectedImage;
  bool _useCloudVision = true;
  bool _cloudConsentChecked = false;
  bool _shareRosterHint = false;
  bool _autoDeletePhotoAfterCommit = true;
  bool _isProcessing = false;
  late Set<String> _selectedColumnCodes;

  List<MinistryGradeColumn> get _allColumns {
    final decoded = jsonDecode(widget.clazz.gradeColumnsJson) as List<dynamic>;
    return decoded
        .map((e) => MinistryGradeColumn.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  @override
  void initState() {
    super.initState();
    _selectedColumnCodes = _allColumns.map((c) => c.code).toSet();
    _loadTeacherDefaults();
  }

  Future<void> _loadTeacherDefaults() async {
    final db = ref.read(appDatabaseProvider);
    final profile = await db.getTeacherProfile();
    if (!mounted) return;
    setState(() {
      if (profile.geminiApiKey.isNotEmpty) {
        _apiKeyController.text = profile.geminiApiKey;
        _useCloudVision = true;
      }
      _cloudConsentChecked = profile.defaultCloudConsent;
      _autoDeletePhotoAfterCommit = profile.autoDeleteScanPhotos;
    });
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    super.dispose();
  }

  Future<void> _pickImage(ImageSource source) async {
    final picked = await _picker.pickImage(
      source: source,
      imageQuality: 92,
      maxWidth: 2200,
    );
    if (picked != null) {
      setState(() => _selectedImage = File(picked.path));
    }
  }

  Future<void> _runExtraction() async {
    if (_selectedImage == null) return;
    if (_useCloudVision) {
      if (_apiKeyController.text.trim().isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: AppTheme.bandRed,
            content: Text('يرجى إدخال مفتاح Gemini API أو التبديل إلى القراءة المحلية للأرقام.'),
          ),
        );
        return;
      }
      if (!_cloudConsentChecked) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: AppTheme.bandRed,
            content: Text('يرجى تأكيد الموافقة على شروط حماية البيانات قبل المعالجة السحابية.'),
          ),
        );
        return;
      }
    }

    setState(() => _isProcessing = true);
    try {
      final repo = ref.read(classroomRepositoryProvider);
      final db = ref.read(appDatabaseProvider);
      final dbStudents = await repo.getStudents(widget.clazz.id);
      final roster = dbStudents
          .map((s) => RosterStudent(
                matricule: s.matricule,
                officialOrder: s.officialOrder,
                lastName: s.lastName,
                firstName: s.firstName,
                birthDate: s.birthDate,
              ))
          .toList();

      final activeCols = _allColumns
          .where((c) => _selectedColumnCodes.contains(c.code))
          .toList();

      final OcrProvider provider = _useCloudVision
          ? VisionLlmOcrProvider(apiKey: _apiKeyController.text.trim())
          : OnDeviceMlKitOcrProvider();

      final bytes = await _selectedImage!.readAsBytes();
      final extraction = await provider.extractSheet(
        imageId: 'scan_${DateTime.now().millisecondsSinceEpoch}',
        imagePath: _selectedImage!.path,
        imageBytes: bytes,
        roster: roster,
        targetColumns: activeCols,
        privacy: OcrPrivacyOptions(
          cloudConsentGranted: _cloudConsentChecked,
          shareRosterNamesAsHint: _shareRosterHint,
        ),
      );

      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (ctx) => VerificationScreen(
            extraction: extraction,
            roster: roster,
            onExportReady: () async {
              final labelMap = {for (final c in activeCols) c.label: c.code};
              final saved = await repo.commitVerifiedExtraction(
                classId: widget.clazz.id,
                extraction: extraction,
                labelToCode: labelMap,
              );

              var deleted = false;
              if (_autoDeletePhotoAfterCommit && _selectedImage != null && _selectedImage!.existsSync()) {
                try {
                  await _selectedImage!.delete();
                  deleted = true;
                } catch (_) {}
              }

              await db.logScanSession(
                classId: widget.clazz.id,
                providerName: provider.name,
                rowsExtracted: extraction.rows.length,
                gradesCommitted: saved,
                photoDeleted: deleted,
              );

              if (!ctx.mounted) return;
              Navigator.of(ctx).pop();
              if (!mounted) return;
              Navigator.of(context).pop();
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  backgroundColor: AppTheme.bandGreen,
                  content: Text('تم اعتماد وحفظ $saved نقطة بنجاح وحفظ العملية في السجل'),
                ),
              );
            },
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: AppTheme.bandRed,
          content: Text('تعذرت معالجة الورقة: $e'),
        ),
      );
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cols = _allColumns;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: Text('تصوير ورقة النقاط — ${widget.clazz.displayName}'),
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  children: [
                    if (_selectedImage != null)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Image.file(
                          _selectedImage!,
                          height: 210,
                          width: double.infinity,
                          fit: BoxFit.cover,
                        ),
                      )
                    else
                      Container(
                        height: 150,
                        width: double.infinity,
                        decoration: BoxDecoration(
                          color: Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.grey.shade300),
                        ),
                        child: const Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.document_scanner_outlined, size: 48, color: Colors.grey),
                            SizedBox(height: 8),
                            Text('التقط صورة واضحة لورقة النقاط أو اخترها من المعرض'),
                          ],
                        ),
                      ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: () => _pickImage(ImageSource.camera),
                            icon: const Icon(Icons.camera_alt),
                            label: const Text('الكاميرا'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => _pickImage(ImageSource.gallery),
                            icon: const Icon(Icons.photo_library),
                            label: const Text('المعرض'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'الأعمدة الموجودة في الورقة المصورة',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: cols.map((c) {
                        final selected = _selectedColumnCodes.contains(c.code);
                        return FilterChip(
                          label: Text(c.label),
                          selected: selected,
                          onSelected: (val) {
                            setState(() {
                              if (val) {
                                _selectedColumnCodes.add(c.code);
                              } else if (_selectedColumnCodes.length > 1) {
                                _selectedColumnCodes.remove(c.code);
                              }
                            });
                          },
                        );
                      }).toList(),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'محرك التعرف وحماية المعطيات الشخصية (قانون 18-07)',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('الرؤية الذكية السحابية (قراءة الأسماء العربية + الأرقام)'),
                      subtitle: const Text(
                        'مُفعّل = قراءة شاملة لخط اليد العربي والفرنسي | مُعطّل = قراءة محلية للأرقام فقط بدون إنترنت',
                      ),
                      value: _useCloudVision,
                      onChanged: (v) => setState(() => _useCloudVision = v),
                    ),
                    if (_useCloudVision) ...[
                      TextField(
                        controller: _apiKeyController,
                        obscureText: true,
                        decoration: const InputDecoration(
                          labelText: 'مفتاح Gemini API',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                      const SizedBox(height: 8),
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        value: _cloudConsentChecked,
                        onChanged: (v) => setState(() => _cloudConsentChecked = v ?? false),
                        title: const Text(
                          'أوافق بصفتي أستاذ القسم على معالجة هذه الصورة سحابياً لغرض استخراج النقاط فقط، مع الالتزام بعدم استخدامها للتدريب.',
                          style: TextStyle(fontSize: 13),
                        ),
                      ),
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        value: _shareRosterHint,
                        onChanged: (v) => setState(() => _shareRosterHint = v ?? false),
                        title: const Text(
                          'إرسال قائمة الأسماء كمرجع لتحسين قراءة الأسماء المتشابهة (اختياري)',
                          style: TextStyle(fontSize: 13),
                        ),
                      ),
                    ],
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _autoDeletePhotoAfterCommit,
                      onChanged: (v) => setState(() => _autoDeletePhotoAfterCommit = v ?? true),
                      title: const Text(
                        'حذف صورة الورقة تلقائياً من الهاتف فور تأكيد النقاط وحفظها',
                        style: TextStyle(fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
              onPressed: (_selectedImage == null || _isProcessing) ? null : _runExtraction,
              icon: _isProcessing
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                    )
                  : const Icon(Icons.auto_awesome),
              label: Text(
                _isProcessing ? 'جاري استخراج ومطابقة النقاط...' : 'استخراج النقاط والانتقال للمراجعة',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
