import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../data/local/app_database.dart';
import '../../data/repositories/classroom_repository.dart';
import '../classes/class_detail_screen.dart';
import '../settings/teacher_settings_screen.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  bool _isImporting = false;

  Future<void> _pickAndImportMinistryExcel() async {
    setState(() => _isImporting = true);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['xlsx'],
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;

      final picked = result.files.single;
      final bytes = picked.bytes ??
          (picked.path != null ? await File(picked.path!).readAsBytes() : null);
      if (bytes == null) {
        throw const FileSystemException('تعذر قراءة بيانات الملف المختار.');
      }

      final repo = ref.read(classroomRepositoryProvider);
      final summary = await repo.importMinistryExcel(
        fileBytes: bytes,
        originalFileName: picked.name,
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: AppTheme.bandGreen,
          content: Text(
            'تم استيراد ${summary.classesImported} أفواج (${summary.totalStudents} تلميذاً) بنجاح',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: AppTheme.bandRed,
          content: Text('خطأ أثناء الاستيراد: $e'),
        ),
      );
    } finally {
      if (mounted) setState(() => _isImporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(classroomRepositoryProvider);

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('الأستاذ الذكي DZ'),
          actions: [
            IconButton(
              tooltip: 'ملف الأستاذ والإعدادات',
              icon: const Icon(Icons.settings_outlined),
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const TeacherSettingsScreen()),
                );
              },
            ),
          ],
        ),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FilledButton.icon(
                style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
                onPressed: _isImporting ? null : _pickAndImportMinistryExcel,
                icon: _isImporting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                      )
                    : const Icon(Icons.upload_file),
                label: Text(
                  _isImporting ? 'جاري تحليل ملف الوزارة...' : 'استيراد ملف الرقمنة الرسمي (.xlsx)',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'الأفواج التربوية المستوردة',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
              const SizedBox(height: 10),
              Expanded(
                child: StreamBuilder<List<ClassRoom>>(
                  stream: repo.watchClasses(),
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    final classesList = snapshot.data ?? [];
                    if (classesList.isEmpty) {
                      return Center(
                        child: Card(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: const [
                                Icon(Icons.table_chart_outlined, size: 48, color: Colors.grey),
                                SizedBox(height: 12),
                                Text(
                                  'لا توجد أفواج مستوردة بعد',
                                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                                ),
                                SizedBox(height: 6),
                                Text(
                                  'اضغط على زر "استيراد ملف الرقمنة الرسمي" لاختيار ملف Excel الخاص بالوزارة.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(color: Colors.black54),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    }

                    return ListView.separated(
                      itemCount: classesList.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (context, idx) {
                        final clazz = classesList[idx];
                        return Card(
                          margin: EdgeInsets.zero,
                          child: ListTile(
                            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                            leading: CircleAvatar(
                              backgroundColor: AppTheme.primaryGreen,
                              foregroundColor: Colors.white,
                              child: Text('${idx + 1}'),
                            ),
                            title: Text(
                              clazz.displayName,
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                            ),
                            subtitle: Text(
                              '${clazz.subjectName} • ${clazz.termName} (${clazz.academicYear})',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: const Icon(Icons.arrow_forward_ios, size: 18),
                            onTap: () {
                              Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => ClassDetailScreen(clazz: clazz),
                                ),
                              );
                            },
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
