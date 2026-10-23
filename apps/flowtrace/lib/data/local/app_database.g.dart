// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_database.dart';

// ignore_for_file: type=lint
class $AppSettingsTable extends AppSettings
    with TableInfo<$AppSettingsTable, AppSetting> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AppSettingsTable(this.attachedDatabase, [this._alias]);
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
  static const String $name = 'app_settings';
  @override
  VerificationContext validateIntegrity(
    Insertable<AppSetting> instance, {
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
  AppSetting map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AppSetting(
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
  $AppSettingsTable createAlias(String alias) {
    return $AppSettingsTable(attachedDatabase, alias);
  }
}

class AppSetting extends DataClass implements Insertable<AppSetting> {
  final String key;
  final String value;
  const AppSetting({required this.key, required this.value});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    map['value'] = Variable<String>(value);
    return map;
  }

  AppSettingsCompanion toCompanion(bool nullToAbsent) {
    return AppSettingsCompanion(key: Value(key), value: Value(value));
  }

  factory AppSetting.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return AppSetting(
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

  AppSetting copyWith({String? key, String? value}) =>
      AppSetting(key: key ?? this.key, value: value ?? this.value);
  AppSetting copyWithCompanion(AppSettingsCompanion data) {
    return AppSetting(
      key: data.key.present ? data.key.value : this.key,
      value: data.value.present ? data.value.value : this.value,
    );
  }

  @override
  String toString() {
    return (StringBuffer('AppSetting(')
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
      (other is AppSetting &&
          other.key == this.key &&
          other.value == this.value);
}

class AppSettingsCompanion extends UpdateCompanion<AppSetting> {
  final Value<String> key;
  final Value<String> value;
  final Value<int> rowid;
  const AppSettingsCompanion({
    this.key = const Value.absent(),
    this.value = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  AppSettingsCompanion.insert({
    required String key,
    required String value,
    this.rowid = const Value.absent(),
  }) : key = Value(key),
       value = Value(value);
  static Insertable<AppSetting> custom({
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

  AppSettingsCompanion copyWith({
    Value<String>? key,
    Value<String>? value,
    Value<int>? rowid,
  }) {
    return AppSettingsCompanion(
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
    return (StringBuffer('AppSettingsCompanion(')
          ..write('key: $key, ')
          ..write('value: $value, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $LocalSpacesTable extends LocalSpaces
    with TableInfo<$LocalSpacesTable, StoredSpace> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalSpacesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _serverAddressMeta = const VerificationMeta(
    'serverAddress',
  );
  @override
  late final GeneratedColumn<String> serverAddress = GeneratedColumn<String>(
    'server_address',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _serverInstanceIdMeta = const VerificationMeta(
    'serverInstanceId',
  );
  @override
  late final GeneratedColumn<String> serverInstanceId = GeneratedColumn<String>(
    'server_instance_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _userIdMeta = const VerificationMeta('userId');
  @override
  late final GeneratedColumn<String> userId = GeneratedColumn<String>(
    'user_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
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
  @override
  List<GeneratedColumn> get $columns => [
    id,
    serverAddress,
    serverInstanceId,
    userId,
    createdAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'local_spaces';
  @override
  VerificationContext validateIntegrity(
    Insertable<StoredSpace> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('server_address')) {
      context.handle(
        _serverAddressMeta,
        serverAddress.isAcceptableOrUnknown(
          data['server_address']!,
          _serverAddressMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_serverAddressMeta);
    }
    if (data.containsKey('server_instance_id')) {
      context.handle(
        _serverInstanceIdMeta,
        serverInstanceId.isAcceptableOrUnknown(
          data['server_instance_id']!,
          _serverInstanceIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_serverInstanceIdMeta);
    }
    if (data.containsKey('user_id')) {
      context.handle(
        _userIdMeta,
        userId.isAcceptableOrUnknown(data['user_id']!, _userIdMeta),
      );
    } else if (isInserting) {
      context.missing(_userIdMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  StoredSpace map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return StoredSpace(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      serverAddress: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}server_address'],
      )!,
      serverInstanceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}server_instance_id'],
      )!,
      userId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}user_id'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
    );
  }

  @override
  $LocalSpacesTable createAlias(String alias) {
    return $LocalSpacesTable(attachedDatabase, alias);
  }
}

class StoredSpace extends DataClass implements Insertable<StoredSpace> {
  final String id;
  final String serverAddress;
  final String serverInstanceId;
  final String userId;
  final DateTime createdAt;
  const StoredSpace({
    required this.id,
    required this.serverAddress,
    required this.serverInstanceId,
    required this.userId,
    required this.createdAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['server_address'] = Variable<String>(serverAddress);
    map['server_instance_id'] = Variable<String>(serverInstanceId);
    map['user_id'] = Variable<String>(userId);
    map['created_at'] = Variable<DateTime>(createdAt);
    return map;
  }

  LocalSpacesCompanion toCompanion(bool nullToAbsent) {
    return LocalSpacesCompanion(
      id: Value(id),
      serverAddress: Value(serverAddress),
      serverInstanceId: Value(serverInstanceId),
      userId: Value(userId),
      createdAt: Value(createdAt),
    );
  }

  factory StoredSpace.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return StoredSpace(
      id: serializer.fromJson<String>(json['id']),
      serverAddress: serializer.fromJson<String>(json['serverAddress']),
      serverInstanceId: serializer.fromJson<String>(json['serverInstanceId']),
      userId: serializer.fromJson<String>(json['userId']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'serverAddress': serializer.toJson<String>(serverAddress),
      'serverInstanceId': serializer.toJson<String>(serverInstanceId),
      'userId': serializer.toJson<String>(userId),
      'createdAt': serializer.toJson<DateTime>(createdAt),
    };
  }

  StoredSpace copyWith({
    String? id,
    String? serverAddress,
    String? serverInstanceId,
    String? userId,
    DateTime? createdAt,
  }) => StoredSpace(
    id: id ?? this.id,
    serverAddress: serverAddress ?? this.serverAddress,
    serverInstanceId: serverInstanceId ?? this.serverInstanceId,
    userId: userId ?? this.userId,
    createdAt: createdAt ?? this.createdAt,
  );
  StoredSpace copyWithCompanion(LocalSpacesCompanion data) {
    return StoredSpace(
      id: data.id.present ? data.id.value : this.id,
      serverAddress: data.serverAddress.present
          ? data.serverAddress.value
          : this.serverAddress,
      serverInstanceId: data.serverInstanceId.present
          ? data.serverInstanceId.value
          : this.serverInstanceId,
      userId: data.userId.present ? data.userId.value : this.userId,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('StoredSpace(')
          ..write('id: $id, ')
          ..write('serverAddress: $serverAddress, ')
          ..write('serverInstanceId: $serverInstanceId, ')
          ..write('userId: $userId, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, serverAddress, serverInstanceId, userId, createdAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is StoredSpace &&
          other.id == this.id &&
          other.serverAddress == this.serverAddress &&
          other.serverInstanceId == this.serverInstanceId &&
          other.userId == this.userId &&
          other.createdAt == this.createdAt);
}

class LocalSpacesCompanion extends UpdateCompanion<StoredSpace> {
  final Value<String> id;
  final Value<String> serverAddress;
  final Value<String> serverInstanceId;
  final Value<String> userId;
  final Value<DateTime> createdAt;
  final Value<int> rowid;
  const LocalSpacesCompanion({
    this.id = const Value.absent(),
    this.serverAddress = const Value.absent(),
    this.serverInstanceId = const Value.absent(),
    this.userId = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LocalSpacesCompanion.insert({
    required String id,
    required String serverAddress,
    required String serverInstanceId,
    required String userId,
    required DateTime createdAt,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       serverAddress = Value(serverAddress),
       serverInstanceId = Value(serverInstanceId),
       userId = Value(userId),
       createdAt = Value(createdAt);
  static Insertable<StoredSpace> custom({
    Expression<String>? id,
    Expression<String>? serverAddress,
    Expression<String>? serverInstanceId,
    Expression<String>? userId,
    Expression<DateTime>? createdAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (serverAddress != null) 'server_address': serverAddress,
      if (serverInstanceId != null) 'server_instance_id': serverInstanceId,
      if (userId != null) 'user_id': userId,
      if (createdAt != null) 'created_at': createdAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LocalSpacesCompanion copyWith({
    Value<String>? id,
    Value<String>? serverAddress,
    Value<String>? serverInstanceId,
    Value<String>? userId,
    Value<DateTime>? createdAt,
    Value<int>? rowid,
  }) {
    return LocalSpacesCompanion(
      id: id ?? this.id,
      serverAddress: serverAddress ?? this.serverAddress,
      serverInstanceId: serverInstanceId ?? this.serverInstanceId,
      userId: userId ?? this.userId,
      createdAt: createdAt ?? this.createdAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (serverAddress.present) {
      map['server_address'] = Variable<String>(serverAddress.value);
    }
    if (serverInstanceId.present) {
      map['server_instance_id'] = Variable<String>(serverInstanceId.value);
    }
    if (userId.present) {
      map['user_id'] = Variable<String>(userId.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalSpacesCompanion(')
          ..write('id: $id, ')
          ..write('serverAddress: $serverAddress, ')
          ..write('serverInstanceId: $serverInstanceId, ')
          ..write('userId: $userId, ')
          ..write('createdAt: $createdAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $LocalDraftsTable extends LocalDrafts
    with TableInfo<$LocalDraftsTable, StoredDraft> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalDraftsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _spaceIdMeta = const VerificationMeta(
    'spaceId',
  );
  @override
  late final GeneratedColumn<String> spaceId = GeneratedColumn<String>(
    'space_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES local_spaces (id)',
    ),
  );
  static const VerificationMeta _bodyMeta = const VerificationMeta('body');
  @override
  late final GeneratedColumn<String> body = GeneratedColumn<String>(
    'body',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
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
  @override
  List<GeneratedColumn> get $columns => [
    id,
    spaceId,
    body,
    createdAt,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'local_drafts';
  @override
  VerificationContext validateIntegrity(
    Insertable<StoredDraft> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('space_id')) {
      context.handle(
        _spaceIdMeta,
        spaceId.isAcceptableOrUnknown(data['space_id']!, _spaceIdMeta),
      );
    } else if (isInserting) {
      context.missing(_spaceIdMeta);
    }
    if (data.containsKey('body')) {
      context.handle(
        _bodyMeta,
        body.isAcceptableOrUnknown(data['body']!, _bodyMeta),
      );
    } else if (isInserting) {
      context.missing(_bodyMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {spaceId, id};
  @override
  StoredDraft map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return StoredDraft(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      spaceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}space_id'],
      )!,
      body: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}body'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $LocalDraftsTable createAlias(String alias) {
    return $LocalDraftsTable(attachedDatabase, alias);
  }
}

class StoredDraft extends DataClass implements Insertable<StoredDraft> {
  final String id;
  final String spaceId;
  final String body;
  final DateTime createdAt;
  final DateTime updatedAt;
  const StoredDraft({
    required this.id,
    required this.spaceId,
    required this.body,
    required this.createdAt,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['space_id'] = Variable<String>(spaceId);
    map['body'] = Variable<String>(body);
    map['created_at'] = Variable<DateTime>(createdAt);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    return map;
  }

  LocalDraftsCompanion toCompanion(bool nullToAbsent) {
    return LocalDraftsCompanion(
      id: Value(id),
      spaceId: Value(spaceId),
      body: Value(body),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory StoredDraft.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return StoredDraft(
      id: serializer.fromJson<String>(json['id']),
      spaceId: serializer.fromJson<String>(json['spaceId']),
      body: serializer.fromJson<String>(json['body']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'spaceId': serializer.toJson<String>(spaceId),
      'body': serializer.toJson<String>(body),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
    };
  }

  StoredDraft copyWith({
    String? id,
    String? spaceId,
    String? body,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) => StoredDraft(
    id: id ?? this.id,
    spaceId: spaceId ?? this.spaceId,
    body: body ?? this.body,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  StoredDraft copyWithCompanion(LocalDraftsCompanion data) {
    return StoredDraft(
      id: data.id.present ? data.id.value : this.id,
      spaceId: data.spaceId.present ? data.spaceId.value : this.spaceId,
      body: data.body.present ? data.body.value : this.body,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('StoredDraft(')
          ..write('id: $id, ')
          ..write('spaceId: $spaceId, ')
          ..write('body: $body, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, spaceId, body, createdAt, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is StoredDraft &&
          other.id == this.id &&
          other.spaceId == this.spaceId &&
          other.body == this.body &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class LocalDraftsCompanion extends UpdateCompanion<StoredDraft> {
  final Value<String> id;
  final Value<String> spaceId;
  final Value<String> body;
  final Value<DateTime> createdAt;
  final Value<DateTime> updatedAt;
  final Value<int> rowid;
  const LocalDraftsCompanion({
    this.id = const Value.absent(),
    this.spaceId = const Value.absent(),
    this.body = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LocalDraftsCompanion.insert({
    required String id,
    required String spaceId,
    required String body,
    required DateTime createdAt,
    required DateTime updatedAt,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       spaceId = Value(spaceId),
       body = Value(body),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<StoredDraft> custom({
    Expression<String>? id,
    Expression<String>? spaceId,
    Expression<String>? body,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (spaceId != null) 'space_id': spaceId,
      if (body != null) 'body': body,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LocalDraftsCompanion copyWith({
    Value<String>? id,
    Value<String>? spaceId,
    Value<String>? body,
    Value<DateTime>? createdAt,
    Value<DateTime>? updatedAt,
    Value<int>? rowid,
  }) {
    return LocalDraftsCompanion(
      id: id ?? this.id,
      spaceId: spaceId ?? this.spaceId,
      body: body ?? this.body,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (spaceId.present) {
      map['space_id'] = Variable<String>(spaceId.value);
    }
    if (body.present) {
      map['body'] = Variable<String>(body.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalDraftsCompanion(')
          ..write('id: $id, ')
          ..write('spaceId: $spaceId, ')
          ..write('body: $body, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $LocalEntitiesTable extends LocalEntities
    with TableInfo<$LocalEntitiesTable, StoredEntity> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalEntitiesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _spaceIdMeta = const VerificationMeta(
    'spaceId',
  );
  @override
  late final GeneratedColumn<String> spaceId = GeneratedColumn<String>(
    'space_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES local_spaces (id)',
    ),
  );
  static const VerificationMeta _scopeIdMeta = const VerificationMeta(
    'scopeId',
  );
  @override
  late final GeneratedColumn<String> scopeId = GeneratedColumn<String>(
    'scope_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _entityTypeMeta = const VerificationMeta(
    'entityType',
  );
  @override
  late final GeneratedColumn<String> entityType = GeneratedColumn<String>(
    'entity_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _entityIdMeta = const VerificationMeta(
    'entityId',
  );
  @override
  late final GeneratedColumn<String> entityId = GeneratedColumn<String>(
    'entity_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _dataJsonMeta = const VerificationMeta(
    'dataJson',
  );
  @override
  late final GeneratedColumn<String> dataJson = GeneratedColumn<String>(
    'data_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _serverRevisionMeta = const VerificationMeta(
    'serverRevision',
  );
  @override
  late final GeneratedColumn<String> serverRevision = GeneratedColumn<String>(
    'server_revision',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('0'),
  );
  static const VerificationMeta _deletedMeta = const VerificationMeta(
    'deleted',
  );
  @override
  late final GeneratedColumn<bool> deleted = GeneratedColumn<bool>(
    'deleted',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("deleted" IN (0, 1))',
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
  @override
  List<GeneratedColumn> get $columns => [
    spaceId,
    scopeId,
    entityType,
    entityId,
    dataJson,
    serverRevision,
    deleted,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'local_entities';
  @override
  VerificationContext validateIntegrity(
    Insertable<StoredEntity> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('space_id')) {
      context.handle(
        _spaceIdMeta,
        spaceId.isAcceptableOrUnknown(data['space_id']!, _spaceIdMeta),
      );
    } else if (isInserting) {
      context.missing(_spaceIdMeta);
    }
    if (data.containsKey('scope_id')) {
      context.handle(
        _scopeIdMeta,
        scopeId.isAcceptableOrUnknown(data['scope_id']!, _scopeIdMeta),
      );
    }
    if (data.containsKey('entity_type')) {
      context.handle(
        _entityTypeMeta,
        entityType.isAcceptableOrUnknown(data['entity_type']!, _entityTypeMeta),
      );
    } else if (isInserting) {
      context.missing(_entityTypeMeta);
    }
    if (data.containsKey('entity_id')) {
      context.handle(
        _entityIdMeta,
        entityId.isAcceptableOrUnknown(data['entity_id']!, _entityIdMeta),
      );
    } else if (isInserting) {
      context.missing(_entityIdMeta);
    }
    if (data.containsKey('data_json')) {
      context.handle(
        _dataJsonMeta,
        dataJson.isAcceptableOrUnknown(data['data_json']!, _dataJsonMeta),
      );
    } else if (isInserting) {
      context.missing(_dataJsonMeta);
    }
    if (data.containsKey('server_revision')) {
      context.handle(
        _serverRevisionMeta,
        serverRevision.isAcceptableOrUnknown(
          data['server_revision']!,
          _serverRevisionMeta,
        ),
      );
    }
    if (data.containsKey('deleted')) {
      context.handle(
        _deletedMeta,
        deleted.isAcceptableOrUnknown(data['deleted']!, _deletedMeta),
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
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {spaceId, entityType, entityId};
  @override
  StoredEntity map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return StoredEntity(
      spaceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}space_id'],
      )!,
      scopeId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}scope_id'],
      )!,
      entityType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}entity_type'],
      )!,
      entityId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}entity_id'],
      )!,
      dataJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}data_json'],
      )!,
      serverRevision: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}server_revision'],
      )!,
      deleted: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}deleted'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $LocalEntitiesTable createAlias(String alias) {
    return $LocalEntitiesTable(attachedDatabase, alias);
  }
}

class StoredEntity extends DataClass implements Insertable<StoredEntity> {
  final String spaceId;
  final String scopeId;
  final String entityType;
  final String entityId;
  final String dataJson;
  final String serverRevision;
  final bool deleted;
  final DateTime updatedAt;
  const StoredEntity({
    required this.spaceId,
    required this.scopeId,
    required this.entityType,
    required this.entityId,
    required this.dataJson,
    required this.serverRevision,
    required this.deleted,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['space_id'] = Variable<String>(spaceId);
    map['scope_id'] = Variable<String>(scopeId);
    map['entity_type'] = Variable<String>(entityType);
    map['entity_id'] = Variable<String>(entityId);
    map['data_json'] = Variable<String>(dataJson);
    map['server_revision'] = Variable<String>(serverRevision);
    map['deleted'] = Variable<bool>(deleted);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    return map;
  }

  LocalEntitiesCompanion toCompanion(bool nullToAbsent) {
    return LocalEntitiesCompanion(
      spaceId: Value(spaceId),
      scopeId: Value(scopeId),
      entityType: Value(entityType),
      entityId: Value(entityId),
      dataJson: Value(dataJson),
      serverRevision: Value(serverRevision),
      deleted: Value(deleted),
      updatedAt: Value(updatedAt),
    );
  }

  factory StoredEntity.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return StoredEntity(
      spaceId: serializer.fromJson<String>(json['spaceId']),
      scopeId: serializer.fromJson<String>(json['scopeId']),
      entityType: serializer.fromJson<String>(json['entityType']),
      entityId: serializer.fromJson<String>(json['entityId']),
      dataJson: serializer.fromJson<String>(json['dataJson']),
      serverRevision: serializer.fromJson<String>(json['serverRevision']),
      deleted: serializer.fromJson<bool>(json['deleted']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'spaceId': serializer.toJson<String>(spaceId),
      'scopeId': serializer.toJson<String>(scopeId),
      'entityType': serializer.toJson<String>(entityType),
      'entityId': serializer.toJson<String>(entityId),
      'dataJson': serializer.toJson<String>(dataJson),
      'serverRevision': serializer.toJson<String>(serverRevision),
      'deleted': serializer.toJson<bool>(deleted),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
    };
  }

  StoredEntity copyWith({
    String? spaceId,
    String? scopeId,
    String? entityType,
    String? entityId,
    String? dataJson,
    String? serverRevision,
    bool? deleted,
    DateTime? updatedAt,
  }) => StoredEntity(
    spaceId: spaceId ?? this.spaceId,
    scopeId: scopeId ?? this.scopeId,
    entityType: entityType ?? this.entityType,
    entityId: entityId ?? this.entityId,
    dataJson: dataJson ?? this.dataJson,
    serverRevision: serverRevision ?? this.serverRevision,
    deleted: deleted ?? this.deleted,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  StoredEntity copyWithCompanion(LocalEntitiesCompanion data) {
    return StoredEntity(
      spaceId: data.spaceId.present ? data.spaceId.value : this.spaceId,
      scopeId: data.scopeId.present ? data.scopeId.value : this.scopeId,
      entityType: data.entityType.present
          ? data.entityType.value
          : this.entityType,
      entityId: data.entityId.present ? data.entityId.value : this.entityId,
      dataJson: data.dataJson.present ? data.dataJson.value : this.dataJson,
      serverRevision: data.serverRevision.present
          ? data.serverRevision.value
          : this.serverRevision,
      deleted: data.deleted.present ? data.deleted.value : this.deleted,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('StoredEntity(')
          ..write('spaceId: $spaceId, ')
          ..write('scopeId: $scopeId, ')
          ..write('entityType: $entityType, ')
          ..write('entityId: $entityId, ')
          ..write('dataJson: $dataJson, ')
          ..write('serverRevision: $serverRevision, ')
          ..write('deleted: $deleted, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    spaceId,
    scopeId,
    entityType,
    entityId,
    dataJson,
    serverRevision,
    deleted,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is StoredEntity &&
          other.spaceId == this.spaceId &&
          other.scopeId == this.scopeId &&
          other.entityType == this.entityType &&
          other.entityId == this.entityId &&
          other.dataJson == this.dataJson &&
          other.serverRevision == this.serverRevision &&
          other.deleted == this.deleted &&
          other.updatedAt == this.updatedAt);
}

class LocalEntitiesCompanion extends UpdateCompanion<StoredEntity> {
  final Value<String> spaceId;
  final Value<String> scopeId;
  final Value<String> entityType;
  final Value<String> entityId;
  final Value<String> dataJson;
  final Value<String> serverRevision;
  final Value<bool> deleted;
  final Value<DateTime> updatedAt;
  final Value<int> rowid;
  const LocalEntitiesCompanion({
    this.spaceId = const Value.absent(),
    this.scopeId = const Value.absent(),
    this.entityType = const Value.absent(),
    this.entityId = const Value.absent(),
    this.dataJson = const Value.absent(),
    this.serverRevision = const Value.absent(),
    this.deleted = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LocalEntitiesCompanion.insert({
    required String spaceId,
    this.scopeId = const Value.absent(),
    required String entityType,
    required String entityId,
    required String dataJson,
    this.serverRevision = const Value.absent(),
    this.deleted = const Value.absent(),
    required DateTime updatedAt,
    this.rowid = const Value.absent(),
  }) : spaceId = Value(spaceId),
       entityType = Value(entityType),
       entityId = Value(entityId),
       dataJson = Value(dataJson),
       updatedAt = Value(updatedAt);
  static Insertable<StoredEntity> custom({
    Expression<String>? spaceId,
    Expression<String>? scopeId,
    Expression<String>? entityType,
    Expression<String>? entityId,
    Expression<String>? dataJson,
    Expression<String>? serverRevision,
    Expression<bool>? deleted,
    Expression<DateTime>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (spaceId != null) 'space_id': spaceId,
      if (scopeId != null) 'scope_id': scopeId,
      if (entityType != null) 'entity_type': entityType,
      if (entityId != null) 'entity_id': entityId,
      if (dataJson != null) 'data_json': dataJson,
      if (serverRevision != null) 'server_revision': serverRevision,
      if (deleted != null) 'deleted': deleted,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LocalEntitiesCompanion copyWith({
    Value<String>? spaceId,
    Value<String>? scopeId,
    Value<String>? entityType,
    Value<String>? entityId,
    Value<String>? dataJson,
    Value<String>? serverRevision,
    Value<bool>? deleted,
    Value<DateTime>? updatedAt,
    Value<int>? rowid,
  }) {
    return LocalEntitiesCompanion(
      spaceId: spaceId ?? this.spaceId,
      scopeId: scopeId ?? this.scopeId,
      entityType: entityType ?? this.entityType,
      entityId: entityId ?? this.entityId,
      dataJson: dataJson ?? this.dataJson,
      serverRevision: serverRevision ?? this.serverRevision,
      deleted: deleted ?? this.deleted,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (spaceId.present) {
      map['space_id'] = Variable<String>(spaceId.value);
    }
    if (scopeId.present) {
      map['scope_id'] = Variable<String>(scopeId.value);
    }
    if (entityType.present) {
      map['entity_type'] = Variable<String>(entityType.value);
    }
    if (entityId.present) {
      map['entity_id'] = Variable<String>(entityId.value);
    }
    if (dataJson.present) {
      map['data_json'] = Variable<String>(dataJson.value);
    }
    if (serverRevision.present) {
      map['server_revision'] = Variable<String>(serverRevision.value);
    }
    if (deleted.present) {
      map['deleted'] = Variable<bool>(deleted.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalEntitiesCompanion(')
          ..write('spaceId: $spaceId, ')
          ..write('scopeId: $scopeId, ')
          ..write('entityType: $entityType, ')
          ..write('entityId: $entityId, ')
          ..write('dataJson: $dataJson, ')
          ..write('serverRevision: $serverRevision, ')
          ..write('deleted: $deleted, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $PendingOperationsTable extends PendingOperations
    with TableInfo<$PendingOperationsTable, StoredOperation> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PendingOperationsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _sequenceMeta = const VerificationMeta(
    'sequence',
  );
  @override
  late final GeneratedColumn<int> sequence = GeneratedColumn<int>(
    'sequence',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _spaceIdMeta = const VerificationMeta(
    'spaceId',
  );
  @override
  late final GeneratedColumn<String> spaceId = GeneratedColumn<String>(
    'space_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES local_spaces (id)',
    ),
  );
  static const VerificationMeta _operationIdMeta = const VerificationMeta(
    'operationId',
  );
  @override
  late final GeneratedColumn<String> operationId = GeneratedColumn<String>(
    'operation_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _entityTypeMeta = const VerificationMeta(
    'entityType',
  );
  @override
  late final GeneratedColumn<String> entityType = GeneratedColumn<String>(
    'entity_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _entityIdMeta = const VerificationMeta(
    'entityId',
  );
  @override
  late final GeneratedColumn<String> entityId = GeneratedColumn<String>(
    'entity_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _operationJsonMeta = const VerificationMeta(
    'operationJson',
  );
  @override
  late final GeneratedColumn<String> operationJson = GeneratedColumn<String>(
    'operation_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _frozenRequestJsonMeta = const VerificationMeta(
    'frozenRequestJson',
  );
  @override
  late final GeneratedColumn<String> frozenRequestJson =
      GeneratedColumn<String>(
        'frozen_request_json',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _stateMeta = const VerificationMeta('state');
  @override
  late final GeneratedColumn<String> state = GeneratedColumn<String>(
    'state',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('queued'),
  );
  static const VerificationMeta _attemptCountMeta = const VerificationMeta(
    'attemptCount',
  );
  @override
  late final GeneratedColumn<int> attemptCount = GeneratedColumn<int>(
    'attempt_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _lastErrorCodeMeta = const VerificationMeta(
    'lastErrorCode',
  );
  @override
  late final GeneratedColumn<String> lastErrorCode = GeneratedColumn<String>(
    'last_error_code',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _predecessorIdMeta = const VerificationMeta(
    'predecessorId',
  );
  @override
  late final GeneratedColumn<String> predecessorId = GeneratedColumn<String>(
    'predecessor_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _appliedRevisionMeta = const VerificationMeta(
    'appliedRevision',
  );
  @override
  late final GeneratedColumn<String> appliedRevision = GeneratedColumn<String>(
    'applied_revision',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _baseDataJsonMeta = const VerificationMeta(
    'baseDataJson',
  );
  @override
  late final GeneratedColumn<String> baseDataJson = GeneratedColumn<String>(
    'base_data_json',
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
  @override
  List<GeneratedColumn> get $columns => [
    sequence,
    spaceId,
    operationId,
    entityType,
    entityId,
    operationJson,
    frozenRequestJson,
    state,
    attemptCount,
    lastErrorCode,
    predecessorId,
    appliedRevision,
    baseDataJson,
    createdAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'pending_operations';
  @override
  VerificationContext validateIntegrity(
    Insertable<StoredOperation> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('sequence')) {
      context.handle(
        _sequenceMeta,
        sequence.isAcceptableOrUnknown(data['sequence']!, _sequenceMeta),
      );
    }
    if (data.containsKey('space_id')) {
      context.handle(
        _spaceIdMeta,
        spaceId.isAcceptableOrUnknown(data['space_id']!, _spaceIdMeta),
      );
    } else if (isInserting) {
      context.missing(_spaceIdMeta);
    }
    if (data.containsKey('operation_id')) {
      context.handle(
        _operationIdMeta,
        operationId.isAcceptableOrUnknown(
          data['operation_id']!,
          _operationIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_operationIdMeta);
    }
    if (data.containsKey('entity_type')) {
      context.handle(
        _entityTypeMeta,
        entityType.isAcceptableOrUnknown(data['entity_type']!, _entityTypeMeta),
      );
    } else if (isInserting) {
      context.missing(_entityTypeMeta);
    }
    if (data.containsKey('entity_id')) {
      context.handle(
        _entityIdMeta,
        entityId.isAcceptableOrUnknown(data['entity_id']!, _entityIdMeta),
      );
    } else if (isInserting) {
      context.missing(_entityIdMeta);
    }
    if (data.containsKey('operation_json')) {
      context.handle(
        _operationJsonMeta,
        operationJson.isAcceptableOrUnknown(
          data['operation_json']!,
          _operationJsonMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_operationJsonMeta);
    }
    if (data.containsKey('frozen_request_json')) {
      context.handle(
        _frozenRequestJsonMeta,
        frozenRequestJson.isAcceptableOrUnknown(
          data['frozen_request_json']!,
          _frozenRequestJsonMeta,
        ),
      );
    }
    if (data.containsKey('state')) {
      context.handle(
        _stateMeta,
        state.isAcceptableOrUnknown(data['state']!, _stateMeta),
      );
    }
    if (data.containsKey('attempt_count')) {
      context.handle(
        _attemptCountMeta,
        attemptCount.isAcceptableOrUnknown(
          data['attempt_count']!,
          _attemptCountMeta,
        ),
      );
    }
    if (data.containsKey('last_error_code')) {
      context.handle(
        _lastErrorCodeMeta,
        lastErrorCode.isAcceptableOrUnknown(
          data['last_error_code']!,
          _lastErrorCodeMeta,
        ),
      );
    }
    if (data.containsKey('predecessor_id')) {
      context.handle(
        _predecessorIdMeta,
        predecessorId.isAcceptableOrUnknown(
          data['predecessor_id']!,
          _predecessorIdMeta,
        ),
      );
    }
    if (data.containsKey('applied_revision')) {
      context.handle(
        _appliedRevisionMeta,
        appliedRevision.isAcceptableOrUnknown(
          data['applied_revision']!,
          _appliedRevisionMeta,
        ),
      );
    }
    if (data.containsKey('base_data_json')) {
      context.handle(
        _baseDataJsonMeta,
        baseDataJson.isAcceptableOrUnknown(
          data['base_data_json']!,
          _baseDataJsonMeta,
        ),
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
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {sequence};
  @override
  List<Set<GeneratedColumn>> get uniqueKeys => [
    {spaceId, operationId},
  ];
  @override
  StoredOperation map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return StoredOperation(
      sequence: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}sequence'],
      )!,
      spaceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}space_id'],
      )!,
      operationId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}operation_id'],
      )!,
      entityType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}entity_type'],
      )!,
      entityId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}entity_id'],
      )!,
      operationJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}operation_json'],
      )!,
      frozenRequestJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}frozen_request_json'],
      ),
      state: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}state'],
      )!,
      attemptCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}attempt_count'],
      )!,
      lastErrorCode: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}last_error_code'],
      ),
      predecessorId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}predecessor_id'],
      ),
      appliedRevision: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}applied_revision'],
      ),
      baseDataJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}base_data_json'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
    );
  }

  @override
  $PendingOperationsTable createAlias(String alias) {
    return $PendingOperationsTable(attachedDatabase, alias);
  }
}

class StoredOperation extends DataClass implements Insertable<StoredOperation> {
  final int sequence;
  final String spaceId;
  final String operationId;
  final String entityType;
  final String entityId;
  final String operationJson;
  final String? frozenRequestJson;
  final String state;
  final int attemptCount;
  final String? lastErrorCode;
  final String? predecessorId;
  final String? appliedRevision;
  final String? baseDataJson;
  final DateTime createdAt;
  const StoredOperation({
    required this.sequence,
    required this.spaceId,
    required this.operationId,
    required this.entityType,
    required this.entityId,
    required this.operationJson,
    this.frozenRequestJson,
    required this.state,
    required this.attemptCount,
    this.lastErrorCode,
    this.predecessorId,
    this.appliedRevision,
    this.baseDataJson,
    required this.createdAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['sequence'] = Variable<int>(sequence);
    map['space_id'] = Variable<String>(spaceId);
    map['operation_id'] = Variable<String>(operationId);
    map['entity_type'] = Variable<String>(entityType);
    map['entity_id'] = Variable<String>(entityId);
    map['operation_json'] = Variable<String>(operationJson);
    if (!nullToAbsent || frozenRequestJson != null) {
      map['frozen_request_json'] = Variable<String>(frozenRequestJson);
    }
    map['state'] = Variable<String>(state);
    map['attempt_count'] = Variable<int>(attemptCount);
    if (!nullToAbsent || lastErrorCode != null) {
      map['last_error_code'] = Variable<String>(lastErrorCode);
    }
    if (!nullToAbsent || predecessorId != null) {
      map['predecessor_id'] = Variable<String>(predecessorId);
    }
    if (!nullToAbsent || appliedRevision != null) {
      map['applied_revision'] = Variable<String>(appliedRevision);
    }
    if (!nullToAbsent || baseDataJson != null) {
      map['base_data_json'] = Variable<String>(baseDataJson);
    }
    map['created_at'] = Variable<DateTime>(createdAt);
    return map;
  }

  PendingOperationsCompanion toCompanion(bool nullToAbsent) {
    return PendingOperationsCompanion(
      sequence: Value(sequence),
      spaceId: Value(spaceId),
      operationId: Value(operationId),
      entityType: Value(entityType),
      entityId: Value(entityId),
      operationJson: Value(operationJson),
      frozenRequestJson: frozenRequestJson == null && nullToAbsent
          ? const Value.absent()
          : Value(frozenRequestJson),
      state: Value(state),
      attemptCount: Value(attemptCount),
      lastErrorCode: lastErrorCode == null && nullToAbsent
          ? const Value.absent()
          : Value(lastErrorCode),
      predecessorId: predecessorId == null && nullToAbsent
          ? const Value.absent()
          : Value(predecessorId),
      appliedRevision: appliedRevision == null && nullToAbsent
          ? const Value.absent()
          : Value(appliedRevision),
      baseDataJson: baseDataJson == null && nullToAbsent
          ? const Value.absent()
          : Value(baseDataJson),
      createdAt: Value(createdAt),
    );
  }

  factory StoredOperation.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return StoredOperation(
      sequence: serializer.fromJson<int>(json['sequence']),
      spaceId: serializer.fromJson<String>(json['spaceId']),
      operationId: serializer.fromJson<String>(json['operationId']),
      entityType: serializer.fromJson<String>(json['entityType']),
      entityId: serializer.fromJson<String>(json['entityId']),
      operationJson: serializer.fromJson<String>(json['operationJson']),
      frozenRequestJson: serializer.fromJson<String?>(
        json['frozenRequestJson'],
      ),
      state: serializer.fromJson<String>(json['state']),
      attemptCount: serializer.fromJson<int>(json['attemptCount']),
      lastErrorCode: serializer.fromJson<String?>(json['lastErrorCode']),
      predecessorId: serializer.fromJson<String?>(json['predecessorId']),
      appliedRevision: serializer.fromJson<String?>(json['appliedRevision']),
      baseDataJson: serializer.fromJson<String?>(json['baseDataJson']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'sequence': serializer.toJson<int>(sequence),
      'spaceId': serializer.toJson<String>(spaceId),
      'operationId': serializer.toJson<String>(operationId),
      'entityType': serializer.toJson<String>(entityType),
      'entityId': serializer.toJson<String>(entityId),
      'operationJson': serializer.toJson<String>(operationJson),
      'frozenRequestJson': serializer.toJson<String?>(frozenRequestJson),
      'state': serializer.toJson<String>(state),
      'attemptCount': serializer.toJson<int>(attemptCount),
      'lastErrorCode': serializer.toJson<String?>(lastErrorCode),
      'predecessorId': serializer.toJson<String?>(predecessorId),
      'appliedRevision': serializer.toJson<String?>(appliedRevision),
      'baseDataJson': serializer.toJson<String?>(baseDataJson),
      'createdAt': serializer.toJson<DateTime>(createdAt),
    };
  }

  StoredOperation copyWith({
    int? sequence,
    String? spaceId,
    String? operationId,
    String? entityType,
    String? entityId,
    String? operationJson,
    Value<String?> frozenRequestJson = const Value.absent(),
    String? state,
    int? attemptCount,
    Value<String?> lastErrorCode = const Value.absent(),
    Value<String?> predecessorId = const Value.absent(),
    Value<String?> appliedRevision = const Value.absent(),
    Value<String?> baseDataJson = const Value.absent(),
    DateTime? createdAt,
  }) => StoredOperation(
    sequence: sequence ?? this.sequence,
    spaceId: spaceId ?? this.spaceId,
    operationId: operationId ?? this.operationId,
    entityType: entityType ?? this.entityType,
    entityId: entityId ?? this.entityId,
    operationJson: operationJson ?? this.operationJson,
    frozenRequestJson: frozenRequestJson.present
        ? frozenRequestJson.value
        : this.frozenRequestJson,
    state: state ?? this.state,
    attemptCount: attemptCount ?? this.attemptCount,
    lastErrorCode: lastErrorCode.present
        ? lastErrorCode.value
        : this.lastErrorCode,
    predecessorId: predecessorId.present
        ? predecessorId.value
        : this.predecessorId,
    appliedRevision: appliedRevision.present
        ? appliedRevision.value
        : this.appliedRevision,
    baseDataJson: baseDataJson.present ? baseDataJson.value : this.baseDataJson,
    createdAt: createdAt ?? this.createdAt,
  );
  StoredOperation copyWithCompanion(PendingOperationsCompanion data) {
    return StoredOperation(
      sequence: data.sequence.present ? data.sequence.value : this.sequence,
      spaceId: data.spaceId.present ? data.spaceId.value : this.spaceId,
      operationId: data.operationId.present
          ? data.operationId.value
          : this.operationId,
      entityType: data.entityType.present
          ? data.entityType.value
          : this.entityType,
      entityId: data.entityId.present ? data.entityId.value : this.entityId,
      operationJson: data.operationJson.present
          ? data.operationJson.value
          : this.operationJson,
      frozenRequestJson: data.frozenRequestJson.present
          ? data.frozenRequestJson.value
          : this.frozenRequestJson,
      state: data.state.present ? data.state.value : this.state,
      attemptCount: data.attemptCount.present
          ? data.attemptCount.value
          : this.attemptCount,
      lastErrorCode: data.lastErrorCode.present
          ? data.lastErrorCode.value
          : this.lastErrorCode,
      predecessorId: data.predecessorId.present
          ? data.predecessorId.value
          : this.predecessorId,
      appliedRevision: data.appliedRevision.present
          ? data.appliedRevision.value
          : this.appliedRevision,
      baseDataJson: data.baseDataJson.present
          ? data.baseDataJson.value
          : this.baseDataJson,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('StoredOperation(')
          ..write('sequence: $sequence, ')
          ..write('spaceId: $spaceId, ')
          ..write('operationId: $operationId, ')
          ..write('entityType: $entityType, ')
          ..write('entityId: $entityId, ')
          ..write('operationJson: $operationJson, ')
          ..write('frozenRequestJson: $frozenRequestJson, ')
          ..write('state: $state, ')
          ..write('attemptCount: $attemptCount, ')
          ..write('lastErrorCode: $lastErrorCode, ')
          ..write('predecessorId: $predecessorId, ')
          ..write('appliedRevision: $appliedRevision, ')
          ..write('baseDataJson: $baseDataJson, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    sequence,
    spaceId,
    operationId,
    entityType,
    entityId,
    operationJson,
    frozenRequestJson,
    state,
    attemptCount,
    lastErrorCode,
    predecessorId,
    appliedRevision,
    baseDataJson,
    createdAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is StoredOperation &&
          other.sequence == this.sequence &&
          other.spaceId == this.spaceId &&
          other.operationId == this.operationId &&
          other.entityType == this.entityType &&
          other.entityId == this.entityId &&
          other.operationJson == this.operationJson &&
          other.frozenRequestJson == this.frozenRequestJson &&
          other.state == this.state &&
          other.attemptCount == this.attemptCount &&
          other.lastErrorCode == this.lastErrorCode &&
          other.predecessorId == this.predecessorId &&
          other.appliedRevision == this.appliedRevision &&
          other.baseDataJson == this.baseDataJson &&
          other.createdAt == this.createdAt);
}

class PendingOperationsCompanion extends UpdateCompanion<StoredOperation> {
  final Value<int> sequence;
  final Value<String> spaceId;
  final Value<String> operationId;
  final Value<String> entityType;
  final Value<String> entityId;
  final Value<String> operationJson;
  final Value<String?> frozenRequestJson;
  final Value<String> state;
  final Value<int> attemptCount;
  final Value<String?> lastErrorCode;
  final Value<String?> predecessorId;
  final Value<String?> appliedRevision;
  final Value<String?> baseDataJson;
  final Value<DateTime> createdAt;
  const PendingOperationsCompanion({
    this.sequence = const Value.absent(),
    this.spaceId = const Value.absent(),
    this.operationId = const Value.absent(),
    this.entityType = const Value.absent(),
    this.entityId = const Value.absent(),
    this.operationJson = const Value.absent(),
    this.frozenRequestJson = const Value.absent(),
    this.state = const Value.absent(),
    this.attemptCount = const Value.absent(),
    this.lastErrorCode = const Value.absent(),
    this.predecessorId = const Value.absent(),
    this.appliedRevision = const Value.absent(),
    this.baseDataJson = const Value.absent(),
    this.createdAt = const Value.absent(),
  });
  PendingOperationsCompanion.insert({
    this.sequence = const Value.absent(),
    required String spaceId,
    required String operationId,
    required String entityType,
    required String entityId,
    required String operationJson,
    this.frozenRequestJson = const Value.absent(),
    this.state = const Value.absent(),
    this.attemptCount = const Value.absent(),
    this.lastErrorCode = const Value.absent(),
    this.predecessorId = const Value.absent(),
    this.appliedRevision = const Value.absent(),
    this.baseDataJson = const Value.absent(),
    required DateTime createdAt,
  }) : spaceId = Value(spaceId),
       operationId = Value(operationId),
       entityType = Value(entityType),
       entityId = Value(entityId),
       operationJson = Value(operationJson),
       createdAt = Value(createdAt);
  static Insertable<StoredOperation> custom({
    Expression<int>? sequence,
    Expression<String>? spaceId,
    Expression<String>? operationId,
    Expression<String>? entityType,
    Expression<String>? entityId,
    Expression<String>? operationJson,
    Expression<String>? frozenRequestJson,
    Expression<String>? state,
    Expression<int>? attemptCount,
    Expression<String>? lastErrorCode,
    Expression<String>? predecessorId,
    Expression<String>? appliedRevision,
    Expression<String>? baseDataJson,
    Expression<DateTime>? createdAt,
  }) {
    return RawValuesInsertable({
      if (sequence != null) 'sequence': sequence,
      if (spaceId != null) 'space_id': spaceId,
      if (operationId != null) 'operation_id': operationId,
      if (entityType != null) 'entity_type': entityType,
      if (entityId != null) 'entity_id': entityId,
      if (operationJson != null) 'operation_json': operationJson,
      if (frozenRequestJson != null) 'frozen_request_json': frozenRequestJson,
      if (state != null) 'state': state,
      if (attemptCount != null) 'attempt_count': attemptCount,
      if (lastErrorCode != null) 'last_error_code': lastErrorCode,
      if (predecessorId != null) 'predecessor_id': predecessorId,
      if (appliedRevision != null) 'applied_revision': appliedRevision,
      if (baseDataJson != null) 'base_data_json': baseDataJson,
      if (createdAt != null) 'created_at': createdAt,
    });
  }

  PendingOperationsCompanion copyWith({
    Value<int>? sequence,
    Value<String>? spaceId,
    Value<String>? operationId,
    Value<String>? entityType,
    Value<String>? entityId,
    Value<String>? operationJson,
    Value<String?>? frozenRequestJson,
    Value<String>? state,
    Value<int>? attemptCount,
    Value<String?>? lastErrorCode,
    Value<String?>? predecessorId,
    Value<String?>? appliedRevision,
    Value<String?>? baseDataJson,
    Value<DateTime>? createdAt,
  }) {
    return PendingOperationsCompanion(
      sequence: sequence ?? this.sequence,
      spaceId: spaceId ?? this.spaceId,
      operationId: operationId ?? this.operationId,
      entityType: entityType ?? this.entityType,
      entityId: entityId ?? this.entityId,
      operationJson: operationJson ?? this.operationJson,
      frozenRequestJson: frozenRequestJson ?? this.frozenRequestJson,
      state: state ?? this.state,
      attemptCount: attemptCount ?? this.attemptCount,
      lastErrorCode: lastErrorCode ?? this.lastErrorCode,
      predecessorId: predecessorId ?? this.predecessorId,
      appliedRevision: appliedRevision ?? this.appliedRevision,
      baseDataJson: baseDataJson ?? this.baseDataJson,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (sequence.present) {
      map['sequence'] = Variable<int>(sequence.value);
    }
    if (spaceId.present) {
      map['space_id'] = Variable<String>(spaceId.value);
    }
    if (operationId.present) {
      map['operation_id'] = Variable<String>(operationId.value);
    }
    if (entityType.present) {
      map['entity_type'] = Variable<String>(entityType.value);
    }
    if (entityId.present) {
      map['entity_id'] = Variable<String>(entityId.value);
    }
    if (operationJson.present) {
      map['operation_json'] = Variable<String>(operationJson.value);
    }
    if (frozenRequestJson.present) {
      map['frozen_request_json'] = Variable<String>(frozenRequestJson.value);
    }
    if (state.present) {
      map['state'] = Variable<String>(state.value);
    }
    if (attemptCount.present) {
      map['attempt_count'] = Variable<int>(attemptCount.value);
    }
    if (lastErrorCode.present) {
      map['last_error_code'] = Variable<String>(lastErrorCode.value);
    }
    if (predecessorId.present) {
      map['predecessor_id'] = Variable<String>(predecessorId.value);
    }
    if (appliedRevision.present) {
      map['applied_revision'] = Variable<String>(appliedRevision.value);
    }
    if (baseDataJson.present) {
      map['base_data_json'] = Variable<String>(baseDataJson.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PendingOperationsCompanion(')
          ..write('sequence: $sequence, ')
          ..write('spaceId: $spaceId, ')
          ..write('operationId: $operationId, ')
          ..write('entityType: $entityType, ')
          ..write('entityId: $entityId, ')
          ..write('operationJson: $operationJson, ')
          ..write('frozenRequestJson: $frozenRequestJson, ')
          ..write('state: $state, ')
          ..write('attemptCount: $attemptCount, ')
          ..write('lastErrorCode: $lastErrorCode, ')
          ..write('predecessorId: $predecessorId, ')
          ..write('appliedRevision: $appliedRevision, ')
          ..write('baseDataJson: $baseDataJson, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }
}

class $ServerShadowsTable extends ServerShadows
    with TableInfo<$ServerShadowsTable, ConfirmedEntity> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ServerShadowsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _spaceIdMeta = const VerificationMeta(
    'spaceId',
  );
  @override
  late final GeneratedColumn<String> spaceId = GeneratedColumn<String>(
    'space_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES local_spaces (id)',
    ),
  );
  static const VerificationMeta _scopeIdMeta = const VerificationMeta(
    'scopeId',
  );
  @override
  late final GeneratedColumn<String> scopeId = GeneratedColumn<String>(
    'scope_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _entityTypeMeta = const VerificationMeta(
    'entityType',
  );
  @override
  late final GeneratedColumn<String> entityType = GeneratedColumn<String>(
    'entity_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _entityIdMeta = const VerificationMeta(
    'entityId',
  );
  @override
  late final GeneratedColumn<String> entityId = GeneratedColumn<String>(
    'entity_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _revisionMeta = const VerificationMeta(
    'revision',
  );
  @override
  late final GeneratedColumn<String> revision = GeneratedColumn<String>(
    'revision',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _dataJsonMeta = const VerificationMeta(
    'dataJson',
  );
  @override
  late final GeneratedColumn<String> dataJson = GeneratedColumn<String>(
    'data_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _deletedMeta = const VerificationMeta(
    'deleted',
  );
  @override
  late final GeneratedColumn<bool> deleted = GeneratedColumn<bool>(
    'deleted',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("deleted" IN (0, 1))',
    ),
  );
  @override
  List<GeneratedColumn> get $columns => [
    spaceId,
    scopeId,
    entityType,
    entityId,
    revision,
    dataJson,
    deleted,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'server_shadows';
  @override
  VerificationContext validateIntegrity(
    Insertable<ConfirmedEntity> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('space_id')) {
      context.handle(
        _spaceIdMeta,
        spaceId.isAcceptableOrUnknown(data['space_id']!, _spaceIdMeta),
      );
    } else if (isInserting) {
      context.missing(_spaceIdMeta);
    }
    if (data.containsKey('scope_id')) {
      context.handle(
        _scopeIdMeta,
        scopeId.isAcceptableOrUnknown(data['scope_id']!, _scopeIdMeta),
      );
    } else if (isInserting) {
      context.missing(_scopeIdMeta);
    }
    if (data.containsKey('entity_type')) {
      context.handle(
        _entityTypeMeta,
        entityType.isAcceptableOrUnknown(data['entity_type']!, _entityTypeMeta),
      );
    } else if (isInserting) {
      context.missing(_entityTypeMeta);
    }
    if (data.containsKey('entity_id')) {
      context.handle(
        _entityIdMeta,
        entityId.isAcceptableOrUnknown(data['entity_id']!, _entityIdMeta),
      );
    } else if (isInserting) {
      context.missing(_entityIdMeta);
    }
    if (data.containsKey('revision')) {
      context.handle(
        _revisionMeta,
        revision.isAcceptableOrUnknown(data['revision']!, _revisionMeta),
      );
    } else if (isInserting) {
      context.missing(_revisionMeta);
    }
    if (data.containsKey('data_json')) {
      context.handle(
        _dataJsonMeta,
        dataJson.isAcceptableOrUnknown(data['data_json']!, _dataJsonMeta),
      );
    } else if (isInserting) {
      context.missing(_dataJsonMeta);
    }
    if (data.containsKey('deleted')) {
      context.handle(
        _deletedMeta,
        deleted.isAcceptableOrUnknown(data['deleted']!, _deletedMeta),
      );
    } else if (isInserting) {
      context.missing(_deletedMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {
    spaceId,
    scopeId,
    entityType,
    entityId,
  };
  @override
  ConfirmedEntity map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ConfirmedEntity(
      spaceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}space_id'],
      )!,
      scopeId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}scope_id'],
      )!,
      entityType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}entity_type'],
      )!,
      entityId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}entity_id'],
      )!,
      revision: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}revision'],
      )!,
      dataJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}data_json'],
      )!,
      deleted: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}deleted'],
      )!,
    );
  }

  @override
  $ServerShadowsTable createAlias(String alias) {
    return $ServerShadowsTable(attachedDatabase, alias);
  }
}

class ConfirmedEntity extends DataClass implements Insertable<ConfirmedEntity> {
  final String spaceId;
  final String scopeId;
  final String entityType;
  final String entityId;
  final String revision;
  final String dataJson;
  final bool deleted;
  const ConfirmedEntity({
    required this.spaceId,
    required this.scopeId,
    required this.entityType,
    required this.entityId,
    required this.revision,
    required this.dataJson,
    required this.deleted,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['space_id'] = Variable<String>(spaceId);
    map['scope_id'] = Variable<String>(scopeId);
    map['entity_type'] = Variable<String>(entityType);
    map['entity_id'] = Variable<String>(entityId);
    map['revision'] = Variable<String>(revision);
    map['data_json'] = Variable<String>(dataJson);
    map['deleted'] = Variable<bool>(deleted);
    return map;
  }

  ServerShadowsCompanion toCompanion(bool nullToAbsent) {
    return ServerShadowsCompanion(
      spaceId: Value(spaceId),
      scopeId: Value(scopeId),
      entityType: Value(entityType),
      entityId: Value(entityId),
      revision: Value(revision),
      dataJson: Value(dataJson),
      deleted: Value(deleted),
    );
  }

  factory ConfirmedEntity.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ConfirmedEntity(
      spaceId: serializer.fromJson<String>(json['spaceId']),
      scopeId: serializer.fromJson<String>(json['scopeId']),
      entityType: serializer.fromJson<String>(json['entityType']),
      entityId: serializer.fromJson<String>(json['entityId']),
      revision: serializer.fromJson<String>(json['revision']),
      dataJson: serializer.fromJson<String>(json['dataJson']),
      deleted: serializer.fromJson<bool>(json['deleted']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'spaceId': serializer.toJson<String>(spaceId),
      'scopeId': serializer.toJson<String>(scopeId),
      'entityType': serializer.toJson<String>(entityType),
      'entityId': serializer.toJson<String>(entityId),
      'revision': serializer.toJson<String>(revision),
      'dataJson': serializer.toJson<String>(dataJson),
      'deleted': serializer.toJson<bool>(deleted),
    };
  }

  ConfirmedEntity copyWith({
    String? spaceId,
    String? scopeId,
    String? entityType,
    String? entityId,
    String? revision,
    String? dataJson,
    bool? deleted,
  }) => ConfirmedEntity(
    spaceId: spaceId ?? this.spaceId,
    scopeId: scopeId ?? this.scopeId,
    entityType: entityType ?? this.entityType,
    entityId: entityId ?? this.entityId,
    revision: revision ?? this.revision,
    dataJson: dataJson ?? this.dataJson,
    deleted: deleted ?? this.deleted,
  );
  ConfirmedEntity copyWithCompanion(ServerShadowsCompanion data) {
    return ConfirmedEntity(
      spaceId: data.spaceId.present ? data.spaceId.value : this.spaceId,
      scopeId: data.scopeId.present ? data.scopeId.value : this.scopeId,
      entityType: data.entityType.present
          ? data.entityType.value
          : this.entityType,
      entityId: data.entityId.present ? data.entityId.value : this.entityId,
      revision: data.revision.present ? data.revision.value : this.revision,
      dataJson: data.dataJson.present ? data.dataJson.value : this.dataJson,
      deleted: data.deleted.present ? data.deleted.value : this.deleted,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ConfirmedEntity(')
          ..write('spaceId: $spaceId, ')
          ..write('scopeId: $scopeId, ')
          ..write('entityType: $entityType, ')
          ..write('entityId: $entityId, ')
          ..write('revision: $revision, ')
          ..write('dataJson: $dataJson, ')
          ..write('deleted: $deleted')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    spaceId,
    scopeId,
    entityType,
    entityId,
    revision,
    dataJson,
    deleted,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ConfirmedEntity &&
          other.spaceId == this.spaceId &&
          other.scopeId == this.scopeId &&
          other.entityType == this.entityType &&
          other.entityId == this.entityId &&
          other.revision == this.revision &&
          other.dataJson == this.dataJson &&
          other.deleted == this.deleted);
}

class ServerShadowsCompanion extends UpdateCompanion<ConfirmedEntity> {
  final Value<String> spaceId;
  final Value<String> scopeId;
  final Value<String> entityType;
  final Value<String> entityId;
  final Value<String> revision;
  final Value<String> dataJson;
  final Value<bool> deleted;
  final Value<int> rowid;
  const ServerShadowsCompanion({
    this.spaceId = const Value.absent(),
    this.scopeId = const Value.absent(),
    this.entityType = const Value.absent(),
    this.entityId = const Value.absent(),
    this.revision = const Value.absent(),
    this.dataJson = const Value.absent(),
    this.deleted = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ServerShadowsCompanion.insert({
    required String spaceId,
    required String scopeId,
    required String entityType,
    required String entityId,
    required String revision,
    required String dataJson,
    required bool deleted,
    this.rowid = const Value.absent(),
  }) : spaceId = Value(spaceId),
       scopeId = Value(scopeId),
       entityType = Value(entityType),
       entityId = Value(entityId),
       revision = Value(revision),
       dataJson = Value(dataJson),
       deleted = Value(deleted);
  static Insertable<ConfirmedEntity> custom({
    Expression<String>? spaceId,
    Expression<String>? scopeId,
    Expression<String>? entityType,
    Expression<String>? entityId,
    Expression<String>? revision,
    Expression<String>? dataJson,
    Expression<bool>? deleted,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (spaceId != null) 'space_id': spaceId,
      if (scopeId != null) 'scope_id': scopeId,
      if (entityType != null) 'entity_type': entityType,
      if (entityId != null) 'entity_id': entityId,
      if (revision != null) 'revision': revision,
      if (dataJson != null) 'data_json': dataJson,
      if (deleted != null) 'deleted': deleted,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ServerShadowsCompanion copyWith({
    Value<String>? spaceId,
    Value<String>? scopeId,
    Value<String>? entityType,
    Value<String>? entityId,
    Value<String>? revision,
    Value<String>? dataJson,
    Value<bool>? deleted,
    Value<int>? rowid,
  }) {
    return ServerShadowsCompanion(
      spaceId: spaceId ?? this.spaceId,
      scopeId: scopeId ?? this.scopeId,
      entityType: entityType ?? this.entityType,
      entityId: entityId ?? this.entityId,
      revision: revision ?? this.revision,
      dataJson: dataJson ?? this.dataJson,
      deleted: deleted ?? this.deleted,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (spaceId.present) {
      map['space_id'] = Variable<String>(spaceId.value);
    }
    if (scopeId.present) {
      map['scope_id'] = Variable<String>(scopeId.value);
    }
    if (entityType.present) {
      map['entity_type'] = Variable<String>(entityType.value);
    }
    if (entityId.present) {
      map['entity_id'] = Variable<String>(entityId.value);
    }
    if (revision.present) {
      map['revision'] = Variable<String>(revision.value);
    }
    if (dataJson.present) {
      map['data_json'] = Variable<String>(dataJson.value);
    }
    if (deleted.present) {
      map['deleted'] = Variable<bool>(deleted.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ServerShadowsCompanion(')
          ..write('spaceId: $spaceId, ')
          ..write('scopeId: $scopeId, ')
          ..write('entityType: $entityType, ')
          ..write('entityId: $entityId, ')
          ..write('revision: $revision, ')
          ..write('dataJson: $dataJson, ')
          ..write('deleted: $deleted, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SyncStatesTable extends SyncStates
    with TableInfo<$SyncStatesTable, SpaceSyncState> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SyncStatesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _spaceIdMeta = const VerificationMeta(
    'spaceId',
  );
  @override
  late final GeneratedColumn<String> spaceId = GeneratedColumn<String>(
    'space_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES local_spaces (id)',
    ),
  );
  static const VerificationMeta _clientIdMeta = const VerificationMeta(
    'clientId',
  );
  @override
  late final GeneratedColumn<String> clientId = GeneratedColumn<String>(
    'client_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _epochMeta = const VerificationMeta('epoch');
  @override
  late final GeneratedColumn<String> epoch = GeneratedColumn<String>(
    'epoch',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _cursorsJsonMeta = const VerificationMeta(
    'cursorsJson',
  );
  @override
  late final GeneratedColumn<String> cursorsJson = GeneratedColumn<String>(
    'cursors_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('{}'),
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('active'),
  );
  static const VerificationMeta _revokedScopesJsonMeta = const VerificationMeta(
    'revokedScopesJson',
  );
  @override
  late final GeneratedColumn<String> revokedScopesJson =
      GeneratedColumn<String>(
        'revoked_scopes_json',
        aliasedName,
        false,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
        defaultValue: const Constant('[]'),
      );
  @override
  List<GeneratedColumn> get $columns => [
    spaceId,
    clientId,
    epoch,
    cursorsJson,
    status,
    revokedScopesJson,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sync_states';
  @override
  VerificationContext validateIntegrity(
    Insertable<SpaceSyncState> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('space_id')) {
      context.handle(
        _spaceIdMeta,
        spaceId.isAcceptableOrUnknown(data['space_id']!, _spaceIdMeta),
      );
    } else if (isInserting) {
      context.missing(_spaceIdMeta);
    }
    if (data.containsKey('client_id')) {
      context.handle(
        _clientIdMeta,
        clientId.isAcceptableOrUnknown(data['client_id']!, _clientIdMeta),
      );
    } else if (isInserting) {
      context.missing(_clientIdMeta);
    }
    if (data.containsKey('epoch')) {
      context.handle(
        _epochMeta,
        epoch.isAcceptableOrUnknown(data['epoch']!, _epochMeta),
      );
    } else if (isInserting) {
      context.missing(_epochMeta);
    }
    if (data.containsKey('cursors_json')) {
      context.handle(
        _cursorsJsonMeta,
        cursorsJson.isAcceptableOrUnknown(
          data['cursors_json']!,
          _cursorsJsonMeta,
        ),
      );
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    }
    if (data.containsKey('revoked_scopes_json')) {
      context.handle(
        _revokedScopesJsonMeta,
        revokedScopesJson.isAcceptableOrUnknown(
          data['revoked_scopes_json']!,
          _revokedScopesJsonMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {spaceId};
  @override
  SpaceSyncState map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SpaceSyncState(
      spaceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}space_id'],
      )!,
      clientId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}client_id'],
      )!,
      epoch: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}epoch'],
      )!,
      cursorsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}cursors_json'],
      )!,
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status'],
      )!,
      revokedScopesJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}revoked_scopes_json'],
      )!,
    );
  }

  @override
  $SyncStatesTable createAlias(String alias) {
    return $SyncStatesTable(attachedDatabase, alias);
  }
}

class SpaceSyncState extends DataClass implements Insertable<SpaceSyncState> {
  final String spaceId;
  final String clientId;
  final String epoch;
  final String cursorsJson;
  final String status;
  final String revokedScopesJson;
  const SpaceSyncState({
    required this.spaceId,
    required this.clientId,
    required this.epoch,
    required this.cursorsJson,
    required this.status,
    required this.revokedScopesJson,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['space_id'] = Variable<String>(spaceId);
    map['client_id'] = Variable<String>(clientId);
    map['epoch'] = Variable<String>(epoch);
    map['cursors_json'] = Variable<String>(cursorsJson);
    map['status'] = Variable<String>(status);
    map['revoked_scopes_json'] = Variable<String>(revokedScopesJson);
    return map;
  }

  SyncStatesCompanion toCompanion(bool nullToAbsent) {
    return SyncStatesCompanion(
      spaceId: Value(spaceId),
      clientId: Value(clientId),
      epoch: Value(epoch),
      cursorsJson: Value(cursorsJson),
      status: Value(status),
      revokedScopesJson: Value(revokedScopesJson),
    );
  }

  factory SpaceSyncState.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SpaceSyncState(
      spaceId: serializer.fromJson<String>(json['spaceId']),
      clientId: serializer.fromJson<String>(json['clientId']),
      epoch: serializer.fromJson<String>(json['epoch']),
      cursorsJson: serializer.fromJson<String>(json['cursorsJson']),
      status: serializer.fromJson<String>(json['status']),
      revokedScopesJson: serializer.fromJson<String>(json['revokedScopesJson']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'spaceId': serializer.toJson<String>(spaceId),
      'clientId': serializer.toJson<String>(clientId),
      'epoch': serializer.toJson<String>(epoch),
      'cursorsJson': serializer.toJson<String>(cursorsJson),
      'status': serializer.toJson<String>(status),
      'revokedScopesJson': serializer.toJson<String>(revokedScopesJson),
    };
  }

  SpaceSyncState copyWith({
    String? spaceId,
    String? clientId,
    String? epoch,
    String? cursorsJson,
    String? status,
    String? revokedScopesJson,
  }) => SpaceSyncState(
    spaceId: spaceId ?? this.spaceId,
    clientId: clientId ?? this.clientId,
    epoch: epoch ?? this.epoch,
    cursorsJson: cursorsJson ?? this.cursorsJson,
    status: status ?? this.status,
    revokedScopesJson: revokedScopesJson ?? this.revokedScopesJson,
  );
  SpaceSyncState copyWithCompanion(SyncStatesCompanion data) {
    return SpaceSyncState(
      spaceId: data.spaceId.present ? data.spaceId.value : this.spaceId,
      clientId: data.clientId.present ? data.clientId.value : this.clientId,
      epoch: data.epoch.present ? data.epoch.value : this.epoch,
      cursorsJson: data.cursorsJson.present
          ? data.cursorsJson.value
          : this.cursorsJson,
      status: data.status.present ? data.status.value : this.status,
      revokedScopesJson: data.revokedScopesJson.present
          ? data.revokedScopesJson.value
          : this.revokedScopesJson,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SpaceSyncState(')
          ..write('spaceId: $spaceId, ')
          ..write('clientId: $clientId, ')
          ..write('epoch: $epoch, ')
          ..write('cursorsJson: $cursorsJson, ')
          ..write('status: $status, ')
          ..write('revokedScopesJson: $revokedScopesJson')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    spaceId,
    clientId,
    epoch,
    cursorsJson,
    status,
    revokedScopesJson,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SpaceSyncState &&
          other.spaceId == this.spaceId &&
          other.clientId == this.clientId &&
          other.epoch == this.epoch &&
          other.cursorsJson == this.cursorsJson &&
          other.status == this.status &&
          other.revokedScopesJson == this.revokedScopesJson);
}

class SyncStatesCompanion extends UpdateCompanion<SpaceSyncState> {
  final Value<String> spaceId;
  final Value<String> clientId;
  final Value<String> epoch;
  final Value<String> cursorsJson;
  final Value<String> status;
  final Value<String> revokedScopesJson;
  final Value<int> rowid;
  const SyncStatesCompanion({
    this.spaceId = const Value.absent(),
    this.clientId = const Value.absent(),
    this.epoch = const Value.absent(),
    this.cursorsJson = const Value.absent(),
    this.status = const Value.absent(),
    this.revokedScopesJson = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SyncStatesCompanion.insert({
    required String spaceId,
    required String clientId,
    required String epoch,
    this.cursorsJson = const Value.absent(),
    this.status = const Value.absent(),
    this.revokedScopesJson = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : spaceId = Value(spaceId),
       clientId = Value(clientId),
       epoch = Value(epoch);
  static Insertable<SpaceSyncState> custom({
    Expression<String>? spaceId,
    Expression<String>? clientId,
    Expression<String>? epoch,
    Expression<String>? cursorsJson,
    Expression<String>? status,
    Expression<String>? revokedScopesJson,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (spaceId != null) 'space_id': spaceId,
      if (clientId != null) 'client_id': clientId,
      if (epoch != null) 'epoch': epoch,
      if (cursorsJson != null) 'cursors_json': cursorsJson,
      if (status != null) 'status': status,
      if (revokedScopesJson != null) 'revoked_scopes_json': revokedScopesJson,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SyncStatesCompanion copyWith({
    Value<String>? spaceId,
    Value<String>? clientId,
    Value<String>? epoch,
    Value<String>? cursorsJson,
    Value<String>? status,
    Value<String>? revokedScopesJson,
    Value<int>? rowid,
  }) {
    return SyncStatesCompanion(
      spaceId: spaceId ?? this.spaceId,
      clientId: clientId ?? this.clientId,
      epoch: epoch ?? this.epoch,
      cursorsJson: cursorsJson ?? this.cursorsJson,
      status: status ?? this.status,
      revokedScopesJson: revokedScopesJson ?? this.revokedScopesJson,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (spaceId.present) {
      map['space_id'] = Variable<String>(spaceId.value);
    }
    if (clientId.present) {
      map['client_id'] = Variable<String>(clientId.value);
    }
    if (epoch.present) {
      map['epoch'] = Variable<String>(epoch.value);
    }
    if (cursorsJson.present) {
      map['cursors_json'] = Variable<String>(cursorsJson.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (revokedScopesJson.present) {
      map['revoked_scopes_json'] = Variable<String>(revokedScopesJson.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SyncStatesCompanion(')
          ..write('spaceId: $spaceId, ')
          ..write('clientId: $clientId, ')
          ..write('epoch: $epoch, ')
          ..write('cursorsJson: $cursorsJson, ')
          ..write('status: $status, ')
          ..write('revokedScopesJson: $revokedScopesJson, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SyncConflictsTable extends SyncConflicts
    with TableInfo<$SyncConflictsTable, StoredConflict> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SyncConflictsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _spaceIdMeta = const VerificationMeta(
    'spaceId',
  );
  @override
  late final GeneratedColumn<String> spaceId = GeneratedColumn<String>(
    'space_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES local_spaces (id)',
    ),
  );
  static const VerificationMeta _operationIdMeta = const VerificationMeta(
    'operationId',
  );
  @override
  late final GeneratedColumn<String> operationId = GeneratedColumn<String>(
    'operation_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _scopeIdMeta = const VerificationMeta(
    'scopeId',
  );
  @override
  late final GeneratedColumn<String> scopeId = GeneratedColumn<String>(
    'scope_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _codeMeta = const VerificationMeta('code');
  @override
  late final GeneratedColumn<String> code = GeneratedColumn<String>(
    'code',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _baseJsonMeta = const VerificationMeta(
    'baseJson',
  );
  @override
  late final GeneratedColumn<String> baseJson = GeneratedColumn<String>(
    'base_json',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _localJsonMeta = const VerificationMeta(
    'localJson',
  );
  @override
  late final GeneratedColumn<String> localJson = GeneratedColumn<String>(
    'local_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _serverJsonMeta = const VerificationMeta(
    'serverJson',
  );
  @override
  late final GeneratedColumn<String> serverJson = GeneratedColumn<String>(
    'server_json',
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
  @override
  List<GeneratedColumn> get $columns => [
    spaceId,
    operationId,
    scopeId,
    code,
    baseJson,
    localJson,
    serverJson,
    createdAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sync_conflicts';
  @override
  VerificationContext validateIntegrity(
    Insertable<StoredConflict> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('space_id')) {
      context.handle(
        _spaceIdMeta,
        spaceId.isAcceptableOrUnknown(data['space_id']!, _spaceIdMeta),
      );
    } else if (isInserting) {
      context.missing(_spaceIdMeta);
    }
    if (data.containsKey('operation_id')) {
      context.handle(
        _operationIdMeta,
        operationId.isAcceptableOrUnknown(
          data['operation_id']!,
          _operationIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_operationIdMeta);
    }
    if (data.containsKey('scope_id')) {
      context.handle(
        _scopeIdMeta,
        scopeId.isAcceptableOrUnknown(data['scope_id']!, _scopeIdMeta),
      );
    } else if (isInserting) {
      context.missing(_scopeIdMeta);
    }
    if (data.containsKey('code')) {
      context.handle(
        _codeMeta,
        code.isAcceptableOrUnknown(data['code']!, _codeMeta),
      );
    } else if (isInserting) {
      context.missing(_codeMeta);
    }
    if (data.containsKey('base_json')) {
      context.handle(
        _baseJsonMeta,
        baseJson.isAcceptableOrUnknown(data['base_json']!, _baseJsonMeta),
      );
    }
    if (data.containsKey('local_json')) {
      context.handle(
        _localJsonMeta,
        localJson.isAcceptableOrUnknown(data['local_json']!, _localJsonMeta),
      );
    } else if (isInserting) {
      context.missing(_localJsonMeta);
    }
    if (data.containsKey('server_json')) {
      context.handle(
        _serverJsonMeta,
        serverJson.isAcceptableOrUnknown(data['server_json']!, _serverJsonMeta),
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
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {spaceId, operationId};
  @override
  StoredConflict map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return StoredConflict(
      spaceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}space_id'],
      )!,
      operationId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}operation_id'],
      )!,
      scopeId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}scope_id'],
      )!,
      code: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}code'],
      )!,
      baseJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}base_json'],
      ),
      localJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}local_json'],
      )!,
      serverJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}server_json'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
    );
  }

  @override
  $SyncConflictsTable createAlias(String alias) {
    return $SyncConflictsTable(attachedDatabase, alias);
  }
}

class StoredConflict extends DataClass implements Insertable<StoredConflict> {
  final String spaceId;
  final String operationId;
  final String scopeId;
  final String code;
  final String? baseJson;
  final String localJson;
  final String? serverJson;
  final DateTime createdAt;
  const StoredConflict({
    required this.spaceId,
    required this.operationId,
    required this.scopeId,
    required this.code,
    this.baseJson,
    required this.localJson,
    this.serverJson,
    required this.createdAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['space_id'] = Variable<String>(spaceId);
    map['operation_id'] = Variable<String>(operationId);
    map['scope_id'] = Variable<String>(scopeId);
    map['code'] = Variable<String>(code);
    if (!nullToAbsent || baseJson != null) {
      map['base_json'] = Variable<String>(baseJson);
    }
    map['local_json'] = Variable<String>(localJson);
    if (!nullToAbsent || serverJson != null) {
      map['server_json'] = Variable<String>(serverJson);
    }
    map['created_at'] = Variable<DateTime>(createdAt);
    return map;
  }

  SyncConflictsCompanion toCompanion(bool nullToAbsent) {
    return SyncConflictsCompanion(
      spaceId: Value(spaceId),
      operationId: Value(operationId),
      scopeId: Value(scopeId),
      code: Value(code),
      baseJson: baseJson == null && nullToAbsent
          ? const Value.absent()
          : Value(baseJson),
      localJson: Value(localJson),
      serverJson: serverJson == null && nullToAbsent
          ? const Value.absent()
          : Value(serverJson),
      createdAt: Value(createdAt),
    );
  }

  factory StoredConflict.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return StoredConflict(
      spaceId: serializer.fromJson<String>(json['spaceId']),
      operationId: serializer.fromJson<String>(json['operationId']),
      scopeId: serializer.fromJson<String>(json['scopeId']),
      code: serializer.fromJson<String>(json['code']),
      baseJson: serializer.fromJson<String?>(json['baseJson']),
      localJson: serializer.fromJson<String>(json['localJson']),
      serverJson: serializer.fromJson<String?>(json['serverJson']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'spaceId': serializer.toJson<String>(spaceId),
      'operationId': serializer.toJson<String>(operationId),
      'scopeId': serializer.toJson<String>(scopeId),
      'code': serializer.toJson<String>(code),
      'baseJson': serializer.toJson<String?>(baseJson),
      'localJson': serializer.toJson<String>(localJson),
      'serverJson': serializer.toJson<String?>(serverJson),
      'createdAt': serializer.toJson<DateTime>(createdAt),
    };
  }

  StoredConflict copyWith({
    String? spaceId,
    String? operationId,
    String? scopeId,
    String? code,
    Value<String?> baseJson = const Value.absent(),
    String? localJson,
    Value<String?> serverJson = const Value.absent(),
    DateTime? createdAt,
  }) => StoredConflict(
    spaceId: spaceId ?? this.spaceId,
    operationId: operationId ?? this.operationId,
    scopeId: scopeId ?? this.scopeId,
    code: code ?? this.code,
    baseJson: baseJson.present ? baseJson.value : this.baseJson,
    localJson: localJson ?? this.localJson,
    serverJson: serverJson.present ? serverJson.value : this.serverJson,
    createdAt: createdAt ?? this.createdAt,
  );
  StoredConflict copyWithCompanion(SyncConflictsCompanion data) {
    return StoredConflict(
      spaceId: data.spaceId.present ? data.spaceId.value : this.spaceId,
      operationId: data.operationId.present
          ? data.operationId.value
          : this.operationId,
      scopeId: data.scopeId.present ? data.scopeId.value : this.scopeId,
      code: data.code.present ? data.code.value : this.code,
      baseJson: data.baseJson.present ? data.baseJson.value : this.baseJson,
      localJson: data.localJson.present ? data.localJson.value : this.localJson,
      serverJson: data.serverJson.present
          ? data.serverJson.value
          : this.serverJson,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('StoredConflict(')
          ..write('spaceId: $spaceId, ')
          ..write('operationId: $operationId, ')
          ..write('scopeId: $scopeId, ')
          ..write('code: $code, ')
          ..write('baseJson: $baseJson, ')
          ..write('localJson: $localJson, ')
          ..write('serverJson: $serverJson, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    spaceId,
    operationId,
    scopeId,
    code,
    baseJson,
    localJson,
    serverJson,
    createdAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is StoredConflict &&
          other.spaceId == this.spaceId &&
          other.operationId == this.operationId &&
          other.scopeId == this.scopeId &&
          other.code == this.code &&
          other.baseJson == this.baseJson &&
          other.localJson == this.localJson &&
          other.serverJson == this.serverJson &&
          other.createdAt == this.createdAt);
}

class SyncConflictsCompanion extends UpdateCompanion<StoredConflict> {
  final Value<String> spaceId;
  final Value<String> operationId;
  final Value<String> scopeId;
  final Value<String> code;
  final Value<String?> baseJson;
  final Value<String> localJson;
  final Value<String?> serverJson;
  final Value<DateTime> createdAt;
  final Value<int> rowid;
  const SyncConflictsCompanion({
    this.spaceId = const Value.absent(),
    this.operationId = const Value.absent(),
    this.scopeId = const Value.absent(),
    this.code = const Value.absent(),
    this.baseJson = const Value.absent(),
    this.localJson = const Value.absent(),
    this.serverJson = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SyncConflictsCompanion.insert({
    required String spaceId,
    required String operationId,
    required String scopeId,
    required String code,
    this.baseJson = const Value.absent(),
    required String localJson,
    this.serverJson = const Value.absent(),
    required DateTime createdAt,
    this.rowid = const Value.absent(),
  }) : spaceId = Value(spaceId),
       operationId = Value(operationId),
       scopeId = Value(scopeId),
       code = Value(code),
       localJson = Value(localJson),
       createdAt = Value(createdAt);
  static Insertable<StoredConflict> custom({
    Expression<String>? spaceId,
    Expression<String>? operationId,
    Expression<String>? scopeId,
    Expression<String>? code,
    Expression<String>? baseJson,
    Expression<String>? localJson,
    Expression<String>? serverJson,
    Expression<DateTime>? createdAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (spaceId != null) 'space_id': spaceId,
      if (operationId != null) 'operation_id': operationId,
      if (scopeId != null) 'scope_id': scopeId,
      if (code != null) 'code': code,
      if (baseJson != null) 'base_json': baseJson,
      if (localJson != null) 'local_json': localJson,
      if (serverJson != null) 'server_json': serverJson,
      if (createdAt != null) 'created_at': createdAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SyncConflictsCompanion copyWith({
    Value<String>? spaceId,
    Value<String>? operationId,
    Value<String>? scopeId,
    Value<String>? code,
    Value<String?>? baseJson,
    Value<String>? localJson,
    Value<String?>? serverJson,
    Value<DateTime>? createdAt,
    Value<int>? rowid,
  }) {
    return SyncConflictsCompanion(
      spaceId: spaceId ?? this.spaceId,
      operationId: operationId ?? this.operationId,
      scopeId: scopeId ?? this.scopeId,
      code: code ?? this.code,
      baseJson: baseJson ?? this.baseJson,
      localJson: localJson ?? this.localJson,
      serverJson: serverJson ?? this.serverJson,
      createdAt: createdAt ?? this.createdAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (spaceId.present) {
      map['space_id'] = Variable<String>(spaceId.value);
    }
    if (operationId.present) {
      map['operation_id'] = Variable<String>(operationId.value);
    }
    if (scopeId.present) {
      map['scope_id'] = Variable<String>(scopeId.value);
    }
    if (code.present) {
      map['code'] = Variable<String>(code.value);
    }
    if (baseJson.present) {
      map['base_json'] = Variable<String>(baseJson.value);
    }
    if (localJson.present) {
      map['local_json'] = Variable<String>(localJson.value);
    }
    if (serverJson.present) {
      map['server_json'] = Variable<String>(serverJson.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SyncConflictsCompanion(')
          ..write('spaceId: $spaceId, ')
          ..write('operationId: $operationId, ')
          ..write('scopeId: $scopeId, ')
          ..write('code: $code, ')
          ..write('baseJson: $baseJson, ')
          ..write('localJson: $localJson, ')
          ..write('serverJson: $serverJson, ')
          ..write('createdAt: $createdAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SyncRecoveryBackupsTable extends SyncRecoveryBackups
    with TableInfo<$SyncRecoveryBackupsTable, RecoveryBackup> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SyncRecoveryBackupsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _spaceIdMeta = const VerificationMeta(
    'spaceId',
  );
  @override
  late final GeneratedColumn<String> spaceId = GeneratedColumn<String>(
    'space_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES local_spaces (id)',
    ),
  );
  static const VerificationMeta _reasonMeta = const VerificationMeta('reason');
  @override
  late final GeneratedColumn<String> reason = GeneratedColumn<String>(
    'reason',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _oldEpochMeta = const VerificationMeta(
    'oldEpoch',
  );
  @override
  late final GeneratedColumn<String> oldEpoch = GeneratedColumn<String>(
    'old_epoch',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _dataJsonMeta = const VerificationMeta(
    'dataJson',
  );
  @override
  late final GeneratedColumn<String> dataJson = GeneratedColumn<String>(
    'data_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
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
  @override
  List<GeneratedColumn> get $columns => [
    id,
    spaceId,
    reason,
    oldEpoch,
    dataJson,
    createdAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sync_recovery_backups';
  @override
  VerificationContext validateIntegrity(
    Insertable<RecoveryBackup> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('space_id')) {
      context.handle(
        _spaceIdMeta,
        spaceId.isAcceptableOrUnknown(data['space_id']!, _spaceIdMeta),
      );
    } else if (isInserting) {
      context.missing(_spaceIdMeta);
    }
    if (data.containsKey('reason')) {
      context.handle(
        _reasonMeta,
        reason.isAcceptableOrUnknown(data['reason']!, _reasonMeta),
      );
    } else if (isInserting) {
      context.missing(_reasonMeta);
    }
    if (data.containsKey('old_epoch')) {
      context.handle(
        _oldEpochMeta,
        oldEpoch.isAcceptableOrUnknown(data['old_epoch']!, _oldEpochMeta),
      );
    } else if (isInserting) {
      context.missing(_oldEpochMeta);
    }
    if (data.containsKey('data_json')) {
      context.handle(
        _dataJsonMeta,
        dataJson.isAcceptableOrUnknown(data['data_json']!, _dataJsonMeta),
      );
    } else if (isInserting) {
      context.missing(_dataJsonMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  RecoveryBackup map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return RecoveryBackup(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      spaceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}space_id'],
      )!,
      reason: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}reason'],
      )!,
      oldEpoch: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}old_epoch'],
      )!,
      dataJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}data_json'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
    );
  }

  @override
  $SyncRecoveryBackupsTable createAlias(String alias) {
    return $SyncRecoveryBackupsTable(attachedDatabase, alias);
  }
}

class RecoveryBackup extends DataClass implements Insertable<RecoveryBackup> {
  final String id;
  final String spaceId;
  final String reason;
  final String oldEpoch;
  final String dataJson;
  final DateTime createdAt;
  const RecoveryBackup({
    required this.id,
    required this.spaceId,
    required this.reason,
    required this.oldEpoch,
    required this.dataJson,
    required this.createdAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['space_id'] = Variable<String>(spaceId);
    map['reason'] = Variable<String>(reason);
    map['old_epoch'] = Variable<String>(oldEpoch);
    map['data_json'] = Variable<String>(dataJson);
    map['created_at'] = Variable<DateTime>(createdAt);
    return map;
  }

  SyncRecoveryBackupsCompanion toCompanion(bool nullToAbsent) {
    return SyncRecoveryBackupsCompanion(
      id: Value(id),
      spaceId: Value(spaceId),
      reason: Value(reason),
      oldEpoch: Value(oldEpoch),
      dataJson: Value(dataJson),
      createdAt: Value(createdAt),
    );
  }

  factory RecoveryBackup.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return RecoveryBackup(
      id: serializer.fromJson<String>(json['id']),
      spaceId: serializer.fromJson<String>(json['spaceId']),
      reason: serializer.fromJson<String>(json['reason']),
      oldEpoch: serializer.fromJson<String>(json['oldEpoch']),
      dataJson: serializer.fromJson<String>(json['dataJson']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'spaceId': serializer.toJson<String>(spaceId),
      'reason': serializer.toJson<String>(reason),
      'oldEpoch': serializer.toJson<String>(oldEpoch),
      'dataJson': serializer.toJson<String>(dataJson),
      'createdAt': serializer.toJson<DateTime>(createdAt),
    };
  }

  RecoveryBackup copyWith({
    String? id,
    String? spaceId,
    String? reason,
    String? oldEpoch,
    String? dataJson,
    DateTime? createdAt,
  }) => RecoveryBackup(
    id: id ?? this.id,
    spaceId: spaceId ?? this.spaceId,
    reason: reason ?? this.reason,
    oldEpoch: oldEpoch ?? this.oldEpoch,
    dataJson: dataJson ?? this.dataJson,
    createdAt: createdAt ?? this.createdAt,
  );
  RecoveryBackup copyWithCompanion(SyncRecoveryBackupsCompanion data) {
    return RecoveryBackup(
      id: data.id.present ? data.id.value : this.id,
      spaceId: data.spaceId.present ? data.spaceId.value : this.spaceId,
      reason: data.reason.present ? data.reason.value : this.reason,
      oldEpoch: data.oldEpoch.present ? data.oldEpoch.value : this.oldEpoch,
      dataJson: data.dataJson.present ? data.dataJson.value : this.dataJson,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('RecoveryBackup(')
          ..write('id: $id, ')
          ..write('spaceId: $spaceId, ')
          ..write('reason: $reason, ')
          ..write('oldEpoch: $oldEpoch, ')
          ..write('dataJson: $dataJson, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, spaceId, reason, oldEpoch, dataJson, createdAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is RecoveryBackup &&
          other.id == this.id &&
          other.spaceId == this.spaceId &&
          other.reason == this.reason &&
          other.oldEpoch == this.oldEpoch &&
          other.dataJson == this.dataJson &&
          other.createdAt == this.createdAt);
}

class SyncRecoveryBackupsCompanion extends UpdateCompanion<RecoveryBackup> {
  final Value<String> id;
  final Value<String> spaceId;
  final Value<String> reason;
  final Value<String> oldEpoch;
  final Value<String> dataJson;
  final Value<DateTime> createdAt;
  final Value<int> rowid;
  const SyncRecoveryBackupsCompanion({
    this.id = const Value.absent(),
    this.spaceId = const Value.absent(),
    this.reason = const Value.absent(),
    this.oldEpoch = const Value.absent(),
    this.dataJson = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SyncRecoveryBackupsCompanion.insert({
    required String id,
    required String spaceId,
    required String reason,
    required String oldEpoch,
    required String dataJson,
    required DateTime createdAt,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       spaceId = Value(spaceId),
       reason = Value(reason),
       oldEpoch = Value(oldEpoch),
       dataJson = Value(dataJson),
       createdAt = Value(createdAt);
  static Insertable<RecoveryBackup> custom({
    Expression<String>? id,
    Expression<String>? spaceId,
    Expression<String>? reason,
    Expression<String>? oldEpoch,
    Expression<String>? dataJson,
    Expression<DateTime>? createdAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (spaceId != null) 'space_id': spaceId,
      if (reason != null) 'reason': reason,
      if (oldEpoch != null) 'old_epoch': oldEpoch,
      if (dataJson != null) 'data_json': dataJson,
      if (createdAt != null) 'created_at': createdAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SyncRecoveryBackupsCompanion copyWith({
    Value<String>? id,
    Value<String>? spaceId,
    Value<String>? reason,
    Value<String>? oldEpoch,
    Value<String>? dataJson,
    Value<DateTime>? createdAt,
    Value<int>? rowid,
  }) {
    return SyncRecoveryBackupsCompanion(
      id: id ?? this.id,
      spaceId: spaceId ?? this.spaceId,
      reason: reason ?? this.reason,
      oldEpoch: oldEpoch ?? this.oldEpoch,
      dataJson: dataJson ?? this.dataJson,
      createdAt: createdAt ?? this.createdAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (spaceId.present) {
      map['space_id'] = Variable<String>(spaceId.value);
    }
    if (reason.present) {
      map['reason'] = Variable<String>(reason.value);
    }
    if (oldEpoch.present) {
      map['old_epoch'] = Variable<String>(oldEpoch.value);
    }
    if (dataJson.present) {
      map['data_json'] = Variable<String>(dataJson.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SyncRecoveryBackupsCompanion(')
          ..write('id: $id, ')
          ..write('spaceId: $spaceId, ')
          ..write('reason: $reason, ')
          ..write('oldEpoch: $oldEpoch, ')
          ..write('dataJson: $dataJson, ')
          ..write('createdAt: $createdAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SnapshotPagesTable extends SnapshotPages
    with TableInfo<$SnapshotPagesTable, StagedSnapshotPage> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SnapshotPagesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _spaceIdMeta = const VerificationMeta(
    'spaceId',
  );
  @override
  late final GeneratedColumn<String> spaceId = GeneratedColumn<String>(
    'space_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES local_spaces (id)',
    ),
  );
  static const VerificationMeta _snapshotIdMeta = const VerificationMeta(
    'snapshotId',
  );
  @override
  late final GeneratedColumn<String> snapshotId = GeneratedColumn<String>(
    'snapshot_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _pageIndexMeta = const VerificationMeta(
    'pageIndex',
  );
  @override
  late final GeneratedColumn<int> pageIndex = GeneratedColumn<int>(
    'page_index',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _itemsJsonMeta = const VerificationMeta(
    'itemsJson',
  );
  @override
  late final GeneratedColumn<String> itemsJson = GeneratedColumn<String>(
    'items_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sha256Meta = const VerificationMeta('sha256');
  @override
  late final GeneratedColumn<String> sha256 = GeneratedColumn<String>(
    'sha256',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    spaceId,
    snapshotId,
    pageIndex,
    itemsJson,
    sha256,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'snapshot_pages';
  @override
  VerificationContext validateIntegrity(
    Insertable<StagedSnapshotPage> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('space_id')) {
      context.handle(
        _spaceIdMeta,
        spaceId.isAcceptableOrUnknown(data['space_id']!, _spaceIdMeta),
      );
    } else if (isInserting) {
      context.missing(_spaceIdMeta);
    }
    if (data.containsKey('snapshot_id')) {
      context.handle(
        _snapshotIdMeta,
        snapshotId.isAcceptableOrUnknown(data['snapshot_id']!, _snapshotIdMeta),
      );
    } else if (isInserting) {
      context.missing(_snapshotIdMeta);
    }
    if (data.containsKey('page_index')) {
      context.handle(
        _pageIndexMeta,
        pageIndex.isAcceptableOrUnknown(data['page_index']!, _pageIndexMeta),
      );
    } else if (isInserting) {
      context.missing(_pageIndexMeta);
    }
    if (data.containsKey('items_json')) {
      context.handle(
        _itemsJsonMeta,
        itemsJson.isAcceptableOrUnknown(data['items_json']!, _itemsJsonMeta),
      );
    } else if (isInserting) {
      context.missing(_itemsJsonMeta);
    }
    if (data.containsKey('sha256')) {
      context.handle(
        _sha256Meta,
        sha256.isAcceptableOrUnknown(data['sha256']!, _sha256Meta),
      );
    } else if (isInserting) {
      context.missing(_sha256Meta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {spaceId, snapshotId, pageIndex};
  @override
  StagedSnapshotPage map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return StagedSnapshotPage(
      spaceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}space_id'],
      )!,
      snapshotId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}snapshot_id'],
      )!,
      pageIndex: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}page_index'],
      )!,
      itemsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}items_json'],
      )!,
      sha256: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sha256'],
      )!,
    );
  }

  @override
  $SnapshotPagesTable createAlias(String alias) {
    return $SnapshotPagesTable(attachedDatabase, alias);
  }
}

class StagedSnapshotPage extends DataClass
    implements Insertable<StagedSnapshotPage> {
  final String spaceId;
  final String snapshotId;
  final int pageIndex;
  final String itemsJson;
  final String sha256;
  const StagedSnapshotPage({
    required this.spaceId,
    required this.snapshotId,
    required this.pageIndex,
    required this.itemsJson,
    required this.sha256,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['space_id'] = Variable<String>(spaceId);
    map['snapshot_id'] = Variable<String>(snapshotId);
    map['page_index'] = Variable<int>(pageIndex);
    map['items_json'] = Variable<String>(itemsJson);
    map['sha256'] = Variable<String>(sha256);
    return map;
  }

  SnapshotPagesCompanion toCompanion(bool nullToAbsent) {
    return SnapshotPagesCompanion(
      spaceId: Value(spaceId),
      snapshotId: Value(snapshotId),
      pageIndex: Value(pageIndex),
      itemsJson: Value(itemsJson),
      sha256: Value(sha256),
    );
  }

  factory StagedSnapshotPage.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return StagedSnapshotPage(
      spaceId: serializer.fromJson<String>(json['spaceId']),
      snapshotId: serializer.fromJson<String>(json['snapshotId']),
      pageIndex: serializer.fromJson<int>(json['pageIndex']),
      itemsJson: serializer.fromJson<String>(json['itemsJson']),
      sha256: serializer.fromJson<String>(json['sha256']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'spaceId': serializer.toJson<String>(spaceId),
      'snapshotId': serializer.toJson<String>(snapshotId),
      'pageIndex': serializer.toJson<int>(pageIndex),
      'itemsJson': serializer.toJson<String>(itemsJson),
      'sha256': serializer.toJson<String>(sha256),
    };
  }

  StagedSnapshotPage copyWith({
    String? spaceId,
    String? snapshotId,
    int? pageIndex,
    String? itemsJson,
    String? sha256,
  }) => StagedSnapshotPage(
    spaceId: spaceId ?? this.spaceId,
    snapshotId: snapshotId ?? this.snapshotId,
    pageIndex: pageIndex ?? this.pageIndex,
    itemsJson: itemsJson ?? this.itemsJson,
    sha256: sha256 ?? this.sha256,
  );
  StagedSnapshotPage copyWithCompanion(SnapshotPagesCompanion data) {
    return StagedSnapshotPage(
      spaceId: data.spaceId.present ? data.spaceId.value : this.spaceId,
      snapshotId: data.snapshotId.present
          ? data.snapshotId.value
          : this.snapshotId,
      pageIndex: data.pageIndex.present ? data.pageIndex.value : this.pageIndex,
      itemsJson: data.itemsJson.present ? data.itemsJson.value : this.itemsJson,
      sha256: data.sha256.present ? data.sha256.value : this.sha256,
    );
  }

  @override
  String toString() {
    return (StringBuffer('StagedSnapshotPage(')
          ..write('spaceId: $spaceId, ')
          ..write('snapshotId: $snapshotId, ')
          ..write('pageIndex: $pageIndex, ')
          ..write('itemsJson: $itemsJson, ')
          ..write('sha256: $sha256')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(spaceId, snapshotId, pageIndex, itemsJson, sha256);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is StagedSnapshotPage &&
          other.spaceId == this.spaceId &&
          other.snapshotId == this.snapshotId &&
          other.pageIndex == this.pageIndex &&
          other.itemsJson == this.itemsJson &&
          other.sha256 == this.sha256);
}

class SnapshotPagesCompanion extends UpdateCompanion<StagedSnapshotPage> {
  final Value<String> spaceId;
  final Value<String> snapshotId;
  final Value<int> pageIndex;
  final Value<String> itemsJson;
  final Value<String> sha256;
  final Value<int> rowid;
  const SnapshotPagesCompanion({
    this.spaceId = const Value.absent(),
    this.snapshotId = const Value.absent(),
    this.pageIndex = const Value.absent(),
    this.itemsJson = const Value.absent(),
    this.sha256 = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SnapshotPagesCompanion.insert({
    required String spaceId,
    required String snapshotId,
    required int pageIndex,
    required String itemsJson,
    required String sha256,
    this.rowid = const Value.absent(),
  }) : spaceId = Value(spaceId),
       snapshotId = Value(snapshotId),
       pageIndex = Value(pageIndex),
       itemsJson = Value(itemsJson),
       sha256 = Value(sha256);
  static Insertable<StagedSnapshotPage> custom({
    Expression<String>? spaceId,
    Expression<String>? snapshotId,
    Expression<int>? pageIndex,
    Expression<String>? itemsJson,
    Expression<String>? sha256,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (spaceId != null) 'space_id': spaceId,
      if (snapshotId != null) 'snapshot_id': snapshotId,
      if (pageIndex != null) 'page_index': pageIndex,
      if (itemsJson != null) 'items_json': itemsJson,
      if (sha256 != null) 'sha256': sha256,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SnapshotPagesCompanion copyWith({
    Value<String>? spaceId,
    Value<String>? snapshotId,
    Value<int>? pageIndex,
    Value<String>? itemsJson,
    Value<String>? sha256,
    Value<int>? rowid,
  }) {
    return SnapshotPagesCompanion(
      spaceId: spaceId ?? this.spaceId,
      snapshotId: snapshotId ?? this.snapshotId,
      pageIndex: pageIndex ?? this.pageIndex,
      itemsJson: itemsJson ?? this.itemsJson,
      sha256: sha256 ?? this.sha256,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (spaceId.present) {
      map['space_id'] = Variable<String>(spaceId.value);
    }
    if (snapshotId.present) {
      map['snapshot_id'] = Variable<String>(snapshotId.value);
    }
    if (pageIndex.present) {
      map['page_index'] = Variable<int>(pageIndex.value);
    }
    if (itemsJson.present) {
      map['items_json'] = Variable<String>(itemsJson.value);
    }
    if (sha256.present) {
      map['sha256'] = Variable<String>(sha256.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SnapshotPagesCompanion(')
          ..write('spaceId: $spaceId, ')
          ..write('snapshotId: $snapshotId, ')
          ..write('pageIndex: $pageIndex, ')
          ..write('itemsJson: $itemsJson, ')
          ..write('sha256: $sha256, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $GroupPullsTable extends GroupPulls
    with TableInfo<$GroupPullsTable, StoredGroupPull> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $GroupPullsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _spaceIdMeta = const VerificationMeta(
    'spaceId',
  );
  @override
  late final GeneratedColumn<String> spaceId = GeneratedColumn<String>(
    'space_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES local_spaces (id)',
    ),
  );
  static const VerificationMeta _requestIdMeta = const VerificationMeta(
    'requestId',
  );
  @override
  late final GeneratedColumn<String> requestId = GeneratedColumn<String>(
    'request_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _clientIdMeta = const VerificationMeta(
    'clientId',
  );
  @override
  late final GeneratedColumn<String> clientId = GeneratedColumn<String>(
    'client_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _epochMeta = const VerificationMeta('epoch');
  @override
  late final GeneratedColumn<String> epoch = GeneratedColumn<String>(
    'epoch',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _intentJsonMeta = const VerificationMeta(
    'intentJson',
  );
  @override
  late final GeneratedColumn<String> intentJson = GeneratedColumn<String>(
    'intent_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _statusJsonMeta = const VerificationMeta(
    'statusJson',
  );
  @override
  late final GeneratedColumn<String> statusJson = GeneratedColumn<String>(
    'status_json',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _pullIdMeta = const VerificationMeta('pullId');
  @override
  late final GeneratedColumn<String> pullId = GeneratedColumn<String>(
    'pull_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _nextTokenMeta = const VerificationMeta(
    'nextToken',
  );
  @override
  late final GeneratedColumn<String> nextToken = GeneratedColumn<String>(
    'next_token',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _receiveStateJsonMeta = const VerificationMeta(
    'receiveStateJson',
  );
  @override
  late final GeneratedColumn<String> receiveStateJson = GeneratedColumn<String>(
    'receive_state_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _receivedPagesMeta = const VerificationMeta(
    'receivedPages',
  );
  @override
  late final GeneratedColumn<int> receivedPages = GeneratedColumn<int>(
    'received_pages',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _reservedBytesMeta = const VerificationMeta(
    'reservedBytes',
  );
  @override
  late final GeneratedColumn<int> reservedBytes = GeneratedColumn<int>(
    'reserved_bytes',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _installedUnitsMeta = const VerificationMeta(
    'installedUnits',
  );
  @override
  late final GeneratedColumn<int> installedUnits = GeneratedColumn<int>(
    'installed_units',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
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
  @override
  List<GeneratedColumn> get $columns => [
    spaceId,
    requestId,
    clientId,
    epoch,
    intentJson,
    statusJson,
    pullId,
    nextToken,
    receiveStateJson,
    receivedPages,
    reservedBytes,
    installedUnits,
    createdAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'group_pulls';
  @override
  VerificationContext validateIntegrity(
    Insertable<StoredGroupPull> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('space_id')) {
      context.handle(
        _spaceIdMeta,
        spaceId.isAcceptableOrUnknown(data['space_id']!, _spaceIdMeta),
      );
    } else if (isInserting) {
      context.missing(_spaceIdMeta);
    }
    if (data.containsKey('request_id')) {
      context.handle(
        _requestIdMeta,
        requestId.isAcceptableOrUnknown(data['request_id']!, _requestIdMeta),
      );
    } else if (isInserting) {
      context.missing(_requestIdMeta);
    }
    if (data.containsKey('client_id')) {
      context.handle(
        _clientIdMeta,
        clientId.isAcceptableOrUnknown(data['client_id']!, _clientIdMeta),
      );
    } else if (isInserting) {
      context.missing(_clientIdMeta);
    }
    if (data.containsKey('epoch')) {
      context.handle(
        _epochMeta,
        epoch.isAcceptableOrUnknown(data['epoch']!, _epochMeta),
      );
    } else if (isInserting) {
      context.missing(_epochMeta);
    }
    if (data.containsKey('intent_json')) {
      context.handle(
        _intentJsonMeta,
        intentJson.isAcceptableOrUnknown(data['intent_json']!, _intentJsonMeta),
      );
    } else if (isInserting) {
      context.missing(_intentJsonMeta);
    }
    if (data.containsKey('status_json')) {
      context.handle(
        _statusJsonMeta,
        statusJson.isAcceptableOrUnknown(data['status_json']!, _statusJsonMeta),
      );
    }
    if (data.containsKey('pull_id')) {
      context.handle(
        _pullIdMeta,
        pullId.isAcceptableOrUnknown(data['pull_id']!, _pullIdMeta),
      );
    }
    if (data.containsKey('next_token')) {
      context.handle(
        _nextTokenMeta,
        nextToken.isAcceptableOrUnknown(data['next_token']!, _nextTokenMeta),
      );
    }
    if (data.containsKey('receive_state_json')) {
      context.handle(
        _receiveStateJsonMeta,
        receiveStateJson.isAcceptableOrUnknown(
          data['receive_state_json']!,
          _receiveStateJsonMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_receiveStateJsonMeta);
    }
    if (data.containsKey('received_pages')) {
      context.handle(
        _receivedPagesMeta,
        receivedPages.isAcceptableOrUnknown(
          data['received_pages']!,
          _receivedPagesMeta,
        ),
      );
    }
    if (data.containsKey('reserved_bytes')) {
      context.handle(
        _reservedBytesMeta,
        reservedBytes.isAcceptableOrUnknown(
          data['reserved_bytes']!,
          _reservedBytesMeta,
        ),
      );
    }
    if (data.containsKey('installed_units')) {
      context.handle(
        _installedUnitsMeta,
        installedUnits.isAcceptableOrUnknown(
          data['installed_units']!,
          _installedUnitsMeta,
        ),
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
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {spaceId, requestId};
  @override
  StoredGroupPull map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return StoredGroupPull(
      spaceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}space_id'],
      )!,
      requestId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}request_id'],
      )!,
      clientId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}client_id'],
      )!,
      epoch: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}epoch'],
      )!,
      intentJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}intent_json'],
      )!,
      statusJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status_json'],
      ),
      pullId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}pull_id'],
      ),
      nextToken: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}next_token'],
      ),
      receiveStateJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}receive_state_json'],
      )!,
      receivedPages: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}received_pages'],
      )!,
      reservedBytes: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}reserved_bytes'],
      )!,
      installedUnits: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}installed_units'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
    );
  }

  @override
  $GroupPullsTable createAlias(String alias) {
    return $GroupPullsTable(attachedDatabase, alias);
  }
}

class StoredGroupPull extends DataClass implements Insertable<StoredGroupPull> {
  final String spaceId;
  final String requestId;
  final String clientId;
  final String epoch;
  final String intentJson;
  final String? statusJson;
  final String? pullId;
  final String? nextToken;
  final String receiveStateJson;
  final int receivedPages;
  final int reservedBytes;
  final int installedUnits;
  final DateTime createdAt;
  const StoredGroupPull({
    required this.spaceId,
    required this.requestId,
    required this.clientId,
    required this.epoch,
    required this.intentJson,
    this.statusJson,
    this.pullId,
    this.nextToken,
    required this.receiveStateJson,
    required this.receivedPages,
    required this.reservedBytes,
    required this.installedUnits,
    required this.createdAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['space_id'] = Variable<String>(spaceId);
    map['request_id'] = Variable<String>(requestId);
    map['client_id'] = Variable<String>(clientId);
    map['epoch'] = Variable<String>(epoch);
    map['intent_json'] = Variable<String>(intentJson);
    if (!nullToAbsent || statusJson != null) {
      map['status_json'] = Variable<String>(statusJson);
    }
    if (!nullToAbsent || pullId != null) {
      map['pull_id'] = Variable<String>(pullId);
    }
    if (!nullToAbsent || nextToken != null) {
      map['next_token'] = Variable<String>(nextToken);
    }
    map['receive_state_json'] = Variable<String>(receiveStateJson);
    map['received_pages'] = Variable<int>(receivedPages);
    map['reserved_bytes'] = Variable<int>(reservedBytes);
    map['installed_units'] = Variable<int>(installedUnits);
    map['created_at'] = Variable<DateTime>(createdAt);
    return map;
  }

  GroupPullsCompanion toCompanion(bool nullToAbsent) {
    return GroupPullsCompanion(
      spaceId: Value(spaceId),
      requestId: Value(requestId),
      clientId: Value(clientId),
      epoch: Value(epoch),
      intentJson: Value(intentJson),
      statusJson: statusJson == null && nullToAbsent
          ? const Value.absent()
          : Value(statusJson),
      pullId: pullId == null && nullToAbsent
          ? const Value.absent()
          : Value(pullId),
      nextToken: nextToken == null && nullToAbsent
          ? const Value.absent()
          : Value(nextToken),
      receiveStateJson: Value(receiveStateJson),
      receivedPages: Value(receivedPages),
      reservedBytes: Value(reservedBytes),
      installedUnits: Value(installedUnits),
      createdAt: Value(createdAt),
    );
  }

  factory StoredGroupPull.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return StoredGroupPull(
      spaceId: serializer.fromJson<String>(json['spaceId']),
      requestId: serializer.fromJson<String>(json['requestId']),
      clientId: serializer.fromJson<String>(json['clientId']),
      epoch: serializer.fromJson<String>(json['epoch']),
      intentJson: serializer.fromJson<String>(json['intentJson']),
      statusJson: serializer.fromJson<String?>(json['statusJson']),
      pullId: serializer.fromJson<String?>(json['pullId']),
      nextToken: serializer.fromJson<String?>(json['nextToken']),
      receiveStateJson: serializer.fromJson<String>(json['receiveStateJson']),
      receivedPages: serializer.fromJson<int>(json['receivedPages']),
      reservedBytes: serializer.fromJson<int>(json['reservedBytes']),
      installedUnits: serializer.fromJson<int>(json['installedUnits']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'spaceId': serializer.toJson<String>(spaceId),
      'requestId': serializer.toJson<String>(requestId),
      'clientId': serializer.toJson<String>(clientId),
      'epoch': serializer.toJson<String>(epoch),
      'intentJson': serializer.toJson<String>(intentJson),
      'statusJson': serializer.toJson<String?>(statusJson),
      'pullId': serializer.toJson<String?>(pullId),
      'nextToken': serializer.toJson<String?>(nextToken),
      'receiveStateJson': serializer.toJson<String>(receiveStateJson),
      'receivedPages': serializer.toJson<int>(receivedPages),
      'reservedBytes': serializer.toJson<int>(reservedBytes),
      'installedUnits': serializer.toJson<int>(installedUnits),
      'createdAt': serializer.toJson<DateTime>(createdAt),
    };
  }

  StoredGroupPull copyWith({
    String? spaceId,
    String? requestId,
    String? clientId,
    String? epoch,
    String? intentJson,
    Value<String?> statusJson = const Value.absent(),
    Value<String?> pullId = const Value.absent(),
    Value<String?> nextToken = const Value.absent(),
    String? receiveStateJson,
    int? receivedPages,
    int? reservedBytes,
    int? installedUnits,
    DateTime? createdAt,
  }) => StoredGroupPull(
    spaceId: spaceId ?? this.spaceId,
    requestId: requestId ?? this.requestId,
    clientId: clientId ?? this.clientId,
    epoch: epoch ?? this.epoch,
    intentJson: intentJson ?? this.intentJson,
    statusJson: statusJson.present ? statusJson.value : this.statusJson,
    pullId: pullId.present ? pullId.value : this.pullId,
    nextToken: nextToken.present ? nextToken.value : this.nextToken,
    receiveStateJson: receiveStateJson ?? this.receiveStateJson,
    receivedPages: receivedPages ?? this.receivedPages,
    reservedBytes: reservedBytes ?? this.reservedBytes,
    installedUnits: installedUnits ?? this.installedUnits,
    createdAt: createdAt ?? this.createdAt,
  );
  StoredGroupPull copyWithCompanion(GroupPullsCompanion data) {
    return StoredGroupPull(
      spaceId: data.spaceId.present ? data.spaceId.value : this.spaceId,
      requestId: data.requestId.present ? data.requestId.value : this.requestId,
      clientId: data.clientId.present ? data.clientId.value : this.clientId,
      epoch: data.epoch.present ? data.epoch.value : this.epoch,
      intentJson: data.intentJson.present
          ? data.intentJson.value
          : this.intentJson,
      statusJson: data.statusJson.present
          ? data.statusJson.value
          : this.statusJson,
      pullId: data.pullId.present ? data.pullId.value : this.pullId,
      nextToken: data.nextToken.present ? data.nextToken.value : this.nextToken,
      receiveStateJson: data.receiveStateJson.present
          ? data.receiveStateJson.value
          : this.receiveStateJson,
      receivedPages: data.receivedPages.present
          ? data.receivedPages.value
          : this.receivedPages,
      reservedBytes: data.reservedBytes.present
          ? data.reservedBytes.value
          : this.reservedBytes,
      installedUnits: data.installedUnits.present
          ? data.installedUnits.value
          : this.installedUnits,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('StoredGroupPull(')
          ..write('spaceId: $spaceId, ')
          ..write('requestId: $requestId, ')
          ..write('clientId: $clientId, ')
          ..write('epoch: $epoch, ')
          ..write('intentJson: $intentJson, ')
          ..write('statusJson: $statusJson, ')
          ..write('pullId: $pullId, ')
          ..write('nextToken: $nextToken, ')
          ..write('receiveStateJson: $receiveStateJson, ')
          ..write('receivedPages: $receivedPages, ')
          ..write('reservedBytes: $reservedBytes, ')
          ..write('installedUnits: $installedUnits, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    spaceId,
    requestId,
    clientId,
    epoch,
    intentJson,
    statusJson,
    pullId,
    nextToken,
    receiveStateJson,
    receivedPages,
    reservedBytes,
    installedUnits,
    createdAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is StoredGroupPull &&
          other.spaceId == this.spaceId &&
          other.requestId == this.requestId &&
          other.clientId == this.clientId &&
          other.epoch == this.epoch &&
          other.intentJson == this.intentJson &&
          other.statusJson == this.statusJson &&
          other.pullId == this.pullId &&
          other.nextToken == this.nextToken &&
          other.receiveStateJson == this.receiveStateJson &&
          other.receivedPages == this.receivedPages &&
          other.reservedBytes == this.reservedBytes &&
          other.installedUnits == this.installedUnits &&
          other.createdAt == this.createdAt);
}

class GroupPullsCompanion extends UpdateCompanion<StoredGroupPull> {
  final Value<String> spaceId;
  final Value<String> requestId;
  final Value<String> clientId;
  final Value<String> epoch;
  final Value<String> intentJson;
  final Value<String?> statusJson;
  final Value<String?> pullId;
  final Value<String?> nextToken;
  final Value<String> receiveStateJson;
  final Value<int> receivedPages;
  final Value<int> reservedBytes;
  final Value<int> installedUnits;
  final Value<DateTime> createdAt;
  final Value<int> rowid;
  const GroupPullsCompanion({
    this.spaceId = const Value.absent(),
    this.requestId = const Value.absent(),
    this.clientId = const Value.absent(),
    this.epoch = const Value.absent(),
    this.intentJson = const Value.absent(),
    this.statusJson = const Value.absent(),
    this.pullId = const Value.absent(),
    this.nextToken = const Value.absent(),
    this.receiveStateJson = const Value.absent(),
    this.receivedPages = const Value.absent(),
    this.reservedBytes = const Value.absent(),
    this.installedUnits = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  GroupPullsCompanion.insert({
    required String spaceId,
    required String requestId,
    required String clientId,
    required String epoch,
    required String intentJson,
    this.statusJson = const Value.absent(),
    this.pullId = const Value.absent(),
    this.nextToken = const Value.absent(),
    required String receiveStateJson,
    this.receivedPages = const Value.absent(),
    this.reservedBytes = const Value.absent(),
    this.installedUnits = const Value.absent(),
    required DateTime createdAt,
    this.rowid = const Value.absent(),
  }) : spaceId = Value(spaceId),
       requestId = Value(requestId),
       clientId = Value(clientId),
       epoch = Value(epoch),
       intentJson = Value(intentJson),
       receiveStateJson = Value(receiveStateJson),
       createdAt = Value(createdAt);
  static Insertable<StoredGroupPull> custom({
    Expression<String>? spaceId,
    Expression<String>? requestId,
    Expression<String>? clientId,
    Expression<String>? epoch,
    Expression<String>? intentJson,
    Expression<String>? statusJson,
    Expression<String>? pullId,
    Expression<String>? nextToken,
    Expression<String>? receiveStateJson,
    Expression<int>? receivedPages,
    Expression<int>? reservedBytes,
    Expression<int>? installedUnits,
    Expression<DateTime>? createdAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (spaceId != null) 'space_id': spaceId,
      if (requestId != null) 'request_id': requestId,
      if (clientId != null) 'client_id': clientId,
      if (epoch != null) 'epoch': epoch,
      if (intentJson != null) 'intent_json': intentJson,
      if (statusJson != null) 'status_json': statusJson,
      if (pullId != null) 'pull_id': pullId,
      if (nextToken != null) 'next_token': nextToken,
      if (receiveStateJson != null) 'receive_state_json': receiveStateJson,
      if (receivedPages != null) 'received_pages': receivedPages,
      if (reservedBytes != null) 'reserved_bytes': reservedBytes,
      if (installedUnits != null) 'installed_units': installedUnits,
      if (createdAt != null) 'created_at': createdAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  GroupPullsCompanion copyWith({
    Value<String>? spaceId,
    Value<String>? requestId,
    Value<String>? clientId,
    Value<String>? epoch,
    Value<String>? intentJson,
    Value<String?>? statusJson,
    Value<String?>? pullId,
    Value<String?>? nextToken,
    Value<String>? receiveStateJson,
    Value<int>? receivedPages,
    Value<int>? reservedBytes,
    Value<int>? installedUnits,
    Value<DateTime>? createdAt,
    Value<int>? rowid,
  }) {
    return GroupPullsCompanion(
      spaceId: spaceId ?? this.spaceId,
      requestId: requestId ?? this.requestId,
      clientId: clientId ?? this.clientId,
      epoch: epoch ?? this.epoch,
      intentJson: intentJson ?? this.intentJson,
      statusJson: statusJson ?? this.statusJson,
      pullId: pullId ?? this.pullId,
      nextToken: nextToken ?? this.nextToken,
      receiveStateJson: receiveStateJson ?? this.receiveStateJson,
      receivedPages: receivedPages ?? this.receivedPages,
      reservedBytes: reservedBytes ?? this.reservedBytes,
      installedUnits: installedUnits ?? this.installedUnits,
      createdAt: createdAt ?? this.createdAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (spaceId.present) {
      map['space_id'] = Variable<String>(spaceId.value);
    }
    if (requestId.present) {
      map['request_id'] = Variable<String>(requestId.value);
    }
    if (clientId.present) {
      map['client_id'] = Variable<String>(clientId.value);
    }
    if (epoch.present) {
      map['epoch'] = Variable<String>(epoch.value);
    }
    if (intentJson.present) {
      map['intent_json'] = Variable<String>(intentJson.value);
    }
    if (statusJson.present) {
      map['status_json'] = Variable<String>(statusJson.value);
    }
    if (pullId.present) {
      map['pull_id'] = Variable<String>(pullId.value);
    }
    if (nextToken.present) {
      map['next_token'] = Variable<String>(nextToken.value);
    }
    if (receiveStateJson.present) {
      map['receive_state_json'] = Variable<String>(receiveStateJson.value);
    }
    if (receivedPages.present) {
      map['received_pages'] = Variable<int>(receivedPages.value);
    }
    if (reservedBytes.present) {
      map['reserved_bytes'] = Variable<int>(reservedBytes.value);
    }
    if (installedUnits.present) {
      map['installed_units'] = Variable<int>(installedUnits.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('GroupPullsCompanion(')
          ..write('spaceId: $spaceId, ')
          ..write('requestId: $requestId, ')
          ..write('clientId: $clientId, ')
          ..write('epoch: $epoch, ')
          ..write('intentJson: $intentJson, ')
          ..write('statusJson: $statusJson, ')
          ..write('pullId: $pullId, ')
          ..write('nextToken: $nextToken, ')
          ..write('receiveStateJson: $receiveStateJson, ')
          ..write('receivedPages: $receivedPages, ')
          ..write('reservedBytes: $reservedBytes, ')
          ..write('installedUnits: $installedUnits, ')
          ..write('createdAt: $createdAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $GroupPagesTable extends GroupPages
    with TableInfo<$GroupPagesTable, StoredGroupPage> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $GroupPagesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _spaceIdMeta = const VerificationMeta(
    'spaceId',
  );
  @override
  late final GeneratedColumn<String> spaceId = GeneratedColumn<String>(
    'space_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES local_spaces (id)',
    ),
  );
  static const VerificationMeta _requestIdMeta = const VerificationMeta(
    'requestId',
  );
  @override
  late final GeneratedColumn<String> requestId = GeneratedColumn<String>(
    'request_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _ordinalMeta = const VerificationMeta(
    'ordinal',
  );
  @override
  late final GeneratedColumn<int> ordinal = GeneratedColumn<int>(
    'ordinal',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _requestTokenMeta = const VerificationMeta(
    'requestToken',
  );
  @override
  late final GeneratedColumn<String> requestToken = GeneratedColumn<String>(
    'request_token',
    aliasedName,
    false,
    type: DriftSqlType.string,
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
  static const VerificationMeta _groupIdMeta = const VerificationMeta(
    'groupId',
  );
  @override
  late final GeneratedColumn<String> groupId = GeneratedColumn<String>(
    'group_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _pageIndexMeta = const VerificationMeta(
    'pageIndex',
  );
  @override
  late final GeneratedColumn<int> pageIndex = GeneratedColumn<int>(
    'page_index',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _bodyJsonMeta = const VerificationMeta(
    'bodyJson',
  );
  @override
  late final GeneratedColumn<String> bodyJson = GeneratedColumn<String>(
    'body_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sha256Meta = const VerificationMeta('sha256');
  @override
  late final GeneratedColumn<String> sha256 = GeneratedColumn<String>(
    'sha256',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sizeBytesMeta = const VerificationMeta(
    'sizeBytes',
  );
  @override
  late final GeneratedColumn<int> sizeBytes = GeneratedColumn<int>(
    'size_bytes',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    spaceId,
    requestId,
    ordinal,
    requestToken,
    kind,
    groupId,
    pageIndex,
    bodyJson,
    sha256,
    sizeBytes,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'group_pages';
  @override
  VerificationContext validateIntegrity(
    Insertable<StoredGroupPage> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('space_id')) {
      context.handle(
        _spaceIdMeta,
        spaceId.isAcceptableOrUnknown(data['space_id']!, _spaceIdMeta),
      );
    } else if (isInserting) {
      context.missing(_spaceIdMeta);
    }
    if (data.containsKey('request_id')) {
      context.handle(
        _requestIdMeta,
        requestId.isAcceptableOrUnknown(data['request_id']!, _requestIdMeta),
      );
    } else if (isInserting) {
      context.missing(_requestIdMeta);
    }
    if (data.containsKey('ordinal')) {
      context.handle(
        _ordinalMeta,
        ordinal.isAcceptableOrUnknown(data['ordinal']!, _ordinalMeta),
      );
    } else if (isInserting) {
      context.missing(_ordinalMeta);
    }
    if (data.containsKey('request_token')) {
      context.handle(
        _requestTokenMeta,
        requestToken.isAcceptableOrUnknown(
          data['request_token']!,
          _requestTokenMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_requestTokenMeta);
    }
    if (data.containsKey('kind')) {
      context.handle(
        _kindMeta,
        kind.isAcceptableOrUnknown(data['kind']!, _kindMeta),
      );
    } else if (isInserting) {
      context.missing(_kindMeta);
    }
    if (data.containsKey('group_id')) {
      context.handle(
        _groupIdMeta,
        groupId.isAcceptableOrUnknown(data['group_id']!, _groupIdMeta),
      );
    } else if (isInserting) {
      context.missing(_groupIdMeta);
    }
    if (data.containsKey('page_index')) {
      context.handle(
        _pageIndexMeta,
        pageIndex.isAcceptableOrUnknown(data['page_index']!, _pageIndexMeta),
      );
    } else if (isInserting) {
      context.missing(_pageIndexMeta);
    }
    if (data.containsKey('body_json')) {
      context.handle(
        _bodyJsonMeta,
        bodyJson.isAcceptableOrUnknown(data['body_json']!, _bodyJsonMeta),
      );
    } else if (isInserting) {
      context.missing(_bodyJsonMeta);
    }
    if (data.containsKey('sha256')) {
      context.handle(
        _sha256Meta,
        sha256.isAcceptableOrUnknown(data['sha256']!, _sha256Meta),
      );
    } else if (isInserting) {
      context.missing(_sha256Meta);
    }
    if (data.containsKey('size_bytes')) {
      context.handle(
        _sizeBytesMeta,
        sizeBytes.isAcceptableOrUnknown(data['size_bytes']!, _sizeBytesMeta),
      );
    } else if (isInserting) {
      context.missing(_sizeBytesMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {spaceId, requestId, ordinal};
  @override
  List<Set<GeneratedColumn>> get uniqueKeys => [
    {spaceId, requestId, requestToken},
    {spaceId, requestId, kind, groupId, pageIndex},
  ];
  @override
  StoredGroupPage map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return StoredGroupPage(
      spaceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}space_id'],
      )!,
      requestId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}request_id'],
      )!,
      ordinal: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}ordinal'],
      )!,
      requestToken: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}request_token'],
      )!,
      kind: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}kind'],
      )!,
      groupId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}group_id'],
      )!,
      pageIndex: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}page_index'],
      )!,
      bodyJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}body_json'],
      )!,
      sha256: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sha256'],
      )!,
      sizeBytes: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}size_bytes'],
      )!,
    );
  }

  @override
  $GroupPagesTable createAlias(String alias) {
    return $GroupPagesTable(attachedDatabase, alias);
  }
}

class StoredGroupPage extends DataClass implements Insertable<StoredGroupPage> {
  final String spaceId;
  final String requestId;
  final int ordinal;
  final String requestToken;
  final String kind;
  final String groupId;
  final int pageIndex;
  final String bodyJson;
  final String sha256;
  final int sizeBytes;
  const StoredGroupPage({
    required this.spaceId,
    required this.requestId,
    required this.ordinal,
    required this.requestToken,
    required this.kind,
    required this.groupId,
    required this.pageIndex,
    required this.bodyJson,
    required this.sha256,
    required this.sizeBytes,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['space_id'] = Variable<String>(spaceId);
    map['request_id'] = Variable<String>(requestId);
    map['ordinal'] = Variable<int>(ordinal);
    map['request_token'] = Variable<String>(requestToken);
    map['kind'] = Variable<String>(kind);
    map['group_id'] = Variable<String>(groupId);
    map['page_index'] = Variable<int>(pageIndex);
    map['body_json'] = Variable<String>(bodyJson);
    map['sha256'] = Variable<String>(sha256);
    map['size_bytes'] = Variable<int>(sizeBytes);
    return map;
  }

  GroupPagesCompanion toCompanion(bool nullToAbsent) {
    return GroupPagesCompanion(
      spaceId: Value(spaceId),
      requestId: Value(requestId),
      ordinal: Value(ordinal),
      requestToken: Value(requestToken),
      kind: Value(kind),
      groupId: Value(groupId),
      pageIndex: Value(pageIndex),
      bodyJson: Value(bodyJson),
      sha256: Value(sha256),
      sizeBytes: Value(sizeBytes),
    );
  }

  factory StoredGroupPage.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return StoredGroupPage(
      spaceId: serializer.fromJson<String>(json['spaceId']),
      requestId: serializer.fromJson<String>(json['requestId']),
      ordinal: serializer.fromJson<int>(json['ordinal']),
      requestToken: serializer.fromJson<String>(json['requestToken']),
      kind: serializer.fromJson<String>(json['kind']),
      groupId: serializer.fromJson<String>(json['groupId']),
      pageIndex: serializer.fromJson<int>(json['pageIndex']),
      bodyJson: serializer.fromJson<String>(json['bodyJson']),
      sha256: serializer.fromJson<String>(json['sha256']),
      sizeBytes: serializer.fromJson<int>(json['sizeBytes']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'spaceId': serializer.toJson<String>(spaceId),
      'requestId': serializer.toJson<String>(requestId),
      'ordinal': serializer.toJson<int>(ordinal),
      'requestToken': serializer.toJson<String>(requestToken),
      'kind': serializer.toJson<String>(kind),
      'groupId': serializer.toJson<String>(groupId),
      'pageIndex': serializer.toJson<int>(pageIndex),
      'bodyJson': serializer.toJson<String>(bodyJson),
      'sha256': serializer.toJson<String>(sha256),
      'sizeBytes': serializer.toJson<int>(sizeBytes),
    };
  }

  StoredGroupPage copyWith({
    String? spaceId,
    String? requestId,
    int? ordinal,
    String? requestToken,
    String? kind,
    String? groupId,
    int? pageIndex,
    String? bodyJson,
    String? sha256,
    int? sizeBytes,
  }) => StoredGroupPage(
    spaceId: spaceId ?? this.spaceId,
    requestId: requestId ?? this.requestId,
    ordinal: ordinal ?? this.ordinal,
    requestToken: requestToken ?? this.requestToken,
    kind: kind ?? this.kind,
    groupId: groupId ?? this.groupId,
    pageIndex: pageIndex ?? this.pageIndex,
    bodyJson: bodyJson ?? this.bodyJson,
    sha256: sha256 ?? this.sha256,
    sizeBytes: sizeBytes ?? this.sizeBytes,
  );
  StoredGroupPage copyWithCompanion(GroupPagesCompanion data) {
    return StoredGroupPage(
      spaceId: data.spaceId.present ? data.spaceId.value : this.spaceId,
      requestId: data.requestId.present ? data.requestId.value : this.requestId,
      ordinal: data.ordinal.present ? data.ordinal.value : this.ordinal,
      requestToken: data.requestToken.present
          ? data.requestToken.value
          : this.requestToken,
      kind: data.kind.present ? data.kind.value : this.kind,
      groupId: data.groupId.present ? data.groupId.value : this.groupId,
      pageIndex: data.pageIndex.present ? data.pageIndex.value : this.pageIndex,
      bodyJson: data.bodyJson.present ? data.bodyJson.value : this.bodyJson,
      sha256: data.sha256.present ? data.sha256.value : this.sha256,
      sizeBytes: data.sizeBytes.present ? data.sizeBytes.value : this.sizeBytes,
    );
  }

  @override
  String toString() {
    return (StringBuffer('StoredGroupPage(')
          ..write('spaceId: $spaceId, ')
          ..write('requestId: $requestId, ')
          ..write('ordinal: $ordinal, ')
          ..write('requestToken: $requestToken, ')
          ..write('kind: $kind, ')
          ..write('groupId: $groupId, ')
          ..write('pageIndex: $pageIndex, ')
          ..write('bodyJson: $bodyJson, ')
          ..write('sha256: $sha256, ')
          ..write('sizeBytes: $sizeBytes')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    spaceId,
    requestId,
    ordinal,
    requestToken,
    kind,
    groupId,
    pageIndex,
    bodyJson,
    sha256,
    sizeBytes,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is StoredGroupPage &&
          other.spaceId == this.spaceId &&
          other.requestId == this.requestId &&
          other.ordinal == this.ordinal &&
          other.requestToken == this.requestToken &&
          other.kind == this.kind &&
          other.groupId == this.groupId &&
          other.pageIndex == this.pageIndex &&
          other.bodyJson == this.bodyJson &&
          other.sha256 == this.sha256 &&
          other.sizeBytes == this.sizeBytes);
}

class GroupPagesCompanion extends UpdateCompanion<StoredGroupPage> {
  final Value<String> spaceId;
  final Value<String> requestId;
  final Value<int> ordinal;
  final Value<String> requestToken;
  final Value<String> kind;
  final Value<String> groupId;
  final Value<int> pageIndex;
  final Value<String> bodyJson;
  final Value<String> sha256;
  final Value<int> sizeBytes;
  final Value<int> rowid;
  const GroupPagesCompanion({
    this.spaceId = const Value.absent(),
    this.requestId = const Value.absent(),
    this.ordinal = const Value.absent(),
    this.requestToken = const Value.absent(),
    this.kind = const Value.absent(),
    this.groupId = const Value.absent(),
    this.pageIndex = const Value.absent(),
    this.bodyJson = const Value.absent(),
    this.sha256 = const Value.absent(),
    this.sizeBytes = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  GroupPagesCompanion.insert({
    required String spaceId,
    required String requestId,
    required int ordinal,
    required String requestToken,
    required String kind,
    required String groupId,
    required int pageIndex,
    required String bodyJson,
    required String sha256,
    required int sizeBytes,
    this.rowid = const Value.absent(),
  }) : spaceId = Value(spaceId),
       requestId = Value(requestId),
       ordinal = Value(ordinal),
       requestToken = Value(requestToken),
       kind = Value(kind),
       groupId = Value(groupId),
       pageIndex = Value(pageIndex),
       bodyJson = Value(bodyJson),
       sha256 = Value(sha256),
       sizeBytes = Value(sizeBytes);
  static Insertable<StoredGroupPage> custom({
    Expression<String>? spaceId,
    Expression<String>? requestId,
    Expression<int>? ordinal,
    Expression<String>? requestToken,
    Expression<String>? kind,
    Expression<String>? groupId,
    Expression<int>? pageIndex,
    Expression<String>? bodyJson,
    Expression<String>? sha256,
    Expression<int>? sizeBytes,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (spaceId != null) 'space_id': spaceId,
      if (requestId != null) 'request_id': requestId,
      if (ordinal != null) 'ordinal': ordinal,
      if (requestToken != null) 'request_token': requestToken,
      if (kind != null) 'kind': kind,
      if (groupId != null) 'group_id': groupId,
      if (pageIndex != null) 'page_index': pageIndex,
      if (bodyJson != null) 'body_json': bodyJson,
      if (sha256 != null) 'sha256': sha256,
      if (sizeBytes != null) 'size_bytes': sizeBytes,
      if (rowid != null) 'rowid': rowid,
    });
  }

  GroupPagesCompanion copyWith({
    Value<String>? spaceId,
    Value<String>? requestId,
    Value<int>? ordinal,
    Value<String>? requestToken,
    Value<String>? kind,
    Value<String>? groupId,
    Value<int>? pageIndex,
    Value<String>? bodyJson,
    Value<String>? sha256,
    Value<int>? sizeBytes,
    Value<int>? rowid,
  }) {
    return GroupPagesCompanion(
      spaceId: spaceId ?? this.spaceId,
      requestId: requestId ?? this.requestId,
      ordinal: ordinal ?? this.ordinal,
      requestToken: requestToken ?? this.requestToken,
      kind: kind ?? this.kind,
      groupId: groupId ?? this.groupId,
      pageIndex: pageIndex ?? this.pageIndex,
      bodyJson: bodyJson ?? this.bodyJson,
      sha256: sha256 ?? this.sha256,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (spaceId.present) {
      map['space_id'] = Variable<String>(spaceId.value);
    }
    if (requestId.present) {
      map['request_id'] = Variable<String>(requestId.value);
    }
    if (ordinal.present) {
      map['ordinal'] = Variable<int>(ordinal.value);
    }
    if (requestToken.present) {
      map['request_token'] = Variable<String>(requestToken.value);
    }
    if (kind.present) {
      map['kind'] = Variable<String>(kind.value);
    }
    if (groupId.present) {
      map['group_id'] = Variable<String>(groupId.value);
    }
    if (pageIndex.present) {
      map['page_index'] = Variable<int>(pageIndex.value);
    }
    if (bodyJson.present) {
      map['body_json'] = Variable<String>(bodyJson.value);
    }
    if (sha256.present) {
      map['sha256'] = Variable<String>(sha256.value);
    }
    if (sizeBytes.present) {
      map['size_bytes'] = Variable<int>(sizeBytes.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('GroupPagesCompanion(')
          ..write('spaceId: $spaceId, ')
          ..write('requestId: $requestId, ')
          ..write('ordinal: $ordinal, ')
          ..write('requestToken: $requestToken, ')
          ..write('kind: $kind, ')
          ..write('groupId: $groupId, ')
          ..write('pageIndex: $pageIndex, ')
          ..write('bodyJson: $bodyJson, ')
          ..write('sha256: $sha256, ')
          ..write('sizeBytes: $sizeBytes, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $GroupReceiptsTable extends GroupReceipts
    with TableInfo<$GroupReceiptsTable, StoredGroupReceipt> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $GroupReceiptsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _spaceIdMeta = const VerificationMeta(
    'spaceId',
  );
  @override
  late final GeneratedColumn<String> spaceId = GeneratedColumn<String>(
    'space_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES local_spaces (id)',
    ),
  );
  static const VerificationMeta _requestIdMeta = const VerificationMeta(
    'requestId',
  );
  @override
  late final GeneratedColumn<String> requestId = GeneratedColumn<String>(
    'request_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _unitIndexMeta = const VerificationMeta(
    'unitIndex',
  );
  @override
  late final GeneratedColumn<int> unitIndex = GeneratedColumn<int>(
    'unit_index',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _groupIdMeta = const VerificationMeta(
    'groupId',
  );
  @override
  late final GeneratedColumn<String> groupId = GeneratedColumn<String>(
    'group_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _manifestSha256Meta = const VerificationMeta(
    'manifestSha256',
  );
  @override
  late final GeneratedColumn<String> manifestSha256 = GeneratedColumn<String>(
    'manifest_sha256',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _endCursorsJsonMeta = const VerificationMeta(
    'endCursorsJson',
  );
  @override
  late final GeneratedColumn<String> endCursorsJson = GeneratedColumn<String>(
    'end_cursors_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sizeBytesMeta = const VerificationMeta(
    'sizeBytes',
  );
  @override
  late final GeneratedColumn<int> sizeBytes = GeneratedColumn<int>(
    'size_bytes',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    spaceId,
    requestId,
    unitIndex,
    groupId,
    manifestSha256,
    endCursorsJson,
    sizeBytes,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'group_receipts';
  @override
  VerificationContext validateIntegrity(
    Insertable<StoredGroupReceipt> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('space_id')) {
      context.handle(
        _spaceIdMeta,
        spaceId.isAcceptableOrUnknown(data['space_id']!, _spaceIdMeta),
      );
    } else if (isInserting) {
      context.missing(_spaceIdMeta);
    }
    if (data.containsKey('request_id')) {
      context.handle(
        _requestIdMeta,
        requestId.isAcceptableOrUnknown(data['request_id']!, _requestIdMeta),
      );
    } else if (isInserting) {
      context.missing(_requestIdMeta);
    }
    if (data.containsKey('unit_index')) {
      context.handle(
        _unitIndexMeta,
        unitIndex.isAcceptableOrUnknown(data['unit_index']!, _unitIndexMeta),
      );
    } else if (isInserting) {
      context.missing(_unitIndexMeta);
    }
    if (data.containsKey('group_id')) {
      context.handle(
        _groupIdMeta,
        groupId.isAcceptableOrUnknown(data['group_id']!, _groupIdMeta),
      );
    } else if (isInserting) {
      context.missing(_groupIdMeta);
    }
    if (data.containsKey('manifest_sha256')) {
      context.handle(
        _manifestSha256Meta,
        manifestSha256.isAcceptableOrUnknown(
          data['manifest_sha256']!,
          _manifestSha256Meta,
        ),
      );
    } else if (isInserting) {
      context.missing(_manifestSha256Meta);
    }
    if (data.containsKey('end_cursors_json')) {
      context.handle(
        _endCursorsJsonMeta,
        endCursorsJson.isAcceptableOrUnknown(
          data['end_cursors_json']!,
          _endCursorsJsonMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_endCursorsJsonMeta);
    }
    if (data.containsKey('size_bytes')) {
      context.handle(
        _sizeBytesMeta,
        sizeBytes.isAcceptableOrUnknown(data['size_bytes']!, _sizeBytesMeta),
      );
    } else if (isInserting) {
      context.missing(_sizeBytesMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {spaceId, requestId, unitIndex};
  @override
  StoredGroupReceipt map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return StoredGroupReceipt(
      spaceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}space_id'],
      )!,
      requestId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}request_id'],
      )!,
      unitIndex: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}unit_index'],
      )!,
      groupId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}group_id'],
      )!,
      manifestSha256: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}manifest_sha256'],
      )!,
      endCursorsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}end_cursors_json'],
      )!,
      sizeBytes: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}size_bytes'],
      )!,
    );
  }

  @override
  $GroupReceiptsTable createAlias(String alias) {
    return $GroupReceiptsTable(attachedDatabase, alias);
  }
}

class StoredGroupReceipt extends DataClass
    implements Insertable<StoredGroupReceipt> {
  final String spaceId;
  final String requestId;
  final int unitIndex;
  final String groupId;
  final String manifestSha256;
  final String endCursorsJson;
  final int sizeBytes;
  const StoredGroupReceipt({
    required this.spaceId,
    required this.requestId,
    required this.unitIndex,
    required this.groupId,
    required this.manifestSha256,
    required this.endCursorsJson,
    required this.sizeBytes,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['space_id'] = Variable<String>(spaceId);
    map['request_id'] = Variable<String>(requestId);
    map['unit_index'] = Variable<int>(unitIndex);
    map['group_id'] = Variable<String>(groupId);
    map['manifest_sha256'] = Variable<String>(manifestSha256);
    map['end_cursors_json'] = Variable<String>(endCursorsJson);
    map['size_bytes'] = Variable<int>(sizeBytes);
    return map;
  }

  GroupReceiptsCompanion toCompanion(bool nullToAbsent) {
    return GroupReceiptsCompanion(
      spaceId: Value(spaceId),
      requestId: Value(requestId),
      unitIndex: Value(unitIndex),
      groupId: Value(groupId),
      manifestSha256: Value(manifestSha256),
      endCursorsJson: Value(endCursorsJson),
      sizeBytes: Value(sizeBytes),
    );
  }

  factory StoredGroupReceipt.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return StoredGroupReceipt(
      spaceId: serializer.fromJson<String>(json['spaceId']),
      requestId: serializer.fromJson<String>(json['requestId']),
      unitIndex: serializer.fromJson<int>(json['unitIndex']),
      groupId: serializer.fromJson<String>(json['groupId']),
      manifestSha256: serializer.fromJson<String>(json['manifestSha256']),
      endCursorsJson: serializer.fromJson<String>(json['endCursorsJson']),
      sizeBytes: serializer.fromJson<int>(json['sizeBytes']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'spaceId': serializer.toJson<String>(spaceId),
      'requestId': serializer.toJson<String>(requestId),
      'unitIndex': serializer.toJson<int>(unitIndex),
      'groupId': serializer.toJson<String>(groupId),
      'manifestSha256': serializer.toJson<String>(manifestSha256),
      'endCursorsJson': serializer.toJson<String>(endCursorsJson),
      'sizeBytes': serializer.toJson<int>(sizeBytes),
    };
  }

  StoredGroupReceipt copyWith({
    String? spaceId,
    String? requestId,
    int? unitIndex,
    String? groupId,
    String? manifestSha256,
    String? endCursorsJson,
    int? sizeBytes,
  }) => StoredGroupReceipt(
    spaceId: spaceId ?? this.spaceId,
    requestId: requestId ?? this.requestId,
    unitIndex: unitIndex ?? this.unitIndex,
    groupId: groupId ?? this.groupId,
    manifestSha256: manifestSha256 ?? this.manifestSha256,
    endCursorsJson: endCursorsJson ?? this.endCursorsJson,
    sizeBytes: sizeBytes ?? this.sizeBytes,
  );
  StoredGroupReceipt copyWithCompanion(GroupReceiptsCompanion data) {
    return StoredGroupReceipt(
      spaceId: data.spaceId.present ? data.spaceId.value : this.spaceId,
      requestId: data.requestId.present ? data.requestId.value : this.requestId,
      unitIndex: data.unitIndex.present ? data.unitIndex.value : this.unitIndex,
      groupId: data.groupId.present ? data.groupId.value : this.groupId,
      manifestSha256: data.manifestSha256.present
          ? data.manifestSha256.value
          : this.manifestSha256,
      endCursorsJson: data.endCursorsJson.present
          ? data.endCursorsJson.value
          : this.endCursorsJson,
      sizeBytes: data.sizeBytes.present ? data.sizeBytes.value : this.sizeBytes,
    );
  }

  @override
  String toString() {
    return (StringBuffer('StoredGroupReceipt(')
          ..write('spaceId: $spaceId, ')
          ..write('requestId: $requestId, ')
          ..write('unitIndex: $unitIndex, ')
          ..write('groupId: $groupId, ')
          ..write('manifestSha256: $manifestSha256, ')
          ..write('endCursorsJson: $endCursorsJson, ')
          ..write('sizeBytes: $sizeBytes')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    spaceId,
    requestId,
    unitIndex,
    groupId,
    manifestSha256,
    endCursorsJson,
    sizeBytes,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is StoredGroupReceipt &&
          other.spaceId == this.spaceId &&
          other.requestId == this.requestId &&
          other.unitIndex == this.unitIndex &&
          other.groupId == this.groupId &&
          other.manifestSha256 == this.manifestSha256 &&
          other.endCursorsJson == this.endCursorsJson &&
          other.sizeBytes == this.sizeBytes);
}

class GroupReceiptsCompanion extends UpdateCompanion<StoredGroupReceipt> {
  final Value<String> spaceId;
  final Value<String> requestId;
  final Value<int> unitIndex;
  final Value<String> groupId;
  final Value<String> manifestSha256;
  final Value<String> endCursorsJson;
  final Value<int> sizeBytes;
  final Value<int> rowid;
  const GroupReceiptsCompanion({
    this.spaceId = const Value.absent(),
    this.requestId = const Value.absent(),
    this.unitIndex = const Value.absent(),
    this.groupId = const Value.absent(),
    this.manifestSha256 = const Value.absent(),
    this.endCursorsJson = const Value.absent(),
    this.sizeBytes = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  GroupReceiptsCompanion.insert({
    required String spaceId,
    required String requestId,
    required int unitIndex,
    required String groupId,
    required String manifestSha256,
    required String endCursorsJson,
    required int sizeBytes,
    this.rowid = const Value.absent(),
  }) : spaceId = Value(spaceId),
       requestId = Value(requestId),
       unitIndex = Value(unitIndex),
       groupId = Value(groupId),
       manifestSha256 = Value(manifestSha256),
       endCursorsJson = Value(endCursorsJson),
       sizeBytes = Value(sizeBytes);
  static Insertable<StoredGroupReceipt> custom({
    Expression<String>? spaceId,
    Expression<String>? requestId,
    Expression<int>? unitIndex,
    Expression<String>? groupId,
    Expression<String>? manifestSha256,
    Expression<String>? endCursorsJson,
    Expression<int>? sizeBytes,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (spaceId != null) 'space_id': spaceId,
      if (requestId != null) 'request_id': requestId,
      if (unitIndex != null) 'unit_index': unitIndex,
      if (groupId != null) 'group_id': groupId,
      if (manifestSha256 != null) 'manifest_sha256': manifestSha256,
      if (endCursorsJson != null) 'end_cursors_json': endCursorsJson,
      if (sizeBytes != null) 'size_bytes': sizeBytes,
      if (rowid != null) 'rowid': rowid,
    });
  }

  GroupReceiptsCompanion copyWith({
    Value<String>? spaceId,
    Value<String>? requestId,
    Value<int>? unitIndex,
    Value<String>? groupId,
    Value<String>? manifestSha256,
    Value<String>? endCursorsJson,
    Value<int>? sizeBytes,
    Value<int>? rowid,
  }) {
    return GroupReceiptsCompanion(
      spaceId: spaceId ?? this.spaceId,
      requestId: requestId ?? this.requestId,
      unitIndex: unitIndex ?? this.unitIndex,
      groupId: groupId ?? this.groupId,
      manifestSha256: manifestSha256 ?? this.manifestSha256,
      endCursorsJson: endCursorsJson ?? this.endCursorsJson,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (spaceId.present) {
      map['space_id'] = Variable<String>(spaceId.value);
    }
    if (requestId.present) {
      map['request_id'] = Variable<String>(requestId.value);
    }
    if (unitIndex.present) {
      map['unit_index'] = Variable<int>(unitIndex.value);
    }
    if (groupId.present) {
      map['group_id'] = Variable<String>(groupId.value);
    }
    if (manifestSha256.present) {
      map['manifest_sha256'] = Variable<String>(manifestSha256.value);
    }
    if (endCursorsJson.present) {
      map['end_cursors_json'] = Variable<String>(endCursorsJson.value);
    }
    if (sizeBytes.present) {
      map['size_bytes'] = Variable<int>(sizeBytes.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('GroupReceiptsCompanion(')
          ..write('spaceId: $spaceId, ')
          ..write('requestId: $requestId, ')
          ..write('unitIndex: $unitIndex, ')
          ..write('groupId: $groupId, ')
          ..write('manifestSha256: $manifestSha256, ')
          ..write('endCursorsJson: $endCursorsJson, ')
          ..write('sizeBytes: $sizeBytes, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $StageImportSourcesTable extends StageImportSources
    with TableInfo<$StageImportSourcesTable, StoredStageImportSource> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $StageImportSourcesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _spaceIdMeta = const VerificationMeta(
    'spaceId',
  );
  @override
  late final GeneratedColumn<String> spaceId = GeneratedColumn<String>(
    'space_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES local_spaces (id)',
    ),
  );
  static const VerificationMeta _stageIdMeta = const VerificationMeta(
    'stageId',
  );
  @override
  late final GeneratedColumn<String> stageId = GeneratedColumn<String>(
    'stage_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _clientIdMeta = const VerificationMeta(
    'clientId',
  );
  @override
  late final GeneratedColumn<String> clientId = GeneratedColumn<String>(
    'client_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _epochMeta = const VerificationMeta('epoch');
  @override
  late final GeneratedColumn<String> epoch = GeneratedColumn<String>(
    'epoch',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _originSessionIdMeta = const VerificationMeta(
    'originSessionId',
  );
  @override
  late final GeneratedColumn<String> originSessionId = GeneratedColumn<String>(
    'origin_session_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
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
  static const VerificationMeta _fileNameMeta = const VerificationMeta(
    'fileName',
  );
  @override
  late final GeneratedColumn<String> fileName = GeneratedColumn<String>(
    'file_name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sourceSha256Meta = const VerificationMeta(
    'sourceSha256',
  );
  @override
  late final GeneratedColumn<String> sourceSha256 = GeneratedColumn<String>(
    'source_sha256',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _createBodyJsonMeta = const VerificationMeta(
    'createBodyJson',
  );
  @override
  late final GeneratedColumn<String> createBodyJson = GeneratedColumn<String>(
    'create_body_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _stateJsonMeta = const VerificationMeta(
    'stateJson',
  );
  @override
  late final GeneratedColumn<String> stateJson = GeneratedColumn<String>(
    'state_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _expectedBytesMeta = const VerificationMeta(
    'expectedBytes',
  );
  @override
  late final GeneratedColumn<int> expectedBytes = GeneratedColumn<int>(
    'expected_bytes',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _reservedBytesMeta = const VerificationMeta(
    'reservedBytes',
  );
  @override
  late final GeneratedColumn<int> reservedBytes = GeneratedColumn<int>(
    'reserved_bytes',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
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
  @override
  List<GeneratedColumn> get $columns => [
    spaceId,
    stageId,
    clientId,
    epoch,
    originSessionId,
    format,
    fileName,
    sourceSha256,
    createBodyJson,
    stateJson,
    expectedBytes,
    reservedBytes,
    createdAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'stage_import_sources';
  @override
  VerificationContext validateIntegrity(
    Insertable<StoredStageImportSource> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('space_id')) {
      context.handle(
        _spaceIdMeta,
        spaceId.isAcceptableOrUnknown(data['space_id']!, _spaceIdMeta),
      );
    } else if (isInserting) {
      context.missing(_spaceIdMeta);
    }
    if (data.containsKey('stage_id')) {
      context.handle(
        _stageIdMeta,
        stageId.isAcceptableOrUnknown(data['stage_id']!, _stageIdMeta),
      );
    } else if (isInserting) {
      context.missing(_stageIdMeta);
    }
    if (data.containsKey('client_id')) {
      context.handle(
        _clientIdMeta,
        clientId.isAcceptableOrUnknown(data['client_id']!, _clientIdMeta),
      );
    } else if (isInserting) {
      context.missing(_clientIdMeta);
    }
    if (data.containsKey('epoch')) {
      context.handle(
        _epochMeta,
        epoch.isAcceptableOrUnknown(data['epoch']!, _epochMeta),
      );
    } else if (isInserting) {
      context.missing(_epochMeta);
    }
    if (data.containsKey('origin_session_id')) {
      context.handle(
        _originSessionIdMeta,
        originSessionId.isAcceptableOrUnknown(
          data['origin_session_id']!,
          _originSessionIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_originSessionIdMeta);
    }
    if (data.containsKey('format')) {
      context.handle(
        _formatMeta,
        format.isAcceptableOrUnknown(data['format']!, _formatMeta),
      );
    } else if (isInserting) {
      context.missing(_formatMeta);
    }
    if (data.containsKey('file_name')) {
      context.handle(
        _fileNameMeta,
        fileName.isAcceptableOrUnknown(data['file_name']!, _fileNameMeta),
      );
    } else if (isInserting) {
      context.missing(_fileNameMeta);
    }
    if (data.containsKey('source_sha256')) {
      context.handle(
        _sourceSha256Meta,
        sourceSha256.isAcceptableOrUnknown(
          data['source_sha256']!,
          _sourceSha256Meta,
        ),
      );
    } else if (isInserting) {
      context.missing(_sourceSha256Meta);
    }
    if (data.containsKey('create_body_json')) {
      context.handle(
        _createBodyJsonMeta,
        createBodyJson.isAcceptableOrUnknown(
          data['create_body_json']!,
          _createBodyJsonMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_createBodyJsonMeta);
    }
    if (data.containsKey('state_json')) {
      context.handle(
        _stateJsonMeta,
        stateJson.isAcceptableOrUnknown(data['state_json']!, _stateJsonMeta),
      );
    } else if (isInserting) {
      context.missing(_stateJsonMeta);
    }
    if (data.containsKey('expected_bytes')) {
      context.handle(
        _expectedBytesMeta,
        expectedBytes.isAcceptableOrUnknown(
          data['expected_bytes']!,
          _expectedBytesMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_expectedBytesMeta);
    }
    if (data.containsKey('reserved_bytes')) {
      context.handle(
        _reservedBytesMeta,
        reservedBytes.isAcceptableOrUnknown(
          data['reserved_bytes']!,
          _reservedBytesMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_reservedBytesMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {spaceId, stageId};
  @override
  StoredStageImportSource map(
    Map<String, dynamic> data, {
    String? tablePrefix,
  }) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return StoredStageImportSource(
      spaceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}space_id'],
      )!,
      stageId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}stage_id'],
      )!,
      clientId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}client_id'],
      )!,
      epoch: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}epoch'],
      )!,
      originSessionId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}origin_session_id'],
      )!,
      format: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}format'],
      )!,
      fileName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}file_name'],
      )!,
      sourceSha256: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}source_sha256'],
      )!,
      createBodyJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}create_body_json'],
      )!,
      stateJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}state_json'],
      )!,
      expectedBytes: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}expected_bytes'],
      )!,
      reservedBytes: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}reserved_bytes'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
    );
  }

  @override
  $StageImportSourcesTable createAlias(String alias) {
    return $StageImportSourcesTable(attachedDatabase, alias);
  }
}

class StoredStageImportSource extends DataClass
    implements Insertable<StoredStageImportSource> {
  final String spaceId;
  final String stageId;
  final String clientId;
  final String epoch;
  final String originSessionId;
  final String format;
  final String fileName;
  final String sourceSha256;
  final String createBodyJson;
  final String stateJson;
  final int expectedBytes;
  final int reservedBytes;
  final DateTime createdAt;
  const StoredStageImportSource({
    required this.spaceId,
    required this.stageId,
    required this.clientId,
    required this.epoch,
    required this.originSessionId,
    required this.format,
    required this.fileName,
    required this.sourceSha256,
    required this.createBodyJson,
    required this.stateJson,
    required this.expectedBytes,
    required this.reservedBytes,
    required this.createdAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['space_id'] = Variable<String>(spaceId);
    map['stage_id'] = Variable<String>(stageId);
    map['client_id'] = Variable<String>(clientId);
    map['epoch'] = Variable<String>(epoch);
    map['origin_session_id'] = Variable<String>(originSessionId);
    map['format'] = Variable<String>(format);
    map['file_name'] = Variable<String>(fileName);
    map['source_sha256'] = Variable<String>(sourceSha256);
    map['create_body_json'] = Variable<String>(createBodyJson);
    map['state_json'] = Variable<String>(stateJson);
    map['expected_bytes'] = Variable<int>(expectedBytes);
    map['reserved_bytes'] = Variable<int>(reservedBytes);
    map['created_at'] = Variable<DateTime>(createdAt);
    return map;
  }

  StageImportSourcesCompanion toCompanion(bool nullToAbsent) {
    return StageImportSourcesCompanion(
      spaceId: Value(spaceId),
      stageId: Value(stageId),
      clientId: Value(clientId),
      epoch: Value(epoch),
      originSessionId: Value(originSessionId),
      format: Value(format),
      fileName: Value(fileName),
      sourceSha256: Value(sourceSha256),
      createBodyJson: Value(createBodyJson),
      stateJson: Value(stateJson),
      expectedBytes: Value(expectedBytes),
      reservedBytes: Value(reservedBytes),
      createdAt: Value(createdAt),
    );
  }

  factory StoredStageImportSource.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return StoredStageImportSource(
      spaceId: serializer.fromJson<String>(json['spaceId']),
      stageId: serializer.fromJson<String>(json['stageId']),
      clientId: serializer.fromJson<String>(json['clientId']),
      epoch: serializer.fromJson<String>(json['epoch']),
      originSessionId: serializer.fromJson<String>(json['originSessionId']),
      format: serializer.fromJson<String>(json['format']),
      fileName: serializer.fromJson<String>(json['fileName']),
      sourceSha256: serializer.fromJson<String>(json['sourceSha256']),
      createBodyJson: serializer.fromJson<String>(json['createBodyJson']),
      stateJson: serializer.fromJson<String>(json['stateJson']),
      expectedBytes: serializer.fromJson<int>(json['expectedBytes']),
      reservedBytes: serializer.fromJson<int>(json['reservedBytes']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'spaceId': serializer.toJson<String>(spaceId),
      'stageId': serializer.toJson<String>(stageId),
      'clientId': serializer.toJson<String>(clientId),
      'epoch': serializer.toJson<String>(epoch),
      'originSessionId': serializer.toJson<String>(originSessionId),
      'format': serializer.toJson<String>(format),
      'fileName': serializer.toJson<String>(fileName),
      'sourceSha256': serializer.toJson<String>(sourceSha256),
      'createBodyJson': serializer.toJson<String>(createBodyJson),
      'stateJson': serializer.toJson<String>(stateJson),
      'expectedBytes': serializer.toJson<int>(expectedBytes),
      'reservedBytes': serializer.toJson<int>(reservedBytes),
      'createdAt': serializer.toJson<DateTime>(createdAt),
    };
  }

  StoredStageImportSource copyWith({
    String? spaceId,
    String? stageId,
    String? clientId,
    String? epoch,
    String? originSessionId,
    String? format,
    String? fileName,
    String? sourceSha256,
    String? createBodyJson,
    String? stateJson,
    int? expectedBytes,
    int? reservedBytes,
    DateTime? createdAt,
  }) => StoredStageImportSource(
    spaceId: spaceId ?? this.spaceId,
    stageId: stageId ?? this.stageId,
    clientId: clientId ?? this.clientId,
    epoch: epoch ?? this.epoch,
    originSessionId: originSessionId ?? this.originSessionId,
    format: format ?? this.format,
    fileName: fileName ?? this.fileName,
    sourceSha256: sourceSha256 ?? this.sourceSha256,
    createBodyJson: createBodyJson ?? this.createBodyJson,
    stateJson: stateJson ?? this.stateJson,
    expectedBytes: expectedBytes ?? this.expectedBytes,
    reservedBytes: reservedBytes ?? this.reservedBytes,
    createdAt: createdAt ?? this.createdAt,
  );
  StoredStageImportSource copyWithCompanion(StageImportSourcesCompanion data) {
    return StoredStageImportSource(
      spaceId: data.spaceId.present ? data.spaceId.value : this.spaceId,
      stageId: data.stageId.present ? data.stageId.value : this.stageId,
      clientId: data.clientId.present ? data.clientId.value : this.clientId,
      epoch: data.epoch.present ? data.epoch.value : this.epoch,
      originSessionId: data.originSessionId.present
          ? data.originSessionId.value
          : this.originSessionId,
      format: data.format.present ? data.format.value : this.format,
      fileName: data.fileName.present ? data.fileName.value : this.fileName,
      sourceSha256: data.sourceSha256.present
          ? data.sourceSha256.value
          : this.sourceSha256,
      createBodyJson: data.createBodyJson.present
          ? data.createBodyJson.value
          : this.createBodyJson,
      stateJson: data.stateJson.present ? data.stateJson.value : this.stateJson,
      expectedBytes: data.expectedBytes.present
          ? data.expectedBytes.value
          : this.expectedBytes,
      reservedBytes: data.reservedBytes.present
          ? data.reservedBytes.value
          : this.reservedBytes,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('StoredStageImportSource(')
          ..write('spaceId: $spaceId, ')
          ..write('stageId: $stageId, ')
          ..write('clientId: $clientId, ')
          ..write('epoch: $epoch, ')
          ..write('originSessionId: $originSessionId, ')
          ..write('format: $format, ')
          ..write('fileName: $fileName, ')
          ..write('sourceSha256: $sourceSha256, ')
          ..write('createBodyJson: $createBodyJson, ')
          ..write('stateJson: $stateJson, ')
          ..write('expectedBytes: $expectedBytes, ')
          ..write('reservedBytes: $reservedBytes, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    spaceId,
    stageId,
    clientId,
    epoch,
    originSessionId,
    format,
    fileName,
    sourceSha256,
    createBodyJson,
    stateJson,
    expectedBytes,
    reservedBytes,
    createdAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is StoredStageImportSource &&
          other.spaceId == this.spaceId &&
          other.stageId == this.stageId &&
          other.clientId == this.clientId &&
          other.epoch == this.epoch &&
          other.originSessionId == this.originSessionId &&
          other.format == this.format &&
          other.fileName == this.fileName &&
          other.sourceSha256 == this.sourceSha256 &&
          other.createBodyJson == this.createBodyJson &&
          other.stateJson == this.stateJson &&
          other.expectedBytes == this.expectedBytes &&
          other.reservedBytes == this.reservedBytes &&
          other.createdAt == this.createdAt);
}

class StageImportSourcesCompanion
    extends UpdateCompanion<StoredStageImportSource> {
  final Value<String> spaceId;
  final Value<String> stageId;
  final Value<String> clientId;
  final Value<String> epoch;
  final Value<String> originSessionId;
  final Value<String> format;
  final Value<String> fileName;
  final Value<String> sourceSha256;
  final Value<String> createBodyJson;
  final Value<String> stateJson;
  final Value<int> expectedBytes;
  final Value<int> reservedBytes;
  final Value<DateTime> createdAt;
  final Value<int> rowid;
  const StageImportSourcesCompanion({
    this.spaceId = const Value.absent(),
    this.stageId = const Value.absent(),
    this.clientId = const Value.absent(),
    this.epoch = const Value.absent(),
    this.originSessionId = const Value.absent(),
    this.format = const Value.absent(),
    this.fileName = const Value.absent(),
    this.sourceSha256 = const Value.absent(),
    this.createBodyJson = const Value.absent(),
    this.stateJson = const Value.absent(),
    this.expectedBytes = const Value.absent(),
    this.reservedBytes = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  StageImportSourcesCompanion.insert({
    required String spaceId,
    required String stageId,
    required String clientId,
    required String epoch,
    required String originSessionId,
    required String format,
    required String fileName,
    required String sourceSha256,
    required String createBodyJson,
    required String stateJson,
    required int expectedBytes,
    required int reservedBytes,
    required DateTime createdAt,
    this.rowid = const Value.absent(),
  }) : spaceId = Value(spaceId),
       stageId = Value(stageId),
       clientId = Value(clientId),
       epoch = Value(epoch),
       originSessionId = Value(originSessionId),
       format = Value(format),
       fileName = Value(fileName),
       sourceSha256 = Value(sourceSha256),
       createBodyJson = Value(createBodyJson),
       stateJson = Value(stateJson),
       expectedBytes = Value(expectedBytes),
       reservedBytes = Value(reservedBytes),
       createdAt = Value(createdAt);
  static Insertable<StoredStageImportSource> custom({
    Expression<String>? spaceId,
    Expression<String>? stageId,
    Expression<String>? clientId,
    Expression<String>? epoch,
    Expression<String>? originSessionId,
    Expression<String>? format,
    Expression<String>? fileName,
    Expression<String>? sourceSha256,
    Expression<String>? createBodyJson,
    Expression<String>? stateJson,
    Expression<int>? expectedBytes,
    Expression<int>? reservedBytes,
    Expression<DateTime>? createdAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (spaceId != null) 'space_id': spaceId,
      if (stageId != null) 'stage_id': stageId,
      if (clientId != null) 'client_id': clientId,
      if (epoch != null) 'epoch': epoch,
      if (originSessionId != null) 'origin_session_id': originSessionId,
      if (format != null) 'format': format,
      if (fileName != null) 'file_name': fileName,
      if (sourceSha256 != null) 'source_sha256': sourceSha256,
      if (createBodyJson != null) 'create_body_json': createBodyJson,
      if (stateJson != null) 'state_json': stateJson,
      if (expectedBytes != null) 'expected_bytes': expectedBytes,
      if (reservedBytes != null) 'reserved_bytes': reservedBytes,
      if (createdAt != null) 'created_at': createdAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  StageImportSourcesCompanion copyWith({
    Value<String>? spaceId,
    Value<String>? stageId,
    Value<String>? clientId,
    Value<String>? epoch,
    Value<String>? originSessionId,
    Value<String>? format,
    Value<String>? fileName,
    Value<String>? sourceSha256,
    Value<String>? createBodyJson,
    Value<String>? stateJson,
    Value<int>? expectedBytes,
    Value<int>? reservedBytes,
    Value<DateTime>? createdAt,
    Value<int>? rowid,
  }) {
    return StageImportSourcesCompanion(
      spaceId: spaceId ?? this.spaceId,
      stageId: stageId ?? this.stageId,
      clientId: clientId ?? this.clientId,
      epoch: epoch ?? this.epoch,
      originSessionId: originSessionId ?? this.originSessionId,
      format: format ?? this.format,
      fileName: fileName ?? this.fileName,
      sourceSha256: sourceSha256 ?? this.sourceSha256,
      createBodyJson: createBodyJson ?? this.createBodyJson,
      stateJson: stateJson ?? this.stateJson,
      expectedBytes: expectedBytes ?? this.expectedBytes,
      reservedBytes: reservedBytes ?? this.reservedBytes,
      createdAt: createdAt ?? this.createdAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (spaceId.present) {
      map['space_id'] = Variable<String>(spaceId.value);
    }
    if (stageId.present) {
      map['stage_id'] = Variable<String>(stageId.value);
    }
    if (clientId.present) {
      map['client_id'] = Variable<String>(clientId.value);
    }
    if (epoch.present) {
      map['epoch'] = Variable<String>(epoch.value);
    }
    if (originSessionId.present) {
      map['origin_session_id'] = Variable<String>(originSessionId.value);
    }
    if (format.present) {
      map['format'] = Variable<String>(format.value);
    }
    if (fileName.present) {
      map['file_name'] = Variable<String>(fileName.value);
    }
    if (sourceSha256.present) {
      map['source_sha256'] = Variable<String>(sourceSha256.value);
    }
    if (createBodyJson.present) {
      map['create_body_json'] = Variable<String>(createBodyJson.value);
    }
    if (stateJson.present) {
      map['state_json'] = Variable<String>(stateJson.value);
    }
    if (expectedBytes.present) {
      map['expected_bytes'] = Variable<int>(expectedBytes.value);
    }
    if (reservedBytes.present) {
      map['reserved_bytes'] = Variable<int>(reservedBytes.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('StageImportSourcesCompanion(')
          ..write('spaceId: $spaceId, ')
          ..write('stageId: $stageId, ')
          ..write('clientId: $clientId, ')
          ..write('epoch: $epoch, ')
          ..write('originSessionId: $originSessionId, ')
          ..write('format: $format, ')
          ..write('fileName: $fileName, ')
          ..write('sourceSha256: $sourceSha256, ')
          ..write('createBodyJson: $createBodyJson, ')
          ..write('stateJson: $stateJson, ')
          ..write('expectedBytes: $expectedBytes, ')
          ..write('reservedBytes: $reservedBytes, ')
          ..write('createdAt: $createdAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $StageImportChunksTable extends StageImportChunks
    with TableInfo<$StageImportChunksTable, StoredStageImportChunk> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $StageImportChunksTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _spaceIdMeta = const VerificationMeta(
    'spaceId',
  );
  @override
  late final GeneratedColumn<String> spaceId = GeneratedColumn<String>(
    'space_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _stageIdMeta = const VerificationMeta(
    'stageId',
  );
  @override
  late final GeneratedColumn<String> stageId = GeneratedColumn<String>(
    'stage_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _chunkIndexMeta = const VerificationMeta(
    'chunkIndex',
  );
  @override
  late final GeneratedColumn<int> chunkIndex = GeneratedColumn<int>(
    'chunk_index',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _bodyMeta = const VerificationMeta('body');
  @override
  late final GeneratedColumn<Uint8List> body = GeneratedColumn<Uint8List>(
    'body',
    aliasedName,
    false,
    type: DriftSqlType.blob,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sha256Meta = const VerificationMeta('sha256');
  @override
  late final GeneratedColumn<String> sha256 = GeneratedColumn<String>(
    'sha256',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sizeBytesMeta = const VerificationMeta(
    'sizeBytes',
  );
  @override
  late final GeneratedColumn<int> sizeBytes = GeneratedColumn<int>(
    'size_bytes',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _receiptJsonMeta = const VerificationMeta(
    'receiptJson',
  );
  @override
  late final GeneratedColumn<String> receiptJson = GeneratedColumn<String>(
    'receipt_json',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    spaceId,
    stageId,
    chunkIndex,
    body,
    sha256,
    sizeBytes,
    receiptJson,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'stage_import_chunks';
  @override
  VerificationContext validateIntegrity(
    Insertable<StoredStageImportChunk> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('space_id')) {
      context.handle(
        _spaceIdMeta,
        spaceId.isAcceptableOrUnknown(data['space_id']!, _spaceIdMeta),
      );
    } else if (isInserting) {
      context.missing(_spaceIdMeta);
    }
    if (data.containsKey('stage_id')) {
      context.handle(
        _stageIdMeta,
        stageId.isAcceptableOrUnknown(data['stage_id']!, _stageIdMeta),
      );
    } else if (isInserting) {
      context.missing(_stageIdMeta);
    }
    if (data.containsKey('chunk_index')) {
      context.handle(
        _chunkIndexMeta,
        chunkIndex.isAcceptableOrUnknown(data['chunk_index']!, _chunkIndexMeta),
      );
    } else if (isInserting) {
      context.missing(_chunkIndexMeta);
    }
    if (data.containsKey('body')) {
      context.handle(
        _bodyMeta,
        body.isAcceptableOrUnknown(data['body']!, _bodyMeta),
      );
    } else if (isInserting) {
      context.missing(_bodyMeta);
    }
    if (data.containsKey('sha256')) {
      context.handle(
        _sha256Meta,
        sha256.isAcceptableOrUnknown(data['sha256']!, _sha256Meta),
      );
    } else if (isInserting) {
      context.missing(_sha256Meta);
    }
    if (data.containsKey('size_bytes')) {
      context.handle(
        _sizeBytesMeta,
        sizeBytes.isAcceptableOrUnknown(data['size_bytes']!, _sizeBytesMeta),
      );
    } else if (isInserting) {
      context.missing(_sizeBytesMeta);
    }
    if (data.containsKey('receipt_json')) {
      context.handle(
        _receiptJsonMeta,
        receiptJson.isAcceptableOrUnknown(
          data['receipt_json']!,
          _receiptJsonMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {spaceId, stageId, chunkIndex};
  @override
  StoredStageImportChunk map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return StoredStageImportChunk(
      spaceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}space_id'],
      )!,
      stageId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}stage_id'],
      )!,
      chunkIndex: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}chunk_index'],
      )!,
      body: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}body'],
      )!,
      sha256: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sha256'],
      )!,
      sizeBytes: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}size_bytes'],
      )!,
      receiptJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}receipt_json'],
      ),
    );
  }

  @override
  $StageImportChunksTable createAlias(String alias) {
    return $StageImportChunksTable(attachedDatabase, alias);
  }
}

class StoredStageImportChunk extends DataClass
    implements Insertable<StoredStageImportChunk> {
  final String spaceId;
  final String stageId;
  final int chunkIndex;
  final Uint8List body;
  final String sha256;
  final int sizeBytes;
  final String? receiptJson;
  const StoredStageImportChunk({
    required this.spaceId,
    required this.stageId,
    required this.chunkIndex,
    required this.body,
    required this.sha256,
    required this.sizeBytes,
    this.receiptJson,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['space_id'] = Variable<String>(spaceId);
    map['stage_id'] = Variable<String>(stageId);
    map['chunk_index'] = Variable<int>(chunkIndex);
    map['body'] = Variable<Uint8List>(body);
    map['sha256'] = Variable<String>(sha256);
    map['size_bytes'] = Variable<int>(sizeBytes);
    if (!nullToAbsent || receiptJson != null) {
      map['receipt_json'] = Variable<String>(receiptJson);
    }
    return map;
  }

  StageImportChunksCompanion toCompanion(bool nullToAbsent) {
    return StageImportChunksCompanion(
      spaceId: Value(spaceId),
      stageId: Value(stageId),
      chunkIndex: Value(chunkIndex),
      body: Value(body),
      sha256: Value(sha256),
      sizeBytes: Value(sizeBytes),
      receiptJson: receiptJson == null && nullToAbsent
          ? const Value.absent()
          : Value(receiptJson),
    );
  }

  factory StoredStageImportChunk.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return StoredStageImportChunk(
      spaceId: serializer.fromJson<String>(json['spaceId']),
      stageId: serializer.fromJson<String>(json['stageId']),
      chunkIndex: serializer.fromJson<int>(json['chunkIndex']),
      body: serializer.fromJson<Uint8List>(json['body']),
      sha256: serializer.fromJson<String>(json['sha256']),
      sizeBytes: serializer.fromJson<int>(json['sizeBytes']),
      receiptJson: serializer.fromJson<String?>(json['receiptJson']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'spaceId': serializer.toJson<String>(spaceId),
      'stageId': serializer.toJson<String>(stageId),
      'chunkIndex': serializer.toJson<int>(chunkIndex),
      'body': serializer.toJson<Uint8List>(body),
      'sha256': serializer.toJson<String>(sha256),
      'sizeBytes': serializer.toJson<int>(sizeBytes),
      'receiptJson': serializer.toJson<String?>(receiptJson),
    };
  }

  StoredStageImportChunk copyWith({
    String? spaceId,
    String? stageId,
    int? chunkIndex,
    Uint8List? body,
    String? sha256,
    int? sizeBytes,
    Value<String?> receiptJson = const Value.absent(),
  }) => StoredStageImportChunk(
    spaceId: spaceId ?? this.spaceId,
    stageId: stageId ?? this.stageId,
    chunkIndex: chunkIndex ?? this.chunkIndex,
    body: body ?? this.body,
    sha256: sha256 ?? this.sha256,
    sizeBytes: sizeBytes ?? this.sizeBytes,
    receiptJson: receiptJson.present ? receiptJson.value : this.receiptJson,
  );
  StoredStageImportChunk copyWithCompanion(StageImportChunksCompanion data) {
    return StoredStageImportChunk(
      spaceId: data.spaceId.present ? data.spaceId.value : this.spaceId,
      stageId: data.stageId.present ? data.stageId.value : this.stageId,
      chunkIndex: data.chunkIndex.present
          ? data.chunkIndex.value
          : this.chunkIndex,
      body: data.body.present ? data.body.value : this.body,
      sha256: data.sha256.present ? data.sha256.value : this.sha256,
      sizeBytes: data.sizeBytes.present ? data.sizeBytes.value : this.sizeBytes,
      receiptJson: data.receiptJson.present
          ? data.receiptJson.value
          : this.receiptJson,
    );
  }

  @override
  String toString() {
    return (StringBuffer('StoredStageImportChunk(')
          ..write('spaceId: $spaceId, ')
          ..write('stageId: $stageId, ')
          ..write('chunkIndex: $chunkIndex, ')
          ..write('body: $body, ')
          ..write('sha256: $sha256, ')
          ..write('sizeBytes: $sizeBytes, ')
          ..write('receiptJson: $receiptJson')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    spaceId,
    stageId,
    chunkIndex,
    $driftBlobEquality.hash(body),
    sha256,
    sizeBytes,
    receiptJson,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is StoredStageImportChunk &&
          other.spaceId == this.spaceId &&
          other.stageId == this.stageId &&
          other.chunkIndex == this.chunkIndex &&
          $driftBlobEquality.equals(other.body, this.body) &&
          other.sha256 == this.sha256 &&
          other.sizeBytes == this.sizeBytes &&
          other.receiptJson == this.receiptJson);
}

class StageImportChunksCompanion
    extends UpdateCompanion<StoredStageImportChunk> {
  final Value<String> spaceId;
  final Value<String> stageId;
  final Value<int> chunkIndex;
  final Value<Uint8List> body;
  final Value<String> sha256;
  final Value<int> sizeBytes;
  final Value<String?> receiptJson;
  final Value<int> rowid;
  const StageImportChunksCompanion({
    this.spaceId = const Value.absent(),
    this.stageId = const Value.absent(),
    this.chunkIndex = const Value.absent(),
    this.body = const Value.absent(),
    this.sha256 = const Value.absent(),
    this.sizeBytes = const Value.absent(),
    this.receiptJson = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  StageImportChunksCompanion.insert({
    required String spaceId,
    required String stageId,
    required int chunkIndex,
    required Uint8List body,
    required String sha256,
    required int sizeBytes,
    this.receiptJson = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : spaceId = Value(spaceId),
       stageId = Value(stageId),
       chunkIndex = Value(chunkIndex),
       body = Value(body),
       sha256 = Value(sha256),
       sizeBytes = Value(sizeBytes);
  static Insertable<StoredStageImportChunk> custom({
    Expression<String>? spaceId,
    Expression<String>? stageId,
    Expression<int>? chunkIndex,
    Expression<Uint8List>? body,
    Expression<String>? sha256,
    Expression<int>? sizeBytes,
    Expression<String>? receiptJson,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (spaceId != null) 'space_id': spaceId,
      if (stageId != null) 'stage_id': stageId,
      if (chunkIndex != null) 'chunk_index': chunkIndex,
      if (body != null) 'body': body,
      if (sha256 != null) 'sha256': sha256,
      if (sizeBytes != null) 'size_bytes': sizeBytes,
      if (receiptJson != null) 'receipt_json': receiptJson,
      if (rowid != null) 'rowid': rowid,
    });
  }

  StageImportChunksCompanion copyWith({
    Value<String>? spaceId,
    Value<String>? stageId,
    Value<int>? chunkIndex,
    Value<Uint8List>? body,
    Value<String>? sha256,
    Value<int>? sizeBytes,
    Value<String?>? receiptJson,
    Value<int>? rowid,
  }) {
    return StageImportChunksCompanion(
      spaceId: spaceId ?? this.spaceId,
      stageId: stageId ?? this.stageId,
      chunkIndex: chunkIndex ?? this.chunkIndex,
      body: body ?? this.body,
      sha256: sha256 ?? this.sha256,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      receiptJson: receiptJson ?? this.receiptJson,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (spaceId.present) {
      map['space_id'] = Variable<String>(spaceId.value);
    }
    if (stageId.present) {
      map['stage_id'] = Variable<String>(stageId.value);
    }
    if (chunkIndex.present) {
      map['chunk_index'] = Variable<int>(chunkIndex.value);
    }
    if (body.present) {
      map['body'] = Variable<Uint8List>(body.value);
    }
    if (sha256.present) {
      map['sha256'] = Variable<String>(sha256.value);
    }
    if (sizeBytes.present) {
      map['size_bytes'] = Variable<int>(sizeBytes.value);
    }
    if (receiptJson.present) {
      map['receipt_json'] = Variable<String>(receiptJson.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('StageImportChunksCompanion(')
          ..write('spaceId: $spaceId, ')
          ..write('stageId: $stageId, ')
          ..write('chunkIndex: $chunkIndex, ')
          ..write('body: $body, ')
          ..write('sha256: $sha256, ')
          ..write('sizeBytes: $sizeBytes, ')
          ..write('receiptJson: $receiptJson, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $StageImportCommandsTable extends StageImportCommands
    with TableInfo<$StageImportCommandsTable, StoredStageImportCommand> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $StageImportCommandsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _spaceIdMeta = const VerificationMeta(
    'spaceId',
  );
  @override
  late final GeneratedColumn<String> spaceId = GeneratedColumn<String>(
    'space_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _stageIdMeta = const VerificationMeta(
    'stageId',
  );
  @override
  late final GeneratedColumn<String> stageId = GeneratedColumn<String>(
    'stage_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _commandIdMeta = const VerificationMeta(
    'commandId',
  );
  @override
  late final GeneratedColumn<String> commandId = GeneratedColumn<String>(
    'command_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
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
  static const VerificationMeta _stageVersionMeta = const VerificationMeta(
    'stageVersion',
  );
  @override
  late final GeneratedColumn<int> stageVersion = GeneratedColumn<int>(
    'stage_version',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _bodyJsonMeta = const VerificationMeta(
    'bodyJson',
  );
  @override
  late final GeneratedColumn<String> bodyJson = GeneratedColumn<String>(
    'body_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _responseJsonMeta = const VerificationMeta(
    'responseJson',
  );
  @override
  late final GeneratedColumn<String> responseJson = GeneratedColumn<String>(
    'response_json',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _phaseMeta = const VerificationMeta('phase');
  @override
  late final GeneratedColumn<String> phase = GeneratedColumn<String>(
    'phase',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
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
  @override
  List<GeneratedColumn> get $columns => [
    spaceId,
    stageId,
    commandId,
    kind,
    stageVersion,
    bodyJson,
    responseJson,
    phase,
    createdAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'stage_import_commands';
  @override
  VerificationContext validateIntegrity(
    Insertable<StoredStageImportCommand> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('space_id')) {
      context.handle(
        _spaceIdMeta,
        spaceId.isAcceptableOrUnknown(data['space_id']!, _spaceIdMeta),
      );
    } else if (isInserting) {
      context.missing(_spaceIdMeta);
    }
    if (data.containsKey('stage_id')) {
      context.handle(
        _stageIdMeta,
        stageId.isAcceptableOrUnknown(data['stage_id']!, _stageIdMeta),
      );
    } else if (isInserting) {
      context.missing(_stageIdMeta);
    }
    if (data.containsKey('command_id')) {
      context.handle(
        _commandIdMeta,
        commandId.isAcceptableOrUnknown(data['command_id']!, _commandIdMeta),
      );
    } else if (isInserting) {
      context.missing(_commandIdMeta);
    }
    if (data.containsKey('kind')) {
      context.handle(
        _kindMeta,
        kind.isAcceptableOrUnknown(data['kind']!, _kindMeta),
      );
    } else if (isInserting) {
      context.missing(_kindMeta);
    }
    if (data.containsKey('stage_version')) {
      context.handle(
        _stageVersionMeta,
        stageVersion.isAcceptableOrUnknown(
          data['stage_version']!,
          _stageVersionMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_stageVersionMeta);
    }
    if (data.containsKey('body_json')) {
      context.handle(
        _bodyJsonMeta,
        bodyJson.isAcceptableOrUnknown(data['body_json']!, _bodyJsonMeta),
      );
    } else if (isInserting) {
      context.missing(_bodyJsonMeta);
    }
    if (data.containsKey('response_json')) {
      context.handle(
        _responseJsonMeta,
        responseJson.isAcceptableOrUnknown(
          data['response_json']!,
          _responseJsonMeta,
        ),
      );
    }
    if (data.containsKey('phase')) {
      context.handle(
        _phaseMeta,
        phase.isAcceptableOrUnknown(data['phase']!, _phaseMeta),
      );
    } else if (isInserting) {
      context.missing(_phaseMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {spaceId, stageId, commandId};
  @override
  StoredStageImportCommand map(
    Map<String, dynamic> data, {
    String? tablePrefix,
  }) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return StoredStageImportCommand(
      spaceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}space_id'],
      )!,
      stageId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}stage_id'],
      )!,
      commandId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}command_id'],
      )!,
      kind: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}kind'],
      )!,
      stageVersion: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}stage_version'],
      )!,
      bodyJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}body_json'],
      )!,
      responseJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}response_json'],
      ),
      phase: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}phase'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
    );
  }

  @override
  $StageImportCommandsTable createAlias(String alias) {
    return $StageImportCommandsTable(attachedDatabase, alias);
  }
}

class StoredStageImportCommand extends DataClass
    implements Insertable<StoredStageImportCommand> {
  final String spaceId;
  final String stageId;
  final String commandId;
  final String kind;
  final int stageVersion;
  final String bodyJson;
  final String? responseJson;
  final String phase;
  final DateTime createdAt;
  const StoredStageImportCommand({
    required this.spaceId,
    required this.stageId,
    required this.commandId,
    required this.kind,
    required this.stageVersion,
    required this.bodyJson,
    this.responseJson,
    required this.phase,
    required this.createdAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['space_id'] = Variable<String>(spaceId);
    map['stage_id'] = Variable<String>(stageId);
    map['command_id'] = Variable<String>(commandId);
    map['kind'] = Variable<String>(kind);
    map['stage_version'] = Variable<int>(stageVersion);
    map['body_json'] = Variable<String>(bodyJson);
    if (!nullToAbsent || responseJson != null) {
      map['response_json'] = Variable<String>(responseJson);
    }
    map['phase'] = Variable<String>(phase);
    map['created_at'] = Variable<DateTime>(createdAt);
    return map;
  }

  StageImportCommandsCompanion toCompanion(bool nullToAbsent) {
    return StageImportCommandsCompanion(
      spaceId: Value(spaceId),
      stageId: Value(stageId),
      commandId: Value(commandId),
      kind: Value(kind),
      stageVersion: Value(stageVersion),
      bodyJson: Value(bodyJson),
      responseJson: responseJson == null && nullToAbsent
          ? const Value.absent()
          : Value(responseJson),
      phase: Value(phase),
      createdAt: Value(createdAt),
    );
  }

  factory StoredStageImportCommand.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return StoredStageImportCommand(
      spaceId: serializer.fromJson<String>(json['spaceId']),
      stageId: serializer.fromJson<String>(json['stageId']),
      commandId: serializer.fromJson<String>(json['commandId']),
      kind: serializer.fromJson<String>(json['kind']),
      stageVersion: serializer.fromJson<int>(json['stageVersion']),
      bodyJson: serializer.fromJson<String>(json['bodyJson']),
      responseJson: serializer.fromJson<String?>(json['responseJson']),
      phase: serializer.fromJson<String>(json['phase']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'spaceId': serializer.toJson<String>(spaceId),
      'stageId': serializer.toJson<String>(stageId),
      'commandId': serializer.toJson<String>(commandId),
      'kind': serializer.toJson<String>(kind),
      'stageVersion': serializer.toJson<int>(stageVersion),
      'bodyJson': serializer.toJson<String>(bodyJson),
      'responseJson': serializer.toJson<String?>(responseJson),
      'phase': serializer.toJson<String>(phase),
      'createdAt': serializer.toJson<DateTime>(createdAt),
    };
  }

  StoredStageImportCommand copyWith({
    String? spaceId,
    String? stageId,
    String? commandId,
    String? kind,
    int? stageVersion,
    String? bodyJson,
    Value<String?> responseJson = const Value.absent(),
    String? phase,
    DateTime? createdAt,
  }) => StoredStageImportCommand(
    spaceId: spaceId ?? this.spaceId,
    stageId: stageId ?? this.stageId,
    commandId: commandId ?? this.commandId,
    kind: kind ?? this.kind,
    stageVersion: stageVersion ?? this.stageVersion,
    bodyJson: bodyJson ?? this.bodyJson,
    responseJson: responseJson.present ? responseJson.value : this.responseJson,
    phase: phase ?? this.phase,
    createdAt: createdAt ?? this.createdAt,
  );
  StoredStageImportCommand copyWithCompanion(
    StageImportCommandsCompanion data,
  ) {
    return StoredStageImportCommand(
      spaceId: data.spaceId.present ? data.spaceId.value : this.spaceId,
      stageId: data.stageId.present ? data.stageId.value : this.stageId,
      commandId: data.commandId.present ? data.commandId.value : this.commandId,
      kind: data.kind.present ? data.kind.value : this.kind,
      stageVersion: data.stageVersion.present
          ? data.stageVersion.value
          : this.stageVersion,
      bodyJson: data.bodyJson.present ? data.bodyJson.value : this.bodyJson,
      responseJson: data.responseJson.present
          ? data.responseJson.value
          : this.responseJson,
      phase: data.phase.present ? data.phase.value : this.phase,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('StoredStageImportCommand(')
          ..write('spaceId: $spaceId, ')
          ..write('stageId: $stageId, ')
          ..write('commandId: $commandId, ')
          ..write('kind: $kind, ')
          ..write('stageVersion: $stageVersion, ')
          ..write('bodyJson: $bodyJson, ')
          ..write('responseJson: $responseJson, ')
          ..write('phase: $phase, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    spaceId,
    stageId,
    commandId,
    kind,
    stageVersion,
    bodyJson,
    responseJson,
    phase,
    createdAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is StoredStageImportCommand &&
          other.spaceId == this.spaceId &&
          other.stageId == this.stageId &&
          other.commandId == this.commandId &&
          other.kind == this.kind &&
          other.stageVersion == this.stageVersion &&
          other.bodyJson == this.bodyJson &&
          other.responseJson == this.responseJson &&
          other.phase == this.phase &&
          other.createdAt == this.createdAt);
}

class StageImportCommandsCompanion
    extends UpdateCompanion<StoredStageImportCommand> {
  final Value<String> spaceId;
  final Value<String> stageId;
  final Value<String> commandId;
  final Value<String> kind;
  final Value<int> stageVersion;
  final Value<String> bodyJson;
  final Value<String?> responseJson;
  final Value<String> phase;
  final Value<DateTime> createdAt;
  final Value<int> rowid;
  const StageImportCommandsCompanion({
    this.spaceId = const Value.absent(),
    this.stageId = const Value.absent(),
    this.commandId = const Value.absent(),
    this.kind = const Value.absent(),
    this.stageVersion = const Value.absent(),
    this.bodyJson = const Value.absent(),
    this.responseJson = const Value.absent(),
    this.phase = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  StageImportCommandsCompanion.insert({
    required String spaceId,
    required String stageId,
    required String commandId,
    required String kind,
    required int stageVersion,
    required String bodyJson,
    this.responseJson = const Value.absent(),
    required String phase,
    required DateTime createdAt,
    this.rowid = const Value.absent(),
  }) : spaceId = Value(spaceId),
       stageId = Value(stageId),
       commandId = Value(commandId),
       kind = Value(kind),
       stageVersion = Value(stageVersion),
       bodyJson = Value(bodyJson),
       phase = Value(phase),
       createdAt = Value(createdAt);
  static Insertable<StoredStageImportCommand> custom({
    Expression<String>? spaceId,
    Expression<String>? stageId,
    Expression<String>? commandId,
    Expression<String>? kind,
    Expression<int>? stageVersion,
    Expression<String>? bodyJson,
    Expression<String>? responseJson,
    Expression<String>? phase,
    Expression<DateTime>? createdAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (spaceId != null) 'space_id': spaceId,
      if (stageId != null) 'stage_id': stageId,
      if (commandId != null) 'command_id': commandId,
      if (kind != null) 'kind': kind,
      if (stageVersion != null) 'stage_version': stageVersion,
      if (bodyJson != null) 'body_json': bodyJson,
      if (responseJson != null) 'response_json': responseJson,
      if (phase != null) 'phase': phase,
      if (createdAt != null) 'created_at': createdAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  StageImportCommandsCompanion copyWith({
    Value<String>? spaceId,
    Value<String>? stageId,
    Value<String>? commandId,
    Value<String>? kind,
    Value<int>? stageVersion,
    Value<String>? bodyJson,
    Value<String?>? responseJson,
    Value<String>? phase,
    Value<DateTime>? createdAt,
    Value<int>? rowid,
  }) {
    return StageImportCommandsCompanion(
      spaceId: spaceId ?? this.spaceId,
      stageId: stageId ?? this.stageId,
      commandId: commandId ?? this.commandId,
      kind: kind ?? this.kind,
      stageVersion: stageVersion ?? this.stageVersion,
      bodyJson: bodyJson ?? this.bodyJson,
      responseJson: responseJson ?? this.responseJson,
      phase: phase ?? this.phase,
      createdAt: createdAt ?? this.createdAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (spaceId.present) {
      map['space_id'] = Variable<String>(spaceId.value);
    }
    if (stageId.present) {
      map['stage_id'] = Variable<String>(stageId.value);
    }
    if (commandId.present) {
      map['command_id'] = Variable<String>(commandId.value);
    }
    if (kind.present) {
      map['kind'] = Variable<String>(kind.value);
    }
    if (stageVersion.present) {
      map['stage_version'] = Variable<int>(stageVersion.value);
    }
    if (bodyJson.present) {
      map['body_json'] = Variable<String>(bodyJson.value);
    }
    if (responseJson.present) {
      map['response_json'] = Variable<String>(responseJson.value);
    }
    if (phase.present) {
      map['phase'] = Variable<String>(phase.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('StageImportCommandsCompanion(')
          ..write('spaceId: $spaceId, ')
          ..write('stageId: $stageId, ')
          ..write('commandId: $commandId, ')
          ..write('kind: $kind, ')
          ..write('stageVersion: $stageVersion, ')
          ..write('bodyJson: $bodyJson, ')
          ..write('responseJson: $responseJson, ')
          ..write('phase: $phase, ')
          ..write('createdAt: $createdAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $StageImportRecoveryChunksTable extends StageImportRecoveryChunks
    with
        TableInfo<
          $StageImportRecoveryChunksTable,
          StoredStageImportRecoveryChunk
        > {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $StageImportRecoveryChunksTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _backupIdMeta = const VerificationMeta(
    'backupId',
  );
  @override
  late final GeneratedColumn<String> backupId = GeneratedColumn<String>(
    'backup_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES sync_recovery_backups (id)',
    ),
  );
  static const VerificationMeta _stageIdMeta = const VerificationMeta(
    'stageId',
  );
  @override
  late final GeneratedColumn<String> stageId = GeneratedColumn<String>(
    'stage_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _chunkIndexMeta = const VerificationMeta(
    'chunkIndex',
  );
  @override
  late final GeneratedColumn<int> chunkIndex = GeneratedColumn<int>(
    'chunk_index',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _bodyMeta = const VerificationMeta('body');
  @override
  late final GeneratedColumn<Uint8List> body = GeneratedColumn<Uint8List>(
    'body',
    aliasedName,
    false,
    type: DriftSqlType.blob,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sha256Meta = const VerificationMeta('sha256');
  @override
  late final GeneratedColumn<String> sha256 = GeneratedColumn<String>(
    'sha256',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sizeBytesMeta = const VerificationMeta(
    'sizeBytes',
  );
  @override
  late final GeneratedColumn<int> sizeBytes = GeneratedColumn<int>(
    'size_bytes',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    backupId,
    stageId,
    chunkIndex,
    body,
    sha256,
    sizeBytes,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'stage_import_recovery_chunks';
  @override
  VerificationContext validateIntegrity(
    Insertable<StoredStageImportRecoveryChunk> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('backup_id')) {
      context.handle(
        _backupIdMeta,
        backupId.isAcceptableOrUnknown(data['backup_id']!, _backupIdMeta),
      );
    } else if (isInserting) {
      context.missing(_backupIdMeta);
    }
    if (data.containsKey('stage_id')) {
      context.handle(
        _stageIdMeta,
        stageId.isAcceptableOrUnknown(data['stage_id']!, _stageIdMeta),
      );
    } else if (isInserting) {
      context.missing(_stageIdMeta);
    }
    if (data.containsKey('chunk_index')) {
      context.handle(
        _chunkIndexMeta,
        chunkIndex.isAcceptableOrUnknown(data['chunk_index']!, _chunkIndexMeta),
      );
    } else if (isInserting) {
      context.missing(_chunkIndexMeta);
    }
    if (data.containsKey('body')) {
      context.handle(
        _bodyMeta,
        body.isAcceptableOrUnknown(data['body']!, _bodyMeta),
      );
    } else if (isInserting) {
      context.missing(_bodyMeta);
    }
    if (data.containsKey('sha256')) {
      context.handle(
        _sha256Meta,
        sha256.isAcceptableOrUnknown(data['sha256']!, _sha256Meta),
      );
    } else if (isInserting) {
      context.missing(_sha256Meta);
    }
    if (data.containsKey('size_bytes')) {
      context.handle(
        _sizeBytesMeta,
        sizeBytes.isAcceptableOrUnknown(data['size_bytes']!, _sizeBytesMeta),
      );
    } else if (isInserting) {
      context.missing(_sizeBytesMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {backupId, stageId, chunkIndex};
  @override
  StoredStageImportRecoveryChunk map(
    Map<String, dynamic> data, {
    String? tablePrefix,
  }) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return StoredStageImportRecoveryChunk(
      backupId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}backup_id'],
      )!,
      stageId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}stage_id'],
      )!,
      chunkIndex: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}chunk_index'],
      )!,
      body: attachedDatabase.typeMapping.read(
        DriftSqlType.blob,
        data['${effectivePrefix}body'],
      )!,
      sha256: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sha256'],
      )!,
      sizeBytes: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}size_bytes'],
      )!,
    );
  }

  @override
  $StageImportRecoveryChunksTable createAlias(String alias) {
    return $StageImportRecoveryChunksTable(attachedDatabase, alias);
  }
}

class StoredStageImportRecoveryChunk extends DataClass
    implements Insertable<StoredStageImportRecoveryChunk> {
  final String backupId;
  final String stageId;
  final int chunkIndex;
  final Uint8List body;
  final String sha256;
  final int sizeBytes;
  const StoredStageImportRecoveryChunk({
    required this.backupId,
    required this.stageId,
    required this.chunkIndex,
    required this.body,
    required this.sha256,
    required this.sizeBytes,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['backup_id'] = Variable<String>(backupId);
    map['stage_id'] = Variable<String>(stageId);
    map['chunk_index'] = Variable<int>(chunkIndex);
    map['body'] = Variable<Uint8List>(body);
    map['sha256'] = Variable<String>(sha256);
    map['size_bytes'] = Variable<int>(sizeBytes);
    return map;
  }

  StageImportRecoveryChunksCompanion toCompanion(bool nullToAbsent) {
    return StageImportRecoveryChunksCompanion(
      backupId: Value(backupId),
      stageId: Value(stageId),
      chunkIndex: Value(chunkIndex),
      body: Value(body),
      sha256: Value(sha256),
      sizeBytes: Value(sizeBytes),
    );
  }

  factory StoredStageImportRecoveryChunk.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return StoredStageImportRecoveryChunk(
      backupId: serializer.fromJson<String>(json['backupId']),
      stageId: serializer.fromJson<String>(json['stageId']),
      chunkIndex: serializer.fromJson<int>(json['chunkIndex']),
      body: serializer.fromJson<Uint8List>(json['body']),
      sha256: serializer.fromJson<String>(json['sha256']),
      sizeBytes: serializer.fromJson<int>(json['sizeBytes']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'backupId': serializer.toJson<String>(backupId),
      'stageId': serializer.toJson<String>(stageId),
      'chunkIndex': serializer.toJson<int>(chunkIndex),
      'body': serializer.toJson<Uint8List>(body),
      'sha256': serializer.toJson<String>(sha256),
      'sizeBytes': serializer.toJson<int>(sizeBytes),
    };
  }

  StoredStageImportRecoveryChunk copyWith({
    String? backupId,
    String? stageId,
    int? chunkIndex,
    Uint8List? body,
    String? sha256,
    int? sizeBytes,
  }) => StoredStageImportRecoveryChunk(
    backupId: backupId ?? this.backupId,
    stageId: stageId ?? this.stageId,
    chunkIndex: chunkIndex ?? this.chunkIndex,
    body: body ?? this.body,
    sha256: sha256 ?? this.sha256,
    sizeBytes: sizeBytes ?? this.sizeBytes,
  );
  StoredStageImportRecoveryChunk copyWithCompanion(
    StageImportRecoveryChunksCompanion data,
  ) {
    return StoredStageImportRecoveryChunk(
      backupId: data.backupId.present ? data.backupId.value : this.backupId,
      stageId: data.stageId.present ? data.stageId.value : this.stageId,
      chunkIndex: data.chunkIndex.present
          ? data.chunkIndex.value
          : this.chunkIndex,
      body: data.body.present ? data.body.value : this.body,
      sha256: data.sha256.present ? data.sha256.value : this.sha256,
      sizeBytes: data.sizeBytes.present ? data.sizeBytes.value : this.sizeBytes,
    );
  }

  @override
  String toString() {
    return (StringBuffer('StoredStageImportRecoveryChunk(')
          ..write('backupId: $backupId, ')
          ..write('stageId: $stageId, ')
          ..write('chunkIndex: $chunkIndex, ')
          ..write('body: $body, ')
          ..write('sha256: $sha256, ')
          ..write('sizeBytes: $sizeBytes')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    backupId,
    stageId,
    chunkIndex,
    $driftBlobEquality.hash(body),
    sha256,
    sizeBytes,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is StoredStageImportRecoveryChunk &&
          other.backupId == this.backupId &&
          other.stageId == this.stageId &&
          other.chunkIndex == this.chunkIndex &&
          $driftBlobEquality.equals(other.body, this.body) &&
          other.sha256 == this.sha256 &&
          other.sizeBytes == this.sizeBytes);
}

class StageImportRecoveryChunksCompanion
    extends UpdateCompanion<StoredStageImportRecoveryChunk> {
  final Value<String> backupId;
  final Value<String> stageId;
  final Value<int> chunkIndex;
  final Value<Uint8List> body;
  final Value<String> sha256;
  final Value<int> sizeBytes;
  final Value<int> rowid;
  const StageImportRecoveryChunksCompanion({
    this.backupId = const Value.absent(),
    this.stageId = const Value.absent(),
    this.chunkIndex = const Value.absent(),
    this.body = const Value.absent(),
    this.sha256 = const Value.absent(),
    this.sizeBytes = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  StageImportRecoveryChunksCompanion.insert({
    required String backupId,
    required String stageId,
    required int chunkIndex,
    required Uint8List body,
    required String sha256,
    required int sizeBytes,
    this.rowid = const Value.absent(),
  }) : backupId = Value(backupId),
       stageId = Value(stageId),
       chunkIndex = Value(chunkIndex),
       body = Value(body),
       sha256 = Value(sha256),
       sizeBytes = Value(sizeBytes);
  static Insertable<StoredStageImportRecoveryChunk> custom({
    Expression<String>? backupId,
    Expression<String>? stageId,
    Expression<int>? chunkIndex,
    Expression<Uint8List>? body,
    Expression<String>? sha256,
    Expression<int>? sizeBytes,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (backupId != null) 'backup_id': backupId,
      if (stageId != null) 'stage_id': stageId,
      if (chunkIndex != null) 'chunk_index': chunkIndex,
      if (body != null) 'body': body,
      if (sha256 != null) 'sha256': sha256,
      if (sizeBytes != null) 'size_bytes': sizeBytes,
      if (rowid != null) 'rowid': rowid,
    });
  }

  StageImportRecoveryChunksCompanion copyWith({
    Value<String>? backupId,
    Value<String>? stageId,
    Value<int>? chunkIndex,
    Value<Uint8List>? body,
    Value<String>? sha256,
    Value<int>? sizeBytes,
    Value<int>? rowid,
  }) {
    return StageImportRecoveryChunksCompanion(
      backupId: backupId ?? this.backupId,
      stageId: stageId ?? this.stageId,
      chunkIndex: chunkIndex ?? this.chunkIndex,
      body: body ?? this.body,
      sha256: sha256 ?? this.sha256,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (backupId.present) {
      map['backup_id'] = Variable<String>(backupId.value);
    }
    if (stageId.present) {
      map['stage_id'] = Variable<String>(stageId.value);
    }
    if (chunkIndex.present) {
      map['chunk_index'] = Variable<int>(chunkIndex.value);
    }
    if (body.present) {
      map['body'] = Variable<Uint8List>(body.value);
    }
    if (sha256.present) {
      map['sha256'] = Variable<String>(sha256.value);
    }
    if (sizeBytes.present) {
      map['size_bytes'] = Variable<int>(sizeBytes.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('StageImportRecoveryChunksCompanion(')
          ..write('backupId: $backupId, ')
          ..write('stageId: $stageId, ')
          ..write('chunkIndex: $chunkIndex, ')
          ..write('body: $body, ')
          ..write('sha256: $sha256, ')
          ..write('sizeBytes: $sizeBytes, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $AppSettingsTable appSettings = $AppSettingsTable(this);
  late final $LocalSpacesTable localSpaces = $LocalSpacesTable(this);
  late final $LocalDraftsTable localDrafts = $LocalDraftsTable(this);
  late final $LocalEntitiesTable localEntities = $LocalEntitiesTable(this);
  late final $PendingOperationsTable pendingOperations =
      $PendingOperationsTable(this);
  late final $ServerShadowsTable serverShadows = $ServerShadowsTable(this);
  late final $SyncStatesTable syncStates = $SyncStatesTable(this);
  late final $SyncConflictsTable syncConflicts = $SyncConflictsTable(this);
  late final $SyncRecoveryBackupsTable syncRecoveryBackups =
      $SyncRecoveryBackupsTable(this);
  late final $SnapshotPagesTable snapshotPages = $SnapshotPagesTable(this);
  late final $GroupPullsTable groupPulls = $GroupPullsTable(this);
  late final $GroupPagesTable groupPages = $GroupPagesTable(this);
  late final $GroupReceiptsTable groupReceipts = $GroupReceiptsTable(this);
  late final $StageImportSourcesTable stageImportSources =
      $StageImportSourcesTable(this);
  late final $StageImportChunksTable stageImportChunks =
      $StageImportChunksTable(this);
  late final $StageImportCommandsTable stageImportCommands =
      $StageImportCommandsTable(this);
  late final $StageImportRecoveryChunksTable stageImportRecoveryChunks =
      $StageImportRecoveryChunksTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    appSettings,
    localSpaces,
    localDrafts,
    localEntities,
    pendingOperations,
    serverShadows,
    syncStates,
    syncConflicts,
    syncRecoveryBackups,
    snapshotPages,
    groupPulls,
    groupPages,
    groupReceipts,
    stageImportSources,
    stageImportChunks,
    stageImportCommands,
    stageImportRecoveryChunks,
  ];
}

typedef $$AppSettingsTableCreateCompanionBuilder =
    AppSettingsCompanion Function({
      required String key,
      required String value,
      Value<int> rowid,
    });
typedef $$AppSettingsTableUpdateCompanionBuilder =
    AppSettingsCompanion Function({
      Value<String> key,
      Value<String> value,
      Value<int> rowid,
    });

class $$AppSettingsTableFilterComposer
    extends Composer<_$AppDatabase, $AppSettingsTable> {
  $$AppSettingsTableFilterComposer({
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

class $$AppSettingsTableOrderingComposer
    extends Composer<_$AppDatabase, $AppSettingsTable> {
  $$AppSettingsTableOrderingComposer({
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

class $$AppSettingsTableAnnotationComposer
    extends Composer<_$AppDatabase, $AppSettingsTable> {
  $$AppSettingsTableAnnotationComposer({
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

class $$AppSettingsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $AppSettingsTable,
          AppSetting,
          $$AppSettingsTableFilterComposer,
          $$AppSettingsTableOrderingComposer,
          $$AppSettingsTableAnnotationComposer,
          $$AppSettingsTableCreateCompanionBuilder,
          $$AppSettingsTableUpdateCompanionBuilder,
          (
            AppSetting,
            BaseReferences<_$AppDatabase, $AppSettingsTable, AppSetting>,
          ),
          AppSetting,
          PrefetchHooks Function()
        > {
  $$AppSettingsTableTableManager(_$AppDatabase db, $AppSettingsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AppSettingsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AppSettingsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AppSettingsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> key = const Value.absent(),
                Value<String> value = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => AppSettingsCompanion(key: key, value: value, rowid: rowid),
          createCompanionCallback:
              ({
                required String key,
                required String value,
                Value<int> rowid = const Value.absent(),
              }) => AppSettingsCompanion.insert(
                key: key,
                value: value,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$AppSettingsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $AppSettingsTable,
      AppSetting,
      $$AppSettingsTableFilterComposer,
      $$AppSettingsTableOrderingComposer,
      $$AppSettingsTableAnnotationComposer,
      $$AppSettingsTableCreateCompanionBuilder,
      $$AppSettingsTableUpdateCompanionBuilder,
      (
        AppSetting,
        BaseReferences<_$AppDatabase, $AppSettingsTable, AppSetting>,
      ),
      AppSetting,
      PrefetchHooks Function()
    >;
typedef $$LocalSpacesTableCreateCompanionBuilder =
    LocalSpacesCompanion Function({
      required String id,
      required String serverAddress,
      required String serverInstanceId,
      required String userId,
      required DateTime createdAt,
      Value<int> rowid,
    });
typedef $$LocalSpacesTableUpdateCompanionBuilder =
    LocalSpacesCompanion Function({
      Value<String> id,
      Value<String> serverAddress,
      Value<String> serverInstanceId,
      Value<String> userId,
      Value<DateTime> createdAt,
      Value<int> rowid,
    });

final class $$LocalSpacesTableReferences
    extends BaseReferences<_$AppDatabase, $LocalSpacesTable, StoredSpace> {
  $$LocalSpacesTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$LocalDraftsTable, List<StoredDraft>>
  _localDraftsRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.localDrafts,
    aliasName: 'local_spaces__id__local_drafts__space_id',
  );

  $$LocalDraftsTableProcessedTableManager get localDraftsRefs {
    final manager = $$LocalDraftsTableTableManager(
      $_db,
      $_db.localDrafts,
    ).filter((f) => f.spaceId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_localDraftsRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$LocalEntitiesTable, List<StoredEntity>>
  _localEntitiesRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.localEntities,
    aliasName: 'local_spaces__id__local_entities__space_id',
  );

  $$LocalEntitiesTableProcessedTableManager get localEntitiesRefs {
    final manager = $$LocalEntitiesTableTableManager(
      $_db,
      $_db.localEntities,
    ).filter((f) => f.spaceId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_localEntitiesRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$PendingOperationsTable, List<StoredOperation>>
  _pendingOperationsRefsTable(_$AppDatabase db) =>
      MultiTypedResultKey.fromTable(
        db.pendingOperations,
        aliasName: 'local_spaces__id__pending_operations__space_id',
      );

  $$PendingOperationsTableProcessedTableManager get pendingOperationsRefs {
    final manager = $$PendingOperationsTableTableManager(
      $_db,
      $_db.pendingOperations,
    ).filter((f) => f.spaceId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(
      _pendingOperationsRefsTable($_db),
    );
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$ServerShadowsTable, List<ConfirmedEntity>>
  _serverShadowsRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.serverShadows,
    aliasName: 'local_spaces__id__server_shadows__space_id',
  );

  $$ServerShadowsTableProcessedTableManager get serverShadowsRefs {
    final manager = $$ServerShadowsTableTableManager(
      $_db,
      $_db.serverShadows,
    ).filter((f) => f.spaceId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_serverShadowsRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$SyncStatesTable, List<SpaceSyncState>>
  _syncStatesRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.syncStates,
    aliasName: 'local_spaces__id__sync_states__space_id',
  );

  $$SyncStatesTableProcessedTableManager get syncStatesRefs {
    final manager = $$SyncStatesTableTableManager(
      $_db,
      $_db.syncStates,
    ).filter((f) => f.spaceId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_syncStatesRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$SyncConflictsTable, List<StoredConflict>>
  _syncConflictsRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.syncConflicts,
    aliasName: 'local_spaces__id__sync_conflicts__space_id',
  );

  $$SyncConflictsTableProcessedTableManager get syncConflictsRefs {
    final manager = $$SyncConflictsTableTableManager(
      $_db,
      $_db.syncConflicts,
    ).filter((f) => f.spaceId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_syncConflictsRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$SyncRecoveryBackupsTable, List<RecoveryBackup>>
  _syncRecoveryBackupsRefsTable(_$AppDatabase db) =>
      MultiTypedResultKey.fromTable(
        db.syncRecoveryBackups,
        aliasName: 'local_spaces__id__sync_recovery_backups__space_id',
      );

  $$SyncRecoveryBackupsTableProcessedTableManager get syncRecoveryBackupsRefs {
    final manager = $$SyncRecoveryBackupsTableTableManager(
      $_db,
      $_db.syncRecoveryBackups,
    ).filter((f) => f.spaceId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(
      _syncRecoveryBackupsRefsTable($_db),
    );
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$SnapshotPagesTable, List<StagedSnapshotPage>>
  _snapshotPagesRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.snapshotPages,
    aliasName: 'local_spaces__id__snapshot_pages__space_id',
  );

  $$SnapshotPagesTableProcessedTableManager get snapshotPagesRefs {
    final manager = $$SnapshotPagesTableTableManager(
      $_db,
      $_db.snapshotPages,
    ).filter((f) => f.spaceId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_snapshotPagesRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$GroupPullsTable, List<StoredGroupPull>>
  _groupPullsRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.groupPulls,
    aliasName: 'local_spaces__id__group_pulls__space_id',
  );

  $$GroupPullsTableProcessedTableManager get groupPullsRefs {
    final manager = $$GroupPullsTableTableManager(
      $_db,
      $_db.groupPulls,
    ).filter((f) => f.spaceId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_groupPullsRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$GroupPagesTable, List<StoredGroupPage>>
  _groupPagesRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.groupPages,
    aliasName: 'local_spaces__id__group_pages__space_id',
  );

  $$GroupPagesTableProcessedTableManager get groupPagesRefs {
    final manager = $$GroupPagesTableTableManager(
      $_db,
      $_db.groupPages,
    ).filter((f) => f.spaceId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_groupPagesRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$GroupReceiptsTable, List<StoredGroupReceipt>>
  _groupReceiptsRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.groupReceipts,
    aliasName: 'local_spaces__id__group_receipts__space_id',
  );

  $$GroupReceiptsTableProcessedTableManager get groupReceiptsRefs {
    final manager = $$GroupReceiptsTableTableManager(
      $_db,
      $_db.groupReceipts,
    ).filter((f) => f.spaceId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_groupReceiptsRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<
    $StageImportSourcesTable,
    List<StoredStageImportSource>
  >
  _stageImportSourcesRefsTable(_$AppDatabase db) =>
      MultiTypedResultKey.fromTable(
        db.stageImportSources,
        aliasName: 'local_spaces__id__stage_import_sources__space_id',
      );

  $$StageImportSourcesTableProcessedTableManager get stageImportSourcesRefs {
    final manager = $$StageImportSourcesTableTableManager(
      $_db,
      $_db.stageImportSources,
    ).filter((f) => f.spaceId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(
      _stageImportSourcesRefsTable($_db),
    );
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$LocalSpacesTableFilterComposer
    extends Composer<_$AppDatabase, $LocalSpacesTable> {
  $$LocalSpacesTableFilterComposer({
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

  ColumnFilters<String> get serverAddress => $composableBuilder(
    column: $table.serverAddress,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get serverInstanceId => $composableBuilder(
    column: $table.serverInstanceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get userId => $composableBuilder(
    column: $table.userId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  Expression<bool> localDraftsRefs(
    Expression<bool> Function($$LocalDraftsTableFilterComposer f) f,
  ) {
    final $$LocalDraftsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.localDrafts,
      getReferencedColumn: (t) => t.spaceId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalDraftsTableFilterComposer(
            $db: $db,
            $table: $db.localDrafts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> localEntitiesRefs(
    Expression<bool> Function($$LocalEntitiesTableFilterComposer f) f,
  ) {
    final $$LocalEntitiesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.localEntities,
      getReferencedColumn: (t) => t.spaceId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalEntitiesTableFilterComposer(
            $db: $db,
            $table: $db.localEntities,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> pendingOperationsRefs(
    Expression<bool> Function($$PendingOperationsTableFilterComposer f) f,
  ) {
    final $$PendingOperationsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.pendingOperations,
      getReferencedColumn: (t) => t.spaceId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PendingOperationsTableFilterComposer(
            $db: $db,
            $table: $db.pendingOperations,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> serverShadowsRefs(
    Expression<bool> Function($$ServerShadowsTableFilterComposer f) f,
  ) {
    final $$ServerShadowsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.serverShadows,
      getReferencedColumn: (t) => t.spaceId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ServerShadowsTableFilterComposer(
            $db: $db,
            $table: $db.serverShadows,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> syncStatesRefs(
    Expression<bool> Function($$SyncStatesTableFilterComposer f) f,
  ) {
    final $$SyncStatesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.syncStates,
      getReferencedColumn: (t) => t.spaceId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SyncStatesTableFilterComposer(
            $db: $db,
            $table: $db.syncStates,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> syncConflictsRefs(
    Expression<bool> Function($$SyncConflictsTableFilterComposer f) f,
  ) {
    final $$SyncConflictsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.syncConflicts,
      getReferencedColumn: (t) => t.spaceId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SyncConflictsTableFilterComposer(
            $db: $db,
            $table: $db.syncConflicts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> syncRecoveryBackupsRefs(
    Expression<bool> Function($$SyncRecoveryBackupsTableFilterComposer f) f,
  ) {
    final $$SyncRecoveryBackupsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.syncRecoveryBackups,
      getReferencedColumn: (t) => t.spaceId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SyncRecoveryBackupsTableFilterComposer(
            $db: $db,
            $table: $db.syncRecoveryBackups,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> snapshotPagesRefs(
    Expression<bool> Function($$SnapshotPagesTableFilterComposer f) f,
  ) {
    final $$SnapshotPagesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.snapshotPages,
      getReferencedColumn: (t) => t.spaceId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SnapshotPagesTableFilterComposer(
            $db: $db,
            $table: $db.snapshotPages,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> groupPullsRefs(
    Expression<bool> Function($$GroupPullsTableFilterComposer f) f,
  ) {
    final $$GroupPullsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.groupPulls,
      getReferencedColumn: (t) => t.spaceId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$GroupPullsTableFilterComposer(
            $db: $db,
            $table: $db.groupPulls,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> groupPagesRefs(
    Expression<bool> Function($$GroupPagesTableFilterComposer f) f,
  ) {
    final $$GroupPagesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.groupPages,
      getReferencedColumn: (t) => t.spaceId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$GroupPagesTableFilterComposer(
            $db: $db,
            $table: $db.groupPages,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> groupReceiptsRefs(
    Expression<bool> Function($$GroupReceiptsTableFilterComposer f) f,
  ) {
    final $$GroupReceiptsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.groupReceipts,
      getReferencedColumn: (t) => t.spaceId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$GroupReceiptsTableFilterComposer(
            $db: $db,
            $table: $db.groupReceipts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> stageImportSourcesRefs(
    Expression<bool> Function($$StageImportSourcesTableFilterComposer f) f,
  ) {
    final $$StageImportSourcesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.stageImportSources,
      getReferencedColumn: (t) => t.spaceId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$StageImportSourcesTableFilterComposer(
            $db: $db,
            $table: $db.stageImportSources,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$LocalSpacesTableOrderingComposer
    extends Composer<_$AppDatabase, $LocalSpacesTable> {
  $$LocalSpacesTableOrderingComposer({
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

  ColumnOrderings<String> get serverAddress => $composableBuilder(
    column: $table.serverAddress,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get serverInstanceId => $composableBuilder(
    column: $table.serverInstanceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get userId => $composableBuilder(
    column: $table.userId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$LocalSpacesTableAnnotationComposer
    extends Composer<_$AppDatabase, $LocalSpacesTable> {
  $$LocalSpacesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get serverAddress => $composableBuilder(
    column: $table.serverAddress,
    builder: (column) => column,
  );

  GeneratedColumn<String> get serverInstanceId => $composableBuilder(
    column: $table.serverInstanceId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get userId =>
      $composableBuilder(column: $table.userId, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  Expression<T> localDraftsRefs<T extends Object>(
    Expression<T> Function($$LocalDraftsTableAnnotationComposer a) f,
  ) {
    final $$LocalDraftsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.localDrafts,
      getReferencedColumn: (t) => t.spaceId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalDraftsTableAnnotationComposer(
            $db: $db,
            $table: $db.localDrafts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> localEntitiesRefs<T extends Object>(
    Expression<T> Function($$LocalEntitiesTableAnnotationComposer a) f,
  ) {
    final $$LocalEntitiesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.localEntities,
      getReferencedColumn: (t) => t.spaceId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalEntitiesTableAnnotationComposer(
            $db: $db,
            $table: $db.localEntities,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> pendingOperationsRefs<T extends Object>(
    Expression<T> Function($$PendingOperationsTableAnnotationComposer a) f,
  ) {
    final $$PendingOperationsTableAnnotationComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.id,
          referencedTable: $db.pendingOperations,
          getReferencedColumn: (t) => t.spaceId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$PendingOperationsTableAnnotationComposer(
                $db: $db,
                $table: $db.pendingOperations,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return f(composer);
  }

  Expression<T> serverShadowsRefs<T extends Object>(
    Expression<T> Function($$ServerShadowsTableAnnotationComposer a) f,
  ) {
    final $$ServerShadowsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.serverShadows,
      getReferencedColumn: (t) => t.spaceId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ServerShadowsTableAnnotationComposer(
            $db: $db,
            $table: $db.serverShadows,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> syncStatesRefs<T extends Object>(
    Expression<T> Function($$SyncStatesTableAnnotationComposer a) f,
  ) {
    final $$SyncStatesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.syncStates,
      getReferencedColumn: (t) => t.spaceId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SyncStatesTableAnnotationComposer(
            $db: $db,
            $table: $db.syncStates,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> syncConflictsRefs<T extends Object>(
    Expression<T> Function($$SyncConflictsTableAnnotationComposer a) f,
  ) {
    final $$SyncConflictsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.syncConflicts,
      getReferencedColumn: (t) => t.spaceId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SyncConflictsTableAnnotationComposer(
            $db: $db,
            $table: $db.syncConflicts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> syncRecoveryBackupsRefs<T extends Object>(
    Expression<T> Function($$SyncRecoveryBackupsTableAnnotationComposer a) f,
  ) {
    final $$SyncRecoveryBackupsTableAnnotationComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.id,
          referencedTable: $db.syncRecoveryBackups,
          getReferencedColumn: (t) => t.spaceId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$SyncRecoveryBackupsTableAnnotationComposer(
                $db: $db,
                $table: $db.syncRecoveryBackups,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return f(composer);
  }

  Expression<T> snapshotPagesRefs<T extends Object>(
    Expression<T> Function($$SnapshotPagesTableAnnotationComposer a) f,
  ) {
    final $$SnapshotPagesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.snapshotPages,
      getReferencedColumn: (t) => t.spaceId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SnapshotPagesTableAnnotationComposer(
            $db: $db,
            $table: $db.snapshotPages,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> groupPullsRefs<T extends Object>(
    Expression<T> Function($$GroupPullsTableAnnotationComposer a) f,
  ) {
    final $$GroupPullsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.groupPulls,
      getReferencedColumn: (t) => t.spaceId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$GroupPullsTableAnnotationComposer(
            $db: $db,
            $table: $db.groupPulls,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> groupPagesRefs<T extends Object>(
    Expression<T> Function($$GroupPagesTableAnnotationComposer a) f,
  ) {
    final $$GroupPagesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.groupPages,
      getReferencedColumn: (t) => t.spaceId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$GroupPagesTableAnnotationComposer(
            $db: $db,
            $table: $db.groupPages,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> groupReceiptsRefs<T extends Object>(
    Expression<T> Function($$GroupReceiptsTableAnnotationComposer a) f,
  ) {
    final $$GroupReceiptsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.groupReceipts,
      getReferencedColumn: (t) => t.spaceId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$GroupReceiptsTableAnnotationComposer(
            $db: $db,
            $table: $db.groupReceipts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> stageImportSourcesRefs<T extends Object>(
    Expression<T> Function($$StageImportSourcesTableAnnotationComposer a) f,
  ) {
    final $$StageImportSourcesTableAnnotationComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.id,
          referencedTable: $db.stageImportSources,
          getReferencedColumn: (t) => t.spaceId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$StageImportSourcesTableAnnotationComposer(
                $db: $db,
                $table: $db.stageImportSources,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return f(composer);
  }
}

class $$LocalSpacesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $LocalSpacesTable,
          StoredSpace,
          $$LocalSpacesTableFilterComposer,
          $$LocalSpacesTableOrderingComposer,
          $$LocalSpacesTableAnnotationComposer,
          $$LocalSpacesTableCreateCompanionBuilder,
          $$LocalSpacesTableUpdateCompanionBuilder,
          (StoredSpace, $$LocalSpacesTableReferences),
          StoredSpace,
          PrefetchHooks Function({
            bool localDraftsRefs,
            bool localEntitiesRefs,
            bool pendingOperationsRefs,
            bool serverShadowsRefs,
            bool syncStatesRefs,
            bool syncConflictsRefs,
            bool syncRecoveryBackupsRefs,
            bool snapshotPagesRefs,
            bool groupPullsRefs,
            bool groupPagesRefs,
            bool groupReceiptsRefs,
            bool stageImportSourcesRefs,
          })
        > {
  $$LocalSpacesTableTableManager(_$AppDatabase db, $LocalSpacesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LocalSpacesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LocalSpacesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LocalSpacesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> serverAddress = const Value.absent(),
                Value<String> serverInstanceId = const Value.absent(),
                Value<String> userId = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LocalSpacesCompanion(
                id: id,
                serverAddress: serverAddress,
                serverInstanceId: serverInstanceId,
                userId: userId,
                createdAt: createdAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String serverAddress,
                required String serverInstanceId,
                required String userId,
                required DateTime createdAt,
                Value<int> rowid = const Value.absent(),
              }) => LocalSpacesCompanion.insert(
                id: id,
                serverAddress: serverAddress,
                serverInstanceId: serverInstanceId,
                userId: userId,
                createdAt: createdAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$LocalSpacesTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback:
              ({
                localDraftsRefs = false,
                localEntitiesRefs = false,
                pendingOperationsRefs = false,
                serverShadowsRefs = false,
                syncStatesRefs = false,
                syncConflictsRefs = false,
                syncRecoveryBackupsRefs = false,
                snapshotPagesRefs = false,
                groupPullsRefs = false,
                groupPagesRefs = false,
                groupReceiptsRefs = false,
                stageImportSourcesRefs = false,
              }) {
                return PrefetchHooks(
                  db: db,
                  explicitlyWatchedTables: [
                    if (localDraftsRefs) db.localDrafts,
                    if (localEntitiesRefs) db.localEntities,
                    if (pendingOperationsRefs) db.pendingOperations,
                    if (serverShadowsRefs) db.serverShadows,
                    if (syncStatesRefs) db.syncStates,
                    if (syncConflictsRefs) db.syncConflicts,
                    if (syncRecoveryBackupsRefs) db.syncRecoveryBackups,
                    if (snapshotPagesRefs) db.snapshotPages,
                    if (groupPullsRefs) db.groupPulls,
                    if (groupPagesRefs) db.groupPages,
                    if (groupReceiptsRefs) db.groupReceipts,
                    if (stageImportSourcesRefs) db.stageImportSources,
                  ],
                  addJoins: null,
                  getPrefetchedDataCallback: (items) async {
                    return [
                      if (localDraftsRefs)
                        await $_getPrefetchedData<
                          StoredSpace,
                          $LocalSpacesTable,
                          StoredDraft
                        >(
                          currentTable: table,
                          referencedTable: $$LocalSpacesTableReferences
                              ._localDraftsRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$LocalSpacesTableReferences(
                                db,
                                table,
                                p0,
                              ).localDraftsRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.spaceId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (localEntitiesRefs)
                        await $_getPrefetchedData<
                          StoredSpace,
                          $LocalSpacesTable,
                          StoredEntity
                        >(
                          currentTable: table,
                          referencedTable: $$LocalSpacesTableReferences
                              ._localEntitiesRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$LocalSpacesTableReferences(
                                db,
                                table,
                                p0,
                              ).localEntitiesRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.spaceId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (pendingOperationsRefs)
                        await $_getPrefetchedData<
                          StoredSpace,
                          $LocalSpacesTable,
                          StoredOperation
                        >(
                          currentTable: table,
                          referencedTable: $$LocalSpacesTableReferences
                              ._pendingOperationsRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$LocalSpacesTableReferences(
                                db,
                                table,
                                p0,
                              ).pendingOperationsRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.spaceId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (serverShadowsRefs)
                        await $_getPrefetchedData<
                          StoredSpace,
                          $LocalSpacesTable,
                          ConfirmedEntity
                        >(
                          currentTable: table,
                          referencedTable: $$LocalSpacesTableReferences
                              ._serverShadowsRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$LocalSpacesTableReferences(
                                db,
                                table,
                                p0,
                              ).serverShadowsRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.spaceId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (syncStatesRefs)
                        await $_getPrefetchedData<
                          StoredSpace,
                          $LocalSpacesTable,
                          SpaceSyncState
                        >(
                          currentTable: table,
                          referencedTable: $$LocalSpacesTableReferences
                              ._syncStatesRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$LocalSpacesTableReferences(
                                db,
                                table,
                                p0,
                              ).syncStatesRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.spaceId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (syncConflictsRefs)
                        await $_getPrefetchedData<
                          StoredSpace,
                          $LocalSpacesTable,
                          StoredConflict
                        >(
                          currentTable: table,
                          referencedTable: $$LocalSpacesTableReferences
                              ._syncConflictsRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$LocalSpacesTableReferences(
                                db,
                                table,
                                p0,
                              ).syncConflictsRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.spaceId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (syncRecoveryBackupsRefs)
                        await $_getPrefetchedData<
                          StoredSpace,
                          $LocalSpacesTable,
                          RecoveryBackup
                        >(
                          currentTable: table,
                          referencedTable: $$LocalSpacesTableReferences
                              ._syncRecoveryBackupsRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$LocalSpacesTableReferences(
                                db,
                                table,
                                p0,
                              ).syncRecoveryBackupsRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.spaceId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (snapshotPagesRefs)
                        await $_getPrefetchedData<
                          StoredSpace,
                          $LocalSpacesTable,
                          StagedSnapshotPage
                        >(
                          currentTable: table,
                          referencedTable: $$LocalSpacesTableReferences
                              ._snapshotPagesRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$LocalSpacesTableReferences(
                                db,
                                table,
                                p0,
                              ).snapshotPagesRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.spaceId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (groupPullsRefs)
                        await $_getPrefetchedData<
                          StoredSpace,
                          $LocalSpacesTable,
                          StoredGroupPull
                        >(
                          currentTable: table,
                          referencedTable: $$LocalSpacesTableReferences
                              ._groupPullsRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$LocalSpacesTableReferences(
                                db,
                                table,
                                p0,
                              ).groupPullsRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.spaceId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (groupPagesRefs)
                        await $_getPrefetchedData<
                          StoredSpace,
                          $LocalSpacesTable,
                          StoredGroupPage
                        >(
                          currentTable: table,
                          referencedTable: $$LocalSpacesTableReferences
                              ._groupPagesRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$LocalSpacesTableReferences(
                                db,
                                table,
                                p0,
                              ).groupPagesRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.spaceId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (groupReceiptsRefs)
                        await $_getPrefetchedData<
                          StoredSpace,
                          $LocalSpacesTable,
                          StoredGroupReceipt
                        >(
                          currentTable: table,
                          referencedTable: $$LocalSpacesTableReferences
                              ._groupReceiptsRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$LocalSpacesTableReferences(
                                db,
                                table,
                                p0,
                              ).groupReceiptsRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.spaceId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (stageImportSourcesRefs)
                        await $_getPrefetchedData<
                          StoredSpace,
                          $LocalSpacesTable,
                          StoredStageImportSource
                        >(
                          currentTable: table,
                          referencedTable: $$LocalSpacesTableReferences
                              ._stageImportSourcesRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$LocalSpacesTableReferences(
                                db,
                                table,
                                p0,
                              ).stageImportSourcesRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.spaceId == item.id,
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

typedef $$LocalSpacesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $LocalSpacesTable,
      StoredSpace,
      $$LocalSpacesTableFilterComposer,
      $$LocalSpacesTableOrderingComposer,
      $$LocalSpacesTableAnnotationComposer,
      $$LocalSpacesTableCreateCompanionBuilder,
      $$LocalSpacesTableUpdateCompanionBuilder,
      (StoredSpace, $$LocalSpacesTableReferences),
      StoredSpace,
      PrefetchHooks Function({
        bool localDraftsRefs,
        bool localEntitiesRefs,
        bool pendingOperationsRefs,
        bool serverShadowsRefs,
        bool syncStatesRefs,
        bool syncConflictsRefs,
        bool syncRecoveryBackupsRefs,
        bool snapshotPagesRefs,
        bool groupPullsRefs,
        bool groupPagesRefs,
        bool groupReceiptsRefs,
        bool stageImportSourcesRefs,
      })
    >;
typedef $$LocalDraftsTableCreateCompanionBuilder =
    LocalDraftsCompanion Function({
      required String id,
      required String spaceId,
      required String body,
      required DateTime createdAt,
      required DateTime updatedAt,
      Value<int> rowid,
    });
typedef $$LocalDraftsTableUpdateCompanionBuilder =
    LocalDraftsCompanion Function({
      Value<String> id,
      Value<String> spaceId,
      Value<String> body,
      Value<DateTime> createdAt,
      Value<DateTime> updatedAt,
      Value<int> rowid,
    });

final class $$LocalDraftsTableReferences
    extends BaseReferences<_$AppDatabase, $LocalDraftsTable, StoredDraft> {
  $$LocalDraftsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $LocalSpacesTable _spaceIdTable(_$AppDatabase db) =>
      db.localSpaces.createAlias('local_drafts__space_id__local_spaces__id');

  $$LocalSpacesTableProcessedTableManager get spaceId {
    final $_column = $_itemColumn<String>('space_id')!;

    final manager = $$LocalSpacesTableTableManager(
      $_db,
      $_db.localSpaces,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_spaceIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$LocalDraftsTableFilterComposer
    extends Composer<_$AppDatabase, $LocalDraftsTable> {
  $$LocalDraftsTableFilterComposer({
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

  ColumnFilters<String> get body => $composableBuilder(
    column: $table.body,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  $$LocalSpacesTableFilterComposer get spaceId {
    final $$LocalSpacesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.spaceId,
      referencedTable: $db.localSpaces,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalSpacesTableFilterComposer(
            $db: $db,
            $table: $db.localSpaces,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$LocalDraftsTableOrderingComposer
    extends Composer<_$AppDatabase, $LocalDraftsTable> {
  $$LocalDraftsTableOrderingComposer({
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

  ColumnOrderings<String> get body => $composableBuilder(
    column: $table.body,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  $$LocalSpacesTableOrderingComposer get spaceId {
    final $$LocalSpacesTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.spaceId,
      referencedTable: $db.localSpaces,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalSpacesTableOrderingComposer(
            $db: $db,
            $table: $db.localSpaces,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$LocalDraftsTableAnnotationComposer
    extends Composer<_$AppDatabase, $LocalDraftsTable> {
  $$LocalDraftsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get body =>
      $composableBuilder(column: $table.body, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  $$LocalSpacesTableAnnotationComposer get spaceId {
    final $$LocalSpacesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.spaceId,
      referencedTable: $db.localSpaces,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalSpacesTableAnnotationComposer(
            $db: $db,
            $table: $db.localSpaces,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$LocalDraftsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $LocalDraftsTable,
          StoredDraft,
          $$LocalDraftsTableFilterComposer,
          $$LocalDraftsTableOrderingComposer,
          $$LocalDraftsTableAnnotationComposer,
          $$LocalDraftsTableCreateCompanionBuilder,
          $$LocalDraftsTableUpdateCompanionBuilder,
          (StoredDraft, $$LocalDraftsTableReferences),
          StoredDraft,
          PrefetchHooks Function({bool spaceId})
        > {
  $$LocalDraftsTableTableManager(_$AppDatabase db, $LocalDraftsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LocalDraftsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LocalDraftsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LocalDraftsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> spaceId = const Value.absent(),
                Value<String> body = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LocalDraftsCompanion(
                id: id,
                spaceId: spaceId,
                body: body,
                createdAt: createdAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String spaceId,
                required String body,
                required DateTime createdAt,
                required DateTime updatedAt,
                Value<int> rowid = const Value.absent(),
              }) => LocalDraftsCompanion.insert(
                id: id,
                spaceId: spaceId,
                body: body,
                createdAt: createdAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$LocalDraftsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({spaceId = false}) {
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
                    if (spaceId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.spaceId,
                                referencedTable: $$LocalDraftsTableReferences
                                    ._spaceIdTable(db),
                                referencedColumn: $$LocalDraftsTableReferences
                                    ._spaceIdTable(db)
                                    .id,
                              )
                              as T;
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

typedef $$LocalDraftsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $LocalDraftsTable,
      StoredDraft,
      $$LocalDraftsTableFilterComposer,
      $$LocalDraftsTableOrderingComposer,
      $$LocalDraftsTableAnnotationComposer,
      $$LocalDraftsTableCreateCompanionBuilder,
      $$LocalDraftsTableUpdateCompanionBuilder,
      (StoredDraft, $$LocalDraftsTableReferences),
      StoredDraft,
      PrefetchHooks Function({bool spaceId})
    >;
typedef $$LocalEntitiesTableCreateCompanionBuilder =
    LocalEntitiesCompanion Function({
      required String spaceId,
      Value<String> scopeId,
      required String entityType,
      required String entityId,
      required String dataJson,
      Value<String> serverRevision,
      Value<bool> deleted,
      required DateTime updatedAt,
      Value<int> rowid,
    });
typedef $$LocalEntitiesTableUpdateCompanionBuilder =
    LocalEntitiesCompanion Function({
      Value<String> spaceId,
      Value<String> scopeId,
      Value<String> entityType,
      Value<String> entityId,
      Value<String> dataJson,
      Value<String> serverRevision,
      Value<bool> deleted,
      Value<DateTime> updatedAt,
      Value<int> rowid,
    });

final class $$LocalEntitiesTableReferences
    extends BaseReferences<_$AppDatabase, $LocalEntitiesTable, StoredEntity> {
  $$LocalEntitiesTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $LocalSpacesTable _spaceIdTable(_$AppDatabase db) =>
      db.localSpaces.createAlias('local_entities__space_id__local_spaces__id');

  $$LocalSpacesTableProcessedTableManager get spaceId {
    final $_column = $_itemColumn<String>('space_id')!;

    final manager = $$LocalSpacesTableTableManager(
      $_db,
      $_db.localSpaces,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_spaceIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$LocalEntitiesTableFilterComposer
    extends Composer<_$AppDatabase, $LocalEntitiesTable> {
  $$LocalEntitiesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get scopeId => $composableBuilder(
    column: $table.scopeId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get entityType => $composableBuilder(
    column: $table.entityType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get entityId => $composableBuilder(
    column: $table.entityId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get dataJson => $composableBuilder(
    column: $table.dataJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get serverRevision => $composableBuilder(
    column: $table.serverRevision,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get deleted => $composableBuilder(
    column: $table.deleted,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  $$LocalSpacesTableFilterComposer get spaceId {
    final $$LocalSpacesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.spaceId,
      referencedTable: $db.localSpaces,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalSpacesTableFilterComposer(
            $db: $db,
            $table: $db.localSpaces,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$LocalEntitiesTableOrderingComposer
    extends Composer<_$AppDatabase, $LocalEntitiesTable> {
  $$LocalEntitiesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get scopeId => $composableBuilder(
    column: $table.scopeId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get entityType => $composableBuilder(
    column: $table.entityType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get entityId => $composableBuilder(
    column: $table.entityId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get dataJson => $composableBuilder(
    column: $table.dataJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get serverRevision => $composableBuilder(
    column: $table.serverRevision,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get deleted => $composableBuilder(
    column: $table.deleted,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  $$LocalSpacesTableOrderingComposer get spaceId {
    final $$LocalSpacesTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.spaceId,
      referencedTable: $db.localSpaces,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalSpacesTableOrderingComposer(
            $db: $db,
            $table: $db.localSpaces,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$LocalEntitiesTableAnnotationComposer
    extends Composer<_$AppDatabase, $LocalEntitiesTable> {
  $$LocalEntitiesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get scopeId =>
      $composableBuilder(column: $table.scopeId, builder: (column) => column);

  GeneratedColumn<String> get entityType => $composableBuilder(
    column: $table.entityType,
    builder: (column) => column,
  );

  GeneratedColumn<String> get entityId =>
      $composableBuilder(column: $table.entityId, builder: (column) => column);

  GeneratedColumn<String> get dataJson =>
      $composableBuilder(column: $table.dataJson, builder: (column) => column);

  GeneratedColumn<String> get serverRevision => $composableBuilder(
    column: $table.serverRevision,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get deleted =>
      $composableBuilder(column: $table.deleted, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  $$LocalSpacesTableAnnotationComposer get spaceId {
    final $$LocalSpacesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.spaceId,
      referencedTable: $db.localSpaces,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalSpacesTableAnnotationComposer(
            $db: $db,
            $table: $db.localSpaces,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$LocalEntitiesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $LocalEntitiesTable,
          StoredEntity,
          $$LocalEntitiesTableFilterComposer,
          $$LocalEntitiesTableOrderingComposer,
          $$LocalEntitiesTableAnnotationComposer,
          $$LocalEntitiesTableCreateCompanionBuilder,
          $$LocalEntitiesTableUpdateCompanionBuilder,
          (StoredEntity, $$LocalEntitiesTableReferences),
          StoredEntity,
          PrefetchHooks Function({bool spaceId})
        > {
  $$LocalEntitiesTableTableManager(_$AppDatabase db, $LocalEntitiesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LocalEntitiesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LocalEntitiesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LocalEntitiesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> spaceId = const Value.absent(),
                Value<String> scopeId = const Value.absent(),
                Value<String> entityType = const Value.absent(),
                Value<String> entityId = const Value.absent(),
                Value<String> dataJson = const Value.absent(),
                Value<String> serverRevision = const Value.absent(),
                Value<bool> deleted = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LocalEntitiesCompanion(
                spaceId: spaceId,
                scopeId: scopeId,
                entityType: entityType,
                entityId: entityId,
                dataJson: dataJson,
                serverRevision: serverRevision,
                deleted: deleted,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String spaceId,
                Value<String> scopeId = const Value.absent(),
                required String entityType,
                required String entityId,
                required String dataJson,
                Value<String> serverRevision = const Value.absent(),
                Value<bool> deleted = const Value.absent(),
                required DateTime updatedAt,
                Value<int> rowid = const Value.absent(),
              }) => LocalEntitiesCompanion.insert(
                spaceId: spaceId,
                scopeId: scopeId,
                entityType: entityType,
                entityId: entityId,
                dataJson: dataJson,
                serverRevision: serverRevision,
                deleted: deleted,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$LocalEntitiesTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({spaceId = false}) {
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
                    if (spaceId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.spaceId,
                                referencedTable: $$LocalEntitiesTableReferences
                                    ._spaceIdTable(db),
                                referencedColumn: $$LocalEntitiesTableReferences
                                    ._spaceIdTable(db)
                                    .id,
                              )
                              as T;
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

typedef $$LocalEntitiesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $LocalEntitiesTable,
      StoredEntity,
      $$LocalEntitiesTableFilterComposer,
      $$LocalEntitiesTableOrderingComposer,
      $$LocalEntitiesTableAnnotationComposer,
      $$LocalEntitiesTableCreateCompanionBuilder,
      $$LocalEntitiesTableUpdateCompanionBuilder,
      (StoredEntity, $$LocalEntitiesTableReferences),
      StoredEntity,
      PrefetchHooks Function({bool spaceId})
    >;
typedef $$PendingOperationsTableCreateCompanionBuilder =
    PendingOperationsCompanion Function({
      Value<int> sequence,
      required String spaceId,
      required String operationId,
      required String entityType,
      required String entityId,
      required String operationJson,
      Value<String?> frozenRequestJson,
      Value<String> state,
      Value<int> attemptCount,
      Value<String?> lastErrorCode,
      Value<String?> predecessorId,
      Value<String?> appliedRevision,
      Value<String?> baseDataJson,
      required DateTime createdAt,
    });
typedef $$PendingOperationsTableUpdateCompanionBuilder =
    PendingOperationsCompanion Function({
      Value<int> sequence,
      Value<String> spaceId,
      Value<String> operationId,
      Value<String> entityType,
      Value<String> entityId,
      Value<String> operationJson,
      Value<String?> frozenRequestJson,
      Value<String> state,
      Value<int> attemptCount,
      Value<String?> lastErrorCode,
      Value<String?> predecessorId,
      Value<String?> appliedRevision,
      Value<String?> baseDataJson,
      Value<DateTime> createdAt,
    });

final class $$PendingOperationsTableReferences
    extends
        BaseReferences<
          _$AppDatabase,
          $PendingOperationsTable,
          StoredOperation
        > {
  $$PendingOperationsTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $LocalSpacesTable _spaceIdTable(_$AppDatabase db) => db.localSpaces
      .createAlias('pending_operations__space_id__local_spaces__id');

  $$LocalSpacesTableProcessedTableManager get spaceId {
    final $_column = $_itemColumn<String>('space_id')!;

    final manager = $$LocalSpacesTableTableManager(
      $_db,
      $_db.localSpaces,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_spaceIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$PendingOperationsTableFilterComposer
    extends Composer<_$AppDatabase, $PendingOperationsTable> {
  $$PendingOperationsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get sequence => $composableBuilder(
    column: $table.sequence,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get operationId => $composableBuilder(
    column: $table.operationId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get entityType => $composableBuilder(
    column: $table.entityType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get entityId => $composableBuilder(
    column: $table.entityId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get operationJson => $composableBuilder(
    column: $table.operationJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get frozenRequestJson => $composableBuilder(
    column: $table.frozenRequestJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get state => $composableBuilder(
    column: $table.state,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get attemptCount => $composableBuilder(
    column: $table.attemptCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get lastErrorCode => $composableBuilder(
    column: $table.lastErrorCode,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get predecessorId => $composableBuilder(
    column: $table.predecessorId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get appliedRevision => $composableBuilder(
    column: $table.appliedRevision,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get baseDataJson => $composableBuilder(
    column: $table.baseDataJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  $$LocalSpacesTableFilterComposer get spaceId {
    final $$LocalSpacesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.spaceId,
      referencedTable: $db.localSpaces,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalSpacesTableFilterComposer(
            $db: $db,
            $table: $db.localSpaces,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$PendingOperationsTableOrderingComposer
    extends Composer<_$AppDatabase, $PendingOperationsTable> {
  $$PendingOperationsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get sequence => $composableBuilder(
    column: $table.sequence,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get operationId => $composableBuilder(
    column: $table.operationId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get entityType => $composableBuilder(
    column: $table.entityType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get entityId => $composableBuilder(
    column: $table.entityId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get operationJson => $composableBuilder(
    column: $table.operationJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get frozenRequestJson => $composableBuilder(
    column: $table.frozenRequestJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get state => $composableBuilder(
    column: $table.state,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get attemptCount => $composableBuilder(
    column: $table.attemptCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get lastErrorCode => $composableBuilder(
    column: $table.lastErrorCode,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get predecessorId => $composableBuilder(
    column: $table.predecessorId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get appliedRevision => $composableBuilder(
    column: $table.appliedRevision,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get baseDataJson => $composableBuilder(
    column: $table.baseDataJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  $$LocalSpacesTableOrderingComposer get spaceId {
    final $$LocalSpacesTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.spaceId,
      referencedTable: $db.localSpaces,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalSpacesTableOrderingComposer(
            $db: $db,
            $table: $db.localSpaces,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$PendingOperationsTableAnnotationComposer
    extends Composer<_$AppDatabase, $PendingOperationsTable> {
  $$PendingOperationsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get sequence =>
      $composableBuilder(column: $table.sequence, builder: (column) => column);

  GeneratedColumn<String> get operationId => $composableBuilder(
    column: $table.operationId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get entityType => $composableBuilder(
    column: $table.entityType,
    builder: (column) => column,
  );

  GeneratedColumn<String> get entityId =>
      $composableBuilder(column: $table.entityId, builder: (column) => column);

  GeneratedColumn<String> get operationJson => $composableBuilder(
    column: $table.operationJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get frozenRequestJson => $composableBuilder(
    column: $table.frozenRequestJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get state =>
      $composableBuilder(column: $table.state, builder: (column) => column);

  GeneratedColumn<int> get attemptCount => $composableBuilder(
    column: $table.attemptCount,
    builder: (column) => column,
  );

  GeneratedColumn<String> get lastErrorCode => $composableBuilder(
    column: $table.lastErrorCode,
    builder: (column) => column,
  );

  GeneratedColumn<String> get predecessorId => $composableBuilder(
    column: $table.predecessorId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get appliedRevision => $composableBuilder(
    column: $table.appliedRevision,
    builder: (column) => column,
  );

  GeneratedColumn<String> get baseDataJson => $composableBuilder(
    column: $table.baseDataJson,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  $$LocalSpacesTableAnnotationComposer get spaceId {
    final $$LocalSpacesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.spaceId,
      referencedTable: $db.localSpaces,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalSpacesTableAnnotationComposer(
            $db: $db,
            $table: $db.localSpaces,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$PendingOperationsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $PendingOperationsTable,
          StoredOperation,
          $$PendingOperationsTableFilterComposer,
          $$PendingOperationsTableOrderingComposer,
          $$PendingOperationsTableAnnotationComposer,
          $$PendingOperationsTableCreateCompanionBuilder,
          $$PendingOperationsTableUpdateCompanionBuilder,
          (StoredOperation, $$PendingOperationsTableReferences),
          StoredOperation,
          PrefetchHooks Function({bool spaceId})
        > {
  $$PendingOperationsTableTableManager(
    _$AppDatabase db,
    $PendingOperationsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$PendingOperationsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$PendingOperationsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$PendingOperationsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<int> sequence = const Value.absent(),
                Value<String> spaceId = const Value.absent(),
                Value<String> operationId = const Value.absent(),
                Value<String> entityType = const Value.absent(),
                Value<String> entityId = const Value.absent(),
                Value<String> operationJson = const Value.absent(),
                Value<String?> frozenRequestJson = const Value.absent(),
                Value<String> state = const Value.absent(),
                Value<int> attemptCount = const Value.absent(),
                Value<String?> lastErrorCode = const Value.absent(),
                Value<String?> predecessorId = const Value.absent(),
                Value<String?> appliedRevision = const Value.absent(),
                Value<String?> baseDataJson = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
              }) => PendingOperationsCompanion(
                sequence: sequence,
                spaceId: spaceId,
                operationId: operationId,
                entityType: entityType,
                entityId: entityId,
                operationJson: operationJson,
                frozenRequestJson: frozenRequestJson,
                state: state,
                attemptCount: attemptCount,
                lastErrorCode: lastErrorCode,
                predecessorId: predecessorId,
                appliedRevision: appliedRevision,
                baseDataJson: baseDataJson,
                createdAt: createdAt,
              ),
          createCompanionCallback:
              ({
                Value<int> sequence = const Value.absent(),
                required String spaceId,
                required String operationId,
                required String entityType,
                required String entityId,
                required String operationJson,
                Value<String?> frozenRequestJson = const Value.absent(),
                Value<String> state = const Value.absent(),
                Value<int> attemptCount = const Value.absent(),
                Value<String?> lastErrorCode = const Value.absent(),
                Value<String?> predecessorId = const Value.absent(),
                Value<String?> appliedRevision = const Value.absent(),
                Value<String?> baseDataJson = const Value.absent(),
                required DateTime createdAt,
              }) => PendingOperationsCompanion.insert(
                sequence: sequence,
                spaceId: spaceId,
                operationId: operationId,
                entityType: entityType,
                entityId: entityId,
                operationJson: operationJson,
                frozenRequestJson: frozenRequestJson,
                state: state,
                attemptCount: attemptCount,
                lastErrorCode: lastErrorCode,
                predecessorId: predecessorId,
                appliedRevision: appliedRevision,
                baseDataJson: baseDataJson,
                createdAt: createdAt,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$PendingOperationsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({spaceId = false}) {
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
                    if (spaceId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.spaceId,
                                referencedTable:
                                    $$PendingOperationsTableReferences
                                        ._spaceIdTable(db),
                                referencedColumn:
                                    $$PendingOperationsTableReferences
                                        ._spaceIdTable(db)
                                        .id,
                              )
                              as T;
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

typedef $$PendingOperationsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $PendingOperationsTable,
      StoredOperation,
      $$PendingOperationsTableFilterComposer,
      $$PendingOperationsTableOrderingComposer,
      $$PendingOperationsTableAnnotationComposer,
      $$PendingOperationsTableCreateCompanionBuilder,
      $$PendingOperationsTableUpdateCompanionBuilder,
      (StoredOperation, $$PendingOperationsTableReferences),
      StoredOperation,
      PrefetchHooks Function({bool spaceId})
    >;
typedef $$ServerShadowsTableCreateCompanionBuilder =
    ServerShadowsCompanion Function({
      required String spaceId,
      required String scopeId,
      required String entityType,
      required String entityId,
      required String revision,
      required String dataJson,
      required bool deleted,
      Value<int> rowid,
    });
typedef $$ServerShadowsTableUpdateCompanionBuilder =
    ServerShadowsCompanion Function({
      Value<String> spaceId,
      Value<String> scopeId,
      Value<String> entityType,
      Value<String> entityId,
      Value<String> revision,
      Value<String> dataJson,
      Value<bool> deleted,
      Value<int> rowid,
    });

final class $$ServerShadowsTableReferences
    extends
        BaseReferences<_$AppDatabase, $ServerShadowsTable, ConfirmedEntity> {
  $$ServerShadowsTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $LocalSpacesTable _spaceIdTable(_$AppDatabase db) =>
      db.localSpaces.createAlias('server_shadows__space_id__local_spaces__id');

  $$LocalSpacesTableProcessedTableManager get spaceId {
    final $_column = $_itemColumn<String>('space_id')!;

    final manager = $$LocalSpacesTableTableManager(
      $_db,
      $_db.localSpaces,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_spaceIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$ServerShadowsTableFilterComposer
    extends Composer<_$AppDatabase, $ServerShadowsTable> {
  $$ServerShadowsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get scopeId => $composableBuilder(
    column: $table.scopeId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get entityType => $composableBuilder(
    column: $table.entityType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get entityId => $composableBuilder(
    column: $table.entityId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get revision => $composableBuilder(
    column: $table.revision,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get dataJson => $composableBuilder(
    column: $table.dataJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get deleted => $composableBuilder(
    column: $table.deleted,
    builder: (column) => ColumnFilters(column),
  );

  $$LocalSpacesTableFilterComposer get spaceId {
    final $$LocalSpacesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.spaceId,
      referencedTable: $db.localSpaces,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalSpacesTableFilterComposer(
            $db: $db,
            $table: $db.localSpaces,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ServerShadowsTableOrderingComposer
    extends Composer<_$AppDatabase, $ServerShadowsTable> {
  $$ServerShadowsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get scopeId => $composableBuilder(
    column: $table.scopeId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get entityType => $composableBuilder(
    column: $table.entityType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get entityId => $composableBuilder(
    column: $table.entityId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get revision => $composableBuilder(
    column: $table.revision,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get dataJson => $composableBuilder(
    column: $table.dataJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get deleted => $composableBuilder(
    column: $table.deleted,
    builder: (column) => ColumnOrderings(column),
  );

  $$LocalSpacesTableOrderingComposer get spaceId {
    final $$LocalSpacesTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.spaceId,
      referencedTable: $db.localSpaces,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalSpacesTableOrderingComposer(
            $db: $db,
            $table: $db.localSpaces,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ServerShadowsTableAnnotationComposer
    extends Composer<_$AppDatabase, $ServerShadowsTable> {
  $$ServerShadowsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get scopeId =>
      $composableBuilder(column: $table.scopeId, builder: (column) => column);

  GeneratedColumn<String> get entityType => $composableBuilder(
    column: $table.entityType,
    builder: (column) => column,
  );

  GeneratedColumn<String> get entityId =>
      $composableBuilder(column: $table.entityId, builder: (column) => column);

  GeneratedColumn<String> get revision =>
      $composableBuilder(column: $table.revision, builder: (column) => column);

  GeneratedColumn<String> get dataJson =>
      $composableBuilder(column: $table.dataJson, builder: (column) => column);

  GeneratedColumn<bool> get deleted =>
      $composableBuilder(column: $table.deleted, builder: (column) => column);

  $$LocalSpacesTableAnnotationComposer get spaceId {
    final $$LocalSpacesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.spaceId,
      referencedTable: $db.localSpaces,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalSpacesTableAnnotationComposer(
            $db: $db,
            $table: $db.localSpaces,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ServerShadowsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ServerShadowsTable,
          ConfirmedEntity,
          $$ServerShadowsTableFilterComposer,
          $$ServerShadowsTableOrderingComposer,
          $$ServerShadowsTableAnnotationComposer,
          $$ServerShadowsTableCreateCompanionBuilder,
          $$ServerShadowsTableUpdateCompanionBuilder,
          (ConfirmedEntity, $$ServerShadowsTableReferences),
          ConfirmedEntity,
          PrefetchHooks Function({bool spaceId})
        > {
  $$ServerShadowsTableTableManager(_$AppDatabase db, $ServerShadowsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ServerShadowsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ServerShadowsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ServerShadowsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> spaceId = const Value.absent(),
                Value<String> scopeId = const Value.absent(),
                Value<String> entityType = const Value.absent(),
                Value<String> entityId = const Value.absent(),
                Value<String> revision = const Value.absent(),
                Value<String> dataJson = const Value.absent(),
                Value<bool> deleted = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ServerShadowsCompanion(
                spaceId: spaceId,
                scopeId: scopeId,
                entityType: entityType,
                entityId: entityId,
                revision: revision,
                dataJson: dataJson,
                deleted: deleted,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String spaceId,
                required String scopeId,
                required String entityType,
                required String entityId,
                required String revision,
                required String dataJson,
                required bool deleted,
                Value<int> rowid = const Value.absent(),
              }) => ServerShadowsCompanion.insert(
                spaceId: spaceId,
                scopeId: scopeId,
                entityType: entityType,
                entityId: entityId,
                revision: revision,
                dataJson: dataJson,
                deleted: deleted,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$ServerShadowsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({spaceId = false}) {
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
                    if (spaceId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.spaceId,
                                referencedTable: $$ServerShadowsTableReferences
                                    ._spaceIdTable(db),
                                referencedColumn: $$ServerShadowsTableReferences
                                    ._spaceIdTable(db)
                                    .id,
                              )
                              as T;
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

typedef $$ServerShadowsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ServerShadowsTable,
      ConfirmedEntity,
      $$ServerShadowsTableFilterComposer,
      $$ServerShadowsTableOrderingComposer,
      $$ServerShadowsTableAnnotationComposer,
      $$ServerShadowsTableCreateCompanionBuilder,
      $$ServerShadowsTableUpdateCompanionBuilder,
      (ConfirmedEntity, $$ServerShadowsTableReferences),
      ConfirmedEntity,
      PrefetchHooks Function({bool spaceId})
    >;
typedef $$SyncStatesTableCreateCompanionBuilder =
    SyncStatesCompanion Function({
      required String spaceId,
      required String clientId,
      required String epoch,
      Value<String> cursorsJson,
      Value<String> status,
      Value<String> revokedScopesJson,
      Value<int> rowid,
    });
typedef $$SyncStatesTableUpdateCompanionBuilder =
    SyncStatesCompanion Function({
      Value<String> spaceId,
      Value<String> clientId,
      Value<String> epoch,
      Value<String> cursorsJson,
      Value<String> status,
      Value<String> revokedScopesJson,
      Value<int> rowid,
    });

final class $$SyncStatesTableReferences
    extends BaseReferences<_$AppDatabase, $SyncStatesTable, SpaceSyncState> {
  $$SyncStatesTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $LocalSpacesTable _spaceIdTable(_$AppDatabase db) =>
      db.localSpaces.createAlias('sync_states__space_id__local_spaces__id');

  $$LocalSpacesTableProcessedTableManager get spaceId {
    final $_column = $_itemColumn<String>('space_id')!;

    final manager = $$LocalSpacesTableTableManager(
      $_db,
      $_db.localSpaces,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_spaceIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$SyncStatesTableFilterComposer
    extends Composer<_$AppDatabase, $SyncStatesTable> {
  $$SyncStatesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get clientId => $composableBuilder(
    column: $table.clientId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get epoch => $composableBuilder(
    column: $table.epoch,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get cursorsJson => $composableBuilder(
    column: $table.cursorsJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get revokedScopesJson => $composableBuilder(
    column: $table.revokedScopesJson,
    builder: (column) => ColumnFilters(column),
  );

  $$LocalSpacesTableFilterComposer get spaceId {
    final $$LocalSpacesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.spaceId,
      referencedTable: $db.localSpaces,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalSpacesTableFilterComposer(
            $db: $db,
            $table: $db.localSpaces,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$SyncStatesTableOrderingComposer
    extends Composer<_$AppDatabase, $SyncStatesTable> {
  $$SyncStatesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get clientId => $composableBuilder(
    column: $table.clientId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get epoch => $composableBuilder(
    column: $table.epoch,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get cursorsJson => $composableBuilder(
    column: $table.cursorsJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get revokedScopesJson => $composableBuilder(
    column: $table.revokedScopesJson,
    builder: (column) => ColumnOrderings(column),
  );

  $$LocalSpacesTableOrderingComposer get spaceId {
    final $$LocalSpacesTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.spaceId,
      referencedTable: $db.localSpaces,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalSpacesTableOrderingComposer(
            $db: $db,
            $table: $db.localSpaces,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$SyncStatesTableAnnotationComposer
    extends Composer<_$AppDatabase, $SyncStatesTable> {
  $$SyncStatesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get clientId =>
      $composableBuilder(column: $table.clientId, builder: (column) => column);

  GeneratedColumn<String> get epoch =>
      $composableBuilder(column: $table.epoch, builder: (column) => column);

  GeneratedColumn<String> get cursorsJson => $composableBuilder(
    column: $table.cursorsJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<String> get revokedScopesJson => $composableBuilder(
    column: $table.revokedScopesJson,
    builder: (column) => column,
  );

  $$LocalSpacesTableAnnotationComposer get spaceId {
    final $$LocalSpacesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.spaceId,
      referencedTable: $db.localSpaces,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalSpacesTableAnnotationComposer(
            $db: $db,
            $table: $db.localSpaces,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$SyncStatesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $SyncStatesTable,
          SpaceSyncState,
          $$SyncStatesTableFilterComposer,
          $$SyncStatesTableOrderingComposer,
          $$SyncStatesTableAnnotationComposer,
          $$SyncStatesTableCreateCompanionBuilder,
          $$SyncStatesTableUpdateCompanionBuilder,
          (SpaceSyncState, $$SyncStatesTableReferences),
          SpaceSyncState,
          PrefetchHooks Function({bool spaceId})
        > {
  $$SyncStatesTableTableManager(_$AppDatabase db, $SyncStatesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SyncStatesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SyncStatesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SyncStatesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> spaceId = const Value.absent(),
                Value<String> clientId = const Value.absent(),
                Value<String> epoch = const Value.absent(),
                Value<String> cursorsJson = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<String> revokedScopesJson = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SyncStatesCompanion(
                spaceId: spaceId,
                clientId: clientId,
                epoch: epoch,
                cursorsJson: cursorsJson,
                status: status,
                revokedScopesJson: revokedScopesJson,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String spaceId,
                required String clientId,
                required String epoch,
                Value<String> cursorsJson = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<String> revokedScopesJson = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SyncStatesCompanion.insert(
                spaceId: spaceId,
                clientId: clientId,
                epoch: epoch,
                cursorsJson: cursorsJson,
                status: status,
                revokedScopesJson: revokedScopesJson,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$SyncStatesTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({spaceId = false}) {
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
                    if (spaceId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.spaceId,
                                referencedTable: $$SyncStatesTableReferences
                                    ._spaceIdTable(db),
                                referencedColumn: $$SyncStatesTableReferences
                                    ._spaceIdTable(db)
                                    .id,
                              )
                              as T;
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

typedef $$SyncStatesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $SyncStatesTable,
      SpaceSyncState,
      $$SyncStatesTableFilterComposer,
      $$SyncStatesTableOrderingComposer,
      $$SyncStatesTableAnnotationComposer,
      $$SyncStatesTableCreateCompanionBuilder,
      $$SyncStatesTableUpdateCompanionBuilder,
      (SpaceSyncState, $$SyncStatesTableReferences),
      SpaceSyncState,
      PrefetchHooks Function({bool spaceId})
    >;
typedef $$SyncConflictsTableCreateCompanionBuilder =
    SyncConflictsCompanion Function({
      required String spaceId,
      required String operationId,
      required String scopeId,
      required String code,
      Value<String?> baseJson,
      required String localJson,
      Value<String?> serverJson,
      required DateTime createdAt,
      Value<int> rowid,
    });
typedef $$SyncConflictsTableUpdateCompanionBuilder =
    SyncConflictsCompanion Function({
      Value<String> spaceId,
      Value<String> operationId,
      Value<String> scopeId,
      Value<String> code,
      Value<String?> baseJson,
      Value<String> localJson,
      Value<String?> serverJson,
      Value<DateTime> createdAt,
      Value<int> rowid,
    });

final class $$SyncConflictsTableReferences
    extends BaseReferences<_$AppDatabase, $SyncConflictsTable, StoredConflict> {
  $$SyncConflictsTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $LocalSpacesTable _spaceIdTable(_$AppDatabase db) =>
      db.localSpaces.createAlias('sync_conflicts__space_id__local_spaces__id');

  $$LocalSpacesTableProcessedTableManager get spaceId {
    final $_column = $_itemColumn<String>('space_id')!;

    final manager = $$LocalSpacesTableTableManager(
      $_db,
      $_db.localSpaces,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_spaceIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$SyncConflictsTableFilterComposer
    extends Composer<_$AppDatabase, $SyncConflictsTable> {
  $$SyncConflictsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get operationId => $composableBuilder(
    column: $table.operationId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get scopeId => $composableBuilder(
    column: $table.scopeId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get code => $composableBuilder(
    column: $table.code,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get baseJson => $composableBuilder(
    column: $table.baseJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get localJson => $composableBuilder(
    column: $table.localJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get serverJson => $composableBuilder(
    column: $table.serverJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  $$LocalSpacesTableFilterComposer get spaceId {
    final $$LocalSpacesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.spaceId,
      referencedTable: $db.localSpaces,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalSpacesTableFilterComposer(
            $db: $db,
            $table: $db.localSpaces,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$SyncConflictsTableOrderingComposer
    extends Composer<_$AppDatabase, $SyncConflictsTable> {
  $$SyncConflictsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get operationId => $composableBuilder(
    column: $table.operationId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get scopeId => $composableBuilder(
    column: $table.scopeId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get code => $composableBuilder(
    column: $table.code,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get baseJson => $composableBuilder(
    column: $table.baseJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get localJson => $composableBuilder(
    column: $table.localJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get serverJson => $composableBuilder(
    column: $table.serverJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  $$LocalSpacesTableOrderingComposer get spaceId {
    final $$LocalSpacesTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.spaceId,
      referencedTable: $db.localSpaces,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalSpacesTableOrderingComposer(
            $db: $db,
            $table: $db.localSpaces,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$SyncConflictsTableAnnotationComposer
    extends Composer<_$AppDatabase, $SyncConflictsTable> {
  $$SyncConflictsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get operationId => $composableBuilder(
    column: $table.operationId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get scopeId =>
      $composableBuilder(column: $table.scopeId, builder: (column) => column);

  GeneratedColumn<String> get code =>
      $composableBuilder(column: $table.code, builder: (column) => column);

  GeneratedColumn<String> get baseJson =>
      $composableBuilder(column: $table.baseJson, builder: (column) => column);

  GeneratedColumn<String> get localJson =>
      $composableBuilder(column: $table.localJson, builder: (column) => column);

  GeneratedColumn<String> get serverJson => $composableBuilder(
    column: $table.serverJson,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  $$LocalSpacesTableAnnotationComposer get spaceId {
    final $$LocalSpacesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.spaceId,
      referencedTable: $db.localSpaces,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalSpacesTableAnnotationComposer(
            $db: $db,
            $table: $db.localSpaces,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$SyncConflictsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $SyncConflictsTable,
          StoredConflict,
          $$SyncConflictsTableFilterComposer,
          $$SyncConflictsTableOrderingComposer,
          $$SyncConflictsTableAnnotationComposer,
          $$SyncConflictsTableCreateCompanionBuilder,
          $$SyncConflictsTableUpdateCompanionBuilder,
          (StoredConflict, $$SyncConflictsTableReferences),
          StoredConflict,
          PrefetchHooks Function({bool spaceId})
        > {
  $$SyncConflictsTableTableManager(_$AppDatabase db, $SyncConflictsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SyncConflictsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SyncConflictsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SyncConflictsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> spaceId = const Value.absent(),
                Value<String> operationId = const Value.absent(),
                Value<String> scopeId = const Value.absent(),
                Value<String> code = const Value.absent(),
                Value<String?> baseJson = const Value.absent(),
                Value<String> localJson = const Value.absent(),
                Value<String?> serverJson = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SyncConflictsCompanion(
                spaceId: spaceId,
                operationId: operationId,
                scopeId: scopeId,
                code: code,
                baseJson: baseJson,
                localJson: localJson,
                serverJson: serverJson,
                createdAt: createdAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String spaceId,
                required String operationId,
                required String scopeId,
                required String code,
                Value<String?> baseJson = const Value.absent(),
                required String localJson,
                Value<String?> serverJson = const Value.absent(),
                required DateTime createdAt,
                Value<int> rowid = const Value.absent(),
              }) => SyncConflictsCompanion.insert(
                spaceId: spaceId,
                operationId: operationId,
                scopeId: scopeId,
                code: code,
                baseJson: baseJson,
                localJson: localJson,
                serverJson: serverJson,
                createdAt: createdAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$SyncConflictsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({spaceId = false}) {
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
                    if (spaceId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.spaceId,
                                referencedTable: $$SyncConflictsTableReferences
                                    ._spaceIdTable(db),
                                referencedColumn: $$SyncConflictsTableReferences
                                    ._spaceIdTable(db)
                                    .id,
                              )
                              as T;
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

typedef $$SyncConflictsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $SyncConflictsTable,
      StoredConflict,
      $$SyncConflictsTableFilterComposer,
      $$SyncConflictsTableOrderingComposer,
      $$SyncConflictsTableAnnotationComposer,
      $$SyncConflictsTableCreateCompanionBuilder,
      $$SyncConflictsTableUpdateCompanionBuilder,
      (StoredConflict, $$SyncConflictsTableReferences),
      StoredConflict,
      PrefetchHooks Function({bool spaceId})
    >;
typedef $$SyncRecoveryBackupsTableCreateCompanionBuilder =
    SyncRecoveryBackupsCompanion Function({
      required String id,
      required String spaceId,
      required String reason,
      required String oldEpoch,
      required String dataJson,
      required DateTime createdAt,
      Value<int> rowid,
    });
typedef $$SyncRecoveryBackupsTableUpdateCompanionBuilder =
    SyncRecoveryBackupsCompanion Function({
      Value<String> id,
      Value<String> spaceId,
      Value<String> reason,
      Value<String> oldEpoch,
      Value<String> dataJson,
      Value<DateTime> createdAt,
      Value<int> rowid,
    });

final class $$SyncRecoveryBackupsTableReferences
    extends
        BaseReferences<
          _$AppDatabase,
          $SyncRecoveryBackupsTable,
          RecoveryBackup
        > {
  $$SyncRecoveryBackupsTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $LocalSpacesTable _spaceIdTable(_$AppDatabase db) => db.localSpaces
      .createAlias('sync_recovery_backups__space_id__local_spaces__id');

  $$LocalSpacesTableProcessedTableManager get spaceId {
    final $_column = $_itemColumn<String>('space_id')!;

    final manager = $$LocalSpacesTableTableManager(
      $_db,
      $_db.localSpaces,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_spaceIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static MultiTypedResultKey<
    $StageImportRecoveryChunksTable,
    List<StoredStageImportRecoveryChunk>
  >
  _stageImportRecoveryChunksRefsTable(
    _$AppDatabase db,
  ) => MultiTypedResultKey.fromTable(
    db.stageImportRecoveryChunks,
    aliasName:
        'sync_recovery_backups__id__stage_import_recovery_chunks__backup_id',
  );

  $$StageImportRecoveryChunksTableProcessedTableManager
  get stageImportRecoveryChunksRefs {
    final manager = $$StageImportRecoveryChunksTableTableManager(
      $_db,
      $_db.stageImportRecoveryChunks,
    ).filter((f) => f.backupId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(
      _stageImportRecoveryChunksRefsTable($_db),
    );
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$SyncRecoveryBackupsTableFilterComposer
    extends Composer<_$AppDatabase, $SyncRecoveryBackupsTable> {
  $$SyncRecoveryBackupsTableFilterComposer({
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

  ColumnFilters<String> get reason => $composableBuilder(
    column: $table.reason,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get oldEpoch => $composableBuilder(
    column: $table.oldEpoch,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get dataJson => $composableBuilder(
    column: $table.dataJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  $$LocalSpacesTableFilterComposer get spaceId {
    final $$LocalSpacesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.spaceId,
      referencedTable: $db.localSpaces,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalSpacesTableFilterComposer(
            $db: $db,
            $table: $db.localSpaces,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  Expression<bool> stageImportRecoveryChunksRefs(
    Expression<bool> Function($$StageImportRecoveryChunksTableFilterComposer f)
    f,
  ) {
    final $$StageImportRecoveryChunksTableFilterComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.id,
          referencedTable: $db.stageImportRecoveryChunks,
          getReferencedColumn: (t) => t.backupId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$StageImportRecoveryChunksTableFilterComposer(
                $db: $db,
                $table: $db.stageImportRecoveryChunks,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return f(composer);
  }
}

class $$SyncRecoveryBackupsTableOrderingComposer
    extends Composer<_$AppDatabase, $SyncRecoveryBackupsTable> {
  $$SyncRecoveryBackupsTableOrderingComposer({
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

  ColumnOrderings<String> get reason => $composableBuilder(
    column: $table.reason,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get oldEpoch => $composableBuilder(
    column: $table.oldEpoch,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get dataJson => $composableBuilder(
    column: $table.dataJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  $$LocalSpacesTableOrderingComposer get spaceId {
    final $$LocalSpacesTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.spaceId,
      referencedTable: $db.localSpaces,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalSpacesTableOrderingComposer(
            $db: $db,
            $table: $db.localSpaces,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$SyncRecoveryBackupsTableAnnotationComposer
    extends Composer<_$AppDatabase, $SyncRecoveryBackupsTable> {
  $$SyncRecoveryBackupsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get reason =>
      $composableBuilder(column: $table.reason, builder: (column) => column);

  GeneratedColumn<String> get oldEpoch =>
      $composableBuilder(column: $table.oldEpoch, builder: (column) => column);

  GeneratedColumn<String> get dataJson =>
      $composableBuilder(column: $table.dataJson, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  $$LocalSpacesTableAnnotationComposer get spaceId {
    final $$LocalSpacesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.spaceId,
      referencedTable: $db.localSpaces,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalSpacesTableAnnotationComposer(
            $db: $db,
            $table: $db.localSpaces,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  Expression<T> stageImportRecoveryChunksRefs<T extends Object>(
    Expression<T> Function($$StageImportRecoveryChunksTableAnnotationComposer a)
    f,
  ) {
    final $$StageImportRecoveryChunksTableAnnotationComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.id,
          referencedTable: $db.stageImportRecoveryChunks,
          getReferencedColumn: (t) => t.backupId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$StageImportRecoveryChunksTableAnnotationComposer(
                $db: $db,
                $table: $db.stageImportRecoveryChunks,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return f(composer);
  }
}

class $$SyncRecoveryBackupsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $SyncRecoveryBackupsTable,
          RecoveryBackup,
          $$SyncRecoveryBackupsTableFilterComposer,
          $$SyncRecoveryBackupsTableOrderingComposer,
          $$SyncRecoveryBackupsTableAnnotationComposer,
          $$SyncRecoveryBackupsTableCreateCompanionBuilder,
          $$SyncRecoveryBackupsTableUpdateCompanionBuilder,
          (RecoveryBackup, $$SyncRecoveryBackupsTableReferences),
          RecoveryBackup,
          PrefetchHooks Function({
            bool spaceId,
            bool stageImportRecoveryChunksRefs,
          })
        > {
  $$SyncRecoveryBackupsTableTableManager(
    _$AppDatabase db,
    $SyncRecoveryBackupsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SyncRecoveryBackupsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SyncRecoveryBackupsTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$SyncRecoveryBackupsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> spaceId = const Value.absent(),
                Value<String> reason = const Value.absent(),
                Value<String> oldEpoch = const Value.absent(),
                Value<String> dataJson = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SyncRecoveryBackupsCompanion(
                id: id,
                spaceId: spaceId,
                reason: reason,
                oldEpoch: oldEpoch,
                dataJson: dataJson,
                createdAt: createdAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String spaceId,
                required String reason,
                required String oldEpoch,
                required String dataJson,
                required DateTime createdAt,
                Value<int> rowid = const Value.absent(),
              }) => SyncRecoveryBackupsCompanion.insert(
                id: id,
                spaceId: spaceId,
                reason: reason,
                oldEpoch: oldEpoch,
                dataJson: dataJson,
                createdAt: createdAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$SyncRecoveryBackupsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback:
              ({spaceId = false, stageImportRecoveryChunksRefs = false}) {
                return PrefetchHooks(
                  db: db,
                  explicitlyWatchedTables: [
                    if (stageImportRecoveryChunksRefs)
                      db.stageImportRecoveryChunks,
                  ],
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
                        if (spaceId) {
                          state =
                              state.withJoin(
                                    currentTable: table,
                                    currentColumn: table.spaceId,
                                    referencedTable:
                                        $$SyncRecoveryBackupsTableReferences
                                            ._spaceIdTable(db),
                                    referencedColumn:
                                        $$SyncRecoveryBackupsTableReferences
                                            ._spaceIdTable(db)
                                            .id,
                                  )
                                  as T;
                        }

                        return state;
                      },
                  getPrefetchedDataCallback: (items) async {
                    return [
                      if (stageImportRecoveryChunksRefs)
                        await $_getPrefetchedData<
                          RecoveryBackup,
                          $SyncRecoveryBackupsTable,
                          StoredStageImportRecoveryChunk
                        >(
                          currentTable: table,
                          referencedTable: $$SyncRecoveryBackupsTableReferences
                              ._stageImportRecoveryChunksRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$SyncRecoveryBackupsTableReferences(
                                db,
                                table,
                                p0,
                              ).stageImportRecoveryChunksRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.backupId == item.id,
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

typedef $$SyncRecoveryBackupsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $SyncRecoveryBackupsTable,
      RecoveryBackup,
      $$SyncRecoveryBackupsTableFilterComposer,
      $$SyncRecoveryBackupsTableOrderingComposer,
      $$SyncRecoveryBackupsTableAnnotationComposer,
      $$SyncRecoveryBackupsTableCreateCompanionBuilder,
      $$SyncRecoveryBackupsTableUpdateCompanionBuilder,
      (RecoveryBackup, $$SyncRecoveryBackupsTableReferences),
      RecoveryBackup,
      PrefetchHooks Function({bool spaceId, bool stageImportRecoveryChunksRefs})
    >;
typedef $$SnapshotPagesTableCreateCompanionBuilder =
    SnapshotPagesCompanion Function({
      required String spaceId,
      required String snapshotId,
      required int pageIndex,
      required String itemsJson,
      required String sha256,
      Value<int> rowid,
    });
typedef $$SnapshotPagesTableUpdateCompanionBuilder =
    SnapshotPagesCompanion Function({
      Value<String> spaceId,
      Value<String> snapshotId,
      Value<int> pageIndex,
      Value<String> itemsJson,
      Value<String> sha256,
      Value<int> rowid,
    });

final class $$SnapshotPagesTableReferences
    extends
        BaseReferences<_$AppDatabase, $SnapshotPagesTable, StagedSnapshotPage> {
  $$SnapshotPagesTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $LocalSpacesTable _spaceIdTable(_$AppDatabase db) =>
      db.localSpaces.createAlias('snapshot_pages__space_id__local_spaces__id');

  $$LocalSpacesTableProcessedTableManager get spaceId {
    final $_column = $_itemColumn<String>('space_id')!;

    final manager = $$LocalSpacesTableTableManager(
      $_db,
      $_db.localSpaces,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_spaceIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$SnapshotPagesTableFilterComposer
    extends Composer<_$AppDatabase, $SnapshotPagesTable> {
  $$SnapshotPagesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get snapshotId => $composableBuilder(
    column: $table.snapshotId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get pageIndex => $composableBuilder(
    column: $table.pageIndex,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get itemsJson => $composableBuilder(
    column: $table.itemsJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sha256 => $composableBuilder(
    column: $table.sha256,
    builder: (column) => ColumnFilters(column),
  );

  $$LocalSpacesTableFilterComposer get spaceId {
    final $$LocalSpacesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.spaceId,
      referencedTable: $db.localSpaces,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalSpacesTableFilterComposer(
            $db: $db,
            $table: $db.localSpaces,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$SnapshotPagesTableOrderingComposer
    extends Composer<_$AppDatabase, $SnapshotPagesTable> {
  $$SnapshotPagesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get snapshotId => $composableBuilder(
    column: $table.snapshotId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get pageIndex => $composableBuilder(
    column: $table.pageIndex,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get itemsJson => $composableBuilder(
    column: $table.itemsJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sha256 => $composableBuilder(
    column: $table.sha256,
    builder: (column) => ColumnOrderings(column),
  );

  $$LocalSpacesTableOrderingComposer get spaceId {
    final $$LocalSpacesTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.spaceId,
      referencedTable: $db.localSpaces,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalSpacesTableOrderingComposer(
            $db: $db,
            $table: $db.localSpaces,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$SnapshotPagesTableAnnotationComposer
    extends Composer<_$AppDatabase, $SnapshotPagesTable> {
  $$SnapshotPagesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get snapshotId => $composableBuilder(
    column: $table.snapshotId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get pageIndex =>
      $composableBuilder(column: $table.pageIndex, builder: (column) => column);

  GeneratedColumn<String> get itemsJson =>
      $composableBuilder(column: $table.itemsJson, builder: (column) => column);

  GeneratedColumn<String> get sha256 =>
      $composableBuilder(column: $table.sha256, builder: (column) => column);

  $$LocalSpacesTableAnnotationComposer get spaceId {
    final $$LocalSpacesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.spaceId,
      referencedTable: $db.localSpaces,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalSpacesTableAnnotationComposer(
            $db: $db,
            $table: $db.localSpaces,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$SnapshotPagesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $SnapshotPagesTable,
          StagedSnapshotPage,
          $$SnapshotPagesTableFilterComposer,
          $$SnapshotPagesTableOrderingComposer,
          $$SnapshotPagesTableAnnotationComposer,
          $$SnapshotPagesTableCreateCompanionBuilder,
          $$SnapshotPagesTableUpdateCompanionBuilder,
          (StagedSnapshotPage, $$SnapshotPagesTableReferences),
          StagedSnapshotPage,
          PrefetchHooks Function({bool spaceId})
        > {
  $$SnapshotPagesTableTableManager(_$AppDatabase db, $SnapshotPagesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SnapshotPagesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SnapshotPagesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SnapshotPagesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> spaceId = const Value.absent(),
                Value<String> snapshotId = const Value.absent(),
                Value<int> pageIndex = const Value.absent(),
                Value<String> itemsJson = const Value.absent(),
                Value<String> sha256 = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SnapshotPagesCompanion(
                spaceId: spaceId,
                snapshotId: snapshotId,
                pageIndex: pageIndex,
                itemsJson: itemsJson,
                sha256: sha256,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String spaceId,
                required String snapshotId,
                required int pageIndex,
                required String itemsJson,
                required String sha256,
                Value<int> rowid = const Value.absent(),
              }) => SnapshotPagesCompanion.insert(
                spaceId: spaceId,
                snapshotId: snapshotId,
                pageIndex: pageIndex,
                itemsJson: itemsJson,
                sha256: sha256,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$SnapshotPagesTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({spaceId = false}) {
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
                    if (spaceId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.spaceId,
                                referencedTable: $$SnapshotPagesTableReferences
                                    ._spaceIdTable(db),
                                referencedColumn: $$SnapshotPagesTableReferences
                                    ._spaceIdTable(db)
                                    .id,
                              )
                              as T;
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

typedef $$SnapshotPagesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $SnapshotPagesTable,
      StagedSnapshotPage,
      $$SnapshotPagesTableFilterComposer,
      $$SnapshotPagesTableOrderingComposer,
      $$SnapshotPagesTableAnnotationComposer,
      $$SnapshotPagesTableCreateCompanionBuilder,
      $$SnapshotPagesTableUpdateCompanionBuilder,
      (StagedSnapshotPage, $$SnapshotPagesTableReferences),
      StagedSnapshotPage,
      PrefetchHooks Function({bool spaceId})
    >;
typedef $$GroupPullsTableCreateCompanionBuilder =
    GroupPullsCompanion Function({
      required String spaceId,
      required String requestId,
      required String clientId,
      required String epoch,
      required String intentJson,
      Value<String?> statusJson,
      Value<String?> pullId,
      Value<String?> nextToken,
      required String receiveStateJson,
      Value<int> receivedPages,
      Value<int> reservedBytes,
      Value<int> installedUnits,
      required DateTime createdAt,
      Value<int> rowid,
    });
typedef $$GroupPullsTableUpdateCompanionBuilder =
    GroupPullsCompanion Function({
      Value<String> spaceId,
      Value<String> requestId,
      Value<String> clientId,
      Value<String> epoch,
      Value<String> intentJson,
      Value<String?> statusJson,
      Value<String?> pullId,
      Value<String?> nextToken,
      Value<String> receiveStateJson,
      Value<int> receivedPages,
      Value<int> reservedBytes,
      Value<int> installedUnits,
      Value<DateTime> createdAt,
      Value<int> rowid,
    });

final class $$GroupPullsTableReferences
    extends BaseReferences<_$AppDatabase, $GroupPullsTable, StoredGroupPull> {
  $$GroupPullsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $LocalSpacesTable _spaceIdTable(_$AppDatabase db) =>
      db.localSpaces.createAlias('group_pulls__space_id__local_spaces__id');

  $$LocalSpacesTableProcessedTableManager get spaceId {
    final $_column = $_itemColumn<String>('space_id')!;

    final manager = $$LocalSpacesTableTableManager(
      $_db,
      $_db.localSpaces,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_spaceIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$GroupPullsTableFilterComposer
    extends Composer<_$AppDatabase, $GroupPullsTable> {
  $$GroupPullsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get requestId => $composableBuilder(
    column: $table.requestId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get clientId => $composableBuilder(
    column: $table.clientId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get epoch => $composableBuilder(
    column: $table.epoch,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get intentJson => $composableBuilder(
    column: $table.intentJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get statusJson => $composableBuilder(
    column: $table.statusJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get pullId => $composableBuilder(
    column: $table.pullId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get nextToken => $composableBuilder(
    column: $table.nextToken,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get receiveStateJson => $composableBuilder(
    column: $table.receiveStateJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get receivedPages => $composableBuilder(
    column: $table.receivedPages,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get reservedBytes => $composableBuilder(
    column: $table.reservedBytes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get installedUnits => $composableBuilder(
    column: $table.installedUnits,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  $$LocalSpacesTableFilterComposer get spaceId {
    final $$LocalSpacesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.spaceId,
      referencedTable: $db.localSpaces,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalSpacesTableFilterComposer(
            $db: $db,
            $table: $db.localSpaces,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$GroupPullsTableOrderingComposer
    extends Composer<_$AppDatabase, $GroupPullsTable> {
  $$GroupPullsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get requestId => $composableBuilder(
    column: $table.requestId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get clientId => $composableBuilder(
    column: $table.clientId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get epoch => $composableBuilder(
    column: $table.epoch,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get intentJson => $composableBuilder(
    column: $table.intentJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get statusJson => $composableBuilder(
    column: $table.statusJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get pullId => $composableBuilder(
    column: $table.pullId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get nextToken => $composableBuilder(
    column: $table.nextToken,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get receiveStateJson => $composableBuilder(
    column: $table.receiveStateJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get receivedPages => $composableBuilder(
    column: $table.receivedPages,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get reservedBytes => $composableBuilder(
    column: $table.reservedBytes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get installedUnits => $composableBuilder(
    column: $table.installedUnits,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  $$LocalSpacesTableOrderingComposer get spaceId {
    final $$LocalSpacesTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.spaceId,
      referencedTable: $db.localSpaces,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalSpacesTableOrderingComposer(
            $db: $db,
            $table: $db.localSpaces,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$GroupPullsTableAnnotationComposer
    extends Composer<_$AppDatabase, $GroupPullsTable> {
  $$GroupPullsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get requestId =>
      $composableBuilder(column: $table.requestId, builder: (column) => column);

  GeneratedColumn<String> get clientId =>
      $composableBuilder(column: $table.clientId, builder: (column) => column);

  GeneratedColumn<String> get epoch =>
      $composableBuilder(column: $table.epoch, builder: (column) => column);

  GeneratedColumn<String> get intentJson => $composableBuilder(
    column: $table.intentJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get statusJson => $composableBuilder(
    column: $table.statusJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get pullId =>
      $composableBuilder(column: $table.pullId, builder: (column) => column);

  GeneratedColumn<String> get nextToken =>
      $composableBuilder(column: $table.nextToken, builder: (column) => column);

  GeneratedColumn<String> get receiveStateJson => $composableBuilder(
    column: $table.receiveStateJson,
    builder: (column) => column,
  );

  GeneratedColumn<int> get receivedPages => $composableBuilder(
    column: $table.receivedPages,
    builder: (column) => column,
  );

  GeneratedColumn<int> get reservedBytes => $composableBuilder(
    column: $table.reservedBytes,
    builder: (column) => column,
  );

  GeneratedColumn<int> get installedUnits => $composableBuilder(
    column: $table.installedUnits,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  $$LocalSpacesTableAnnotationComposer get spaceId {
    final $$LocalSpacesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.spaceId,
      referencedTable: $db.localSpaces,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalSpacesTableAnnotationComposer(
            $db: $db,
            $table: $db.localSpaces,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$GroupPullsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $GroupPullsTable,
          StoredGroupPull,
          $$GroupPullsTableFilterComposer,
          $$GroupPullsTableOrderingComposer,
          $$GroupPullsTableAnnotationComposer,
          $$GroupPullsTableCreateCompanionBuilder,
          $$GroupPullsTableUpdateCompanionBuilder,
          (StoredGroupPull, $$GroupPullsTableReferences),
          StoredGroupPull,
          PrefetchHooks Function({bool spaceId})
        > {
  $$GroupPullsTableTableManager(_$AppDatabase db, $GroupPullsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$GroupPullsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$GroupPullsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$GroupPullsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> spaceId = const Value.absent(),
                Value<String> requestId = const Value.absent(),
                Value<String> clientId = const Value.absent(),
                Value<String> epoch = const Value.absent(),
                Value<String> intentJson = const Value.absent(),
                Value<String?> statusJson = const Value.absent(),
                Value<String?> pullId = const Value.absent(),
                Value<String?> nextToken = const Value.absent(),
                Value<String> receiveStateJson = const Value.absent(),
                Value<int> receivedPages = const Value.absent(),
                Value<int> reservedBytes = const Value.absent(),
                Value<int> installedUnits = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => GroupPullsCompanion(
                spaceId: spaceId,
                requestId: requestId,
                clientId: clientId,
                epoch: epoch,
                intentJson: intentJson,
                statusJson: statusJson,
                pullId: pullId,
                nextToken: nextToken,
                receiveStateJson: receiveStateJson,
                receivedPages: receivedPages,
                reservedBytes: reservedBytes,
                installedUnits: installedUnits,
                createdAt: createdAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String spaceId,
                required String requestId,
                required String clientId,
                required String epoch,
                required String intentJson,
                Value<String?> statusJson = const Value.absent(),
                Value<String?> pullId = const Value.absent(),
                Value<String?> nextToken = const Value.absent(),
                required String receiveStateJson,
                Value<int> receivedPages = const Value.absent(),
                Value<int> reservedBytes = const Value.absent(),
                Value<int> installedUnits = const Value.absent(),
                required DateTime createdAt,
                Value<int> rowid = const Value.absent(),
              }) => GroupPullsCompanion.insert(
                spaceId: spaceId,
                requestId: requestId,
                clientId: clientId,
                epoch: epoch,
                intentJson: intentJson,
                statusJson: statusJson,
                pullId: pullId,
                nextToken: nextToken,
                receiveStateJson: receiveStateJson,
                receivedPages: receivedPages,
                reservedBytes: reservedBytes,
                installedUnits: installedUnits,
                createdAt: createdAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$GroupPullsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({spaceId = false}) {
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
                    if (spaceId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.spaceId,
                                referencedTable: $$GroupPullsTableReferences
                                    ._spaceIdTable(db),
                                referencedColumn: $$GroupPullsTableReferences
                                    ._spaceIdTable(db)
                                    .id,
                              )
                              as T;
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

typedef $$GroupPullsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $GroupPullsTable,
      StoredGroupPull,
      $$GroupPullsTableFilterComposer,
      $$GroupPullsTableOrderingComposer,
      $$GroupPullsTableAnnotationComposer,
      $$GroupPullsTableCreateCompanionBuilder,
      $$GroupPullsTableUpdateCompanionBuilder,
      (StoredGroupPull, $$GroupPullsTableReferences),
      StoredGroupPull,
      PrefetchHooks Function({bool spaceId})
    >;
typedef $$GroupPagesTableCreateCompanionBuilder =
    GroupPagesCompanion Function({
      required String spaceId,
      required String requestId,
      required int ordinal,
      required String requestToken,
      required String kind,
      required String groupId,
      required int pageIndex,
      required String bodyJson,
      required String sha256,
      required int sizeBytes,
      Value<int> rowid,
    });
typedef $$GroupPagesTableUpdateCompanionBuilder =
    GroupPagesCompanion Function({
      Value<String> spaceId,
      Value<String> requestId,
      Value<int> ordinal,
      Value<String> requestToken,
      Value<String> kind,
      Value<String> groupId,
      Value<int> pageIndex,
      Value<String> bodyJson,
      Value<String> sha256,
      Value<int> sizeBytes,
      Value<int> rowid,
    });

final class $$GroupPagesTableReferences
    extends BaseReferences<_$AppDatabase, $GroupPagesTable, StoredGroupPage> {
  $$GroupPagesTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $LocalSpacesTable _spaceIdTable(_$AppDatabase db) =>
      db.localSpaces.createAlias('group_pages__space_id__local_spaces__id');

  $$LocalSpacesTableProcessedTableManager get spaceId {
    final $_column = $_itemColumn<String>('space_id')!;

    final manager = $$LocalSpacesTableTableManager(
      $_db,
      $_db.localSpaces,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_spaceIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$GroupPagesTableFilterComposer
    extends Composer<_$AppDatabase, $GroupPagesTable> {
  $$GroupPagesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get requestId => $composableBuilder(
    column: $table.requestId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get ordinal => $composableBuilder(
    column: $table.ordinal,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get requestToken => $composableBuilder(
    column: $table.requestToken,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get groupId => $composableBuilder(
    column: $table.groupId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get pageIndex => $composableBuilder(
    column: $table.pageIndex,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get bodyJson => $composableBuilder(
    column: $table.bodyJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sha256 => $composableBuilder(
    column: $table.sha256,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sizeBytes => $composableBuilder(
    column: $table.sizeBytes,
    builder: (column) => ColumnFilters(column),
  );

  $$LocalSpacesTableFilterComposer get spaceId {
    final $$LocalSpacesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.spaceId,
      referencedTable: $db.localSpaces,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalSpacesTableFilterComposer(
            $db: $db,
            $table: $db.localSpaces,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$GroupPagesTableOrderingComposer
    extends Composer<_$AppDatabase, $GroupPagesTable> {
  $$GroupPagesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get requestId => $composableBuilder(
    column: $table.requestId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get ordinal => $composableBuilder(
    column: $table.ordinal,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get requestToken => $composableBuilder(
    column: $table.requestToken,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get groupId => $composableBuilder(
    column: $table.groupId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get pageIndex => $composableBuilder(
    column: $table.pageIndex,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get bodyJson => $composableBuilder(
    column: $table.bodyJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sha256 => $composableBuilder(
    column: $table.sha256,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sizeBytes => $composableBuilder(
    column: $table.sizeBytes,
    builder: (column) => ColumnOrderings(column),
  );

  $$LocalSpacesTableOrderingComposer get spaceId {
    final $$LocalSpacesTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.spaceId,
      referencedTable: $db.localSpaces,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalSpacesTableOrderingComposer(
            $db: $db,
            $table: $db.localSpaces,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$GroupPagesTableAnnotationComposer
    extends Composer<_$AppDatabase, $GroupPagesTable> {
  $$GroupPagesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get requestId =>
      $composableBuilder(column: $table.requestId, builder: (column) => column);

  GeneratedColumn<int> get ordinal =>
      $composableBuilder(column: $table.ordinal, builder: (column) => column);

  GeneratedColumn<String> get requestToken => $composableBuilder(
    column: $table.requestToken,
    builder: (column) => column,
  );

  GeneratedColumn<String> get kind =>
      $composableBuilder(column: $table.kind, builder: (column) => column);

  GeneratedColumn<String> get groupId =>
      $composableBuilder(column: $table.groupId, builder: (column) => column);

  GeneratedColumn<int> get pageIndex =>
      $composableBuilder(column: $table.pageIndex, builder: (column) => column);

  GeneratedColumn<String> get bodyJson =>
      $composableBuilder(column: $table.bodyJson, builder: (column) => column);

  GeneratedColumn<String> get sha256 =>
      $composableBuilder(column: $table.sha256, builder: (column) => column);

  GeneratedColumn<int> get sizeBytes =>
      $composableBuilder(column: $table.sizeBytes, builder: (column) => column);

  $$LocalSpacesTableAnnotationComposer get spaceId {
    final $$LocalSpacesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.spaceId,
      referencedTable: $db.localSpaces,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalSpacesTableAnnotationComposer(
            $db: $db,
            $table: $db.localSpaces,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$GroupPagesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $GroupPagesTable,
          StoredGroupPage,
          $$GroupPagesTableFilterComposer,
          $$GroupPagesTableOrderingComposer,
          $$GroupPagesTableAnnotationComposer,
          $$GroupPagesTableCreateCompanionBuilder,
          $$GroupPagesTableUpdateCompanionBuilder,
          (StoredGroupPage, $$GroupPagesTableReferences),
          StoredGroupPage,
          PrefetchHooks Function({bool spaceId})
        > {
  $$GroupPagesTableTableManager(_$AppDatabase db, $GroupPagesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$GroupPagesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$GroupPagesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$GroupPagesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> spaceId = const Value.absent(),
                Value<String> requestId = const Value.absent(),
                Value<int> ordinal = const Value.absent(),
                Value<String> requestToken = const Value.absent(),
                Value<String> kind = const Value.absent(),
                Value<String> groupId = const Value.absent(),
                Value<int> pageIndex = const Value.absent(),
                Value<String> bodyJson = const Value.absent(),
                Value<String> sha256 = const Value.absent(),
                Value<int> sizeBytes = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => GroupPagesCompanion(
                spaceId: spaceId,
                requestId: requestId,
                ordinal: ordinal,
                requestToken: requestToken,
                kind: kind,
                groupId: groupId,
                pageIndex: pageIndex,
                bodyJson: bodyJson,
                sha256: sha256,
                sizeBytes: sizeBytes,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String spaceId,
                required String requestId,
                required int ordinal,
                required String requestToken,
                required String kind,
                required String groupId,
                required int pageIndex,
                required String bodyJson,
                required String sha256,
                required int sizeBytes,
                Value<int> rowid = const Value.absent(),
              }) => GroupPagesCompanion.insert(
                spaceId: spaceId,
                requestId: requestId,
                ordinal: ordinal,
                requestToken: requestToken,
                kind: kind,
                groupId: groupId,
                pageIndex: pageIndex,
                bodyJson: bodyJson,
                sha256: sha256,
                sizeBytes: sizeBytes,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$GroupPagesTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({spaceId = false}) {
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
                    if (spaceId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.spaceId,
                                referencedTable: $$GroupPagesTableReferences
                                    ._spaceIdTable(db),
                                referencedColumn: $$GroupPagesTableReferences
                                    ._spaceIdTable(db)
                                    .id,
                              )
                              as T;
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

typedef $$GroupPagesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $GroupPagesTable,
      StoredGroupPage,
      $$GroupPagesTableFilterComposer,
      $$GroupPagesTableOrderingComposer,
      $$GroupPagesTableAnnotationComposer,
      $$GroupPagesTableCreateCompanionBuilder,
      $$GroupPagesTableUpdateCompanionBuilder,
      (StoredGroupPage, $$GroupPagesTableReferences),
      StoredGroupPage,
      PrefetchHooks Function({bool spaceId})
    >;
typedef $$GroupReceiptsTableCreateCompanionBuilder =
    GroupReceiptsCompanion Function({
      required String spaceId,
      required String requestId,
      required int unitIndex,
      required String groupId,
      required String manifestSha256,
      required String endCursorsJson,
      required int sizeBytes,
      Value<int> rowid,
    });
typedef $$GroupReceiptsTableUpdateCompanionBuilder =
    GroupReceiptsCompanion Function({
      Value<String> spaceId,
      Value<String> requestId,
      Value<int> unitIndex,
      Value<String> groupId,
      Value<String> manifestSha256,
      Value<String> endCursorsJson,
      Value<int> sizeBytes,
      Value<int> rowid,
    });

final class $$GroupReceiptsTableReferences
    extends
        BaseReferences<_$AppDatabase, $GroupReceiptsTable, StoredGroupReceipt> {
  $$GroupReceiptsTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $LocalSpacesTable _spaceIdTable(_$AppDatabase db) =>
      db.localSpaces.createAlias('group_receipts__space_id__local_spaces__id');

  $$LocalSpacesTableProcessedTableManager get spaceId {
    final $_column = $_itemColumn<String>('space_id')!;

    final manager = $$LocalSpacesTableTableManager(
      $_db,
      $_db.localSpaces,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_spaceIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$GroupReceiptsTableFilterComposer
    extends Composer<_$AppDatabase, $GroupReceiptsTable> {
  $$GroupReceiptsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get requestId => $composableBuilder(
    column: $table.requestId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get unitIndex => $composableBuilder(
    column: $table.unitIndex,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get groupId => $composableBuilder(
    column: $table.groupId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get manifestSha256 => $composableBuilder(
    column: $table.manifestSha256,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get endCursorsJson => $composableBuilder(
    column: $table.endCursorsJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sizeBytes => $composableBuilder(
    column: $table.sizeBytes,
    builder: (column) => ColumnFilters(column),
  );

  $$LocalSpacesTableFilterComposer get spaceId {
    final $$LocalSpacesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.spaceId,
      referencedTable: $db.localSpaces,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalSpacesTableFilterComposer(
            $db: $db,
            $table: $db.localSpaces,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$GroupReceiptsTableOrderingComposer
    extends Composer<_$AppDatabase, $GroupReceiptsTable> {
  $$GroupReceiptsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get requestId => $composableBuilder(
    column: $table.requestId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get unitIndex => $composableBuilder(
    column: $table.unitIndex,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get groupId => $composableBuilder(
    column: $table.groupId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get manifestSha256 => $composableBuilder(
    column: $table.manifestSha256,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get endCursorsJson => $composableBuilder(
    column: $table.endCursorsJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sizeBytes => $composableBuilder(
    column: $table.sizeBytes,
    builder: (column) => ColumnOrderings(column),
  );

  $$LocalSpacesTableOrderingComposer get spaceId {
    final $$LocalSpacesTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.spaceId,
      referencedTable: $db.localSpaces,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalSpacesTableOrderingComposer(
            $db: $db,
            $table: $db.localSpaces,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$GroupReceiptsTableAnnotationComposer
    extends Composer<_$AppDatabase, $GroupReceiptsTable> {
  $$GroupReceiptsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get requestId =>
      $composableBuilder(column: $table.requestId, builder: (column) => column);

  GeneratedColumn<int> get unitIndex =>
      $composableBuilder(column: $table.unitIndex, builder: (column) => column);

  GeneratedColumn<String> get groupId =>
      $composableBuilder(column: $table.groupId, builder: (column) => column);

  GeneratedColumn<String> get manifestSha256 => $composableBuilder(
    column: $table.manifestSha256,
    builder: (column) => column,
  );

  GeneratedColumn<String> get endCursorsJson => $composableBuilder(
    column: $table.endCursorsJson,
    builder: (column) => column,
  );

  GeneratedColumn<int> get sizeBytes =>
      $composableBuilder(column: $table.sizeBytes, builder: (column) => column);

  $$LocalSpacesTableAnnotationComposer get spaceId {
    final $$LocalSpacesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.spaceId,
      referencedTable: $db.localSpaces,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalSpacesTableAnnotationComposer(
            $db: $db,
            $table: $db.localSpaces,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$GroupReceiptsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $GroupReceiptsTable,
          StoredGroupReceipt,
          $$GroupReceiptsTableFilterComposer,
          $$GroupReceiptsTableOrderingComposer,
          $$GroupReceiptsTableAnnotationComposer,
          $$GroupReceiptsTableCreateCompanionBuilder,
          $$GroupReceiptsTableUpdateCompanionBuilder,
          (StoredGroupReceipt, $$GroupReceiptsTableReferences),
          StoredGroupReceipt,
          PrefetchHooks Function({bool spaceId})
        > {
  $$GroupReceiptsTableTableManager(_$AppDatabase db, $GroupReceiptsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$GroupReceiptsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$GroupReceiptsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$GroupReceiptsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> spaceId = const Value.absent(),
                Value<String> requestId = const Value.absent(),
                Value<int> unitIndex = const Value.absent(),
                Value<String> groupId = const Value.absent(),
                Value<String> manifestSha256 = const Value.absent(),
                Value<String> endCursorsJson = const Value.absent(),
                Value<int> sizeBytes = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => GroupReceiptsCompanion(
                spaceId: spaceId,
                requestId: requestId,
                unitIndex: unitIndex,
                groupId: groupId,
                manifestSha256: manifestSha256,
                endCursorsJson: endCursorsJson,
                sizeBytes: sizeBytes,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String spaceId,
                required String requestId,
                required int unitIndex,
                required String groupId,
                required String manifestSha256,
                required String endCursorsJson,
                required int sizeBytes,
                Value<int> rowid = const Value.absent(),
              }) => GroupReceiptsCompanion.insert(
                spaceId: spaceId,
                requestId: requestId,
                unitIndex: unitIndex,
                groupId: groupId,
                manifestSha256: manifestSha256,
                endCursorsJson: endCursorsJson,
                sizeBytes: sizeBytes,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$GroupReceiptsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({spaceId = false}) {
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
                    if (spaceId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.spaceId,
                                referencedTable: $$GroupReceiptsTableReferences
                                    ._spaceIdTable(db),
                                referencedColumn: $$GroupReceiptsTableReferences
                                    ._spaceIdTable(db)
                                    .id,
                              )
                              as T;
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

typedef $$GroupReceiptsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $GroupReceiptsTable,
      StoredGroupReceipt,
      $$GroupReceiptsTableFilterComposer,
      $$GroupReceiptsTableOrderingComposer,
      $$GroupReceiptsTableAnnotationComposer,
      $$GroupReceiptsTableCreateCompanionBuilder,
      $$GroupReceiptsTableUpdateCompanionBuilder,
      (StoredGroupReceipt, $$GroupReceiptsTableReferences),
      StoredGroupReceipt,
      PrefetchHooks Function({bool spaceId})
    >;
typedef $$StageImportSourcesTableCreateCompanionBuilder =
    StageImportSourcesCompanion Function({
      required String spaceId,
      required String stageId,
      required String clientId,
      required String epoch,
      required String originSessionId,
      required String format,
      required String fileName,
      required String sourceSha256,
      required String createBodyJson,
      required String stateJson,
      required int expectedBytes,
      required int reservedBytes,
      required DateTime createdAt,
      Value<int> rowid,
    });
typedef $$StageImportSourcesTableUpdateCompanionBuilder =
    StageImportSourcesCompanion Function({
      Value<String> spaceId,
      Value<String> stageId,
      Value<String> clientId,
      Value<String> epoch,
      Value<String> originSessionId,
      Value<String> format,
      Value<String> fileName,
      Value<String> sourceSha256,
      Value<String> createBodyJson,
      Value<String> stateJson,
      Value<int> expectedBytes,
      Value<int> reservedBytes,
      Value<DateTime> createdAt,
      Value<int> rowid,
    });

final class $$StageImportSourcesTableReferences
    extends
        BaseReferences<
          _$AppDatabase,
          $StageImportSourcesTable,
          StoredStageImportSource
        > {
  $$StageImportSourcesTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $LocalSpacesTable _spaceIdTable(_$AppDatabase db) => db.localSpaces
      .createAlias('stage_import_sources__space_id__local_spaces__id');

  $$LocalSpacesTableProcessedTableManager get spaceId {
    final $_column = $_itemColumn<String>('space_id')!;

    final manager = $$LocalSpacesTableTableManager(
      $_db,
      $_db.localSpaces,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_spaceIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$StageImportSourcesTableFilterComposer
    extends Composer<_$AppDatabase, $StageImportSourcesTable> {
  $$StageImportSourcesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get stageId => $composableBuilder(
    column: $table.stageId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get clientId => $composableBuilder(
    column: $table.clientId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get epoch => $composableBuilder(
    column: $table.epoch,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get originSessionId => $composableBuilder(
    column: $table.originSessionId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get format => $composableBuilder(
    column: $table.format,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get fileName => $composableBuilder(
    column: $table.fileName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sourceSha256 => $composableBuilder(
    column: $table.sourceSha256,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get createBodyJson => $composableBuilder(
    column: $table.createBodyJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get stateJson => $composableBuilder(
    column: $table.stateJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get expectedBytes => $composableBuilder(
    column: $table.expectedBytes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get reservedBytes => $composableBuilder(
    column: $table.reservedBytes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  $$LocalSpacesTableFilterComposer get spaceId {
    final $$LocalSpacesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.spaceId,
      referencedTable: $db.localSpaces,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalSpacesTableFilterComposer(
            $db: $db,
            $table: $db.localSpaces,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$StageImportSourcesTableOrderingComposer
    extends Composer<_$AppDatabase, $StageImportSourcesTable> {
  $$StageImportSourcesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get stageId => $composableBuilder(
    column: $table.stageId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get clientId => $composableBuilder(
    column: $table.clientId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get epoch => $composableBuilder(
    column: $table.epoch,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get originSessionId => $composableBuilder(
    column: $table.originSessionId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get format => $composableBuilder(
    column: $table.format,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get fileName => $composableBuilder(
    column: $table.fileName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sourceSha256 => $composableBuilder(
    column: $table.sourceSha256,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get createBodyJson => $composableBuilder(
    column: $table.createBodyJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get stateJson => $composableBuilder(
    column: $table.stateJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get expectedBytes => $composableBuilder(
    column: $table.expectedBytes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get reservedBytes => $composableBuilder(
    column: $table.reservedBytes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  $$LocalSpacesTableOrderingComposer get spaceId {
    final $$LocalSpacesTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.spaceId,
      referencedTable: $db.localSpaces,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalSpacesTableOrderingComposer(
            $db: $db,
            $table: $db.localSpaces,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$StageImportSourcesTableAnnotationComposer
    extends Composer<_$AppDatabase, $StageImportSourcesTable> {
  $$StageImportSourcesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get stageId =>
      $composableBuilder(column: $table.stageId, builder: (column) => column);

  GeneratedColumn<String> get clientId =>
      $composableBuilder(column: $table.clientId, builder: (column) => column);

  GeneratedColumn<String> get epoch =>
      $composableBuilder(column: $table.epoch, builder: (column) => column);

  GeneratedColumn<String> get originSessionId => $composableBuilder(
    column: $table.originSessionId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get format =>
      $composableBuilder(column: $table.format, builder: (column) => column);

  GeneratedColumn<String> get fileName =>
      $composableBuilder(column: $table.fileName, builder: (column) => column);

  GeneratedColumn<String> get sourceSha256 => $composableBuilder(
    column: $table.sourceSha256,
    builder: (column) => column,
  );

  GeneratedColumn<String> get createBodyJson => $composableBuilder(
    column: $table.createBodyJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get stateJson =>
      $composableBuilder(column: $table.stateJson, builder: (column) => column);

  GeneratedColumn<int> get expectedBytes => $composableBuilder(
    column: $table.expectedBytes,
    builder: (column) => column,
  );

  GeneratedColumn<int> get reservedBytes => $composableBuilder(
    column: $table.reservedBytes,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  $$LocalSpacesTableAnnotationComposer get spaceId {
    final $$LocalSpacesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.spaceId,
      referencedTable: $db.localSpaces,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LocalSpacesTableAnnotationComposer(
            $db: $db,
            $table: $db.localSpaces,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$StageImportSourcesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $StageImportSourcesTable,
          StoredStageImportSource,
          $$StageImportSourcesTableFilterComposer,
          $$StageImportSourcesTableOrderingComposer,
          $$StageImportSourcesTableAnnotationComposer,
          $$StageImportSourcesTableCreateCompanionBuilder,
          $$StageImportSourcesTableUpdateCompanionBuilder,
          (StoredStageImportSource, $$StageImportSourcesTableReferences),
          StoredStageImportSource,
          PrefetchHooks Function({bool spaceId})
        > {
  $$StageImportSourcesTableTableManager(
    _$AppDatabase db,
    $StageImportSourcesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$StageImportSourcesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$StageImportSourcesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$StageImportSourcesTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> spaceId = const Value.absent(),
                Value<String> stageId = const Value.absent(),
                Value<String> clientId = const Value.absent(),
                Value<String> epoch = const Value.absent(),
                Value<String> originSessionId = const Value.absent(),
                Value<String> format = const Value.absent(),
                Value<String> fileName = const Value.absent(),
                Value<String> sourceSha256 = const Value.absent(),
                Value<String> createBodyJson = const Value.absent(),
                Value<String> stateJson = const Value.absent(),
                Value<int> expectedBytes = const Value.absent(),
                Value<int> reservedBytes = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => StageImportSourcesCompanion(
                spaceId: spaceId,
                stageId: stageId,
                clientId: clientId,
                epoch: epoch,
                originSessionId: originSessionId,
                format: format,
                fileName: fileName,
                sourceSha256: sourceSha256,
                createBodyJson: createBodyJson,
                stateJson: stateJson,
                expectedBytes: expectedBytes,
                reservedBytes: reservedBytes,
                createdAt: createdAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String spaceId,
                required String stageId,
                required String clientId,
                required String epoch,
                required String originSessionId,
                required String format,
                required String fileName,
                required String sourceSha256,
                required String createBodyJson,
                required String stateJson,
                required int expectedBytes,
                required int reservedBytes,
                required DateTime createdAt,
                Value<int> rowid = const Value.absent(),
              }) => StageImportSourcesCompanion.insert(
                spaceId: spaceId,
                stageId: stageId,
                clientId: clientId,
                epoch: epoch,
                originSessionId: originSessionId,
                format: format,
                fileName: fileName,
                sourceSha256: sourceSha256,
                createBodyJson: createBodyJson,
                stateJson: stateJson,
                expectedBytes: expectedBytes,
                reservedBytes: reservedBytes,
                createdAt: createdAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$StageImportSourcesTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({spaceId = false}) {
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
                    if (spaceId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.spaceId,
                                referencedTable:
                                    $$StageImportSourcesTableReferences
                                        ._spaceIdTable(db),
                                referencedColumn:
                                    $$StageImportSourcesTableReferences
                                        ._spaceIdTable(db)
                                        .id,
                              )
                              as T;
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

typedef $$StageImportSourcesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $StageImportSourcesTable,
      StoredStageImportSource,
      $$StageImportSourcesTableFilterComposer,
      $$StageImportSourcesTableOrderingComposer,
      $$StageImportSourcesTableAnnotationComposer,
      $$StageImportSourcesTableCreateCompanionBuilder,
      $$StageImportSourcesTableUpdateCompanionBuilder,
      (StoredStageImportSource, $$StageImportSourcesTableReferences),
      StoredStageImportSource,
      PrefetchHooks Function({bool spaceId})
    >;
typedef $$StageImportChunksTableCreateCompanionBuilder =
    StageImportChunksCompanion Function({
      required String spaceId,
      required String stageId,
      required int chunkIndex,
      required Uint8List body,
      required String sha256,
      required int sizeBytes,
      Value<String?> receiptJson,
      Value<int> rowid,
    });
typedef $$StageImportChunksTableUpdateCompanionBuilder =
    StageImportChunksCompanion Function({
      Value<String> spaceId,
      Value<String> stageId,
      Value<int> chunkIndex,
      Value<Uint8List> body,
      Value<String> sha256,
      Value<int> sizeBytes,
      Value<String?> receiptJson,
      Value<int> rowid,
    });

class $$StageImportChunksTableFilterComposer
    extends Composer<_$AppDatabase, $StageImportChunksTable> {
  $$StageImportChunksTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get spaceId => $composableBuilder(
    column: $table.spaceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get stageId => $composableBuilder(
    column: $table.stageId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get chunkIndex => $composableBuilder(
    column: $table.chunkIndex,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get body => $composableBuilder(
    column: $table.body,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sha256 => $composableBuilder(
    column: $table.sha256,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sizeBytes => $composableBuilder(
    column: $table.sizeBytes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get receiptJson => $composableBuilder(
    column: $table.receiptJson,
    builder: (column) => ColumnFilters(column),
  );
}

class $$StageImportChunksTableOrderingComposer
    extends Composer<_$AppDatabase, $StageImportChunksTable> {
  $$StageImportChunksTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get spaceId => $composableBuilder(
    column: $table.spaceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get stageId => $composableBuilder(
    column: $table.stageId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get chunkIndex => $composableBuilder(
    column: $table.chunkIndex,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get body => $composableBuilder(
    column: $table.body,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sha256 => $composableBuilder(
    column: $table.sha256,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sizeBytes => $composableBuilder(
    column: $table.sizeBytes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get receiptJson => $composableBuilder(
    column: $table.receiptJson,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$StageImportChunksTableAnnotationComposer
    extends Composer<_$AppDatabase, $StageImportChunksTable> {
  $$StageImportChunksTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get spaceId =>
      $composableBuilder(column: $table.spaceId, builder: (column) => column);

  GeneratedColumn<String> get stageId =>
      $composableBuilder(column: $table.stageId, builder: (column) => column);

  GeneratedColumn<int> get chunkIndex => $composableBuilder(
    column: $table.chunkIndex,
    builder: (column) => column,
  );

  GeneratedColumn<Uint8List> get body =>
      $composableBuilder(column: $table.body, builder: (column) => column);

  GeneratedColumn<String> get sha256 =>
      $composableBuilder(column: $table.sha256, builder: (column) => column);

  GeneratedColumn<int> get sizeBytes =>
      $composableBuilder(column: $table.sizeBytes, builder: (column) => column);

  GeneratedColumn<String> get receiptJson => $composableBuilder(
    column: $table.receiptJson,
    builder: (column) => column,
  );
}

class $$StageImportChunksTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $StageImportChunksTable,
          StoredStageImportChunk,
          $$StageImportChunksTableFilterComposer,
          $$StageImportChunksTableOrderingComposer,
          $$StageImportChunksTableAnnotationComposer,
          $$StageImportChunksTableCreateCompanionBuilder,
          $$StageImportChunksTableUpdateCompanionBuilder,
          (
            StoredStageImportChunk,
            BaseReferences<
              _$AppDatabase,
              $StageImportChunksTable,
              StoredStageImportChunk
            >,
          ),
          StoredStageImportChunk,
          PrefetchHooks Function()
        > {
  $$StageImportChunksTableTableManager(
    _$AppDatabase db,
    $StageImportChunksTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$StageImportChunksTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$StageImportChunksTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$StageImportChunksTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> spaceId = const Value.absent(),
                Value<String> stageId = const Value.absent(),
                Value<int> chunkIndex = const Value.absent(),
                Value<Uint8List> body = const Value.absent(),
                Value<String> sha256 = const Value.absent(),
                Value<int> sizeBytes = const Value.absent(),
                Value<String?> receiptJson = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => StageImportChunksCompanion(
                spaceId: spaceId,
                stageId: stageId,
                chunkIndex: chunkIndex,
                body: body,
                sha256: sha256,
                sizeBytes: sizeBytes,
                receiptJson: receiptJson,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String spaceId,
                required String stageId,
                required int chunkIndex,
                required Uint8List body,
                required String sha256,
                required int sizeBytes,
                Value<String?> receiptJson = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => StageImportChunksCompanion.insert(
                spaceId: spaceId,
                stageId: stageId,
                chunkIndex: chunkIndex,
                body: body,
                sha256: sha256,
                sizeBytes: sizeBytes,
                receiptJson: receiptJson,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$StageImportChunksTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $StageImportChunksTable,
      StoredStageImportChunk,
      $$StageImportChunksTableFilterComposer,
      $$StageImportChunksTableOrderingComposer,
      $$StageImportChunksTableAnnotationComposer,
      $$StageImportChunksTableCreateCompanionBuilder,
      $$StageImportChunksTableUpdateCompanionBuilder,
      (
        StoredStageImportChunk,
        BaseReferences<
          _$AppDatabase,
          $StageImportChunksTable,
          StoredStageImportChunk
        >,
      ),
      StoredStageImportChunk,
      PrefetchHooks Function()
    >;
typedef $$StageImportCommandsTableCreateCompanionBuilder =
    StageImportCommandsCompanion Function({
      required String spaceId,
      required String stageId,
      required String commandId,
      required String kind,
      required int stageVersion,
      required String bodyJson,
      Value<String?> responseJson,
      required String phase,
      required DateTime createdAt,
      Value<int> rowid,
    });
typedef $$StageImportCommandsTableUpdateCompanionBuilder =
    StageImportCommandsCompanion Function({
      Value<String> spaceId,
      Value<String> stageId,
      Value<String> commandId,
      Value<String> kind,
      Value<int> stageVersion,
      Value<String> bodyJson,
      Value<String?> responseJson,
      Value<String> phase,
      Value<DateTime> createdAt,
      Value<int> rowid,
    });

class $$StageImportCommandsTableFilterComposer
    extends Composer<_$AppDatabase, $StageImportCommandsTable> {
  $$StageImportCommandsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get spaceId => $composableBuilder(
    column: $table.spaceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get stageId => $composableBuilder(
    column: $table.stageId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get commandId => $composableBuilder(
    column: $table.commandId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get stageVersion => $composableBuilder(
    column: $table.stageVersion,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get bodyJson => $composableBuilder(
    column: $table.bodyJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get responseJson => $composableBuilder(
    column: $table.responseJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get phase => $composableBuilder(
    column: $table.phase,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$StageImportCommandsTableOrderingComposer
    extends Composer<_$AppDatabase, $StageImportCommandsTable> {
  $$StageImportCommandsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get spaceId => $composableBuilder(
    column: $table.spaceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get stageId => $composableBuilder(
    column: $table.stageId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get commandId => $composableBuilder(
    column: $table.commandId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get stageVersion => $composableBuilder(
    column: $table.stageVersion,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get bodyJson => $composableBuilder(
    column: $table.bodyJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get responseJson => $composableBuilder(
    column: $table.responseJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get phase => $composableBuilder(
    column: $table.phase,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$StageImportCommandsTableAnnotationComposer
    extends Composer<_$AppDatabase, $StageImportCommandsTable> {
  $$StageImportCommandsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get spaceId =>
      $composableBuilder(column: $table.spaceId, builder: (column) => column);

  GeneratedColumn<String> get stageId =>
      $composableBuilder(column: $table.stageId, builder: (column) => column);

  GeneratedColumn<String> get commandId =>
      $composableBuilder(column: $table.commandId, builder: (column) => column);

  GeneratedColumn<String> get kind =>
      $composableBuilder(column: $table.kind, builder: (column) => column);

  GeneratedColumn<int> get stageVersion => $composableBuilder(
    column: $table.stageVersion,
    builder: (column) => column,
  );

  GeneratedColumn<String> get bodyJson =>
      $composableBuilder(column: $table.bodyJson, builder: (column) => column);

  GeneratedColumn<String> get responseJson => $composableBuilder(
    column: $table.responseJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get phase =>
      $composableBuilder(column: $table.phase, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);
}

class $$StageImportCommandsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $StageImportCommandsTable,
          StoredStageImportCommand,
          $$StageImportCommandsTableFilterComposer,
          $$StageImportCommandsTableOrderingComposer,
          $$StageImportCommandsTableAnnotationComposer,
          $$StageImportCommandsTableCreateCompanionBuilder,
          $$StageImportCommandsTableUpdateCompanionBuilder,
          (
            StoredStageImportCommand,
            BaseReferences<
              _$AppDatabase,
              $StageImportCommandsTable,
              StoredStageImportCommand
            >,
          ),
          StoredStageImportCommand,
          PrefetchHooks Function()
        > {
  $$StageImportCommandsTableTableManager(
    _$AppDatabase db,
    $StageImportCommandsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$StageImportCommandsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$StageImportCommandsTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$StageImportCommandsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> spaceId = const Value.absent(),
                Value<String> stageId = const Value.absent(),
                Value<String> commandId = const Value.absent(),
                Value<String> kind = const Value.absent(),
                Value<int> stageVersion = const Value.absent(),
                Value<String> bodyJson = const Value.absent(),
                Value<String?> responseJson = const Value.absent(),
                Value<String> phase = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => StageImportCommandsCompanion(
                spaceId: spaceId,
                stageId: stageId,
                commandId: commandId,
                kind: kind,
                stageVersion: stageVersion,
                bodyJson: bodyJson,
                responseJson: responseJson,
                phase: phase,
                createdAt: createdAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String spaceId,
                required String stageId,
                required String commandId,
                required String kind,
                required int stageVersion,
                required String bodyJson,
                Value<String?> responseJson = const Value.absent(),
                required String phase,
                required DateTime createdAt,
                Value<int> rowid = const Value.absent(),
              }) => StageImportCommandsCompanion.insert(
                spaceId: spaceId,
                stageId: stageId,
                commandId: commandId,
                kind: kind,
                stageVersion: stageVersion,
                bodyJson: bodyJson,
                responseJson: responseJson,
                phase: phase,
                createdAt: createdAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$StageImportCommandsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $StageImportCommandsTable,
      StoredStageImportCommand,
      $$StageImportCommandsTableFilterComposer,
      $$StageImportCommandsTableOrderingComposer,
      $$StageImportCommandsTableAnnotationComposer,
      $$StageImportCommandsTableCreateCompanionBuilder,
      $$StageImportCommandsTableUpdateCompanionBuilder,
      (
        StoredStageImportCommand,
        BaseReferences<
          _$AppDatabase,
          $StageImportCommandsTable,
          StoredStageImportCommand
        >,
      ),
      StoredStageImportCommand,
      PrefetchHooks Function()
    >;
typedef $$StageImportRecoveryChunksTableCreateCompanionBuilder =
    StageImportRecoveryChunksCompanion Function({
      required String backupId,
      required String stageId,
      required int chunkIndex,
      required Uint8List body,
      required String sha256,
      required int sizeBytes,
      Value<int> rowid,
    });
typedef $$StageImportRecoveryChunksTableUpdateCompanionBuilder =
    StageImportRecoveryChunksCompanion Function({
      Value<String> backupId,
      Value<String> stageId,
      Value<int> chunkIndex,
      Value<Uint8List> body,
      Value<String> sha256,
      Value<int> sizeBytes,
      Value<int> rowid,
    });

final class $$StageImportRecoveryChunksTableReferences
    extends
        BaseReferences<
          _$AppDatabase,
          $StageImportRecoveryChunksTable,
          StoredStageImportRecoveryChunk
        > {
  $$StageImportRecoveryChunksTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $SyncRecoveryBackupsTable _backupIdTable(_$AppDatabase db) =>
      db.syncRecoveryBackups.createAlias(
        'stage_import_recovery_chunks__backup_id__sync_recovery_backups__id',
      );

  $$SyncRecoveryBackupsTableProcessedTableManager get backupId {
    final $_column = $_itemColumn<String>('backup_id')!;

    final manager = $$SyncRecoveryBackupsTableTableManager(
      $_db,
      $_db.syncRecoveryBackups,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_backupIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$StageImportRecoveryChunksTableFilterComposer
    extends Composer<_$AppDatabase, $StageImportRecoveryChunksTable> {
  $$StageImportRecoveryChunksTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get stageId => $composableBuilder(
    column: $table.stageId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get chunkIndex => $composableBuilder(
    column: $table.chunkIndex,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<Uint8List> get body => $composableBuilder(
    column: $table.body,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sha256 => $composableBuilder(
    column: $table.sha256,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sizeBytes => $composableBuilder(
    column: $table.sizeBytes,
    builder: (column) => ColumnFilters(column),
  );

  $$SyncRecoveryBackupsTableFilterComposer get backupId {
    final $$SyncRecoveryBackupsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.backupId,
      referencedTable: $db.syncRecoveryBackups,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SyncRecoveryBackupsTableFilterComposer(
            $db: $db,
            $table: $db.syncRecoveryBackups,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$StageImportRecoveryChunksTableOrderingComposer
    extends Composer<_$AppDatabase, $StageImportRecoveryChunksTable> {
  $$StageImportRecoveryChunksTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get stageId => $composableBuilder(
    column: $table.stageId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get chunkIndex => $composableBuilder(
    column: $table.chunkIndex,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<Uint8List> get body => $composableBuilder(
    column: $table.body,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sha256 => $composableBuilder(
    column: $table.sha256,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sizeBytes => $composableBuilder(
    column: $table.sizeBytes,
    builder: (column) => ColumnOrderings(column),
  );

  $$SyncRecoveryBackupsTableOrderingComposer get backupId {
    final $$SyncRecoveryBackupsTableOrderingComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.backupId,
          referencedTable: $db.syncRecoveryBackups,
          getReferencedColumn: (t) => t.id,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$SyncRecoveryBackupsTableOrderingComposer(
                $db: $db,
                $table: $db.syncRecoveryBackups,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return composer;
  }
}

class $$StageImportRecoveryChunksTableAnnotationComposer
    extends Composer<_$AppDatabase, $StageImportRecoveryChunksTable> {
  $$StageImportRecoveryChunksTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get stageId =>
      $composableBuilder(column: $table.stageId, builder: (column) => column);

  GeneratedColumn<int> get chunkIndex => $composableBuilder(
    column: $table.chunkIndex,
    builder: (column) => column,
  );

  GeneratedColumn<Uint8List> get body =>
      $composableBuilder(column: $table.body, builder: (column) => column);

  GeneratedColumn<String> get sha256 =>
      $composableBuilder(column: $table.sha256, builder: (column) => column);

  GeneratedColumn<int> get sizeBytes =>
      $composableBuilder(column: $table.sizeBytes, builder: (column) => column);

  $$SyncRecoveryBackupsTableAnnotationComposer get backupId {
    final $$SyncRecoveryBackupsTableAnnotationComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.backupId,
          referencedTable: $db.syncRecoveryBackups,
          getReferencedColumn: (t) => t.id,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$SyncRecoveryBackupsTableAnnotationComposer(
                $db: $db,
                $table: $db.syncRecoveryBackups,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return composer;
  }
}

class $$StageImportRecoveryChunksTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $StageImportRecoveryChunksTable,
          StoredStageImportRecoveryChunk,
          $$StageImportRecoveryChunksTableFilterComposer,
          $$StageImportRecoveryChunksTableOrderingComposer,
          $$StageImportRecoveryChunksTableAnnotationComposer,
          $$StageImportRecoveryChunksTableCreateCompanionBuilder,
          $$StageImportRecoveryChunksTableUpdateCompanionBuilder,
          (
            StoredStageImportRecoveryChunk,
            $$StageImportRecoveryChunksTableReferences,
          ),
          StoredStageImportRecoveryChunk,
          PrefetchHooks Function({bool backupId})
        > {
  $$StageImportRecoveryChunksTableTableManager(
    _$AppDatabase db,
    $StageImportRecoveryChunksTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$StageImportRecoveryChunksTableFilterComposer(
                $db: db,
                $table: table,
              ),
          createOrderingComposer: () =>
              $$StageImportRecoveryChunksTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$StageImportRecoveryChunksTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> backupId = const Value.absent(),
                Value<String> stageId = const Value.absent(),
                Value<int> chunkIndex = const Value.absent(),
                Value<Uint8List> body = const Value.absent(),
                Value<String> sha256 = const Value.absent(),
                Value<int> sizeBytes = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => StageImportRecoveryChunksCompanion(
                backupId: backupId,
                stageId: stageId,
                chunkIndex: chunkIndex,
                body: body,
                sha256: sha256,
                sizeBytes: sizeBytes,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String backupId,
                required String stageId,
                required int chunkIndex,
                required Uint8List body,
                required String sha256,
                required int sizeBytes,
                Value<int> rowid = const Value.absent(),
              }) => StageImportRecoveryChunksCompanion.insert(
                backupId: backupId,
                stageId: stageId,
                chunkIndex: chunkIndex,
                body: body,
                sha256: sha256,
                sizeBytes: sizeBytes,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$StageImportRecoveryChunksTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({backupId = false}) {
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
                    if (backupId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.backupId,
                                referencedTable:
                                    $$StageImportRecoveryChunksTableReferences
                                        ._backupIdTable(db),
                                referencedColumn:
                                    $$StageImportRecoveryChunksTableReferences
                                        ._backupIdTable(db)
                                        .id,
                              )
                              as T;
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

typedef $$StageImportRecoveryChunksTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $StageImportRecoveryChunksTable,
      StoredStageImportRecoveryChunk,
      $$StageImportRecoveryChunksTableFilterComposer,
      $$StageImportRecoveryChunksTableOrderingComposer,
      $$StageImportRecoveryChunksTableAnnotationComposer,
      $$StageImportRecoveryChunksTableCreateCompanionBuilder,
      $$StageImportRecoveryChunksTableUpdateCompanionBuilder,
      (
        StoredStageImportRecoveryChunk,
        $$StageImportRecoveryChunksTableReferences,
      ),
      StoredStageImportRecoveryChunk,
      PrefetchHooks Function({bool backupId})
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$AppSettingsTableTableManager get appSettings =>
      $$AppSettingsTableTableManager(_db, _db.appSettings);
  $$LocalSpacesTableTableManager get localSpaces =>
      $$LocalSpacesTableTableManager(_db, _db.localSpaces);
  $$LocalDraftsTableTableManager get localDrafts =>
      $$LocalDraftsTableTableManager(_db, _db.localDrafts);
  $$LocalEntitiesTableTableManager get localEntities =>
      $$LocalEntitiesTableTableManager(_db, _db.localEntities);
  $$PendingOperationsTableTableManager get pendingOperations =>
      $$PendingOperationsTableTableManager(_db, _db.pendingOperations);
  $$ServerShadowsTableTableManager get serverShadows =>
      $$ServerShadowsTableTableManager(_db, _db.serverShadows);
  $$SyncStatesTableTableManager get syncStates =>
      $$SyncStatesTableTableManager(_db, _db.syncStates);
  $$SyncConflictsTableTableManager get syncConflicts =>
      $$SyncConflictsTableTableManager(_db, _db.syncConflicts);
  $$SyncRecoveryBackupsTableTableManager get syncRecoveryBackups =>
      $$SyncRecoveryBackupsTableTableManager(_db, _db.syncRecoveryBackups);
  $$SnapshotPagesTableTableManager get snapshotPages =>
      $$SnapshotPagesTableTableManager(_db, _db.snapshotPages);
  $$GroupPullsTableTableManager get groupPulls =>
      $$GroupPullsTableTableManager(_db, _db.groupPulls);
  $$GroupPagesTableTableManager get groupPages =>
      $$GroupPagesTableTableManager(_db, _db.groupPages);
  $$GroupReceiptsTableTableManager get groupReceipts =>
      $$GroupReceiptsTableTableManager(_db, _db.groupReceipts);
  $$StageImportSourcesTableTableManager get stageImportSources =>
      $$StageImportSourcesTableTableManager(_db, _db.stageImportSources);
  $$StageImportChunksTableTableManager get stageImportChunks =>
      $$StageImportChunksTableTableManager(_db, _db.stageImportChunks);
  $$StageImportCommandsTableTableManager get stageImportCommands =>
      $$StageImportCommandsTableTableManager(_db, _db.stageImportCommands);
  $$StageImportRecoveryChunksTableTableManager get stageImportRecoveryChunks =>
      $$StageImportRecoveryChunksTableTableManager(
        _db,
        _db.stageImportRecoveryChunks,
      );
}
