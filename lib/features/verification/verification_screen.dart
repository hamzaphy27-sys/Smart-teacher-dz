import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../../core/theme/app_theme.dart';
import '../../domain/logic/export_gate.dart';
import '../../domain/models/extraction_models.dart';

/// Interactive verification screen:
/// Displays the original image crop of each student row beside the recognized name,
/// confidence badge, and editable grade chips. Blocks export until [ExportGateService] passes.
class VerificationScreen extends StatefulWidget {
  final SheetExtraction extraction;
  final List<RosterStudent> roster;
  final VoidCallback onExportReady;

  const VerificationScreen({
    super.key,
    required this.extraction,
    required this.roster,
    required this.onExportReady,
  });

  @override
  State<VerificationScreen> createState() => _VerificationScreenState();
}

class _VerificationScreenState extends State<VerificationScreen> {
  late Map<String, RosterStudent> _rosterByMat;
  ui.Image? _decodedSheetImage;

  @override
  void initState() {
    super.initState();
    _rosterByMat = {for (final s in widget.roster) s.matricule: s};
    _loadSheetImage();
  }

  Future<void> _loadSheetImage() async {
    final path = widget.extraction.imagePath;
    if (path.isEmpty) return;
    final file = File(path);
    if (!file.existsSync()) return;
    final bytes = await file.readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    if (mounted) {
      setState(() => _decodedSheetImage = frame.image);
    }
  }

  @override
  void dispose() {
    _decodedSheetImage?.dispose();
    super.dispose();
  }

  Color _bandColor(ConfidenceBand band) {
    switch (band) {
      case ConfidenceBand.green:
        return AppTheme.bandGreen;
      case ConfidenceBand.orange:
        return AppTheme.bandOrange;
      case ConfidenceBand.red:
        return AppTheme.bandRed;
    }
  }

  void _acceptAllGreen() {
    setState(() {
      for (final r in widget.extraction.rows) {
        if (r.band == ConfidenceBand.green &&
            r.suggestedMatricule != null &&
            r.verification == VerificationStatus.unverified) {
          r.confirmedMatricule = r.suggestedMatricule;
          r.verification = VerificationStatus.confirmed;
          for (final g in r.grades) {
            g.verification = VerificationStatus.confirmed;
          }
        }
      }
    });
  }

  Future<void> _pickStudentFromRosterDialog(ExtractedRow row) async {
    final assignedByOthers = widget.extraction.rows
        .where((other) => other.rowIndex != row.rowIndex && other.verification != VerificationStatus.rejected)
        .map((other) => ExportGateService.resolvedMatricule(other))
        .whereType<String>()
        .toSet();

    var query = '';
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) {
          final filtered = widget.roster.where((s) {
            if (query.trim().isEmpty) return true;
            return s.fullName.contains(query.trim()) || s.matricule.contains(query.trim());
          }).toList();

          return Directionality(
            textDirection: TextDirection.rtl,
            child: AlertDialog(
              title: const Text('اختيار التلميذ من القائمة الرسمية'),
              content: SizedBox(
                width: double.maxFinite,
                height: 360,
                child: Column(
                  children: [
                    TextField(
                      decoration: const InputDecoration(
                        hintText: 'ابحث باللقب أو الاسم...',
                        prefixIcon: Icon(Icons.search),
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      onChanged: (v) => setDlgState(() => query = v),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: ListView.builder(
                        itemCount: filtered.length,
                        itemBuilder: (_, i) {
                          final st = filtered[i];
                          final alreadyUsed = assignedByOthers.contains(st.matricule);
                          return ListTile(
                            dense: true,
                            enabled: !alreadyUsed,
                            title: Text('${st.officialOrder}. ${st.fullName}'),
                            subtitle: alreadyUsed
                                ? const Text('مُعيّن لسطر آخر', style: TextStyle(color: AppTheme.bandRed))
                                : null,
                            onTap: () {
                              setState(() {
                                row.confirmedMatricule = st.matricule;
                                row.verification = VerificationStatus.corrected;
                              });
                              Navigator.pop(ctx);
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
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final gate = ExportGateService.evaluate(widget.extraction);
    final greenPending = widget.extraction.rows
        .where((r) =>
            r.band == ConfidenceBand.green &&
            r.verification == VerificationStatus.unverified)
        .length;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('مراجعة وتأكيد النقاط'),
          actions: [
            if (greenPending > 0)
              TextButton.icon(
                onPressed: _acceptAllGreen,
                icon: const Icon(Icons.done_all, color: Colors.white),
                label: Text(
                  'تأكيد المؤكد ($greenPending)',
                  style: const TextStyle(color: Colors.white),
                ),
              ),
          ],
        ),
        body: ListView.builder(
          padding: const EdgeInsets.all(12),
          itemCount: widget.extraction.rows.length,
          itemBuilder: (context, idx) {
            final row = widget.extraction.rows[idx];
            if (row.verification == VerificationStatus.rejected) {
              return Card(
                color: Colors.grey.shade200,
                child: ListTile(
                  title: Text('سطر #${row.rowIndex + 1} مستبعد (${row.rawNameText})'),
                  trailing: TextButton(
                    onPressed: () => setState(() => row.verification = VerificationStatus.unverified),
                    child: const Text('تراجع'),
                  ),
                ),
              );
            }

            final borderColor = _bandColor(row.band);
            final matchedStudent = row.confirmedMatricule != null
                ? _rosterByMat[row.confirmedMatricule]
                : (row.suggestedMatricule != null
                    ? _rosterByMat[row.suggestedMatricule]
                    : null);

            return Card(
              margin: const EdgeInsets.only(bottom: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: borderColor, width: 2.5),
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 1. Original image row crop (Row Alignment Protection)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        height: 54,
                        width: double.infinity,
                        color: Colors.grey.shade100,
                        child: _decodedSheetImage != null
                            ? CustomPaint(
                                painter: _RowCropPainter(
                                  image: _decodedSheetImage!,
                                  box: row.rowBbox,
                                ),
                              )
                            : Center(
                                child: Text(
                                  'النص المقروء من الورقة: "${row.rawNameText}"',
                                  style: const TextStyle(fontWeight: FontWeight.w600),
                                ),
                              ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    // 2. Matched Student Row + Roster Picker
                    Row(
                      children: [
                        Icon(
                          row.verification == VerificationStatus.confirmed ||
                                  row.verification == VerificationStatus.corrected
                              ? Icons.verified
                              : Icons.person_search,
                          color: borderColor,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: InkWell(
                            onTap: () => _pickStudentFromRosterDialog(row),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  matchedStudent?.fullName ?? 'تلميذ غير محدد — اضغط للاختيار',
                                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                                ),
                                Text(
                                  'المقروء: "${row.rawNameText}" (اضغط لتغيير التلميذ)',
                                  style: const TextStyle(fontSize: 12, color: Colors.black54),
                                ),
                              ],
                            ),
                          ),
                        ),
                        if (row.suggestedMatricule != null &&
                            row.verification == VerificationStatus.unverified)
                          FilledButton.tonal(
                            onPressed: () {
                              setState(() {
                                row.confirmedMatricule = row.suggestedMatricule;
                                row.verification = VerificationStatus.confirmed;
                              });
                            },
                            child: const Text('تأكيد'),
                          ),
                        IconButton(
                          tooltip: 'استبعاد السطر',
                          icon: const Icon(Icons.close, size: 18, color: Colors.grey),
                          onPressed: () => setState(() => row.verification = VerificationStatus.rejected),
                        ),
                      ],
                    ),
                    const Divider(height: 18),
                    // 3. Extracted Grade Chips
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: row.grades.map((g) {
                        final gColor = _bandColor(g.band);
                        final displayVal = g.effectiveStatus == GradeStatus.value
                            ? '${g.effectiveValue}'
                            : (g.effectiveStatus == GradeStatus.absent ? 'غائب' : g.effectiveStatus.name);
                        return InputChip(
                          avatar: CircleAvatar(backgroundColor: gColor, radius: 6),
                          label: Text('${g.columnLabel}: $displayVal'),
                          selected: g.verification == VerificationStatus.confirmed ||
                              g.verification == VerificationStatus.corrected,
                          onPressed: () => _showGradeEditDialog(row, g),
                        );
                      }).toList(),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: FilledButton.icon(
              onPressed: gate.ok ? widget.onExportReady : null,
              icon: Icon(gate.ok ? Icons.check_circle : Icons.lock),
              label: Text(
                gate.ok
                    ? 'اعتماد وحفظ النقاط في الفوج'
                    : 'الحفظ مقفل (${gate.blockers.length} عناصر تحتاج مراجعة)',
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showGradeEditDialog(ExtractedRow row, ExtractedGrade grade) async {
    final controller = TextEditingController(
      text: grade.effectiveValue != null ? grade.effectiveValue.toString() : '',
    );
    await showDialog<void>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: Text('تعديل نقطة: ${grade.columnLabel}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (grade.candidates.length > 1)
                Wrap(
                  spacing: 6,
                  children: grade.candidates
                      .where((c) => c.value != null)
                      .map((c) => ActionChip(
                            label: Text('${c.value}'),
                            onPressed: () {
                              controller.text = '${c.value}';
                            },
                          ))
                      .toList(),
                ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: 'النقطة المؤكدة (/20)',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                setState(() {
                  grade.finalStatus = GradeStatus.absent;
                  grade.finalValue = null;
                  grade.verification = VerificationStatus.corrected;
                });
                Navigator.pop(ctx);
              },
              child: const Text('غائب (غ)'),
            ),
            FilledButton(
              onPressed: () {
                final v = double.tryParse(controller.text.replaceAll(',', '.').trim());
                if (v != null && v >= 0 && v <= 20) {
                  setState(() {
                    grade.finalStatus = GradeStatus.value;
                    grade.finalValue = v;
                    grade.verification = VerificationStatus.corrected;
                  });
                  Navigator.pop(ctx);
                }
              },
              child: const Text('حفظ وتأكيد'),
            ),
          ],
        ),
      ),
    );
  }
}

class _RowCropPainter extends CustomPainter {
  final ui.Image image;
  final NormalizedBox box;

  const _RowCropPainter({required this.image, required this.box});

  @override
  void paint(Canvas canvas, Size size) {
    final w = image.width.toDouble();
    final h = image.height.toDouble();
    final src = Rect.fromLTRB(
      (box.x0 * w).clamp(0.0, w),
      (box.y0 * h).clamp(0.0, h),
      (box.x1 * w).clamp(0.0, w),
      (box.y1 * h).clamp(0.0, h),
    );
    final dst = Rect.fromLTWH(0, 0, size.width, size.height);
    canvas.drawImageRect(image, src, dst, Paint()..filterQuality = FilterQuality.medium);
  }

  @override
  bool shouldRepaint(covariant _RowCropPainter oldDelegate) =>
      oldDelegate.image != image || oldDelegate.box != box;
}
