import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';
import '../../core/theme/app_theme.dart';
import '../../data/services/backup_service.dart';
import '../../data/repositories/classroom_repository.dart';

class TeacherSettingsScreen extends ConsumerStatefulWidget {
  const TeacherSettingsScreen({super.key});

  @override
  ConsumerState<TeacherSettingsScreen> createState() => _TeacherSettingsScreenState();
}

class _TeacherSettingsScreenState extends ConsumerState<TeacherSettingsScreen> {
  final _nameCtrl = TextEditingController();
  final _schoolCtrl = TextEditingController();
  final _wilayaCtrl = TextEditingController();
  final _subjectCtrl = TextEditingController();
  final _yearCtrl = TextEditingController(text: '2025-2026');
  final _apiKeyCtrl = TextEditingController();

  bool _defaultCloudConsent = false;
  bool _autoDeletePhotos = true;
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    final db = ref.read(appDatabaseProvider);
    final profile = await db.getTeacherProfile();
    if (!mounted) return;
    setState(() {
      _nameCtrl.text = profile.fullName;
      _schoolCtrl.text = profile.schoolName;
      _wilayaCtrl.text = profile.wilaya;
      _subjectCtrl.text = profile.subjectName;
      _yearCtrl.text = profile.academicYear.isNotEmpty ? profile.academicYear : '2025-2026';
      _apiKeyCtrl.text = profile.geminiApiKey;
      _defaultCloudConsent = profile.defaultCloudConsent;
      _autoDeletePhotos = profile.autoDeleteScanPhotos;
      _loading = false;
    });
  }

  Future<void> _saveProfile() async {
    setState(() => _saving = true);
    try {
      final db = ref.read(appDatabaseProvider);
      await db.saveTeacherProfile(
        fullName: _nameCtrl.text,
        schoolName: _schoolCtrl.text,
        wilaya: _wilayaCtrl.text,
        subjectName: _subjectCtrl.text,
        academicYear: _yearCtrl.text,
        geminiApiKey: _apiKeyCtrl.text,
        defaultCloudConsent: _defaultCloudConsent,
        autoDeleteScanPhotos: _autoDeletePhotos,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: AppTheme.bandGreen,
          content: Text('تم حفظ بيانات الأستاذ والإعدادات محلياً بنجاح'),
        ),
      );
      Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }


  Future<void> _exportBackup() async {
    final db = ref.read(appDatabaseProvider);
    final file = await BackupService.exportBackupFile(db);
    if (!mounted) return;
    await Share.shareXFiles([XFile(file.path)], text: 'نسخة احتياطية - الأستاذ الذكي DZ');
  }

  Future<void> _restoreBackup() async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
      withData: true,
    );
    if (res == null || res.files.isEmpty) return;
    final picked = res.files.single;
    final raw = picked.bytes != null
        ? utf8.decode(picked.bytes!)
        : (picked.path != null ? await File(picked.path!).readAsString() : '');
    if (raw.isEmpty) return;

    final db = ref.read(appDatabaseProvider);
    final summary = await BackupService.restoreFromJson(db, raw);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: AppTheme.bandGreen,
        content: Text(
          'تم استرجاع ${summary.classesRestored} أفواج و${summary.studentsRestored} تلميذاً و${summary.gradesRestored} نقطة',
        ),
      ),
    );
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _schoolCtrl.dispose();
    _wilayaCtrl.dispose();
    _subjectCtrl.dispose();
    _yearCtrl.dispose();
    _apiKeyCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('ملف الأستاذ والإعدادات'),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'المعلومات المهنية (تُدرج في تقارير PDF)',
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _nameCtrl,
                            decoration: const InputDecoration(
                              labelText: 'الاسم الكامل للأستاذ(ة)',
                              prefixIcon: Icon(Icons.person_outline),
                              border: OutlineInputBorder(),
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _schoolCtrl,
                            decoration: const InputDecoration(
                              labelText: 'المؤسسة التربوية (متوسطة / ثانوية)',
                              prefixIcon: Icon(Icons.school_outlined),
                              border: OutlineInputBorder(),
                            ),
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _wilayaCtrl,
                                  decoration: const InputDecoration(
                                    labelText: 'الولاية',
                                    border: OutlineInputBorder(),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: TextField(
                                  controller: _yearCtrl,
                                  decoration: const InputDecoration(
                                    labelText: 'السنة الدراسية',
                                    border: OutlineInputBorder(),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _subjectCtrl,
                            decoration: const InputDecoration(
                              labelText: 'المادة المُدرَّسة',
                              prefixIcon: Icon(Icons.science_outlined),
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'إعدادات التعرف البصري والخصوصية (قانون 18-07)',
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                          ),
                          const SizedBox(height: 10),
                          TextField(
                            controller: _apiKeyCtrl,
                            obscureText: true,
                            decoration: const InputDecoration(
                              labelText: 'مفتاح Gemini API (يُحفظ على جهازك فقط)',
                              prefixIcon: Icon(Icons.key_outlined),
                              border: OutlineInputBorder(),
                            ),
                          ),
                          const SizedBox(height: 8),
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('حذف صور الأوراق تلقائياً بعد اعتماد النقاط'),
                            subtitle: const Text('يضمن عدم بقاء صور التلاميذ في ذاكرة الهاتف'),
                            value: _autoDeletePhotos,
                            onChanged: (v) => setState(() => _autoDeletePhotos = v),
                          ),
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('تفعيل خيار الذكاء الاصطناعي السحابي افتراضياً'),
                            value: _defaultCloudConsent,
                            onChanged: (v) => setState(() => _defaultCloudConsent = v),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'النسخ الاحتياطي واسترجاع البيانات',
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'احفظ نسخة احتياطية كاملة من أقسامك ونقاطك لمشاركتها أو استرجاعها على أي هاتف آخر.',
                            style: TextStyle(fontSize: 12.5, color: Colors.black54),
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: _exportBackup,
                                  icon: const Icon(Icons.backup_outlined),
                                  label: const Text('تصدير نسخة'),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: _restoreBackup,
                                  icon: const Icon(Icons.restore),
                                  label: const Text('استرجاع نسخة'),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 15)),
                    onPressed: _saving ? null : _saveProfile,
                    icon: const Icon(Icons.save),
                    label: const Text('حفظ الإعدادات', style: TextStyle(fontSize: 16)),
                  ),
                ],
              ),
      ),
    );
  }
}
