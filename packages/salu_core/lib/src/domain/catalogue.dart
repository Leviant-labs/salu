import 'food.dart';

/// Validates a GTIN checksum; does not establish registration or product identity.
final class ProductBarcode {
  ProductBarcode(String input) : value = input.replaceAll(RegExp(r'\s'), '') {
    if (!RegExp(r'^(\d{8}|\d{12}|\d{13}|\d{14})$').hasMatch(value)) {
      throw const FormatException('Expected a GTIN-8/12/13/14 barcode');
    }
    var sum = 0, weight = 3;
    for (var i = value.length - 2; i >= 0; i--) {
      sum += int.parse(value[i]) * weight;
      weight = weight == 3 ? 1 : 3;
    }
    if ((10 - sum % 10) % 10 != int.parse(value[value.length - 1])) {
      throw const FormatException('Invalid barcode check digit');
    }
  }
  final String value;
}

final class CatalogueQuery {
  CatalogueQuery(this.text, {this.preparation, this.region, this.limit = 30}) {
    if (text.length > 300) throw ArgumentError('Search text is too long');
    if (limit < 1 || limit > 200) {
      throw ArgumentError('Search limit must be 1..200');
    }
  }
  final String text;
  final Preparation? preparation;
  final String? region;
  final int limit;
}

/// A pinned licence/content review, provided by the application release policy.
/// It is never read from a catalogue pack's self-declared approval field.
final class DatasetReview {
  const DatasetReview(
      {required this.dataset,
      required this.version,
      required this.licence,
      required this.reviewId});
  final String dataset, version, licence, reviewId;
}
