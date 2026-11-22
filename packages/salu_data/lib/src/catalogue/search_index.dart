import 'package:drift/drift.dart';
import 'package:salu_core/salu_core.dart';

import '../database/app_database.dart';
import '../repositories/local_document_store.dart';
import 'bundled_catalogue_data.dart';

/// Current persisted format version for the `food_names` FTS5 index.
const int searchIndexVersion = 1;

/// Local document key storing the persisted FTS5 index state.
const String searchIndexStateKey = 'search-index-state';

/// Sentinel rank returned when a label does not match a query.
const int searchNoMatch = 8;

/// Computes the match rank of a folded [label] against [query] and [queryWords].
///
/// Lower values are better matches; [searchNoMatch] indicates no match.
int searchRank(
  String label,
  String query,
  List<String> queryWords, {
  required bool alias,
}) {
  final offset = alias ? 1 : 0;
  if (label == query) return offset;
  if (label.startsWith(query)) return 2 + offset;
  final words = label.split(' ');
  if (queryWords.every((part) => words.any((word) => word.startsWith(part)))) {
    return 4 + offset;
  }
  if (label.contains(query)) return 6 + offset;
  return searchNoMatch;
}

// SQLite's built-in lower/NOCASE only folds ASCII. Cover Portuguese and other
// common Latin accent variants here, including decomposed input from keyboards.
const _foldGroups = {
  'àáâãäåāăą': 'a',
  'çćč': 'c',
  'èéêëēėęě': 'e',
  'ìíîïīįı': 'i',
  'ł': 'l',
  'ñń': 'n',
  'òóôõöøōő': 'o',
  'śš': 's',
  'ùúûüūůű': 'u',
  'ýÿ': 'y',
  'źżž': 'z',
  'æ': 'ae',
  'œ': 'oe',
  'ß': 'ss',
};
final _foldVariants = {
  for (final entry in _foldGroups.entries)
    for (final letter in entry.key.split('')) letter: entry.value,
};
final _accentedLatin = RegExp('[${_foldGroups.keys.join()}]');
final _combiningMarks = RegExp(r'\p{M}+', unicode: true);
final _wordSeparators = RegExp(r'[^\p{L}\p{N}]+', unicode: true);

/// Folds accents, case, and punctuation for accent-insensitive search.
String foldSearchText(String text) => text
    .toLowerCase()
    .replaceAll(_combiningMarks, '')
    .replaceAllMapped(_accentedLatin, (match) => _foldVariants[match[0]]!)
    .replaceAll(_wordSeparators, ' ')
    .trim();

/// Computes the best rank for a catalogue row, including bundled aliases.
({String foldedName, int rank}) rankCatalogueRow(
  String id,
  String name,
  String source,
  String foldedQuery,
  List<String> queryWords,
) {
  final foldedName = foldSearchText(name);
  var rank = searchRank(foldedName, foldedQuery, queryWords, alias: false);
  if (source == bundledCatalogueDataset) {
    final aliases = bundledCatalogueEntries[id]?.aliases ?? const <String>[];
    for (final alias in aliases) {
      final aliasRank = searchRank(
        foldSearchText(alias),
        foldedQuery,
        queryWords,
        alias: true,
      );
      if (aliasRank < rank) rank = aliasRank;
    }
  }
  return (foldedName: foldedName, rank: rank);
}

/// Manages the persistent FTS5 search index (`food_names`) and keyset fallback.
final class SearchIndex {
  /// Creates a search index bound to [_db].
  ///
  /// Setting [forceFallback] to `true` bypasses FTS5 and exercises the
  /// ordered keyset pagination fallback across the entire catalogue.
  SearchIndex(this._db, {this.forceFallback = false});

  final AppDatabase _db;

  /// When `true`, skips FTS5 and always uses keyset-paginated fallback scans.
  final bool forceFallback;

  static const _fallbackPageSize = 512;
  static const _batchChunkSize = 200;

  /// Ensures the `food_names` FTS5 table exists and matches [searchIndexVersion].
  ///
  /// Returns `true` if FTS5 is ready, or `false` if [forceFallback] is set or
  /// the SQLite build lacks FTS5. When a valid index already exists, returns
  /// immediately without rebuilding.
  Future<bool> ensureReady() async {
    if (forceFallback) return false;
    if (await _isReady()) return true;

    return _db.transaction(() async {
      if (await _isReady()) return true;
      try {
        await _db.customStatement(
          'CREATE VIRTUAL TABLE IF NOT EXISTS food_names '
          'USING fts5(food_id UNINDEXED, search_text)',
        );
      } catch (_) {
        return false;
      }

      await _db.customStatement('DELETE FROM food_names');
      final table = _db.catalogFoods;
      String? lastId;
      while (true) {
        final query = _db.selectOnly(table)
          ..addColumns([table.id, table.name, table.source])
          ..orderBy([OrderingTerm.asc(table.id)])
          ..limit(_fallbackPageSize);
        if (lastId != null) {
          query.where(table.id.isBiggerThanValue(lastId));
        }
        final rows = await query.get();
        if (rows.isEmpty) break;
        final batchEntries = [
          for (final row in rows)
            (
              id: row.read(table.id)!,
              text: _buildSearchText(
                row.read(table.id)!,
                row.read(table.name)!,
                row.read(table.source)!,
              ),
            ),
        ];
        await _insertBatch(batchEntries);
        lastId = rows.last.read(table.id);
        if (rows.length < _fallbackPageSize) break;
      }

      final documents = LocalDocumentStore(_db);
      final existing = await documents.read(searchIndexStateKey);
      await documents.put(
        searchIndexStateKey,
        existing?.revision ?? 0,
        {'format': searchIndexVersion},
      );
      return true;
    });
  }

  /// Incrementally replaces FTS rows for [foods] inside the caller's transaction
  /// when the index is already ready.
  Future<void> replaceRows(Iterable<Food> foods) async {
    final list = foods.toList(growable: false);
    if (list.isEmpty) return;
    if (!await _isReady()) return;

    final ids = [for (final food in list) food.id];
    for (var i = 0; i < ids.length; i += _batchChunkSize) {
      final chunk = ids.sublist(
        i,
        i + _batchChunkSize > ids.length ? ids.length : i + _batchChunkSize,
      );
      final placeholders = List.filled(chunk.length, '?').join(', ');
      await _db.customStatement(
        'DELETE FROM food_names WHERE food_id IN ($placeholders)',
        chunk,
      );
    }

    final entries = [
      for (final food in list)
        (
          id: food.id,
          text: _buildSearchText(food.id, food.name, food.source.dataset),
        ),
    ];
    await _insertBatch(entries);
  }

  /// Removes all FTS rows belonging to [dataset] inside the caller's transaction
  /// when the index is already ready.
  Future<void> removeDataset(String dataset) async {
    if (!await _isReady()) return;
    await _db.customStatement(
      'DELETE FROM food_names '
      'WHERE food_id IN (SELECT id FROM catalog_foods WHERE source = ?) '
      'OR food_id LIKE ?',
      [dataset, '$dataset:%'],
    );
  }

  /// Searches the catalogue and returns ranked food IDs up to [limit].
  Future<List<String>> searchIds(String query, {int limit = 20}) async {
    if (limit <= 0) return const [];
    final table = _db.catalogFoods;
    final text = query.trim();
    if (text.isEmpty) {
      final rows = await (_db.selectOnly(table)
            ..addColumns([table.id])
            ..orderBy([OrderingTerm.asc(table.id)])
            ..limit(limit))
          .get();
      return [for (final row in rows) row.read(table.id)!];
    }

    final foldedQuery = foldSearchText(text);
    if (foldedQuery.isEmpty) return const [];
    final queryWords = foldedQuery.split(' ');
    final indexed = await ensureReady();
    if (indexed) {
      return _searchFts(foldedQuery, queryWords, limit);
    }
    return _searchFallback(foldedQuery, queryWords, limit);
  }

  Future<bool> _isReady() async {
    if (forceFallback) return false;
    final tableRows = await _db
        .customSelect(
          "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'food_names'",
        )
        .get();
    if (tableRows.isEmpty) return false;
    final state = await LocalDocumentStore(_db).read(searchIndexStateKey);
    return state?.data['format'] == searchIndexVersion;
  }

  String _buildSearchText(String id, String name, String source) {
    final aliases = source == bundledCatalogueDataset
        ? bundledCatalogueEntries[id]?.aliases ?? const <String>[]
        : const <String>[];
    return foldSearchText([name, ...aliases].join(' '));
  }

  Future<void> _insertBatch(List<({String id, String text})> entries) async {
    for (var i = 0; i < entries.length; i += _batchChunkSize) {
      final chunk = entries.sublist(
        i,
        i + _batchChunkSize > entries.length
            ? entries.length
            : i + _batchChunkSize,
      );
      final placeholders = List.filled(chunk.length, '(?, ?)').join(', ');
      final args = <Object?>[
        for (final entry in chunk) ...[entry.id, entry.text],
      ];
      await _db.customStatement(
        'INSERT INTO food_names (food_id, search_text) VALUES $placeholders',
        args,
      );
    }
  }

  Future<List<String>> _searchFts(
    String foldedQuery,
    List<String> queryWords,
    int limit,
  ) async {
    final hits = await _db.customSelect(
      'SELECT food_id FROM food_names WHERE food_names MATCH ? '
      'ORDER BY rank LIMIT ?',
      variables: [
        Variable.withString(
          queryWords.map((word) => '"$word"*').join(' AND '),
        ),
        Variable.withInt(2000),
      ],
    ).get();
    if (hits.isEmpty) return const [];

    final table = _db.catalogFoods;
    final hitIds = [for (final row in hits) row.read<String>('food_id')];
    final candidates = <TypedResult>[];
    for (var i = 0; i < hitIds.length; i += _batchChunkSize) {
      final chunk = hitIds.sublist(
        i,
        i + _batchChunkSize > hitIds.length
            ? hitIds.length
            : i + _batchChunkSize,
      );
      candidates.addAll(
        await (_db.selectOnly(table)
              ..addColumns([table.id, table.name, table.source])
              ..where(table.id.isIn(chunk)))
            .get(),
      );
    }

    final matches = <({String id, String name, int rank})>[];
    for (final row in candidates) {
      final id = row.read(table.id)!;
      final scored = rankCatalogueRow(
        id,
        row.read(table.name)!,
        row.read(table.source)!,
        foldedQuery,
        queryWords,
      );
      if (scored.rank != searchNoMatch) {
        matches.add((id: id, name: scored.foldedName, rank: scored.rank));
      }
    }
    matches.sort(_compareMatches);
    return matches.take(limit).map((m) => m.id).toList(growable: false);
  }

  Future<List<String>> _searchFallback(
    String foldedQuery,
    List<String> queryWords,
    int limit,
  ) async {
    final table = _db.catalogFoods;
    final best = <({String id, String name, int rank})>[];
    String? lastId;

    while (true) {
      final query = _db.selectOnly(table)
        ..addColumns([table.id, table.name, table.source])
        ..orderBy([OrderingTerm.asc(table.id)])
        ..limit(_fallbackPageSize);
      if (lastId != null) {
        query.where(table.id.isBiggerThanValue(lastId));
      }
      final page = await query.get();
      if (page.isEmpty) break;

      var added = false;
      for (final row in page) {
        final id = row.read(table.id)!;
        final scored = rankCatalogueRow(
          id,
          row.read(table.name)!,
          row.read(table.source)!,
          foldedQuery,
          queryWords,
        );
        if (scored.rank != searchNoMatch) {
          best.add((id: id, name: scored.foldedName, rank: scored.rank));
          added = true;
        }
      }
      if (added) {
        best.sort(_compareMatches);
        if (best.length > limit) {
          best.removeRange(limit, best.length);
        }
      }

      lastId = page.last.read(table.id);
      if (page.length < _fallbackPageSize) break;
      await Future<void>.delayed(Duration.zero);
    }

    return best.map((m) => m.id).toList(growable: false);
  }

  static int _compareMatches(
    ({String id, String name, int rank}) a,
    ({String id, String name, int rank}) b,
  ) {
    final rank = a.rank.compareTo(b.rank);
    if (rank != 0) return rank;
    final name = a.name.compareTo(b.name);
    return name == 0 ? a.id.compareTo(b.id) : name;
  }
}
