import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'supabase_config.dart';

const primary = Color(0xff9b7bff);
const background = Color(0xff090a0f);
const cardColor = Color(0xff12141d);

// Сигнал об изменении остатков.
final ValueNotifier<int> inventoryVersion = ValueNotifier<int>(0);

void notifyInventoryChanged() {
  inventoryVersion.value++;
}

String money(num value) => '${value.toStringAsFixed(2)} ₽';

String formatDateTime(Object? value) {
  final raw = value?.toString() ?? '';
  final date = DateTime.tryParse(raw);

  if (date == null) {
    return raw;
  }

  final local = date.isUtc ? date.toLocal() : date;

  String two(int n) => n.toString().padLeft(2, '0');

  return '${two(local.day)}.${two(local.month)}.${local.year} • '
      '${two(local.hour)}:${two(local.minute)}';
}

String hashPassword(String value) {
  return sha256.convert(utf8.encode(value)).toString();
}

const sellerPermissionDefaults = <String, bool>{
  'sell': true,
  'returns': true,
  'defects': true,
  'products_view': true,
  'products_edit': false,
  'stats': true,
  'profit': false,
  'shift': true,
  'history': true,
  'receipts': true,
  'backup': false,
  'purchases': false,
  'product_history': true,
};

const permissionLabels = <String, String>{
  'sell': 'Продажи',
  'returns': 'Возвраты',
  'defects': 'Списание брака',
  'products_view': 'Просмотр товаров',
  'products_edit': 'Добавление и изменение товаров',
  'stats': 'Статистика',
  'profit': 'Видеть прибыль и закупочные цены',
  'shift': 'Кассовая смена',
  'history': 'История операций',
  'receipts': 'Чеки',
  'backup': 'Резервная копия',
  'purchases': 'Закупки и пополнение товара',
  'product_history': 'История товара',
};

Map<String, bool> decodePermissions(Object? raw) {
  final result = <String, bool>{...sellerPermissionDefaults};

  Map<dynamic, dynamic>? decoded;

  if (raw is Map) {
    // Supabase JSONB приходит в Flutter как Map.
    decoded = raw;
  } else if (raw is String && raw.trim().isNotEmpty) {
    try {
      final value = jsonDecode(raw);
      if (value is Map) {
        decoded = value;
      }
    } catch (_) {}
  }

  if (decoded != null) {
    for (final key in sellerPermissionDefaults.keys) {
      final value = decoded[key];
      if (value is bool) {
        result[key] = value;
      }
    }
  }

  return result;
}
bool hasPermission(Map<String, dynamic> user, String permission) {
  if (user['role']?.toString() == 'admin') return true;
  return decodePermissions(user['permissions'])[permission] ?? false;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await DB.i.open();

  await Supabase.initialize(
    url: supabaseUrl,
    publishableKey: supabasePublishableKey,
  );

  runApp(const App());
}

class DB {
  DB._();

  static final DB i = DB._();
  Database? db;

  Future<Database> open() async {
    if (db != null) return db!;

    final dir = await getDatabasesPath();
    final path = p.join(dir, 'shop.db');

    if (!await databaseExists(path)) {
      final bytes = await rootBundle.load('assets/shop.db');
      await File(path).writeAsBytes(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      );
    }

    db = await openDatabase(path, version: 1);
    final database = db!;

    await _ensureColumn(
      database,
      'products',
      'purchase_price',
      'REAL DEFAULT 0',
    );
    // ID товара на сервере Supabase. Локальный id сохраняем для совместимости
    // с текущими продажами, пока продажи не перенесены на сервер.
    await _ensureColumn(
      database,
      'products',
      'server_id',
      'INTEGER',
    );
    await _ensureColumn(
      database,
      'operations',
      'cost',
      'REAL DEFAULT 0',
    );
    await _ensureColumn(
      database,
      'operations',
      'profit',
      'REAL DEFAULT 0',
    );
    await _ensureColumn(
      database,
      'operations',
      'seller',
      "TEXT DEFAULT ''",
    );

    await _ensureColumn(
      database,
      'operations',
      'payment_method',
      "TEXT DEFAULT 'Наличные'",
    );

    await database.execute("""
      CREATE TABLE IF NOT EXISTS users(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        username TEXT UNIQUE NOT NULL,
        password_hash TEXT NOT NULL,
        role TEXT NOT NULL DEFAULT 'seller',
        full_name TEXT NOT NULL,
        active INTEGER NOT NULL DEFAULT 1,
        created_at TEXT NOT NULL
      )
    """);

    await _ensureColumn(
      database,
      'users',
      'permissions',
      "TEXT DEFAULT ''",
    );

    final sellersWithoutPermissions = await database.query(
      'users',
      columns: ['id'],
      where: "role = 'seller' AND (permissions IS NULL OR permissions = '')",
    );

    for (final seller in sellersWithoutPermissions) {
      await database.update(
        'users',
        {'permissions': jsonEncode(sellerPermissionDefaults)},
        where: 'id = ?',
        whereArgs: [seller['id']],
      );
    }

    await database.execute("""
      CREATE TABLE IF NOT EXISTS receipts(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        seller TEXT NOT NULL,
        subtotal REAL NOT NULL,
        discount REAL NOT NULL,
        total REAL NOT NULL,
        created_at TEXT NOT NULL
      )
    """);

    await _ensureColumn(
      database,
      'receipts',
      'payment_method',
      "TEXT DEFAULT 'Наличные'",
    );

    await database.execute("""
      CREATE TABLE IF NOT EXISTS receipt_items(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        receipt_id INTEGER NOT NULL,
        barcode TEXT,
        product_name TEXT,
        quantity INTEGER,
        price REAL,
        purchase_price REAL,
        discount REAL,
        total REAL,
        cost REAL,
        profit REAL
      )
    """);

    await database.execute('''
      CREATE TABLE IF NOT EXISTS purchase_reports(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        product_id INTEGER NOT NULL,
        seller TEXT NOT NULL,
        quantity INTEGER NOT NULL,
        purchase_price REAL NOT NULL,
        created_at TEXT NOT NULL
      )
    ''');

    await database.execute('''
      CREATE TABLE IF NOT EXISTS purchase_photos(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        report_id INTEGER NOT NULL,
        file_path TEXT NOT NULL,
        created_at TEXT NOT NULL
      )
    ''');

    await database.execute(
      'CREATE TABLE IF NOT EXISTS shifts('
      'id INTEGER PRIMARY KEY AUTOINCREMENT,'
      'opened_by TEXT NOT NULL,'
      'opened_at TEXT NOT NULL,'
      'opening_cash REAL NOT NULL DEFAULT 0,'
      'closed_by TEXT,'
      'closed_at TEXT,'
      'closing_cash REAL,'
      'status TEXT NOT NULL DEFAULT "open"'
      ')',
    );

    final admin = await database.query(
      'users',
      where: 'username = ?',
      whereArgs: ['admin'],
      limit: 1,
    );

    if (admin.isEmpty) {
      await database.insert('users', {
        'username': 'admin',
        'password_hash': hashPassword('admin123'),
        'role': 'admin',
        'full_name': 'Администратор',
        'active': 1,
        'created_at': DateTime.now().toIso8601String(),
      });
    }

    return database;
  }

  Future<void> _ensureColumn(
    Database database,
    String table,
    String column,
    String definition,
  ) async {
    final columns = await database.rawQuery('PRAGMA table_info($table)');
    final exists = columns.any(
      (row) => row['name']?.toString() == column,
    );

    if (!exists) {
      await database.execute(
        'ALTER TABLE $table ADD COLUMN $column $definition',
      );
    }
  }

  Future<Map<String, dynamic>?> login(
  String email,
  String password,
) async {
  try {
    // Вход через Supabase Auth
    final response = await Supabase.instance.client.auth
        .signInWithPassword(
      email: email.trim(),
      password: password,
    );

    final authUser = response.user;

    if (authUser == null) {
      return null;
    }

    // Получаем профиль пользователя из нашей таблицы users
    final profile = await Supabase.instance.client
        .from('users')
        .select()
        .eq('auth_user_id', authUser.id)
        .eq('active', true)
        .maybeSingle();

    if (profile == null) {
      await Supabase.instance.client.auth.signOut();
      return null;
    }

    final result = Map<String, dynamic>.from(profile);
    print('LOGIN PROFILE: ${result['username']} permissions=${result['permissions']}');
    return result;
  } catch (e) {
    print('LOGIN ERROR: $e');
    return null;
  }
  }



  // =========================
  // ТОВАРЫ: SUPABASE + ЛОКАЛЬНЫЙ КЭШ
  // =========================

  Future<List<Map<String, dynamic>>> serverProducts() async {
    final data = await Supabase.instance.client
        .from('products')
        .select()
        .order('name');

    return List<Map<String, dynamic>>.from(
      data.map((row) => Map<String, dynamic>.from(row)),
    );
  }

  Future<void> cacheServerProducts(
    List<Map<String, dynamic>> serverRows,
  ) async {
    for (final serverProduct in serverRows) {
      final barcode = serverProduct['barcode']?.toString().trim() ?? '';
      if (barcode.isEmpty) continue;

      final localRows = await db!.query(
        'products',
        where: 'barcode = ?',
        whereArgs: [barcode],
        limit: 1,
      );

      final localData = <String, dynamic>{
        'barcode': barcode,
        'name': serverProduct['name']?.toString() ?? '',
        'price': (serverProduct['price'] as num?)?.toDouble() ?? 0,
        'quantity': (serverProduct['quantity'] as num?)?.toInt() ?? 0,
        'purchase_price':
            (serverProduct['purchase_price'] as num?)?.toDouble() ?? 0,
        'server_id': (serverProduct['id'] as num?)?.toInt(),
      };

      if (localRows.isEmpty) {
        await db!.insert('products', localData);
      } else {
        await db!.update(
          'products',
          localData,
          where: 'id = ?',
          whereArgs: [localRows.first['id']],
        );
      }
    }
  }

  Future<List<Map<String, dynamic>>> products([String query = '']) async {
    try {
      final serverRows = await serverProducts();
      await cacheServerProducts(serverRows);

      final q = query.trim().toLowerCase();
      final filtered = q.isEmpty
          ? serverRows
          : serverRows.where((product) {
              final name =
                  product['name']?.toString().toLowerCase() ?? '';
              final barcode =
                  product['barcode']?.toString().toLowerCase() ?? '';
              return name.contains(q) || barcode.contains(q);
            }).toList();

      // Возвращаем локальные строки, чтобы старый модуль продаж продолжал
      // работать с локальным id. У серверного товара есть server_id.
      final result = <Map<String, dynamic>>[];
      for (final serverProduct in filtered) {
        final barcode = serverProduct['barcode']?.toString() ?? '';
        final localRows = await db!.query(
          'products',
          where: 'barcode = ?',
          whereArgs: [barcode],
          limit: 1,
        );
        if (localRows.isNotEmpty) {
          result.add(localRows.first);
        }
      }
      return result;
    } catch (e) {
      print('SERVER PRODUCTS ERROR: $e');

      if (query.trim().isEmpty) {
        return db!.query(
          'products',
          where: 'server_id IS NOT NULL',
          orderBy: 'name COLLATE NOCASE',
        );
      }

      final q = query.trim();
      return db!.query(
        'products',
        where: '(name LIKE ? OR barcode LIKE ?) AND server_id IS NOT NULL',
        whereArgs: ['%$q%', '%$q%'],
        orderBy: 'name COLLATE NOCASE',
      );
    }
  }

  Future<Map<String, dynamic>?> product(String barcode) async {
    final code = barcode.trim();
    if (code.isEmpty) return null;

    try {
      final data = await Supabase.instance.client
          .from('products')
          .select()
          .eq('barcode', code)
          .maybeSingle();

      if (data != null) {
        await cacheServerProducts([Map<String, dynamic>.from(data)]);
      }
    } catch (e) {
      print('SERVER PRODUCT ERROR: $e');
    }

    final rows = await db!.query(
      'products',
      where: 'barcode = ? AND server_id IS NOT NULL',
      whereArgs: [code],
      limit: 1,
    );

    return rows.isEmpty ? null : rows.first;
  }

  Future<void> saveProduct(Map<String, dynamic> product) async {
    final barcode = product['barcode']?.toString().trim() ?? '';
    if (barcode.isEmpty) {
      throw Exception('Штрихкод не может быть пустым');
    }

    final data = <String, dynamic>{
      'barcode': barcode,
      'name': product['name']?.toString().trim() ?? '',
      'price': (product['price'] as num?)?.toDouble() ?? 0,
      'quantity': (product['quantity'] as num?)?.toInt() ?? 0,
      'purchase_price':
          (product['purchase_price'] as num?)?.toDouble() ?? 0,
    };

    final serverId = (product['server_id'] as num?)?.toInt();
    final localId = (product['id'] as num?)?.toInt();

    Map<String, dynamic>? savedServerProduct;

    if (serverId == null) {
      savedServerProduct = Map<String, dynamic>.from(
        await Supabase.instance.client
            .from('products')
            .insert(data)
            .select()
            .single(),
      );
    } else {
      savedServerProduct = Map<String, dynamic>.from(
        await Supabase.instance.client
            .from('products')
            .update(data)
            .eq('id', serverId)
            .select()
            .single(),
      );
    }

    final savedServerId =
        (savedServerProduct['id'] as num?)?.toInt();
    final localData = <String, dynamic>{
      ...data,
      'server_id': savedServerId,
    };

    if (localId == null) {
      final existing = await db!.query(
        'products',
        where: 'barcode = ?',
        whereArgs: [barcode],
        limit: 1,
      );

      if (existing.isEmpty) {
        await db!.insert('products', localData);
      } else {
        await db!.update(
          'products',
          localData,
          where: 'id = ?',
          whereArgs: [existing.first['id']],
        );
      }
    } else {
      await db!.update(
        'products',
        localData,
        where: 'id = ?',
        whereArgs: [localId],
      );
    }
  }

  Future<int> createPurchaseReport({
    required int productId,
    required String seller,
    required int quantity,
    required double purchasePrice,
    List<String> photoPaths = const [],
  }) async {
    if (quantity <= 0) return 0;
    final now = DateTime.now().toIso8601String();

    final reportId = await db!.transaction<int>((transaction) async {
      final id = await transaction.insert('purchase_reports', {
        'product_id': productId,
        'seller': seller,
        'quantity': quantity,
        'purchase_price': purchasePrice,
        'created_at': now,
      });

      for (final path in photoPaths) {
        await transaction.insert('purchase_photos', {
          'report_id': id,
          'file_path': path,
          'created_at': now,
        });
      }

      return id;
    });

    return reportId;
  }

  Future<int> sale(
    List<CartItem> cart,
    double discount,
    String seller,
    String paymentMethod,
  ) async {
    if (cart.isEmpty) return 0;

    final subtotal = cart.fold<double>(
      0,
      (sum, item) => sum + item.total,
    );
    final discountAmount = subtotal * discount / 100;
    final receiptTotal = subtotal - discountAmount;

    final items = cart.map((item) => {
      'barcode': item.code,
      'quantity': item.qty,
    }).toList();

    final response = await Supabase.instance.client.rpc(
      'process_sale',
      params: {
        'p_items': items,
        'p_subtotal': subtotal,
        'p_discount': discountAmount,
        'p_total': receiptTotal,
        'p_payment_method': paymentMethod,
        'p_seller_name': seller,
      },
    );

    if (response is Map) {
      final data = Map<String, dynamic>.from(response);
      final receiptId = (data['receipt_id'] as num?)?.toInt();
      if (receiptId != null) {
        // Сервер уже изменил остаток и создал чек атомарно.
        // Обновляем локальный кэш только после успешного ответа сервера.
        await _syncSoldProductsToLocalCache(cart);
        notifyInventoryChanged();
        return receiptId;
      }
    }

    throw Exception('Сервер не вернул номер чека');
  }

  Future<void> _syncSoldProductsToLocalCache(List<CartItem> cart) async {
    for (final item in cart) {
      try {
        final serverProduct = await Supabase.instance.client
            .from('products')
            .select()
            .eq('barcode', item.code)
            .maybeSingle();

        if (serverProduct == null) continue;

        final serverId = (serverProduct['id'] as num?)?.toInt();
        final existing = await db!.query(
          'products',
          where: 'barcode = ?',
          whereArgs: [item.code],
          limit: 1,
        );

        final localData = {
          'barcode': serverProduct['barcode'],
          'name': serverProduct['name'],
          'price': (serverProduct['price'] as num?)?.toDouble() ?? 0,
          'quantity': (serverProduct['quantity'] as num?)?.toInt() ?? 0,
          'purchase_price':
              (serverProduct['purchase_price'] as num?)?.toDouble() ?? 0,
          'server_id': serverId,
        };

        if (existing.isEmpty) {
          await db!.insert('products', localData);
        } else {
          await db!.update(
            'products',
            localData,
            where: 'id = ?',
            whereArgs: [existing.first['id']],
          );
        }
      } catch (e) {
        print('LOCAL PRODUCT CACHE SYNC ERROR: $e');
      }
    }
  }

  Future<Map<String, dynamic>?> currentShift() async {
    try {
      final response = await Supabase.instance.client.rpc(
        'get_current_shift',
      );

      if (response == null) return null;
      if (response is Map) {
        return Map<String, dynamic>.from(response);
      }

      return null;
    } catch (e) {
      print('SUPABASE CURRENT SHIFT ERROR: $e');
      rethrow;
    }
  }

  Future<int> openShift(String openedBy, double openingCash) async {
    try {
      final response = await Supabase.instance.client.rpc(
        'open_shift',
        params: {
          'p_opening_cash': openingCash,
        },
      );

      if (response is Map && response['success'] == true) {
        return (response['shift_id'] as num).toInt();
      }

      throw Exception('Не удалось открыть смену на сервере');
    } catch (e) {
      print('SUPABASE OPEN SHIFT ERROR: $e');
      rethrow;
    }
  }

  Future<void> closeShift(
    int shiftId,
    String closedBy,
    double closingCash,
  ) async {
    try {
      final response = await Supabase.instance.client.rpc(
        'close_shift',
        params: {
          'p_closing_cash': closingCash,
        },
      );

      if (response is Map && response['success'] == true) {
        return;
      }

      throw Exception('Не удалось закрыть смену на сервере');
    } catch (e) {
      print('SUPABASE CLOSE SHIFT ERROR: $e');
      rethrow;
    }
  }

Future<Map<String, num>> shiftTotals(int shiftId) async {
  // Продажи берём из серверных чеков текущей смены.
  final receiptsResponse = await Supabase.instance.client
      .from('receipts')
      .select('id,total,shift_id')
      .eq('shift_id', shiftId);

  final receipts = (receiptsResponse as List)
      .map((row) => Map<String, dynamic>.from(row as Map))
      .toList();

  double sales = 0;
  final receiptIds = <int>{};

  for (final row in receipts) {
    sales += (row['total'] as num?)?.toDouble() ?? 0;

    final id = (row['id'] as num?)?.toInt();
    if (id != null) {
      receiptIds.add(id);
    }
  }

  double sold = 0;

  if (receiptIds.isNotEmpty) {
    final itemsResponse = await Supabase.instance.client
        .from('receipt_items')
        .select('receipt_id,quantity');

    for (final raw in (itemsResponse as List)) {
      final row = Map<String, dynamic>.from(raw as Map);
      final receiptId = (row['receipt_id'] as num?)?.toInt();

      if (receiptId != null && receiptIds.contains(receiptId)) {
        sold += (row['quantity'] as num?)?.toDouble() ?? 0;
      }
    }
  }

  double returns = 0;

  final operationsResponse = await Supabase.instance.client
      .from('operations')
      .select('operation_type,total,quantity,shift_id')
      .eq('shift_id', shiftId);

  for (final raw in (operationsResponse as List)) {
    final row = Map<String, dynamic>.from(raw as Map);

    if (row['operation_type']?.toString() == 'Возврат') {
      returns += (row['total'] as num?)?.toDouble() ?? 0;
    }
  }

  return <String, num>{
    'sales': sales,
    'returns': returns,
    'sold': sold,
  };
}

  Future<List<Map<String, dynamic>>> receipts(
    String seller, {
    DateTime? from,
    DateTime? to,
    String paymentMethod = '',
  }) async {
    // Чеки хранятся на сервере Supabase. Локальная SQLite больше
    // не является источником списка чеков.
    var query = Supabase.instance.client
        .from('receipts')
        .select();

    if (seller.isNotEmpty) {
      query = query.eq('seller', seller);
    }

    if (from != null) {
      final start = DateTime(from.year, from.month, from.day);
      query = query.gte('created_at', start.toUtc().toIso8601String());
    }

    if (to != null) {
      final end = DateTime(to.year, to.month, to.day)
          .add(const Duration(days: 1));
      query = query.lt('created_at', end.toUtc().toIso8601String());
    }

    final serverPayment = switch (paymentMethod) {
      'Наличные' => 'cash',
      'Карта' => 'card',
      'Перевод' => 'transfer',
      _ => '',
    };

    if (serverPayment.isNotEmpty) {
      query = query.eq('payment_method', serverPayment);
    }

    final rows = await query.order('id', ascending: false).limit(500);

    return (rows as List)
        .map((row) {
          final item = Map<String, dynamic>.from(row as Map);
          final method = item['payment_method']?.toString() ?? '';
          item['payment_method'] = switch (method) {
            'cash' => 'Наличные',
            'card' => 'Карта',
            'transfer' => 'Перевод',
            _ => method,
          };
          return item;
        })
        .toList();
  }

  Future<List<Map<String, dynamic>>> receiptItems(
    int receiptId,
  ) async {
    final rows = await Supabase.instance.client
        .from('receipt_items')
        .select()
        .eq('receipt_id', receiptId)
        .order('id', ascending: true);

    return (rows as List)
        .map((row) => Map<String, dynamic>.from(row as Map))
        .toList();
  }

  Future<Map<String, dynamic>?> receipt(
    int receiptId,
  ) async {
    final row = await Supabase.instance.client
        .from('receipts')
        .select()
        .eq('id', receiptId)
        .maybeSingle();

    if (row == null) return null;

    final result = Map<String, dynamic>.from(row);
    final method = result['payment_method']?.toString() ?? '';
    result['payment_method'] = switch (method) {
      'cash' => 'Наличные',
      'card' => 'Карта',
      'transfer' => 'Перевод',
      _ => method,
    };

    return result;
  }

  Future<void> stock(
    int productId,
    int delta,
    String type,
    String seller,
  ) async {
    if (await currentShift() == null) {
      throw Exception('Смена не открыта. Сначала откройте смену.');
    }

    if (delta == 0) {
      throw Exception('Изменение количества не может быть равно нулю');
    }

    // Сначала меняем остаток на сервере Supabase.
    // Для возврата остаток увеличивается, для брака уменьшается.
    final productRows = await db!.query(
      'products',
      where: 'id = ?',
      whereArgs: [productId],
      limit: 1,
    );
    if (productRows.isEmpty) throw Exception('Товар не найден');

    final product = productRows.first;
    final barcode = product['barcode']?.toString() ?? '';
    if (barcode.isEmpty) throw Exception('У товара нет штрихкода');

    await _applyStockAdjustmentToSupabase(
      barcode: barcode,
      delta: delta,
      type: type,
    );

    try {
      await db!.transaction((transaction) async {
        final rows = await transaction.query(
          'products',
          where: 'id = ?',
          whereArgs: [productId],
          limit: 1,
        );

        if (rows.isEmpty) {
          throw Exception('Товар не найден');
        }

        final localProduct = rows.first;
        final oldQuantity = (localProduct['quantity'] as num).toInt();
        final newQuantity = oldQuantity + delta;

        if (newQuantity < 0) {
          throw Exception('Недостаточно товара на складе');
        }

        final quantity = delta.abs();
        final purchasePrice =
            (localProduct['purchase_price'] as num?)?.toDouble() ?? 0;
        final price = (localProduct['price'] as num).toDouble();

        await transaction.update(
          'products',
          {'quantity': newQuantity},
          where: 'id = ?',
          whereArgs: [productId],
        );

        final total = type == 'Возврат' ? price * quantity : 0.0;
        final profit = type == 'Брак'
            ? -purchasePrice * quantity
            : -(price * quantity - purchasePrice * quantity);

        await transaction.insert('operations', {
          'operation_type': type,
          'barcode': localProduct['barcode'],
          'product_name': localProduct['name'],
          'quantity': quantity,
          'price': price,
          'discount': 0,
          'total': total,
          'created_at': DateTime.now().toIso8601String(),
          'cost': purchasePrice * quantity,
          'profit': profit,
          'seller': seller,
        });
      });

      notifyInventoryChanged();
    } catch (e) {
      // Если локальная запись не удалась, возвращаем серверный остаток назад.
      try {
        await _applyStockAdjustmentToSupabase(
          barcode: barcode,
          delta: -delta,
          type: type,
          compensation: true,
        );
      } catch (restoreError) {
        print('SUPABASE STOCK RESTORE ERROR: $restoreError');
      }
      rethrow;
    }
  }

  Future<void> _applyStockAdjustmentToSupabase({
    required String barcode,
    required int delta,
    required String type,
    bool compensation = false,
  }) async {
    await Supabase.instance.client.rpc(
      'process_stock_adjustment',
      params: {
        'p_barcode': barcode,
        'p_delta': delta,
        'p_type': type,
        'p_compensation': compensation,
      },
    );
  }

  Future<int> purchase(
    int productId,
    int quantity,
    double purchasePrice,
    String seller, {
    List<String> photoPaths = const [],
  }) async {
    if (quantity <= 0) throw Exception('Количество должно быть больше нуля');
    if (purchasePrice < 0) {
      throw Exception('Закупочная цена не может быть отрицательной');
    }
    if (await currentShift() == null) {
      throw Exception('Смена не открыта. Сначала откройте смену.');
    }

    final productRows = await db!.query(
      'products',
      where: 'id = ?',
      whereArgs: [productId],
      limit: 1,
    );
    if (productRows.isEmpty) throw Exception('Товар не найден');

    final productBefore = productRows.first;
    final barcode = productBefore['barcode']?.toString() ?? '';
    if (barcode.isEmpty) throw Exception('У товара нет штрихкода');
    final oldPurchasePrice =
        (productBefore['purchase_price'] as num?)?.toDouble() ?? 0;

    // Закупка тоже меняет серверный остаток, а не только SQLite.
    await _applyPurchaseToSupabase(
      barcode: barcode,
      quantity: quantity,
      purchasePrice: purchasePrice,
    );

    try {
      final reportId = await db!.transaction<int>((transaction) async {
        final rows = await transaction.query(
          'products',
          where: 'id = ?',
          whereArgs: [productId],
          limit: 1,
        );
        if (rows.isEmpty) throw Exception('Товар не найден');

        final product = rows.first;
        final oldQuantity = (product['quantity'] as num).toInt();
        final price = (product['price'] as num).toDouble();
        final cost = purchasePrice * quantity;
        final now = DateTime.now().toIso8601String();

        await transaction.update(
          'products',
          {
            'quantity': oldQuantity + quantity,
            'purchase_price': purchasePrice,
          },
          where: 'id = ?',
          whereArgs: [productId],
        );

        await transaction.insert('operations', {
          'operation_type': 'Закупка',
          'barcode': product['barcode'],
          'product_name': product['name'],
          'quantity': quantity,
          'price': price,
          'discount': 0,
          'total': 0,
          'created_at': now,
          'cost': cost,
          'profit': 0,
          'seller': seller,
          'payment_method': 'Наличные',
        });

        final id = await transaction.insert('purchase_reports', {
          'product_id': productId,
          'seller': seller,
          'quantity': quantity,
          'purchase_price': purchasePrice,
          'created_at': now,
        });

        for (final path in photoPaths) {
          await transaction.insert('purchase_photos', {
            'report_id': id,
            'file_path': path,
            'created_at': now,
          });
        }

        return id;
      });

      notifyInventoryChanged();
      return reportId;
    } catch (e) {
      try {
        await _restorePurchaseOnSupabase(
          barcode: barcode,
          quantity: quantity,
          oldPurchasePrice: oldPurchasePrice,
        );
      } catch (restoreError) {
        print('SUPABASE PURCHASE RESTORE ERROR: $restoreError');
      }
      rethrow;
    }
  }

  Future<void> _applyPurchaseToSupabase({
    required String barcode,
    required int quantity,
    required double purchasePrice,
  }) async {
    await Supabase.instance.client.rpc(
      'process_purchase_stock',
      params: {
        'p_barcode': barcode,
        'p_quantity': quantity,
        'p_purchase_price': purchasePrice,
      },
    );
  }

  Future<void> _restorePurchaseOnSupabase({
    required String barcode,
    required int quantity,
    required double oldPurchasePrice,
  }) async {
    await Supabase.instance.client.rpc(
      'restore_purchase_stock',
      params: {
        'p_barcode': barcode,
        'p_quantity': quantity,
        'p_purchase_price': oldPurchasePrice,
      },
    );
  }

  Future<List<Map<String, dynamic>>> purchaseReports({
    String seller = '',
  }) async {
    return db!.query(
      'purchase_reports',
      where: seller.isEmpty ? null : 'seller = ?',
      whereArgs: seller.isEmpty ? null : [seller],
      orderBy: 'id DESC',
      limit: 300,
    );
  }

  Future<List<Map<String, dynamic>>> purchasePhotos(int reportId) async {
    return db!.query(
      'purchase_photos',
      where: 'report_id = ?',
      whereArgs: [reportId],
      orderBy: 'id ASC',
    );
  }

 Future<List<Map<String, dynamic>>> productHistory(
  int productId,
  String seller,
) async {
  final productRows = await db!.query(
    'products',
    where: 'id = ?',
    whereArgs: [productId],
    limit: 1,
  );

  if (productRows.isEmpty) {
    throw Exception('Товар не найден');
  }

  final barcode = productRows.first['barcode']?.toString() ?? '';

  if (barcode.isEmpty) {
    throw Exception('У товара нет штрихкода');
  }

  dynamic query = Supabase.instance.client
      .from('operations')
      .select()
      .eq('barcode', barcode);

  if (seller.isNotEmpty) {
    query = query.eq('seller', seller);
  }

  final response = await query
      .order('id', ascending: false)
      .limit(500);

  return (response as List)
      .map((row) => Map<String, dynamic>.from(row as Map))
      .toList();
}

  Future<List<Map<String, dynamic>>> dailySales(
    String seller, [
    String period = 'all',
  ]) async {
    DateTime? start;
    DateTime? end;

    if (period != 'all') {
      final now = DateTime.now();
      if (period == 'today') {
        start = DateTime(now.year, now.month, now.day);
        end = start.add(const Duration(days: 1));
      } else if (period == 'week') {
        end = DateTime(now.year, now.month, now.day)
            .add(const Duration(days: 1));
        start = end.subtract(const Duration(days: 7));
      } else if (period == 'month') {
        start = DateTime(now.year, now.month);
        end = now.month == 12
            ? DateTime(now.year + 1, 1)
            : DateTime(now.year, now.month + 1);
      }
    }

    final periodStart = start;
    final periodEnd = end;

    bool inPeriod(Object? value) {
      if (periodStart == null || periodEnd == null) return true;
      final date = DateTime.tryParse(value?.toString() ?? '');
      if (date == null) return false;
      final local = date.isUtc ? date.toLocal() : date;
      return !local.isBefore(periodStart) && local.isBefore(periodEnd);
    }

    final receiptsResponse = await Supabase.instance.client
        .from('receipts')
        .select('id,total,seller,created_at')
        .order('created_at', ascending: false);

    final receipts = (receiptsResponse as List)
        .map((row) => Map<String, dynamic>.from(row as Map))
        .where((row) => seller.isEmpty || row['seller']?.toString() == seller)
        .where((row) => inPeriod(row['created_at']))
        .toList();

    if (receipts.isEmpty) return [];

    final receiptIds = receipts
        .map((row) => (row['id'] as num?)?.toInt())
        .whereType<int>()
        .toSet();

    final itemsResponse = await Supabase.instance.client
        .from('receipt_items')
        .select('receipt_id,quantity');

    final soldByReceipt = <int, int>{};
    for (final raw in (itemsResponse as List)) {
      final row = Map<String, dynamic>.from(raw as Map);
      final receiptId = (row['receipt_id'] as num?)?.toInt();
      if (receiptId == null || !receiptIds.contains(receiptId)) continue;
      soldByReceipt[receiptId] =
          (soldByReceipt[receiptId] ?? 0) +
          ((row['quantity'] as num?)?.toInt() ?? 0);
    }

    final grouped = <String, Map<String, dynamic>>{};
    for (final receipt in receipts) {
      final date = DateTime.tryParse(receipt['created_at']?.toString() ?? '');
      if (date == null) continue;
      final local = date.isUtc ? date.toLocal() : date;
      final day =
          '${local.year.toString().padLeft(4, '0')}-'
          '${local.month.toString().padLeft(2, '0')}-'
          '${local.day.toString().padLeft(2, '0')}';
      final id = (receipt['id'] as num?)?.toInt();
      final row = grouped.putIfAbsent(
        day,
        () => {
          'day': day,
          'sales': 0,
          'sold': 0,
          'revenue': 0.0,
        },
      );
      row['sales'] = (row['sales'] as int) + 1;
      row['sold'] = (row['sold'] as int) + (id == null ? 0 : (soldByReceipt[id] ?? 0));
      row['revenue'] =
          (row['revenue'] as double) +
          ((receipt['total'] as num?)?.toDouble() ?? 0);
    }

    final result = grouped.values.toList();
    result.sort((a, b) => b['day'].toString().compareTo(a['day'].toString()));
    return result.take(90).toList();
  }

  Future<List<Map<String, dynamic>>> ops(
    String seller, {
    String? productName,
    String? operationType,
  }) async {
    dynamic query = Supabase.instance.client
        .from('operations')
        .select();

    if (seller.isNotEmpty) {
      query = query.eq('seller', seller);
    }

    if (productName != null && productName.isNotEmpty) {
      query = query.eq('product_name', productName);
    }

    if (operationType != null && operationType.isNotEmpty) {
      query = query.eq('operation_type', operationType);
    }

    final response = await query
        .order('id', ascending: false)
        .limit(300);

    return (response as List)
        .map((row) => Map<String, dynamic>.from(row as Map))
        .toList();
  }

  Future<Map<String, num>> stats(
    String seller, [
    String period = 'all',
  ]) async {
    DateTime? start;
    DateTime? end;

    if (period != 'all') {
      final now = DateTime.now();
      if (period == 'today') {
        start = DateTime(now.year, now.month, now.day);
        end = start.add(const Duration(days: 1));
      } else if (period == 'week') {
        end = DateTime(now.year, now.month, now.day)
            .add(const Duration(days: 1));
        start = end.subtract(const Duration(days: 7));
      } else if (period == 'month') {
        start = DateTime(now.year, now.month);
        end = now.month == 12
            ? DateTime(now.year + 1, 1)
            : DateTime(now.year, now.month + 1);
      }
    }

    final periodStart = start;
    final periodEnd = end;

    bool inPeriod(Object? value) {
      if (periodStart == null || periodEnd == null) return true;
      final date = DateTime.tryParse(value?.toString() ?? '');
      if (date == null) return false;
      final local = date.isUtc ? date.toLocal() : date;
      return !local.isBefore(periodStart) && local.isBefore(periodEnd);
    }

    final receipts = await Supabase.instance.client
        .from('receipts')
        .select('id,total,seller,created_at')
        .order('id', ascending: false);

    final receiptRows = (receipts as List)
        .map((row) => Map<String, dynamic>.from(row as Map))
        .where((row) => seller.isEmpty || row['seller']?.toString() == seller)
        .where((row) => inPeriod(row['created_at']))
        .toList();

    final receiptIds = receiptRows
        .map((row) => (row['id'] as num?)?.toInt())
        .whereType<int>()
        .toSet();

    double revenue = 0;
    for (final row in receiptRows) {
      revenue += (row['total'] as num?)?.toDouble() ?? 0;
    }

    double sold = 0;
    double profit = 0;

    if (receiptIds.isNotEmpty) {
      final items = await Supabase.instance.client
          .from('receipt_items')
          .select('receipt_id,quantity,profit');

      for (final raw in (items as List)) {
        final row = Map<String, dynamic>.from(raw as Map);
        final receiptId = (row['receipt_id'] as num?)?.toInt();
        if (receiptId != null && receiptIds.contains(receiptId)) {
          sold += (row['quantity'] as num?)?.toDouble() ?? 0;
          profit += (row['profit'] as num?)?.toDouble() ?? 0;
        }
      }
    }

    double returns = 0;
    double defects = 0;

    final operations = await Supabase.instance.client
        .from('operations')
        .select('operation_type,total,quantity,seller,created_at')
        .order('id', ascending: false)
        .limit(1000);

    for (final raw in (operations as List)) {
      final row = Map<String, dynamic>.from(raw as Map);
      if (seller.isNotEmpty && row['seller']?.toString() != seller) {
        continue;
      }
      if (!inPeriod(row['created_at'])) continue;

      final type = row['operation_type']?.toString();
      if (type == 'Возврат') {
        returns += (row['total'] as num?)?.toDouble() ?? 0;
      } else if (type == 'Брак') {
        defects += (row['quantity'] as num?)?.toDouble() ?? 0;
      }
    }

    return <String, num>{
      'sales': receiptRows.length,
      'sold': sold,
      'revenue': revenue,
      'profit': profit,
      'returns': returns,
      'defects': defects,
    };
  }

  Future<List<Map<String, dynamic>>> sellerStats(
    String period,
  ) async {
    final conditions = <String>[];
    final args = <Object?>[];

    if (period != 'all') {
      final now = DateTime.now();
      late final DateTime start;
      late final DateTime end;

      if (period == 'today') {
        start = DateTime(now.year, now.month, now.day);
        end = start.add(const Duration(days: 1));
      } else if (period == 'week') {
        end = DateTime(now.year, now.month, now.day).add(
          const Duration(days: 1),
        );
        start = end.subtract(const Duration(days: 7));
      } else if (period == 'month') {
        start = DateTime(now.year, now.month);
        end = now.month == 12
            ? DateTime(now.year + 1, 1)
            : DateTime(now.year, now.month + 1);
      } else {
        start = DateTime(2000);
        end = DateTime(2100);
      }

      conditions.add('r.created_at >= ? AND r.created_at < ?');
      args.add(start.toIso8601String());
      args.add(end.toIso8601String());
    }

    final where = conditions.isEmpty
        ? ''
        : ' WHERE ${conditions.join(' AND ')}';

    return db!.rawQuery(
      '''
      SELECT
        r.seller,
        COUNT(r.id) AS sales,
        COALESCE(SUM(it.sold), 0) AS sold,
        COALESCE(SUM(r.total), 0) AS revenue,
        COALESCE(SUM(it.profit), 0) AS profit
      FROM receipts r
      LEFT JOIN (
        SELECT
          receipt_id,
          SUM(quantity) AS sold,
          SUM(profit) AS profit
        FROM receipt_items
        GROUP BY receipt_id
      ) it ON it.receipt_id = r.id
      $where
      GROUP BY r.seller
      ORDER BY revenue DESC
      ''',
      args,
    );
  }

  Future<List<Map<String, dynamic>>> users() async {
    return db!.query(
      'users',
      orderBy: 'full_name COLLATE NOCASE',
    );
  }

  Future<void> saveUser(Map<String, dynamic> user) async {
    if (user['id'] == null) {
      await db!.insert('users', user);
    } else {
      await db!.update(
        'users',
        user,
        where: 'id = ?',
        whereArgs: [user['id']],
      );
    }
  }

  Future<void> clearAllData() async {
    final database = db!;

    final photoRows = await database.query(
      'purchase_photos',
      columns: ['file_path'],
    );

    await database.transaction((txn) async {
      // Рабочие данные удаляем полностью, пользователей оставляем.
      await txn.delete('receipt_items');
      await txn.delete('receipts');
      await txn.delete('operations');
      await txn.delete('purchase_photos');
      await txn.delete('purchase_reports');
      await txn.delete('shifts');
      await txn.delete('products');

      // Начинаем нумерацию заново после очистки тестовых данных.
      await txn.rawDelete(
        "DELETE FROM sqlite_sequence WHERE name IN "
        "('receipt_items', 'receipts', 'operations', "
        "'purchase_photos', 'purchase_reports', 'shifts', 'products')",
      );
    });

    // Удаляем сохранённые фотографии с устройства.
    for (final row in photoRows) {
      final path = row['file_path']?.toString() ?? '';
      if (path.isEmpty) continue;

      try {
        final file = File(path);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (_) {
        // База уже очищена; отсутствие одного файла не должно мешать очистке.
      }
    }

    try {
      final documents = await getApplicationDocumentsDirectory();
      final photosDirectory = Directory(
        p.join(documents.path, 'purchase_photos'),
      );
      if (await photosDirectory.exists()) {
        await photosDirectory.delete(recursive: true);
      }
    } catch (_) {}

    notifyInventoryChanged();
  }

  Future<Map<String, dynamic>> restoreBackupFromFile(
    String filePath,
  ) async {
    final raw = await File(filePath).readAsString();
    final decoded = jsonDecode(raw);

    if (decoded is! Map) {
      throw Exception('Файл резервной копии имеет неверный формат');
    }

    final backupData = Map<String, dynamic>.from(decoded);

    if ((backupData['backup_version'] as num?)?.toInt() != 1) {
      throw Exception('Неподдерживаемая версия резервной копии');
    }

    final response = await Supabase.instance.client.rpc(
      'restore_shop_backup',
      params: {'p_backup': backupData},
    );

    if (response is! Map) {
      throw Exception('Сервер не подтвердил восстановление');
    }

    final database = db!;
    await database.transaction((txn) async {
      await txn.delete('receipt_items');
      await txn.delete('operations');
      await txn.delete('receipts');
      await txn.delete('purchase_photos');
      await txn.delete('purchase_reports');
      await txn.delete('shifts');
      await txn.delete('products');

      await txn.rawDelete(
        "DELETE FROM sqlite_sequence WHERE name IN "
        "('receipt_items', 'receipts', 'operations', "
        "'purchase_photos', 'purchase_reports', 'shifts', 'products')",
      );
    });

    await serverProducts();
    notifyInventoryChanged();

    return backupData;
  }

  Future<String?> backup() async {
    final client = Supabase.instance.client;
    final authUser = client.auth.currentUser;

    if (authUser == null) {
      throw Exception('Пользователь не авторизован');
    }

    final profile = await client
        .from('users')
        .select('role, active')
        .eq('auth_user_id', authUser.id)
        .maybeSingle();

    if (profile == null ||
        profile['role'] != 'admin' ||
        profile['active'] != true) {
      throw Exception(
        'Только активный администратор может создавать резервную копию',
      );
    }

    final response = await client.rpc('create_shop_backup');

    if (response is! Map) {
      throw Exception('Сервер вернул некорректную резервную копию');
    }

    final backupData = Map<String, dynamic>.from(response);

    final now = DateTime.now();
    final stamp =
        '${now.year.toString().padLeft(4, '0')}'
        '${now.month.toString().padLeft(2, '0')}_'
        '${now.day.toString().padLeft(2, '0')}_'
        '${now.hour.toString().padLeft(2, '0')}'
        '${now.minute.toString().padLeft(2, '0')}_'
        '${now.second.toString().padLeft(2, '0')}';

    final fileName = 'shop_backup_$stamp.json';
    final jsonText = const JsonEncoder.withIndent('  ').convert(backupData);

    // Сохраняем через системное окно Android/iOS, чтобы файл
    // находился в обычном доступном пользователю месте.
    final savedPath = await FilePicker.platform.saveFile(
      dialogTitle: 'Сохранить резервную копию',
      fileName: fileName,
      type: FileType.custom,
      allowedExtensions: ['json'],
      bytes: Uint8List.fromList(utf8.encode(jsonText)),
    );

    return savedPath;
  }
}

class CartItem {
  final int id;
  final String code;
  final String name;
  final double price;
  final double buy;
  int qty;

  CartItem({
    required this.id,
    required this.code,
    required this.name,
    required this.price,
    required this.buy,
    this.qty = 1,
  });

  double get total => price * qty;
}

class App extends StatefulWidget {
  const App({super.key});

  @override
  State<App> createState() => _AppState();
}

class _AppState extends State<App> {
  Map<String, dynamic>? user;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: primary,
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: background,
        cardTheme: CardThemeData(
          color: cardColor,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xff171820),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: const BorderSide(
              color: Colors.white38,
            ),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: const BorderSide(
              color: primary,
              width: 2,
            ),
          ),
        ),
      ),
      home: user == null
          ? Login(
              onLogin: (value) {
                setState(() => user = value);
              },
            )
          : Shell(
              user: user!,
              logout: () {
                setState(() => user = null);
              },
            ),
    );
  }
}

class Login extends StatefulWidget {
  final ValueChanged<Map<String, dynamic>> onLogin;

  const Login({
    super.key,
    required this.onLogin,
  });

  @override
  State<Login> createState() => _LoginState();
}

class _LoginState extends State<Login> {
  final usernameController =
      TextEditingController(text: 'admin');
  final passwordController =
      TextEditingController(text: 'admin123');

  bool busy = false;

  @override
  void dispose() {
    usernameController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  Future<void> login() async {
    setState(() => busy = true);

    final result = await DB.i.login(
      usernameController.text,
      passwordController.text,
    );

    if (!mounted) return;

    setState(() => busy = false);

    if (result == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Неверный логин или пароль'),
        ),
      );
      return;
    }

    widget.onLogin(result);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: Column(
            children: [
              const Icon(
                Icons.storefront_rounded,
                size: 76,
                color: primary,
              ),
              const SizedBox(height: 20),
              const Text(
                'SHOP',
                style: TextStyle(
                  fontSize: 38,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const Text(
                'Учет магазина',
                style: TextStyle(
                  color: Colors.white54,
                ),
              ),
              const SizedBox(height: 40),
              TextField(
                controller: usernameController,
                 keyboardType: TextInputType.emailAddress,
                 decoration: const InputDecoration(
                   labelText: 'Email',
                   hintText: 'Введите email',
                   prefixIcon: Icon(Icons.email),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: passwordController,
                obscureText: true,
                onSubmitted: (_) => login(),
                decoration: const InputDecoration(
                  labelText: 'Пароль',
                  prefixIcon: Icon(Icons.lock),
                ),
              ),
              const SizedBox(height: 20),
              FilledButton(
  onPressed: busy ? null : login,
  style: FilledButton.styleFrom(
    minimumSize: const Size.fromHeight(54),
  ),
  child: busy
      ? const SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(),
        )
      : const Text('Войти'),
),
const SizedBox(height: 14),
const Text(
  'Вход через сервер',
  style: TextStyle(
    color: Colors.white38,
  ),
),
            ],
          ),
        ),
      ),
    );
  }
}

class Shell extends StatefulWidget {
  final Map<String, dynamic> user;
  final VoidCallback logout;

  const Shell({
    super.key,
    required this.user,
    required this.logout,
  });

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> with WidgetsBindingObserver {
  int index = 0;
  late Map<String, dynamic> currentUser;
  bool refreshingPermissions = false;

  @override
  void initState() {
    super.initState();
    currentUser = Map<String, dynamic>.from(widget.user);
    WidgetsBinding.instance.addObserver(this);
    _refreshPermissions();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshPermissions();
    }
  }

  Future<void> _refreshPermissions() async {
    if (refreshingPermissions) return;

    final authUser = Supabase.instance.client.auth.currentUser;
    if (authUser == null) return;

    refreshingPermissions = true;
    try {
      final profile = await Supabase.instance.client
          .from('users')
          .select()
          .eq('auth_user_id', authUser.id)
          .eq('active', true)
          .maybeSingle();

      if (!mounted || profile == null) return;

      setState(() {
        currentUser = Map<String, dynamic>.from(profile);
      });
    } catch (e) {
      print('PERMISSIONS REFRESH ERROR: $e');
    } finally {
      refreshingPermissions = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      Home(user: currentUser),
      Products(user: currentUser),
      Sale(user: currentUser),
      Stats(user: currentUser),
      More(
        user: currentUser,
        logout: widget.logout,
        onRefreshPermissions: _refreshPermissions,
      ),
    ];

    return Scaffold(
      body: IndexedStack(
        index: index,
        children: pages,
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (value) {
          setState(() => index = value);
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'Главная',
          ),
          NavigationDestination(
            icon: Icon(Icons.inventory_2_outlined),
            selectedIcon: Icon(Icons.inventory_2),
            label: 'Товары',
          ),
          NavigationDestination(
            icon: Icon(Icons.shopping_cart_outlined),
            selectedIcon: Icon(Icons.shopping_cart),
            label: 'Продажа',
          ),
          NavigationDestination(
            icon: Icon(Icons.bar_chart_outlined),
            selectedIcon: Icon(Icons.bar_chart),
            label: 'Статистика',
          ),
          NavigationDestination(
            icon: Icon(Icons.more_horiz),
            selectedIcon: Icon(Icons.more_horiz),
            label: 'Ещё',
          ),
        ],
      ),
    );
  }
}

class Home extends StatefulWidget {
  final Map<String, dynamic> user;

  const Home({
    super.key,
    required this.user,
  });

  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  Map<String, num> statistics = {};
  int productsCount = 0;
  int stockCount = 0;

  @override
  void initState() {
    super.initState();
    inventoryVersion.addListener(_inventoryChanged);
    load();
  }

  void _inventoryChanged() {
    if (!mounted) return;
    load();
  }

  @override
  void dispose() {
    inventoryVersion.removeListener(_inventoryChanged);
    super.dispose();
  }

  Future<void> load() async {
    final products = await DB.i.products();
    final statistics = await DB.i.stats(
      widget.user['role'] == 'admin'
          ? ''
          : widget.user['username'].toString(),
    );

    if (!mounted) return;

    setState(() {
      this.statistics = statistics;
      productsCount = products.length;
      stockCount = products.fold<int>(
        0,
        (sum, item) =>
            sum + (item['quantity'] as num).toInt(),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Скрыть клавиатуру',
          onPressed: () => FocusManager.instance.primaryFocus?.unfocus(),
          icon: const Icon(Icons.keyboard_hide),
        ),
        title: const Text(
          'Главная',
          style: TextStyle(
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 30),
          children: [
            Text(
              'Привет, ${widget.user['full_name']} 👋',
              style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              widget.user['role'] == 'admin'
                  ? 'Администратор'
                  : 'Продавец',
              style: const TextStyle(
                color: Colors.white54,
              ),
            ),
            const SizedBox(height: 24),
            StatCard(
              title: 'Выручка',
              value: money(statistics['revenue'] ?? 0),
              icon: Icons.payments,
            ),
            if (hasPermission(widget.user, 'profit'))
              StatCard(
                title: 'Прибыль',
                value: money(statistics['profit'] ?? 0),
                icon: Icons.trending_up,
              ),
            StatCard(
              title: 'Продано',
              value:
                  '${(statistics['sold'] ?? 0).toInt()} шт.',
              icon: Icons.shopping_bag,
            ),
            StatCard(
              title: 'Брак',
              value:
                  '${(statistics['defects'] ?? 0).toInt()} шт.',
              icon: Icons.delete_outline,
            ),
            Card(
              child: ListTile(
                leading: const CircleAvatar(
                  backgroundColor: Color(0xff4f3b86),
                  child: Icon(Icons.inventory_2),
                ),
                title: Text('$productsCount товаров'),
                subtitle: const Text('Количество позиций'),
                trailing: Text(
                  '$stockCount шт.',
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class StatCard extends StatelessWidget {
  final String title;
  final String value;
  final IconData icon;

  const StatCard({
    super.key,
    required this.title,
    required this.value,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            CircleAvatar(
              radius: 29,
              backgroundColor: const Color(0xff4f3b86),
              child: Icon(
                icon,
                color: Colors.white,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: Colors.white60,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    value,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class Products extends StatefulWidget {
  final Map<String, dynamic> user;

  const Products({
    super.key,
    required this.user,
  });

  @override
  State<Products> createState() => _ProductsState();
}

class _ProductsState extends State<Products> {
  final searchController = TextEditingController();
  List<Map<String, dynamic>> items = [];

  @override
  void initState() {
    super.initState();
    inventoryVersion.addListener(_inventoryChanged);
    load();
  }

  void _inventoryChanged() {
    if (!mounted) return;
    load();
  }

  @override
  void dispose() {
    inventoryVersion.removeListener(_inventoryChanged);
    searchController.dispose();
    super.dispose();
  }

  Future<void> load() async {
    final query = searchController.text.trim();
    final result = await DB.i.products(query);

    if (!mounted) return;

    // Товары с нулевым остатком не показываем в общем списке.
    // При поиске по названию или штрихкоду они остаются доступны,
    // чтобы администратор мог открыть товар и сделать пополнение.
    final visible = query.isEmpty
        ? result.where((product) {
            final quantity = (product['quantity'] as num?)?.toInt() ?? 0;
            return quantity > 0;
          }).toList()
        : result;

    setState(() => items = visible);
  }

  Future<void> form([Map<String, dynamic>? product]) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => ProductForm(
        product,
        user: widget.user,
      ),
    );

    if (!mounted) return;
    await load();
  }

  @override
  Widget build(BuildContext context) {
    if (!hasPermission(widget.user, 'products_view')) {
      return Scaffold(
        appBar: AppBar(title: const Text('Товары')),
        body: const Center(
          child: Text('У вас нет доступа к товарам.'),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Скрыть клавиатуру',
          onPressed: () => FocusManager.instance.primaryFocus?.unfocus(),
          icon: const Icon(Icons.keyboard_hide),
        ),
        title: const Text(
          'Товары',
          style: TextStyle(
            fontWeight: FontWeight.w900,
          ),
        ),
        actions: [
          if (hasPermission(widget.user, 'products_edit'))
            IconButton(
              onPressed: () => form(),
              icon: const Icon(Icons.add),
            ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: searchController,
              onChanged: (_) => load(),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Название или штрихкод',
              ),
            ),
          ),
          Expanded(
            child: items.isEmpty
                ? const Center(
                    child: Text(
                      'Товары не найдены',
                      style: TextStyle(
                        color: Colors.white54,
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.only(
                      left: 12,
                      right: 12,
                      bottom: 20,
                    ),
                    itemCount: items.length,
                    itemBuilder: (_, index) {
                      final product = items[index];
                      final quantity =
                          (product['quantity'] as num).toInt();
                      final price =
                          (product['price'] as num).toDouble();

                      return Card(
                        child: ListTile(
                          onTap: () => showProductPhotos(context, product),
                          contentPadding:
                              const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 6,
                          ),
                          leading: CircleAvatar(
                            backgroundColor:
                                const Color(0xff4f3b86),
                            child: Icon(
                              quantity == 0
                                  ? Icons.warning_amber
                                  : Icons.inventory_2,
                            ),
                          ),
                          title: Text(
                            product['name'].toString(),
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          subtitle: Text(
                            '${product['barcode']} • '
                            '${money(price)}\n'
                            'Остаток: $quantity шт.',
                          ),
                          isThreeLine: true,
                          trailing: hasPermission(widget.user, 'products_edit')
                              ? TextButton(
                                  onPressed: () =>
                                      form(product),
                                  child:
                                      const Text('Изменить'),
                                )
                              : null,
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}


Future<void> showProductPhotos(
  BuildContext context,
  Map<String, dynamic> product,
) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => ProductPhotosSheet(product: product),
  );
}

class ProductPhotosSheet extends StatefulWidget {
  final Map<String, dynamic> product;

  const ProductPhotosSheet({
    super.key,
    required this.product,
  });

  @override
  State<ProductPhotosSheet> createState() => _ProductPhotosSheetState();
}

class _ProductPhotosSheetState extends State<ProductPhotosSheet> {
  bool loading = true;
  String? error;
  List<String> urls = [];

  @override
  void initState() {
    super.initState();
    loadPhotos();
  }

  Future<void> loadPhotos() async {
    final barcode = widget.product['barcode']?.toString().trim() ?? '';
    if (barcode.isEmpty) {
      if (mounted) {
        setState(() {
          loading = false;
          error = 'У товара нет штрихкода';
        });
      }
      return;
    }

    try {
      final storage = Supabase.instance.client.storage.from('product-photos');
      final files = await storage.list(path: barcode);
      final imageFiles = files
          .where((file) => file.name.isNotEmpty)
          .toList()
        ..sort((a, b) => b.name.compareTo(a.name));

      final signedUrls = <String>[];
      for (final file in imageFiles) {
        final path = '$barcode/${file.name}';
        final url = await storage.createSignedUrl(path, 3600);
        signedUrls.add(url);
      }

      if (!mounted) return;
      setState(() {
        urls = signedUrls;
        loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        loading = false;
        error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.product['name']?.toString() ?? 'Товар';
    final barcode = widget.product['barcode']?.toString() ?? '';

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.photo_library_outlined),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    name,
                    style: const TextStyle(
                      fontSize: 21,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            Text(
              'Штрихкод: $barcode',
              style: const TextStyle(color: Colors.white60),
            ),
            const SizedBox(height: 16),
            if (loading)
              const SizedBox(
                height: 180,
                child: Center(child: CircularProgressIndicator()),
              )
            else if (error != null)
              SizedBox(
                height: 180,
                child: Center(
                  child: Text(
                    'Не удалось загрузить фото.\n$error',
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            else if (urls.isEmpty)
              const SizedBox(
                height: 180,
                child: Center(
                  child: Text(
                    'Фотографий у товара пока нет.',
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            else
              SizedBox(
                height: 330,
                child: PageView.builder(
                  itemCount: urls.length,
                  itemBuilder: (_, index) => Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(18),
                      child: InteractiveViewer(
                        minScale: 0.8,
                        maxScale: 4,
                        child: Image.network(
                          urls[index],
                          fit: BoxFit.contain,
                          loadingBuilder: (context, child, progress) {
                            if (progress == null) return child;
                            return const Center(
                              child: CircularProgressIndicator(),
                            );
                          },
                          errorBuilder: (_, _, _) => const Center(
                            child: Icon(
                              Icons.broken_image_outlined,
                              size: 56,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            if (urls.length > 1) ...[
              const SizedBox(height: 10),
              Center(
                child: Text(
                  'Фотографий: ${urls.length} • листайте влево/вправо',
                  style: const TextStyle(color: Colors.white60),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class ProductForm extends StatefulWidget {
  final Map<String, dynamic>? product;
  final Map<String, dynamic> user;

  const ProductForm(
    this.product, {
    super.key,
    required this.user,
  });

  @override
  State<ProductForm> createState() => _ProductFormState();
}

class _ProductFormState extends State<ProductForm> {
  late final TextEditingController barcode;
  late final TextEditingController name;
  late final TextEditingController buy;
  late final TextEditingController price;
  late final TextEditingController quantity;

  final picker = ImagePicker();
  final photos = <XFile>[];
  bool saving = false;

  @override
  void initState() {
    super.initState();

    barcode = TextEditingController(
      text: widget.product?['barcode']?.toString() ?? '',
    );
    name = TextEditingController(
      text: widget.product?['name']?.toString() ?? '',
    );
    buy = TextEditingController(
      text:
          widget.product?['purchase_price']?.toString() ?? '0',
    );
    price = TextEditingController(
      text: widget.product?['price']?.toString() ?? '0',
    );
    quantity = TextEditingController(
      text: widget.product?['quantity']?.toString() ?? '0',
    );
  }

  @override
  void dispose() {
    barcode.dispose();
    name.dispose();
    buy.dispose();
    price.dispose();
    quantity.dispose();
    super.dispose();
  }

  Future<void> takePhoto() async {
    try {
      final photo = await picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 85,
        maxWidth: 1800,
      );
      if (photo == null || !mounted) return;
      setState(() => photos.add(photo));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось сделать фото: $e')),
      );
    }
  }

  Future<List<String>> uploadPhotosToSupabase(
    String productBarcode,
  ) async {
    if (photos.isEmpty) return [];

    final storage =
        Supabase.instance.client.storage.from('product-photos');
    final uploadedPaths = <String>[];

    for (var i = 0; i < photos.length; i++) {
      final source = File(photos[i].path);
      if (!await source.exists()) {
        throw Exception('Файл фотографии не найден');
      }

      final extension = p.extension(photos[i].path).toLowerCase();
      final safeExtension = extension.isEmpty ? '.jpg' : extension;
      final contentType = safeExtension == '.png'
          ? 'image/png'
          : safeExtension == '.webp'
              ? 'image/webp'
              : 'image/jpeg';

      final path =
          '$productBarcode/${DateTime.now().microsecondsSinceEpoch}_$i$safeExtension';

      await storage.upload(
        path,
        source,
        fileOptions: FileOptions(
          cacheControl: '31536000',
          contentType: contentType,
          upsert: false,
        ),
      );

      uploadedPaths.add(path);
    }

    return uploadedPaths;
  }

  Future<List<String>> savePhotosLocally() async {
    if (photos.isEmpty) return [];

    final directory = await getApplicationDocumentsDirectory();
    final folder = Directory(
      p.join(directory.path, 'purchase_photos'),
    );
    await folder.create(recursive: true);

    final paths = <String>[];

    for (var i = 0; i < photos.length; i++) {
      final source = File(photos[i].path);
      final extension = p.extension(photos[i].path).isEmpty
          ? '.jpg'
          : p.extension(photos[i].path);
      final target = File(
        p.join(
          folder.path,
          'purchase_${DateTime.now().microsecondsSinceEpoch}_$i$extension',
        ),
      );

      await source.copy(target.path);
      paths.add(target.path);
    }

    return paths;
  }

  Future<void> save() async {
    if (saving) return;

    final productName = name.text.trim();
    final productBarcode = barcode.text.trim();

    if (productBarcode.isEmpty || productName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Заполните штрихкод и название',
          ),
        ),
      );
      return;
    }

    final buyPrice =
        double.tryParse(buy.text.replaceAll(',', '.')) ?? 0;
    final salePrice =
        double.tryParse(price.text.replaceAll(',', '.')) ?? 0;
    final stock =
        int.tryParse(quantity.text.trim()) ?? 0;

    if (buyPrice < 0 || salePrice < 0 || stock < 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Цена и количество не могут быть отрицательными',
          ),
        ),
      );
      return;
    }

    setState(() => saving = true);

    try {
      final isNew = widget.product?['id'] == null;
      final data = <String, dynamic>{
        'barcode': productBarcode,
        'name': productName,
        'purchase_price': buyPrice,
        'price': salePrice,
        'quantity': stock,
      };

      if (!isNew) {
        data['id'] = widget.product!['id'];
        data['server_id'] = widget.product!['server_id'];
      }

      await DB.i.saveProduct(data);

      var uploadedPhotoCount = 0;
      if (photos.isNotEmpty) {
        final uploadedPaths = await uploadPhotosToSupabase(productBarcode);
        uploadedPhotoCount = uploadedPaths.length;

        // Локальная копия остаётся для существующей истории закупок.
        if (isNew && stock > 0) {
          final productRow = await DB.i.product(productBarcode);
          if (productRow != null) {
            final localPaths = await savePhotosLocally();
            await DB.i.createPurchaseReport(
              productId: productRow['id'] as int,
              seller: widget.user['username'].toString(),
              quantity: stock,
              purchasePrice: buyPrice,
              photoPaths: localPaths,
            );
          }
        }
      }

      if (!mounted) return;

      if (uploadedPhotoCount > 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              isNew
                  ? 'Товар добавлен. Фото загружено: $uploadedPhotoCount'
                  : 'Товар сохранён. Фото загружено: $uploadedPhotoCount',
            ),
          ),
        );
      }

      Navigator.pop(context);
    } catch (error) {
      if (!mounted) return;

      setState(() => saving = false);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Не удалось сохранить: $error',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.product != null;
    final canAddReceivingPhotos = !editing;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        20,
        20,
        MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              editing
                  ? 'Изменить товар'
                  : 'Новый товар',
              style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: barcode,
              decoration: const InputDecoration(
                labelText: 'Штрихкод',
                prefixIcon: Icon(Icons.qr_code),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: name,
              decoration: const InputDecoration(
                labelText: 'Название',
                prefixIcon: Icon(Icons.inventory_2),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: buy,
              keyboardType:
                  const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: 'Закупочная цена',
                prefixIcon: Icon(Icons.shopping_cart),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: price,
              keyboardType:
                  const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: 'Цена продажи',
                prefixIcon: Icon(Icons.payments),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: quantity,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Количество',
                prefixIcon: Icon(Icons.tag),
              ),
            ),
            if (canAddReceivingPhotos) ...[
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Фото приёмки товара',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                ),
              ),
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Фото сохраняются в защищённое хранилище Supabase и '
                  'привязываются к штрихкоду товара.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: saving ? null : takePhoto,
                icon: const Icon(Icons.camera_alt),
                label: const Text('Сделать фото'),
              ),
              if (photos.isNotEmpty) ...[
                const SizedBox(height: 10),
                SizedBox(
                  height: 110,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: photos.length,
                    separatorBuilder: (_, _) =>
                        const SizedBox(width: 8),
                    itemBuilder: (_, index) => Stack(
                      children: [
                        ClipRRect(
                          borderRadius:
                              BorderRadius.circular(12),
                          child: Image.file(
                            File(photos[index].path),
                            width: 110,
                            height: 110,
                            fit: BoxFit.cover,
                          ),
                        ),
                        Positioned(
                          top: 4,
                          right: 4,
                          child: IconButton.filled(
                            onPressed: saving
                                ? null
                                : () => setState(
                                      () => photos.removeAt(index),
                                    ),
                            icon: const Icon(
                              Icons.close,
                              size: 18,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
            const SizedBox(height: 14),
            FilledButton(
              onPressed: saving ? null : save,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(54),
              ),
              child: Text(
                saving ? 'Сохранение...' : 'Сохранить',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class Sale extends StatefulWidget {
  final Map<String, dynamic> user;

  const Sale({
    super.key,
    required this.user,
  });

  @override
  State<Sale> createState() => _SaleState();
}

class _SaleState extends State<Sale> {
  final barcodeController = TextEditingController();
  final searchController = TextEditingController();
  final discountController =
      TextEditingController(text: '0');

  String paymentMethod = 'Наличные';

  final cart = <CartItem>[];
  List<Map<String, dynamic>> _searchResults = [];

  @override
  void dispose() {
    barcodeController.dispose();
    searchController.dispose();
    discountController.dispose();
    super.dispose();
  }

  Future<void> addProductToCart(Map<String, dynamic> product) async {
    final stock = (product['quantity'] as num).toInt();

    final existing = cart.where(
      (item) => item.id == product['id'],
    );

    if (existing.isNotEmpty) {
      final item = existing.first;

      if (item.qty >= stock) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Нельзя добавить больше товара, чем есть на складе',
            ),
          ),
        );
        return;
      }

      setState(() => item.qty++);
    } else {
      if (stock <= 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Товара нет на складе')),
        );
        return;
      }

      setState(() {
        cart.add(
          CartItem(
            id: product['id'] as int,
            code: product['barcode'].toString(),
            name: product['name'].toString(),
            price: (product['price'] as num).toDouble(),
            buy: (product['purchase_price'] as num?)?.toDouble() ?? 0,
          ),
        );
      });
    }
  }

  Future<void> addByBarcode(String value) async {
    final code = value.trim();
    if (code.isEmpty) return;

    final product = await DB.i.product(code);

    if (!mounted) return;

    if (product == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Товар не найден')),
      );
      return;
    }

    await addProductToCart(product);
    barcodeController.clear();
  }

  Future<void> searchProducts(String value) async {
    final query = value.trim();

    if (query.isEmpty) {
      if (mounted) setState(() {});
      return;
    }

    final results = await DB.i.products(query);

    if (!mounted || searchController.text.trim() != query) return;

    setState(() {
      _searchResults = results;
    });
  }

  Future<void> scan() async {
    final result = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => const Scan(),
      ),
    );

    if (!mounted) return;

    if (result != null && result.isNotEmpty) {
      await addByBarcode(result);
    }
  }

  double get discount {
    return (double.tryParse(
          discountController.text.replaceAll(',', '.'),
        ) ??
        0)
        .clamp(0, 100)
        .toDouble();
  }

  double get subtotal {
    return cart.fold<double>(
      0,
      (sum, item) => sum + item.total,
    );
  }

  double get total {
    return subtotal * (1 - discount / 100);
  }

  Future<void> pay() async {
    if (cart.isEmpty) return;

    final paidTotal = total;

    try {
      final receiptId = await DB.i.sale(
        cart,
        discount,
        widget.user['username'].toString(),
        paymentMethod,
      );

      if (!mounted) return;

      setState(() {
        cart.clear();
        discountController.text = '0';
      });

      await showDialog<void>(
        context: context,
        builder: (dialogContext) {
          return AlertDialog(
            title: Text(
              'Чек №${receiptId.toString().padLeft(6, '0')}',
            ),
            content: Text(
              'Продажа оформлена\n\n'
              'Итого: ${money(paidTotal)}',
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.pop(dialogContext);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ReceiptDetail(
                        receiptId: receiptId,
                      ),
                    ),
                  );
                },
                child: const Text('Открыть чек'),
              ),
              TextButton(
                onPressed: () =>
                    Navigator.pop(dialogContext),
                child: const Text('Готово'),
              ),
            ],
          );
        },
      );
    } catch (error) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$error'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!hasPermission(widget.user, 'sell')) {
      return Scaffold(
        appBar: AppBar(title: const Text('Продажа')),
        body: const Center(
          child: Text('У вас нет права на продажи.'),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Скрыть клавиатуру',
          onPressed: () => FocusManager.instance.primaryFocus?.unfocus(),
          icon: const Icon(Icons.keyboard_hide),
        ),
        title: const Text(
          'Продажа',
          style: TextStyle(
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: searchController,
                    onChanged: searchProducts,
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: 'Найти товар по названию',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: scan,
                  icon: const Icon(
                    Icons.camera_alt,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: barcodeController,
                    onSubmitted: addByBarcode,
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.qr_code),
                      hintText: 'Штрихкод',
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (searchController.text.trim().isNotEmpty)
            Container(
              constraints: const BoxConstraints(maxHeight: 240),
              margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              decoration: BoxDecoration(
                color: cardColor,
                borderRadius: BorderRadius.circular(16),
              ),
              child: _searchResults.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('Товар не найден'),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: _searchResults.length,
                      itemBuilder: (context, index) {
                        final product = _searchResults[index];
                        final stock = (product['quantity'] as num).toInt();
                        return ListTile(
                          leading: const Icon(Icons.inventory_2_outlined),
                          title: Text(product['name'].toString()),
                          subtitle: Text(
                            '${money((product['price'] as num).toDouble())} • Остаток: $stock',
                          ),
                          trailing: const Icon(Icons.add_circle_outline),
                          enabled: stock > 0,
                          onTap: stock <= 0
                              ? null
                              : () async {
                                  await addProductToCart(product);
                                  if (!mounted) return;
                                  searchController.clear();
                                  setState(() => _searchResults = []);
                                },
                        );
                      },
                    ),
            ),
          Expanded(
            child: cart.isEmpty
                ? const Center(
                    child: Text(
                      'Корзина пуста',
                      style: TextStyle(
                        color: Colors.white54,
                      ),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                    ),
                    children: cart.map((item) {
                      return Card(
                        child: ListTile(
                          title: Text(
                            item.name,
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          subtitle: Text(
                            '${money(item.price)} × ${item.qty}',
                          ),
                          trailing: Row(
                            mainAxisSize:
                                MainAxisSize.min,
                            children: [
                              IconButton(
                                onPressed: () {
                                  setState(() {
                                    if (item.qty > 1) {
                                      item.qty--;
                                    }
                                  });
                                },
                                icon: const Icon(
                                  Icons.remove,
                                ),
                              ),
                              Text(
                                '${item.qty}',
                                style: const TextStyle(
                                  fontWeight:
                                      FontWeight.w800,
                                ),
                              ),
                              IconButton(
                                onPressed: () async {
                                  final product =
                                      await DB.i.product(
                                    item.code,
                                  );

                                  if (!context.mounted) return;

                                  final stock =
                                      product == null
                                          ? 0
                                          : (product['quantity']
                                                  as num)
                                              .toInt();

                                  if (item.qty >= stock) {
                                    ScaffoldMessenger.of(
                                      context,
                                    ).showSnackBar(
                                      const SnackBar(
                                        content: Text(
                                          'Достигнут остаток товара',
                                        ),
                                      ),
                                    );
                                    return;
                                  }

                                  setState(
                                    () => item.qty++,
                                  );
                                },
                                icon: const Icon(
                                  Icons.add,
                                ),
                              ),
                              IconButton(
                                onPressed: () {
                                  setState(
                                    () => cart.remove(
                                      item,
                                    ),
                                  );
                                },
                                icon: const Icon(
                                  Icons.delete_outline,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }).toList(),
                  ),
          ),
          Card(
            margin: const EdgeInsets.all(12),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment:
                        MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Скидка'),
                      SizedBox(
                        width: 100,
                        child: TextField(
                          controller:
                              discountController,
                          onChanged: (_) =>
                              setState(() {}),
                          keyboardType:
                              const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration:
                              const InputDecoration(
                            suffixText: '%',
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Способ оплаты',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  const SizedBox(height: 6),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(
                        value: 'Наличные',
                        label: Text('Наличные'),
                        icon: Icon(Icons.payments_outlined),
                      ),
                      ButtonSegment(
                        value: 'Карта',
                        label: Text('Карта'),
                        icon: Icon(Icons.credit_card),
                      ),
                      ButtonSegment(
                        value: 'Перевод',
                        label: Text('Перевод'),
                        icon: Icon(Icons.account_balance),
                      ),
                    ],
                    selected: {paymentMethod},
                    onSelectionChanged: (value) {
                      setState(() => paymentMethod = value.first);
                    },
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment:
                        MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'ИТОГО',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      Text(
                        money(total),
                        style: const TextStyle(
                          fontSize: 23,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  FilledButton(
                    onPressed:
                        cart.isEmpty ? null : pay,
                    style: FilledButton.styleFrom(
                      minimumSize:
                          const Size.fromHeight(52),
                    ),
                    child: const Text(
                      'Оформить продажу',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class Scan extends StatefulWidget {
  const Scan({super.key});

  @override
  State<Scan> createState() => _ScanState();
}

class _ScanState extends State<Scan> {
  bool completed = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Сканирование'),
      ),
      body: MobileScanner(
        onDetect: (capture) {
          if (completed) return;

          final value = capture.barcodes.isEmpty
              ? null
              : capture.barcodes.first.rawValue;

          if (value == null || value.isEmpty) return;

          completed = true;

          if (mounted) {
            Navigator.pop(context, value);
          }
        },
      ),
    );
  }
}

class Stats extends StatefulWidget {
  final Map<String, dynamic> user;

  const Stats({
    super.key,
    required this.user,
  });

  @override
  State<Stats> createState() => _StatsState();
}

class _StatsState extends State<Stats> {
  Map<String, num> statistics = {};
  List<Map<String, dynamic>> sellerStatistics = [];
  String period = 'all';
  bool loading = true;

  final Map<String, String> periodLabels = const {
    'today': 'Сегодня',
    'week': '7 дней',
    'month': 'Месяц',
    'all': 'Всё время',
  };

  @override
  void initState() {
    super.initState();
    inventoryVersion.addListener(_inventoryChanged);
    load();
  }

  void _inventoryChanged() {
    if (mounted) load();
  }

  @override
  void dispose() {
    inventoryVersion.removeListener(_inventoryChanged);
    super.dispose();
  }

  Future<void> load() async {
    if (mounted) {
      setState(() => loading = true);
    }

    final sellerFilter = widget.user['role'] == 'admin'
        ? ''
        : widget.user['username'].toString();

    final result = await DB.i.stats(sellerFilter, period);
    final allSellers = await DB.i.sellerStats(period);

    final sellers = widget.user['role'] == 'admin'
        ? allSellers
        : allSellers
            .where(
              (row) =>
                  row['seller']?.toString() ==
                  widget.user['username']?.toString(),
            )
            .toList();

    if (!mounted) return;

    setState(() {
      statistics = result;
      sellerStatistics = sellers;
      loading = false;
    });
  }

  Future<void> changePeriod(String value) async {
    setState(() => period = value);
    await load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Скрыть клавиатуру',
          onPressed: () => FocusManager.instance.primaryFocus?.unfocus(),
          icon: const Icon(Icons.keyboard_hide),
        ),
        title: const Text('Статистика'),
      ),
      body: RefreshIndicator(
        onRefresh: load,
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            if (!hasPermission(widget.user, 'stats'))
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(20),
                  child: Text(
                    'У вас нет доступа к статистике.',
                    style: TextStyle(fontSize: 18),
                  ),
                ),
              )
            else ...[
            if (loading)
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: LinearProgressIndicator(),
              ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: periodLabels.entries.map((entry) {
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(entry.value),
                      selected: period == entry.key,
                      onSelected: (_) => changePeriod(entry.key),
                    ),
                  );
                }).toList(),
              ),
            ),
            const SizedBox(height: 12),
            StatCard(
              title: 'Выручка',
              value: money(statistics['revenue'] ?? 0),
              icon: Icons.payments,
            ),
            if (hasPermission(widget.user, 'profit'))
              StatCard(
                title: 'Прибыль',
                value: money(statistics['profit'] ?? 0),
                icon: Icons.trending_up,
              ),
            StatCard(
              title: 'Продано',
              value: '${(statistics['sold'] ?? 0).toInt()} шт.',
              icon: Icons.shopping_bag,
            ),
            StatCard(
              title: 'Возвраты',
              value: money(statistics['returns'] ?? 0),
              icon: Icons.undo,
            ),
            StatCard(
              title: 'Брак',
              value: '${(statistics['defects'] ?? 0).toInt()} шт.',
              icon: Icons.delete_outline,
            ),
            const SizedBox(height: 12),
            const Text(
              'Продажи по дням',
              style: TextStyle(fontSize: 21, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 8),
            FutureBuilder<List<Map<String, dynamic>>>(
              future: DB.i.dailySales(
                widget.user['role'] == 'admin'
                    ? ''
                    : widget.user['username'].toString(),
              ),
              builder: (context, snapshot) {
                if (!snapshot.hasData) return const LinearProgressIndicator();
                final rows = snapshot.data!;
                if (rows.isEmpty) return const Card(child: Padding(padding: EdgeInsets.all(16), child: Text('Продаж пока нет')));
                return Column(
                  children: rows.take(31).map((row) => Card(
                    child: ListTile(
                      title: Text(row['day'].toString(), style: const TextStyle(fontWeight: FontWeight.w800)),
                      subtitle: Text('Продаж: ${row['sales']} • Товаров: ${row['sold']}'),
                      trailing: Text(money((row['revenue'] as num?)?.toDouble() ?? 0)),
                    ),
                  )).toList(),
                );
              },
            ),
            if (widget.user['role'] == 'admin') ...[
              const SizedBox(height: 12),
              const Text(
                'Продажи по продавцам',
                style: TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 8),
              if (sellerStatistics.isEmpty)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(
                      'За период продаж нет',
                      style: TextStyle(color: Colors.white54),
                    ),
                  ),
                )
              else
                ...sellerStatistics.map(
                  (row) => _SellerStatCard(
                    row: row,
                    canSeeProfit: hasPermission(widget.user, 'profit'),
                  ),
                ),
            ],
            ],
          ],
        ),
      ),
    );
  }
}

class _SellerStatCard extends StatelessWidget {
  final Map<String, dynamic> row;
  final bool canSeeProfit;

  const _SellerStatCard({
    required this.row,
    required this.canSeeProfit,
  });

  @override
  Widget build(BuildContext context) {
    final seller = row['seller']?.toString() ?? 'Неизвестно';
    final sales = (row['sales'] as num?)?.toInt() ?? 0;
    final sold = (row['sold'] as num?)?.toInt() ?? 0;
    final revenue = (row['revenue'] as num?)?.toDouble() ?? 0;
    final profit = (row['profit'] as num?)?.toDouble() ?? 0;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const CircleAvatar(
                  child: Icon(Icons.person),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    seller,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: _MiniStat(
                    label: 'Продаж',
                    value: '$sales',
                  ),
                ),
                Expanded(
                  child: _MiniStat(
                    label: 'Товаров',
                    value: '$sold шт.',
                  ),
                ),
              ],
            ),
            const Divider(height: 24),
            Row(
              children: [
                Expanded(
                  child: _MiniStat(
                    label: 'Выручка',
                    value: money(revenue),
                  ),
                ),
                if (canSeeProfit)
                  Expanded(
                    child: _MiniStat(
                      label: 'Прибыль',
                      value: money(profit),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  final String label;
  final String value;

  const _MiniStat({
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: Colors.white54,
            fontSize: 13,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
  }
}

class More extends StatelessWidget {
  final Map<String, dynamic> user;
  final VoidCallback logout;
  final Future<void> Function()? onRefreshPermissions;

  const More({
    super.key,
    required this.user,
    required this.logout,
    this.onRefreshPermissions,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Скрыть клавиатуру',
          onPressed: () => FocusManager.instance.primaryFocus?.unfocus(),
          icon: const Icon(Icons.keyboard_hide),
        ),
        title: const Text('Ещё'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Card(
            child: ListTile(
              leading: const CircleAvatar(
                child: Icon(Icons.person),
              ),
              title: Text(
                user['full_name'].toString(),
              ),
              subtitle: Text(
                '@${user['username']}',
              ),
            ),
          ),
          if (onRefreshPermissions != null)
            MoreAction(
              title: 'Обновить права доступа',
              icon: Icons.sync,
              onTap: () async {
                await onRefreshPermissions!();
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Права доступа обновлены'),
                  ),
                );
              },
            ),
          if (hasPermission(user, 'shift'))
            MoreAction(
              title: 'Кассовая смена',
            icon: Icons.point_of_sale,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ShiftPage(user: user),
                ),
              );
            },
          ),
          if (hasPermission(user, 'history'))
            MoreAction(
              title: 'История операций',
            icon: Icons.receipt_long,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => History(user: user),
                ),
              );
            },
          ),
          if (hasPermission(user, 'receipts'))
            MoreAction(
              title: 'Чеки',
            icon: Icons.receipt,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => Receipts(user: user),
                ),
              );
            },
          ),
          if (hasPermission(user, 'purchases'))
            MoreAction(
              title: 'Дополнительная закупка',
              icon: Icons.add_box,
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => PurchasePage(user: user),
                  ),
                );
              },
            ),
          if (hasPermission(user, 'product_history'))
            MoreAction(
              title: 'История товара',
              icon: Icons.history,
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ProductHistoryPage(user: user),
                  ),
                );
              },
            ),
          if (hasPermission(user, 'returns'))
            MoreAction(
              title: 'Возврат',
            icon: Icons.undo,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => StockPage(
                    user: user,
                    type: 'Возврат',
                  ),
                ),
              );
            },
          ),
          if (hasPermission(user, 'defects'))
            MoreAction(
              title: 'Списать брак',
            icon: Icons.delete_outline,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => StockPage(
                    user: user,
                    type: 'Брак',
                  ),
                ),
              );
            },
          ),
          if (user['role'] == 'admin')
            MoreAction(
              title: 'Продавцы',
              icon: Icons.manage_accounts,
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const Users(),
                  ),
                );
              },
            ),
          if (hasPermission(user, 'backup'))
            MoreAction(
              title: 'Восстановить из резервной копии',
              icon: Icons.restore,
              onTap: () async {
                try {
                  final result = await FilePicker.platform.pickFiles(
                    type: FileType.custom,
                    allowedExtensions: ['json'],
                    withData: false,
                  );

                  if (result == null || result.files.isEmpty) return;

                  final path = result.files.single.path;
                  if (path == null || path.isEmpty) {
                    throw Exception('Не удалось получить путь к файлу');
                  }

                  final raw = await File(path).readAsString();
                  final decoded = jsonDecode(raw);

                  if (decoded is! Map) {
                    throw Exception(
                      'Файл резервной копии имеет неверный формат',
                    );
                  }

                  final backupData = Map<String, dynamic>.from(decoded);

                  if ((backupData['backup_version'] as num?)?.toInt() != 1) {
                    throw Exception(
                      'Неподдерживаемая версия резервной копии',
                    );
                  }

                  final products = backupData['products'] is List
                      ? (backupData['products'] as List).length
                      : 0;
                  final receipts = backupData['receipts'] is List
                      ? (backupData['receipts'] as List).length
                      : 0;
                  final operations = backupData['operations'] is List
                      ? (backupData['operations'] as List).length
                      : 0;

                  if (!context.mounted) return;

                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (dialogContext) {
                      return AlertDialog(
                        title: const Text('Восстановить резервную копию?'),
                        content: Text(
                          'В копии найдено:\n\n'
                          'Товаров: $products\n'
                          'Чеков: $receipts\n'
                          'Операций: $operations\n\n'
                          'Текущие рабочие данные на сервере будут '
                          'заменены данными из этой копии.\n\n'
                          'Пользователи и их аккаунты не изменятся.',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () =>
                                Navigator.pop(dialogContext, false),
                            child: const Text('Отмена'),
                          ),
                          FilledButton(
                            onPressed: () =>
                                Navigator.pop(dialogContext, true),
                            child: const Text('Восстановить'),
                          ),
                        ],
                      );
                    },
                  );

                  if (confirmed != true || !context.mounted) return;

                  await DB.i.restoreBackupFromFile(path);

                  if (!context.mounted) return;

                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'Резервная копия успешно восстановлена',
                      ),
                    ),
                  );
                } catch (error) {
                  if (!context.mounted) return;

                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        'Не удалось восстановить копию: $error',
                      ),
                    ),
                  );
                }
              },
            ),
          if (hasPermission(user, 'backup'))
            MoreAction(
              title: 'Резервная копия',
              icon: Icons.backup,
              onTap: () async {
                try {
                  final savedPath = await DB.i.backup();

                  if (!context.mounted) return;
                  if (savedPath == null || savedPath.isEmpty) return;

                  ScaffoldMessenger.of(context)
                      .showSnackBar(
                    SnackBar(
                      content: Text(
                        'Резервная копия сохранена: ${p.basename(savedPath)}',
                      ),
                    ),
                  );
                } catch (error) {
                  if (!context.mounted) return;

                  ScaffoldMessenger.of(context)
                      .showSnackBar(
                    SnackBar(
                      content: Text(
                        'Не удалось создать резервную копию: $error',
                      ),
                    ),
                  );
                }
              },
            ),
          if (user['role'] == 'admin')
            MoreAction(
              title: 'Очистить все рабочие данные',
              icon: Icons.delete_forever,
              onTap: () async {
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (dialogContext) => AlertDialog(
                    title: const Text('Очистить все данные?'),
                    content: const Text(
                      'Будут удалены товары, продажи, чеки, операции, '
                      'закупки, фотографии и смены. Пользователи и аккаунт '
                      'администратора останутся. Это действие нельзя отменить.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(dialogContext, false),
                        child: const Text('Отмена'),
                      ),
                      FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.red,
                        ),
                        onPressed: () => Navigator.pop(dialogContext, true),
                        child: const Text('Продолжить'),
                      ),
                    ],
                  ),
                );

                if (confirmed != true || !context.mounted) return;

                final keywordController = TextEditingController();
                final finalConfirmed = await showDialog<bool>(
                  context: context,
                  builder: (dialogContext) => AlertDialog(
                    title: const Text('Последнее подтверждение'),
                    content: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('Для подтверждения введите: УДАЛИТЬ'),
                        const SizedBox(height: 12),
                        TextField(
                          controller: keywordController,
                          autofocus: true,
                          decoration: const InputDecoration(
                            labelText: 'Подтверждение',
                          ),
                        ),
                      ],
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(dialogContext, false),
                        child: const Text('Отмена'),
                      ),
                      FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.red,
                        ),
                        onPressed: () {
                          if (keywordController.text.trim() == 'УДАЛИТЬ') {
                            Navigator.pop(dialogContext, true);
                          }
                        },
                        child: const Text('Удалить'),
                      ),
                    ],
                  ),
                );
                keywordController.dispose();

                if (finalConfirmed != true || !context.mounted) return;

                try {
                  await DB.i.clearAllData();

                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'Все рабочие данные очищены. Пользователи сохранены.',
                      ),
                    ),
                  );
                } catch (error) {
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Не удалось очистить данные: $error'),
                    ),
                  );
                }
              },
            ),
          const SizedBox(height: 20),
          OutlinedButton.icon(
            onPressed: logout,
            icon: const Icon(Icons.logout),
            label: const Text('Выйти'),
          ),
        ],
      ),
    );
  }
}

class ShiftPage extends StatefulWidget {
  final Map<String, dynamic> user;

  const ShiftPage({super.key, required this.user});

  @override
  State<ShiftPage> createState() => _ShiftPageState();
}

class _ShiftPageState extends State<ShiftPage> {
  Map<String, dynamic>? shift;
  Map<String, num> totals = {};
  bool loading = true;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    if (mounted) setState(() => loading = true);
    final current = await DB.i.currentShift();
    final currentTotals = current == null
        ? <String, num>{}
        : await DB.i.shiftTotals((current['id'] as num).toInt());

    if (!mounted) return;
    setState(() {
      shift = current;
      totals = currentTotals;
      loading = false;
    });
  }

  Future<double?> askCash(String title) async {
    final controller = TextEditingController(text: '0');
    final result = await showDialog<double>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            labelText: 'Сумма',
            suffixText: '₽',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () {
              final value = double.tryParse(
                controller.text.replaceAll(',', '.'),
              );
              if (value != null && value >= 0) {
                Navigator.pop(dialogContext, value);
              }
            },
            child: const Text('Продолжить'),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  Future<void> open() async {
    final cash = await askCash('Открыть смену');
    if (cash == null) return;
    try {
      await DB.i.openShift(
        widget.user['username'].toString(),
        cash,
      );
      await load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Смена открыта')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e')),
      );
    }
  }

  Future<void> close() async {
    final current = shift;
    if (current == null) return;

    final opening =
        (current['opening_cash'] as num?)?.toDouble() ?? 0;
    final sales = totals['sales']?.toDouble() ?? 0;
    final returns = totals['returns']?.toDouble() ?? 0;
    final expected = opening + sales - returns;

    final cash = await askCash(
      'Закрыть смену\nОжидаемая касса: ${money(expected)}',
    );
    if (cash == null) return;

    try {
      await DB.i.closeShift(
        (current['id'] as num).toInt(),
        widget.user['username'].toString(),
        cash,
      );
      await load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Смена закрыта')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!hasPermission(widget.user, 'shift')) {
      return Scaffold(
        appBar: AppBar(title: const Text('Кассовая смена')),
        body: const Center(
          child: Text('У вас нет права на кассовую смену.'),
        ),
      );
    }

    if (loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Кассовая смена')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final current = shift;
    final opening =
        (current?['opening_cash'] as num?)?.toDouble() ?? 0;
    final sales = totals['sales']?.toDouble() ?? 0;
    final returns = totals['returns']?.toDouble() ?? 0;
    final sold = totals['sold']?.toInt() ?? 0;
    final expected = opening + sales - returns;

    return Scaffold(
      appBar: AppBar(title: const Text('Кассовая смена')),
      body: RefreshIndicator(
        onRefresh: load,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    Icon(
                      current == null
                          ? Icons.lock_outline
                          : Icons.lock_open,
                      size: 56,
                      color: primary,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      current == null ? 'Смена закрыта' : 'Смена открыта',
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    if (current != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        'Открыл: ${current['opened_by']}',
                        style: const TextStyle(color: Colors.white54),
                      ),
                      Text(
                        formatDateTime(current['opened_at']),
                        style: const TextStyle(color: Colors.white54),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (current == null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: FilledButton.icon(
                  onPressed: open,
                  icon: const Icon(Icons.lock_open),
                  label: const Text('Открыть смену'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(54),
                  ),
                ),
              )
            else ...[
              const SizedBox(height: 12),
              StatCard(
                title: 'Начальная касса',
                value: money(opening),
                icon: Icons.account_balance_wallet,
              ),
              StatCard(
                title: 'Продажи',
                value: money(sales),
                icon: Icons.payments,
              ),
              StatCard(
                title: 'Возвраты',
                value: money(returns),
                icon: Icons.undo,
              ),
              StatCard(
                title: 'Ожидаемая касса',
                value: money(expected),
                icon: Icons.calculate,
              ),
              StatCard(
                title: 'Продано',
                value: '$sold шт.',
                icon: Icons.shopping_bag,
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: close,
                icon: const Icon(Icons.lock),
                label: const Text('Закрыть смену'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(54),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class MoreAction extends StatelessWidget {
  final String title;
  final IconData icon;
  final VoidCallback onTap;

  const MoreAction({
    super.key,
    required this.title,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        onTap: onTap,
        leading: Icon(
          icon,
          color: primary,
        ),
        title: Text(title),
        trailing: const Icon(
          Icons.chevron_right,
        ),
      ),
    );
  }
}


class Receipts extends StatefulWidget {
  final Map<String, dynamic> user;

  const Receipts({
    super.key,
    required this.user,
  });

  @override
  State<Receipts> createState() => _ReceiptsState();
}

class _ReceiptsState extends State<Receipts> {
  DateTime? from;
  DateTime? to;
  String paymentMethod = '';
  late Future<List<Map<String, dynamic>>> future;

  String get seller => widget.user['role'] == 'admin'
      ? ''
      : widget.user['username'].toString();

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    future = DB.i.receipts(
      seller,
      from: from,
      to: to,
      paymentMethod: paymentMethod,
    );
  }

  Future<void> refresh() async {
    setState(_reload);
    await future;
  }

  Future<void> pickFrom() async {
    final value = await showDatePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
      initialDate: from ?? DateTime.now(),
    );
    if (value == null) return;
    setState(() {
      from = value;
      if (to != null && to!.isBefore(value)) to = value;
      _reload();
    });
  }

  Future<void> pickTo() async {
    final value = await showDatePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
      initialDate: to ?? DateTime.now(),
    );
    if (value == null) return;
    setState(() {
      to = value;
      if (from != null && from!.isAfter(value)) from = value;
      _reload();
    });
  }

  String dateLabel(DateTime? value) {
    if (value == null) return 'Дата';
    return '${value.day.toString().padLeft(2, '0')}.${value.month.toString().padLeft(2, '0')}.${value.year}';
  }

  String receiptNumber(int id) => '#${id.toString().padLeft(6, '0')}';

  @override
  Widget build(BuildContext context) {
    if (!hasPermission(widget.user, 'receipts')) {
      return Scaffold(
        appBar: AppBar(title: const Text('Чеки')),
        body: const Center(child: Text('У вас нет доступа к чекам.')),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Чеки')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: pickFrom,
                        icon: const Icon(Icons.calendar_today),
                        label: Text('От: ${dateLabel(from)}'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: pickTo,
                        icon: const Icon(Icons.calendar_today),
                        label: Text('До: ${dateLabel(to)}'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: '', label: Text('Все')),
                      ButtonSegment(value: 'Наличные', label: Text('Наличные')),
                      ButtonSegment(value: 'Карта', label: Text('Карта')),
                      ButtonSegment(value: 'Перевод', label: Text('Перевод')),
                    ],
                    selected: {paymentMethod},
                    onSelectionChanged: (value) {
                      setState(() {
                        paymentMethod = value.first;
                        _reload();
                      });
                    },
                  ),
                ),
                if (from != null || to != null || paymentMethod.isNotEmpty)
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: () {
                        setState(() {
                          from = null;
                          to = null;
                          paymentMethod = '';
                          _reload();
                        });
                      },
                      icon: const Icon(Icons.clear),
                      label: const Text('Сбросить фильтры'),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: FutureBuilder<List<Map<String, dynamic>>>(
              future: future,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return Center(child: Text('Ошибка: ${snapshot.error}'));
                }
                final items = snapshot.data ?? [];
                if (items.isEmpty) {
                  return RefreshIndicator(
                    onRefresh: refresh,
                    child: ListView(
                      children: const [
                        SizedBox(height: 160),
                        Center(child: Text('Чеков по выбранным фильтрам нет')),
                      ],
                    ),
                  );
                }
                return RefreshIndicator(
                  onRefresh: refresh,
                  child: ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: items.length,
                    itemBuilder: (_, index) {
                      final receipt = items[index];
                      final id = (receipt['id'] as num).toInt();
                      final total = (receipt['total'] as num?)?.toDouble() ?? 0;
                      final seller = receipt['seller']?.toString() ?? '';
                      final created = receipt['created_at']?.toString() ?? '';
                      return Card(
                        child: ListTile(
                          leading: const CircleAvatar(child: Icon(Icons.receipt_long)),
                          title: Text('Чек ${receiptNumber(id)}', style: const TextStyle(fontWeight: FontWeight.w900)),
                          subtitle: Text(
                            '${seller.isEmpty ? 'Продавец не указан' : seller} • ${receipt['payment_method'] ?? 'Наличные'}\n${formatDateTime(created)}',
                          ),
                          isThreeLine: true,
                          trailing: Text(money(total), style: const TextStyle(fontWeight: FontWeight.w900)),
                          onTap: () async {
                            await Navigator.push(
                              context,
                              MaterialPageRoute(builder: (_) => ReceiptDetail(receiptId: id)),
                            );
                            if (!mounted) return;
                            await refresh();
                          },
                        ),
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class ReceiptDetail extends StatefulWidget {
  final int receiptId;

  const ReceiptDetail({
    super.key,
    required this.receiptId,
  });

  @override
  State<ReceiptDetail> createState() => _ReceiptDetailState();
}

class _ReceiptDetailState extends State<ReceiptDetail> {
  late Future<Map<String, dynamic>> future;

  @override
  void initState() {
    super.initState();
    future = load();
  }

  Future<Map<String, dynamic>> load() async {
    final receipt = await DB.i.receipt(widget.receiptId);
    final items = await DB.i.receiptItems(widget.receiptId);

    if (receipt == null) {
      throw Exception('Чек не найден');
    }

    return {
      'receipt': receipt,
      'items': items,
    };
  }

  String receiptNumber(int id) {
    return '#${id.toString().padLeft(6, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Чек ${receiptNumber(widget.receiptId)}',
        ),
      ),
      body: FutureBuilder<Map<String, dynamic>>(
        future: future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(
              child: CircularProgressIndicator(),
            );
          }

          if (snapshot.hasError) {
            return Center(
              child: Text(
                'Ошибка: ${snapshot.error}',
              ),
            );
          }

          final data = snapshot.data!;
          final receipt =
              data['receipt'] as Map<String, dynamic>;
          final items =
              data['items'] as List<Map<String, dynamic>>;

          final subtotal =
              (receipt['subtotal'] as num?)?.toDouble() ?? 0;
          final discount =
              (receipt['discount'] as num?)?.toDouble() ?? 0;
          final total =
              (receipt['total'] as num?)?.toDouble() ?? 0;

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    children: [
                      const Icon(
                        Icons.receipt_long,
                        size: 48,
                        color: primary,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'ЧЕК ${receiptNumber(widget.receiptId)}',
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        formatDateTime(receipt['created_at']),
                        style: const TextStyle(
                          color: Colors.white54,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Продавец: ${receipt['seller'] ?? ''}',
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Оплата: ${receipt['payment_method'] ?? 'Наличные'}',
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              ...items.map(
                (item) {
                  final quantity =
                      (item['quantity'] as num?)?.toInt() ?? 0;
                  final price =
                      (item['price'] as num?)?.toDouble() ?? 0;
                  final itemTotal =
                      (item['total'] as num?)?.toDouble() ?? 0;

                  return Card(
                    child: ListTile(
                      title: Text(
                        item['product_name']?.toString() ?? '',
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      subtitle: Text(
                        '${money(price)} × $quantity',
                      ),
                      trailing: Text(
                        money(itemTotal),
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 8),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    children: [
                      _ReceiptTotalRow(
                        title: 'Подытог',
                        value: money(subtotal),
                      ),
                      const SizedBox(height: 8),
                      _ReceiptTotalRow(
                        title: 'Скидка',
                        value: money(discount),
                      ),
                      const Divider(height: 24),
                      _ReceiptTotalRow(
                        title: 'ИТОГО',
                        value: money(total),
                        large: true,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ReceiptTotalRow extends StatelessWidget {
  final String title;
  final String value;
  final bool large;

  const _ReceiptTotalRow({
    required this.title,
    required this.value,
    this.large = false,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: large ? 20 : 15,
            fontWeight: large
                ? FontWeight.w900
                : FontWeight.w500,
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: large ? 21 : 15,
            fontWeight: FontWeight.w900,
          ),
        ),
      ],
    );
  }
}

class History extends StatefulWidget {
  final Map<String, dynamic> user;

  const History({
    super.key,
    required this.user,
  });

  @override
  State<History> createState() => _HistoryState();
}

class _HistoryState extends State<History> {
  late Future<List<Map<String, dynamic>>> future;

  String selectedProduct = 'Все товары';
  String selectedType = 'Все операции';

  String get seller => widget.user['role'] == 'admin'
      ? ''
      : widget.user['username'].toString();

  @override
  void initState() {
    super.initState();
    future = DB.i.ops(seller);
  }

  void reload() {
    setState(() {
      future = DB.i.ops(seller);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!hasPermission(widget.user, 'history')) {
      return Scaffold(
        appBar: AppBar(title: const Text('История операций')),
        body: const Center(
          child: Text('У вас нет доступа к истории операций.'),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('История'),
        actions: [
          IconButton(
            tooltip: 'Обновить',
            onPressed: reload,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(
              child: CircularProgressIndicator(),
            );
          }

          if (snapshot.hasError) {
            return Center(
              child: Text('Ошибка: ${snapshot.error}'),
            );
          }

          final allItems = snapshot.data ?? [];

          if (allItems.isEmpty) {
            return const Center(
              child: Text(
                'Операций пока нет',
                style: TextStyle(
                  color: Colors.white54,
                ),
              ),
            );
          }

          final products = allItems
              .map((item) => item['product_name']?.toString() ?? '')
              .where((name) => name.isNotEmpty)
              .toSet()
              .toList()
            ..sort(
              (a, b) => a.toLowerCase().compareTo(
                    b.toLowerCase(),
                  ),
            );

          final filteredItems = allItems.where((item) {
            final productMatches = selectedProduct == 'Все товары' ||
                item['product_name']?.toString() == selectedProduct;

            final typeMatches = selectedType == 'Все операции' ||
                item['operation_type']?.toString() == selectedType;

            return productMatches && typeMatches;
          }).toList();

          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: selectedType,
                        decoration: const InputDecoration(
                          labelText: 'Операция',
                          prefixIcon: Icon(Icons.filter_list),
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 'Все операции',
                            child: Text('Все операции'),
                          ),
                          DropdownMenuItem(
                            value: 'Продажа',
                            child: Text('Только продажи'),
                          ),
                          DropdownMenuItem(
                            value: 'Возврат',
                            child: Text('Только возвраты'),
                          ),
                          DropdownMenuItem(
                            value: 'Брак',
                            child: Text('Только брак'),
                          ),
                          DropdownMenuItem(
                            value: 'Закупка',
                            child: Text('Только закупки'),
                          ),
                        ],
                        onChanged: (value) {
                          if (value == null) return;
                          setState(() => selectedType = value);
                        },
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: selectedProduct,
                        decoration: const InputDecoration(
                          labelText: 'Товар',
                          prefixIcon: Icon(Icons.inventory_2_outlined),
                        ),
                        isExpanded: true,
                        items: [
                          const DropdownMenuItem(
                            value: 'Все товары',
                            child: Text('Все товары'),
                          ),
                          ...products.map(
                            (name) => DropdownMenuItem(
                              value: name,
                              child: Text(
                                name,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        ],
                        onChanged: (value) {
                          if (value == null) return;
                          setState(() => selectedProduct = value);
                        },
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Найдено: ${filteredItems.length}',
                    style: const TextStyle(
                      color: Colors.white60,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              Expanded(
                child: filteredItems.isEmpty
                    ? const Center(
                        child: Text(
                          'По выбранному фильтру ничего нет',
                          style: TextStyle(
                            color: Colors.white54,
                          ),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(
                          12,
                          0,
                          12,
                          12,
                        ),
                        itemCount: filteredItems.length,
                        itemBuilder: (_, index) {
                          final item = filteredItems[index];
                          final type =
                              item['operation_type'].toString();

                          final icon = type == 'Продажа'
                              ? Icons.shopping_cart
                              : type == 'Возврат'
                                  ? Icons.undo
                                  : type == 'Закупка'
                                      ? Icons.add_box
                                      : Icons.delete_outline;

                          return Card(
                            child: ListTile(
                              leading: CircleAvatar(
                                backgroundColor:
                                    const Color(0xff4f3b86),
                                child: Icon(icon),
                              ),
                              title: Text(
                                '${item['product_name']} × '
                                '${item['quantity']}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              subtitle: Text(
                                '$type • ${item['seller'] ?? ''} • '
                                '${item['payment_method'] ?? 'Наличные'}\n'
                                '${formatDateTime(item['created_at'])}',
                              ),
                              isThreeLine: true,
                              trailing: hasPermission(widget.user, 'profit')
                                  ? Text(
                                      type == 'Закупка'
                                          ? money((item['cost'] as num?) ?? 0)
                                          : money((item['total'] as num?) ?? 0),
                                    )
                                  : null,
                            ),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class StockPage extends StatefulWidget {
  final Map<String, dynamic> user;
  final String type;

  const StockPage({
    super.key,
    required this.user,
    required this.type,
  });

  @override
  State<StockPage> createState() => _StockState();
}

class _StockState extends State<StockPage> {
  final barcodeController = TextEditingController();
  final searchController = TextEditingController();
  List<Map<String, dynamic>> searchResults = [];

  Map<String, dynamic>? product;
  int quantity = 1;

  @override
  void dispose() {
    barcodeController.dispose();
    searchController.dispose();
    super.dispose();
  }

  Future<void> findProduct() async {
    final text = barcodeController.text.trim();
    if (text.isEmpty) return;
    final result = await DB.i.product(text);
    if (!mounted) return;
    setState(() {
      product = result;
      searchResults = [];
    });
    if (result == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Товар не найден')),
      );
    }
  }

  Future<void> searchProducts(String value) async {
    final q = value.trim();
    if (q.isEmpty) {
      if (mounted) setState(() => searchResults = []);
      return;
    }
    final results = await DB.i.products(q);
    if (!mounted || searchController.text.trim() != q) return;
    setState(() => searchResults = results);
  }

  void selectProduct(Map<String, dynamic> value) {
    setState(() {
      product = value;
      searchResults = [];
    });
    searchController.clear();
    barcodeController.text = value['barcode'].toString();
  }

  Future<void> save() async {
    final current = product;

    if (current == null) return;

    try {
      await DB.i.stock(
        current['id'] as int,
        widget.type == 'Брак'
            ? -quantity
            : quantity,
        widget.type,
        widget.user['username'].toString(),
      );

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${widget.type} оформлен',
          ),
        ),
      );

      setState(() {
        product = null;
        quantity = 1;
      });

      barcodeController.clear();
    } catch (error) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$error'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final allowed = widget.type == 'Брак'
        ? hasPermission(widget.user, 'defects')
        : hasPermission(widget.user, 'returns');

    if (!allowed) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.type)),
        body: const Center(
          child: Text('У вас нет права на эту операцию.'),
        ),
      );
    }

    final stock = product == null
        ? 0
        : (product!['quantity'] as num).toInt();

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.type),
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            TextField(
              controller: searchController,
              onChanged: searchProducts,
              decoration: const InputDecoration(
                labelText: 'Поиск по названию или штрихкоду',
                prefixIcon: Icon(Icons.search),
              ),
            ),
            if (searchResults.isNotEmpty)
              Container(
                constraints: const BoxConstraints(maxHeight: 220),
                margin: const EdgeInsets.only(top: 8),
                decoration: BoxDecoration(
                  color: cardColor,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: searchResults.length,
                  itemBuilder: (_, index) {
                    final item = searchResults[index];
                    return ListTile(
                      title: Text(item['name'].toString()),
                      subtitle: Text(
                        '${item['barcode']} • Остаток: ${item['quantity']}',
                      ),
                      onTap: () => selectProduct(item),
                    );
                  },
                ),
              ),
            const SizedBox(height: 10),
            TextField(
              controller: barcodeController,
              onSubmitted: (_) => findProduct(),
              decoration: InputDecoration(
                labelText: 'Штрихкод',
                prefixIcon:
                    const Icon(Icons.qr_code),
                suffixIcon: IconButton(
                  onPressed: findProduct,
                  icon: const Icon(Icons.search),
                ),
              ),
            ),
            if (product != null) ...[
              const SizedBox(height: 16),
              Card(
                child: ListTile(
                  title: Text(
                    product!['name'].toString(),
                  ),
                  subtitle: Text(
                    'Остаток: $stock шт.\n'
                    'Цена: ${money(product!['price'] as num)}',
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment:
                    MainAxisAlignment.center,
                children: [
                  IconButton(
                    onPressed: () {
                      setState(() {
                        if (quantity > 1) {
                          quantity--;
                        }
                      });
                    },
                    icon: const Icon(
                      Icons.remove_circle,
                    ),
                  ),
                  Text(
                    '$quantity',
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  IconButton(
                    onPressed: () {
                      if (widget.type == 'Брак' &&
                          quantity >= stock) {
                        return;
                      }

                      setState(() => quantity++);
                    },
                    icon: const Icon(
                      Icons.add_circle,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed:
                    quantity > 0 &&
                            (widget.type != 'Брак' ||
                                quantity <= stock)
                        ? save
                        : null,
                style: FilledButton.styleFrom(
                  minimumSize:
                      const Size.fromHeight(52),
                ),
                child: Text(
                  'Оформить '
                  '${widget.type.toLowerCase()}',
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}


class PurchasePage extends StatefulWidget {
  final Map<String, dynamic> user;
  const PurchasePage({super.key, required this.user});
  @override
  State<PurchasePage> createState() => _PurchasePageState();
}

class _PurchasePageState extends State<PurchasePage> {
  final search = TextEditingController();
  final qty = TextEditingController(text: '1');
  final buy = TextEditingController();
  final picker = ImagePicker();
  List<Map<String, dynamic>> results = [];
  Map<String, dynamic>? product;
  final photos = <XFile>[];
  bool saving = false;

  @override
  void dispose() {
    search.dispose();
    qty.dispose();
    buy.dispose();
    super.dispose();
  }

  Future<void> find(String value) async {
    final q = value.trim();
    if (q.isEmpty) {
      if (mounted) setState(() => results = []);
      return;
    }
    final r = await DB.i.products(q);
    if (!mounted || search.text.trim() != q) return;
    setState(() => results = r);
  }

  void select(Map<String, dynamic> p) {
    setState(() {
      product = p;
      results = [];
    });
    search.text = p['name'].toString();
    buy.text = ((p['purchase_price'] as num?)?.toDouble() ?? 0).toString();
  }

  Future<void> takePhoto() async {
    try {
      final photo = await picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 85,
        maxWidth: 1800,
      );
      if (photo == null || !mounted) return;
      setState(() => photos.add(photo));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не удалось сделать фото: $e')));
    }
  }

  Future<List<String>> savePhotosLocally() async {
    if (photos.isEmpty) return [];
    final directory = await getApplicationDocumentsDirectory();
    final folder = Directory(p.join(directory.path, 'purchase_photos'));
    await folder.create(recursive: true);
    final paths = <String>[];
    for (var i = 0; i < photos.length; i++) {
      final source = File(photos[i].path);
      final extension = p.extension(photos[i].path).isEmpty ? '.jpg' : p.extension(photos[i].path);
      final target = File(
        p.join(folder.path, 'purchase_${DateTime.now().microsecondsSinceEpoch}_$i$extension'),
      );
      await source.copy(target.path);
      paths.add(target.path);
    }
    return paths;
  }

  Future<List<String>> uploadPurchasePhotosToSupabase(String productBarcode) async {
    if (photos.isEmpty) return [];

    final storage = Supabase.instance.client.storage.from('product-photos');
    final uploadedPaths = <String>[];
    final batchId = DateTime.now().microsecondsSinceEpoch;

    try {
      for (var i = 0; i < photos.length; i++) {
        final source = File(photos[i].path);
        if (!await source.exists()) {
          throw Exception('Файл фотографии не найден');
        }

        final extension = p.extension(photos[i].path).toLowerCase();
        final safeExtension = extension.isEmpty ? '.jpg' : extension;
        final contentType = safeExtension == '.png'
            ? 'image/png'
            : safeExtension == '.webp'
                ? 'image/webp'
                : 'image/jpeg';

        // Фото закупки кладём в папку штрихкода. Поэтому администратор
        // увидит их вместе с остальными фото этого товара.
        final path = '$productBarcode/purchase_${batchId}_$i$safeExtension';

        await storage.upload(
          path,
          source,
          fileOptions: FileOptions(
            cacheControl: '31536000',
            contentType: contentType,
            upsert: false,
          ),
        );

        uploadedPaths.add(path);
      }

      return uploadedPaths;
    } catch (e) {
      if (uploadedPaths.isNotEmpty) {
        try {
          await storage.remove(uploadedPaths);
        } catch (_) {
          // Не скрываем исходную ошибку загрузки.
        }
      }
      rethrow;
    }
  }

  Future<void> deletePurchasePhotosFromSupabase(List<String> paths) async {
    if (paths.isEmpty) return;
    final storage = Supabase.instance.client.storage.from('product-photos');
    await storage.remove(paths);
  }

  Future<void> save() async {
    final pdt = product;
    if (pdt == null || saving) return;
    final count = int.tryParse(qty.text.trim()) ?? 0;
    final price = double.tryParse(buy.text.replaceAll(',', '.')) ?? -1;
    if (count <= 0 || price < 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Проверьте количество и закупочную цену')),
      );
      return;
    }

    setState(() => saving = true);
    List<String> uploadedPaths = [];

    try {
      final localPaths = await savePhotosLocally();
      final productBarcode = pdt['barcode']?.toString().trim() ?? '';
      if (productBarcode.isEmpty) {
        throw Exception('У товара нет штрихкода');
      }

      // Сначала загружаем фото в защищённое хранилище Supabase.
      uploadedPaths = await uploadPurchasePhotosToSupabase(productBarcode);

      await DB.i.purchase(
        pdt['id'] as int,
        count,
        price,
        widget.user['username'].toString(),
        photoPaths: localPaths,
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Закупка добавлена. Фото загружено: ${uploadedPaths.length}',
          ),
        ),
      );
      Navigator.pop(context);
    } catch (e) {
      // Если закупка не сохранилась локально, удаляем уже загруженные
      // серверные фотографии, чтобы не оставлять мусор в Storage.
      if (uploadedPaths.isNotEmpty) {
        try {
          await deletePurchasePhotosFromSupabase(uploadedPaths);
        } catch (_) {}
      }

      if (!mounted) return;
      setState(() => saving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!hasPermission(widget.user, 'purchases')) {
      return Scaffold(
        appBar: AppBar(title: const Text('Закупка')),
        body: const Center(child: Text('У вас нет права на закупки.')),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Дополнительная закупка')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: search,
            onChanged: find,
            decoration: const InputDecoration(
              labelText: 'Товар: название или штрихкод',
              prefixIcon: Icon(Icons.search),
            ),
          ),
          if (results.isNotEmpty)
            Card(
              child: Column(
                children: results
                    .map(
                      (p) => ListTile(
                        title: Text(p['name'].toString()),
                        subtitle: Text('${p['barcode']} • Остаток: ${p['quantity']}'),
                        onTap: () => select(p),
                      ),
                    )
                    .toList(),
              ),
            ),
          if (product != null) ...[
            const SizedBox(height: 12),
            Card(
              child: ListTile(
                title: Text(product!['name'].toString()),
                subtitle: Text('Текущий остаток: ${product!['quantity']} шт.'),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: qty,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Количество',
                prefixIcon: Icon(Icons.add_box),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: buy,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Закупочная цена за 1 шт.',
                prefixIcon: Icon(Icons.payments_outlined),
              ),
            ),
            const SizedBox(height: 18),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Фотоотчёт', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
                    const SizedBox(height: 6),
                    const Text('Сфотографируйте товар или поставку. Фото сохраняются в защищённом хранилище Supabase и привязываются к штрихкоду товара.'),
                    const SizedBox(height: 12),
                    if (photos.isNotEmpty)
                      SizedBox(
                        height: 110,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: photos.length,
                          separatorBuilder: (_, _) => const SizedBox(width: 8),
                          itemBuilder: (_, index) => Stack(
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: Image.file(
                                  File(photos[index].path),
                                  width: 110,
                                  height: 110,
                                  fit: BoxFit.cover,
                                ),
                              ),
                              Positioned(
                                top: 4,
                                right: 4,
                                child: IconButton.filled(
                                  onPressed: () => setState(() => photos.removeAt(index)),
                                  icon: const Icon(Icons.close, size: 18),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      onPressed: saving ? null : takePhoto,
                      icon: const Icon(Icons.camera_alt),
                      label: Text(photos.isEmpty ? 'Сделать фото' : 'Добавить фото'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: saving ? null : save,
              icon: saving
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.check),
              label: const Text('Принять товар'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            ),
          ],
        ],
      ),
    );
  }
}

class ProductHistoryPage extends StatefulWidget {
  final Map<String, dynamic> user;
  const ProductHistoryPage({super.key, required this.user});
  @override
  State<ProductHistoryPage> createState() => _ProductHistoryPageState();
}

class _ProductHistoryPageState extends State<ProductHistoryPage> {
  final search = TextEditingController();
  List<Map<String, dynamic>> results = [];
  Map<String, dynamic>? product;
  List<Map<String, dynamic>> history = [];

  @override
  void dispose() { search.dispose(); super.dispose(); }

  Future<void> find(String value) async {
    final q = value.trim();
    if (q.isEmpty) { if (mounted) setState(() => results = []); return; }
    final r = await DB.i.products(q);
    if (!mounted || search.text.trim() != q) return;
    setState(() => results = r);
  }

  Future<void> select(Map<String, dynamic> p) async {
    final seller = widget.user['role'] == 'admin' ? '' : widget.user['username'].toString();
    final h = await DB.i.productHistory(p['id'] as int, seller);
    if (!mounted) return;
    setState(() { product = p; results = []; history = h; });
    search.text = p['name'].toString();
  }

  @override
  Widget build(BuildContext context) {
    if (!hasPermission(widget.user, 'product_history')) {
      return Scaffold(appBar: AppBar(title: const Text('История товара')), body: const Center(child: Text('У вас нет доступа к истории товара.')));
    }
    final canProfit = hasPermission(widget.user, 'profit');
    return Scaffold(
      appBar: AppBar(title: const Text('История товара')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          TextField(controller: search, onChanged: find, decoration: const InputDecoration(labelText: 'Название или штрихкод', prefixIcon: Icon(Icons.search))),
          if (results.isNotEmpty)
            Card(child: Column(children: results.map((p) => ListTile(title: Text(p['name'].toString()), subtitle: Text('${p['barcode']} • Остаток: ${p['quantity']}'), onTap: () => select(p))).toList())),
          if (product != null) ...[
            const SizedBox(height: 10),
            Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(product!['name'].toString(), style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w900)),
              const SizedBox(height: 6),
              Text('Остаток: ${product!['quantity']} шт.'),
              if (canProfit) Text('Текущая закупочная цена: ${money((product!['purchase_price'] as num?)?.toDouble() ?? 0)}'),
            ]))),
            const SizedBox(height: 8),
            Text('Движение товара', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
            if (history.isEmpty) const Padding(padding: EdgeInsets.all(20), child: Text('Истории пока нет')),
            ...history.map((item) {
              final type = item['operation_type'].toString();
              final qty = (item['quantity'] as num?)?.toInt() ?? 0;
              final cost = (item['cost'] as num?)?.toDouble() ?? 0;
              return Card(child: ListTile(
                title: Text('$type • $qty шт.', style: const TextStyle(fontWeight: FontWeight.w800)),
                subtitle: Text('${formatDateTime(item['created_at'])}\nПродавец: ${item['seller'] ?? ''}'),
                isThreeLine: true,
                trailing: canProfit && type == 'Закупка' ? Text(money(cost)) : null,
              ));
            }),
          ],
        ],
      ),
    );
  }
}

class Users extends StatefulWidget {
  const Users({super.key});

  @override
  State<Users> createState() => _UsersState();
}

class _UsersState extends State<Users> {
  Future<List<Map<String, dynamic>>> load() {
    return DB.i.users();
  }

  Future<void> openForm([
    Map<String, dynamic>? user,
  ]) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => UserForm(user),
    );

    if (!mounted) return;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Продавцы'),
        actions: [
          IconButton(
            onPressed: () => openForm(),
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: FutureBuilder<
          List<Map<String, dynamic>>>(
        future: load(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(
              child: CircularProgressIndicator(),
            );
          }

          final users = snapshot.data!;

          if (users.isEmpty) {
            return const Center(
              child: Text('Продавцов пока нет'),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: users.length,
            itemBuilder: (_, index) {
              final user = users[index];

              return Card(
                child: ListTile(
                  title: Text(
                    user['full_name'].toString(),
                  ),
                  subtitle: Text(
                    '@${user['username']} • '
                    '${user['role']}'
                    '${user['active'] == 1 ? '' : ' • выключен'}',
                  ),
                  trailing: IconButton(
                    onPressed: () =>
                        openForm(user),
                    icon: const Icon(Icons.edit),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class UserForm extends StatefulWidget {
  final Map<String, dynamic>? user;

  const UserForm(
    this.user, {
    super.key,
  });

  @override
  State<UserForm> createState() => _UserFormState();
}

class _UserFormState extends State<UserForm> {
  late final TextEditingController login;
  late final TextEditingController name;
  late final TextEditingController password;

  bool active = true;
  late Map<String, bool> permissions;

  @override
  void initState() {
    super.initState();

    login = TextEditingController(
      text: widget.user?['username']?.toString() ?? '',
    );
    name = TextEditingController(
      text: widget.user?['full_name']?.toString() ?? '',
    );
    password = TextEditingController();

    active = widget.user == null
        ? true
        : widget.user!['active'] != 0;
    permissions = widget.user == null
        ? <String, bool>{...sellerPermissionDefaults}
        : decodePermissions(widget.user!['permissions']);
  }

  @override
  void dispose() {
    login.dispose();
    name.dispose();
    password.dispose();
    super.dispose();
  }
Future<void> save() async {
  print('SELLER SAVE BUTTON PRESSED');

  final username = login.text.trim();
  final fullName = name.text.trim();

  if (username.isEmpty || fullName.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Заполните email и имя'),
      ),
    );
    return;
  }

  if (widget.user == null && password.text.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Для нового продавца нужен пароль'),
      ),
    );
    return;
  }

  if (widget.user == null && password.text.length < 6) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Пароль должен содержать минимум 6 символов',
        ),
      ),
    );
    return;
  }

  try {
    // =========================================================
    // СОЗДАНИЕ НОВОГО ПРОДАВЦА
    // =========================================================

    if (widget.user == null) {
      print('CREATE SELLER: отправляем запрос');

      final session =
          Supabase.instance.client.auth.currentSession;

      if (session == null || session.accessToken.isEmpty) {
        throw Exception('Нет активной сессии Supabase');
      }

      print('JWT найден, отправляем его в create-seller');

      final response =
          await Supabase.instance.client.functions.invoke(
        'create-seller',
        headers: {
          'Authorization':
              'Bearer ${session.accessToken}',
        },
        body: {
          'email': username,
          'full_name': fullName,
          'password': password.text,
          'permissions': permissions,
        },
      );

      print('FUNCTION STATUS: ${response.status}');
      print('FUNCTION DATA: ${response.data}');

      final responseData = response.data;

      if (responseData is Map &&
          responseData['success'] == true) {
        // Сохраняем локальный кэш только после
        // успешного создания на сервере.
        await DB.i.saveUser({
          'username': username,
          'password_hash': '',
          'role': 'seller',
          'full_name': fullName,
          'active': active ? 1 : 0,
          'permissions': jsonEncode(permissions),
          'created_at':
              DateTime.now().toIso8601String(),
        });

        if (!mounted) return;

        Navigator.pop(context);

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Продавец создан на сервере',
            ),
          ),
        );

        return;
      }

      final errorMessage =
          responseData is Map
              ? responseData['error']?.toString()
              : null;

      throw Exception(
        errorMessage ??
            'Не удалось создать продавца',
      );
    }

    // =========================================================
    // РЕДАКТИРОВАНИЕ СУЩЕСТВУЮЩЕГО ПРОДАВЦА
    // =========================================================

    final oldEmail =
        widget.user!['username']
            ?.toString()
            .trim()
            .toLowerCase() ??
        '';

    if (oldEmail.isEmpty) {
      throw Exception(
        'Не найден текущий email продавца',
      );
    }

    print('UPDATE SELLER: отправляем запрос');

    final session =
        Supabase.instance.client.auth.currentSession;

    if (session == null || session.accessToken.isEmpty) {
      throw Exception(
        'Нет активной сессии Supabase',
      );
    }

    print('JWT найден, отправляем его в update-seller');

    final response =
        await Supabase.instance.client.functions.invoke(
      'update-seller',
      headers: {
        'Authorization':
            'Bearer ${session.accessToken}',
      },
      body: {
        'old_email': oldEmail,
        'email': username,
        'full_name': fullName,
        'active': active,
        'permissions': permissions,
        if (password.text.isNotEmpty)
          'password': password.text,
      },
    );

    print(
      'UPDATE SELLER STATUS: ${response.status}',
    );

    print(
      'UPDATE SELLER DATA: ${response.data}',
    );

    final responseData = response.data;

    if (responseData is! Map ||
        responseData['success'] != true) {
      final errorMessage =
          responseData is Map
              ? responseData['error']?.toString()
              : null;

      throw Exception(
        errorMessage ??
            'Не удалось обновить продавца',
      );
    }

    // =========================================================
    // ОБНОВЛЯЕМ ЛОКАЛЬНЫЙ КЭШ
    // ТОЛЬКО ПОСЛЕ УСПЕШНОГО СЕРВЕРА
    // =========================================================

    await DB.i.saveUser({
      'id': widget.user!['id'],
      'username': username,
      'password_hash': '',
      'role': 'seller',
      'full_name': fullName,
      'active': active ? 1 : 0,
      'permissions': jsonEncode(permissions),
    });

    if (!mounted) return;

    Navigator.pop(context);

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Продавец обновлен на сервере',
        ),
      ),
    );
  } catch (error) {
    print('SELLER SAVE ERROR: $error');

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Не удалось сохранить: $error',
        ),
      ),
    );
  }
}
 @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        20,
        20,
        MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.user == null
                  ? 'Новый продавец'
                  : 'Продавец',
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: login,
              decoration: const InputDecoration(
  labelText: 'Email',
  prefixIcon: Icon(Icons.email),
),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: name,
              decoration: const InputDecoration(
                labelText: 'Имя',
                prefixIcon: Icon(Icons.badge),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: password,
              obscureText: true,
              decoration: InputDecoration(
                labelText: widget.user == null
                    ? 'Пароль'
                    : 'Новый пароль',
                prefixIcon: const Icon(Icons.lock),
              ),
            ),
            SwitchListTile(
              value: active,
              onChanged: (value) {
                setState(() => active = value);
              },
              title: const Text('Активен'),
            ),
            if (widget.user?['role']?.toString() != 'admin') ...[
              const Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: EdgeInsets.only(top: 8, bottom: 4),
                  child: Text(
                    'Права доступа',
                    style: TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ),
              ...permissionLabels.entries.map(
                (entry) => SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: permissions[entry.key] ?? false,
                  onChanged: (value) {
                    setState(() => permissions[entry.key] = value);
                  },
                  title: Text(entry.value),
                ),
              ),
            ],
            FilledButton(
              onPressed: save,
              style: FilledButton.styleFrom(
                minimumSize:
                    const Size.fromHeight(52),
              ),
              child: const Text('Сохранить'),
            ),
          ],
        ),
      ),
    );
  }
}
