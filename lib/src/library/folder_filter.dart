import 'dart:convert';

import 'library_store.dart';

/// How big a comic is on disk, in ranges a person picks from.
enum SizeRange {
  any('Any size'),
  under10('Under 10 MB', max: 10),
  to50('10 to 50 MB', min: 10, max: 50),
  to200('50 to 200 MB', min: 50, max: 200),
  over200('Over 200 MB', min: 200);

  const SizeRange(this.label, {this.min, this.max});

  final String label;

  /// Bounds in MB (10^6 bytes, as file managers count), from inclusive, to
  /// exclusive; null is open.
  final int? min, max;

  bool accepts(int? bytes) {
    if (this == any) return true;
    if (bytes == null) return false;
    final mb = bytes / 1e6;
    return (min == null || mb >= min!) && (max == null || mb < max!);
  }
}

/// When a comic's file last changed, in ranges back from now.
enum DateRange {
  any('Any time'),
  day('Last 24 hours', within: Duration(days: 1)),
  week('Last 7 days', within: Duration(days: 7)),
  month('Last 30 days', within: Duration(days: 30)),
  year('Last 12 months', within: Duration(days: 365)),
  older('Over a year ago', before: Duration(days: 365));

  const DateRange(this.label, {this.within, this.before});

  final String label;
  final Duration? within, before;

  bool accepts(DateTime? modified, DateTime now) {
    if (this == any) return true;
    if (modified == null) return false;
    final age = now.difference(modified);
    return (within == null || age <= within!) && (before == null || age > before!);
  }
}

/// Whether a comic is completed ([LibraryBook.completed]: marked so, or
/// left on its last page), as the filter asks it.
enum CompletedFilter {
  any('Completed or not'),
  only('Completed only'),
  hide('Not completed');

  const CompletedFilter(this.label);

  final String label;

  bool accepts(bool completed) => switch (this) {
    any => true,
    only => completed,
    hide => !completed,
  };
}

/// The name a comic's format goes by in the filter, from [LibraryBook.format].
String formatLabel(String format) => switch (format) {
  'cbz' => 'CBZ',
  'cbt' => 'CBT',
  'pdf' => 'PDF',
  'epub' => 'EPUB',
  'folder' => 'Image folder',
  'image' => 'Single image',
  _ => format.toUpperCase(),
};

/// The Folders tab's filter (`F`): the comics of some types, sizes and
/// modification dates, completed or not. Each part left at its default
/// lets everything through; the parts combine, and with the search.
///
/// A new part is a field with a default that lets everything through, a
/// line each in [isActive], [accepts], [copyWith], [encode], [decode], `==`
/// and [hashCode], chips in the dialog and a part on the filter line. A
/// saved filter without the part reads as its default, so older settings
/// keep working.
class FolderFilter {
  const FolderFilter({
    this.formats = const {},
    this.size = SizeRange.any,
    this.date = DateRange.any,
    this.completed = CompletedFilter.any,
  });

  /// The formats shown, by [LibraryBook.format]; empty shows them all.
  final Set<String> formats;
  final SizeRange size;
  final DateRange date;
  final CompletedFilter completed;

  static const none = FolderFilter();

  bool get isActive =>
      formats.isNotEmpty || size != SizeRange.any || date != DateRange.any || completed != CompletedFilter.any;

  bool accepts(LibraryBook b, DateTime now) =>
      (formats.isEmpty || formats.contains(b.format)) &&
      size.accepts(b.size) &&
      date.accepts(b.modified, now) &&
      completed.accepts(b.completed);

  FolderFilter copyWith({Set<String>? formats, SizeRange? size, DateRange? date, CompletedFilter? completed}) =>
      FolderFilter(
        formats: formats ?? this.formats,
        size: size ?? this.size,
        date: date ?? this.date,
        completed: completed ?? this.completed,
      );

  /// [format] shown or not, the others as they are.
  FolderFilter toggle(String format) {
    final next = {...formats};
    if (!next.remove(format)) next.add(format);
    return copyWith(formats: next);
  }

  /// For the setting: null when nothing is filtered. `completed` is left
  /// out at its default, so a filter without it is saved as it always was.
  String? encode() => isActive
      ? jsonEncode({
          'formats': (formats.toList()..sort()),
          'size': size.name,
          'date': date.name,
          if (completed != CompletedFilter.any) 'completed': completed.name,
        })
      : null;

  /// A saved filter; anything unreadable in it counts as not filtered.
  static FolderFilter decode(String? text) {
    if (text == null) return none;
    try {
      final j = jsonDecode(text);
      if (j is! Map) return none;
      return FolderFilter(
        formats: {
          for (final f in j['formats'] is List ? j['formats'] as List : const [])
            if (f is String) f,
        },
        size: SizeRange.values.asNameMap()[j['size']] ?? SizeRange.any,
        date: DateRange.values.asNameMap()[j['date']] ?? DateRange.any,
        // Not in a filter saved before comics could be completed.
        completed: CompletedFilter.values.asNameMap()[j['completed']] ?? CompletedFilter.any,
      );
    } on FormatException {
      return none;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is FolderFilter &&
      other.size == size &&
      other.date == date &&
      other.completed == completed &&
      other.formats.length == formats.length &&
      other.formats.containsAll(formats);

  @override
  int get hashCode => Object.hash(size, date, completed, Object.hashAllUnordered(formats));
}
