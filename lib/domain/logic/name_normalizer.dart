/// Arabic & French name normalization ported from Python `stocr/normalize.py`.
class NameNormalizer {
  static const Map<String, String> _arabicIndic = {
    '٠': '0', '١': '1', '٢': '2', '٣': '3', '٤': '4',
    '٥': '5', '٦': '6', '٧': '7', '٨': '8', '٩': '9',
    '۰': '0', '۱': '1', '۲': '2', '۳': '3', '۴': '4',
    '۵': '5', '۶': '6', '۷': '7', '۸': '8', '۹': '9',
  };

  static String normalizeDigits(String input) {
    final buf = StringBuffer();
    for (final rune in input.runes) {
      final ch = String.fromCharCode(rune);
      buf.write(_arabicIndic[ch] ?? ch);
    }
    return buf
        .toString()
        .replaceAll('٫', '.')
        .replaceAll('،', ',')
        .replaceAll('٬', ',');
  }

  static String normalizeArabic(String input) {
    // Strip tashkeel & tatweel
    var s = input.replaceAll(RegExp(r'[\u0610-\u061A\u064B-\u065F\u0670\u0640]'), '');
    s = s
        .replaceAll(RegExp(r'[أإآٱ]'), 'ا')
        .replaceAll(RegExp(r'[ىئ]'), 'ي')
        .replaceAll('ؤ', 'و')
        .replaceAll(RegExp(r'[ةۀ]'), 'ه')
        .replaceAll('ڨ', 'ق')
        .replaceAll('ڤ', 'ف')
        .replaceAll('پ', 'ب')
        .replaceAll('ء', '');
    s = s.replaceAll(RegExp(r'[^\u0621-\u064A\s]'), ' ');
    return s.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static List<String> arabicTokens(String input) {
    const joiners = {'عبد', 'عبدال', 'بن', 'ابن', 'بنت', 'بو', 'ابو', 'ايت', 'ولد', 'ال'};
    final raw = normalizeArabic(input).split(' ').where((w) => w.isNotEmpty).toList();
    final out = <String>[];
    var i = 0;
    while (i < raw.length) {
      var cur = raw[i++];
      while (joiners.contains(cur) && i < raw.length) {
        cur += raw[i++];
      }
      out.add(cur);
    }
    return out;
  }
}
