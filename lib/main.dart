import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'database_helper.dart';
import 'ai_service.dart';

void main() {
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthProvider()),
        ChangeNotifierProvider(create: (_) => ChatProvider()),
      ],
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '常来测 - 桌面版',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      home: const AuthCheck(),
    );
  }
}

// --- Providers (保持原有逻辑，略作适配) ---

class AuthProvider extends ChangeNotifier {
  Map<String, dynamic>? _user;
  Map<String, dynamic>? get user => _user;
  final AIService _aiService = AIService();

  AuthProvider() {
    _loadUserFromPrefs();
  }

  Future<void> _loadUserFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final userStr = prefs.getString('auth_user');
    if (userStr != null) {
      _user = jsonDecode(userStr);
      notifyListeners();
    }
  }

  Future<void> _saveUserToPrefs(Map<String, dynamic> userData) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('auth_user', jsonEncode(userData));
  }

  Future<bool> login(String mobile, String password) async {
    try {
      final data = await _aiService.login(mobile, password);
      _user = {
        'id': data['user_id'],
        'mobile': data['username'],
        'token': data['access_token'],
        'role': data['role'] ?? 'customer'
      };
      await _saveUserToPrefs(_user!);
      notifyListeners();
      return true;
    } catch (e) {
      print("Login Error: $e");
      return false;
    }
  }

  Future<bool> register(String mobile, String password, String code) async {
    try {
      final data = await _aiService.register(mobile, password, code);
      _user = {
        'id': data['user_id'],
        'mobile': data['username'],
        'token': data['access_token'],
        'role': data['role'] ?? 'customer'
      };
      await _saveUserToPrefs(_user!);
      notifyListeners();
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<bool> resetPassword(String mobile, String code, String newPassword) async {
    try {
      await _aiService.resetPassword(mobile, code, newPassword);
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<String> sendCode(String mobile) async {
    return await _aiService.sendCode(mobile);
  }

  Future<void> logout() async {
    _user = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('auth_user');
    notifyListeners();
  }
}

class ChatProvider extends ChangeNotifier {
  final List<Map<String, dynamic>> _messages = [];
  final Map<String, String> _formData = {};
  bool _isLoading = false;
  bool _isTransferred = false;
  final AIService _aiService = AIService();

  List<Map<String, dynamic>> _sessions = [];
  int? _currentSessionId;
  int? get currentSessionId => _currentSessionId;
  List<Map<String, dynamic>> get sessions => _sessions;

  List<Map<String, dynamic>> get messages => _messages;
  Map<String, String> get formData => _formData;
  bool get isLoading => _isLoading;
  bool get isTransferred => _isTransferred;

  Future<void> loadSessions(int userId) async {
    _sessions = await DatabaseHelper.instance.getUserSessions(userId);
    notifyListeners();
  }

  Future<void> startNewSession(int userId) async {
    _messages.clear();
    _formData.clear();
    _isLoading = false;
    _isTransferred = false;
    final id = await DatabaseHelper.instance.createSession(userId, "新对话");
    _currentSessionId = id;
    await loadSessions(userId);
    await _addMessageAndLog('assistant', '您好！我是您的智能检测助手(桌面版)，您可以向我发送图片、提问或告诉我您的测试需求。');
    notifyListeners();
  }

  Future<void> switchSession(int sessionId) async {
    if (_currentSessionId == sessionId) return;
    _isLoading = true;
    _isTransferred = false;
    notifyListeners();
    _currentSessionId = sessionId;
    final dbMessages = await DatabaseHelper.instance.getSessionMessages(sessionId);
    _messages.clear();
    for (var msg in dbMessages) {
      _messages.add({
        'role': msg['sender'] == 'assistant' ? 'assistant' : 'user',
        'content': msg['message'],
        'image': msg['image_path']
      });
    }
    _formData.clear();
    final savedData = await DatabaseHelper.instance.getSessionFormData(sessionId);
    savedData.forEach((key, value) => _formData[key] = value.toString());
    _isLoading = false;
    notifyListeners();
  }

  Future<void> _addMessageAndLog(String role, String content, {String? imagePath}) async {
    if (_currentSessionId == null) return;
    _messages.add({'role': role, 'content': content, 'image': imagePath});
    await DatabaseHelper.instance.logMessage(_currentSessionId!, role, content, imagePath: imagePath);
    notifyListeners();
  }

  Future<void> sendMessage(String text, int userId, {String? imagePath, String? token}) async {
    if (text.isEmpty && imagePath == null) return;
    if (_currentSessionId == null) await startNewSession(userId);

    if (_messages.length <= 1) {
      String newTitle = text.length > 15 ? "${text.substring(0, 15)}..." : text;
      if (newTitle.isEmpty) newTitle = "图片对话";
      await DatabaseHelper.instance.updateSessionTitle(_currentSessionId!, newTitle);
      await loadSessions(userId);
    }

    await _addMessageAndLog('user', text, imagePath: imagePath);
    _isLoading = true;
    notifyListeners();

    String? base64Image;
    if (imagePath != null) {
      final bytes = await File(imagePath).readAsBytes();
      base64Image = base64Encode(bytes);
    }

    try {
      List<Map<String, dynamic>> history = _messages
          .where((m) => m['role'] != 'system' && m['image'] == null)
          .map((m) => {'role': m['role'], 'content': m['content']})
          .toList();

      final rawResponse = await _aiService.sendMessage(history, text, base64Image, token: token);
      final transferData = _aiService.extractHumanTransferData(rawResponse);
      if (transferData != null) {
        _isTransferred = true;
        await _addMessageAndLog('assistant', transferData['message'] ?? '正在为您转接人工客服...');
        _isLoading = false;
        notifyListeners();
        return;
      }

      final extractedData = _aiService.extractFormData(rawResponse);
      if (extractedData != null) {
        _updateFormData(extractedData);
        if (_formData.containsKey('sf_tracking_number')) {
          await DatabaseHelper.instance.submitSampleRequest(userId, _currentSessionId!, _formData);
        }
      }
      await _addMessageAndLog('assistant', _aiService.cleanResponse(rawResponse));
    } catch (e) {
      _messages.add({'role': 'system', 'content': 'Error: $e'});
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  void _updateFormData(Map<String, dynamic> data) async {
    bool hasChanged = false;

    // 1. 模糊匹配测试目的 (支持: 测试目的, 检测目的, 测试项目)
    final purpose = data['测试目的'] ?? data['检测目的'] ?? data['测试项目'];
    if (purpose != null) {
      _formData['test_purpose'] = purpose.toString();
      hasChanged = true;
    }

    // 2. 模糊匹配样品性状 (支持: 样品性状, 样品状态, 样品描述)
    final shape = data['样品性状'] ?? data['样品状态'] ?? data['样品描述'];
    if (shape != null) {
      _formData['sample_shape'] = shape.toString();
      hasChanged = true;
    }

    // 3. 模糊匹配测试要求 (支持: 测试要求, 检测要求, 实验要求)
    final reqs = data['测试要求'] ?? data['检测要求'] ?? data['实验要求'];
    if (reqs != null) {
      _formData['test_requirements'] = reqs.toString();
      hasChanged = true;
    }

    // 4. 地址信息
    final addr = data['客户联系方式和地址'] ?? data['联系方式'] ?? data['地址'];
    if (addr != null) {
      _formData['customer_address'] = addr.toString();
      hasChanged = true;
    }

    // 5. 顺丰单号
    final sf = data['顺丰单号'] ?? data['快递单号'] ?? data['单号'];
    if (sf != null) {
      _formData['sf_tracking_number'] = sf.toString();
      hasChanged = true;
    }

    if (hasChanged) {
      // 实时保存到本地数据库
      if (_currentSessionId != null) {
        await DatabaseHelper.instance.updateSessionFormData(_currentSessionId!, _formData);
      }
      notifyListeners(); // 强制刷新 UI
    }
  }

  void clear() {
    _messages.clear();
    _formData.clear();
    _sessions = [];
    _currentSessionId = null;
    _isLoading = false;
    notifyListeners();
  }
}

// --- UI Screens ---

class AuthCheck extends StatelessWidget {
  const AuthCheck({super.key});
  @override
  Widget build(BuildContext context) {
    final user = context.watch<AuthProvider>().user;
    if (user == null) return const LoginScreen();
    return const DesktopMainScreen();
  }
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final _mobileCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  final _newPassCtrl = TextEditingController();
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  void _showMsg(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  Future<void> _handleLogin() async {
    if (_mobileCtrl.text.isEmpty || _passCtrl.text.isEmpty) {
      _showMsg("请输入手机号和密码");
      return;
    }
    setState(() => _isSubmitting = true);
    final success = await context.read<AuthProvider>().login(_mobileCtrl.text, _passCtrl.text);
    setState(() => _isSubmitting = false);
    if (!success) {
      _showMsg("登录失败，请检查账号密码");
    }
  }

  Future<void> _handleRegister() async {
    if (_mobileCtrl.text.isEmpty || _passCtrl.text.isEmpty || _codeCtrl.text.isEmpty) {
      _showMsg("请完善注册信息");
      return;
    }
    setState(() => _isSubmitting = true);
    final success = await context.read<AuthProvider>().register(_mobileCtrl.text, _passCtrl.text, _codeCtrl.text);
    setState(() => _isSubmitting = false);
    if (success) {
      _showMsg("注册成功并已登录");
    } else {
      _showMsg("注册失败，请检查验证码或手机号");
    }
  }

  Future<void> _handleReset() async {
    if (_mobileCtrl.text.isEmpty || _codeCtrl.text.isEmpty || _newPassCtrl.text.isEmpty) {
      _showMsg("请完善重置信息");
      return;
    }
    setState(() => _isSubmitting = true);
    final success = await context.read<AuthProvider>().resetPassword(_mobileCtrl.text, _codeCtrl.text, _newPassCtrl.text);
    setState(() => _isSubmitting = false);
    if (success) {
      _showMsg("密码重置成功，请尝试登录");
      _tabController.animateTo(0);
    } else {
      _showMsg("重置失败，请检查验证码");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[100],
      body: Center(
        child: Container(
          width: 400,
          padding: const EdgeInsets.all(30),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 10)],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text("常来测 - 智能桌面端", style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
              const SizedBox(height: 20),
              TabBar(
                controller: _tabController,
                labelColor: Colors.blue,
                unselectedLabelColor: Colors.grey,
                tabs: const [Tab(text: "登录"), Tab(text: "注册"), Tab(text: "找回密码")],
              ),
              const SizedBox(height: 20),
              if (_isSubmitting) const LinearProgressIndicator(),
              SizedBox(
                height: 350,
                child: TabBarView(
                  controller: _tabController,
                  children: [
                    _buildLoginForm(),
                    _buildRegisterForm(),
                    _buildResetForm(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLoginForm() {
    return Column(
      children: [
        TextField(controller: _mobileCtrl, decoration: const InputDecoration(labelText: "手机号", prefixIcon: Icon(Icons.phone))),
        TextField(controller: _passCtrl, decoration: const InputDecoration(labelText: "密码", prefixIcon: Icon(Icons.lock)), obscureText: true),
        const SizedBox(height: 30),
        ElevatedButton(
          onPressed: _isSubmitting ? null : _handleLogin,
          style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 50)),
          child: Text(_isSubmitting ? "正在登录..." : "立即登录"),
        ),
      ],
    );
  }

  Widget _buildRegisterForm() {
    return Column(
      children: [
        TextField(controller: _mobileCtrl, decoration: const InputDecoration(labelText: "手机号", prefixIcon: Icon(Icons.phone))),
        Row(
          children: [
            Expanded(child: TextField(controller: _codeCtrl, decoration: const InputDecoration(labelText: "验证码", prefixIcon: Icon(Icons.message)))),
            const SizedBox(width: 10),
            CountDownButton(
              mobileCtrl: _mobileCtrl,
              onSent: (code) {
                _showMsg("验证码已发送: $code");
                if (code.isNotEmpty) _codeCtrl.text = code;
              },
            )
          ],
        ),
        TextField(controller: _passCtrl, decoration: const InputDecoration(labelText: "设置密码", prefixIcon: Icon(Icons.lock)), obscureText: true),
        const SizedBox(height: 30),
        ElevatedButton(
          onPressed: _isSubmitting ? null : _handleRegister,
          style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 50)),
          child: Text(_isSubmitting ? "正在注册..." : "注册并登录"),
        ),
      ],
    );
  }

  Widget _buildResetForm() {
    return Column(
      children: [
        TextField(controller: _mobileCtrl, decoration: const InputDecoration(labelText: "手机号", prefixIcon: Icon(Icons.phone))),
        Row(
          children: [
            Expanded(child: TextField(controller: _codeCtrl, decoration: const InputDecoration(labelText: "验证码", prefixIcon: Icon(Icons.message)))),
            const SizedBox(width: 10),
            CountDownButton(
              mobileCtrl: _mobileCtrl,
              onSent: (code) {
                _showMsg("验证码已发送: $code");
                if (code.isNotEmpty) _codeCtrl.text = code;
              },
            )
          ],
        ),
        TextField(controller: _newPassCtrl, decoration: const InputDecoration(labelText: "新密码", prefixIcon: Icon(Icons.lock)), obscureText: true),
        const SizedBox(height: 30),
        ElevatedButton(
          onPressed: _isSubmitting ? null : _handleReset,
          style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 50)),
          child: Text(_isSubmitting ? "正在重置..." : "重置密码"),
        ),
      ],
    );
  }
}

class CountDownButton extends StatefulWidget {
  final TextEditingController mobileCtrl;
  final Function(String) onSent;
  const CountDownButton({super.key, required this.mobileCtrl, required this.onSent});
  @override
  State<CountDownButton> createState() => _CountDownButtonState();
}

class _CountDownButtonState extends State<CountDownButton> {
  int _seconds = 0;
  Timer? _timer;

  void _startTimer() {
    setState(() => _seconds = 60);
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_seconds > 0) setState(() => _seconds--);
      else _timer?.cancel();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ElevatedButton(
      onPressed: _seconds > 0 ? null : () async {
        final mobile = widget.mobileCtrl.text.trim();
        if (mobile.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("请输入手机号")));
          return;
        }
        _startTimer();
        try {
          final code = await context.read<AuthProvider>().sendCode(mobile);
          widget.onSent(code);
        } catch (e) {
          if (mounted) {
            _timer?.cancel();
            setState(() => _seconds = 0);
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
          }
        }
      },
      child: Text(_seconds > 0 ? "${_seconds}s" : "获取验证码"),
    );
  }
}

class DesktopMainScreen extends StatefulWidget {
  const DesktopMainScreen({super.key});
  @override
  State<DesktopMainScreen> createState() => _DesktopMainScreenState();
}

class _DesktopMainScreenState extends State<DesktopMainScreen> {
  final _textCtrl = TextEditingController();
  final ImagePicker _picker = ImagePicker();
  String? _selectedImagePath;
  bool _isSidebarExpanded = false; // 控制侧边栏展开状态

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final user = context.read<AuthProvider>().user;
      if (user != null) {
        context.read<ChatProvider>().loadSessions(user['id']).then((_) {
          if (context.read<ChatProvider>().currentSessionId == null) {
            context.read<ChatProvider>().startNewSession(user['id']);
          }
        });
      }
    });
  }

  void _send() {
    final user = context.read<AuthProvider>().user;
    if (user == null) return;
    context.read<ChatProvider>().sendMessage(_textCtrl.text, user['id'], imagePath: _selectedImagePath, token: user['token']);
    _textCtrl.clear();
    setState(() => _selectedImagePath = null);
  }

  @override
  Widget build(BuildContext context) {
    final chatProvider = context.watch<ChatProvider>();
    final user = context.read<AuthProvider>().user;

    return Scaffold(
      body: Row(
        children: [
          // 左侧栏：可折叠的历史记录
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            width: _isSidebarExpanded ? 200 : 60,
            color: const Color(0xFFF8F9FA),
            child: Column(
              children: [
                // 顶部汉堡菜单按钮
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 15),
                  child: IconButton(
                    icon: const Icon(Icons.menu, color: Colors.black87),
                    onPressed: () => setState(() => _isSidebarExpanded = !_isSidebarExpanded),
                  ),
                ),
                // “新建对话”按钮/图标
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Tooltip(
                    message: "新建对话",
                    child: InkWell(
                      onTap: () => chatProvider.startNewSession(user!['id']),
                      borderRadius: BorderRadius.circular(10),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 300),
                        padding: EdgeInsets.symmetric(vertical: 10, horizontal: _isSidebarExpanded ? 16 : 0),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(10),
                          boxShadow: [
                            BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 10),
                          ],
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.add, size: 20, color: Colors.blue),
                            if (_isSidebarExpanded) ...[
                              const SizedBox(width: 12),
                              const Text("新建对话", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                            ]
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                if (_isSidebarExpanded)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text("最近通话", style: TextStyle(fontSize: 11, color: Colors.grey, fontWeight: FontWeight.bold)),
                    ),
                  ),
                // 历史列表
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    itemCount: chatProvider.sessions.length,
                    itemBuilder: (ctx, i) {
                      final s = chatProvider.sessions[i];
                      final active = s['id'] == chatProvider.currentSessionId;
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Tooltip(
                          message: _isSidebarExpanded ? "" : (s['title'] ?? "未命名"),
                          child: InkWell(
                            onTap: () => chatProvider.switchSession(s['id']),
                            borderRadius: BorderRadius.circular(8),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 300),
                              padding: EdgeInsets.symmetric(vertical: 10, horizontal: _isSidebarExpanded ? 12 : 0),
                              decoration: BoxDecoration(
                                color: active ? Colors.white : Colors.transparent,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: active ? Colors.blue.withOpacity(0.2) : Colors.transparent),
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(active ? Icons.chat_bubble : Icons.chat_bubble_outline, 
                                       size: 18, color: active ? Colors.blue : Colors.grey[600]),
                                  if (_isSidebarExpanded) ...[
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Text(
                                        s['title'] ?? "未命名",
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 13,
                                          fontWeight: active ? FontWeight.bold : FontWeight.normal,
                                          color: active ? Colors.blue[700] : Colors.black87,
                                        ),
                                      ),
                                    ),
                                  ]
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Padding(
                    padding: EdgeInsets.only(left: 20),
                    child: Icon(Icons.logout, size: 20),
                  ),
                  title: _isSidebarExpanded ? const Text("退出登录", style: TextStyle(fontSize: 13)) : null,
                  onTap: () {
                    context.read<ChatProvider>().clear();
                    context.read<AuthProvider>().logout();
                  },
                ),
                const SizedBox(height: 10),
              ],
            ),
          ),
          // 中间栏：聊天内容
          Expanded(
            child: Column(
              children: [
                AppBar(
                  title: Text(chatProvider.sessions.firstWhere((s)=>s['id']==chatProvider.currentSessionId, orElse: ()=>({'title':'对话'}))['title'] ?? "对话", style: const TextStyle(fontSize: 18)), 
                  elevation: 0.5,
                  centerTitle: true,
                ),
                Expanded(
                  child: Container(
                    color: Colors.grey[50],
                    child: ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 20),
                      itemCount: chatProvider.messages.length,
                      itemBuilder: (ctx, i) {
                        final msg = chatProvider.messages[i];
                        final isUser = msg['role'] == 'user';
                        return Align(
                          alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
                          child: Container(
                            margin: const EdgeInsets.symmetric(vertical: 8),
                            padding: const EdgeInsets.all(12),
                            constraints: BoxConstraints(
                              maxWidth: MediaQuery.of(context).size.width * 0.6, // 最大占用中间区域的60%
                            ),
                            decoration: BoxDecoration(
                              color: isUser ? Colors.blue[100] : Colors.white,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: Colors.grey[200]!),
                              boxShadow: [
                                if (!isUser) BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 5, offset: const Offset(0, 2))
                              ],
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (msg['image'] != null) 
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 8.0),
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(8),
                                      child: Image.file(File(msg['image']), height: 200, fit: BoxFit.cover),
                                    ),
                                  ),
                                SelectableText(msg['content'], style: const TextStyle(height: 1.5)),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                if (chatProvider.isLoading) const LinearProgressIndicator(),
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(color: Colors.white, border: Border(top: BorderSide(color: Colors.grey[200]!))),
                  child: Center(
                    child: Container(
                      constraints: const BoxConstraints(maxWidth: 900), // 限制输入框最大宽度
                      child: Row(
                        children: [
                          IconButton(icon: const Icon(Icons.image_outlined), onPressed: () async {
                            final img = await _picker.pickImage(source: ImageSource.gallery);
                            if (img != null) setState(() => _selectedImagePath = img.path);
                          }),
                          Expanded(
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 15),
                              decoration: BoxDecoration(
                                color: Colors.grey[100],
                                borderRadius: BorderRadius.circular(25),
                              ),
                              child: TextField(
                                controller: _textCtrl,
                                decoration: const InputDecoration(hintText: "请输入您的问题...", border: InputBorder.none),
                                onSubmitted: (_) => _send(),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          IconButton(icon: const Icon(Icons.send, color: Colors.blue), onPressed: _send),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // 右侧栏：表单信息
          Container(
            width: 220,
            decoration: BoxDecoration(border: Border(left: BorderSide(color: Colors.grey[200]!)), color: Colors.white),
            child: const FormStatusPanel(),
          ),
        ],
      ),
    );
  }
}

class FormStatusPanel extends StatelessWidget {
  const FormStatusPanel({super.key});
  @override
  Widget build(BuildContext context) {
    final formData = context.watch<ChatProvider>().formData;
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("当前送样进度", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const Divider(height: 30),
          _item("测试目的", formData['test_purpose']),
          _item("样品性状", formData['sample_shape']),
          _item("测试要求", formData['test_requirements']),
          _item("收货信息", formData['customer_address']),
          const Spacer(),
          Container(
            padding: const EdgeInsets.all(15),
            decoration: BoxDecoration(color: Colors.blue[50], borderRadius: BorderRadius.circular(8)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text("物流单号", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blue)),
                const SizedBox(height: 5),
                Text(formData['sf_tracking_number'] ?? "尚未识别到单号", style: const TextStyle(fontSize: 16)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _item(String label, String? value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: Colors.grey, fontSize: 12)),
          const SizedBox(height: 4),
          Text(value ?? "待完善...", style: TextStyle(color: value == null ? Colors.grey : Colors.black, fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }
}
