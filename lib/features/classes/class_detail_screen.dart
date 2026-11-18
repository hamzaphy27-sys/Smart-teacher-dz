import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/theme/app_theme.dart';
import '../../data/local/app_database.dart';
import '../../data/repositories/classroom_repository.dart';
import '../../data/services/ministry_excel_service.dart';
import '../../domain/models/extraction_models.dart';
import '../../domain/logic/grade_calculator.dart';
import '../reports/bilan_trimestriel_screen.dart';
import '../scan/scan_screen.dart';

class ClassDetailScreen extends ConsumerStatefulWidget {
  final ClassRoom clazz;

  const ClassDetailScreen({super.key, required this.clazz});

  @override
  ConsumerState<ClassDetailScreen> createState() => _ClassDetailScreenState();
}

class _ClassDetailScreenState extends ConsumerState<ClassDetailScreen> {
  String _searchQuery = '';
  bool _isExporting = false;

  List<MinistryGradeColumn> get _gradeColumns {
    final decoded = jsonDecode(widget.clazz.gradeColumnsJson) as List<dynamic>;
    return decoded
        .map((e) => MinistryGradeColumn.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> _exportExcel() async {
    setState(() => _isExporting = true);
    try {
      final repo = ref.read(classroomRepositoryProvider);
      final file = await repo.exportClassToMinistryExcel(widget.clazz.id);
      if (!mounted) return;
      await Share.shareXFiles(
        [XFile(file.path)],
        text: 'ملف حجز النقاط - ${widget.clazz.displayName}',
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذر التصدير: $e'), backgroundColor: AppTheme.bandRed),
      );
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  Future<void> _showScanHistorySheet() async {
    final db = ref.read(appDatabaseProvider);
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'سجل عمليات المسح السابقة',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 10),
              Expanded(
                child: StreamBuilder<List<ScanSession>>(
                  stream: db.watchScanSessionsForClass(widget.clazz.id),
                  builder: (context, snap) {
                    final sessions = snap.data ?? [];
                    if (sessions.isEmpty) {
                      return const Center(child: Text('لا توجد عمليات مسح مسجلة لهذا الفوج بعد.'));
                    }
                    return ListView.builder(
                      itemCount: sessions.length,
                      itemBuilder: (_, i) {
                        final s = sessions[i];
                        return ListTile(
                          leading: const Icon(Icons.history, color: AppTheme.primaryGreen),
                          title: Text('تم حفظ ${s.gradesCommitted} نقطة (${s.rowsExtracted} سطر)'),
                          subtitle: Text('${s.providerName} • ${s.createdAt.toLocal().toString().split(".").first}'),
                          trailing: Icon(
                            s.photoDeleted ? Icons.verified_user : Icons.image_outlined,
                            color: s.photoDeleted ? AppTheme.bandGreen : Colors.grey,
                            size: 18,
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

  Future<void> _editStudentGradesDialog(
    Student student,
    Map<String, StudentGrade> currentGrades,
  ) async {
    final cols = _gradeColumns;
    final controllers = <String, TextEditingController>{};
    final absentFlags = <String, bool>{};

    for (final c in cols) {
      final existing = currentGrades[c.code];
      absentFlags[c.code] = existing?.status == 'absent';
      controllers[c.code] = TextEditingController(
        text: existing?.numericValue != null ? existing!.numericValue.toString() : '',
      );
    }

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => Directionality(
          textDirection: TextDirection.rtl,
          child: AlertDialog(
            title: Text('${student.officialOrder}. ${student.lastName} ${student.firstName}'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: cols.map((c) {
                  final isAbs = absentFlags[c.code] ?? false;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: controllers[c.code],
                            enabled: !isAbs,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            decoration: InputDecoration(
                              labelText: c.label,
                              border: const OutlineInputBorder(),
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilterChip(
                          label: const Text('غائب'),
                          selected: isAbs,
                          onSelected: (val) {
                            setDialogState(() {
                              absentFlags[c.code] = val;
                              if (val) controllers[c.code]!.clear();
                            });
                          },
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('إلغاء'),
              ),
              FilledButton(
                onPressed: () async {
                  final repo = ref.read(classroomRepositoryProvider);
                  for (final c in cols) {
                    final isAbs = absentFlags[c.code] ?? false;
                    final raw = controllers[c.code]!.text.replaceAll(',', '.').trim();
                    if (isAbs) {
                      await repo.saveManualGrade(
                        classId: widget.clazz.id,
                        matricule: student.matricule,
                        columnCode: c.code,
                        status: 'absent',
                        numericValue: null,
                      );
                    } else if (raw.isEmpty) {
                      await repo.saveManualGrade(
                        classId: widget.clazz.id,
                        matricule: student.matricule,
                        columnCode: c.code,
                        status: 'missing',
                        numericValue: null,
                      );
                    } else {
                      final parsed = double.tryParse(raw);
                      if (parsed != null && parsed >= 0 && parsed <= 20) {
                        await repo.saveManualGrade(
                          classId: widget.clazz.id,
                          matricule: student.matricule,
                          columnCode: c.code,
                          status: 'value',
                          numericValue: parsed,
                        );
                      }
                    }
                  }
                  if (ctx.mounted) Navigator.pop(ctx);
                },
                child: const Text('حفظ'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(classroomRepositoryProvider);
    final cols = _gradeColumns;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: FutureBuilder<List<Student>>(
        future: repo.getStudents(widget.clazz.id),
        builder: (context, studentSnap) {
          final allStudents = studentSnap.data ?? [];
          final filteredStudents = _searchQuery.trim().isEmpty
              ? allStudents
              : allStudents.where((s) {
                  final full = '${s.lastName} ${s.firstName} ${s.matricule}';
                  return full.contains(_searchQuery.trim());
                }).toList();

          return Scaffold(
            appBar: AppBar(
              title: Text(widget.clazz.displayName),
              actions: [
                IconButton(
                  tooltip: 'الحصيلة الفصلية الذكية',
                  icon: const Icon(Icons.analytics_outlined),
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => BilanTrimestrielScreen(clazz: widget.clazz),
                      ),
                    );
                  },
                ),
                IconButton(
                  tooltip: 'سجل عمليات المسح السابقة',
                  icon: const Icon(Icons.history),
                  onPressed: _showScanHistorySheet,
                ),
                IconButton(
                  tooltip: 'تصدير ملف الوزارة Excel',
                  icon: _isExporting
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                        )
                      : const Icon(Icons.ios_share),
                  onPressed: _isExporting ? null : _exportExcel,
                ),
              ],
            ),
            floatingActionButton: FloatingActionButton.extended(
              backgroundColor: AppTheme.primaryGreen,
              foregroundColor: Colors.white,
              icon: const Icon(Icons.document_scanner),
              label: const Text('تصوير ورقة النقاط'),
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ScanScreen(clazz: widget.clazz),
                  ),
                );
              },
            ),
            body: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: TextField(
                    decoration: InputDecoration(
                      hintText: 'بحث باللقب أو الاسم أو رقم التعريف...',
                      prefixIcon: const Icon(Icons.search),
                      filled: true,
                      fillColor: Colors.white,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    onChanged: (v) => setState(() => _searchQuery = v),
                  ),
                ),
                Expanded(
                  child: StreamBuilder<List<StudentGrade>>(
                    stream: repo.watchGrades(widget.clazz.id),
                    builder: (context, gradeSnap) {
                      final gradeMap = <String, Map<String, StudentGrade>>{};
                      for (final g in gradeSnap.data ?? <StudentGrade>[]) {
                        gradeMap.putIfAbsent(g.matricule, () => {})[g.columnCode] = g;
                      }

                      if (studentSnap.connectionState == ConnectionState.waiting) {
                        return const Center(child: CircularProgressIndicator());
                      }

                      return ListView.separated(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                        itemCount: filteredStudents.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (context, idx) {
                          final st = filteredStudents[idx];
                          final stGrades = gradeMap[st.matricule] ?? {};
                          final calc = MinistryGradeCalculator.computeStudentAverage(
                            gradesByCode: stGrades,
                            columns: cols,
                            config: GradingFormulaConfig.inferFromColumns(cols),
                          );

                          return Card(
                            margin: EdgeInsets.zero,
                            child: ListTile(
                              onTap: () => _editStudentGradesDialog(st, stGrades),
                              leading: CircleAvatar(
                                backgroundColor: AppTheme.primaryGreen.withValues(alpha: 0.12),
                                child: Text(
                                  '${st.officialOrder}',
                                  style: const TextStyle(
                                    color: AppTheme.primaryGreen,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              title: Text(
                                '${st.lastName} ${st.firstName}',
                                style: const TextStyle(fontWeight: FontWeight.bold),
                              ),
                              subtitle: Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: Wrap(
                                  spacing: 6,
                                  runSpacing: 4,
                                  children: cols.map((c) {
                                    final g = stGrades[c.code];
                                    String labelVal = '—';
                                    Color chipBg = Colors.grey.shade100;
                                    if (g != null) {
                                      if (g.status == 'absent') {
                                        labelVal = 'غائب';
                                        chipBg = AppTheme.bandOrange.withValues(alpha: 0.15);
                                      } else if (g.status == 'value' && g.numericValue != null) {
                                        labelVal = '${g.numericValue}';
                                        chipBg = AppTheme.bandGreen.withValues(alpha: 0.15);
                                      }
                                    }
                                    return Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                      decoration: BoxDecoration(
                                        color: chipBg,
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Text(
                                        '${c.label.split('/').first.trim()}: $labelVal',
                                        style: const TextStyle(fontSize: 12),
                                      ),
                                    );
                                  }).toList(),
                                ),
                              ),
                              trailing: calc.termAvg != null
                                  ? Chip(
                                      label: Text(
                                        '${calc.termAvg}',
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                          color: calc.termAvg! >= 10
                                              ? AppTheme.bandGreen
                                              : AppTheme.bandRed,
                                        ),
                                      ),
                                    )
                                  : const Icon(Icons.edit_outlined, size: 20),
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
