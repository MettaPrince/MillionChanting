class KathaLine {
  final String text;
  final String desc;
  final List<String> triggerWords;

  const KathaLine({
    required this.text,
    required this.desc,
    required this.triggerWords,
  });
}

// Ported 1:1 from index.html's kathaLines array.
const List<KathaLine> kathaLines = [
  KathaLine(
    text: "สัมปะจิตฉามิ",
    desc: "คาถาสนองกลับคุณไสย",
    triggerWords: ["สัมปะจิต", "สัมปจิต", "สัมปะจิชฌามิ", "จิชฌามิ", "ปะจิตฉา"],
  ),
  KathaLine(
    text: "นาสังสิโม",
    desc: "คาถาพระพุทธกัสสป หรือหัวใจพญาเต่าเรือน",
    triggerWords: ["สังสิโม"],
  ),
  KathaLine(
    text: "พรัหมา จะ มหาเทวา สัพเพยักขา ปะลายันติ",
    desc: "คาถาปัดอุปสรรค",
    triggerWords: ["สัพเพยักขา", "ปะรายันติ", "ยันติ", "ปรายัน", "ปรายันติ"],
  ),
  KathaLine(
    text: "พรัหมา จะ มหาเทวา อภิลาภา ภะวันตุ เม",
    desc: "คาถาเงินแสน",
    triggerWords: ["อภิลาภา", "ภิลาภะ", "ภิลาภา", "ภะวันตุเม", "อภิราภา", "พวันตุเม", "วันตุเม"],
  ),
  KathaLine(
    text: "มหาปุญโญ มหาลาโภ ภะวันตุ เม",
    desc: "คาถาลาภไม่ขาดสาย",
    triggerWords: ["มหาปุญ", "ปุญโญ", "ปุนโย", "ปุญโย", "ลาโภ"],
  ),
  KathaLine(
    text: "มิเตพาหุหะติ",
    desc: "คาถาเงินล้าน",
    triggerWords: ["มิเต", "มีเต", "ภาหุ", "หุหะ", "หะติ", "หุหะติ", "หูหะ"],
  ),
  KathaLine(
    text: "พุทธะมะอะอุ นะโมพุทธายะ",
    desc: "คาถาพระปัจเจกพุทธเจ้า",
    triggerWords: ["มะอะอุ", "นะโม", "พุทธายะ", "ทายะ", "ท้ายะ"],
  ),
  KathaLine(
    text: "วิระทะโย วิระโคนายัง วิระหิงสา",
    desc: "คาถาพระปัจเจกพุทธเจ้า",
    triggerWords: ["ทะโย", "ทาโย", "โคนา", "หิงสา", "อิงสา"],
  ),
  KathaLine(
    text: "วิระทาสี วิระทาสา วิระอิตถิโย",
    desc: "คาถาพระปัจเจกพุทธเจ้า",
    triggerWords: ["ทาสี", "ทาสา", "อิตถิ", "ถิโย"],
  ),
  KathaLine(
    text: "พุทธัสสะ มานีมามะ พุทธัสสะ สวาโหม",
    desc: "คาถาพระปัจเจกพุทธเจ้า",
    triggerWords: ["มานี", "มามะ", "สวา", "สะหวา", "สวาโหม", "วาโหม", "โหม"],
  ),
  KathaLine(
    text: "สัมปะติจฉามิ",
    desc: "คาถาเร่งลาภให้ได้เร็วขึ้น",
    triggerWords: ["สัมปติ", "สัมปะติ", "ปะติฉา", "ติจฉามิ"],
  ),
  KathaLine(
    text: "เพ็งเพ็ง พาพา หาหา ฤๅฤๅ",
    desc: "คาถามหาลาภ",
    triggerWords: ["หา", "ฤ", "ฤๅ", "ลือ", "รือ"],
  ),
];

// Same curated allow-list as server.js's CONFIRMED_TRIGGER_WORDS - only add
// words here once they've been seen correctly transcribed in a real chanting
// test. See HANDOFF.md "Hotwords / contextual biasing" for why.
const Set<String> confirmedTriggerWords = {
  'สังสิโม', 'ยันติ', 'มิเต', 'พุทธายะ', 'อิงสา', 'ทาสา', 'มามะ', 'หา',
  'ปะจิตฉา', 'ปุนโย', 'อภิลาภา', 'โคนา',
};

const double confirmedTriggerWordScore = 8.0;
const double canonicalTextHotwordScore = 6.0;

// Builds the hotwords file content the same way server.js's HOTWORDS string
// is built, one phrase per line with a ":score" suffix - Dart's
// OfflineRecognizerConfig takes a hotwordsFile path (set once at recognizer
// creation) rather than sherpa-onnx-node's per-call createStream(hotwords).
String buildHotwordsFileContent() {
  final scores = <String, double>{};
  void add(String phrase, double score) {
    final existing = scores[phrase];
    if (existing == null || score > existing) scores[phrase] = score;
  }

  for (final line in kathaLines) {
    add(line.text, canonicalTextHotwordScore);
    for (final w in line.triggerWords) {
      if (confirmedTriggerWords.contains(w)) add(w, confirmedTriggerWordScore);
    }
  }

  return scores.entries.map((e) => '${e.key} :${e.value}').join('\n');
}
