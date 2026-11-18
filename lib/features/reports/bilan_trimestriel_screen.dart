import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:printing/printing.dart';

import '../../core/theme/app_theme.dart';
import '../../data/local/app_database.dart';
import '../../data/repositories/classroom_repository.dart';
import '../../data/services/bilan_pdf_service.dart';
import '../../data/services/ministry_excel_service.dart';
import '../../domain/logic/grade_calculator.dart';

class BilanTrimestrielScreen extends ConsumerStatefulWidget {
  final ClassRoom clazz;

  const BilanTrimestrielScreen({super.key, required this.clazz});

  @override
  ConsumerState<BilanTrimestrielScreen> createState() => _BilanTrimestrielScreenState();
}

class _BilanTrimestrielScreenState extends ConsumerState<BilanTrimestrielScreen> {
  FormulaPreset? _selectedPreset;
  bool _isGeneratingPdf = false;

  List<MinistryGradeColumn> get _gradeColumns {
    final decoded = jsonDecode(widget.clazz.gradeColumnsJson) as List<dynamic>;
    return decoded
        .map((e) => MinistryGradeColumn.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  GradingFormulaConfig get _activeConfig {
    final inferred = GradingFormulaConfig.inferFromColumns(_gradeColumns);
    if (_selectedPreset == null) return inferred;
    return GradingFormulaConfig(preset: _selectedPreset!);
  }

  Future<void> _exportPdf(ClassBilanReport report) async {
    setState(() => _isGeneratingPdf = true);
    try {
      final teacher = await ref.read(appDatabaseProvider).getTeacherProfile();
      final bytes = await BilanPdfService.generateClassBilanPdf(
        clazz: widget.clazz,
        report: report,
        formulaConfig: _activeConfig,
        teacher: teacher,
      );
      if (!mounted) return;
      await Printing.sharePdf(
        bytes: bytes,
        filename: 'الحصيلة_الفصلية_${widget.clazz.displayName}.pdf',
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذر توليد ملف PDF: $e'), backgroundColor: AppTheme.bandRed),
      );
    } finally {
      if (mounted) setState(() => _isGeneratingPdf = false);
    }
  }

  Future<void> _approveAllSuggestedComments(ClassBilanReport report) async {
    final cols = _gradeColumns;
    if (cols.isEmpty) return;
    final repo = ref.read(classroomRepositoryProvider);
    var count = 0;

    for (final r in report.studentResults) {
      if (r.termAverage != null && (r.savedObservation == null || r.savedObservation!.isEmpty)) {
        await repo.saveStudentObservation(
          classId: widget.clazz.id,
          matricule: r.student.matricule,
          primaryColumnCode: cols.first.code,
          observation: r.suggestedComment,
        );
        count++;
      }
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: AppTheme.bandGreen,
        content: Text('تم اعتماد وحفظ $count تقدير تربوي في قاعدة البيانات'),
      ),
    );
  }

  Future<void> _editObservationDialog(StudentTermResult item) async {
    final cols = _gradeColumns;
    if (cols.isEmpty) return;
    final controller = TextEditingController(
      text: item.savedObservation ?? item.suggestedComment,
    );

    await showDialog<void>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: Text('تقدير: ${item.student.lastName} ${item.student.firstName}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'المعدل المحسوب: ${item.termAverage ?? "—"} / 20',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: controller,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'التقدير التربوي (يُصدَّر لعمود التقديرات)',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () async {
                final repo = ref.read(classroomRepositoryProvider);
                await repo.saveStudentObservation(
                  classId: widget.clazz.id,
                  matricule: item.student.matricule,
                  primaryColumnCode: cols.first.code,
                  observation: controller.text,
                );
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('اعتماد وحفظ'),
            ),
          ],
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
          final students = studentSnap.data ?? [];
          return StreamBuilder<List<StudentGrade>>(
            stream: repo.watchGrades(widget.clazz.id),
            builder: (context, gradeSnap) {
              final grades = gradeSnap.data ?? [];
              final report = MinistryGradeCalculator.buildClassReport(
                students: students,
                allGrades: grades,
                columns: cols,
                config: _activeConfig,
              );

              return Scaffold(
                appBar: AppBar(
                  title: const Text('الحصيلة الفصلية الذكية'),
                  actions: [
                    IconButton(
                      tooltip: 'تصدير تقرير PDF',
                      icon: _isGeneratingPdf
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                            )
                          : const Icon(Icons.picture_as_pdf),
                      onPressed: _isGeneratingPdf ? null : () => _exportPdf(report),
                    ),
                  ],
                ),
                body: ListView(
                  padding: const EdgeInsets.all(14),
                  children: [
                    // 1. Formula Selector Card
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'صيغة حساب المعدل الوزارية',
                              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                            ),
                            const SizedBox(height: 8),
                            DropdownButtonFormField<FormulaPreset>(
                              value: _activeConfig.preset,
                              isExpanded: true,
                              decoration: const InputDecoration(
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                              items: const [
                                DropdownMenuItem(
                                  value: FormulaPreset.standardSingleDevoir,
                                  child: Text('المتوسط / الثانوي العادي (فرض واحد)'),
                                ),
                                DropdownMenuItem(
                                  value: FormulaPreset.secondaryTwoDevoirs,
                                  child: Text('الثانوي (مادة بفرضين)'),
                                ),
                                DropdownMenuItem(
                                  value: FormulaPreset.secondaryWithTp,
                                  child: Text('الثانوي (أعمال تطبيقية TP)'),
                                ),
                              ],
                              onChanged: (val) {
                                if (val != null) setState(() => _selectedPreset = val);
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),

                    // 2. KPI Metrics Grid
                    GridView.count(
                      crossAxisCount: 2,
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                      childAspectRatio: 2.1,
                      children: [
                        _statCard('معدل القسم', '${report.classAverage ?? "—"} / 20', AppTheme.primaryGreen),
                        _statCard('نسبة النجاح', '${report.passRatePercent ?? "—"} %', AppTheme.bandGreen),
                        _statCard('الناجحون / المتعثرون', '${report.passedCount} / ${report.failedCount}', Colors.blueGrey),
                        _statCard('أعلى / أدنى معدل', '${report.highestAverage ?? "—"} / ${report.lowestAverage ?? "—"}', AppTheme.accentGold),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // 3. Distribution Card
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'توزيع مستويات التلاميذ',
                              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              runSpacing: 6,
                              children: [
                                _tierChip('امتياز (≥16)', report.distribution.excellent, AppTheme.bandGreen),
                                _tierChip('جيد جداً (14-16)', report.distribution.veryGood, Colors.teal),
                                _tierChip('جيد (12-14)', report.distribution.good, Colors.blue),
                                _tierChip('متوسط (10-12)', report.distribution.average, Colors.indigo),
                                _tierChip('دون المتوسط (8-10)', report.distribution.belowAvg, AppTheme.bandOrange),
                                _tierChip('ضعيف (<8)', report.distribution.weak, AppTheme.bandRed),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),

                    // 4. Smart Pedagogical Comments Header
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'المعدلات والتقديرات المقترحة',
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                          ),
                        ),
                        FilledButton.tonalIcon(
                          onPressed: () => _approveAllSuggestedComments(report),
                          icon: const Icon(Icons.auto_fix_high, size: 18),
                          label: const Text('اعتماد الكل'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),

                    // 5. Student Results List
                    ...report.studentResults.map((item) {
                      final isApproved = item.savedObservation != null && item.savedObservation!.isNotEmpty;
                      final commentText = isApproved ? item.savedObservation! : item.suggestedComment;
                      final avgColor = item.termAverage == null
                          ? Colors.grey
                          : (item.isPassing ? AppTheme.bandGreen : AppTheme.bandRed);

                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          onTap: () => _editObservationDialog(item),
                          leading: CircleAvatar(
                            backgroundColor: avgColor.withValues(alpha: 0.15),
                            child: Text(
                              item.termAverage != null ? '${item.termAverage}' : '—',
                              style: TextStyle(
                                color: avgColor,
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                              ),
                            ),
                          ),
                          title: Text(
                            '${item.student.officialOrder}. ${item.student.lastName} ${item.student.firstName}',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          subtitle: Row(
                            children: [
                              Icon(
                                isApproved ? Icons.check_circle : Icons.lightbulb_outline,
                                size: 15,
                                color: isApproved ? AppTheme.bandGreen : AppTheme.bandOrange,
                              ),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  commentText,
                                  style: TextStyle(
                                    color: isApproved ? Colors.black87 : Colors.black54,
                                    fontStyle: isApproved ? FontStyle.normal : FontStyle.italic,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          trailing: const Icon(Icons.edit_note),
                        ),
                      );
                    }),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  Widget _statCard(String title, String value, Color accent) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontSize: 12, color: Colors.black54)),
            const SizedBox(height: 4),
            Text(
              value,
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: accent),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tierChip(String label, int count, Color color) {
    return Chip(
      backgroundColor: color.withValues(alpha: 0.12),
      label: Text(
        '$label: $count',
        style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 12),
      ),
    );
  }
}
