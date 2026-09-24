// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_database.dart';

// ignore_for_file: type=lint
class $SeriesTableTable extends SeriesTable
    with TableInfo<$SeriesTableTable, Series> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SeriesTableTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sortNameMeta = const VerificationMeta(
    'sortName',
  );
  @override
  late final GeneratedColumn<String> sortName = GeneratedColumn<String>(
    'sort_name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _rtlMeta = const VerificationMeta('rtl');
  @override
  late final GeneratedColumn<bool> rtl = GeneratedColumn<bool>(
    'rtl',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("rtl" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  @override
  List<GeneratedColumn> get $columns => [id, name, sortName, rtl];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'series';
  @override
  VerificationContext validateIntegrity(
    Insertable<Series> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('sort_name')) {
      context.handle(
        _sortNameMeta,
        sortName.isAcceptableOrUnknown(data['sort_name']!, _sortNameMeta),
      );
    } else if (isInserting) {
      context.missing(_sortNameMeta);
    }
    if (data.containsKey('rtl')) {
      context.handle(
        _rtlMeta,
        rtl.isAcceptableOrUnknown(data['rtl']!, _rtlMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Series map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Series(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      sortName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sort_name'],
      )!,
      rtl: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}rtl'],
      )!,
    );
  }

  @override
  $SeriesTableTable createAlias(String alias) {
    return $SeriesTableTable(attachedDatabase, alias);
  }
}

class Series extends DataClass implements Insertable<Series> {
  final int id;
  final String name;
  final String sortName;
  final bool rtl;
  const Series({
    required this.id,
    required this.name,
    required this.sortName,
    required this.rtl,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['name'] = Variable<String>(name);
    map['sort_name'] = Variable<String>(sortName);
    map['rtl'] = Variable<bool>(rtl);
    return map;
  }

  SeriesTableCompanion toCompanion(bool nullToAbsent) {
    return SeriesTableCompanion(
      id: Value(id),
      name: Value(name),
      sortName: Value(sortName),
      rtl: Value(rtl),
    );
  }

  factory Series.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Series(
      id: serializer.fromJson<int>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      sortName: serializer.fromJson<String>(json['sortName']),
      rtl: serializer.fromJson<bool>(json['rtl']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'name': serializer.toJson<String>(name),
      'sortName': serializer.toJson<String>(sortName),
      'rtl': serializer.toJson<bool>(rtl),
    };
  }

  Series copyWith({int? id, String? name, String? sortName, bool? rtl}) =>
      Series(
        id: id ?? this.id,
        name: name ?? this.name,
        sortName: sortName ?? this.sortName,
        rtl: rtl ?? this.rtl,
      );
  Series copyWithCompanion(SeriesTableCompanion data) {
    return Series(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      sortName: data.sortName.present ? data.sortName.value : this.sortName,
      rtl: data.rtl.present ? data.rtl.value : this.rtl,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Series(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('sortName: $sortName, ')
          ..write('rtl: $rtl')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, name, sortName, rtl);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Series &&
          other.id == this.id &&
          other.name == this.name &&
          other.sortName == this.sortName &&
          other.rtl == this.rtl);
}

class SeriesTableCompanion extends UpdateCompanion<Series> {
  final Value<int> id;
  final Value<String> name;
  final Value<String> sortName;
  final Value<bool> rtl;
  const SeriesTableCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.sortName = const Value.absent(),
    this.rtl = const Value.absent(),
  });
  SeriesTableCompanion.insert({
    this.id = const Value.absent(),
    required String name,
    required String sortName,
    this.rtl = const Value.absent(),
  }) : name = Value(name),
       sortName = Value(sortName);
  static Insertable<Series> custom({
    Expression<int>? id,
    Expression<String>? name,
    Expression<String>? sortName,
    Expression<bool>? rtl,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (sortName != null) 'sort_name': sortName,
      if (rtl != null) 'rtl': rtl,
    });
  }

  SeriesTableCompanion copyWith({
    Value<int>? id,
    Value<String>? name,
    Value<String>? sortName,
    Value<bool>? rtl,
  }) {
    return SeriesTableCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      sortName: sortName ?? this.sortName,
      rtl: rtl ?? this.rtl,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (sortName.present) {
      map['sort_name'] = Variable<String>(sortName.value);
    }
    if (rtl.present) {
      map['rtl'] = Variable<bool>(rtl.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SeriesTableCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('sortName: $sortName, ')
          ..write('rtl: $rtl')
          ..write(')'))
        .toString();
  }
}

class $BooksTable extends Books with TableInfo<$BooksTable, Book> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $BooksTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _contentKeyMeta = const VerificationMeta(
    'contentKey',
  );
  @override
  late final GeneratedColumn<String> contentKey = GeneratedColumn<String>(
    'content_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _seriesIdMeta = const VerificationMeta(
    'seriesId',
  );
  @override
  late final GeneratedColumn<int> seriesId = GeneratedColumn<int>(
    'series_id',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES series (id)',
    ),
  );
  static const VerificationMeta _numberMeta = const VerificationMeta('number');
  @override
  late final GeneratedColumn<String> number = GeneratedColumn<String>(
    'number',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _pageCountMeta = const VerificationMeta(
    'pageCount',
  );
  @override
  late final GeneratedColumn<int> pageCount = GeneratedColumn<int>(
    'page_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _formatMeta = const VerificationMeta('format');
  @override
  late final GeneratedColumn<String> format = GeneratedColumn<String>(
    'format',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _addedAtMeta = const VerificationMeta(
    'addedAt',
  );
  @override
  late final GeneratedColumn<DateTime> addedAt = GeneratedColumn<DateTime>(
    'added_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
    defaultValue: currentDateAndTime,
  );
  static const VerificationMeta _issueTitleMeta = const VerificationMeta(
    'issueTitle',
  );
  @override
  late final GeneratedColumn<String> issueTitle = GeneratedColumn<String>(
    'issue_title',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _volumeMeta = const VerificationMeta('volume');
  @override
  late final GeneratedColumn<int> volume = GeneratedColumn<int>(
    'volume',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _yearMeta = const VerificationMeta('year');
  @override
  late final GeneratedColumn<int> year = GeneratedColumn<int>(
    'year',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _writersMeta = const VerificationMeta(
    'writers',
  );
  @override
  late final GeneratedColumn<String> writers = GeneratedColumn<String>(
    'writers',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _artistsMeta = const VerificationMeta(
    'artists',
  );
  @override
  late final GeneratedColumn<String> artists = GeneratedColumn<String>(
    'artists',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _summaryMeta = const VerificationMeta(
    'summary',
  );
  @override
  late final GeneratedColumn<String> summary = GeneratedColumn<String>(
    'summary',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    contentKey,
    title,
    seriesId,
    number,
    pageCount,
    format,
    addedAt,
    issueTitle,
    volume,
    year,
    writers,
    artists,
    summary,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'books';
  @override
  VerificationContext validateIntegrity(
    Insertable<Book> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('content_key')) {
      context.handle(
        _contentKeyMeta,
        contentKey.isAcceptableOrUnknown(data['content_key']!, _contentKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_contentKeyMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('series_id')) {
      context.handle(
        _seriesIdMeta,
        seriesId.isAcceptableOrUnknown(data['series_id']!, _seriesIdMeta),
      );
    }
    if (data.containsKey('number')) {
      context.handle(
        _numberMeta,
        number.isAcceptableOrUnknown(data['number']!, _numberMeta),
      );
    }
    if (data.containsKey('page_count')) {
      context.handle(
        _pageCountMeta,
        pageCount.isAcceptableOrUnknown(data['page_count']!, _pageCountMeta),
      );
    } else if (isInserting) {
      context.missing(_pageCountMeta);
    }
    if (data.containsKey('format')) {
      context.handle(
        _formatMeta,
        format.isAcceptableOrUnknown(data['format']!, _formatMeta),
      );
    } else if (isInserting) {
      context.missing(_formatMeta);
    }
    if (data.containsKey('added_at')) {
      context.handle(
        _addedAtMeta,
        addedAt.isAcceptableOrUnknown(data['added_at']!, _addedAtMeta),
      );
    }
    if (data.containsKey('issue_title')) {
      context.handle(
        _issueTitleMeta,
        issueTitle.isAcceptableOrUnknown(data['issue_title']!, _issueTitleMeta),
      );
    }
    if (data.containsKey('volume')) {
      context.handle(
        _volumeMeta,
        volume.isAcceptableOrUnknown(data['volume']!, _volumeMeta),
      );
    }
    if (data.containsKey('year')) {
      context.handle(
        _yearMeta,
        year.isAcceptableOrUnknown(data['year']!, _yearMeta),
      );
    }
    if (data.containsKey('writers')) {
      context.handle(
        _writersMeta,
        writers.isAcceptableOrUnknown(data['writers']!, _writersMeta),
      );
    }
    if (data.containsKey('artists')) {
      context.handle(
        _artistsMeta,
        artists.isAcceptableOrUnknown(data['artists']!, _artistsMeta),
      );
    }
    if (data.containsKey('summary')) {
      context.handle(
        _summaryMeta,
        summary.isAcceptableOrUnknown(data['summary']!, _summaryMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {contentKey};
  @override
  Book map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Book(
      contentKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}content_key'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      seriesId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}series_id'],
      ),
      number: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}number'],
      ),
      pageCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}page_count'],
      )!,
      format: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}format'],
      )!,
      addedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}added_at'],
      )!,
      issueTitle: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}issue_title'],
      ),
      volume: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}volume'],
      ),
      year: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}year'],
      ),
      writers: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}writers'],
      ),
      artists: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}artists'],
      ),
      summary: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}summary'],
      ),
    );
  }

  @override
  $BooksTable createAlias(String alias) {
    return $BooksTable(attachedDatabase, alias);
  }
}

class Book extends DataClass implements Insertable<Book> {
  final String contentKey;
  final String title;
  final int? seriesId;
  final String? number;
  final int pageCount;
  final String format;
  final DateTime addedAt;
  final String? issueTitle;
  final int? volume;
  final int? year;
  final String? writers;
  final String? artists;
  final String? summary;
  const Book({
    required this.contentKey,
    required this.title,
    this.seriesId,
    this.number,
    required this.pageCount,
    required this.format,
    required this.addedAt,
    this.issueTitle,
    this.volume,
    this.year,
    this.writers,
    this.artists,
    this.summary,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['content_key'] = Variable<String>(contentKey);
    map['title'] = Variable<String>(title);
    if (!nullToAbsent || seriesId != null) {
      map['series_id'] = Variable<int>(seriesId);
    }
    if (!nullToAbsent || number != null) {
      map['number'] = Variable<String>(number);
    }
    map['page_count'] = Variable<int>(pageCount);
    map['format'] = Variable<String>(format);
    map['added_at'] = Variable<DateTime>(addedAt);
    if (!nullToAbsent || issueTitle != null) {
      map['issue_title'] = Variable<String>(issueTitle);
    }
    if (!nullToAbsent || volume != null) {
      map['volume'] = Variable<int>(volume);
    }
    if (!nullToAbsent || year != null) {
      map['year'] = Variable<int>(year);
    }
    if (!nullToAbsent || writers != null) {
      map['writers'] = Variable<String>(writers);
    }
    if (!nullToAbsent || artists != null) {
      map['artists'] = Variable<String>(artists);
    }
    if (!nullToAbsent || summary != null) {
      map['summary'] = Variable<String>(summary);
    }
    return map;
  }

  BooksCompanion toCompanion(bool nullToAbsent) {
    return BooksCompanion(
      contentKey: Value(contentKey),
      title: Value(title),
      seriesId: seriesId == null && nullToAbsent
          ? const Value.absent()
          : Value(seriesId),
      number: number == null && nullToAbsent
          ? const Value.absent()
          : Value(number),
      pageCount: Value(pageCount),
      format: Value(format),
      addedAt: Value(addedAt),
      issueTitle: issueTitle == null && nullToAbsent
          ? const Value.absent()
          : Value(issueTitle),
      volume: volume == null && nullToAbsent
          ? const Value.absent()
          : Value(volume),
      year: year == null && nullToAbsent ? const Value.absent() : Value(year),
      writers: writers == null && nullToAbsent
          ? const Value.absent()
          : Value(writers),
      artists: artists == null && nullToAbsent
          ? const Value.absent()
          : Value(artists),
      summary: summary == null && nullToAbsent
          ? const Value.absent()
          : Value(summary),
    );
  }

  factory Book.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Book(
      contentKey: serializer.fromJson<String>(json['contentKey']),
      title: serializer.fromJson<String>(json['title']),
      seriesId: serializer.fromJson<int?>(json['seriesId']),
      number: serializer.fromJson<String?>(json['number']),
      pageCount: serializer.fromJson<int>(json['pageCount']),
      format: serializer.fromJson<String>(json['format']),
      addedAt: serializer.fromJson<DateTime>(json['addedAt']),
      issueTitle: serializer.fromJson<String?>(json['issueTitle']),
      volume: serializer.fromJson<int?>(json['volume']),
      year: serializer.fromJson<int?>(json['year']),
      writers: serializer.fromJson<String?>(json['writers']),
      artists: serializer.fromJson<String?>(json['artists']),
      summary: serializer.fromJson<String?>(json['summary']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'contentKey': serializer.toJson<String>(contentKey),
      'title': serializer.toJson<String>(title),
      'seriesId': serializer.toJson<int?>(seriesId),
      'number': serializer.toJson<String?>(number),
      'pageCount': serializer.toJson<int>(pageCount),
      'format': serializer.toJson<String>(format),
      'addedAt': serializer.toJson<DateTime>(addedAt),
      'issueTitle': serializer.toJson<String?>(issueTitle),
      'volume': serializer.toJson<int?>(volume),
      'year': serializer.toJson<int?>(year),
      'writers': serializer.toJson<String?>(writers),
      'artists': serializer.toJson<String?>(artists),
      'summary': serializer.toJson<String?>(summary),
    };
  }

  Book copyWith({
    String? contentKey,
    String? title,
    Value<int?> seriesId = const Value.absent(),
    Value<String?> number = const Value.absent(),
    int? pageCount,
    String? format,
    DateTime? addedAt,
    Value<String?> issueTitle = const Value.absent(),
    Value<int?> volume = const Value.absent(),
    Value<int?> year = const Value.absent(),
    Value<String?> writers = const Value.absent(),
    Value<String?> artists = const Value.absent(),
    Value<String?> summary = const Value.absent(),
  }) => Book(
    contentKey: contentKey ?? this.contentKey,
    title: title ?? this.title,
    seriesId: seriesId.present ? seriesId.value : this.seriesId,
    number: number.present ? number.value : this.number,
    pageCount: pageCount ?? this.pageCount,
    format: format ?? this.format,
    addedAt: addedAt ?? this.addedAt,
    issueTitle: issueTitle.present ? issueTitle.value : this.issueTitle,
    volume: volume.present ? volume.value : this.volume,
    year: year.present ? year.value : this.year,
    writers: writers.present ? writers.value : this.writers,
    artists: artists.present ? artists.value : this.artists,
    summary: summary.present ? summary.value : this.summary,
  );
  Book copyWithCompanion(BooksCompanion data) {
    return Book(
      contentKey: data.contentKey.present
          ? data.contentKey.value
          : this.contentKey,
      title: data.title.present ? data.title.value : this.title,
      seriesId: data.seriesId.present ? data.seriesId.value : this.seriesId,
      number: data.number.present ? data.number.value : this.number,
      pageCount: data.pageCount.present ? data.pageCount.value : this.pageCount,
      format: data.format.present ? data.format.value : this.format,
      addedAt: data.addedAt.present ? data.addedAt.value : this.addedAt,
      issueTitle: data.issueTitle.present
          ? data.issueTitle.value
          : this.issueTitle,
      volume: data.volume.present ? data.volume.value : this.volume,
      year: data.year.present ? data.year.value : this.year,
      writers: data.writers.present ? data.writers.value : this.writers,
      artists: data.artists.present ? data.artists.value : this.artists,
      summary: data.summary.present ? data.summary.value : this.summary,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Book(')
          ..write('contentKey: $contentKey, ')
          ..write('title: $title, ')
          ..write('seriesId: $seriesId, ')
          ..write('number: $number, ')
          ..write('pageCount: $pageCount, ')
          ..write('format: $format, ')
          ..write('addedAt: $addedAt, ')
          ..write('issueTitle: $issueTitle, ')
          ..write('volume: $volume, ')
          ..write('year: $year, ')
          ..write('writers: $writers, ')
          ..write('artists: $artists, ')
          ..write('summary: $summary')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    contentKey,
    title,
    seriesId,
    number,
    pageCount,
    format,
    addedAt,
    issueTitle,
    volume,
    year,
    writers,
    artists,
    summary,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Book &&
          other.contentKey == this.contentKey &&
          other.title == this.title &&
          other.seriesId == this.seriesId &&
          other.number == this.number &&
          other.pageCount == this.pageCount &&
          other.format == this.format &&
          other.addedAt == this.addedAt &&
          other.issueTitle == this.issueTitle &&
          other.volume == this.volume &&
          other.year == this.year &&
          other.writers == this.writers &&
          other.artists == this.artists &&
          other.summary == this.summary);
}

class BooksCompanion extends UpdateCompanion<Book> {
  final Value<String> contentKey;
  final Value<String> title;
  final Value<int?> seriesId;
  final Value<String?> number;
  final Value<int> pageCount;
  final Value<String> format;
  final Value<DateTime> addedAt;
  final Value<String?> issueTitle;
  final Value<int?> volume;
  final Value<int?> year;
  final Value<String?> writers;
  final Value<String?> artists;
  final Value<String?> summary;
  final Value<int> rowid;
  const BooksCompanion({
    this.contentKey = const Value.absent(),
    this.title = const Value.absent(),
    this.seriesId = const Value.absent(),
    this.number = const Value.absent(),
    this.pageCount = const Value.absent(),
    this.format = const Value.absent(),
    this.addedAt = const Value.absent(),
    this.issueTitle = const Value.absent(),
    this.volume = const Value.absent(),
    this.year = const Value.absent(),
    this.writers = const Value.absent(),
    this.artists = const Value.absent(),
    this.summary = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  BooksCompanion.insert({
    required String contentKey,
    required String title,
    this.seriesId = const Value.absent(),
    this.number = const Value.absent(),
    required int pageCount,
    required String format,
    this.addedAt = const Value.absent(),
    this.issueTitle = const Value.absent(),
    this.volume = const Value.absent(),
    this.year = const Value.absent(),
    this.writers = const Value.absent(),
    this.artists = const Value.absent(),
    this.summary = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : contentKey = Value(contentKey),
       title = Value(title),
       pageCount = Value(pageCount),
       format = Value(format);
  static Insertable<Book> custom({
    Expression<String>? contentKey,
    Expression<String>? title,
    Expression<int>? seriesId,
    Expression<String>? number,
    Expression<int>? pageCount,
    Expression<String>? format,
    Expression<DateTime>? addedAt,
    Expression<String>? issueTitle,
    Expression<int>? volume,
    Expression<int>? year,
    Expression<String>? writers,
    Expression<String>? artists,
    Expression<String>? summary,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (contentKey != null) 'content_key': contentKey,
      if (title != null) 'title': title,
      if (seriesId != null) 'series_id': seriesId,
      if (number != null) 'number': number,
      if (pageCount != null) 'page_count': pageCount,
      if (format != null) 'format': format,
      if (addedAt != null) 'added_at': addedAt,
      if (issueTitle != null) 'issue_title': issueTitle,
      if (volume != null) 'volume': volume,
      if (year != null) 'year': year,
      if (writers != null) 'writers': writers,
      if (artists != null) 'artists': artists,
      if (summary != null) 'summary': summary,
      if (rowid != null) 'rowid': rowid,
    });
  }

  BooksCompanion copyWith({
    Value<String>? contentKey,
    Value<String>? title,
    Value<int?>? seriesId,
    Value<String?>? number,
    Value<int>? pageCount,
    Value<String>? format,
    Value<DateTime>? addedAt,
    Value<String?>? issueTitle,
    Value<int?>? volume,
    Value<int?>? year,
    Value<String?>? writers,
    Value<String?>? artists,
    Value<String?>? summary,
    Value<int>? rowid,
  }) {
    return BooksCompanion(
      contentKey: contentKey ?? this.contentKey,
      title: title ?? this.title,
      seriesId: seriesId ?? this.seriesId,
      number: number ?? this.number,
      pageCount: pageCount ?? this.pageCount,
      format: format ?? this.format,
      addedAt: addedAt ?? this.addedAt,
      issueTitle: issueTitle ?? this.issueTitle,
      volume: volume ?? this.volume,
      year: year ?? this.year,
      writers: writers ?? this.writers,
      artists: artists ?? this.artists,
      summary: summary ?? this.summary,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (contentKey.present) {
      map['content_key'] = Variable<String>(contentKey.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (seriesId.present) {
      map['series_id'] = Variable<int>(seriesId.value);
    }
    if (number.present) {
      map['number'] = Variable<String>(number.value);
    }
    if (pageCount.present) {
      map['page_count'] = Variable<int>(pageCount.value);
    }
    if (format.present) {
      map['format'] = Variable<String>(format.value);
    }
    if (addedAt.present) {
      map['added_at'] = Variable<DateTime>(addedAt.value);
    }
    if (issueTitle.present) {
      map['issue_title'] = Variable<String>(issueTitle.value);
    }
    if (volume.present) {
      map['volume'] = Variable<int>(volume.value);
    }
    if (year.present) {
      map['year'] = Variable<int>(year.value);
    }
    if (writers.present) {
      map['writers'] = Variable<String>(writers.value);
    }
    if (artists.present) {
      map['artists'] = Variable<String>(artists.value);
    }
    if (summary.present) {
      map['summary'] = Variable<String>(summary.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('BooksCompanion(')
          ..write('contentKey: $contentKey, ')
          ..write('title: $title, ')
          ..write('seriesId: $seriesId, ')
          ..write('number: $number, ')
          ..write('pageCount: $pageCount, ')
          ..write('format: $format, ')
          ..write('addedAt: $addedAt, ')
          ..write('issueTitle: $issueTitle, ')
          ..write('volume: $volume, ')
          ..write('year: $year, ')
          ..write('writers: $writers, ')
          ..write('artists: $artists, ')
          ..write('summary: $summary, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $RootsTable extends Roots with TableInfo<$RootsTable, LibraryRoot> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $RootsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _pathMeta = const VerificationMeta('path');
  @override
  late final GeneratedColumn<String> path = GeneratedColumn<String>(
    'path',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways('UNIQUE'),
  );
  static const VerificationMeta _addedAtMeta = const VerificationMeta(
    'addedAt',
  );
  @override
  late final GeneratedColumn<DateTime> addedAt = GeneratedColumn<DateTime>(
    'added_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
    defaultValue: currentDateAndTime,
  );
  @override
  List<GeneratedColumn> get $columns => [id, path, addedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'roots';
  @override
  VerificationContext validateIntegrity(
    Insertable<LibraryRoot> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('path')) {
      context.handle(
        _pathMeta,
        path.isAcceptableOrUnknown(data['path']!, _pathMeta),
      );
    } else if (isInserting) {
      context.missing(_pathMeta);
    }
    if (data.containsKey('added_at')) {
      context.handle(
        _addedAtMeta,
        addedAt.isAcceptableOrUnknown(data['added_at']!, _addedAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  LibraryRoot map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LibraryRoot(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      path: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}path'],
      )!,
      addedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}added_at'],
      )!,
    );
  }

  @override
  $RootsTable createAlias(String alias) {
    return $RootsTable(attachedDatabase, alias);
  }
}

class LibraryRoot extends DataClass implements Insertable<LibraryRoot> {
  final int id;
  final String path;
  final DateTime addedAt;
  const LibraryRoot({
    required this.id,
    required this.path,
    required this.addedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['path'] = Variable<String>(path);
    map['added_at'] = Variable<DateTime>(addedAt);
    return map;
  }

  RootsCompanion toCompanion(bool nullToAbsent) {
    return RootsCompanion(
      id: Value(id),
      path: Value(path),
      addedAt: Value(addedAt),
    );
  }

  factory LibraryRoot.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LibraryRoot(
      id: serializer.fromJson<int>(json['id']),
      path: serializer.fromJson<String>(json['path']),
      addedAt: serializer.fromJson<DateTime>(json['addedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'path': serializer.toJson<String>(path),
      'addedAt': serializer.toJson<DateTime>(addedAt),
    };
  }

  LibraryRoot copyWith({int? id, String? path, DateTime? addedAt}) =>
      LibraryRoot(
        id: id ?? this.id,
        path: path ?? this.path,
        addedAt: addedAt ?? this.addedAt,
      );
  LibraryRoot copyWithCompanion(RootsCompanion data) {
    return LibraryRoot(
      id: data.id.present ? data.id.value : this.id,
      path: data.path.present ? data.path.value : this.path,
      addedAt: data.addedAt.present ? data.addedAt.value : this.addedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LibraryRoot(')
          ..write('id: $id, ')
          ..write('path: $path, ')
          ..write('addedAt: $addedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, path, addedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LibraryRoot &&
          other.id == this.id &&
          other.path == this.path &&
          other.addedAt == this.addedAt);
}

class RootsCompanion extends UpdateCompanion<LibraryRoot> {
  final Value<int> id;
  final Value<String> path;
  final Value<DateTime> addedAt;
  const RootsCompanion({
    this.id = const Value.absent(),
    this.path = const Value.absent(),
    this.addedAt = const Value.absent(),
  });
  RootsCompanion.insert({
    this.id = const Value.absent(),
    required String path,
    this.addedAt = const Value.absent(),
  }) : path = Value(path);
  static Insertable<LibraryRoot> custom({
    Expression<int>? id,
    Expression<String>? path,
    Expression<DateTime>? addedAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (path != null) 'path': path,
      if (addedAt != null) 'added_at': addedAt,
    });
  }

  RootsCompanion copyWith({
    Value<int>? id,
    Value<String>? path,
    Value<DateTime>? addedAt,
  }) {
    return RootsCompanion(
      id: id ?? this.id,
      path: path ?? this.path,
      addedAt: addedAt ?? this.addedAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (path.present) {
      map['path'] = Variable<String>(path.value);
    }
    if (addedAt.present) {
      map['added_at'] = Variable<DateTime>(addedAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('RootsCompanion(')
          ..write('id: $id, ')
          ..write('path: $path, ')
          ..write('addedAt: $addedAt')
          ..write(')'))
        .toString();
  }
}

class $FilesTable extends Files with TableInfo<$FilesTable, BookFile> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $FilesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _contentKeyMeta = const VerificationMeta(
    'contentKey',
  );
  @override
  late final GeneratedColumn<String> contentKey = GeneratedColumn<String>(
    'content_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES books (content_key)',
    ),
  );
  static const VerificationMeta _rootIdMeta = const VerificationMeta('rootId');
  @override
  late final GeneratedColumn<int> rootId = GeneratedColumn<int>(
    'root_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _relPathMeta = const VerificationMeta(
    'relPath',
  );
  @override
  late final GeneratedColumn<String> relPath = GeneratedColumn<String>(
    'rel_path',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sizeMeta = const VerificationMeta('size');
  @override
  late final GeneratedColumn<int> size = GeneratedColumn<int>(
    'size',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _mtimeMeta = const VerificationMeta('mtime');
  @override
  late final GeneratedColumn<DateTime> mtime = GeneratedColumn<DateTime>(
    'mtime',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    contentKey,
    rootId,
    relPath,
    size,
    mtime,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'files';
  @override
  VerificationContext validateIntegrity(
    Insertable<BookFile> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('content_key')) {
      context.handle(
        _contentKeyMeta,
        contentKey.isAcceptableOrUnknown(data['content_key']!, _contentKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_contentKeyMeta);
    }
    if (data.containsKey('root_id')) {
      context.handle(
        _rootIdMeta,
        rootId.isAcceptableOrUnknown(data['root_id']!, _rootIdMeta),
      );
    } else if (isInserting) {
      context.missing(_rootIdMeta);
    }
    if (data.containsKey('rel_path')) {
      context.handle(
        _relPathMeta,
        relPath.isAcceptableOrUnknown(data['rel_path']!, _relPathMeta),
      );
    } else if (isInserting) {
      context.missing(_relPathMeta);
    }
    if (data.containsKey('size')) {
      context.handle(
        _sizeMeta,
        size.isAcceptableOrUnknown(data['size']!, _sizeMeta),
      );
    } else if (isInserting) {
      context.missing(_sizeMeta);
    }
    if (data.containsKey('mtime')) {
      context.handle(
        _mtimeMeta,
        mtime.isAcceptableOrUnknown(data['mtime']!, _mtimeMeta),
      );
    } else if (isInserting) {
      context.missing(_mtimeMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {rootId, relPath};
  @override
  BookFile map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return BookFile(
      contentKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}content_key'],
      )!,
      rootId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}root_id'],
      )!,
      relPath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}rel_path'],
      )!,
      size: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}size'],
      )!,
      mtime: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}mtime'],
      )!,
    );
  }

  @override
  $FilesTable createAlias(String alias) {
    return $FilesTable(attachedDatabase, alias);
  }
}

class BookFile extends DataClass implements Insertable<BookFile> {
  final String contentKey;
  final int rootId;
  final String relPath;
  final int size;
  final DateTime mtime;
  const BookFile({
    required this.contentKey,
    required this.rootId,
    required this.relPath,
    required this.size,
    required this.mtime,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['content_key'] = Variable<String>(contentKey);
    map['root_id'] = Variable<int>(rootId);
    map['rel_path'] = Variable<String>(relPath);
    map['size'] = Variable<int>(size);
    map['mtime'] = Variable<DateTime>(mtime);
    return map;
  }

  FilesCompanion toCompanion(bool nullToAbsent) {
    return FilesCompanion(
      contentKey: Value(contentKey),
      rootId: Value(rootId),
      relPath: Value(relPath),
      size: Value(size),
      mtime: Value(mtime),
    );
  }

  factory BookFile.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return BookFile(
      contentKey: serializer.fromJson<String>(json['contentKey']),
      rootId: serializer.fromJson<int>(json['rootId']),
      relPath: serializer.fromJson<String>(json['relPath']),
      size: serializer.fromJson<int>(json['size']),
      mtime: serializer.fromJson<DateTime>(json['mtime']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'contentKey': serializer.toJson<String>(contentKey),
      'rootId': serializer.toJson<int>(rootId),
      'relPath': serializer.toJson<String>(relPath),
      'size': serializer.toJson<int>(size),
      'mtime': serializer.toJson<DateTime>(mtime),
    };
  }

  BookFile copyWith({
    String? contentKey,
    int? rootId,
    String? relPath,
    int? size,
    DateTime? mtime,
  }) => BookFile(
    contentKey: contentKey ?? this.contentKey,
    rootId: rootId ?? this.rootId,
    relPath: relPath ?? this.relPath,
    size: size ?? this.size,
    mtime: mtime ?? this.mtime,
  );
  BookFile copyWithCompanion(FilesCompanion data) {
    return BookFile(
      contentKey: data.contentKey.present
          ? data.contentKey.value
          : this.contentKey,
      rootId: data.rootId.present ? data.rootId.value : this.rootId,
      relPath: data.relPath.present ? data.relPath.value : this.relPath,
      size: data.size.present ? data.size.value : this.size,
      mtime: data.mtime.present ? data.mtime.value : this.mtime,
    );
  }

  @override
  String toString() {
    return (StringBuffer('BookFile(')
          ..write('contentKey: $contentKey, ')
          ..write('rootId: $rootId, ')
          ..write('relPath: $relPath, ')
          ..write('size: $size, ')
          ..write('mtime: $mtime')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(contentKey, rootId, relPath, size, mtime);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is BookFile &&
          other.contentKey == this.contentKey &&
          other.rootId == this.rootId &&
          other.relPath == this.relPath &&
          other.size == this.size &&
          other.mtime == this.mtime);
}

class FilesCompanion extends UpdateCompanion<BookFile> {
  final Value<String> contentKey;
  final Value<int> rootId;
  final Value<String> relPath;
  final Value<int> size;
  final Value<DateTime> mtime;
  final Value<int> rowid;
  const FilesCompanion({
    this.contentKey = const Value.absent(),
    this.rootId = const Value.absent(),
    this.relPath = const Value.absent(),
    this.size = const Value.absent(),
    this.mtime = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  FilesCompanion.insert({
    required String contentKey,
    required int rootId,
    required String relPath,
    required int size,
    required DateTime mtime,
    this.rowid = const Value.absent(),
  }) : contentKey = Value(contentKey),
       rootId = Value(rootId),
       relPath = Value(relPath),
       size = Value(size),
       mtime = Value(mtime);
  static Insertable<BookFile> custom({
    Expression<String>? contentKey,
    Expression<int>? rootId,
    Expression<String>? relPath,
    Expression<int>? size,
    Expression<DateTime>? mtime,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (contentKey != null) 'content_key': contentKey,
      if (rootId != null) 'root_id': rootId,
      if (relPath != null) 'rel_path': relPath,
      if (size != null) 'size': size,
      if (mtime != null) 'mtime': mtime,
      if (rowid != null) 'rowid': rowid,
    });
  }

  FilesCompanion copyWith({
    Value<String>? contentKey,
    Value<int>? rootId,
    Value<String>? relPath,
    Value<int>? size,
    Value<DateTime>? mtime,
    Value<int>? rowid,
  }) {
    return FilesCompanion(
      contentKey: contentKey ?? this.contentKey,
      rootId: rootId ?? this.rootId,
      relPath: relPath ?? this.relPath,
      size: size ?? this.size,
      mtime: mtime ?? this.mtime,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (contentKey.present) {
      map['content_key'] = Variable<String>(contentKey.value);
    }
    if (rootId.present) {
      map['root_id'] = Variable<int>(rootId.value);
    }
    if (relPath.present) {
      map['rel_path'] = Variable<String>(relPath.value);
    }
    if (size.present) {
      map['size'] = Variable<int>(size.value);
    }
    if (mtime.present) {
      map['mtime'] = Variable<DateTime>(mtime.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('FilesCompanion(')
          ..write('contentKey: $contentKey, ')
          ..write('rootId: $rootId, ')
          ..write('relPath: $relPath, ')
          ..write('size: $size, ')
          ..write('mtime: $mtime, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ProgressTable extends Progress
    with TableInfo<$ProgressTable, ProgressData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ProgressTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _contentKeyMeta = const VerificationMeta(
    'contentKey',
  );
  @override
  late final GeneratedColumn<String> contentKey = GeneratedColumn<String>(
    'content_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _pageMeta = const VerificationMeta('page');
  @override
  late final GeneratedColumn<int> page = GeneratedColumn<int>(
    'page',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _panelMeta = const VerificationMeta('panel');
  @override
  late final GeneratedColumn<int> panel = GeneratedColumn<int>(
    'panel',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _percentMeta = const VerificationMeta(
    'percent',
  );
  @override
  late final GeneratedColumn<double> percent = GeneratedColumn<double>(
    'percent',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _finishedMeta = const VerificationMeta(
    'finished',
  );
  @override
  late final GeneratedColumn<bool> finished = GeneratedColumn<bool>(
    'finished',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("finished" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _viewJsonMeta = const VerificationMeta(
    'viewJson',
  );
  @override
  late final GeneratedColumn<String> viewJson = GeneratedColumn<String>(
    'view_json',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    contentKey,
    page,
    panel,
    percent,
    finished,
    updatedAt,
    viewJson,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'progress';
  @override
  VerificationContext validateIntegrity(
    Insertable<ProgressData> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('content_key')) {
      context.handle(
        _contentKeyMeta,
        contentKey.isAcceptableOrUnknown(data['content_key']!, _contentKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_contentKeyMeta);
    }
    if (data.containsKey('page')) {
      context.handle(
        _pageMeta,
        page.isAcceptableOrUnknown(data['page']!, _pageMeta),
      );
    } else if (isInserting) {
      context.missing(_pageMeta);
    }
    if (data.containsKey('panel')) {
      context.handle(
        _panelMeta,
        panel.isAcceptableOrUnknown(data['panel']!, _panelMeta),
      );
    }
    if (data.containsKey('percent')) {
      context.handle(
        _percentMeta,
        percent.isAcceptableOrUnknown(data['percent']!, _percentMeta),
      );
    } else if (isInserting) {
      context.missing(_percentMeta);
    }
    if (data.containsKey('finished')) {
      context.handle(
        _finishedMeta,
        finished.isAcceptableOrUnknown(data['finished']!, _finishedMeta),
      );
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    if (data.containsKey('view_json')) {
      context.handle(
        _viewJsonMeta,
        viewJson.isAcceptableOrUnknown(data['view_json']!, _viewJsonMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {contentKey};
  @override
  ProgressData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ProgressData(
      contentKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}content_key'],
      )!,
      page: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}page'],
      )!,
      panel: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}panel'],
      ),
      percent: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}percent'],
      )!,
      finished: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}finished'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
      viewJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}view_json'],
      ),
    );
  }

  @override
  $ProgressTable createAlias(String alias) {
    return $ProgressTable(attachedDatabase, alias);
  }
}

class ProgressData extends DataClass implements Insertable<ProgressData> {
  final String contentKey;
  final int page;
  final int? panel;
  final double percent;
  final bool finished;
  final DateTime updatedAt;

  /// The rest of the spot as JSON: guided and balloon mode, the balloon,
  /// spread and direction, zoom and scroll. See ReadingPosition.
  final String? viewJson;
  const ProgressData({
    required this.contentKey,
    required this.page,
    this.panel,
    required this.percent,
    required this.finished,
    required this.updatedAt,
    this.viewJson,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['content_key'] = Variable<String>(contentKey);
    map['page'] = Variable<int>(page);
    if (!nullToAbsent || panel != null) {
      map['panel'] = Variable<int>(panel);
    }
    map['percent'] = Variable<double>(percent);
    map['finished'] = Variable<bool>(finished);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    if (!nullToAbsent || viewJson != null) {
      map['view_json'] = Variable<String>(viewJson);
    }
    return map;
  }

  ProgressCompanion toCompanion(bool nullToAbsent) {
    return ProgressCompanion(
      contentKey: Value(contentKey),
      page: Value(page),
      panel: panel == null && nullToAbsent
          ? const Value.absent()
          : Value(panel),
      percent: Value(percent),
      finished: Value(finished),
      updatedAt: Value(updatedAt),
      viewJson: viewJson == null && nullToAbsent
          ? const Value.absent()
          : Value(viewJson),
    );
  }

  factory ProgressData.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ProgressData(
      contentKey: serializer.fromJson<String>(json['contentKey']),
      page: serializer.fromJson<int>(json['page']),
      panel: serializer.fromJson<int?>(json['panel']),
      percent: serializer.fromJson<double>(json['percent']),
      finished: serializer.fromJson<bool>(json['finished']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
      viewJson: serializer.fromJson<String?>(json['viewJson']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'contentKey': serializer.toJson<String>(contentKey),
      'page': serializer.toJson<int>(page),
      'panel': serializer.toJson<int?>(panel),
      'percent': serializer.toJson<double>(percent),
      'finished': serializer.toJson<bool>(finished),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
      'viewJson': serializer.toJson<String?>(viewJson),
    };
  }

  ProgressData copyWith({
    String? contentKey,
    int? page,
    Value<int?> panel = const Value.absent(),
    double? percent,
    bool? finished,
    DateTime? updatedAt,
    Value<String?> viewJson = const Value.absent(),
  }) => ProgressData(
    contentKey: contentKey ?? this.contentKey,
    page: page ?? this.page,
    panel: panel.present ? panel.value : this.panel,
    percent: percent ?? this.percent,
    finished: finished ?? this.finished,
    updatedAt: updatedAt ?? this.updatedAt,
    viewJson: viewJson.present ? viewJson.value : this.viewJson,
  );
  ProgressData copyWithCompanion(ProgressCompanion data) {
    return ProgressData(
      contentKey: data.contentKey.present
          ? data.contentKey.value
          : this.contentKey,
      page: data.page.present ? data.page.value : this.page,
      panel: data.panel.present ? data.panel.value : this.panel,
      percent: data.percent.present ? data.percent.value : this.percent,
      finished: data.finished.present ? data.finished.value : this.finished,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      viewJson: data.viewJson.present ? data.viewJson.value : this.viewJson,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ProgressData(')
          ..write('contentKey: $contentKey, ')
          ..write('page: $page, ')
          ..write('panel: $panel, ')
          ..write('percent: $percent, ')
          ..write('finished: $finished, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('viewJson: $viewJson')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    contentKey,
    page,
    panel,
    percent,
    finished,
    updatedAt,
    viewJson,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ProgressData &&
          other.contentKey == this.contentKey &&
          other.page == this.page &&
          other.panel == this.panel &&
          other.percent == this.percent &&
          other.finished == this.finished &&
          other.updatedAt == this.updatedAt &&
          other.viewJson == this.viewJson);
}

class ProgressCompanion extends UpdateCompanion<ProgressData> {
  final Value<String> contentKey;
  final Value<int> page;
  final Value<int?> panel;
  final Value<double> percent;
  final Value<bool> finished;
  final Value<DateTime> updatedAt;
  final Value<String?> viewJson;
  final Value<int> rowid;
  const ProgressCompanion({
    this.contentKey = const Value.absent(),
    this.page = const Value.absent(),
    this.panel = const Value.absent(),
    this.percent = const Value.absent(),
    this.finished = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.viewJson = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ProgressCompanion.insert({
    required String contentKey,
    required int page,
    this.panel = const Value.absent(),
    required double percent,
    this.finished = const Value.absent(),
    required DateTime updatedAt,
    this.viewJson = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : contentKey = Value(contentKey),
       page = Value(page),
       percent = Value(percent),
       updatedAt = Value(updatedAt);
  static Insertable<ProgressData> custom({
    Expression<String>? contentKey,
    Expression<int>? page,
    Expression<int>? panel,
    Expression<double>? percent,
    Expression<bool>? finished,
    Expression<DateTime>? updatedAt,
    Expression<String>? viewJson,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (contentKey != null) 'content_key': contentKey,
      if (page != null) 'page': page,
      if (panel != null) 'panel': panel,
      if (percent != null) 'percent': percent,
      if (finished != null) 'finished': finished,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (viewJson != null) 'view_json': viewJson,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ProgressCompanion copyWith({
    Value<String>? contentKey,
    Value<int>? page,
    Value<int?>? panel,
    Value<double>? percent,
    Value<bool>? finished,
    Value<DateTime>? updatedAt,
    Value<String?>? viewJson,
    Value<int>? rowid,
  }) {
    return ProgressCompanion(
      contentKey: contentKey ?? this.contentKey,
      page: page ?? this.page,
      panel: panel ?? this.panel,
      percent: percent ?? this.percent,
      finished: finished ?? this.finished,
      updatedAt: updatedAt ?? this.updatedAt,
      viewJson: viewJson ?? this.viewJson,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (contentKey.present) {
      map['content_key'] = Variable<String>(contentKey.value);
    }
    if (page.present) {
      map['page'] = Variable<int>(page.value);
    }
    if (panel.present) {
      map['panel'] = Variable<int>(panel.value);
    }
    if (percent.present) {
      map['percent'] = Variable<double>(percent.value);
    }
    if (finished.present) {
      map['finished'] = Variable<bool>(finished.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (viewJson.present) {
      map['view_json'] = Variable<String>(viewJson.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ProgressCompanion(')
          ..write('contentKey: $contentKey, ')
          ..write('page: $page, ')
          ..write('panel: $panel, ')
          ..write('percent: $percent, ')
          ..write('finished: $finished, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('viewJson: $viewJson, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $BookmarksTable extends Bookmarks
    with TableInfo<$BookmarksTable, Bookmark> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $BookmarksTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _contentKeyMeta = const VerificationMeta(
    'contentKey',
  );
  @override
  late final GeneratedColumn<String> contentKey = GeneratedColumn<String>(
    'content_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _pageMeta = const VerificationMeta('page');
  @override
  late final GeneratedColumn<int> page = GeneratedColumn<int>(
    'page',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _panelMeta = const VerificationMeta('panel');
  @override
  late final GeneratedColumn<int> panel = GeneratedColumn<int>(
    'panel',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _markMeta = const VerificationMeta('mark');
  @override
  late final GeneratedColumn<String> mark = GeneratedColumn<String>(
    'mark',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _noteMeta = const VerificationMeta('note');
  @override
  late final GeneratedColumn<String> note = GeneratedColumn<String>(
    'note',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deletedAtMeta = const VerificationMeta(
    'deletedAt',
  );
  @override
  late final GeneratedColumn<DateTime> deletedAt = GeneratedColumn<DateTime>(
    'deleted_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    contentKey,
    page,
    panel,
    mark,
    note,
    createdAt,
    deletedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'bookmarks';
  @override
  VerificationContext validateIntegrity(
    Insertable<Bookmark> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('content_key')) {
      context.handle(
        _contentKeyMeta,
        contentKey.isAcceptableOrUnknown(data['content_key']!, _contentKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_contentKeyMeta);
    }
    if (data.containsKey('page')) {
      context.handle(
        _pageMeta,
        page.isAcceptableOrUnknown(data['page']!, _pageMeta),
      );
    } else if (isInserting) {
      context.missing(_pageMeta);
    }
    if (data.containsKey('panel')) {
      context.handle(
        _panelMeta,
        panel.isAcceptableOrUnknown(data['panel']!, _panelMeta),
      );
    }
    if (data.containsKey('mark')) {
      context.handle(
        _markMeta,
        mark.isAcceptableOrUnknown(data['mark']!, _markMeta),
      );
    }
    if (data.containsKey('note')) {
      context.handle(
        _noteMeta,
        note.isAcceptableOrUnknown(data['note']!, _noteMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('deleted_at')) {
      context.handle(
        _deletedAtMeta,
        deletedAt.isAcceptableOrUnknown(data['deleted_at']!, _deletedAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  Bookmark map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Bookmark(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      contentKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}content_key'],
      )!,
      page: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}page'],
      )!,
      panel: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}panel'],
      ),
      mark: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}mark'],
      ),
      note: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}note'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
      deletedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}deleted_at'],
      ),
    );
  }

  @override
  $BookmarksTable createAlias(String alias) {
    return $BookmarksTable(attachedDatabase, alias);
  }
}

class Bookmark extends DataClass implements Insertable<Bookmark> {
  final String id;
  final String contentKey;
  final int page;
  final int? panel;
  final String? mark;
  final String? note;
  final DateTime createdAt;

  /// Set when the bookmark is removed. The row stays, so a sidecar copied
  /// from another device that still has it cannot bring it back (M8).
  final DateTime? deletedAt;
  const Bookmark({
    required this.id,
    required this.contentKey,
    required this.page,
    this.panel,
    this.mark,
    this.note,
    required this.createdAt,
    this.deletedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['content_key'] = Variable<String>(contentKey);
    map['page'] = Variable<int>(page);
    if (!nullToAbsent || panel != null) {
      map['panel'] = Variable<int>(panel);
    }
    if (!nullToAbsent || mark != null) {
      map['mark'] = Variable<String>(mark);
    }
    if (!nullToAbsent || note != null) {
      map['note'] = Variable<String>(note);
    }
    map['created_at'] = Variable<DateTime>(createdAt);
    if (!nullToAbsent || deletedAt != null) {
      map['deleted_at'] = Variable<DateTime>(deletedAt);
    }
    return map;
  }

  BookmarksCompanion toCompanion(bool nullToAbsent) {
    return BookmarksCompanion(
      id: Value(id),
      contentKey: Value(contentKey),
      page: Value(page),
      panel: panel == null && nullToAbsent
          ? const Value.absent()
          : Value(panel),
      mark: mark == null && nullToAbsent ? const Value.absent() : Value(mark),
      note: note == null && nullToAbsent ? const Value.absent() : Value(note),
      createdAt: Value(createdAt),
      deletedAt: deletedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(deletedAt),
    );
  }

  factory Bookmark.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Bookmark(
      id: serializer.fromJson<String>(json['id']),
      contentKey: serializer.fromJson<String>(json['contentKey']),
      page: serializer.fromJson<int>(json['page']),
      panel: serializer.fromJson<int?>(json['panel']),
      mark: serializer.fromJson<String?>(json['mark']),
      note: serializer.fromJson<String?>(json['note']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      deletedAt: serializer.fromJson<DateTime?>(json['deletedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'contentKey': serializer.toJson<String>(contentKey),
      'page': serializer.toJson<int>(page),
      'panel': serializer.toJson<int?>(panel),
      'mark': serializer.toJson<String?>(mark),
      'note': serializer.toJson<String?>(note),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'deletedAt': serializer.toJson<DateTime?>(deletedAt),
    };
  }

  Bookmark copyWith({
    String? id,
    String? contentKey,
    int? page,
    Value<int?> panel = const Value.absent(),
    Value<String?> mark = const Value.absent(),
    Value<String?> note = const Value.absent(),
    DateTime? createdAt,
    Value<DateTime?> deletedAt = const Value.absent(),
  }) => Bookmark(
    id: id ?? this.id,
    contentKey: contentKey ?? this.contentKey,
    page: page ?? this.page,
    panel: panel.present ? panel.value : this.panel,
    mark: mark.present ? mark.value : this.mark,
    note: note.present ? note.value : this.note,
    createdAt: createdAt ?? this.createdAt,
    deletedAt: deletedAt.present ? deletedAt.value : this.deletedAt,
  );
  Bookmark copyWithCompanion(BookmarksCompanion data) {
    return Bookmark(
      id: data.id.present ? data.id.value : this.id,
      contentKey: data.contentKey.present
          ? data.contentKey.value
          : this.contentKey,
      page: data.page.present ? data.page.value : this.page,
      panel: data.panel.present ? data.panel.value : this.panel,
      mark: data.mark.present ? data.mark.value : this.mark,
      note: data.note.present ? data.note.value : this.note,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      deletedAt: data.deletedAt.present ? data.deletedAt.value : this.deletedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Bookmark(')
          ..write('id: $id, ')
          ..write('contentKey: $contentKey, ')
          ..write('page: $page, ')
          ..write('panel: $panel, ')
          ..write('mark: $mark, ')
          ..write('note: $note, ')
          ..write('createdAt: $createdAt, ')
          ..write('deletedAt: $deletedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    contentKey,
    page,
    panel,
    mark,
    note,
    createdAt,
    deletedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Bookmark &&
          other.id == this.id &&
          other.contentKey == this.contentKey &&
          other.page == this.page &&
          other.panel == this.panel &&
          other.mark == this.mark &&
          other.note == this.note &&
          other.createdAt == this.createdAt &&
          other.deletedAt == this.deletedAt);
}

class BookmarksCompanion extends UpdateCompanion<Bookmark> {
  final Value<String> id;
  final Value<String> contentKey;
  final Value<int> page;
  final Value<int?> panel;
  final Value<String?> mark;
  final Value<String?> note;
  final Value<DateTime> createdAt;
  final Value<DateTime?> deletedAt;
  final Value<int> rowid;
  const BookmarksCompanion({
    this.id = const Value.absent(),
    this.contentKey = const Value.absent(),
    this.page = const Value.absent(),
    this.panel = const Value.absent(),
    this.mark = const Value.absent(),
    this.note = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.deletedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  BookmarksCompanion.insert({
    required String id,
    required String contentKey,
    required int page,
    this.panel = const Value.absent(),
    this.mark = const Value.absent(),
    this.note = const Value.absent(),
    required DateTime createdAt,
    this.deletedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       contentKey = Value(contentKey),
       page = Value(page),
       createdAt = Value(createdAt);
  static Insertable<Bookmark> custom({
    Expression<String>? id,
    Expression<String>? contentKey,
    Expression<int>? page,
    Expression<int>? panel,
    Expression<String>? mark,
    Expression<String>? note,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? deletedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (contentKey != null) 'content_key': contentKey,
      if (page != null) 'page': page,
      if (panel != null) 'panel': panel,
      if (mark != null) 'mark': mark,
      if (note != null) 'note': note,
      if (createdAt != null) 'created_at': createdAt,
      if (deletedAt != null) 'deleted_at': deletedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  BookmarksCompanion copyWith({
    Value<String>? id,
    Value<String>? contentKey,
    Value<int>? page,
    Value<int?>? panel,
    Value<String?>? mark,
    Value<String?>? note,
    Value<DateTime>? createdAt,
    Value<DateTime?>? deletedAt,
    Value<int>? rowid,
  }) {
    return BookmarksCompanion(
      id: id ?? this.id,
      contentKey: contentKey ?? this.contentKey,
      page: page ?? this.page,
      panel: panel ?? this.panel,
      mark: mark ?? this.mark,
      note: note ?? this.note,
      createdAt: createdAt ?? this.createdAt,
      deletedAt: deletedAt ?? this.deletedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (contentKey.present) {
      map['content_key'] = Variable<String>(contentKey.value);
    }
    if (page.present) {
      map['page'] = Variable<int>(page.value);
    }
    if (panel.present) {
      map['panel'] = Variable<int>(panel.value);
    }
    if (mark.present) {
      map['mark'] = Variable<String>(mark.value);
    }
    if (note.present) {
      map['note'] = Variable<String>(note.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (deletedAt.present) {
      map['deleted_at'] = Variable<DateTime>(deletedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('BookmarksCompanion(')
          ..write('id: $id, ')
          ..write('contentKey: $contentKey, ')
          ..write('page: $page, ')
          ..write('panel: $panel, ')
          ..write('mark: $mark, ')
          ..write('note: $note, ')
          ..write('createdAt: $createdAt, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $PanelsTable extends Panels with TableInfo<$PanelsTable, PanelRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PanelsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _contentKeyMeta = const VerificationMeta(
    'contentKey',
  );
  @override
  late final GeneratedColumn<String> contentKey = GeneratedColumn<String>(
    'content_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _pageMeta = const VerificationMeta('page');
  @override
  late final GeneratedColumn<int> page = GeneratedColumn<int>(
    'page',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _idxMeta = const VerificationMeta('idx');
  @override
  late final GeneratedColumn<int> idx = GeneratedColumn<int>(
    'idx',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _xMeta = const VerificationMeta('x');
  @override
  late final GeneratedColumn<double> x = GeneratedColumn<double>(
    'x',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _yMeta = const VerificationMeta('y');
  @override
  late final GeneratedColumn<double> y = GeneratedColumn<double>(
    'y',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _wMeta = const VerificationMeta('w');
  @override
  late final GeneratedColumn<double> w = GeneratedColumn<double>(
    'w',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _hMeta = const VerificationMeta('h');
  @override
  late final GeneratedColumn<double> h = GeneratedColumn<double>(
    'h',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _kindMeta = const VerificationMeta('kind');
  @override
  late final GeneratedColumn<String> kind = GeneratedColumn<String>(
    'kind',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sourceMeta = const VerificationMeta('source');
  @override
  late final GeneratedColumn<String> source = GeneratedColumn<String>(
    'source',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _modelVerMeta = const VerificationMeta(
    'modelVer',
  );
  @override
  late final GeneratedColumn<int> modelVer = GeneratedColumn<int>(
    'model_ver',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _confidenceMeta = const VerificationMeta(
    'confidence',
  );
  @override
  late final GeneratedColumn<double> confidence = GeneratedColumn<double>(
    'confidence',
    aliasedName,
    false,
    type: DriftSqlType.double,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _shapeMeta = const VerificationMeta('shape');
  @override
  late final GeneratedColumn<String> shape = GeneratedColumn<String>(
    'shape',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    contentKey,
    page,
    idx,
    x,
    y,
    w,
    h,
    kind,
    source,
    modelVer,
    confidence,
    shape,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'panels';
  @override
  VerificationContext validateIntegrity(
    Insertable<PanelRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('content_key')) {
      context.handle(
        _contentKeyMeta,
        contentKey.isAcceptableOrUnknown(data['content_key']!, _contentKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_contentKeyMeta);
    }
    if (data.containsKey('page')) {
      context.handle(
        _pageMeta,
        page.isAcceptableOrUnknown(data['page']!, _pageMeta),
      );
    } else if (isInserting) {
      context.missing(_pageMeta);
    }
    if (data.containsKey('idx')) {
      context.handle(
        _idxMeta,
        idx.isAcceptableOrUnknown(data['idx']!, _idxMeta),
      );
    } else if (isInserting) {
      context.missing(_idxMeta);
    }
    if (data.containsKey('x')) {
      context.handle(_xMeta, x.isAcceptableOrUnknown(data['x']!, _xMeta));
    } else if (isInserting) {
      context.missing(_xMeta);
    }
    if (data.containsKey('y')) {
      context.handle(_yMeta, y.isAcceptableOrUnknown(data['y']!, _yMeta));
    } else if (isInserting) {
      context.missing(_yMeta);
    }
    if (data.containsKey('w')) {
      context.handle(_wMeta, w.isAcceptableOrUnknown(data['w']!, _wMeta));
    } else if (isInserting) {
      context.missing(_wMeta);
    }
    if (data.containsKey('h')) {
      context.handle(_hMeta, h.isAcceptableOrUnknown(data['h']!, _hMeta));
    } else if (isInserting) {
      context.missing(_hMeta);
    }
    if (data.containsKey('kind')) {
      context.handle(
        _kindMeta,
        kind.isAcceptableOrUnknown(data['kind']!, _kindMeta),
      );
    } else if (isInserting) {
      context.missing(_kindMeta);
    }
    if (data.containsKey('source')) {
      context.handle(
        _sourceMeta,
        source.isAcceptableOrUnknown(data['source']!, _sourceMeta),
      );
    } else if (isInserting) {
      context.missing(_sourceMeta);
    }
    if (data.containsKey('model_ver')) {
      context.handle(
        _modelVerMeta,
        modelVer.isAcceptableOrUnknown(data['model_ver']!, _modelVerMeta),
      );
    } else if (isInserting) {
      context.missing(_modelVerMeta);
    }
    if (data.containsKey('confidence')) {
      context.handle(
        _confidenceMeta,
        confidence.isAcceptableOrUnknown(data['confidence']!, _confidenceMeta),
      );
    } else if (isInserting) {
      context.missing(_confidenceMeta);
    }
    if (data.containsKey('shape')) {
      context.handle(
        _shapeMeta,
        shape.isAcceptableOrUnknown(data['shape']!, _shapeMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {contentKey, page, kind, idx, source};
  @override
  PanelRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return PanelRow(
      contentKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}content_key'],
      )!,
      page: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}page'],
      )!,
      idx: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}idx'],
      )!,
      x: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}x'],
      )!,
      y: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}y'],
      )!,
      w: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}w'],
      )!,
      h: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}h'],
      )!,
      kind: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}kind'],
      )!,
      source: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source'],
      )!,
      modelVer: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}model_ver'],
      )!,
      confidence: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}confidence'],
      )!,
      shape: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}shape'],
      ),
    );
  }

  @override
  $PanelsTable createAlias(String alias) {
    return $PanelsTable(attachedDatabase, alias);
  }
}

class PanelRow extends DataClass implements Insertable<PanelRow> {
  final String contentKey;
  final int page;
  final int idx;
  final double x;
  final double y;
  final double w;
  final double h;
  final String kind;
  final String source;
  final int modelVer;
  final double confidence;

  /// A frame's outline when it is not its box (Panel.shape), as
  /// "x,y,x,y,..." in page coordinates; null for a rectangle.
  final String? shape;
  const PanelRow({
    required this.contentKey,
    required this.page,
    required this.idx,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    required this.kind,
    required this.source,
    required this.modelVer,
    required this.confidence,
    this.shape,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['content_key'] = Variable<String>(contentKey);
    map['page'] = Variable<int>(page);
    map['idx'] = Variable<int>(idx);
    map['x'] = Variable<double>(x);
    map['y'] = Variable<double>(y);
    map['w'] = Variable<double>(w);
    map['h'] = Variable<double>(h);
    map['kind'] = Variable<String>(kind);
    map['source'] = Variable<String>(source);
    map['model_ver'] = Variable<int>(modelVer);
    map['confidence'] = Variable<double>(confidence);
    if (!nullToAbsent || shape != null) {
      map['shape'] = Variable<String>(shape);
    }
    return map;
  }

  PanelsCompanion toCompanion(bool nullToAbsent) {
    return PanelsCompanion(
      contentKey: Value(contentKey),
      page: Value(page),
      idx: Value(idx),
      x: Value(x),
      y: Value(y),
      w: Value(w),
      h: Value(h),
      kind: Value(kind),
      source: Value(source),
      modelVer: Value(modelVer),
      confidence: Value(confidence),
      shape: shape == null && nullToAbsent
          ? const Value.absent()
          : Value(shape),
    );
  }

  factory PanelRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return PanelRow(
      contentKey: serializer.fromJson<String>(json['contentKey']),
      page: serializer.fromJson<int>(json['page']),
      idx: serializer.fromJson<int>(json['idx']),
      x: serializer.fromJson<double>(json['x']),
      y: serializer.fromJson<double>(json['y']),
      w: serializer.fromJson<double>(json['w']),
      h: serializer.fromJson<double>(json['h']),
      kind: serializer.fromJson<String>(json['kind']),
      source: serializer.fromJson<String>(json['source']),
      modelVer: serializer.fromJson<int>(json['modelVer']),
      confidence: serializer.fromJson<double>(json['confidence']),
      shape: serializer.fromJson<String?>(json['shape']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'contentKey': serializer.toJson<String>(contentKey),
      'page': serializer.toJson<int>(page),
      'idx': serializer.toJson<int>(idx),
      'x': serializer.toJson<double>(x),
      'y': serializer.toJson<double>(y),
      'w': serializer.toJson<double>(w),
      'h': serializer.toJson<double>(h),
      'kind': serializer.toJson<String>(kind),
      'source': serializer.toJson<String>(source),
      'modelVer': serializer.toJson<int>(modelVer),
      'confidence': serializer.toJson<double>(confidence),
      'shape': serializer.toJson<String?>(shape),
    };
  }

  PanelRow copyWith({
    String? contentKey,
    int? page,
    int? idx,
    double? x,
    double? y,
    double? w,
    double? h,
    String? kind,
    String? source,
    int? modelVer,
    double? confidence,
    Value<String?> shape = const Value.absent(),
  }) => PanelRow(
    contentKey: contentKey ?? this.contentKey,
    page: page ?? this.page,
    idx: idx ?? this.idx,
    x: x ?? this.x,
    y: y ?? this.y,
    w: w ?? this.w,
    h: h ?? this.h,
    kind: kind ?? this.kind,
    source: source ?? this.source,
    modelVer: modelVer ?? this.modelVer,
    confidence: confidence ?? this.confidence,
    shape: shape.present ? shape.value : this.shape,
  );
  PanelRow copyWithCompanion(PanelsCompanion data) {
    return PanelRow(
      contentKey: data.contentKey.present
          ? data.contentKey.value
          : this.contentKey,
      page: data.page.present ? data.page.value : this.page,
      idx: data.idx.present ? data.idx.value : this.idx,
      x: data.x.present ? data.x.value : this.x,
      y: data.y.present ? data.y.value : this.y,
      w: data.w.present ? data.w.value : this.w,
      h: data.h.present ? data.h.value : this.h,
      kind: data.kind.present ? data.kind.value : this.kind,
      source: data.source.present ? data.source.value : this.source,
      modelVer: data.modelVer.present ? data.modelVer.value : this.modelVer,
      confidence: data.confidence.present
          ? data.confidence.value
          : this.confidence,
      shape: data.shape.present ? data.shape.value : this.shape,
    );
  }

  @override
  String toString() {
    return (StringBuffer('PanelRow(')
          ..write('contentKey: $contentKey, ')
          ..write('page: $page, ')
          ..write('idx: $idx, ')
          ..write('x: $x, ')
          ..write('y: $y, ')
          ..write('w: $w, ')
          ..write('h: $h, ')
          ..write('kind: $kind, ')
          ..write('source: $source, ')
          ..write('modelVer: $modelVer, ')
          ..write('confidence: $confidence, ')
          ..write('shape: $shape')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    contentKey,
    page,
    idx,
    x,
    y,
    w,
    h,
    kind,
    source,
    modelVer,
    confidence,
    shape,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PanelRow &&
          other.contentKey == this.contentKey &&
          other.page == this.page &&
          other.idx == this.idx &&
          other.x == this.x &&
          other.y == this.y &&
          other.w == this.w &&
          other.h == this.h &&
          other.kind == this.kind &&
          other.source == this.source &&
          other.modelVer == this.modelVer &&
          other.confidence == this.confidence &&
          other.shape == this.shape);
}

class PanelsCompanion extends UpdateCompanion<PanelRow> {
  final Value<String> contentKey;
  final Value<int> page;
  final Value<int> idx;
  final Value<double> x;
  final Value<double> y;
  final Value<double> w;
  final Value<double> h;
  final Value<String> kind;
  final Value<String> source;
  final Value<int> modelVer;
  final Value<double> confidence;
  final Value<String?> shape;
  final Value<int> rowid;
  const PanelsCompanion({
    this.contentKey = const Value.absent(),
    this.page = const Value.absent(),
    this.idx = const Value.absent(),
    this.x = const Value.absent(),
    this.y = const Value.absent(),
    this.w = const Value.absent(),
    this.h = const Value.absent(),
    this.kind = const Value.absent(),
    this.source = const Value.absent(),
    this.modelVer = const Value.absent(),
    this.confidence = const Value.absent(),
    this.shape = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  PanelsCompanion.insert({
    required String contentKey,
    required int page,
    required int idx,
    required double x,
    required double y,
    required double w,
    required double h,
    required String kind,
    required String source,
    required int modelVer,
    required double confidence,
    this.shape = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : contentKey = Value(contentKey),
       page = Value(page),
       idx = Value(idx),
       x = Value(x),
       y = Value(y),
       w = Value(w),
       h = Value(h),
       kind = Value(kind),
       source = Value(source),
       modelVer = Value(modelVer),
       confidence = Value(confidence);
  static Insertable<PanelRow> custom({
    Expression<String>? contentKey,
    Expression<int>? page,
    Expression<int>? idx,
    Expression<double>? x,
    Expression<double>? y,
    Expression<double>? w,
    Expression<double>? h,
    Expression<String>? kind,
    Expression<String>? source,
    Expression<int>? modelVer,
    Expression<double>? confidence,
    Expression<String>? shape,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (contentKey != null) 'content_key': contentKey,
      if (page != null) 'page': page,
      if (idx != null) 'idx': idx,
      if (x != null) 'x': x,
      if (y != null) 'y': y,
      if (w != null) 'w': w,
      if (h != null) 'h': h,
      if (kind != null) 'kind': kind,
      if (source != null) 'source': source,
      if (modelVer != null) 'model_ver': modelVer,
      if (confidence != null) 'confidence': confidence,
      if (shape != null) 'shape': shape,
      if (rowid != null) 'rowid': rowid,
    });
  }

  PanelsCompanion copyWith({
    Value<String>? contentKey,
    Value<int>? page,
    Value<int>? idx,
    Value<double>? x,
    Value<double>? y,
    Value<double>? w,
    Value<double>? h,
    Value<String>? kind,
    Value<String>? source,
    Value<int>? modelVer,
    Value<double>? confidence,
    Value<String?>? shape,
    Value<int>? rowid,
  }) {
    return PanelsCompanion(
      contentKey: contentKey ?? this.contentKey,
      page: page ?? this.page,
      idx: idx ?? this.idx,
      x: x ?? this.x,
      y: y ?? this.y,
      w: w ?? this.w,
      h: h ?? this.h,
      kind: kind ?? this.kind,
      source: source ?? this.source,
      modelVer: modelVer ?? this.modelVer,
      confidence: confidence ?? this.confidence,
      shape: shape ?? this.shape,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (contentKey.present) {
      map['content_key'] = Variable<String>(contentKey.value);
    }
    if (page.present) {
      map['page'] = Variable<int>(page.value);
    }
    if (idx.present) {
      map['idx'] = Variable<int>(idx.value);
    }
    if (x.present) {
      map['x'] = Variable<double>(x.value);
    }
    if (y.present) {
      map['y'] = Variable<double>(y.value);
    }
    if (w.present) {
      map['w'] = Variable<double>(w.value);
    }
    if (h.present) {
      map['h'] = Variable<double>(h.value);
    }
    if (kind.present) {
      map['kind'] = Variable<String>(kind.value);
    }
    if (source.present) {
      map['source'] = Variable<String>(source.value);
    }
    if (modelVer.present) {
      map['model_ver'] = Variable<int>(modelVer.value);
    }
    if (confidence.present) {
      map['confidence'] = Variable<double>(confidence.value);
    }
    if (shape.present) {
      map['shape'] = Variable<String>(shape.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PanelsCompanion(')
          ..write('contentKey: $contentKey, ')
          ..write('page: $page, ')
          ..write('idx: $idx, ')
          ..write('x: $x, ')
          ..write('y: $y, ')
          ..write('w: $w, ')
          ..write('h: $h, ')
          ..write('kind: $kind, ')
          ..write('source: $source, ')
          ..write('modelVer: $modelVer, ')
          ..write('confidence: $confidence, ')
          ..write('shape: $shape, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $AnalysedPagesTable extends AnalysedPages
    with TableInfo<$AnalysedPagesTable, AnalysedPage> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AnalysedPagesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _contentKeyMeta = const VerificationMeta(
    'contentKey',
  );
  @override
  late final GeneratedColumn<String> contentKey = GeneratedColumn<String>(
    'content_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _pageMeta = const VerificationMeta('page');
  @override
  late final GeneratedColumn<int> page = GeneratedColumn<int>(
    'page',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sourceMeta = const VerificationMeta('source');
  @override
  late final GeneratedColumn<String> source = GeneratedColumn<String>(
    'source',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _modelVerMeta = const VerificationMeta(
    'modelVer',
  );
  @override
  late final GeneratedColumn<int> modelVer = GeneratedColumn<int>(
    'model_ver',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _millisMeta = const VerificationMeta('millis');
  @override
  late final GeneratedColumn<int> millis = GeneratedColumn<int>(
    'millis',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _analysedAtMeta = const VerificationMeta(
    'analysedAt',
  );
  @override
  late final GeneratedColumn<DateTime> analysedAt = GeneratedColumn<DateTime>(
    'analysed_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    contentKey,
    page,
    source,
    modelVer,
    millis,
    analysedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'analysed_pages';
  @override
  VerificationContext validateIntegrity(
    Insertable<AnalysedPage> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('content_key')) {
      context.handle(
        _contentKeyMeta,
        contentKey.isAcceptableOrUnknown(data['content_key']!, _contentKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_contentKeyMeta);
    }
    if (data.containsKey('page')) {
      context.handle(
        _pageMeta,
        page.isAcceptableOrUnknown(data['page']!, _pageMeta),
      );
    } else if (isInserting) {
      context.missing(_pageMeta);
    }
    if (data.containsKey('source')) {
      context.handle(
        _sourceMeta,
        source.isAcceptableOrUnknown(data['source']!, _sourceMeta),
      );
    } else if (isInserting) {
      context.missing(_sourceMeta);
    }
    if (data.containsKey('model_ver')) {
      context.handle(
        _modelVerMeta,
        modelVer.isAcceptableOrUnknown(data['model_ver']!, _modelVerMeta),
      );
    } else if (isInserting) {
      context.missing(_modelVerMeta);
    }
    if (data.containsKey('millis')) {
      context.handle(
        _millisMeta,
        millis.isAcceptableOrUnknown(data['millis']!, _millisMeta),
      );
    } else if (isInserting) {
      context.missing(_millisMeta);
    }
    if (data.containsKey('analysed_at')) {
      context.handle(
        _analysedAtMeta,
        analysedAt.isAcceptableOrUnknown(data['analysed_at']!, _analysedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_analysedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {contentKey, page, source};
  @override
  AnalysedPage map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AnalysedPage(
      contentKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}content_key'],
      )!,
      page: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}page'],
      )!,
      source: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source'],
      )!,
      modelVer: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}model_ver'],
      )!,
      millis: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}millis'],
      )!,
      analysedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}analysed_at'],
      )!,
    );
  }

  @override
  $AnalysedPagesTable createAlias(String alias) {
    return $AnalysedPagesTable(attachedDatabase, alias);
  }
}

class AnalysedPage extends DataClass implements Insertable<AnalysedPage> {
  final String contentKey;
  final int page;
  final String source;
  final int modelVer;
  final int millis;
  final DateTime analysedAt;
  const AnalysedPage({
    required this.contentKey,
    required this.page,
    required this.source,
    required this.modelVer,
    required this.millis,
    required this.analysedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['content_key'] = Variable<String>(contentKey);
    map['page'] = Variable<int>(page);
    map['source'] = Variable<String>(source);
    map['model_ver'] = Variable<int>(modelVer);
    map['millis'] = Variable<int>(millis);
    map['analysed_at'] = Variable<DateTime>(analysedAt);
    return map;
  }

  AnalysedPagesCompanion toCompanion(bool nullToAbsent) {
    return AnalysedPagesCompanion(
      contentKey: Value(contentKey),
      page: Value(page),
      source: Value(source),
      modelVer: Value(modelVer),
      millis: Value(millis),
      analysedAt: Value(analysedAt),
    );
  }

  factory AnalysedPage.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return AnalysedPage(
      contentKey: serializer.fromJson<String>(json['contentKey']),
      page: serializer.fromJson<int>(json['page']),
      source: serializer.fromJson<String>(json['source']),
      modelVer: serializer.fromJson<int>(json['modelVer']),
      millis: serializer.fromJson<int>(json['millis']),
      analysedAt: serializer.fromJson<DateTime>(json['analysedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'contentKey': serializer.toJson<String>(contentKey),
      'page': serializer.toJson<int>(page),
      'source': serializer.toJson<String>(source),
      'modelVer': serializer.toJson<int>(modelVer),
      'millis': serializer.toJson<int>(millis),
      'analysedAt': serializer.toJson<DateTime>(analysedAt),
    };
  }

  AnalysedPage copyWith({
    String? contentKey,
    int? page,
    String? source,
    int? modelVer,
    int? millis,
    DateTime? analysedAt,
  }) => AnalysedPage(
    contentKey: contentKey ?? this.contentKey,
    page: page ?? this.page,
    source: source ?? this.source,
    modelVer: modelVer ?? this.modelVer,
    millis: millis ?? this.millis,
    analysedAt: analysedAt ?? this.analysedAt,
  );
  AnalysedPage copyWithCompanion(AnalysedPagesCompanion data) {
    return AnalysedPage(
      contentKey: data.contentKey.present
          ? data.contentKey.value
          : this.contentKey,
      page: data.page.present ? data.page.value : this.page,
      source: data.source.present ? data.source.value : this.source,
      modelVer: data.modelVer.present ? data.modelVer.value : this.modelVer,
      millis: data.millis.present ? data.millis.value : this.millis,
      analysedAt: data.analysedAt.present
          ? data.analysedAt.value
          : this.analysedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('AnalysedPage(')
          ..write('contentKey: $contentKey, ')
          ..write('page: $page, ')
          ..write('source: $source, ')
          ..write('modelVer: $modelVer, ')
          ..write('millis: $millis, ')
          ..write('analysedAt: $analysedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(contentKey, page, source, modelVer, millis, analysedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AnalysedPage &&
          other.contentKey == this.contentKey &&
          other.page == this.page &&
          other.source == this.source &&
          other.modelVer == this.modelVer &&
          other.millis == this.millis &&
          other.analysedAt == this.analysedAt);
}

class AnalysedPagesCompanion extends UpdateCompanion<AnalysedPage> {
  final Value<String> contentKey;
  final Value<int> page;
  final Value<String> source;
  final Value<int> modelVer;
  final Value<int> millis;
  final Value<DateTime> analysedAt;
  final Value<int> rowid;
  const AnalysedPagesCompanion({
    this.contentKey = const Value.absent(),
    this.page = const Value.absent(),
    this.source = const Value.absent(),
    this.modelVer = const Value.absent(),
    this.millis = const Value.absent(),
    this.analysedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  AnalysedPagesCompanion.insert({
    required String contentKey,
    required int page,
    required String source,
    required int modelVer,
    required int millis,
    required DateTime analysedAt,
    this.rowid = const Value.absent(),
  }) : contentKey = Value(contentKey),
       page = Value(page),
       source = Value(source),
       modelVer = Value(modelVer),
       millis = Value(millis),
       analysedAt = Value(analysedAt);
  static Insertable<AnalysedPage> custom({
    Expression<String>? contentKey,
    Expression<int>? page,
    Expression<String>? source,
    Expression<int>? modelVer,
    Expression<int>? millis,
    Expression<DateTime>? analysedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (contentKey != null) 'content_key': contentKey,
      if (page != null) 'page': page,
      if (source != null) 'source': source,
      if (modelVer != null) 'model_ver': modelVer,
      if (millis != null) 'millis': millis,
      if (analysedAt != null) 'analysed_at': analysedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  AnalysedPagesCompanion copyWith({
    Value<String>? contentKey,
    Value<int>? page,
    Value<String>? source,
    Value<int>? modelVer,
    Value<int>? millis,
    Value<DateTime>? analysedAt,
    Value<int>? rowid,
  }) {
    return AnalysedPagesCompanion(
      contentKey: contentKey ?? this.contentKey,
      page: page ?? this.page,
      source: source ?? this.source,
      modelVer: modelVer ?? this.modelVer,
      millis: millis ?? this.millis,
      analysedAt: analysedAt ?? this.analysedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (contentKey.present) {
      map['content_key'] = Variable<String>(contentKey.value);
    }
    if (page.present) {
      map['page'] = Variable<int>(page.value);
    }
    if (source.present) {
      map['source'] = Variable<String>(source.value);
    }
    if (modelVer.present) {
      map['model_ver'] = Variable<int>(modelVer.value);
    }
    if (millis.present) {
      map['millis'] = Variable<int>(millis.value);
    }
    if (analysedAt.present) {
      map['analysed_at'] = Variable<DateTime>(analysedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('AnalysedPagesCompanion(')
          ..write('contentKey: $contentKey, ')
          ..write('page: $page, ')
          ..write('source: $source, ')
          ..write('modelVer: $modelVer, ')
          ..write('millis: $millis, ')
          ..write('analysedAt: $analysedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $OverridesTable extends Overrides
    with TableInfo<$OverridesTable, Override> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $OverridesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _contentKeyMeta = const VerificationMeta(
    'contentKey',
  );
  @override
  late final GeneratedColumn<String> contentKey = GeneratedColumn<String>(
    'content_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _fieldMeta = const VerificationMeta('field');
  @override
  late final GeneratedColumn<String> field = GeneratedColumn<String>(
    'field',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _valueMeta = const VerificationMeta('value');
  @override
  late final GeneratedColumn<String> value = GeneratedColumn<String>(
    'value',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [contentKey, field, value];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'overrides';
  @override
  VerificationContext validateIntegrity(
    Insertable<Override> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('content_key')) {
      context.handle(
        _contentKeyMeta,
        contentKey.isAcceptableOrUnknown(data['content_key']!, _contentKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_contentKeyMeta);
    }
    if (data.containsKey('field')) {
      context.handle(
        _fieldMeta,
        field.isAcceptableOrUnknown(data['field']!, _fieldMeta),
      );
    } else if (isInserting) {
      context.missing(_fieldMeta);
    }
    if (data.containsKey('value')) {
      context.handle(
        _valueMeta,
        value.isAcceptableOrUnknown(data['value']!, _valueMeta),
      );
    } else if (isInserting) {
      context.missing(_valueMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {contentKey, field};
  @override
  Override map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Override(
      contentKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}content_key'],
      )!,
      field: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}field'],
      )!,
      value: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}value'],
      )!,
    );
  }

  @override
  $OverridesTable createAlias(String alias) {
    return $OverridesTable(attachedDatabase, alias);
  }
}

class Override extends DataClass implements Insertable<Override> {
  final String contentKey;
  final String field;
  final String value;
  const Override({
    required this.contentKey,
    required this.field,
    required this.value,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['content_key'] = Variable<String>(contentKey);
    map['field'] = Variable<String>(field);
    map['value'] = Variable<String>(value);
    return map;
  }

  OverridesCompanion toCompanion(bool nullToAbsent) {
    return OverridesCompanion(
      contentKey: Value(contentKey),
      field: Value(field),
      value: Value(value),
    );
  }

  factory Override.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Override(
      contentKey: serializer.fromJson<String>(json['contentKey']),
      field: serializer.fromJson<String>(json['field']),
      value: serializer.fromJson<String>(json['value']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'contentKey': serializer.toJson<String>(contentKey),
      'field': serializer.toJson<String>(field),
      'value': serializer.toJson<String>(value),
    };
  }

  Override copyWith({String? contentKey, String? field, String? value}) =>
      Override(
        contentKey: contentKey ?? this.contentKey,
        field: field ?? this.field,
        value: value ?? this.value,
      );
  Override copyWithCompanion(OverridesCompanion data) {
    return Override(
      contentKey: data.contentKey.present
          ? data.contentKey.value
          : this.contentKey,
      field: data.field.present ? data.field.value : this.field,
      value: data.value.present ? data.value.value : this.value,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Override(')
          ..write('contentKey: $contentKey, ')
          ..write('field: $field, ')
          ..write('value: $value')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(contentKey, field, value);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Override &&
          other.contentKey == this.contentKey &&
          other.field == this.field &&
          other.value == this.value);
}

class OverridesCompanion extends UpdateCompanion<Override> {
  final Value<String> contentKey;
  final Value<String> field;
  final Value<String> value;
  final Value<int> rowid;
  const OverridesCompanion({
    this.contentKey = const Value.absent(),
    this.field = const Value.absent(),
    this.value = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  OverridesCompanion.insert({
    required String contentKey,
    required String field,
    required String value,
    this.rowid = const Value.absent(),
  }) : contentKey = Value(contentKey),
       field = Value(field),
       value = Value(value);
  static Insertable<Override> custom({
    Expression<String>? contentKey,
    Expression<String>? field,
    Expression<String>? value,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (contentKey != null) 'content_key': contentKey,
      if (field != null) 'field': field,
      if (value != null) 'value': value,
      if (rowid != null) 'rowid': rowid,
    });
  }

  OverridesCompanion copyWith({
    Value<String>? contentKey,
    Value<String>? field,
    Value<String>? value,
    Value<int>? rowid,
  }) {
    return OverridesCompanion(
      contentKey: contentKey ?? this.contentKey,
      field: field ?? this.field,
      value: value ?? this.value,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (contentKey.present) {
      map['content_key'] = Variable<String>(contentKey.value);
    }
    if (field.present) {
      map['field'] = Variable<String>(field.value);
    }
    if (value.present) {
      map['value'] = Variable<String>(value.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('OverridesCompanion(')
          ..write('contentKey: $contentKey, ')
          ..write('field: $field, ')
          ..write('value: $value, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ReadLogTable extends ReadLog with TableInfo<$ReadLogTable, ReadLogData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ReadLogTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _contentKeyMeta = const VerificationMeta(
    'contentKey',
  );
  @override
  late final GeneratedColumn<String> contentKey = GeneratedColumn<String>(
    'content_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _startedAtMeta = const VerificationMeta(
    'startedAt',
  );
  @override
  late final GeneratedColumn<DateTime> startedAt = GeneratedColumn<DateTime>(
    'started_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _endedAtMeta = const VerificationMeta(
    'endedAt',
  );
  @override
  late final GeneratedColumn<DateTime> endedAt = GeneratedColumn<DateTime>(
    'ended_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _pagesMeta = const VerificationMeta('pages');
  @override
  late final GeneratedColumn<int> pages = GeneratedColumn<int>(
    'pages',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [contentKey, startedAt, endedAt, pages];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'read_log';
  @override
  VerificationContext validateIntegrity(
    Insertable<ReadLogData> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('content_key')) {
      context.handle(
        _contentKeyMeta,
        contentKey.isAcceptableOrUnknown(data['content_key']!, _contentKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_contentKeyMeta);
    }
    if (data.containsKey('started_at')) {
      context.handle(
        _startedAtMeta,
        startedAt.isAcceptableOrUnknown(data['started_at']!, _startedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_startedAtMeta);
    }
    if (data.containsKey('ended_at')) {
      context.handle(
        _endedAtMeta,
        endedAt.isAcceptableOrUnknown(data['ended_at']!, _endedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_endedAtMeta);
    }
    if (data.containsKey('pages')) {
      context.handle(
        _pagesMeta,
        pages.isAcceptableOrUnknown(data['pages']!, _pagesMeta),
      );
    } else if (isInserting) {
      context.missing(_pagesMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => const {};
  @override
  ReadLogData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ReadLogData(
      contentKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}content_key'],
      )!,
      startedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}started_at'],
      )!,
      endedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}ended_at'],
      )!,
      pages: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}pages'],
      )!,
    );
  }

  @override
  $ReadLogTable createAlias(String alias) {
    return $ReadLogTable(attachedDatabase, alias);
  }
}

class ReadLogData extends DataClass implements Insertable<ReadLogData> {
  final String contentKey;
  final DateTime startedAt;
  final DateTime endedAt;
  final int pages;
  const ReadLogData({
    required this.contentKey,
    required this.startedAt,
    required this.endedAt,
    required this.pages,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['content_key'] = Variable<String>(contentKey);
    map['started_at'] = Variable<DateTime>(startedAt);
    map['ended_at'] = Variable<DateTime>(endedAt);
    map['pages'] = Variable<int>(pages);
    return map;
  }

  ReadLogCompanion toCompanion(bool nullToAbsent) {
    return ReadLogCompanion(
      contentKey: Value(contentKey),
      startedAt: Value(startedAt),
      endedAt: Value(endedAt),
      pages: Value(pages),
    );
  }

  factory ReadLogData.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ReadLogData(
      contentKey: serializer.fromJson<String>(json['contentKey']),
      startedAt: serializer.fromJson<DateTime>(json['startedAt']),
      endedAt: serializer.fromJson<DateTime>(json['endedAt']),
      pages: serializer.fromJson<int>(json['pages']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'contentKey': serializer.toJson<String>(contentKey),
      'startedAt': serializer.toJson<DateTime>(startedAt),
      'endedAt': serializer.toJson<DateTime>(endedAt),
      'pages': serializer.toJson<int>(pages),
    };
  }

  ReadLogData copyWith({
    String? contentKey,
    DateTime? startedAt,
    DateTime? endedAt,
    int? pages,
  }) => ReadLogData(
    contentKey: contentKey ?? this.contentKey,
    startedAt: startedAt ?? this.startedAt,
    endedAt: endedAt ?? this.endedAt,
    pages: pages ?? this.pages,
  );
  ReadLogData copyWithCompanion(ReadLogCompanion data) {
    return ReadLogData(
      contentKey: data.contentKey.present
          ? data.contentKey.value
          : this.contentKey,
      startedAt: data.startedAt.present ? data.startedAt.value : this.startedAt,
      endedAt: data.endedAt.present ? data.endedAt.value : this.endedAt,
      pages: data.pages.present ? data.pages.value : this.pages,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ReadLogData(')
          ..write('contentKey: $contentKey, ')
          ..write('startedAt: $startedAt, ')
          ..write('endedAt: $endedAt, ')
          ..write('pages: $pages')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(contentKey, startedAt, endedAt, pages);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ReadLogData &&
          other.contentKey == this.contentKey &&
          other.startedAt == this.startedAt &&
          other.endedAt == this.endedAt &&
          other.pages == this.pages);
}

class ReadLogCompanion extends UpdateCompanion<ReadLogData> {
  final Value<String> contentKey;
  final Value<DateTime> startedAt;
  final Value<DateTime> endedAt;
  final Value<int> pages;
  final Value<int> rowid;
  const ReadLogCompanion({
    this.contentKey = const Value.absent(),
    this.startedAt = const Value.absent(),
    this.endedAt = const Value.absent(),
    this.pages = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ReadLogCompanion.insert({
    required String contentKey,
    required DateTime startedAt,
    required DateTime endedAt,
    required int pages,
    this.rowid = const Value.absent(),
  }) : contentKey = Value(contentKey),
       startedAt = Value(startedAt),
       endedAt = Value(endedAt),
       pages = Value(pages);
  static Insertable<ReadLogData> custom({
    Expression<String>? contentKey,
    Expression<DateTime>? startedAt,
    Expression<DateTime>? endedAt,
    Expression<int>? pages,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (contentKey != null) 'content_key': contentKey,
      if (startedAt != null) 'started_at': startedAt,
      if (endedAt != null) 'ended_at': endedAt,
      if (pages != null) 'pages': pages,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ReadLogCompanion copyWith({
    Value<String>? contentKey,
    Value<DateTime>? startedAt,
    Value<DateTime>? endedAt,
    Value<int>? pages,
    Value<int>? rowid,
  }) {
    return ReadLogCompanion(
      contentKey: contentKey ?? this.contentKey,
      startedAt: startedAt ?? this.startedAt,
      endedAt: endedAt ?? this.endedAt,
      pages: pages ?? this.pages,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (contentKey.present) {
      map['content_key'] = Variable<String>(contentKey.value);
    }
    if (startedAt.present) {
      map['started_at'] = Variable<DateTime>(startedAt.value);
    }
    if (endedAt.present) {
      map['ended_at'] = Variable<DateTime>(endedAt.value);
    }
    if (pages.present) {
      map['pages'] = Variable<int>(pages.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ReadLogCompanion(')
          ..write('contentKey: $contentKey, ')
          ..write('startedAt: $startedAt, ')
          ..write('endedAt: $endedAt, ')
          ..write('pages: $pages, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SettingsTable extends Settings
    with TableInfo<$SettingsTable, SettingRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SettingsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
    'key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _valueMeta = const VerificationMeta('value');
  @override
  late final GeneratedColumn<String> value = GeneratedColumn<String>(
    'value',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [key, value];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'settings';
  @override
  VerificationContext validateIntegrity(
    Insertable<SettingRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('key')) {
      context.handle(
        _keyMeta,
        key.isAcceptableOrUnknown(data['key']!, _keyMeta),
      );
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('value')) {
      context.handle(
        _valueMeta,
        value.isAcceptableOrUnknown(data['value']!, _valueMeta),
      );
    } else if (isInserting) {
      context.missing(_valueMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {key};
  @override
  SettingRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SettingRow(
      key: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}key'],
      )!,
      value: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}value'],
      )!,
    );
  }

  @override
  $SettingsTable createAlias(String alias) {
    return $SettingsTable(attachedDatabase, alias);
  }
}

class SettingRow extends DataClass implements Insertable<SettingRow> {
  final String key;
  final String value;
  const SettingRow({required this.key, required this.value});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    map['value'] = Variable<String>(value);
    return map;
  }

  SettingsCompanion toCompanion(bool nullToAbsent) {
    return SettingsCompanion(key: Value(key), value: Value(value));
  }

  factory SettingRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SettingRow(
      key: serializer.fromJson<String>(json['key']),
      value: serializer.fromJson<String>(json['value']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'key': serializer.toJson<String>(key),
      'value': serializer.toJson<String>(value),
    };
  }

  SettingRow copyWith({String? key, String? value}) =>
      SettingRow(key: key ?? this.key, value: value ?? this.value);
  SettingRow copyWithCompanion(SettingsCompanion data) {
    return SettingRow(
      key: data.key.present ? data.key.value : this.key,
      value: data.value.present ? data.value.value : this.value,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SettingRow(')
          ..write('key: $key, ')
          ..write('value: $value')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(key, value);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SettingRow &&
          other.key == this.key &&
          other.value == this.value);
}

class SettingsCompanion extends UpdateCompanion<SettingRow> {
  final Value<String> key;
  final Value<String> value;
  final Value<int> rowid;
  const SettingsCompanion({
    this.key = const Value.absent(),
    this.value = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SettingsCompanion.insert({
    required String key,
    required String value,
    this.rowid = const Value.absent(),
  }) : key = Value(key),
       value = Value(value);
  static Insertable<SettingRow> custom({
    Expression<String>? key,
    Expression<String>? value,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (key != null) 'key': key,
      if (value != null) 'value': value,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SettingsCompanion copyWith({
    Value<String>? key,
    Value<String>? value,
    Value<int>? rowid,
  }) {
    return SettingsCompanion(
      key: key ?? this.key,
      value: value ?? this.value,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (value.present) {
      map['value'] = Variable<String>(value.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SettingsCompanion(')
          ..write('key: $key, ')
          ..write('value: $value, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $SeriesTableTable seriesTable = $SeriesTableTable(this);
  late final $BooksTable books = $BooksTable(this);
  late final $RootsTable roots = $RootsTable(this);
  late final $FilesTable files = $FilesTable(this);
  late final $ProgressTable progress = $ProgressTable(this);
  late final $BookmarksTable bookmarks = $BookmarksTable(this);
  late final $PanelsTable panels = $PanelsTable(this);
  late final $AnalysedPagesTable analysedPages = $AnalysedPagesTable(this);
  late final $OverridesTable overrides = $OverridesTable(this);
  late final $ReadLogTable readLog = $ReadLogTable(this);
  late final $SettingsTable settings = $SettingsTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    seriesTable,
    books,
    roots,
    files,
    progress,
    bookmarks,
    panels,
    analysedPages,
    overrides,
    readLog,
    settings,
  ];
}

typedef $$SeriesTableTableCreateCompanionBuilder =
    SeriesTableCompanion Function({
      Value<int> id,
      required String name,
      required String sortName,
      Value<bool> rtl,
    });
typedef $$SeriesTableTableUpdateCompanionBuilder =
    SeriesTableCompanion Function({
      Value<int> id,
      Value<String> name,
      Value<String> sortName,
      Value<bool> rtl,
    });

final class $$SeriesTableTableReferences
    extends BaseReferences<_$AppDatabase, $SeriesTableTable, Series> {
  $$SeriesTableTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$BooksTable, List<Book>> _booksRefsTable(
    _$AppDatabase db,
  ) => MultiTypedResultKey.fromTable(
    db.books,
    aliasName: 'series__id__books__series_id',
  );

  $$BooksTableProcessedTableManager get booksRefs {
    final manager = $$BooksTableTableManager(
      $_db,
      $_db.books,
    ).filter((f) => f.seriesId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache = $_typedResult.readTableOrNull(_booksRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$SeriesTableTableFilterComposer
    extends Composer<_$AppDatabase, $SeriesTableTable> {
  $$SeriesTableTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sortName => $composableBuilder(
    column: $table.sortName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get rtl => $composableBuilder(
    column: $table.rtl,
    builder: (column) => ColumnFilters(column),
  );

  Expression<bool> booksRefs(
    Expression<bool> Function($$BooksTableFilterComposer f) f,
  ) {
    final $$BooksTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.books,
      getReferencedColumn: (t) => t.seriesId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$BooksTableFilterComposer(
            $db: $db,
            $table: $db.books,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$SeriesTableTableOrderingComposer
    extends Composer<_$AppDatabase, $SeriesTableTable> {
  $$SeriesTableTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sortName => $composableBuilder(
    column: $table.sortName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get rtl => $composableBuilder(
    column: $table.rtl,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SeriesTableTableAnnotationComposer
    extends Composer<_$AppDatabase, $SeriesTableTable> {
  $$SeriesTableTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get sortName =>
      $composableBuilder(column: $table.sortName, builder: (column) => column);

  GeneratedColumn<bool> get rtl =>
      $composableBuilder(column: $table.rtl, builder: (column) => column);

  Expression<T> booksRefs<T extends Object>(
    Expression<T> Function($$BooksTableAnnotationComposer a) f,
  ) {
    final $$BooksTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.books,
      getReferencedColumn: (t) => t.seriesId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$BooksTableAnnotationComposer(
            $db: $db,
            $table: $db.books,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$SeriesTableTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $SeriesTableTable,
          Series,
          $$SeriesTableTableFilterComposer,
          $$SeriesTableTableOrderingComposer,
          $$SeriesTableTableAnnotationComposer,
          $$SeriesTableTableCreateCompanionBuilder,
          $$SeriesTableTableUpdateCompanionBuilder,
          (Series, $$SeriesTableTableReferences),
          Series,
          PrefetchHooks Function({bool booksRefs})
        > {
  $$SeriesTableTableTableManager(_$AppDatabase db, $SeriesTableTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SeriesTableTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SeriesTableTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SeriesTableTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String> sortName = const Value.absent(),
                Value<bool> rtl = const Value.absent(),
              }) => SeriesTableCompanion(
                id: id,
                name: name,
                sortName: sortName,
                rtl: rtl,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String name,
                required String sortName,
                Value<bool> rtl = const Value.absent(),
              }) => SeriesTableCompanion.insert(
                id: id,
                name: name,
                sortName: sortName,
                rtl: rtl,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$SeriesTableTable, Series>(table),
                  $$SeriesTableTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({booksRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [if (booksRefs) db.books],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (booksRefs)
                    await $_getPrefetchedData<Series, $SeriesTableTable, Book>(
                      currentTable: table,
                      referencedTable: $$SeriesTableTableReferences
                          ._booksRefsTable(db),
                      managerFromTypedResult: (p0) =>
                          $$SeriesTableTableReferences(db, table, p0).booksRefs,
                      referencedItemsForCurrentItem: (item, referencedItems) =>
                          referencedItems.where((e) => e.seriesId == item.id),
                      typedResults: items,
                    ),
                ];
              },
            );
          },
        ),
      );
}

typedef $$SeriesTableTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $SeriesTableTable,
      Series,
      $$SeriesTableTableFilterComposer,
      $$SeriesTableTableOrderingComposer,
      $$SeriesTableTableAnnotationComposer,
      $$SeriesTableTableCreateCompanionBuilder,
      $$SeriesTableTableUpdateCompanionBuilder,
      (Series, $$SeriesTableTableReferences),
      Series,
      PrefetchHooks Function({bool booksRefs})
    >;
typedef $$BooksTableCreateCompanionBuilder = BooksCompanion Function({
  required String contentKey,
  required String title,
  Value<int?> seriesId,
  Value<String?> number,
  required int pageCount,
  required String format,
  Value<DateTime> addedAt,
  Value<String?> issueTitle,
  Value<int?> volume,
  Value<int?> year,
  Value<String?> writers,
  Value<String?> artists,
  Value<String?> summary,
  Value<int> rowid,
});
typedef $$BooksTableUpdateCompanionBuilder = BooksCompanion Function({
  Value<String> contentKey,
  Value<String> title,
  Value<int?> seriesId,
  Value<String?> number,
  Value<int> pageCount,
  Value<String> format,
  Value<DateTime> addedAt,
  Value<String?> issueTitle,
  Value<int?> volume,
  Value<int?> year,
  Value<String?> writers,
  Value<String?> artists,
  Value<String?> summary,
  Value<int> rowid,
});

final class $$BooksTableReferences
    extends BaseReferences<_$AppDatabase, $BooksTable, Book> {
  $$BooksTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $SeriesTableTable _seriesIdTable(_$AppDatabase db) =>
      db.seriesTable.createAlias('books__series_id__series__id');

  $$SeriesTableTableProcessedTableManager? get seriesId {
    final $_column = $_itemColumn<int>('series_id');
    if ($_column == null) return null;
    final manager = $$SeriesTableTableTableManager(
      $_db,
      $_db.seriesTable,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_seriesIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static MultiTypedResultKey<$FilesTable, List<BookFile>> _filesRefsTable(
    _$AppDatabase db,
  ) => MultiTypedResultKey.fromTable(
    db.files,
    aliasName: 'books__content_key__files__content_key',
  );

  $$FilesTableProcessedTableManager get filesRefs {
    final manager = $$FilesTableTableManager($_db, $_db.files).filter(
      (f) => f.contentKey.contentKey.sqlEquals(
        $_itemColumn<String>('content_key')!,
      ),
    );

    final cache = $_typedResult.readTableOrNull(_filesRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$BooksTableFilterComposer extends Composer<_$AppDatabase, $BooksTable> {
  $$BooksTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get contentKey => $composableBuilder(
    column: $table.contentKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get number => $composableBuilder(
    column: $table.number,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get pageCount => $composableBuilder(
    column: $table.pageCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get format => $composableBuilder(
    column: $table.format,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get addedAt => $composableBuilder(
    column: $table.addedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get issueTitle => $composableBuilder(
    column: $table.issueTitle,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get volume => $composableBuilder(
    column: $table.volume,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get year => $composableBuilder(
    column: $table.year,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get writers => $composableBuilder(
    column: $table.writers,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get artists => $composableBuilder(
    column: $table.artists,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get summary => $composableBuilder(
    column: $table.summary,
    builder: (column) => ColumnFilters(column),
  );

  $$SeriesTableTableFilterComposer get seriesId {
    final $$SeriesTableTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.seriesId,
      referencedTable: $db.seriesTable,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SeriesTableTableFilterComposer(
            $db: $db,
            $table: $db.seriesTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  Expression<bool> filesRefs(
    Expression<bool> Function($$FilesTableFilterComposer f) f,
  ) {
    final $$FilesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.contentKey,
      referencedTable: $db.files,
      getReferencedColumn: (t) => t.contentKey,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$FilesTableFilterComposer(
            $db: $db,
            $table: $db.files,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$BooksTableOrderingComposer
    extends Composer<_$AppDatabase, $BooksTable> {
  $$BooksTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get contentKey => $composableBuilder(
    column: $table.contentKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get number => $composableBuilder(
    column: $table.number,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get pageCount => $composableBuilder(
    column: $table.pageCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get format => $composableBuilder(
    column: $table.format,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get addedAt => $composableBuilder(
    column: $table.addedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get issueTitle => $composableBuilder(
    column: $table.issueTitle,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get volume => $composableBuilder(
    column: $table.volume,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get year => $composableBuilder(
    column: $table.year,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get writers => $composableBuilder(
    column: $table.writers,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get artists => $composableBuilder(
    column: $table.artists,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get summary => $composableBuilder(
    column: $table.summary,
    builder: (column) => ColumnOrderings(column),
  );

  $$SeriesTableTableOrderingComposer get seriesId {
    final $$SeriesTableTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.seriesId,
      referencedTable: $db.seriesTable,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SeriesTableTableOrderingComposer(
            $db: $db,
            $table: $db.seriesTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$BooksTableAnnotationComposer
    extends Composer<_$AppDatabase, $BooksTable> {
  $$BooksTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get contentKey => $composableBuilder(
    column: $table.contentKey,
    builder: (column) => column,
  );

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get number =>
      $composableBuilder(column: $table.number, builder: (column) => column);

  GeneratedColumn<int> get pageCount =>
      $composableBuilder(column: $table.pageCount, builder: (column) => column);

  GeneratedColumn<String> get format =>
      $composableBuilder(column: $table.format, builder: (column) => column);

  GeneratedColumn<DateTime> get addedAt =>
      $composableBuilder(column: $table.addedAt, builder: (column) => column);

  GeneratedColumn<String> get issueTitle => $composableBuilder(
    column: $table.issueTitle,
    builder: (column) => column,
  );

  GeneratedColumn<int> get volume =>
      $composableBuilder(column: $table.volume, builder: (column) => column);

  GeneratedColumn<int> get year =>
      $composableBuilder(column: $table.year, builder: (column) => column);

  GeneratedColumn<String> get writers =>
      $composableBuilder(column: $table.writers, builder: (column) => column);

  GeneratedColumn<String> get artists =>
      $composableBuilder(column: $table.artists, builder: (column) => column);

  GeneratedColumn<String> get summary =>
      $composableBuilder(column: $table.summary, builder: (column) => column);

  $$SeriesTableTableAnnotationComposer get seriesId {
    final $$SeriesTableTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.seriesId,
      referencedTable: $db.seriesTable,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SeriesTableTableAnnotationComposer(
            $db: $db,
            $table: $db.seriesTable,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  Expression<T> filesRefs<T extends Object>(
    Expression<T> Function($$FilesTableAnnotationComposer a) f,
  ) {
    final $$FilesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.contentKey,
      referencedTable: $db.files,
      getReferencedColumn: (t) => t.contentKey,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$FilesTableAnnotationComposer(
            $db: $db,
            $table: $db.files,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$BooksTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $BooksTable,
          Book,
          $$BooksTableFilterComposer,
          $$BooksTableOrderingComposer,
          $$BooksTableAnnotationComposer,
          $$BooksTableCreateCompanionBuilder,
          $$BooksTableUpdateCompanionBuilder,
          (Book, $$BooksTableReferences),
          Book,
          PrefetchHooks Function({bool seriesId, bool filesRefs})
        > {
  $$BooksTableTableManager(_$AppDatabase db, $BooksTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$BooksTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$BooksTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$BooksTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> contentKey = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<int?> seriesId = const Value.absent(),
                Value<String?> number = const Value.absent(),
                Value<int> pageCount = const Value.absent(),
                Value<String> format = const Value.absent(),
                Value<DateTime> addedAt = const Value.absent(),
                Value<String?> issueTitle = const Value.absent(),
                Value<int?> volume = const Value.absent(),
                Value<int?> year = const Value.absent(),
                Value<String?> writers = const Value.absent(),
                Value<String?> artists = const Value.absent(),
                Value<String?> summary = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => BooksCompanion(
                contentKey: contentKey,
                title: title,
                seriesId: seriesId,
                number: number,
                pageCount: pageCount,
                format: format,
                addedAt: addedAt,
                issueTitle: issueTitle,
                volume: volume,
                year: year,
                writers: writers,
                artists: artists,
                summary: summary,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String contentKey,
                required String title,
                Value<int?> seriesId = const Value.absent(),
                Value<String?> number = const Value.absent(),
                required int pageCount,
                required String format,
                Value<DateTime> addedAt = const Value.absent(),
                Value<String?> issueTitle = const Value.absent(),
                Value<int?> volume = const Value.absent(),
                Value<int?> year = const Value.absent(),
                Value<String?> writers = const Value.absent(),
                Value<String?> artists = const Value.absent(),
                Value<String?> summary = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => BooksCompanion.insert(
                contentKey: contentKey,
                title: title,
                seriesId: seriesId,
                number: number,
                pageCount: pageCount,
                format: format,
                addedAt: addedAt,
                issueTitle: issueTitle,
                volume: volume,
                year: year,
                writers: writers,
                artists: artists,
                summary: summary,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$BooksTable, Book>(table),
                  $$BooksTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({seriesId = false, filesRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [if (filesRefs) db.files],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (seriesId) {
                      state = state.withJoin(
                        currentTable: table,
                        currentColumn: table.seriesId,
                        referencedTable: $$BooksTableReferences._seriesIdTable(
                          db,
                        ),
                        referencedColumn: $$BooksTableReferences
                            ._seriesIdTable(db)
                            .id,
                      ) as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [
                  if (filesRefs)
                    await $_getPrefetchedData<Book, $BooksTable, BookFile>(
                      currentTable: table,
                      referencedTable: $$BooksTableReferences._filesRefsTable(
                        db,
                      ),
                      managerFromTypedResult: (p0) =>
                          $$BooksTableReferences(db, table, p0).filesRefs,
                      referencedItemsForCurrentItem: (item, referencedItems) =>
                          referencedItems.where(
                            (e) => e.contentKey == item.contentKey,
                          ),
                      typedResults: items,
                    ),
                ];
              },
            );
          },
        ),
      );
}

typedef $$BooksTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $BooksTable,
      Book,
      $$BooksTableFilterComposer,
      $$BooksTableOrderingComposer,
      $$BooksTableAnnotationComposer,
      $$BooksTableCreateCompanionBuilder,
      $$BooksTableUpdateCompanionBuilder,
      (Book, $$BooksTableReferences),
      Book,
      PrefetchHooks Function({bool seriesId, bool filesRefs})
    >;
typedef $$RootsTableCreateCompanionBuilder = RootsCompanion Function({
  Value<int> id,
  required String path,
  Value<DateTime> addedAt,
});
typedef $$RootsTableUpdateCompanionBuilder = RootsCompanion Function({
  Value<int> id,
  Value<String> path,
  Value<DateTime> addedAt,
});

class $$RootsTableFilterComposer extends Composer<_$AppDatabase, $RootsTable> {
  $$RootsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get path => $composableBuilder(
    column: $table.path,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get addedAt => $composableBuilder(
    column: $table.addedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$RootsTableOrderingComposer
    extends Composer<_$AppDatabase, $RootsTable> {
  $$RootsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get path => $composableBuilder(
    column: $table.path,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get addedAt => $composableBuilder(
    column: $table.addedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$RootsTableAnnotationComposer
    extends Composer<_$AppDatabase, $RootsTable> {
  $$RootsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get path =>
      $composableBuilder(column: $table.path, builder: (column) => column);

  GeneratedColumn<DateTime> get addedAt =>
      $composableBuilder(column: $table.addedAt, builder: (column) => column);
}

class $$RootsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $RootsTable,
          LibraryRoot,
          $$RootsTableFilterComposer,
          $$RootsTableOrderingComposer,
          $$RootsTableAnnotationComposer,
          $$RootsTableCreateCompanionBuilder,
          $$RootsTableUpdateCompanionBuilder,
          (
            LibraryRoot,
            BaseReferences<_$AppDatabase, $RootsTable, LibraryRoot>,
          ),
          LibraryRoot,
          PrefetchHooks Function()
        > {
  $$RootsTableTableManager(_$AppDatabase db, $RootsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$RootsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$RootsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$RootsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> path = const Value.absent(),
            Value<DateTime> addedAt = const Value.absent(),
          }) => RootsCompanion(id: id, path: path, addedAt: addedAt),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required String path,
            Value<DateTime> addedAt = const Value.absent(),
          }) => RootsCompanion.insert(id: id, path: path, addedAt: addedAt),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$RootsTable, LibraryRoot>(table),
                  BaseReferences<_$AppDatabase, $RootsTable, LibraryRoot>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$RootsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $RootsTable,
      LibraryRoot,
      $$RootsTableFilterComposer,
      $$RootsTableOrderingComposer,
      $$RootsTableAnnotationComposer,
      $$RootsTableCreateCompanionBuilder,
      $$RootsTableUpdateCompanionBuilder,
      (LibraryRoot, BaseReferences<_$AppDatabase, $RootsTable, LibraryRoot>),
      LibraryRoot,
      PrefetchHooks Function()
    >;
typedef $$FilesTableCreateCompanionBuilder = FilesCompanion Function({
  required String contentKey,
  required int rootId,
  required String relPath,
  required int size,
  required DateTime mtime,
  Value<int> rowid,
});
typedef $$FilesTableUpdateCompanionBuilder = FilesCompanion Function({
  Value<String> contentKey,
  Value<int> rootId,
  Value<String> relPath,
  Value<int> size,
  Value<DateTime> mtime,
  Value<int> rowid,
});

final class $$FilesTableReferences
    extends BaseReferences<_$AppDatabase, $FilesTable, BookFile> {
  $$FilesTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $BooksTable _contentKeyTable(_$AppDatabase db) =>
      db.books.createAlias('files__content_key__books__content_key');

  $$BooksTableProcessedTableManager get contentKey {
    final $_column = $_itemColumn<String>('content_key')!;

    final manager = $$BooksTableTableManager(
      $_db,
      $_db.books,
    ).filter((f) => f.contentKey.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_contentKeyTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$FilesTableFilterComposer extends Composer<_$AppDatabase, $FilesTable> {
  $$FilesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get rootId => $composableBuilder(
    column: $table.rootId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get relPath => $composableBuilder(
    column: $table.relPath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get size => $composableBuilder(
    column: $table.size,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get mtime => $composableBuilder(
    column: $table.mtime,
    builder: (column) => ColumnFilters(column),
  );

  $$BooksTableFilterComposer get contentKey {
    final $$BooksTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.contentKey,
      referencedTable: $db.books,
      getReferencedColumn: (t) => t.contentKey,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$BooksTableFilterComposer(
            $db: $db,
            $table: $db.books,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$FilesTableOrderingComposer
    extends Composer<_$AppDatabase, $FilesTable> {
  $$FilesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get rootId => $composableBuilder(
    column: $table.rootId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get relPath => $composableBuilder(
    column: $table.relPath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get size => $composableBuilder(
    column: $table.size,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get mtime => $composableBuilder(
    column: $table.mtime,
    builder: (column) => ColumnOrderings(column),
  );

  $$BooksTableOrderingComposer get contentKey {
    final $$BooksTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.contentKey,
      referencedTable: $db.books,
      getReferencedColumn: (t) => t.contentKey,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$BooksTableOrderingComposer(
            $db: $db,
            $table: $db.books,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$FilesTableAnnotationComposer
    extends Composer<_$AppDatabase, $FilesTable> {
  $$FilesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get rootId =>
      $composableBuilder(column: $table.rootId, builder: (column) => column);

  GeneratedColumn<String> get relPath =>
      $composableBuilder(column: $table.relPath, builder: (column) => column);

  GeneratedColumn<int> get size =>
      $composableBuilder(column: $table.size, builder: (column) => column);

  GeneratedColumn<DateTime> get mtime =>
      $composableBuilder(column: $table.mtime, builder: (column) => column);

  $$BooksTableAnnotationComposer get contentKey {
    final $$BooksTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.contentKey,
      referencedTable: $db.books,
      getReferencedColumn: (t) => t.contentKey,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$BooksTableAnnotationComposer(
            $db: $db,
            $table: $db.books,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$FilesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $FilesTable,
          BookFile,
          $$FilesTableFilterComposer,
          $$FilesTableOrderingComposer,
          $$FilesTableAnnotationComposer,
          $$FilesTableCreateCompanionBuilder,
          $$FilesTableUpdateCompanionBuilder,
          (BookFile, $$FilesTableReferences),
          BookFile,
          PrefetchHooks Function({bool contentKey})
        > {
  $$FilesTableTableManager(_$AppDatabase db, $FilesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$FilesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$FilesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$FilesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> contentKey = const Value.absent(),
                Value<int> rootId = const Value.absent(),
                Value<String> relPath = const Value.absent(),
                Value<int> size = const Value.absent(),
                Value<DateTime> mtime = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => FilesCompanion(
                contentKey: contentKey,
                rootId: rootId,
                relPath: relPath,
                size: size,
                mtime: mtime,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String contentKey,
                required int rootId,
                required String relPath,
                required int size,
                required DateTime mtime,
                Value<int> rowid = const Value.absent(),
              }) => FilesCompanion.insert(
                contentKey: contentKey,
                rootId: rootId,
                relPath: relPath,
                size: size,
                mtime: mtime,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$FilesTable, BookFile>(table),
                  $$FilesTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({contentKey = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (contentKey) {
                      state = state.withJoin(
                        currentTable: table,
                        currentColumn: table.contentKey,
                        referencedTable: $$FilesTableReferences
                            ._contentKeyTable(db),
                        referencedColumn: $$FilesTableReferences
                            ._contentKeyTable(db)
                            .contentKey,
                      ) as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$FilesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $FilesTable,
      BookFile,
      $$FilesTableFilterComposer,
      $$FilesTableOrderingComposer,
      $$FilesTableAnnotationComposer,
      $$FilesTableCreateCompanionBuilder,
      $$FilesTableUpdateCompanionBuilder,
      (BookFile, $$FilesTableReferences),
      BookFile,
      PrefetchHooks Function({bool contentKey})
    >;
typedef $$ProgressTableCreateCompanionBuilder = ProgressCompanion Function({
  required String contentKey,
  required int page,
  Value<int?> panel,
  required double percent,
  Value<bool> finished,
  required DateTime updatedAt,
  Value<String?> viewJson,
  Value<int> rowid,
});
typedef $$ProgressTableUpdateCompanionBuilder = ProgressCompanion Function({
  Value<String> contentKey,
  Value<int> page,
  Value<int?> panel,
  Value<double> percent,
  Value<bool> finished,
  Value<DateTime> updatedAt,
  Value<String?> viewJson,
  Value<int> rowid,
});

class $$ProgressTableFilterComposer
    extends Composer<_$AppDatabase, $ProgressTable> {
  $$ProgressTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get contentKey => $composableBuilder(
    column: $table.contentKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get page => $composableBuilder(
    column: $table.page,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get panel => $composableBuilder(
    column: $table.panel,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get percent => $composableBuilder(
    column: $table.percent,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get finished => $composableBuilder(
    column: $table.finished,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get viewJson => $composableBuilder(
    column: $table.viewJson,
    builder: (column) => ColumnFilters(column),
  );
}

class $$ProgressTableOrderingComposer
    extends Composer<_$AppDatabase, $ProgressTable> {
  $$ProgressTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get contentKey => $composableBuilder(
    column: $table.contentKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get page => $composableBuilder(
    column: $table.page,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get panel => $composableBuilder(
    column: $table.panel,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get percent => $composableBuilder(
    column: $table.percent,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get finished => $composableBuilder(
    column: $table.finished,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get viewJson => $composableBuilder(
    column: $table.viewJson,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ProgressTableAnnotationComposer
    extends Composer<_$AppDatabase, $ProgressTable> {
  $$ProgressTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get contentKey => $composableBuilder(
    column: $table.contentKey,
    builder: (column) => column,
  );

  GeneratedColumn<int> get page =>
      $composableBuilder(column: $table.page, builder: (column) => column);

  GeneratedColumn<int> get panel =>
      $composableBuilder(column: $table.panel, builder: (column) => column);

  GeneratedColumn<double> get percent =>
      $composableBuilder(column: $table.percent, builder: (column) => column);

  GeneratedColumn<bool> get finished =>
      $composableBuilder(column: $table.finished, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<String> get viewJson =>
      $composableBuilder(column: $table.viewJson, builder: (column) => column);
}

class $$ProgressTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ProgressTable,
          ProgressData,
          $$ProgressTableFilterComposer,
          $$ProgressTableOrderingComposer,
          $$ProgressTableAnnotationComposer,
          $$ProgressTableCreateCompanionBuilder,
          $$ProgressTableUpdateCompanionBuilder,
          (
            ProgressData,
            BaseReferences<_$AppDatabase, $ProgressTable, ProgressData>,
          ),
          ProgressData,
          PrefetchHooks Function()
        > {
  $$ProgressTableTableManager(_$AppDatabase db, $ProgressTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ProgressTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ProgressTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ProgressTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> contentKey = const Value.absent(),
                Value<int> page = const Value.absent(),
                Value<int?> panel = const Value.absent(),
                Value<double> percent = const Value.absent(),
                Value<bool> finished = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<String?> viewJson = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ProgressCompanion(
                contentKey: contentKey,
                page: page,
                panel: panel,
                percent: percent,
                finished: finished,
                updatedAt: updatedAt,
                viewJson: viewJson,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String contentKey,
                required int page,
                Value<int?> panel = const Value.absent(),
                required double percent,
                Value<bool> finished = const Value.absent(),
                required DateTime updatedAt,
                Value<String?> viewJson = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ProgressCompanion.insert(
                contentKey: contentKey,
                page: page,
                panel: panel,
                percent: percent,
                finished: finished,
                updatedAt: updatedAt,
                viewJson: viewJson,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$ProgressTable, ProgressData>(table),
                  BaseReferences<_$AppDatabase, $ProgressTable, ProgressData>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ProgressTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ProgressTable,
      ProgressData,
      $$ProgressTableFilterComposer,
      $$ProgressTableOrderingComposer,
      $$ProgressTableAnnotationComposer,
      $$ProgressTableCreateCompanionBuilder,
      $$ProgressTableUpdateCompanionBuilder,
      (
        ProgressData,
        BaseReferences<_$AppDatabase, $ProgressTable, ProgressData>,
      ),
      ProgressData,
      PrefetchHooks Function()
    >;
typedef $$BookmarksTableCreateCompanionBuilder = BookmarksCompanion Function({
  required String id,
  required String contentKey,
  required int page,
  Value<int?> panel,
  Value<String?> mark,
  Value<String?> note,
  required DateTime createdAt,
  Value<DateTime?> deletedAt,
  Value<int> rowid,
});
typedef $$BookmarksTableUpdateCompanionBuilder = BookmarksCompanion Function({
  Value<String> id,
  Value<String> contentKey,
  Value<int> page,
  Value<int?> panel,
  Value<String?> mark,
  Value<String?> note,
  Value<DateTime> createdAt,
  Value<DateTime?> deletedAt,
  Value<int> rowid,
});

class $$BookmarksTableFilterComposer
    extends Composer<_$AppDatabase, $BookmarksTable> {
  $$BookmarksTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get contentKey => $composableBuilder(
    column: $table.contentKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get page => $composableBuilder(
    column: $table.page,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get panel => $composableBuilder(
    column: $table.panel,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get mark => $composableBuilder(
    column: $table.mark,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get note => $composableBuilder(
    column: $table.note,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$BookmarksTableOrderingComposer
    extends Composer<_$AppDatabase, $BookmarksTable> {
  $$BookmarksTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get contentKey => $composableBuilder(
    column: $table.contentKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get page => $composableBuilder(
    column: $table.page,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get panel => $composableBuilder(
    column: $table.panel,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get mark => $composableBuilder(
    column: $table.mark,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get note => $composableBuilder(
    column: $table.note,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get deletedAt => $composableBuilder(
    column: $table.deletedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$BookmarksTableAnnotationComposer
    extends Composer<_$AppDatabase, $BookmarksTable> {
  $$BookmarksTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get contentKey => $composableBuilder(
    column: $table.contentKey,
    builder: (column) => column,
  );

  GeneratedColumn<int> get page =>
      $composableBuilder(column: $table.page, builder: (column) => column);

  GeneratedColumn<int> get panel =>
      $composableBuilder(column: $table.panel, builder: (column) => column);

  GeneratedColumn<String> get mark =>
      $composableBuilder(column: $table.mark, builder: (column) => column);

  GeneratedColumn<String> get note =>
      $composableBuilder(column: $table.note, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get deletedAt =>
      $composableBuilder(column: $table.deletedAt, builder: (column) => column);
}

class $$BookmarksTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $BookmarksTable,
          Bookmark,
          $$BookmarksTableFilterComposer,
          $$BookmarksTableOrderingComposer,
          $$BookmarksTableAnnotationComposer,
          $$BookmarksTableCreateCompanionBuilder,
          $$BookmarksTableUpdateCompanionBuilder,
          (Bookmark, BaseReferences<_$AppDatabase, $BookmarksTable, Bookmark>),
          Bookmark,
          PrefetchHooks Function()
        > {
  $$BookmarksTableTableManager(_$AppDatabase db, $BookmarksTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$BookmarksTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$BookmarksTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$BookmarksTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> contentKey = const Value.absent(),
                Value<int> page = const Value.absent(),
                Value<int?> panel = const Value.absent(),
                Value<String?> mark = const Value.absent(),
                Value<String?> note = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<DateTime?> deletedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => BookmarksCompanion(
                id: id,
                contentKey: contentKey,
                page: page,
                panel: panel,
                mark: mark,
                note: note,
                createdAt: createdAt,
                deletedAt: deletedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String contentKey,
                required int page,
                Value<int?> panel = const Value.absent(),
                Value<String?> mark = const Value.absent(),
                Value<String?> note = const Value.absent(),
                required DateTime createdAt,
                Value<DateTime?> deletedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => BookmarksCompanion.insert(
                id: id,
                contentKey: contentKey,
                page: page,
                panel: panel,
                mark: mark,
                note: note,
                createdAt: createdAt,
                deletedAt: deletedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$BookmarksTable, Bookmark>(table),
                  BaseReferences<_$AppDatabase, $BookmarksTable, Bookmark>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$BookmarksTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $BookmarksTable,
      Bookmark,
      $$BookmarksTableFilterComposer,
      $$BookmarksTableOrderingComposer,
      $$BookmarksTableAnnotationComposer,
      $$BookmarksTableCreateCompanionBuilder,
      $$BookmarksTableUpdateCompanionBuilder,
      (Bookmark, BaseReferences<_$AppDatabase, $BookmarksTable, Bookmark>),
      Bookmark,
      PrefetchHooks Function()
    >;
typedef $$PanelsTableCreateCompanionBuilder = PanelsCompanion Function({
  required String contentKey,
  required int page,
  required int idx,
  required double x,
  required double y,
  required double w,
  required double h,
  required String kind,
  required String source,
  required int modelVer,
  required double confidence,
  Value<String?> shape,
  Value<int> rowid,
});
typedef $$PanelsTableUpdateCompanionBuilder = PanelsCompanion Function({
  Value<String> contentKey,
  Value<int> page,
  Value<int> idx,
  Value<double> x,
  Value<double> y,
  Value<double> w,
  Value<double> h,
  Value<String> kind,
  Value<String> source,
  Value<int> modelVer,
  Value<double> confidence,
  Value<String?> shape,
  Value<int> rowid,
});

class $$PanelsTableFilterComposer
    extends Composer<_$AppDatabase, $PanelsTable> {
  $$PanelsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get contentKey => $composableBuilder(
    column: $table.contentKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get page => $composableBuilder(
    column: $table.page,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get idx => $composableBuilder(
    column: $table.idx,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get x => $composableBuilder(
    column: $table.x,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get y => $composableBuilder(
    column: $table.y,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get w => $composableBuilder(
    column: $table.w,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get h => $composableBuilder(
    column: $table.h,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get modelVer => $composableBuilder(
    column: $table.modelVer,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get confidence => $composableBuilder(
    column: $table.confidence,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get shape => $composableBuilder(
    column: $table.shape,
    builder: (column) => ColumnFilters(column),
  );
}

class $$PanelsTableOrderingComposer
    extends Composer<_$AppDatabase, $PanelsTable> {
  $$PanelsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get contentKey => $composableBuilder(
    column: $table.contentKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get page => $composableBuilder(
    column: $table.page,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get idx => $composableBuilder(
    column: $table.idx,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get x => $composableBuilder(
    column: $table.x,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get y => $composableBuilder(
    column: $table.y,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get w => $composableBuilder(
    column: $table.w,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get h => $composableBuilder(
    column: $table.h,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get modelVer => $composableBuilder(
    column: $table.modelVer,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get confidence => $composableBuilder(
    column: $table.confidence,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get shape => $composableBuilder(
    column: $table.shape,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$PanelsTableAnnotationComposer
    extends Composer<_$AppDatabase, $PanelsTable> {
  $$PanelsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get contentKey => $composableBuilder(
    column: $table.contentKey,
    builder: (column) => column,
  );

  GeneratedColumn<int> get page =>
      $composableBuilder(column: $table.page, builder: (column) => column);

  GeneratedColumn<int> get idx =>
      $composableBuilder(column: $table.idx, builder: (column) => column);

  GeneratedColumn<double> get x =>
      $composableBuilder(column: $table.x, builder: (column) => column);

  GeneratedColumn<double> get y =>
      $composableBuilder(column: $table.y, builder: (column) => column);

  GeneratedColumn<double> get w =>
      $composableBuilder(column: $table.w, builder: (column) => column);

  GeneratedColumn<double> get h =>
      $composableBuilder(column: $table.h, builder: (column) => column);

  GeneratedColumn<String> get kind =>
      $composableBuilder(column: $table.kind, builder: (column) => column);

  GeneratedColumn<String> get source =>
      $composableBuilder(column: $table.source, builder: (column) => column);

  GeneratedColumn<int> get modelVer =>
      $composableBuilder(column: $table.modelVer, builder: (column) => column);

  GeneratedColumn<double> get confidence => $composableBuilder(
    column: $table.confidence,
    builder: (column) => column,
  );

  GeneratedColumn<String> get shape =>
      $composableBuilder(column: $table.shape, builder: (column) => column);
}

class $$PanelsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $PanelsTable,
          PanelRow,
          $$PanelsTableFilterComposer,
          $$PanelsTableOrderingComposer,
          $$PanelsTableAnnotationComposer,
          $$PanelsTableCreateCompanionBuilder,
          $$PanelsTableUpdateCompanionBuilder,
          (PanelRow, BaseReferences<_$AppDatabase, $PanelsTable, PanelRow>),
          PanelRow,
          PrefetchHooks Function()
        > {
  $$PanelsTableTableManager(_$AppDatabase db, $PanelsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$PanelsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$PanelsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$PanelsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> contentKey = const Value.absent(),
                Value<int> page = const Value.absent(),
                Value<int> idx = const Value.absent(),
                Value<double> x = const Value.absent(),
                Value<double> y = const Value.absent(),
                Value<double> w = const Value.absent(),
                Value<double> h = const Value.absent(),
                Value<String> kind = const Value.absent(),
                Value<String> source = const Value.absent(),
                Value<int> modelVer = const Value.absent(),
                Value<double> confidence = const Value.absent(),
                Value<String?> shape = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => PanelsCompanion(
                contentKey: contentKey,
                page: page,
                idx: idx,
                x: x,
                y: y,
                w: w,
                h: h,
                kind: kind,
                source: source,
                modelVer: modelVer,
                confidence: confidence,
                shape: shape,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String contentKey,
                required int page,
                required int idx,
                required double x,
                required double y,
                required double w,
                required double h,
                required String kind,
                required String source,
                required int modelVer,
                required double confidence,
                Value<String?> shape = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => PanelsCompanion.insert(
                contentKey: contentKey,
                page: page,
                idx: idx,
                x: x,
                y: y,
                w: w,
                h: h,
                kind: kind,
                source: source,
                modelVer: modelVer,
                confidence: confidence,
                shape: shape,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$PanelsTable, PanelRow>(table),
                  BaseReferences<_$AppDatabase, $PanelsTable, PanelRow>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$PanelsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $PanelsTable,
      PanelRow,
      $$PanelsTableFilterComposer,
      $$PanelsTableOrderingComposer,
      $$PanelsTableAnnotationComposer,
      $$PanelsTableCreateCompanionBuilder,
      $$PanelsTableUpdateCompanionBuilder,
      (PanelRow, BaseReferences<_$AppDatabase, $PanelsTable, PanelRow>),
      PanelRow,
      PrefetchHooks Function()
    >;
typedef $$AnalysedPagesTableCreateCompanionBuilder =
    AnalysedPagesCompanion Function({
      required String contentKey,
      required int page,
      required String source,
      required int modelVer,
      required int millis,
      required DateTime analysedAt,
      Value<int> rowid,
    });
typedef $$AnalysedPagesTableUpdateCompanionBuilder =
    AnalysedPagesCompanion Function({
      Value<String> contentKey,
      Value<int> page,
      Value<String> source,
      Value<int> modelVer,
      Value<int> millis,
      Value<DateTime> analysedAt,
      Value<int> rowid,
    });

class $$AnalysedPagesTableFilterComposer
    extends Composer<_$AppDatabase, $AnalysedPagesTable> {
  $$AnalysedPagesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get contentKey => $composableBuilder(
    column: $table.contentKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get page => $composableBuilder(
    column: $table.page,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get modelVer => $composableBuilder(
    column: $table.modelVer,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get millis => $composableBuilder(
    column: $table.millis,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get analysedAt => $composableBuilder(
    column: $table.analysedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$AnalysedPagesTableOrderingComposer
    extends Composer<_$AppDatabase, $AnalysedPagesTable> {
  $$AnalysedPagesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get contentKey => $composableBuilder(
    column: $table.contentKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get page => $composableBuilder(
    column: $table.page,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get source => $composableBuilder(
    column: $table.source,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get modelVer => $composableBuilder(
    column: $table.modelVer,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get millis => $composableBuilder(
    column: $table.millis,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get analysedAt => $composableBuilder(
    column: $table.analysedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$AnalysedPagesTableAnnotationComposer
    extends Composer<_$AppDatabase, $AnalysedPagesTable> {
  $$AnalysedPagesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get contentKey => $composableBuilder(
    column: $table.contentKey,
    builder: (column) => column,
  );

  GeneratedColumn<int> get page =>
      $composableBuilder(column: $table.page, builder: (column) => column);

  GeneratedColumn<String> get source =>
      $composableBuilder(column: $table.source, builder: (column) => column);

  GeneratedColumn<int> get modelVer =>
      $composableBuilder(column: $table.modelVer, builder: (column) => column);

  GeneratedColumn<int> get millis =>
      $composableBuilder(column: $table.millis, builder: (column) => column);

  GeneratedColumn<DateTime> get analysedAt => $composableBuilder(
    column: $table.analysedAt,
    builder: (column) => column,
  );
}

class $$AnalysedPagesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $AnalysedPagesTable,
          AnalysedPage,
          $$AnalysedPagesTableFilterComposer,
          $$AnalysedPagesTableOrderingComposer,
          $$AnalysedPagesTableAnnotationComposer,
          $$AnalysedPagesTableCreateCompanionBuilder,
          $$AnalysedPagesTableUpdateCompanionBuilder,
          (
            AnalysedPage,
            BaseReferences<_$AppDatabase, $AnalysedPagesTable, AnalysedPage>,
          ),
          AnalysedPage,
          PrefetchHooks Function()
        > {
  $$AnalysedPagesTableTableManager(_$AppDatabase db, $AnalysedPagesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AnalysedPagesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AnalysedPagesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AnalysedPagesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> contentKey = const Value.absent(),
                Value<int> page = const Value.absent(),
                Value<String> source = const Value.absent(),
                Value<int> modelVer = const Value.absent(),
                Value<int> millis = const Value.absent(),
                Value<DateTime> analysedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => AnalysedPagesCompanion(
                contentKey: contentKey,
                page: page,
                source: source,
                modelVer: modelVer,
                millis: millis,
                analysedAt: analysedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String contentKey,
                required int page,
                required String source,
                required int modelVer,
                required int millis,
                required DateTime analysedAt,
                Value<int> rowid = const Value.absent(),
              }) => AnalysedPagesCompanion.insert(
                contentKey: contentKey,
                page: page,
                source: source,
                modelVer: modelVer,
                millis: millis,
                analysedAt: analysedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$AnalysedPagesTable, AnalysedPage>(table),
                  BaseReferences<
                    _$AppDatabase,
                    $AnalysedPagesTable,
                    AnalysedPage
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$AnalysedPagesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $AnalysedPagesTable,
      AnalysedPage,
      $$AnalysedPagesTableFilterComposer,
      $$AnalysedPagesTableOrderingComposer,
      $$AnalysedPagesTableAnnotationComposer,
      $$AnalysedPagesTableCreateCompanionBuilder,
      $$AnalysedPagesTableUpdateCompanionBuilder,
      (
        AnalysedPage,
        BaseReferences<_$AppDatabase, $AnalysedPagesTable, AnalysedPage>,
      ),
      AnalysedPage,
      PrefetchHooks Function()
    >;
typedef $$OverridesTableCreateCompanionBuilder = OverridesCompanion Function({
  required String contentKey,
  required String field,
  required String value,
  Value<int> rowid,
});
typedef $$OverridesTableUpdateCompanionBuilder = OverridesCompanion Function({
  Value<String> contentKey,
  Value<String> field,
  Value<String> value,
  Value<int> rowid,
});

class $$OverridesTableFilterComposer
    extends Composer<_$AppDatabase, $OverridesTable> {
  $$OverridesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get contentKey => $composableBuilder(
    column: $table.contentKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get field => $composableBuilder(
    column: $table.field,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnFilters(column),
  );
}

class $$OverridesTableOrderingComposer
    extends Composer<_$AppDatabase, $OverridesTable> {
  $$OverridesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get contentKey => $composableBuilder(
    column: $table.contentKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get field => $composableBuilder(
    column: $table.field,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$OverridesTableAnnotationComposer
    extends Composer<_$AppDatabase, $OverridesTable> {
  $$OverridesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get contentKey => $composableBuilder(
    column: $table.contentKey,
    builder: (column) => column,
  );

  GeneratedColumn<String> get field =>
      $composableBuilder(column: $table.field, builder: (column) => column);

  GeneratedColumn<String> get value =>
      $composableBuilder(column: $table.value, builder: (column) => column);
}

class $$OverridesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $OverridesTable,
          Override,
          $$OverridesTableFilterComposer,
          $$OverridesTableOrderingComposer,
          $$OverridesTableAnnotationComposer,
          $$OverridesTableCreateCompanionBuilder,
          $$OverridesTableUpdateCompanionBuilder,
          (Override, BaseReferences<_$AppDatabase, $OverridesTable, Override>),
          Override,
          PrefetchHooks Function()
        > {
  $$OverridesTableTableManager(_$AppDatabase db, $OverridesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$OverridesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$OverridesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$OverridesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> contentKey = const Value.absent(),
                Value<String> field = const Value.absent(),
                Value<String> value = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => OverridesCompanion(
                contentKey: contentKey,
                field: field,
                value: value,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String contentKey,
                required String field,
                required String value,
                Value<int> rowid = const Value.absent(),
              }) => OverridesCompanion.insert(
                contentKey: contentKey,
                field: field,
                value: value,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$OverridesTable, Override>(table),
                  BaseReferences<_$AppDatabase, $OverridesTable, Override>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$OverridesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $OverridesTable,
      Override,
      $$OverridesTableFilterComposer,
      $$OverridesTableOrderingComposer,
      $$OverridesTableAnnotationComposer,
      $$OverridesTableCreateCompanionBuilder,
      $$OverridesTableUpdateCompanionBuilder,
      (Override, BaseReferences<_$AppDatabase, $OverridesTable, Override>),
      Override,
      PrefetchHooks Function()
    >;
typedef $$ReadLogTableCreateCompanionBuilder = ReadLogCompanion Function({
  required String contentKey,
  required DateTime startedAt,
  required DateTime endedAt,
  required int pages,
  Value<int> rowid,
});
typedef $$ReadLogTableUpdateCompanionBuilder = ReadLogCompanion Function({
  Value<String> contentKey,
  Value<DateTime> startedAt,
  Value<DateTime> endedAt,
  Value<int> pages,
  Value<int> rowid,
});

class $$ReadLogTableFilterComposer
    extends Composer<_$AppDatabase, $ReadLogTable> {
  $$ReadLogTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get contentKey => $composableBuilder(
    column: $table.contentKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get startedAt => $composableBuilder(
    column: $table.startedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get endedAt => $composableBuilder(
    column: $table.endedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get pages => $composableBuilder(
    column: $table.pages,
    builder: (column) => ColumnFilters(column),
  );
}

class $$ReadLogTableOrderingComposer
    extends Composer<_$AppDatabase, $ReadLogTable> {
  $$ReadLogTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get contentKey => $composableBuilder(
    column: $table.contentKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get startedAt => $composableBuilder(
    column: $table.startedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get endedAt => $composableBuilder(
    column: $table.endedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get pages => $composableBuilder(
    column: $table.pages,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ReadLogTableAnnotationComposer
    extends Composer<_$AppDatabase, $ReadLogTable> {
  $$ReadLogTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get contentKey => $composableBuilder(
    column: $table.contentKey,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get startedAt =>
      $composableBuilder(column: $table.startedAt, builder: (column) => column);

  GeneratedColumn<DateTime> get endedAt =>
      $composableBuilder(column: $table.endedAt, builder: (column) => column);

  GeneratedColumn<int> get pages =>
      $composableBuilder(column: $table.pages, builder: (column) => column);
}

class $$ReadLogTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ReadLogTable,
          ReadLogData,
          $$ReadLogTableFilterComposer,
          $$ReadLogTableOrderingComposer,
          $$ReadLogTableAnnotationComposer,
          $$ReadLogTableCreateCompanionBuilder,
          $$ReadLogTableUpdateCompanionBuilder,
          (
            ReadLogData,
            BaseReferences<_$AppDatabase, $ReadLogTable, ReadLogData>,
          ),
          ReadLogData,
          PrefetchHooks Function()
        > {
  $$ReadLogTableTableManager(_$AppDatabase db, $ReadLogTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ReadLogTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ReadLogTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ReadLogTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> contentKey = const Value.absent(),
                Value<DateTime> startedAt = const Value.absent(),
                Value<DateTime> endedAt = const Value.absent(),
                Value<int> pages = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ReadLogCompanion(
                contentKey: contentKey,
                startedAt: startedAt,
                endedAt: endedAt,
                pages: pages,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String contentKey,
                required DateTime startedAt,
                required DateTime endedAt,
                required int pages,
                Value<int> rowid = const Value.absent(),
              }) => ReadLogCompanion.insert(
                contentKey: contentKey,
                startedAt: startedAt,
                endedAt: endedAt,
                pages: pages,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$ReadLogTable, ReadLogData>(table),
                  BaseReferences<_$AppDatabase, $ReadLogTable, ReadLogData>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ReadLogTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ReadLogTable,
      ReadLogData,
      $$ReadLogTableFilterComposer,
      $$ReadLogTableOrderingComposer,
      $$ReadLogTableAnnotationComposer,
      $$ReadLogTableCreateCompanionBuilder,
      $$ReadLogTableUpdateCompanionBuilder,
      (ReadLogData, BaseReferences<_$AppDatabase, $ReadLogTable, ReadLogData>),
      ReadLogData,
      PrefetchHooks Function()
    >;
typedef $$SettingsTableCreateCompanionBuilder = SettingsCompanion Function({
  required String key,
  required String value,
  Value<int> rowid,
});
typedef $$SettingsTableUpdateCompanionBuilder = SettingsCompanion Function({
  Value<String> key,
  Value<String> value,
  Value<int> rowid,
});

class $$SettingsTableFilterComposer
    extends Composer<_$AppDatabase, $SettingsTable> {
  $$SettingsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SettingsTableOrderingComposer
    extends Composer<_$AppDatabase, $SettingsTable> {
  $$SettingsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SettingsTableAnnotationComposer
    extends Composer<_$AppDatabase, $SettingsTable> {
  $$SettingsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get value =>
      $composableBuilder(column: $table.value, builder: (column) => column);
}

class $$SettingsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $SettingsTable,
          SettingRow,
          $$SettingsTableFilterComposer,
          $$SettingsTableOrderingComposer,
          $$SettingsTableAnnotationComposer,
          $$SettingsTableCreateCompanionBuilder,
          $$SettingsTableUpdateCompanionBuilder,
          (
            SettingRow,
            BaseReferences<_$AppDatabase, $SettingsTable, SettingRow>,
          ),
          SettingRow,
          PrefetchHooks Function()
        > {
  $$SettingsTableTableManager(_$AppDatabase db, $SettingsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SettingsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SettingsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SettingsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> key = const Value.absent(),
            Value<String> value = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) => SettingsCompanion(key: key, value: value, rowid: rowid),
          createCompanionCallback: ({
            required String key,
            required String value,
            Value<int> rowid = const Value.absent(),
          }) => SettingsCompanion.insert(key: key, value: value, rowid: rowid),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$SettingsTable, SettingRow>(table),
                  BaseReferences<_$AppDatabase, $SettingsTable, SettingRow>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SettingsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $SettingsTable,
      SettingRow,
      $$SettingsTableFilterComposer,
      $$SettingsTableOrderingComposer,
      $$SettingsTableAnnotationComposer,
      $$SettingsTableCreateCompanionBuilder,
      $$SettingsTableUpdateCompanionBuilder,
      (SettingRow, BaseReferences<_$AppDatabase, $SettingsTable, SettingRow>),
      SettingRow,
      PrefetchHooks Function()
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$SeriesTableTableTableManager get seriesTable =>
      $$SeriesTableTableTableManager(_db, _db.seriesTable);
  $$BooksTableTableManager get books =>
      $$BooksTableTableManager(_db, _db.books);
  $$RootsTableTableManager get roots =>
      $$RootsTableTableManager(_db, _db.roots);
  $$FilesTableTableManager get files =>
      $$FilesTableTableManager(_db, _db.files);
  $$ProgressTableTableManager get progress =>
      $$ProgressTableTableManager(_db, _db.progress);
  $$BookmarksTableTableManager get bookmarks =>
      $$BookmarksTableTableManager(_db, _db.bookmarks);
  $$PanelsTableTableManager get panels =>
      $$PanelsTableTableManager(_db, _db.panels);
  $$AnalysedPagesTableTableManager get analysedPages =>
      $$AnalysedPagesTableTableManager(_db, _db.analysedPages);
  $$OverridesTableTableManager get overrides =>
      $$OverridesTableTableManager(_db, _db.overrides);
  $$ReadLogTableTableManager get readLog =>
      $$ReadLogTableTableManager(_db, _db.readLog);
  $$SettingsTableTableManager get settings =>
      $$SettingsTableTableManager(_db, _db.settings);
}
