import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite/sqflite.dart';

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;

  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('app_database_v3.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    // 桌面版初始化逻辑
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
    
    final appDir = await getApplicationSupportDirectory();
    final path = join(appDir.path, filePath);
    
    return await openDatabase(path, version: 1, onCreate: _createDB);
  }

  Future _createDB(Database db, int version) async {
    await db.execute('''
    CREATE TABLE users (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      mobile TEXT NOT NULL UNIQUE,
      hashed_password TEXT NOT NULL,
      role TEXT NOT NULL DEFAULT 'customer'
    )
    ''');

    await db.execute('''
    CREATE TABLE sessions (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL,
      title TEXT,
      created_at TEXT NOT NULL,
      form_data TEXT,
      FOREIGN KEY (user_id) REFERENCES users (id)
    )
    ''');

    await db.execute('''
    CREATE TABLE chat_messages (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id INTEGER NOT NULL, 
      sender TEXT NOT NULL,
      message TEXT NOT NULL,
      timestamp TEXT NOT NULL,
      image_path TEXT, 
      FOREIGN KEY (session_id) REFERENCES sessions (id) ON DELETE CASCADE
    )
    ''');

    await db.execute('''
    CREATE TABLE sample_requests (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL,
      session_id INTEGER,
      test_purpose TEXT,
      sample_shape TEXT,
      test_requirements TEXT,
      customer_address TEXT,
      sf_tracking_number TEXT,
      FOREIGN KEY (user_id) REFERENCES users (id)
    )
    ''');
  }

  // --- Session Operations ---
  Future<void> updateSessionFormData(int sessionId, Map<String, dynamic> formData) async {
    final db = await instance.database;
    await db.update(
      'sessions',
      {'form_data': jsonEncode(formData)},
      where: 'id = ?',
      whereArgs: [sessionId],
    );
  }

  Future<Map<String, dynamic>> getSessionFormData(int sessionId) async {
    final db = await instance.database;
    final maps = await db.query(
      'sessions',
      columns: ['form_data'],
      where: 'id = ?',
      whereArgs: [sessionId],
    );
    if (maps.isNotEmpty && maps.first['form_data'] != null) {
      try {
        return jsonDecode(maps.first['form_data'] as String);
      } catch (e) {
        return {};
      }
    }
    return {};
  }

  // --- Crypto Helper ---
  String _hashPassword(String password) {
    var bytes = utf8.encode(password);
    var digest = sha256.convert(bytes);
    return digest.toString();
  }

  // --- User Operations ---
  Future<Map<String, dynamic>> register(String mobile, String password) async {
    final db = await instance.database;
    final hashedPassword = _hashPassword(password);
    try {
      final id = await db.insert('users', {
        'mobile': mobile,
        'hashed_password': hashedPassword,
        'role': 'customer'
      });
      return {'id': id, 'mobile': mobile, 'role': 'customer'};
    } catch (e) {
      throw Exception("手机号可能已被注册");
    }
  }

  Future<Map<String, dynamic>> login(String mobile, String password) async {
    final db = await instance.database;
    final hashedPassword = _hashPassword(password);
    final maps = await db.query(
      'users',
      where: 'mobile = ? AND hashed_password = ?',
      whereArgs: [mobile, hashedPassword],
    );
    if (maps.isNotEmpty) {
      return maps.first;
    } else {
      throw Exception("手机号或密码错误");
    }
  }

  Future<int> createSession(int userId, String title) async {
    final db = await instance.database;
    return await db.insert('sessions', {
      'user_id': userId,
      'title': title,
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  Future<List<Map<String, dynamic>>> getUserSessions(int userId) async {
    final db = await instance.database;
    return await db.query(
      'sessions',
      where: 'user_id = ?',
      whereArgs: [userId],
      orderBy: 'created_at DESC',
    );
  }
  
  Future<void> updateSessionTitle(int sessionId, String newTitle) async {
    final db = await instance.database;
    await db.update(
      'sessions',
      {'title': newTitle},
      where: 'id = ?',
      whereArgs: [sessionId],
    );
  }

  Future<void> logMessage(int sessionId, String sender, String message, {String? imagePath}) async {
    final db = await instance.database;
    await db.insert('chat_messages', {
      'session_id': sessionId,
      'sender': sender,
      'message': message,
      'image_path': imagePath,
      'timestamp': DateTime.now().toIso8601String(),
    });
  }

  Future<List<Map<String, dynamic>>> getSessionMessages(int sessionId) async {
    final db = await instance.database;
    return await db.query(
      'chat_messages',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'timestamp ASC',
    );
  }

  Future<int> submitSampleRequest(int userId, int sessionId, Map<String, dynamic> data) async {
    final db = await instance.database;
    return await db.insert('sample_requests', {
      'user_id': userId,
      'session_id': sessionId,
      'test_purpose': data['test_purpose'],
      'sample_shape': data['sample_shape'],
      'test_requirements': data['test_requirements'],
      'customer_address': data['customer_address'],
      'sf_tracking_number': data['sf_tracking_number'],
    });
  }
}
