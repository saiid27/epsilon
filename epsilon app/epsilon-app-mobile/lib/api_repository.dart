import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class ApiException implements Exception {
  const ApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

class ApiRepository {
  ApiRepository({String? baseUrl})
    : baseUrl = baseUrl ?? const String.fromEnvironment(
        'EPSILON_API_URL',
        defaultValue: 'https://epsilon-app.onrender.com',
      );

  final String baseUrl;
  static const _tokenKey = 'epsilon_api_token';
  String? _token;

  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    _token = prefs.getString(_tokenKey);
  }

  Future<Map<String, dynamic>?> currentUser() async {
    if (_token == null) {
      return null;
    }
    try {
      final data = await get('/api/me');
      return data['user'] as Map<String, dynamic>?;
    } on Object {
      await signOut();
      return null;
    }
  }

  Future<Map<String, dynamic>> signIn({
    required String email,
    required String password,
  }) async {
    final data = await post('/api/auth/login', {
      'identifier': email.trim(),
      'email': email.trim(),
      'password': password,
    }, authenticated: false);
    final token = data['token'] as String?;
    if (token == null || token.isEmpty) {
      throw const ApiException('Login did not return a token.');
    }
    _token = token;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, token);
    return data['user'] as Map<String, dynamic>;
  }

  Future<void> signOut() async {
    _token = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
  }

  Future<Map<String, dynamic>> get(String path) async {
    final response = await http.get(_uri(path), headers: _headers());
    return _decode(response);
  }

  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> body, {
    bool authenticated = true,
  }) async {
    final response = await http.post(
      _uri(path),
      headers: _headers(authenticated: authenticated),
      body: jsonEncode(body),
    );
    return _decode(response);
  }

  Future<Map<String, dynamic>> patch(
    String path,
    Map<String, dynamic> body,
  ) async {
    final response = await http.patch(
      _uri(path),
      headers: _headers(),
      body: jsonEncode(body),
    );
    return _decode(response);
  }

  Future<Map<String, dynamic>> delete(String path) async {
    final response = await http.delete(_uri(path), headers: _headers());
    return _decode(response);
  }

  Future<Map<String, dynamic>> registerStudent({
    required String name,
    required String email,
    required String password,
    required String courseId,
    required String paymentSenderPhone,
  }) {
    return post('/api/auth/register-student', {
      'name': name,
      'email': email,
      'phone': email,
      'password': password,
      'courseId': courseId,
      'paymentSenderPhone': paymentSenderPhone,
    }, authenticated: false);
  }

  Future<Map<String, dynamic>> createUser({
    required String name,
    required String email,
    required String password,
    required String role,
    required String courseId,
    String? subject,
  }) {
    return post('/api/admin/users', {
      'name': name,
      'email': email,
      'phone': email,
      'password': password,
      'role': role,
      'courseId': courseId,
      'classId': courseId,
      'level': courseId,
      'subject': subject,
      'status': role == 'student' ? 'active' : 'active',
    });
  }

  Future<void> updateAccountStatus(String uid, String status) async {
    await patch('/api/users/$uid/status', {'status': status});
  }

  Future<void> deleteUserAccount(String uid) async {
    await delete('/api/users/$uid');
  }

  Future<void> createCourse({
    required String title,
    required String classId,
    required String description,
    required String price,
    required List<String> subjects,
  }) async {
    await post('/api/courses', {
      'title': title,
      'classId': classId,
      'description': description,
      'price': price,
      'subjects': subjects,
    });
  }

  Future<void> deleteCourse(String courseId) async {
    await delete('/api/courses/$courseId');
  }

  Future<void> createLesson({
    required String title,
    required String url,
    required String classId,
    required String courseId,
    required String subject,
  }) async {
    await post('/api/lessons', {
      'title': title,
      'url': url,
      'classId': classId,
      'courseId': courseId,
      'level': classId,
      'subject': subject,
    });
  }

  Future<void> updateLesson({
    required String lessonId,
    required String title,
    required String url,
  }) async {
    await patch('/api/lessons/$lessonId', {'title': title, 'url': url});
  }

  Future<void> deleteLesson(String lessonId) async {
    await delete('/api/lessons/$lessonId');
  }

  Future<void> addNotification({required String title, required String body}) async {
    await post('/api/notifications', {'title': title, 'body': body});
  }

  Uri _uri(String path) {
    final root = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    return Uri.parse('$root$path');
  }

  Map<String, String> _headers({bool authenticated = true}) {
    final headers = {HttpHeaders.contentTypeHeader: 'application/json'};
    if (authenticated && _token != null) {
      headers[HttpHeaders.authorizationHeader] = 'Bearer $_token';
    }
    return headers;
  }

  Map<String, dynamic> _decode(http.Response response) {
    final decoded = response.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final message =
          decoded['message'] as String? ??
          decoded['error'] as String? ??
          'Request failed with status ${response.statusCode}.';
      throw ApiException(message);
    }
    return decoded;
  }
}
