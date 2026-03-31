import 'dart:convert';
import 'package:http/http.dart' as http;

class AIService {
  // TODO: 请将 localhost 替换为你的阿里云服务器公网 IP
  // 如果在 Android 模拟器运行，本地服务器请使用 http://10.0.2.2:8000/chat
  // 如果在 iOS 模拟器运行，本地服务器请使用 http://127.0.0.1:8000/chat
  static const String apiUrl = "https://changlaice.cczu.edu.cn/chat";
  // 修改为你的 HTTPS 域名。注意：不再需要写端口号，且必须以 https:// 开头,后边也需要改

  // System Prompt 现在由服务器端管理，客户端不需要知道

  Future<String> sendMessage(List<Map<String, dynamic>> history,
      String userMessage, String? base64Image,
      {String? token}) async {
    final headers = {
      'Content-Type': 'application/json',
    };

    if (token != null) {
      headers['Authorization'] = 'Bearer $token';
    }

    // 构建符合 Python 服务器 ChatRequest 模型的请求体
    // class ChatRequest(BaseModel):
    //    session_id: Optional[int] = None
    //    message: str
    //    history: List[Dict[str, Any]] = []
    //    base64_image: Optional[str] = None

    final body = {
      'message': userMessage,
      'history': history,
      'base64_image': base64Image,
      'source': 'app', // 明确标识请求来自 App 端
    };

    try {
      final response = await http.post(
        Uri.parse(apiUrl),
        headers: headers,
        body: jsonEncode(body),
      );

      if (response.statusCode == 200) {
        // 服务器返回格式: {"response": "...", "session_id": 123}
        final data = jsonDecode(utf8.decode(response.bodyBytes));
        return data['response'];
      } else if (response.statusCode == 401) {
        throw Exception('认证失效，请重新登录');
      } else {
        throw Exception('服务器错误: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('网络连接失败: $e');
    }
  }

  // 客户端仍然保留这些辅助函数，用于在 UI 上隐藏 JSON 数据
  // 虽然服务器已经拦截并存储了数据，但 AI 的回复可能仍然包含 <form_data> 标签
  // 这里的逻辑可以保持不变，用于清洗显示给用户的文本
  Map<String, dynamic>? extractFormData(String aiResponse) {
    const startTag = "<form_data>";
    const endTag = "</form_data>";

    final startIndex = aiResponse.indexOf(startTag);
    final endIndex = aiResponse.indexOf(endTag);

    if (startIndex != -1 && endIndex != -1) {
      final jsonStr =
          aiResponse.substring(startIndex + startTag.length, endIndex).trim();
      try {
        return jsonDecode(jsonStr);
      } catch (e) {
        print("JSON Parse Error: $e");
      }
    }
    return null;
  }

  String cleanResponse(String aiResponse) {
    const startTag = "<form_data>";
    const endTag = "</form_data>";
    const transferStartTag = "<transfer_to_human>";
    const transferEndTag = "</transfer_to_human>";

    String cleaned = aiResponse;

    final formStartIndex = cleaned.indexOf(startTag);
    final formEndIndex = cleaned.indexOf(endTag);
    if (formStartIndex != -1 && formEndIndex != -1) {
      cleaned = cleaned.replaceRange(formStartIndex, formEndIndex + endTag.length, "").trim();
    }
    
    final transferStartIndex = cleaned.indexOf(transferStartTag);
    final transferEndIndex = cleaned.indexOf(transferEndTag);
    if (transferStartIndex != -1 && transferEndIndex != -1) {
        cleaned = cleaned.replaceRange(transferStartIndex, transferEndIndex + transferEndTag.length, "").trim();
    }

    return cleaned;
  }

  Map<String, dynamic>? extractHumanTransferData(String aiResponse) {
    const startTag = "<transfer_to_human>";
    const endTag = "</transfer_to_human>";

    final startIndex = aiResponse.indexOf(startTag);
    final endIndex = aiResponse.indexOf(endTag);

    if (startIndex != -1 && endIndex != -1) {
      final jsonStr =
          aiResponse.substring(startIndex + startTag.length, endIndex).trim();
      try {
        return jsonDecode(jsonStr);
      } catch (e) {
        print("JSON Parse Error (transfer_to_human): $e");
      }
    }
    return null;
  }

  // --- 认证接口 ---
  Future<String> sendCode(String mobile) async {
    final response = await http.post(
      Uri.parse(apiUrl.replaceAll("/chat", "/auth/send-code")),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'mobile': mobile}),
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      // 测试阶段返回 debug_code，方便自动填充
      return data['debug_code'] ?? "";
    } else {
      throw Exception('发送验证码失败: ${response.body}');
    }
  }

  Future<void> resetPassword(
      String mobile, String code, String newPassword) async {
    final response = await http.post(
      Uri.parse(apiUrl.replaceAll("/chat", "/auth/reset-password")),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(
          {'mobile': mobile, 'code': code, 'new_password': newPassword}),
    );

    if (response.statusCode != 200) {
      throw Exception('重置密码失败: ${response.body}');
    }
  }

  Future<Map<String, dynamic>> register(
      String mobile, String password, String code) async {
    final response = await http.post(
      Uri.parse(apiUrl.replaceAll("/chat", "/register")),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'mobile': mobile, 'password': password, 'code': code}),
    );

    if (response.statusCode == 200) {
      return jsonDecode(response.body);
    } else {
      throw Exception('注册失败: ${response.body}');
    }
  }

  Future<Map<String, dynamic>> login(String mobile, String password) async {
    // FastAPI OAuth2PasswordRequestForm expects form-data, not json usually,
    // but in our server code we used OAuth2PasswordRequestForm which expects x-www-form-urlencoded
    // Let's check server main.py again. Yes, it uses OAuth2PasswordRequestForm.

    final response = await http.post(
      Uri.parse(apiUrl.replaceAll("/chat", "/token")),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: {
        'username': mobile, // OAuth2 standard field for login
        'password': password
      },
    );

    if (response.statusCode == 200) {
      return jsonDecode(response.body);
    } else {
      throw Exception('登录失败: ${response.body}');
    }
  }
}
