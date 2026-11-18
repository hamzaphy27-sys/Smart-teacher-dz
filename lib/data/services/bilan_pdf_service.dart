import 'dart:typed_data';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../domain/logic/grade_calculator.dart';
import '../local/app_database.dart';

class BilanPdfService {
  static Future<Uint8List> generateClassBilanPdf({
    required ClassRoom clazz,
    required ClassBilanReport report,
    required GradingFormulaConfig formulaConfig,
    TeacherProfile? teacher,
  }) async {
    final fontRegular = await PdfGoogleFonts.cairoRegular();
    final fontBold = await PdfGoogleFonts.cairoBold();

    final pdf = pw.Document(
      theme: pw.ThemeData.withFont(base: fontRegular, bold: fontBold),
    );

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        textDirection: pw.TextDirection.rtl,
        margin: const pw.EdgeInsets.all(24),
        build: (context) => [
          // Official-style Header
          pw.Container(
            padding: const pw.EdgeInsets.all(14),
            decoration: pw.BoxDecoration(
              color: PdfColor.fromHex('#0F6B4E'),
              borderRadius: pw.BorderRadius.circular(8),
            ),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.stretch,
              children: [
                pw.Text(
                  'الحصيلة الفصلية الذكية — Bilan Trimestriel',
                  style: pw.TextStyle(
                    color: PdfColors.white,
                    fontSize: 16,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
                pw.SizedBox(height: 4),
                pw.Text(
                  'الفوج التربوي: ${clazz.displayName}  |  المادة: ${clazz.subjectName}',
                  style: const pw.TextStyle(color: PdfColors.white, fontSize: 11),
                ),
                pw.Text(
                  'الفصل: ${clazz.termName}  |  السنة الدراسية: ${clazz.academicYear}',
                  style: const pw.TextStyle(color: PdfColors.white, fontSize: 10),
                ),
                if (teacher != null && (teacher.fullName.isNotEmpty || teacher.schoolName.isNotEmpty))
                  pw.Text(
                    'الأستاذ(ة): ${teacher.fullName}  |  المؤسسة: ${teacher.schoolName} (${teacher.wilaya})',
                    style: const pw.TextStyle(color: PdfColors.white, fontSize: 9.5),
                  ),
              ],
            ),
          ),
          pw.SizedBox(height: 14),

          // Summary KPI Grid
          pw.Table(
            border: pw.TableBorder.all(color: PdfColors.grey300),
            children: [
              pw.TableRow(
                decoration: pw.BoxDecoration(color: PdfColor.fromHex('#F1F5F3')),
                children: [
                  _kpiCell('معدل القسم العام', '${report.classAverage ?? "—"} / 20'),
                  _kpiCell('نسبة النجاح (≥ 10)', '${report.passRatePercent ?? "—"} %'),
                  _kpiCell('أعلى معدل', '${report.highestAverage ?? "—"}'),
                  _kpiCell('أدنى معدل', '${report.lowestAverage ?? "—"}'),
                ],
              ),
              pw.TableRow(
                children: [
                  _kpiCell('عدد التلاميذ', '${report.evaluatedStudents} / ${report.totalStudents}'),
                  _kpiCell('الناجحون / المتعثرون', '${report.passedCount} / ${report.failedCount}'),
                  _kpiCell('معدل الفروض', '${report.fardMean ?? "—"}'),
                  _kpiCell('معدل الاختبارات', '${report.examMean ?? "—"}'),
                ],
              ),
            ],
          ),
          pw.SizedBox(height: 10),
          pw.Text(
            'صيغة الحساب المعتمدة: ${formulaConfig.presetLabelAr}',
            style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700),
          ),
          pw.SizedBox(height: 14),

          // Performance Distribution Summary
          pw.Text(
            'توزيع التلاميذ حسب فئات الأداء',
            style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 6),
          pw.Table(
            border: pw.TableBorder.all(color: PdfColors.grey300),
            children: [
              pw.TableRow(
                decoration: pw.BoxDecoration(color: PdfColor.fromHex('#E8EFEA')),
                children: [
                  _headerCell('امتياز (≥16)'),
                  _headerCell('جيد جداً (14-15.99)'),
                  _headerCell('جيد (12-13.99)'),
                  _headerCell('متوسط (10-11.99)'),
                  _headerCell('دون المتوسط (8-9.99)'),
                  _headerCell('ضعيف (<8)'),
                ],
              ),
              pw.TableRow(
                children: [
                  _centerCell('${report.distribution.excellent}'),
                  _centerCell('${report.distribution.veryGood}'),
                  _centerCell('${report.distribution.good}'),
                  _centerCell('${report.distribution.average}'),
                  _centerCell('${report.distribution.belowAvg}'),
                  _centerCell('${report.distribution.weak}'),
                ],
              ),
            ],
          ),
          pw.SizedBox(height: 16),

          // Detailed Student Table
          pw.Text(
            'الكشف الفصلي التفصيلي للتلاميذ',
            style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 6),
          pw.Table(
            border: pw.TableBorder.all(color: PdfColors.grey300),
            columnWidths: {
              0: const pw.FixedColumnWidth(26),
              1: const pw.FlexColumnWidth(2.2),
              2: const pw.FixedColumnWidth(48),
              3: const pw.FixedColumnWidth(48),
              4: const pw.FixedColumnWidth(54),
              5: const pw.FlexColumnWidth(2.6),
            },
            children: [
              pw.TableRow(
                decoration: pw.BoxDecoration(color: PdfColor.fromHex('#0F6B4E')),
                children: [
                  _whiteHeader('#'),
                  _whiteHeader('اللقب والاسم'),
                  _whiteHeader('التقويم م.'),
                  _whiteHeader('الاختبار'),
                  _whiteHeader('المعدل /20'),
                  _whiteHeader('التقدير التربوي'),
                ],
              ),
              ...report.studentResults.map((r) {
                final obs = r.savedObservation ?? r.suggestedComment;
                final isLow = r.termAverage != null && r.termAverage! < 10.0;
                return pw.TableRow(
                  decoration: isLow
                      ? pw.BoxDecoration(color: PdfColor.fromHex('#FFF3F4'))
                      : null,
                  children: [
                    _centerCell('${r.student.officialOrder}'),
                    _paddedCell('${r.student.lastName} ${r.student.firstName}'),
                    _centerCell('${r.continuousAverage ?? "—"}'),
                    _centerCell('${r.examGrade ?? "—"}'),
                    _centerCell(
                      r.termAverage != null ? '${r.termAverage}' : '—',
                      bold: true,
                    ),
                    _paddedCell(obs),
                  ],
                );
              }),
            ],
          ),
        ],
      ),
    );

    return pdf.save();
  }

  static pw.Widget _kpiCell(String label, String value) {
    return pw.Padding(
      padding: const pw.EdgeInsets.all(6),
      child: pw.Column(
        children: [
          pw.Text(label, style: const pw.TextStyle(fontSize: 8.5, color: PdfColors.grey700)),
          pw.SizedBox(height: 2),
          pw.Text(value, style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
        ],
      ),
    );
  }

  static pw.Widget _headerCell(String text) => pw.Padding(
        padding: const pw.EdgeInsets.all(5),
        child: pw.Center(
          child: pw.Text(text, style: pw.TextStyle(fontSize: 8.5, fontWeight: pw.FontWeight.bold)),
        ),
      );

  static pw.Widget _whiteHeader(String text) => pw.Padding(
        padding: const pw.EdgeInsets.all(5),
        child: pw.Center(
          child: pw.Text(
            text,
            style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold, color: PdfColors.white),
          ),
        ),
      );

  static pw.Widget _centerCell(String text, {bool bold = false}) => pw.Padding(
        padding: const pw.EdgeInsets.all(4),
        child: pw.Center(
          child: pw.Text(
            text,
            style: pw.TextStyle(
              fontSize: 9,
              fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
            ),
          ),
        ),
      );

  static pw.Widget _paddedCell(String text) => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: pw.Text(text, style: const pw.TextStyle(fontSize: 9)),
      );
}
