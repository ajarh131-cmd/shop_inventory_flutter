import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

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
  if (date == null) return raw;

  final local = date.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');

  return '${two(local.day)}.${two(local.month)}.${local.year} • '
      '${two(local.hour)}:${two(local.minute)}';
}

String hashPassword(String value) {
  return sha256.convert(utf8.encode(value)).toString();
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await DB.i.open();
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
    String username,
    String password,
  ) async {
    final rows = await db!.query(
      'users',
      where: 'username = ? AND password_hash = ? AND active = 1',
      whereArgs: [username.trim(), hashPassword(password)],
      limit: 1,
    );

    return rows.isEmpty ? null : rows.first;
  }

  Future<List<Map<String, dynamic>>> products([String query = '']) async {
    if (query.trim().isEmpty) {
      return db!.query(
        'products',
        orderBy: 'name COLLATE NOCASE',
      );
    }

    final q = query.trim();

    return db!.query(
      'products',
      where: 'name LIKE ? OR barcode LIKE ?',
      whereArgs: ['%$q%', '%$q%'],
      orderBy: 'name COLLATE NOCASE',
    );
  }

  Future<Map<String, dynamic>?> product(String barcode) async {
    final rows = await db!.query(
      'products',
      where: 'barcode = ?',
      whereArgs: [barcode.trim()],
      limit: 1,
    );

    return rows.isEmpty ? null : rows.first;
  }

  Future<void> saveProduct(Map<String, dynamic> product) async {
    if (product['id'] == null) {
      await db!.insert('products', product);
    } else {
      await db!.update(
        'products',
        product,
        where: 'id = ?',
        whereArgs: [product['id']],
      );
    }
  }

  Future<int> sale(
    List<CartItem> cart,
    double discount,
    String seller,
  ) async {
    if (cart.isEmpty) return 0;

    if (await currentShift() == null) {
      throw Exception('Смена не открыта. Сначала откройте смену.');
    }

    return await db!.transaction<int>((transaction) async {
      final subtotal = cart.fold<double>(
        0,
        (sum, item) => sum + item.total,
      );

      final discountAmount = subtotal * discount / 100;
      final receiptTotal = subtotal - discountAmount;

      final receiptId = await transaction.insert('receipts', {
        'seller': seller,
        'subtotal': subtotal,
        'discount': discountAmount,
        'total': receiptTotal,
        'created_at': DateTime.now().toIso8601String(),
      });

      for (final item in cart) {
        final rows = await transaction.query(
          'products',
          where: 'id = ?',
          whereArgs: [item.id],
          limit: 1,
        );

        if (rows.isEmpty) {
          throw Exception('Товар не найден: ${item.name}');
        }

        final product = rows.first;
        final stock = (product['quantity'] as num).toInt();

        if (item.qty > stock) {
          throw Exception('Недостаточно товара: ${item.name}');
        }

        final itemTotal = item.total * (1 - discount / 100);
        final cost = item.buy * item.qty;
        final profit = itemTotal - cost;
        final itemDiscount = item.total - itemTotal;

        await transaction.update(
          'products',
          {'quantity': stock - item.qty},
          where: 'id = ?',
          whereArgs: [item.id],
        );

        await transaction.insert('receipt_items', {
          'receipt_id': receiptId,
          'barcode': item.code,
          'product_name': item.name,
          'quantity': item.qty,
          'price': item.price,
          'purchase_price': item.buy,
          'discount': itemDiscount,
          'total': itemTotal,
          'cost': cost,
          'profit': profit,
        });

        await transaction.insert('operations', {
          'operation_type': 'Продажа',
          'barcode': item.code,
          'product_name': item.name,
          'quantity': item.qty,
          'price': item.price,
          'discount': itemDiscount,
          'total': itemTotal,
          'created_at': DateTime.now().toIso8601String(),
          'cost': cost,
          'profit': profit,
          'seller': seller,
        });
      }

      return receiptId;
    }).then((receiptId) {
      notifyInventoryChanged();
      return receiptId;
    });
  }

  Future<Map<String, dynamic>?> currentShift() async {
    final rows = await db!.query(
      'shifts',
      where: 'status = ?',
      whereArgs: ['open'],
      orderBy: 'id DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<int> openShift(String openedBy, double openingCash) async {
    if (await currentShift() != null) {
      throw Exception('Смена уже открыта');
    }
    return db!.insert('shifts', {
      'opened_by': openedBy,
      'opened_at': DateTime.now().toIso8601String(),
      'opening_cash': openingCash,
      'status': 'open',
    });
  }

  Future<void> closeShift(
    int shiftId,
    String closedBy,
    double closingCash,
  ) async {
    final changed = await db!.update(
      'shifts',
      {
        'closed_by': closedBy,
        'closed_at': DateTime.now().toIso8601String(),
        'closing_cash': closingCash,
        'status': 'closed',
      },
      where: 'id = ? AND status = ?',
      whereArgs: [shiftId, 'open'],
    );
    if (changed == 0) {
      throw Exception('Смена уже закрыта');
    }
  }

  Future<Map<String, num>> shiftTotals(int shiftId) async {
    final rows = await db!.query(
      'shifts',
      where: 'id = ?',
      whereArgs: [shiftId],
      limit: 1,
    );
    if (rows.isEmpty) throw Exception('Смена не найдена');

    final openedAt = rows.first['opened_at'].toString();
    final closedAt = rows.first['closed_at']?.toString();

    final where = closedAt == null
        ? 'created_at >= ?'
        : 'created_at >= ? AND created_at <= ?';
    final args = closedAt == null
        ? <Object?>[openedAt]
        : <Object?>[openedAt, closedAt];

    final row = (await db!.rawQuery(
      'SELECT '
      'COALESCE(SUM(CASE WHEN operation_type = "Продажа" THEN total ELSE 0 END),0) AS sales, '
      'COALESCE(SUM(CASE WHEN operation_type = "Возврат" THEN total ELSE 0 END),0) AS returns, '
      'COALESCE(SUM(CASE WHEN operation_type = "Продажа" THEN quantity ELSE 0 END),0) AS sold '
      'FROM operations WHERE $where',
      args,
    )).first;

    return row.map((key, value) => MapEntry(key, value as num));
  }

  Future<List<Map<String, dynamic>>> receipts(
    String seller,
  ) async {
    if (seller.isEmpty) {
      return db!.query(
        'receipts',
        orderBy: 'id DESC',
        limit: 300,
      );
    }

    return db!.query(
      'receipts',
      where: 'seller = ?',
      whereArgs: [seller],
      orderBy: 'id DESC',
      limit: 300,
    );
  }

  Future<List<Map<String, dynamic>>> receiptItems(
    int receiptId,
  ) async {
    return db!.query(
      'receipt_items',
      where: 'receipt_id = ?',
      whereArgs: [receiptId],
      orderBy: 'id ASC',
    );
  }

  Future<Map<String, dynamic>?> receipt(
    int receiptId,
  ) async {
    final rows = await db!.query(
      'receipts',
      where: 'id = ?',
      whereArgs: [receiptId],
      limit: 1,
    );

    return rows.isEmpty ? null : rows.first;
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

      final product = rows.first;
      final oldQuantity = (product['quantity'] as num).toInt();
      final newQuantity = oldQuantity + delta;

      if (newQuantity < 0) {
        throw Exception('Недостаточно товара на складе');
      }

      final quantity = delta.abs();
      final purchasePrice =
          (product['purchase_price'] as num?)?.toDouble() ?? 0;
      final price = (product['price'] as num).toDouble();

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
        'barcode': product['barcode'],
        'product_name': product['name'],
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
  }

  Future<List<Map<String, dynamic>>> ops(String seller) async {
    if (seller.isEmpty) {
      return db!.query(
        'operations',
        orderBy: 'id DESC',
        limit: 300,
      );
    }

    return db!.query(
      'operations',
      where: 'seller = ?',
      whereArgs: [seller],
      orderBy: 'id DESC',
      limit: 300,
    );
  }

  Future<Map<String, num>> stats(
    String seller, [
    String period = 'all',
  ]) async {
    final conditions = <String>[];
    final args = <Object?>[];

    if (seller.isNotEmpty) {
      conditions.add('seller = ?');
      args.add(seller);
    }

    if (period == 'today') {
      conditions.add(
        "date(created_at, 'localtime') = date('now', 'localtime')",
      );
    } else if (period == 'week') {
      conditions.add(
        "date(created_at, 'localtime') >= date('now', 'localtime', '-6 day')",
      );
    } else if (period == 'month') {
      conditions.add(
        "date(created_at, 'localtime') >= date('now', 'localtime', 'start of month')",
      );
    }

    final where = conditions.isEmpty
        ? ''
        : ' WHERE ${conditions.join(' AND ')}';

    final row = (await db!.rawQuery(
      '''
      SELECT
        COALESCE(SUM(
          CASE WHEN operation_type = 'Продажа'
          THEN quantity ELSE 0 END
        ), 0) AS sold,
        COALESCE(SUM(
          CASE WHEN operation_type = 'Продажа'
          THEN total ELSE 0 END
        ), 0) AS revenue,
        COALESCE(SUM(profit), 0) AS profit,
        COALESCE(SUM(
          CASE WHEN operation_type = 'Возврат'
          THEN total ELSE 0 END
        ), 0) AS returns,
        COALESCE(SUM(
          CASE WHEN operation_type = 'Брак'
          THEN quantity ELSE 0 END
        ), 0) AS defects
      FROM operations
      $where
      ''',
      args,
    )).first;

    return row.map(
      (key, value) => MapEntry(key, value as num),
    );
  }

  Future<List<Map<String, dynamic>>> sellerStats(
    String period,
  ) async {
    String dateCondition = '';

    if (period == 'today') {
      dateCondition =
          " AND date(created_at, 'localtime') = date('now', 'localtime')";
    } else if (period == 'week') {
      dateCondition =
          " AND date(created_at, 'localtime') >= date('now', 'localtime', '-6 day')";
    } else if (period == 'month') {
      dateCondition =
          " AND date(created_at, 'localtime') >= date('now', 'localtime', 'start of month')";
    }

    return db!.rawQuery(
      '''
      SELECT
        seller,
        COUNT(DISTINCT CASE WHEN operation_type = 'Продажа'
          THEN id END) AS sales,
        COALESCE(SUM(
          CASE WHEN operation_type = 'Продажа'
          THEN quantity ELSE 0 END
        ), 0) AS sold,
        COALESCE(SUM(
          CASE WHEN operation_type = 'Продажа'
          THEN total ELSE 0 END
        ), 0) AS revenue,
        COALESCE(SUM(
          CASE WHEN operation_type = 'Продажа'
          THEN profit ELSE 0 END
        ), 0) AS profit
      FROM operations
      WHERE seller IS NOT NULL
        AND seller != ''
        $dateCondition
      GROUP BY seller
      ORDER BY revenue DESC
      ''',
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

  Future<void> backup() async {
    final databaseFile = File(
      p.join(await getDatabasesPath(), 'shop.db'),
    );

    final backupDirectory = Directory(
      p.join(await getDatabasesPath(), 'backups'),
    );

    if (!await backupDirectory.exists()) {
      await backupDirectory.create(recursive: true);
    }

    final filename =
        'shop_${DateTime.now().millisecondsSinceEpoch}.db';

    await databaseFile.copy(
      p.join(backupDirectory.path, filename),
    );
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
                decoration: const InputDecoration(
                  labelText: 'Логин',
                  prefixIcon: Icon(Icons.person),
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
                'Первый вход: admin / admin123',
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

class _ShellState extends State<Shell> {
  int index = 0;

  @override
  Widget build(BuildContext context) {
    final pages = [
      Home(user: widget.user),
      Products(user: widget.user),
      Sale(user: widget.user),
      Stats(user: widget.user),
      More(
        user: widget.user,
        logout: widget.logout,
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
    final result = await DB.i.products(searchController.text);

    if (!mounted) return;

    setState(() => items = result);
  }

  Future<void> form([Map<String, dynamic>? product]) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => ProductForm(product),
    );

    if (!mounted) return;
    await load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Товары',
          style: TextStyle(
            fontWeight: FontWeight.w900,
          ),
        ),
        actions: [
          if (widget.user['role'] == 'admin')
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
                          trailing: widget.user['role'] ==
                                  'admin'
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

class ProductForm extends StatefulWidget {
  final Map<String, dynamic>? product;

  const ProductForm(
    this.product, {
    super.key,
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

  Future<void> save() async {
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

    final data = <String, dynamic>{
      'barcode': productBarcode,
      'name': productName,
      'purchase_price': buyPrice,
      'price': salePrice,
      'quantity': stock,
    };

    if (widget.product?['id'] != null) {
      data['id'] = widget.product!['id'];
    }

    try {
      await DB.i.saveProduct(data);

      if (!mounted) return;
      Navigator.pop(context);
    } catch (error) {
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
    final editing = widget.product != null;

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
            const SizedBox(height: 14),
            FilledButton(
              onPressed: save,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(54),
              ),
              child: const Text('Сохранить'),
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
  final discountController =
      TextEditingController(text: '0');

  final cart = <CartItem>[];

  @override
  void dispose() {
    barcodeController.dispose();
    discountController.dispose();
    super.dispose();
  }

  Future<void> addByBarcode(String value) async {
    final code = value.trim();

    if (code.isEmpty) return;

    final product = await DB.i.product(code);

    if (!mounted) return;

    if (product == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Товар не найден'),
        ),
      );
      return;
    }

    final stock =
        (product['quantity'] as num).toInt();

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
          const SnackBar(
            content: Text('Товара нет на складе'),
          ),
        );
        return;
      }

      setState(() {
        cart.add(
          CartItem(
            id: product['id'] as int,
            code: product['barcode'].toString(),
            name: product['name'].toString(),
            price:
                (product['price'] as num).toDouble(),
            buy:
                (product['purchase_price'] as num?)
                        ?.toDouble() ??
                    0,
          ),
        );
      });
    }

    barcodeController.clear();
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
    return Scaffold(
      appBar: AppBar(
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
                    controller: barcodeController,
                    onSubmitted: addByBarcode,
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.qr_code),
                      hintText: 'Штрихкод',
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
    load();
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
        title: const Text('Статистика'),
      ),
      body: RefreshIndicator(
        onRefresh: load,
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: [
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
                  (row) => _SellerStatCard(row: row),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SellerStatCard extends StatelessWidget {
  final Map<String, dynamic> row;

  const _SellerStatCard({
    required this.row,
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

  const More({
    super.key,
    required this.user,
    required this.logout,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
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
          MoreAction(
            title: 'Резервная копия',
            icon: Icons.backup,
            onTap: () async {
              await DB.i.backup();

              if (!context.mounted) return;

              ScaffoldMessenger.of(context)
                  .showSnackBar(
                const SnackBar(
                  content: Text(
                    'Резервная копия создана',
                  ),
                ),
              );
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
  late Future<List<Map<String, dynamic>>> future;

  @override
  void initState() {
    super.initState();
    future = DB.i.receipts(
      widget.user['role'] == 'admin'
          ? ''
          : widget.user['username'].toString(),
    );
  }

  Future<void> refresh() async {
    setState(() {
      future = DB.i.receipts(
        widget.user['role'] == 'admin'
            ? ''
            : widget.user['username'].toString(),
      );
    });
    await future;
  }

  String receiptNumber(int id) {
    return '#${id.toString().padLeft(6, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Чеки'),
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
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Text(
                  'Ошибка: ${snapshot.error}',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }

          final items = snapshot.data ?? [];

          if (items.isEmpty) {
            return RefreshIndicator(
              onRefresh: refresh,
              child: ListView(
                children: const [
                  SizedBox(height: 180),
                  Center(
                    child: Text(
                      'Чеков пока нет',
                      style: TextStyle(
                        color: Colors.white54,
                      ),
                    ),
                  ),
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
                final total =
                    (receipt['total'] as num?)?.toDouble() ?? 0;
                final seller =
                    receipt['seller']?.toString() ?? '';
                final created =
                    receipt['created_at']?.toString() ?? '';

                return Card(
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: const Color(0xff4f3b86),
                      child: const Icon(Icons.receipt_long),
                    ),
                    title: Text(
                      'Чек ${receiptNumber(id)}',
                      style: const TextStyle(
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    subtitle: Text(
                      '${seller.isEmpty ? 'Продавец не указан' : seller}\n'
                      '${formatDateTime(created)}',
                    ),
                    isThreeLine: true,
                    trailing: Text(
                      money(total),
                      style: const TextStyle(
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    onTap: () async {
                      await Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => ReceiptDetail(
                            receiptId: id,
                          ),
                        ),
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

  @override
  void initState() {
    super.initState();
    future = DB.i.ops(
      widget.user['role'] == 'admin'
          ? ''
          : widget.user['username'].toString(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('История'),
      ),
      body: FutureBuilder<
          List<Map<String, dynamic>>>(
        future: future,
        builder: (context, snapshot) {
          if (snapshot.connectionState !=
              ConnectionState.done) {
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

          final items = snapshot.data ?? [];

          if (items.isEmpty) {
            return const Center(
              child: Text(
                'Операций пока нет',
                style: TextStyle(
                  color: Colors.white54,
                ),
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: items.length,
            itemBuilder: (_, index) {
              final item = items[index];
              final type =
                  item['operation_type'].toString();

              final icon = type == 'Продажа'
                  ? Icons.shopping_cart
                  : type == 'Возврат'
                      ? Icons.undo
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
                    '$type • '
                    '${item['seller'] ?? ''}\n'
                    '${formatDateTime(item['created_at'])}',
                  ),
                  isThreeLine: true,
                  trailing: Text(
                    money(
                      (item['total'] as num?) ?? 0,
                    ),
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

  Map<String, dynamic>? product;
  int quantity = 1;

  @override
  void dispose() {
    barcodeController.dispose();
    super.dispose();
  }

  Future<void> findProduct() async {
    final result = await DB.i.product(
      barcodeController.text,
    );

    if (!mounted) return;

    setState(() => product = result);

    if (result == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Товар не найден'),
        ),
      );
    }
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
  }

  @override
  void dispose() {
    login.dispose();
    name.dispose();
    password.dispose();
    super.dispose();
  }

  Future<void> save() async {
    final username = login.text.trim();
    final fullName = name.text.trim();

    if (username.isEmpty || fullName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Заполните логин и имя',
          ),
        ),
      );
      return;
    }

    if (widget.user == null &&
        password.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Для нового продавца нужен пароль',
          ),
        ),
      );
      return;
    }

    final data = <String, dynamic>{
      'username': username,
      'full_name': fullName,
      'active': active ? 1 : 0,
    };

    if (widget.user == null) {
      data['password_hash'] =
          hashPassword(password.text);
      data['role'] = 'seller';
      data['created_at'] =
          DateTime.now().toIso8601String();
    } else {
      data['id'] = widget.user!['id'];

      if (password.text.isNotEmpty) {
        data['password_hash'] =
            hashPassword(password.text);
      }
    }

    try {
      await DB.i.saveUser(data);

      if (!mounted) return;
      Navigator.pop(context);
    } catch (error) {
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
                labelText: 'Логин',
                prefixIcon: Icon(Icons.person),
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
