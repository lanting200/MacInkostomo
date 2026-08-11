import Foundation
import NaturalLanguage
import SQLite3
import CryptoKit

// MARK: - Source ingest models

/// How `splitSourceChapters` divided the original work.
enum SourceSplitStrategy: String, Codable, Sendable {
  /// Chapter headings were found and used as boundaries.
  case headings
  /// No usable headings; the text was cut into fixed-size blocks so retrieval
  /// still has units smaller than the whole novel.
  case fixedBlocks
}

/// One chapter of the ingested original work.
struct SourceChapter: Codable, Equatable, Sendable {
  /// 1-based position in the original, which is what every canon `sourceChapter`
  /// reference and every mode anchor (divergence point, insertion point) means.
  let index: Int
  let title: String
  /// Character offset of the body inside `original.txt`, so a passage can be
  /// traced back to the exact source location without storing the text twice.
  let offset: Int
  let length: Int
}

/// Result of ingesting an original work. Persisted as `source/manifest.json`.
struct SourceManifest: Codable, Equatable, Sendable {
  let version: Int
  /// SHA-256 of the *original bytes as supplied*, before normalization. Re-import
  /// of identical bytes is a no-op, so a stray second import cannot wipe
  /// extraction progress.
  let sourceDigest: String
  let detectedEncoding: String
  let characterCount: Int
  let chapterCount: Int
  let splitStrategy: SourceSplitStrategy
  let chapters: [SourceChapter]
  let ingestedAt: String

  static let currentVersion = 1
}

/// A retrieved slice of the original work.
struct SourcePassage: Codable, Equatable, Sendable {
  let chapterIndex: Int
  let chapterTitle: String
  let paragraphIndex: Int
  let text: String
  /// Merged BM25 score. Lower is a better match, matching SQLite's convention
  /// where bm25() returns negative values for stronger matches.
  let score: Double
}

// MARK: - Encoding detection

extension InkOSCore {
  /// Encodings a Chinese novel `.txt` realistically arrives in.
  ///
  /// `String.Encoding` has no GB18030 or Big5 member, so the CJK codecs are built
  /// from CoreFoundation's extended constants (`CFStringEncodingExt.h`) and then
  /// filtered against `availableStringEncodings`.
  ///
  /// The filter is not defensive padding — it is the guard for a failure this code
  /// already shipped. An unmapped CFStringEncoding does not report an error: it
  /// converts to `0x8000_0000 | raw`, which `String(data:encoding:)` rejects for
  /// every input. The first version used 0x0630 for GB18030, but 0x0630 is
  /// GB_2312_80 (GB18030 is 0x0632) and this SDK maps neither, so the branch was
  /// dead and every GB18030 novel fell through to UTF-8 and decoded as U+FFFD
  /// soup. Dropping unusable candidates up front turns that class of typo into a
  /// missing encoding rather than a silently mangled book.
  private static let sourceEncodingCandidates: [(name: String, encoding: String.Encoding)] = {
    // GB18030 is a superset of GBK, which is a superset of GB2312, so one entry
    // covers every simplified-Chinese file. Big5-HKSCS likewise supersets Big5.
    let extended: [(name: String, raw: UInt32)] = [
      ("gb18030", 0x0632),
      ("big5-hkscs", 0x0A06),
      ("big5", 0x0A03),
    ]
    var candidates: [(name: String, encoding: String.Encoding)] = [("utf-8", .utf8)]
    for entry in extended {
      let encoding = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(entry.raw))
      )
      guard String.availableStringEncodings.contains(encoding) else { continue }
      candidates.append((entry.name, encoding))
    }
    candidates.append(("utf-16", .utf16))
    return candidates
  }()

  /// Decodes an original work, choosing the encoding that yields the most
  /// plausible Chinese text rather than the first one that does not throw.
  ///
  /// A GB18030 novel decoded as UTF-8 does not fail outright — it produces
  /// U+FFFD replacement characters — so picking the first success would silently
  /// mangle the whole book. Scoring on CJK density minus replacement-character
  /// penalty catches that.
  func decodeSourceText(_ data: Data) throws -> (text: String, encoding: String) {
    // A BOM is authoritative; skip scoring entirely.
    if data.count >= 3, data[0] == 0xEF, data[1] == 0xBB, data[2] == 0xBF,
      let text = String(data: data.dropFirst(3), encoding: .utf8)
    {
      return (text, "utf-8-bom")
    }

    var best: (text: String, encoding: String, score: Double)?
    for candidate in Self.sourceEncodingCandidates {
      guard let text = String(data: data, encoding: candidate.encoding), !text.isEmpty else {
        continue
      }
      let score = sourceDecodeScore(text)
      if best == nil || score > best!.score {
        best = (text, candidate.name, score)
      }
    }
    guard let best else {
      throw InkOSCoreError("无法识别原著文本编码，请另存为 UTF-8 后重试", statusCode: 400)
    }
    return (best.text, best.encoding)
  }

  /// CJK density minus a heavy replacement-character penalty, sampled from the
  /// head so a multi-megabyte novel is not scanned twice.
  private func sourceDecodeScore(_ text: String) -> Double {
    let sample = text.prefix(20_000)
    guard !sample.isEmpty else { return -1 }
    var cjk = 0
    var replacement = 0
    var control = 0
    for scalar in sample.unicodeScalars {
      switch scalar.value {
      case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF:
        cjk += 1
      case 0xFFFD:
        replacement += 1
      case 0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F:
        control += 1
      default:
        break
      }
    }
    let total = Double(sample.unicodeScalars.count)
    return Double(cjk) / total
      - 4.0 * Double(replacement) / total
      - 8.0 * Double(control) / total
  }
}

// MARK: - Chapter splitting

extension InkOSCore {
  /// Heading forms seen in Chinese web novels and their translations. Anchored to
  /// line start so a mid-sentence "第三章" reference is not mistaken for a heading.
  private static let sourceHeadingPattern = try? NSRegularExpression(
    pattern: #"(?m)^[ \t　]{0,8}("#
      + #"第[〇零一二三四五六七八九十百千万\d]{1,12}[章回节卷折幕][^\n]{0,60}"#
      + #"|[Cc]hapter[ \t]+\d{1,6}[^\n]{0,60}"#
      + #"|[序尾终][章幕][^\n]{0,60}"#
      + #"|楔子[^\n]{0,60}"#
      + #"|番外[^\n]{0,60}"#
      + #")[ \t]*$"#
  )

  /// Block size for the fallback split. Small enough that a retrieved unit is
  /// usable in a prompt, large enough to keep the index from exploding.
  private static let sourceFallbackBlockSize = 4_000

  /// Divides the original into chapters, preferring real headings.
  ///
  /// Headings are only trusted when there are at least three of them and the
  /// average span is plausible. A stray "第一章" in a foreword would otherwise
  /// produce one chapter holding the entire novel, which defeats retrieval — so
  /// an implausible result falls back to fixed blocks rather than being accepted.
  func splitSourceChapters(_ text: String) -> (chapters: [SourceChapter], strategy: SourceSplitStrategy) {
    let headings = sourceHeadingMatches(text)
    if headings.count >= 3 {
      let chapters = sourceChaptersFromHeadings(text, headings: headings)
      let averageLength = chapters.reduce(0) { $0 + $1.length } / Swift.max(1, chapters.count)
      if averageLength < 60_000 {
        return (chapters, .headings)
      }
    }
    return (sourceFixedBlockChapters(text), .fixedBlocks)
  }

  /// Heading ranges as (titleStart, titleEnd) character offsets.
  private func sourceHeadingMatches(_ text: String) -> [(start: Int, end: Int, title: String)] {
    guard let pattern = Self.sourceHeadingPattern else { return [] }
    let ns = text as NSString
    let matches = pattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
    return matches.compactMap { match in
      let range = match.range
      guard range.location != NSNotFound else { return nil }
      let title = ns.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
      guard !title.isEmpty else { return nil }
      return (range.location, range.location + range.length, title)
    }
  }

  private func sourceChaptersFromHeadings(
    _ text: String,
    headings: [(start: Int, end: Int, title: String)]
  ) -> [SourceChapter] {
    let ns = text as NSString
    var chapters: [SourceChapter] = []
    // Text before the first heading is real content (foreword, blurb), so it is
    // kept as chapter 0 rather than dropped.
    if let first = headings.first, first.start > 0 {
      let head = ns.substring(to: first.start).trimmingCharacters(in: .whitespacesAndNewlines)
      if head.count >= 200 {
        chapters.append(SourceChapter(index: 0, title: "卷首", offset: 0, length: first.start))
      }
    }
    for (position, heading) in headings.enumerated() {
      // Body starts after the heading line and runs to the next heading.
      let bodyStart = heading.end
      let bodyEnd = position + 1 < headings.count ? headings[position + 1].start : ns.length
      guard bodyEnd > bodyStart else { continue }
      chapters.append(SourceChapter(
        index: position + 1,
        title: heading.title,
        offset: bodyStart,
        length: bodyEnd - bodyStart
      ))
    }
    return chapters
  }

  /// Segments Chinese text into space-delimited words for the `unicode61` mirror
  /// column. `unicode61` splits on whitespace, so pre-segmenting is what makes a
  /// two-character query like 渡口 findable at all — see `SourceSearchIndex`.
  func segmentChineseForSearch(_ text: String) -> String {
    let tokenizer = NLTokenizer(unit: .word)
    tokenizer.setLanguage(.simplifiedChinese)
    tokenizer.string = text
    var tokens: [String] = []
    tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
      let token = String(text[range])
      if !token.isEmpty { tokens.append(token) }
      return true
    }
    return tokens.joined(separator: " ")
  }

  private func sourceFixedBlockChapters(_ text: String) -> [SourceChapter] {
    let ns = text as NSString
    let size = Self.sourceFallbackBlockSize
    guard ns.length > 0 else { return [] }
    var chapters: [SourceChapter] = []
    var offset = 0
    var index = 1
    while offset < ns.length {
      let length = Swift.min(size, ns.length - offset)
      chapters.append(SourceChapter(
        index: index,
        title: "第\(index)段",
        offset: offset,
        length: length
      ))
      offset += length
      index += 1
    }
    return chapters
  }
}

// MARK: - FTS5 retrieval index

/// BM25 lexical index over the original work, backed by the system SQLite.
///
/// Two tables rather than one, and neither is contentless. Both choices are
/// forced by measured SQLite behaviour:
///
/// - FTS5 `trigram` never matches a query shorter than three characters, so
///   `渡口` and `纱布` return zero rows against a trigram index. `body_seg`
///   holds `NLTokenizer` output and uses `unicode61`, which matches on word
///   boundaries and therefore does find two-character terms. FTS5 allows one
///   tokenizer per table, hence two tables.
/// - A contentless table (`content=''`) joined to a metadata table does not have
///   its `MATCH` constrain the join: a non-matching query returns *every* row
///   with `bm25()` = 0. Each table therefore carries its own text plus
///   `UNINDEXED` metadata, is queried alone, and results are merged in Swift.
final class SourceSearchIndex {
  private var handle: OpaquePointer?

  /// Callers pass `NLTokenizer`-segmented text for `segmented`; the class does not
  /// segment, so it stays free of NaturalLanguage state.
  struct Row {
    let chapterIndex: Int
    let chapterTitle: String
    let paragraphIndex: Int
    let text: String
    let segmented: String
  }

  init(path: String, reset: Bool) throws {
    if reset { try? FileManager.default.removeItem(at: URL(fileURLWithPath: path)) }
    guard sqlite3_open_v2(
      path, &handle,
      SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil
    ) == SQLITE_OK else {
      let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
      sqlite3_close(handle)
      handle = nil
      throw InkOSCoreError("原著检索索引打开失败：\(message)", statusCode: 500)
    }
    try execute("PRAGMA journal_mode=WAL;")
    try execute("PRAGMA synchronous=NORMAL;")
    try execute("""
      CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
      CREATE VIRTUAL TABLE IF NOT EXISTS body_tri USING fts5(
        text,
        chapterIndex UNINDEXED, chapterTitle UNINDEXED, paragraphIndex UNINDEXED,
        tokenize="trigram"
      );
      CREATE VIRTUAL TABLE IF NOT EXISTS body_seg USING fts5(
        text,
        chapterIndex UNINDEXED, chapterTitle UNINDEXED, paragraphIndex UNINDEXED,
        tokenize="unicode61"
      );
      -- Semantic half of the hybrid retrieval. Written with a NULL vector during
      -- ingest and filled in by embedDerivativeSource, so `vector IS NULL` is the
      -- work queue: an interrupted embedding pass resumes instead of restarting,
      -- and retrieval can report how much of the book is semantically indexed.
      CREATE TABLE IF NOT EXISTS passages(
        chapterIndex INTEGER NOT NULL,
        chapterTitle TEXT NOT NULL,
        paragraphIndex INTEGER NOT NULL,
        text TEXT NOT NULL,
        vector BLOB,
        PRIMARY KEY(chapterIndex, paragraphIndex)
      );
      """)
  }

  deinit { sqlite3_close(handle) }

  func close() {
    sqlite3_close(handle)
    handle = nil
  }

  private func execute(_ sql: String) throws {
    var error: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
      let message = error.map { String(cString: $0) } ?? "unknown"
      sqlite3_free(error)
      throw InkOSCoreError("原著检索索引写入失败：\(message)", statusCode: 500)
    }
  }

  func beginTransaction() throws { try execute("BEGIN IMMEDIATE;") }
  func commitTransaction() throws { try execute("COMMIT;") }

  /// Inserts one passage into both FTS tables plus the `passages` row that the
  /// semantic pass later fills with a vector. `body_tri` gets raw text for
  /// substring-style queries; `body_seg` gets the segmented mirror.
  func insert(_ row: Row) throws {
    let sql = """
      INSERT INTO %@(text, chapterIndex, chapterTitle, paragraphIndex)
      VALUES(?, ?, ?, ?);
      """
    for (table, payload) in [("body_tri", row.text), ("body_seg", row.segmented)] {
      var statement: OpaquePointer?
      guard sqlite3_prepare_v2(
        handle, String(format: sql, table), -1, &statement, nil
      ) == SQLITE_OK else {
        throw InkOSCoreError("原著检索索引准备失败", statusCode: 500)
      }
      defer { sqlite3_finalize(statement) }
      sqlite3_bind_text(statement, 1, payload, -1, sqliteTransient)
      sqlite3_bind_int(statement, 2, Int32(row.chapterIndex))
      sqlite3_bind_text(statement, 3, row.chapterTitle, -1, sqliteTransient)
      sqlite3_bind_int(statement, 4, Int32(row.paragraphIndex))
      guard sqlite3_step(statement) == SQLITE_DONE else {
        throw InkOSCoreError("原著检索索引插入失败", statusCode: 500)
      }
    }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, """
      INSERT OR REPLACE INTO passages(chapterIndex, chapterTitle, paragraphIndex, text, vector)
      VALUES(?, ?, ?, ?, NULL);
      """, -1, &statement, nil) == SQLITE_OK else {
      throw InkOSCoreError("原著段落表准备失败", statusCode: 500)
    }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_int(statement, 1, Int32(row.chapterIndex))
    sqlite3_bind_text(statement, 2, row.chapterTitle, -1, sqliteTransient)
    sqlite3_bind_int(statement, 3, Int32(row.paragraphIndex))
    sqlite3_bind_text(statement, 4, row.text, -1, sqliteTransient)
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw InkOSCoreError("原著段落表插入失败", statusCode: 500)
    }
  }

  // MARK: Vector store

  /// One passage awaiting an embedding.
  struct PendingPassage {
    let chapterIndex: Int
    let paragraphIndex: Int
    let text: String
  }

  /// Passages with no vector yet, oldest position first. `limit` bounds memory
  /// for a multi-megabyte novel; the caller loops until this returns empty.
  func passagesMissingVectors(limit: Int) throws -> [PendingPassage] {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, """
      SELECT chapterIndex, paragraphIndex, text FROM passages
      WHERE vector IS NULL ORDER BY chapterIndex, paragraphIndex LIMIT ?;
      """, -1, &statement, nil) == SQLITE_OK else {
      throw InkOSCoreError("原著向量待办查询失败", statusCode: 500)
    }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_int(statement, 1, Int32(limit))
    var pending: [PendingPassage] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      pending.append(PendingPassage(
        chapterIndex: Int(sqlite3_column_int(statement, 0)),
        paragraphIndex: Int(sqlite3_column_int(statement, 1)),
        text: sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? ""
      ))
    }
    return pending
  }

  /// Stores one L2-normalized vector as little-endian Float32.
  ///
  /// Float32 rather than Double: the vectors are already normalized and only ever
  /// compared by dot product, so the extra precision buys nothing and would
  /// double a 512-dimension index from 2 KB to 4 KB per passage.
  func storeVector(_ vector: [Float], chapterIndex: Int, paragraphIndex: Int) throws {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, """
      UPDATE passages SET vector = ? WHERE chapterIndex = ? AND paragraphIndex = ?;
      """, -1, &statement, nil) == SQLITE_OK else {
      throw InkOSCoreError("原著向量写入准备失败", statusCode: 500)
    }
    defer { sqlite3_finalize(statement) }
    let bytes = vector.withUnsafeBufferPointer { Data(buffer: $0) }
    _ = bytes.withUnsafeBytes { raw in
      sqlite3_bind_blob(statement, 1, raw.baseAddress, Int32(raw.count), sqliteTransient)
    }
    sqlite3_bind_int(statement, 2, Int32(chapterIndex))
    sqlite3_bind_int(statement, 3, Int32(paragraphIndex))
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw InkOSCoreError("原著向量写入失败", statusCode: 500)
    }
  }

  /// (embedded, total) passage counts, so callers can report coverage and decide
  /// whether the semantic half of retrieval is usable at all.
  func vectorCoverage() throws -> (embedded: Int, total: Int) {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, """
      SELECT COUNT(vector), COUNT(*) FROM passages;
      """, -1, &statement, nil) == SQLITE_OK else {
      throw InkOSCoreError("原著向量覆盖率查询失败", statusCode: 500)
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { return (0, 0) }
    return (Int(sqlite3_column_int(statement, 0)), Int(sqlite3_column_int(statement, 1)))
  }

  /// Brute-force cosine ranking over every stored vector.
  ///
  /// No ANN index: both vectors are L2-normalized so similarity is a plain dot
  /// product, and a 5 500-passage novel is 2.8 M multiply-adds per query —
  /// microseconds. An approximate index would add a dependency and a build step
  /// to save time that is not being spent.
  func semanticSearch(query: [Float], limit: Int) throws -> [SourcePassage] {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, """
      SELECT chapterIndex, chapterTitle, paragraphIndex, text, vector FROM passages
      WHERE vector IS NOT NULL;
      """, -1, &statement, nil) == SQLITE_OK else {
      throw InkOSCoreError("原著语义检索准备失败", statusCode: 500)
    }
    defer { sqlite3_finalize(statement) }
    var scored: [SourcePassage] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let blob = sqlite3_column_blob(statement, 4) else { continue }
      let byteCount = Int(sqlite3_column_bytes(statement, 4))
      guard byteCount == query.count * MemoryLayout<Float>.size else { continue }
      let stored = Data(bytes: blob, count: byteCount).withUnsafeBytes {
        Array($0.bindMemory(to: Float.self))
      }
      var dot: Float = 0
      for i in 0..<query.count { dot += query[i] * stored[i] }
      scored.append(SourcePassage(
        chapterIndex: Int(sqlite3_column_int(statement, 0)),
        chapterTitle: sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? "",
        paragraphIndex: Int(sqlite3_column_int(statement, 2)),
        text: sqlite3_column_text(statement, 3).map { String(cString: $0) } ?? "",
        // Negated so "lower is better" holds for both halves of the hybrid,
        // matching SQLite's bm25() convention.
        score: Double(-dot)
      ))
    }
    return scored
      .sorted {
        $0.score != $1.score
          ? $0.score < $1.score
          : ($0.chapterIndex, $0.paragraphIndex) < ($1.chapterIndex, $1.paragraphIndex)
      }
      .prefix(limit)
      .map { $0 }
  }

  /// Runs one MATCH expression against one table and returns ranked hits.
  ///
  /// Ranking comes from the FTS table but the returned prose comes from
  /// `passages`, joined on the same `(chapterIndex, paragraphIndex)` primary key.
  /// Selecting `body_seg.text` instead would hand the caller the space-delimited
  /// `NLTokenizer` mirror — measured at 133 inserted spaces in a 232-character
  /// paragraph — and that text is rendered into the prompt as a canon quotation.
  /// Two-character keys are exactly the case that only `body_seg` can answer, so
  /// without the join the mirror leaks precisely when it is the only half hitting.
  /// `COALESCE` keeps a hit alive if the join ever misses; the FTS text is wrong
  /// for `body_seg` but losing the passage entirely is worse.
  ///
  /// FTS5 refuses `MATCH` and `bm25()` against an aliased table
  /// (`no such column: f`), so the table is named in full on both sides.
  private func query(table: String, expression: String, limit: Int) throws -> [SourcePassage] {
    let sql = """
      SELECT \(table).chapterIndex, \(table).chapterTitle, \(table).paragraphIndex,
             COALESCE(p.text, \(table).text) AS body, bm25(\(table)) AS score
      FROM \(table)
      LEFT JOIN passages AS p
        ON p.chapterIndex = \(table).chapterIndex
       AND p.paragraphIndex = \(table).paragraphIndex
      WHERE \(table) MATCH ? ORDER BY score LIMIT ?;
      """
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
      throw InkOSCoreError("原著检索准备失败", statusCode: 500)
    }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_text(statement, 1, expression, -1, sqliteTransient)
    sqlite3_bind_int(statement, 2, Int32(limit))
    var results: [SourcePassage] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      let title = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
      let text = sqlite3_column_text(statement, 3).map { String(cString: $0) } ?? ""
      results.append(SourcePassage(
        chapterIndex: Int(sqlite3_column_int(statement, 0)),
        chapterTitle: title,
        paragraphIndex: Int(sqlite3_column_int(statement, 2)),
        text: text,
        score: sqlite3_column_double(statement, 4)
      ))
    }
    return results
  }

  /// Searches both tables and merges on (chapterIndex, paragraphIndex), keeping
  /// the better score. `segmentedKeys` must be the caller's segmented form of the
  /// same keys, used for the `body_seg` side.
  func search(
    triExpression: String?,
    segExpression: String?,
    limit: Int
  ) throws -> [SourcePassage] {
    var merged: [String: SourcePassage] = [:]
    for (table, expression) in [("body_tri", triExpression), ("body_seg", segExpression)] {
      guard let expression, !expression.isEmpty else { continue }
      for hit in try query(table: table, expression: expression, limit: limit) {
        let key = "\(hit.chapterIndex)#\(hit.paragraphIndex)"
        if let existing = merged[key] {
          // Both halves now read their prose from `passages` via `query`, so the
          // two texts are identical and either one is safe to keep.
          merged[key] = SourcePassage(
            chapterIndex: hit.chapterIndex,
            chapterTitle: hit.chapterTitle,
            paragraphIndex: hit.paragraphIndex,
            text: existing.text,
            score: Swift.min(existing.score, hit.score)
          )
        } else {
          merged[key] = hit
        }
      }
    }
    return merged.values
      .sorted {
        $0.score != $1.score
          ? $0.score < $1.score
          : ($0.chapterIndex, $0.paragraphIndex) < ($1.chapterIndex, $1.paragraphIndex)
      }
      .prefix(limit)
      .map { $0 }
  }
}

/// `SQLITE_TRANSIENT` is a macro and does not survive into Swift, so SQLite is
/// told to copy bound strings via its documented sentinel value.
private let sqliteTransient = unsafeBitCast(
  -1, to: sqlite3_destructor_type.self
)

// MARK: - Ingest

extension InkOSCore {
  func sourceDirectoryURL(_ bookID: String) throws -> URL {
    try existingBookURL(bookID).appendingPathComponent("source", isDirectory: true)
  }

  /// Imports an original work: detects encoding, splits chapters, stores a
  /// normalized UTF-8 copy, and builds the BM25 index.
  ///
  /// Idempotent on identical bytes. Extraction is the expensive phase, so a
  /// second import of the same file returns the existing manifest untouched
  /// rather than rebuilding and discarding progress.
  @discardableResult
  func importDerivativeSource(bookID: String, from fileURL: URL) throws -> SourceManifest {
    let data = try Data(contentsOf: fileURL)
    guard !data.isEmpty else {
      throw InkOSCoreError("原著文件为空", statusCode: 400)
    }
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let sourceURL = try sourceDirectoryURL(bookID)
    let manifestURL = sourceURL.appendingPathComponent("manifest.json")

    let existingManifest = try? decoder.decode(
      SourceManifest.self,
      from: Data(contentsOf: manifestURL)
    )

    if let existing = existingManifest,
      existing.sourceDigest == digest,
      existing.version == SourceManifest.currentVersion,
      fileManager.fileExists(atPath: sourceURL.appendingPathComponent("passages.sqlite").path)
    {
      recordDebug(scope: "derivative", message: "source.unchanged", data: [
        "bookId": bookID,
        "chapterCount": existing.chapterCount,
      ])
      return existing
    }

    let decoded = try decodeSourceText(data)
    // Normalize line endings before offsets are computed, so every recorded
    // offset indexes the text that actually gets written.
    let text = decoded.text
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
    let split = splitSourceChapters(text)
    guard !split.chapters.isEmpty else {
      throw InkOSCoreError("原著文本无法切分出章节", statusCode: 400)
    }

    try fileManager.createDirectory(at: sourceURL, withIntermediateDirectories: true)
    try atomicWrite(text, to: sourceURL.appendingPathComponent("original.txt"))

    let manifest = SourceManifest(
      version: SourceManifest.currentVersion,
      sourceDigest: digest,
      detectedEncoding: decoded.encoding,
      characterCount: (text as NSString).length,
      // A retained preface uses source index 0. It is searchable but is not one of
      // the numbered chapters the resumable canon cursor advances through.
      chapterCount: split.chapters.filter { $0.index > 0 }.count,
      splitStrategy: split.strategy,
      chapters: split.chapters,
      ingestedAt: isoTimestamp()
    )
    try buildSourceSearchIndex(bookID: bookID, text: text, chapters: split.chapters)

    // A new source digest invalidates more than the cursor: completed batches have
    // already been merged into `baseContinuity`. Leaving that layer in place would
    // mix facts from two originals even though `loadCanonProgress` correctly starts
    // the new source at chapter 1. The reset keeps author and chapter layers intact.
    if fileManager.fileExists(atPath: manifestURL.path),
      existingManifest?.sourceDigest != digest
    {
      _ = try clearSourceCanonBaseContinuity(bookID: bookID)
      try? fileManager.removeItem(at: sourceURL.appendingPathComponent("canon-progress.json"))
      try? fileManager.removeItem(at: sourceURL.appendingPathComponent("preparation.json"))
      recordDebug(scope: "derivative", message: "source.canon_reset", data: [
        "bookId": bookID,
        "previousDigest": existingManifest?.sourceDigest ?? "unreadable",
        "sourceDigest": digest,
      ])
    }
    try atomicWrite(try encoder.encode(manifest), to: manifestURL)
    recordDebug(scope: "derivative", message: "source.imported", data: [
      "bookId": bookID,
      "encoding": decoded.encoding,
      "characterCount": manifest.characterCount,
      "chapterCount": manifest.chapterCount,
      "splitStrategy": split.strategy.rawValue,
    ])
    return manifest
  }

  /// Builds the FTS index at paragraph granularity, merging runs of short lines
  /// so a passage carries enough context to be usable in a prompt.
  private func buildSourceSearchIndex(
    bookID: String,
    text: String,
    chapters: [SourceChapter]
  ) throws {
    let sourceURL = try sourceDirectoryURL(bookID)
    let index = try SourceSearchIndex(
      path: sourceURL.appendingPathComponent("passages.sqlite").path,
      reset: true
    )
    defer { index.close() }
    let ns = text as NSString
    try index.beginTransaction()
    for chapter in chapters {
      let body = ns.substring(with: NSRange(location: chapter.offset, length: chapter.length))
      for (position, passage) in mergedParagraphs(body).enumerated() {
        try index.insert(SourceSearchIndex.Row(
          chapterIndex: chapter.index,
          chapterTitle: chapter.title,
          paragraphIndex: position,
          text: passage,
          segmented: segmentChineseForSearch(passage)
        ))
      }
    }
    try index.commitTransaction()
  }

  /// Groups lines into passages of roughly `minimum` characters. Dialogue-heavy
  /// prose is mostly one-line paragraphs; indexing each alone would return
  /// fragments with no surrounding situation.
  private func mergedParagraphs(_ body: String, minimum: Int = 180) -> [String] {
    var passages: [String] = []
    var current = ""
    for line in body.components(separatedBy: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }
      current += (current.isEmpty ? "" : "\n") + trimmed
      if current.count >= minimum {
        passages.append(current)
        current = ""
      }
    }
    if !current.isEmpty { passages.append(current) }
    return passages
  }

  /// Retrieves passages of the original matching `keys` (character names, place
  /// names, object names taken from a beat card or canon entry).
  func searchDerivativeSource(
    bookID: String,
    keys: [String],
    limit: Int = 8
  ) throws -> [SourcePassage] {
    let sourceURL = try sourceDirectoryURL(bookID)
    let databaseURL = sourceURL.appendingPathComponent("passages.sqlite")
    guard fileManager.fileExists(atPath: databaseURL.path) else {
      throw InkOSCoreError("尚未导入原著，无法检索", statusCode: 404)
    }
    let expressions = sourceMatchExpressions(keys)
    guard expressions.tri != nil || expressions.seg != nil else { return [] }
    let index = try SourceSearchIndex(path: databaseURL.path, reset: false)
    defer { index.close() }
    return try index.search(
      triExpression: expressions.tri,
      segExpression: expressions.seg,
      limit: limit
    )
  }

  /// Builds the two MATCH expressions.
  ///
  /// Keys arrive from beat cards and canon entries, so they can hold quotes,
  /// punctuation and FTS5 operator words. Every term is wrapped in double quotes
  /// as a phrase with inner quotes doubled, which neutralizes operators. Terms
  /// under three characters go only to the segmented table, because trigram
  /// cannot match them.
  /// FTS5 bareword operators. A beat card writes keys as prose, so `NOT 渡口`
  /// arrives as a key meaning "the ferry crossing", never as a query operator.
  private static let sourceMatchOperators: Set<String> = ["AND", "OR", "NOT", "NEAR"]

  /// Builds the `MATCH` expression for each table from caller-supplied keys.
  ///
  /// Keys come from generated beat cards, so they are hostile input to FTS5: an
  /// unpaired `"` is `unterminated string` and a bareword `NOT` is
  /// `syntax error near "NOT"`, either of which fails the whole retrieval. Three
  /// measured properties of FTS5 shape the sanitizing:
  ///
  /// - Quoting is enough to neutralize *syntax*. `"NOT 渡口"` parses cleanly as a
  ///   phrase, so operators do not need escaping, only wrapping.
  /// - Quoting is not enough to preserve *recall*. A phrase matches only
  ///   consecutive tokens, so the key `船老大 AND 跳板` — whose words appear in one
  ///   passage but not adjacently — matches nothing. Each key is therefore split
  ///   on whitespace and every token becomes its own phrase.
  /// - A token that is only an operator word carries no search intent, so it is
  ///   dropped rather than quoted; keeping it would just add a term that matches
  ///   the literal string "AND" somewhere in the novel.
  ///
  /// Tokens of one key are joined with `AND` (all must appear, in any order) and
  /// separate keys with `OR`, so an unrelated key never suppresses a good one.
  func sourceMatchExpressions(_ keys: [String]) -> (tri: String?, seg: String?) {
    var triGroups: [String] = []
    var segGroups: [String] = []
    for key in keys {
      let cleaned = key
        .replacingOccurrences(of: "\"", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard cleaned.count >= 2 else { continue }

      let tokens = cleaned
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty && !Self.sourceMatchOperators.contains($0.uppercased()) }
      guard !tokens.isEmpty else { continue }

      // `trigram` never matches a query shorter than three characters, so a
      // two-character token would make the whole group unsatisfiable here. Those
      // tokens are the segmented mirror's job.
      let triTokens = tokens.filter { $0.count >= 3 }
      if !triTokens.isEmpty {
        triGroups.append(sourceMatchGroup(triTokens.map { "\"\($0)\"" }))
      }

      // The segmented column stores NLTokenizer output, so each token is
      // segmented the same way to line up with the indexed token boundaries.
      let segTokens = tokens.compactMap { token -> String? in
        let segmented = segmentChineseForSearch(token)
          .replacingOccurrences(of: "\"", with: " ")
          .trimmingCharacters(in: .whitespacesAndNewlines)
        return segmented.isEmpty ? nil : "\"\(segmented)\""
      }
      if !segTokens.isEmpty {
        segGroups.append(sourceMatchGroup(segTokens))
      }
    }
    return (
      triGroups.isEmpty ? nil : triGroups.joined(separator: " OR "),
      segGroups.isEmpty ? nil : segGroups.joined(separator: " OR ")
    )
  }

  /// Parenthesizes a multi-phrase group so the implicit `AND` inside one key
  /// cannot bind across the `OR` that separates keys.
  private func sourceMatchGroup(_ phrases: [String]) -> String {
    phrases.count == 1
      ? phrases[0]
      : "(" + phrases.joined(separator: " AND ") + ")"
  }
}

// MARK: - Semantic embedding

/// Coverage of the semantic half of the retrieval index.
struct SourceEmbeddingStatus: Codable, Equatable, Sendable {
  let embedded: Int
  let total: Int
  /// False when this machine cannot run the on-device model. Retrieval then
  /// degrades to BM25 alone instead of failing, so this is a capability report,
  /// not an error.
  let semanticAvailable: Bool

  var isComplete: Bool { total > 0 && embedded >= total }
}

/// Mean-pooled sentence vectors from Apple's on-device contextual embedding model.
///
/// The framework choice was measured on this SDK, not assumed, against four
/// (anchor, related, unrelated) passage triples drawn from the kind of prose this
/// app actually indexes:
///
/// - `NLEmbedding.sentenceEmbedding(for: .simplifiedChinese)` (640-dim) scored
///   2/4. It ranked the unrelated passage *closer* than the related one half the
///   time, which is worse than no semantic search at all — it would actively
///   promote noise into the prompt.
/// - `NLEmbedding.wordEmbedding` is unusable for a different reason: 渡口 is
///   outside its 30 278-word vocabulary, and out-of-vocabulary lookups return the
///   2.0 sentinel rather than a distance, so multi-character story nouns simply
///   have no vector.
/// - `NLContextualEmbedding` (transformer, 512-dim) scored 4/4 with clear margins
///   (related 0.17-0.23 against unrelated 0.32-0.47) at 85 passages/sec, so a
///   5 500-passage novel embeds in about a minute.
///
/// The model ships as an on-device asset and is loaded in-process: no service is
/// contacted, no runtime is added, nothing is downloaded at use time.
@available(macOS 14.0, *)
final class SourceEmbedder {
  private let model: NLContextualEmbedding
  let dimension: Int

  init() throws {
    guard let model = NLContextualEmbedding(language: .simplifiedChinese) else {
      throw InkOSCoreError("本机没有可用的中文语义模型，检索将退化为纯 BM25", statusCode: 500)
    }
    do {
      try model.load()
    } catch {
      throw InkOSCoreError("中文语义模型加载失败：\(error.localizedDescription)", statusCode: 500)
    }
    self.model = model
    dimension = model.dimension
  }

  deinit { model.unload() }

  /// L2-normalized mean of the token vectors. Normalizing here is what lets
  /// `semanticSearch` rank by a plain dot product.
  func vector(for text: String) throws -> [Float] {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw InkOSCoreError("空文本无法生成语义向量", statusCode: 400)
    }
    let result = try model.embeddingResult(for: trimmed, language: .simplifiedChinese)
    var sum = [Double](repeating: 0, count: dimension)
    var tokens = 0
    result.enumerateTokenVectors(in: trimmed.startIndex..<trimmed.endIndex) { vector, _ in
      for (index, value) in vector.enumerated() where index < sum.count {
        sum[index] += value
      }
      tokens += 1
      return true
    }
    guard tokens > 0 else {
      throw InkOSCoreError("语义模型未返回任何 token 向量", statusCode: 500)
    }
    let mean = sum.map { $0 / Double(tokens) }
    let norm = mean.reduce(0) { $0 + $1 * $1 }.squareRoot()
    guard norm > 0 else {
      throw InkOSCoreError("语义向量为零向量", statusCode: 500)
    }
    return mean.map { Float($0 / norm) }
  }
}

extension InkOSCore {
  private func sourceIndexURL(_ bookID: String) throws -> URL {
    let url = try sourceDirectoryURL(bookID).appendingPathComponent("passages.sqlite")
    guard fileManager.fileExists(atPath: url.path) else {
      throw InkOSCoreError("尚未导入原著，请先导入原著文本", statusCode: 404)
    }
    return url
  }

  /// Fills in the passage vectors the ingest left NULL.
  ///
  /// Resumable by construction: `vector IS NULL` is the work queue, so an
  /// interrupted pass continues where it stopped and a completed pass is a no-op.
  @discardableResult
  func embedDerivativeSource(bookID: String, batchSize: Int = 200) throws -> SourceEmbeddingStatus {
    let index = try SourceSearchIndex(path: try sourceIndexURL(bookID).path, reset: false)
    defer { index.close() }
    guard #available(macOS 14.0, *) else {
      let coverage = try index.vectorCoverage()
      recordDebug(scope: "derivative", message: "source.semantic_unsupported", level: "warning", data: [
        "bookId": bookID,
        "reason": "语义模型需要 macOS 14 及以上，检索退化为纯 BM25。",
      ])
      return SourceEmbeddingStatus(
        embedded: coverage.embedded,
        total: coverage.total,
        semanticAvailable: false
      )
    }
    let embedder = try SourceEmbedder()
    var embedded = 0
    var failed = 0
    while true {
      let pending = try index.passagesMissingVectors(limit: batchSize)
      if pending.isEmpty { break }
      try index.beginTransaction()
      for passage in pending {
        var vector: [Float]
        do {
          vector = try embedder.vector(for: passage.text)
          embedded += 1
        } catch {
          // A passage the model rejects (pure punctuation, stray control bytes)
          // must not stall the queue: leaving it NULL would make the next
          // `passagesMissingVectors` return the same row forever. A zero vector
          // records "attempted, unusable" and scores 0 on the dot product, i.e.
          // dead last, so it never displaces a real hit.
          vector = [Float](repeating: 0, count: embedder.dimension)
          failed += 1
        }
        try index.storeVector(
          vector,
          chapterIndex: passage.chapterIndex,
          paragraphIndex: passage.paragraphIndex
        )
      }
      try index.commitTransaction()
    }
    let coverage = try index.vectorCoverage()
    recordDebug(scope: "derivative", message: "source.embedded", data: [
      "bookId": bookID,
      "embeddedThisPass": embedded,
      "unusable": failed,
      "coverage": "\(coverage.embedded)/\(coverage.total)",
      "dimension": embedder.dimension,
    ])
    return SourceEmbeddingStatus(
      embedded: coverage.embedded,
      total: coverage.total,
      semanticAvailable: true
    )
  }

  func derivativeSourceEmbeddingStatus(bookID: String) throws -> SourceEmbeddingStatus {
    let index = try SourceSearchIndex(path: try sourceIndexURL(bookID).path, reset: false)
    defer { index.close() }
    let coverage = try index.vectorCoverage()
    var available = false
    if #available(macOS 14.0, *) {
      available = NLContextualEmbedding(language: .simplifiedChinese) != nil
    }
    return SourceEmbeddingStatus(
      embedded: coverage.embedded,
      total: coverage.total,
      semanticAvailable: available
    )
  }
}

// MARK: - Hybrid retrieval

/// A retrieved passage plus its provenance in each retrieval half, so a prompt
/// builder (and a human reading the debug log) can tell why a passage surfaced.
struct SourceRetrievalHit: Codable, Equatable, Sendable {
  let chapterIndex: Int
  let chapterTitle: String
  let paragraphIndex: Int
  let text: String
  /// Fused score. Higher is better here, unlike the per-engine scores, because
  /// reciprocal rank fusion sums rank contributions instead of comparing raw
  /// magnitudes.
  let score: Double
  /// 1-based rank in the BM25 result list, nil when only the semantic half found it.
  let lexicalRank: Int?
  /// 1-based rank in the semantic result list, nil when only BM25 found it.
  let semanticRank: Int?
}

extension InkOSCore {
  /// Reciprocal rank fusion constant. 60 is the value from the original RRF
  /// paper and the one every mainstream hybrid-search stack ships with; it damps
  /// the top ranks enough that a single engine cannot monopolize the result.
  private static let retrievalFusionK = 60.0

  /// Weight on the semantic half's rank contribution, below the lexical half's 1.0.
  ///
  /// Textbook RRF weights both halves equally, which assumes both are strong. On a
  /// 21 000-passage novel this one is not: `NLContextualEmbedding` mean-pooled over
  /// ~210-character paragraphs scores AUC 0.628 at telling a passage containing the
  /// queried term from one that does not (0.5 is no signal), and recall@10 is 14.6%.
  /// The four-triple probe that justified picking the model measured a much easier
  /// task — distinct topics, tens of passages — so it did not surface this.
  ///
  /// Measured cost of the equal vote: over six terms whose answers are all in the
  /// source, precision@8 falls from 100% to 61.3% because semantic-only passages
  /// displace correct BM25 hits. At 0.3 a lexical hit at rank r contributes
  /// 1/(60+r) against the semantic half's 0.3/(60+r), so the semantic half can
  /// reorder passages BM25 already found and fill slots BM25 left empty, but it
  /// cannot evict a lexical hit. Precision@8 stays at 100% for every weight <= 0.5.
  ///
  /// A similarity floor would be the alternative and it is not available: a gold
  /// passage scores 0.905 while the 99th percentile of unrelated passages scores
  /// 0.910, so no threshold separates them. Centering and ZCA whitening were both
  /// measured and neither recovers the ranking (top-1 0.8% -> 2.6%).
  private static let retrievalSemanticWeight = 0.3

  /// Hybrid retrieval over the ingested original: BM25 on `keys`, semantic on
  /// `query`, fused by reciprocal rank fusion.
  ///
  /// RRF rather than a weighted sum of the two scores because the scores are not
  /// commensurable: `bm25()` is unbounded, negative, and scaled by corpus
  /// statistics, while cosine similarity is bounded in [-1, 1]. Normalizing one
  /// onto the other needs per-corpus calibration that silently rots as the index
  /// grows; summing `1 / (k + rank)` needs none.
  ///
  /// The two halves also fail differently, which is the real reason to keep both:
  /// BM25 cannot find a passage that never names the key ("那条船" for 渡船), and
  /// the embedding cannot reliably pin a rare proper noun it never saw in
  /// training. A passage both halves rank climbs above either one alone.
  func retrieveDerivativeContext(
    bookID: String,
    keys: [String],
    query: String? = nil,
    limit: Int = 8
  ) throws -> [SourceRetrievalHit] {
    let databaseURL = try sourceIndexURL(bookID)
    // Fuse from a deeper pool than we return: a passage ranked 15th lexically and
    // 3rd semantically should be able to win, and it cannot if the pool is the
    // same size as the output.
    let pool = Swift.max(limit * 4, 20)
    let lexical = try searchDerivativeSource(bookID: bookID, keys: keys, limit: pool)
    let semanticQuery = (query ?? keys.joined(separator: "，"))
      .trimmingCharacters(in: .whitespacesAndNewlines)

    // Keys that match nothing mean the caller asked about something this novel
    // does not contain. The semantic half cannot report that: a dot product always
    // has a maximum, so it fills every slot with its least-unrelated passages —
    // measured at 8 of 8 for 量子计算机集群 against 诡秘之主. Those passages are
    // rendered into the prompt as source canon, so the model would treat noise as
    // fact. Returning nothing is the honest answer. A caller that passes no keys at
    // all is explicitly asking for paraphrase search and still gets the semantic
    // half; this only suppresses it when supplied keys came back empty.
    if !keys.isEmpty, lexical.isEmpty {
      recordDebug(
        scope: "derivative",
        message: "source.no_lexical_match",
        data: ["bookId": bookID, "keys": keys.joined(separator: "|")]
      )
      return []
    }

    var semantic: [SourcePassage] = []
    if #available(macOS 14.0, *), !semanticQuery.isEmpty {
      // Best-effort: the semantic half is an enhancement, so a machine that
      // cannot load the model still gets BM25 results instead of an error.
      do {
        let embedder = try SourceEmbedder()
        let vector = try embedder.vector(for: semanticQuery)
        let index = try SourceSearchIndex(path: databaseURL.path, reset: false)
        defer { index.close() }
        semantic = try index.semanticSearch(query: vector, limit: pool)
      } catch {
        recordDebug(
          scope: "derivative",
          message: "source.semantic_skipped",
          level: "warning",
          data: ["bookId": bookID, "error": error.localizedDescription]
        )
      }
    }

    var fused: [String: SourceRetrievalHit] = [:]
    func fuse(_ passages: [SourcePassage], lexicalHalf: Bool) {
      for (offset, passage) in passages.enumerated() {
        let rank = offset + 1
        let weight = lexicalHalf ? 1.0 : Self.retrievalSemanticWeight
        let contribution = weight / (Self.retrievalFusionK + Double(rank))
        let key = "\(passage.chapterIndex)#\(passage.paragraphIndex)"
        let existing = fused[key]
        fused[key] = SourceRetrievalHit(
          chapterIndex: passage.chapterIndex,
          chapterTitle: passage.chapterTitle,
          paragraphIndex: passage.paragraphIndex,
          text: existing?.text ?? passage.text,
          score: (existing?.score ?? 0) + contribution,
          lexicalRank: lexicalHalf ? rank : existing?.lexicalRank,
          semanticRank: lexicalHalf ? existing?.semanticRank : rank
        )
      }
    }
    fuse(lexical, lexicalHalf: true)
    fuse(semantic, lexicalHalf: false)

    let ranked = fused.values
      .sorted {
        $0.score != $1.score
          ? $0.score > $1.score
          : ($0.chapterIndex, $0.paragraphIndex) < ($1.chapterIndex, $1.paragraphIndex)
      }
      .prefix(limit)
      .map { $0 }
    recordDebug(scope: "derivative", message: "source.retrieved", data: [
      "bookId": bookID,
      "keys": keys.joined(separator: "|"),
      "lexicalHits": lexical.count,
      "semanticHits": semantic.count,
      "returned": ranked.count,
      "bothHalves": ranked.filter { $0.lexicalRank != nil && $0.semanticRank != nil }.count,
    ])
    return ranked
  }

  /// Renders retrieved passages as a prompt section, newest chapter order first.
  ///
  /// Budgeted in characters because that is the unit the rest of the prompt
  /// budgeting uses; a passage is dropped whole rather than cut mid-sentence, so
  /// the model never sees a truncated quotation it might treat as canon.
  func derivativeSourceContext(
    bookID: String,
    keys: [String],
    query: String? = nil,
    limit: Int = 8,
    maxCharacters: Int = 6_000
  ) throws -> String {
    let hits = try retrieveDerivativeContext(bookID: bookID, keys: keys, query: query, limit: limit)
    guard !hits.isEmpty else { return "（原著检索无命中，本章不得引用未检索到的原著细节）" }
    var sections: [String] = []
    var used = 0
    for hit in hits.sorted(by: { ($0.chapterIndex, $0.paragraphIndex) < ($1.chapterIndex, $1.paragraphIndex) }) {
      let header = "【原著 第\(hit.chapterIndex)章 \(hit.chapterTitle) 第\(hit.paragraphIndex + 1)段】"
      let block = "\(header)\n\(hit.text)"
      if used + block.count > maxCharacters { continue }
      sections.append(block)
      used += block.count
    }
    return sections.isEmpty ? "（原著检索命中过长，已全部略去）" : sections.joined(separator: "\n\n")
  }
}
