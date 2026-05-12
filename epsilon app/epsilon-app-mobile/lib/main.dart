import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'api_repository.dart';
import 'firebase_options.dart';
import 'firebase_schema.dart';

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final firebaseStatus = await FirebaseBootstrap.initialize();
  runApp(EpsilonApp(firebaseStatus: firebaseStatus));
}

class FirebaseBootstrap {
  const FirebaseBootstrap({required this.isReady, this.errorMessage});

  final bool isReady;
  final String? errorMessage;

  static Future<FirebaseBootstrap> initialize() async {
    return const FirebaseBootstrap(isReady: true);
  }
}

class PushNotifications {
  const PushNotifications._();

  static const AndroidNotificationChannel _androidChannel =
      AndroidNotificationChannel(
        'epsilon_notifications',
        'إشعارات Epsilon',
        description: 'إشعارات الإدارة والدروس الجديدة',
        importance: Importance.high,
        playSound: true,
      );

  static final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();

  static Future<void> initialize() async {
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );

    await _localNotifications.initialize(
      settings: const InitializationSettings(
        android: androidSettings,
        iOS: iosSettings,
      ),
    );

    final androidNotifications = _localNotifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await androidNotifications?.createNotificationChannel(_androidChannel);
    await androidNotifications?.requestNotificationsPermission();

    final messaging = FirebaseMessaging.instance;
    await messaging.requestPermission(alert: true, badge: true, sound: true);
    await messaging.setForegroundNotificationPresentationOptions(
      alert: true,
      badge: true,
      sound: true,
    );
    await messaging.subscribeToTopic('all_users');

    FirebaseMessaging.onMessage.listen(_showForegroundNotification);
  }

  static Future<void> _showForegroundNotification(RemoteMessage message) async {
    final title = message.notification?.title ?? message.data['title'];
    final body = message.notification?.body ?? message.data['body'];

    if (title == null && body == null) {
      return;
    }

    await _localNotifications.show(
      id: message.messageId.hashCode,
      title: title ?? 'إشعار جديد',
      body: body ?? '',
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          _androidChannel.id,
          _androidChannel.name,
          channelDescription: _androidChannel.description,
          importance: Importance.high,
          priority: Priority.high,
          playSound: true,
        ),
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
    );
  }

  static Future<void> showLocalNotification({
    required String id,
    required String title,
    required String body,
  }) async {
    await _localNotifications.show(
      id: id.hashCode,
      title: title,
      body: body,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          _androidChannel.id,
          _androidChannel.name,
          channelDescription: _androidChannel.description,
          importance: Importance.high,
          priority: Priority.high,
          playSound: true,
        ),
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
    );
  }
}

String friendlyFirebaseError(Object error) {
  final text = error.toString().toLowerCase();

  if (text.contains('unauthenticated') || text.contains('not-signed-in')) {
    return 'انتهت جلسة الإدارة. سجل الخروج ثم ادخل من جديد وحاول مرة أخرى.';
  }
  if (text.contains('permission-denied')) {
    return 'هذا الحساب لا يملك صلاحية الإدارة.';
  }
  if (text.contains('email-already-exists') ||
      text.contains('email-already-in-use')) {
    return 'هذا البريد مستخدم مسبقا.';
  }
  if (text.contains('invalid-email')) {
    return 'البريد الإلكتروني غير صحيح.';
  }
  if (text.contains('weak-password')) {
    return 'كلمة المرور ضعيفة. اختر كلمة مرور أقوى.';
  }
  if (text.contains('network') || text.contains('unavailable')) {
    return 'تحقق من الاتصال بالإنترنت ثم حاول مرة أخرى.';
  }

  return 'حدث خطأ أثناء العملية. حاول مرة أخرى.';
}

enum UserRole { admin, teacher, student }

enum AccountStatus { pending, active, blocked, rejected }

class AppUser {
  AppUser({
    required this.id,
    required this.name,
    required this.email,
    required this.password,
    required this.role,
    required this.status,
    this.classId,
    this.courseId,
    this.subject,
    this.paymentProofPath,
    this.paymentSenderPhone,
    this.activeDeviceId,
  });

  final String id;
  final String name;
  final String email;
  final String password;
  final UserRole role;
  AccountStatus status;
  String? classId;
  String? courseId;
  String? subject;
  String? paymentProofPath;
  String? paymentSenderPhone;
  String? activeDeviceId;
}

class SchoolClass {
  const SchoolClass({
    required this.id,
    required this.name,
    required this.level,
  });

  final String id;
  final String name;
  final String level;
}

class Course {
  Course({
    required this.id,
    required this.title,
    required this.classId,
    this.description = 'دروس وتمارين وملخصات منظمة للطلاب',
    this.price = '',
    List<String>? subjects,
    this.isActive = true,
  }) : subjects = subjects ?? const ['الرياضيات', 'الفيزياء', 'الكيمياء'];

  final String id;
  final String title;
  final String classId;
  String description;
  String price;
  List<String> subjects;
  bool isActive;
}

class Lesson {
  Lesson({
    required this.id,
    required this.title,
    required this.url,
    required this.teacherId,
    required this.classId,
    required this.courseId,
    required this.subject,
    required this.createdAt,
    this.isPublished = true,
  });

  final String id;
  String title;
  String url;
  final String teacherId;
  String classId;
  String courseId;
  final String subject;
  final DateTime createdAt;
  bool isPublished;
}

class GuestContentItem {
  GuestContentItem({
    required this.id,
    required this.title,
    required this.url,
    this.description = '',
    this.courseId,
    required this.createdAt,
  });

  final String id;
  String title;
  String url;
  String description;
  String? courseId;
  final DateTime createdAt;
}

class AppNotification {
  const AppNotification({
    required this.id,
    required this.title,
    required this.body,
    required this.createdAt,
  });

  final String id;
  final String title;
  final String body;
  final DateTime createdAt;
}

class SchoolStore extends ChangeNotifier {
  SchoolStore({required this.firebaseEnabled}) {
    unawaited(_loadReadNotifications());
    if (firebaseEnabled) {
      _repository = ApiRepository();
      unawaited(_bindApi());
    } else {
      _seed();
    }
  }

  final bool firebaseEnabled;
  dynamic _repository;
  final List<StreamSubscription<Object?>> _subscriptions = [];
  StreamSubscription<Object?>? _usersSubscription;
  StreamSubscription<Object?>? _currentUserSubscription;
  StreamSubscription<Object?>? _coursesSubscription;
  StreamSubscription<Object?>? _lessonsSubscription;
  StreamSubscription<Object?>? _guestVideosSubscription;
  StreamSubscription<Object?>? _archiveFilesSubscription;
  final List<SchoolClass> classes = [];
  final List<Course> courses = [];
  final List<Lesson> lessons = [];
  final List<GuestContentItem> guestVideos = [];
  final List<GuestContentItem> archiveFiles = [];
  final List<AppUser> users = [];
  final List<AppNotification> notifications = [];
  final Set<String> readNotificationIds = {};
  String paymentNumber = '22334455';
  String paymentAmount = 'غير محدد';
  ThemeMode themeMode = ThemeMode.light;
  String languageCode = 'ar';
  AppUser? currentUser;
  bool isLoading = false;
  bool _claimingStudentDevice = false;
  bool _notificationsLoadedOnce = false;
  String? lastError;

  static const _readNotificationsKey = 'epsilon_read_notification_ids';

  int get unreadNotificationCount => notifications
      .where((notification) => !readNotificationIds.contains(notification.id))
      .length;

  Future<void> _loadReadNotifications() async {
    final prefs = await SharedPreferences.getInstance();
    readNotificationIds
      ..clear()
      ..addAll(prefs.getStringList(_readNotificationsKey) ?? const []);
    notifyListeners();
  }

  Future<void> markNotificationsRead() async {
    if (notifications.isEmpty) {
      return;
    }

    readNotificationIds.addAll(
      notifications.map((notification) => notification.id),
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _readNotificationsKey,
      readNotificationIds.toList(),
    );
    notifyListeners();
  }

  String get defaultClassId {
    if (classes.isEmpty) {
      if (firebaseEnabled) {
        return 'default';
      }
      createClass(name: 'عام', level: 'كل المستويات');
    }
    return classes.first.id;
  }

  // ignore: unused_element
  void _bindFirebase() {
    final repository = _repository!;
    _listenToPublicCourses();
    _listenToGuestContent();

    _subscriptions.add(
      repository.auth.authStateChanges().listen((firebaseUser) async {
        if (firebaseUser == null) {
          currentUser = null;
          users.clear();
          unawaited(_usersSubscription?.cancel() ?? Future<void>.value());
          unawaited(_currentUserSubscription?.cancel() ?? Future<void>.value());
          unawaited(_coursesSubscription?.cancel() ?? Future<void>.value());
          unawaited(_lessonsSubscription?.cancel() ?? Future<void>.value());
          _usersSubscription = null;
          _currentUserSubscription = null;
          _coursesSubscription = null;
          _lessonsSubscription = null;
          lessons.clear();
          _listenToPublicCourses();
          notifyListeners();
          return;
        }

        final snapshot = await repository.users.doc(firebaseUser.uid).get();
        if (!snapshot.exists) {
          currentUser = null;
          users.clear();
          unawaited(_usersSubscription?.cancel() ?? Future<void>.value());
          unawaited(_currentUserSubscription?.cancel() ?? Future<void>.value());
          unawaited(_coursesSubscription?.cancel() ?? Future<void>.value());
          unawaited(_lessonsSubscription?.cancel() ?? Future<void>.value());
          _usersSubscription = null;
          _currentUserSubscription = null;
          _coursesSubscription = null;
          _lessonsSubscription = null;
          notifyListeners();
          return;
        }

        currentUser = _userFromDoc(snapshot);
        if (currentUser?.role == UserRole.admin) {
          unawaited(_currentUserSubscription?.cancel() ?? Future<void>.value());
          _currentUserSubscription = null;
          _listenToAllUsers();
        } else {
          unawaited(_usersSubscription?.cancel() ?? Future<void>.value());
          _usersSubscription = null;
          _listenToCurrentUser(firebaseUser.uid);
        }
        _listenToCoursesAndLessons(currentUser!);
        notifyListeners();
      }),
    );

    _subscriptions.add(
      repository.classes.snapshots().listen((snapshot) {
        classes
          ..clear()
          ..addAll(snapshot.docs.map(_classFromDoc));
        notifyListeners();
      }, onError: _rememberError),
    );

    _subscriptions.add(
      repository.notifications
          .orderBy(NotificationFields.createdAt, descending: true)
          .snapshots()
          .listen((snapshot) {
            final previousIds = notifications
                .map((notification) => notification.id)
                .toSet();
            final incoming = snapshot.docs.map(_notificationFromDoc).toList();
            final hasNewStudentNotification =
                _notificationsLoadedOnce &&
                currentUser?.role == UserRole.student &&
                incoming.any(
                  (notification) =>
                      !previousIds.contains(notification.id) &&
                      !readNotificationIds.contains(notification.id),
                );

            notifications
              ..clear()
              ..addAll(incoming);
            _notificationsLoadedOnce = true;

            if (hasNewStudentNotification) {
              final newestNotification = incoming.firstWhere(
                (notification) =>
                    !previousIds.contains(notification.id) &&
                    !readNotificationIds.contains(notification.id),
              );
              unawaited(
                PushNotifications.showLocalNotification(
                  id: newestNotification.id,
                  title: newestNotification.title,
                  body: newestNotification.body,
                ),
              );
              SystemSound.play(SystemSoundType.alert);
              HapticFeedback.mediumImpact();
            }
            notifyListeners();
          }, onError: _rememberError),
    );

    _subscriptions.add(
      repository.appSettings.snapshots().listen((snapshot) {
        final data = snapshot.data();
        final number = data?[SettingsFields.paymentNumber];
        if (number is String && number.trim().isNotEmpty) {
          paymentNumber = number;
        }
        final amount = data?[SettingsFields.paymentAmount];
        if (amount is String && amount.trim().isNotEmpty) {
          paymentAmount = amount;
        }
        notifyListeners();
      }, onError: _rememberError),
    );
  }

  Future<void> _bindApi() async {
    try {
      final repository = _repository as ApiRepository;
      await repository.initialize();
      await _loadPublicApiData();
      final userData = await repository.currentUser();
      if (userData != null) {
        currentUser = _userFromApi(userData);
        users
          ..clear()
          ..add(currentUser!);
        await _loadSignedInApiData();
      }
      notifyListeners();
    } on Object catch (error) {
      _rememberError(error);
      _seed();
    }
  }

  Future<void> _loadPublicApiData() async {
    final repository = _repository as ApiRepository;
    final classesData = await repository.get('/api/classes');
    classes
      ..clear()
      ..addAll(
        (classesData['classes'] as List? ?? const []).whereType<Map>().map(
          (item) => _classFromApi(Map<String, dynamic>.from(item)),
        ),
      );

    final coursesData = await repository.get('/api/courses');
    courses
      ..clear()
      ..addAll(
        (coursesData['courses'] as List? ?? const []).whereType<Map>().map(
          (item) => _courseFromApi(Map<String, dynamic>.from(item)),
        ),
      );

    final guestData = await repository.get('/api/guest-videos');
    guestVideos
      ..clear()
      ..addAll(
        (guestData['items'] as List? ?? const []).whereType<Map>().map(
          (item) => _guestContentFromApi(Map<String, dynamic>.from(item)),
        ),
      );

    final archiveData = await repository.get('/api/archive-files');
    archiveFiles
      ..clear()
      ..addAll(
        (archiveData['items'] as List? ?? const []).whereType<Map>().map(
          (item) => _guestContentFromApi(Map<String, dynamic>.from(item)),
        ),
      );
  }

  Future<void> _loadSignedInApiData() async {
    final repository = _repository as ApiRepository;
    final user = currentUser;
    if (user == null) {
      return;
    }

    if (user.role == UserRole.admin) {
      final usersData = await repository.get('/api/users');
      users
        ..clear()
        ..addAll(
          (usersData['users'] as List? ?? const []).whereType<Map>().map(
            (item) => _userFromApi(Map<String, dynamic>.from(item)),
          ),
        );
      currentUser = users
          .where((candidate) => candidate.id == user.id)
          .cast<AppUser?>()
          .firstOrNull;
    } else {
      final allowedCourseId = user.courseId ?? user.classId;
      if (allowedCourseId != null && allowedCourseId.trim().isNotEmpty) {
        final visibleCourses = courses
            .where(
              (course) =>
                  course.id == allowedCourseId ||
                  course.classId == allowedCourseId,
            )
            .toList();
        final visibleClasses = classes
            .where(
              (schoolClass) =>
                  schoolClass.id == allowedCourseId ||
                  schoolClass.level == allowedCourseId,
            )
            .toList();
        courses
          ..clear()
          ..addAll(visibleCourses);
        classes
          ..clear()
          ..addAll(visibleClasses);
      }
    }

    final lessonsData = await repository.get('/api/lessons');
    lessons
      ..clear()
      ..addAll(
        (lessonsData['lessons'] as List? ?? const []).whereType<Map>().map(
          (item) => _lessonFromApi(Map<String, dynamic>.from(item)),
        ),
      );

    final notificationsData = await repository.get('/api/notifications');
    notifications
      ..clear()
      ..addAll(
        (notificationsData['notifications'] as List? ?? const [])
            .whereType<Map>()
            .map((item) => _notificationFromApi(Map<String, dynamic>.from(item))),
      );
  }

  void _rememberError(Object error) {
    lastError = error.toString();
    notifyListeners();
  }

  void _listenToAllUsers() {
    if (_usersSubscription != null) {
      return;
    }

    _usersSubscription = _repository!.users.snapshots().listen((snapshot) {
      users
        ..clear()
        ..addAll(snapshot.docs.map(_userFromDoc));
      final signedInUid = _repository!.auth.currentUser?.uid;
      if (signedInUid != null) {
        currentUser = users.where((user) => user.id == signedInUid).firstOrNull;
      }
      notifyListeners();
    }, onError: _rememberError);
  }

  void _listenToCurrentUser(String uid) {
    if (_currentUserSubscription != null) {
      return;
    }

    _currentUserSubscription = _repository!.users.doc(uid).snapshots().listen((
      snapshot,
    ) {
      if (!snapshot.exists) {
        logout();
        return;
      }

      final user = _userFromDoc(snapshot);
      currentUser = user;
      users
        ..clear()
        ..add(user);

      if (user.role == UserRole.student) {
        unawaited(_enforceStudentDevice(user));
      }

      notifyListeners();
    }, onError: _rememberError);
  }

  Future<String> _deviceId() async {
    const key = 'epsilon_device_id';
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(key);
    if (existing != null && existing.trim().isNotEmpty) {
      return existing;
    }

    final random = Random.secure();
    final generated =
        '${DateTime.now().microsecondsSinceEpoch}-'
        '${random.nextInt(1 << 32)}-${random.nextInt(1 << 32)}';
    await prefs.setString(key, generated);
    return generated;
  }

  Future<void> _claimStudentDevice(String uid) async {
    final deviceId = await _deviceId();
    await _repository!.setStudentActiveDevice(uid: uid, deviceId: deviceId);
  }

  // ignore: unused_element
  Future<void> _claimStudentDeviceIfNeeded(String uid) async {
    final snapshot = await _repository!.users.doc(uid).get();
    final user = _userFromDoc(snapshot);
    if (user.role != UserRole.student) {
      return;
    }

    await _claimStudentDevice(uid);
  }

  Future<void> _enforceStudentDevice(AppUser user) async {
    if (!firebaseEnabled || _claimingStudentDevice) {
      return;
    }

    final deviceId = await _deviceId();
    final activeDeviceId = user.activeDeviceId?.trim();

    if (activeDeviceId == null || activeDeviceId.isEmpty) {
      _claimingStudentDevice = true;
      try {
        await _claimStudentDevice(user.id);
      } finally {
        _claimingStudentDevice = false;
      }
      return;
    }

    if (activeDeviceId != deviceId) {
      lastError = 'تم تسجيل الدخول لهذا الحساب من جهاز آخر.';
      await _repository?.signOut();
      currentUser = null;
      users.clear();
      notifyListeners();
    }
  }

  void _listenToPublicCourses() {
    unawaited(_coursesSubscription?.cancel() ?? Future<void>.value());
    _coursesSubscription = _repository!.courses
        .where(CourseFields.isActive, isEqualTo: true)
        .snapshots()
        .listen((snapshot) {
          courses
            ..clear()
            ..addAll(snapshot.docs.map(_courseFromDoc));
          notifyListeners();
        }, onError: _rememberError);
  }

  void _listenToGuestContent() {
    _guestVideosSubscription = _repository!.guestVideos
        .orderBy(GuestContentFields.createdAt, descending: true)
        .snapshots()
        .listen((snapshot) {
          guestVideos
            ..clear()
            ..addAll(snapshot.docs.map(_guestContentFromDoc));
          notifyListeners();
        }, onError: _rememberError);

    _archiveFilesSubscription = _repository!.archiveFiles
        .orderBy(GuestContentFields.createdAt, descending: true)
        .snapshots()
        .listen((snapshot) {
          archiveFiles
            ..clear()
            ..addAll(snapshot.docs.map(_guestContentFromDoc));
          notifyListeners();
        }, onError: _rememberError);
  }

  void _listenToCoursesAndLessons(AppUser user) {
    unawaited(_coursesSubscription?.cancel() ?? Future<void>.value());
    unawaited(_lessonsSubscription?.cancel() ?? Future<void>.value());

    final repository = _repository!;
    Query<Map<String, dynamic>> courseQuery = repository.courses;
    Query<Map<String, dynamic>> lessonQuery = repository.lessons;

    if (user.role != UserRole.admin) {
      final classId = user.classId;
      if (classId == null) {
        courses.clear();
        lessons.clear();
        notifyListeners();
        return;
      }

      courseQuery = courseQuery.where(CourseFields.classId, isEqualTo: classId);
      lessonQuery = lessonQuery.where(LessonFields.classId, isEqualTo: classId);
      if (user.role == UserRole.student) {
        courseQuery = courseQuery.where(CourseFields.isActive, isEqualTo: true);
        lessonQuery = lessonQuery.where(
          LessonFields.isPublished,
          isEqualTo: true,
        );
      }
    }

    _coursesSubscription = courseQuery.snapshots().listen((snapshot) {
      courses
        ..clear()
        ..addAll(snapshot.docs.map(_courseFromDoc));
      notifyListeners();
    }, onError: _rememberError);

    _lessonsSubscription = lessonQuery.snapshots().listen((snapshot) {
      lessons
        ..clear()
        ..addAll(snapshot.docs.map(_lessonFromDoc));
      notifyListeners();
    }, onError: _rememberError);
  }

  AppUser _userFromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? {};
    return AppUser(
      id: doc.id,
      name: (data[UserFields.name] as String?) ?? 'مستخدم',
      email: (data[UserFields.email] as String?) ?? '',
      password: '',
      role: _roleFromString(data[UserFields.role] as String?),
      status: _statusFromString(data[UserFields.status] as String?),
      classId: data[UserFields.classId] as String?,
      courseId: data[UserFields.courseId] as String?,
      subject: data[UserFields.subject] as String?,
      paymentProofPath: data[UserFields.paymentProofUrl] as String?,
      paymentSenderPhone: data[UserFields.paymentSenderPhone] as String?,
      activeDeviceId: data[UserFields.activeDeviceId] as String?,
    );
  }

  SchoolClass _classFromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? {};
    return SchoolClass(
      id: doc.id,
      name: (data['name'] as String?) ?? 'عام',
      level: (data['level'] as String?) ?? 'كل المستويات',
    );
  }

  Course _courseFromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? {};
    final subjects = data[CourseFields.subjects];
    return Course(
      id: doc.id,
      title: (data[CourseFields.title] as String?) ?? 'قسم',
      classId: (data[CourseFields.classId] as String?) ?? defaultClassId,
      description:
          (data[CourseFields.description] as String?) ??
          'دروس وتمارين وملخصات منظمة للطلاب',
      price: (data[CourseFields.price] as String?) ?? '',
      subjects: subjects is List
          ? subjects.whereType<String>().toList()
          : const ['الرياضيات', 'الفيزياء', 'الكيمياء'],
      isActive: (data[CourseFields.isActive] as bool?) ?? true,
    );
  }

  Lesson _lessonFromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? {};
    final timestamp = data[LessonFields.createdAt];
    return Lesson(
      id: doc.id,
      title: (data[LessonFields.title] as String?) ?? 'درس',
      url: (data[LessonFields.url] as String?) ?? '',
      teacherId: (data[LessonFields.teacherId] as String?) ?? '',
      classId: (data[LessonFields.classId] as String?) ?? '',
      courseId: (data[LessonFields.courseId] as String?) ?? '',
      subject: (data[LessonFields.subject] as String?) ?? 'مادة عامة',
      createdAt: timestamp is Timestamp ? timestamp.toDate() : DateTime.now(),
      isPublished: (data[LessonFields.isPublished] as bool?) ?? true,
    );
  }

  GuestContentItem _guestContentFromDoc(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data() ?? {};
    final timestamp = data[GuestContentFields.createdAt];
    return GuestContentItem(
      id: doc.id,
      title: (data[GuestContentFields.title] as String?) ?? 'محتوى',
      url: (data[GuestContentFields.url] as String?) ?? '',
      description: (data[GuestContentFields.description] as String?) ?? '',
      courseId: data[GuestContentFields.courseId] as String?,
      createdAt: timestamp is Timestamp ? timestamp.toDate() : DateTime.now(),
    );
  }

  AppNotification _notificationFromDoc(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data() ?? {};
    final timestamp = data[NotificationFields.createdAt];
    return AppNotification(
      id: doc.id,
      title: (data[NotificationFields.title] as String?) ?? 'إشعار',
      body: (data[NotificationFields.body] as String?) ?? '',
      createdAt: timestamp is Timestamp ? timestamp.toDate() : DateTime.now(),
    );
  }

  AppUser _userFromApi(Map<String, dynamic> data) {
    return AppUser(
      id: '${data['id'] ?? ''}',
      name: (data['name'] as String?) ?? (data['username'] as String?) ?? 'مستخدم',
      email: (data['email'] as String?) ?? (data['phone'] as String?) ?? '',
      password: '',
      role: _roleFromString(data['role'] as String?),
      status: _statusFromString(data['status'] as String?),
      classId: data['classId'] as String? ?? data['level'] as String?,
      courseId: data['courseId'] as String? ?? data['level'] as String?,
      subject: data['subject'] as String?,
      paymentProofPath: data['paymentProofUrl'] as String?,
      paymentSenderPhone: data['paymentSenderPhone'] as String?,
      activeDeviceId: data['activeDeviceId'] as String?,
    );
  }

  SchoolClass _classFromApi(Map<String, dynamic> data) {
    return SchoolClass(
      id: '${data['id'] ?? data['level'] ?? ''}',
      name: (data['name'] as String?) ?? 'عام',
      level: (data['level'] as String?) ?? '${data['id'] ?? ''}',
    );
  }

  Course _courseFromApi(Map<String, dynamic> data) {
    final subjects = data['subjects'];
    return Course(
      id: '${data['id'] ?? data['code'] ?? ''}',
      title: (data['title'] as String?) ?? (data['name'] as String?) ?? 'قسم',
      classId:
          (data['classId'] as String?) ??
          (data['level'] as String?) ??
          '${data['code'] ?? data['id'] ?? ''}',
      description: (data['description'] as String?) ?? '',
      price: (data['price'] as String?) ?? '',
      subjects: subjects is List
          ? subjects.whereType<String>().toList()
          : const ['Math', 'Physique', 'Chimie'],
      isActive: (data['isActive'] as bool?) ?? true,
    );
  }

  Lesson _lessonFromApi(Map<String, dynamic> data) {
    return Lesson(
      id: '${data['id'] ?? ''}',
      title: (data['title'] as String?) ?? 'درس',
      url:
          (data['url'] as String?) ??
          (data['videoUrl'] as String?) ??
          (data['pdfUrl'] as String?) ??
          '',
      teacherId: '${data['teacherId'] ?? ''}',
      classId: (data['classId'] as String?) ?? (data['level'] as String?) ?? '',
      courseId: (data['courseId'] as String?) ?? (data['level'] as String?) ?? '',
      subject: (data['subject'] as String?) ?? 'مادة عامة',
      createdAt: _dateFromApi(data['createdAt']),
      isPublished: (data['isPublished'] as bool?) ?? true,
    );
  }

  GuestContentItem _guestContentFromApi(Map<String, dynamic> data) {
    return GuestContentItem(
      id: '${data['id'] ?? ''}',
      title: (data['title'] as String?) ?? 'محتوى',
      url: (data['url'] as String?) ?? '',
      description: (data['description'] as String?) ?? '',
      courseId: data['courseId'] as String?,
      createdAt: _dateFromApi(data['createdAt']),
    );
  }

  AppNotification _notificationFromApi(Map<String, dynamic> data) {
    return AppNotification(
      id: '${data['id'] ?? ''}',
      title: (data['title'] as String?) ?? 'إشعار',
      body: (data['body'] as String?) ?? '',
      createdAt: _dateFromApi(data['createdAt']),
    );
  }

  DateTime _dateFromApi(Object? value) {
    if (value is String) {
      return DateTime.tryParse(value)?.toLocal() ?? DateTime.now();
    }
    return DateTime.now();
  }

  UserRole _roleFromString(String? value) {
    return switch (value) {
      'admin' => UserRole.admin,
      'developer' => UserRole.admin,
      'teacher' => UserRole.teacher,
      _ => UserRole.student,
    };
  }

  AccountStatus _statusFromString(String? value) {
    return switch (value) {
      'active' => AccountStatus.active,
      'blocked' => AccountStatus.blocked,
      'rejected' => AccountStatus.rejected,
      _ => AccountStatus.pending,
    };
  }

  String _statusValue(AccountStatus status) {
    return switch (status) {
      AccountStatus.pending => 'pending',
      AccountStatus.active => 'active',
      AccountStatus.blocked => 'blocked',
      AccountStatus.rejected => 'rejected',
    };
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(_usersSubscription?.cancel() ?? Future<void>.value());
    unawaited(_currentUserSubscription?.cancel() ?? Future<void>.value());
    unawaited(_coursesSubscription?.cancel() ?? Future<void>.value());
    unawaited(_lessonsSubscription?.cancel() ?? Future<void>.value());
    unawaited(_guestVideosSubscription?.cancel() ?? Future<void>.value());
    unawaited(_archiveFilesSubscription?.cancel() ?? Future<void>.value());
    super.dispose();
  }

  void _seed() {
    classes.addAll(const [
      SchoolClass(id: 'c1', name: 'عام', level: 'كل المستويات'),
    ]);

    users.addAll([
      AppUser(
        id: 'u-admin',
        name: 'إدارة المدرسة',
        email: 'admin@demo.com',
        password: '123456',
        role: UserRole.admin,
        status: AccountStatus.active,
      ),
      AppUser(
        id: 'u-teacher',
        name: 'الأستاذ أحمد',
        email: 'teacher@demo.com',
        password: '123456',
        role: UserRole.teacher,
        status: AccountStatus.active,
        classId: 'c1',
        subject: 'الرياضيات',
      ),
      AppUser(
        id: 'u-student',
        name: 'الطالب محمد',
        email: 'student@demo.com',
        password: '123456',
        role: UserRole.student,
        status: AccountStatus.active,
        classId: 'c1',
        courseId: 'course-1',
      ),
    ]);

    courses.addAll([
      Course(
        id: 'course-1',
        title: 'البكالوريا',
        classId: 'c1',
        description:
            'قسم البكالوريا مع مواد الفيزياء والكيمياء والرياضيات والعلوم',
        price: 'غير محدد',
        subjects: ['الفيزياء', 'الكيمياء', 'الرياضيات', 'العلوم'],
      ),
      Course(
        id: 'course-2',
        title: 'شهادة التعليم المتوسط',
        classId: 'c1',
        description: 'مواد منظمة ودروس فيديو لطلاب التعليم المتوسط',
        price: 'غير محدد',
        subjects: ['الرياضيات', 'العلوم'],
      ),
    ]);

    lessons.add(
      Lesson(
        id: 'lesson-1',
        title: 'مقدمة في المعادلات',
        url: 'https://example.com/math-lesson',
        teacherId: 'u-teacher',
        classId: 'c1',
        courseId: 'course-1',
        subject: 'الرياضيات',
        createdAt: DateTime.now().subtract(const Duration(days: 1)),
      ),
    );

    guestVideos.add(
      GuestContentItem(
        id: 'guest-video-1',
        title: 'فيديو مجاني تجريبي',
        url: 'https://drive.google.com',
        description: 'أضف رابط Google Drive من لوحة الإدارة.',
        courseId: 'course-1',
        createdAt: DateTime.now(),
      ),
    );

    archiveFiles.add(
      GuestContentItem(
        id: 'archive-1',
        title: 'ملف PDF تجريبي',
        url: 'https://drive.google.com',
        description: 'أضف رابط ملف PDF من لوحة الإدارة.',
        courseId: 'course-1',
        createdAt: DateTime.now(),
      ),
    );

    notifications.add(
      AppNotification(
        id: 'n-welcome',
        title: 'مرحبا بكم في Epsilon',
        body: 'تابعوا صفحة المواد للحصول على آخر الدروس المنشورة.',
        createdAt: DateTime.now().subtract(const Duration(hours: 2)),
      ),
    );
  }

  Future<bool> login(String email, String password) async {
    if (firebaseEnabled) {
      try {
        isLoading = true;
        lastError = null;
        notifyListeners();
        final userData = await (_repository as ApiRepository).signIn(
          email: email,
          password: password,
        );
        currentUser = _userFromApi(userData);
        users
          ..clear()
          ..add(currentUser!);
        await _loadSignedInApiData();
        return true;
      } on Object catch (error) {
        lastError = error.toString();
        unawaited((_repository as ApiRepository).signOut());
        return false;
      } finally {
        isLoading = false;
        notifyListeners();
      }
    }

    final normalizedEmail = email.trim().toLowerCase();
    final match = users.where(
      (user) => user.email == normalizedEmail && user.password == password,
    );

    if (match.isEmpty) {
      return false;
    }

    currentUser = match.first;
    notifyListeners();
    return true;
  }

  void logout() {
    if (firebaseEnabled) {
      unawaited((_repository as ApiRepository).signOut());
    }
    currentUser = null;
    users.clear();
    lessons.clear();
    notifyListeners();
  }

  Future<bool> changeCurrentPassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    if (firebaseEnabled) {
      lastError = 'تغيير كلمة المرور غير متاح من التطبيق حالياً.';
      notifyListeners();
      return false;
    }

    final user = currentUser;
    if (user == null ||
        user.password != currentPassword ||
        newPassword.length < 6) {
      return false;
    }

    final index = users.indexOf(user);
    if (index == -1) {
      return false;
    }

    users[index] = AppUser(
      id: user.id,
      name: user.name,
      email: user.email,
      password: newPassword,
      role: user.role,
      status: user.status,
      classId: user.classId,
      courseId: user.courseId,
      subject: user.subject,
      paymentProofPath: user.paymentProofPath,
      paymentSenderPhone: user.paymentSenderPhone,
      activeDeviceId: user.activeDeviceId,
    );
    currentUser = users[index];
    notifyListeners();
    return true;
  }

  Future<void> sendPasswordResetEmail(String email) async {
    if (firebaseEnabled) {
      lastError = 'استعادة كلمة المرور تتم حالياً من موقع الإدارة.';
      notifyListeners();
      return;
    }
  }

  Future<void> registerStudent({
    required String name,
    required String email,
    required String password,
    required String courseId,
    required String paymentProofPath,
    required String paymentSenderPhone,
  }) async {
    final course = courseById(courseId);
    if (firebaseEnabled) {
      if (course == null) {
        return;
      }
      await (_repository as ApiRepository).registerStudent(
        name: name,
        email: email,
        password: password,
        courseId: courseId,
        paymentSenderPhone: paymentSenderPhone,
      );
      await _loadPublicApiData();
      return;
    }

    users.add(
      AppUser(
        id: 'u-${DateTime.now().microsecondsSinceEpoch}',
        name: name.trim(),
        email: email.trim().toLowerCase(),
        password: password,
        role: UserRole.student,
        status: AccountStatus.pending,
        classId: course?.classId,
        courseId: courseId,
        paymentProofPath: paymentProofPath,
        paymentSenderPhone: paymentSenderPhone.trim(),
      ),
    );
    notifyListeners();
  }

  void createStudentByAdmin({
    required String name,
    required String email,
    required String password,
    required String courseId,
  }) {
    final course = courseById(courseId);
    if (firebaseEnabled) {
      if (course == null) {
        return;
      }
      unawaited(
        (_repository as ApiRepository)
            .createUser(
              name: name,
              email: email,
              password: password,
              role: 'student',
              courseId: courseId,
            )
            .then((_) => _loadSignedInApiData())
            .catchError(_rememberError),
      );
      return;
    }

    users.add(
      AppUser(
        id: 'u-${DateTime.now().microsecondsSinceEpoch}',
        name: name.trim(),
        email: email.trim().toLowerCase(),
        password: password,
        role: UserRole.student,
        status: AccountStatus.active,
        classId: course?.classId,
        courseId: courseId,
      ),
    );
    notifyListeners();
  }

  Future<void> createTeacher({
    required String name,
    required String email,
    required String password,
    required String classId,
    required String courseId,
    required String subject,
  }) async {
    if (firebaseEnabled) {
      await (_repository as ApiRepository).createUser(
        name: name,
        email: email,
        password: password,
        role: 'teacher',
        courseId: courseId,
        subject: subject,
      );
      await _loadSignedInApiData();
      return;
    }

    users.add(
      AppUser(
        id: 'u-${DateTime.now().microsecondsSinceEpoch}',
        name: name.trim(),
        email: email.trim().toLowerCase(),
        password: password,
        role: UserRole.teacher,
        status: AccountStatus.active,
        classId: classId,
        courseId: courseId,
        subject: subject.trim(),
      ),
    );
    notifyListeners();
  }

  void approveUser(AppUser user) {
    if (firebaseEnabled) {
      unawaited(
        (_repository as ApiRepository)
            .updateAccountStatus(user.id, _statusValue(AccountStatus.active))
            .then((_) => _loadSignedInApiData())
            .catchError(_rememberError),
      );
      return;
    }
    user.status = AccountStatus.active;
    notifyListeners();
  }

  void blockUser(AppUser user) {
    if (firebaseEnabled) {
      unawaited(
        (_repository as ApiRepository)
            .updateAccountStatus(user.id, _statusValue(AccountStatus.blocked))
            .then((_) => _loadSignedInApiData())
            .catchError(_rememberError),
      );
      return;
    }
    user.status = AccountStatus.blocked;
    notifyListeners();
  }

  void rejectUser(AppUser user) {
    if (firebaseEnabled) {
      unawaited(
        (_repository as ApiRepository)
            .updateAccountStatus(user.id, _statusValue(AccountStatus.rejected))
            .then((_) => _loadSignedInApiData())
            .catchError(_rememberError),
      );
      return;
    }
    user.status = AccountStatus.rejected;
    notifyListeners();
  }

  void activateUser(AppUser user) {
    if (firebaseEnabled) {
      unawaited(
        (_repository as ApiRepository)
            .updateAccountStatus(user.id, _statusValue(AccountStatus.active))
            .then((_) => _loadSignedInApiData())
            .catchError(_rememberError),
      );
      return;
    }
    user.status = AccountStatus.active;
    notifyListeners();
  }

  Future<void> deleteUser(AppUser user) async {
    if (firebaseEnabled) {
      await (_repository as ApiRepository).deleteUserAccount(user.id);
      await _loadSignedInApiData();
      return;
    }

    users.remove(user);
    notifyListeners();
  }

  void createCourse({
    required String title,
    required String classId,
    required String description,
    required String price,
    required List<String> subjects,
  }) {
    if (firebaseEnabled) {
      unawaited(
        (_repository as ApiRepository)
            .createCourse(
              title: title,
              classId: classId,
              description: description,
              price: price,
              subjects: subjects,
            )
            .then((_) => _loadPublicApiData())
            .catchError(_rememberError),
      );
      return;
    }

    courses.add(
      Course(
        id: 'course-${DateTime.now().microsecondsSinceEpoch}',
        title: title.trim(),
        classId: classId,
        description: description.trim(),
        price: price.trim(),
        subjects: subjects,
      ),
    );
    notifyListeners();
  }

  void updatePaymentNumber(String value) {
    if (firebaseEnabled) {
      paymentNumber = value.trim();
      notifyListeners();
      return;
    }
    paymentNumber = value.trim();
    notifyListeners();
  }

  void updatePaymentAmount(String value) {
    if (firebaseEnabled) {
      paymentAmount = value.trim();
      notifyListeners();
      return;
    }
    paymentAmount = value.trim();
    notifyListeners();
  }

  void createClass({required String name, required String level}) {
    if (firebaseEnabled) {
      unawaited(
        (_repository as ApiRepository)
            .post('/api/classes', {
              'name': name.trim(),
              'level': level.trim(),
              'title': name.trim(),
              'description': level.trim(),
            })
            .then((_) => _loadPublicApiData())
            .catchError(_rememberError),
      );
      return;
    }

    classes.add(
      SchoolClass(
        id: 'c-${DateTime.now().microsecondsSinceEpoch}',
        name: name.trim(),
        level: level.trim(),
      ),
    );
    notifyListeners();
  }

  void deleteCourse(Course course) {
    if (firebaseEnabled) {
      unawaited(
        (_repository as ApiRepository)
            .deleteCourse(course.id)
            .then((_) => _loadPublicApiData())
            .catchError(_rememberError),
      );
      return;
    }

    courses.remove(course);
    lessons.removeWhere((lesson) => lesson.courseId == course.id);
    for (final user in users) {
      if (user.courseId == course.id) {
        user.courseId = null;
      }
    }
    notifyListeners();
  }

  void deleteClass(SchoolClass schoolClass) {
    if (firebaseEnabled) {
      deleteCourse(
        Course(id: schoolClass.id, title: schoolClass.name, classId: schoolClass.id),
      );
      return;
    }

    classes.remove(schoolClass);
    courses.removeWhere((course) => course.classId == schoolClass.id);
    lessons.removeWhere((lesson) => lesson.classId == schoolClass.id);
    for (final user in users) {
      if (user.classId == schoolClass.id) {
        user.classId = null;
        user.courseId = null;
      }
    }
    notifyListeners();
  }

  void createLesson({
    required String title,
    required String url,
    required String classId,
    required String courseId,
  }) {
    final teacher = currentUser;
    if (teacher == null) {
      return;
    }

    if (firebaseEnabled) {
      unawaited(
        (_repository as ApiRepository)
            .createLesson(
              title: title,
              url: url,
              classId: classId,
              courseId: courseId,
              subject: teacher.subject ?? 'مادة عامة',
            )
            .then((_) => _loadSignedInApiData())
            .catchError(_rememberError),
      );
      return;
    }

    lessons.add(
      Lesson(
        id: 'lesson-${DateTime.now().microsecondsSinceEpoch}',
        title: title.trim(),
        url: url.trim(),
        teacherId: teacher.id,
        classId: classId,
        courseId: courseId,
        subject: teacher.subject ?? 'مادة عامة',
        createdAt: DateTime.now(),
      ),
    );
    notifyListeners();
  }

  void updateLesson({
    required Lesson lesson,
    required String title,
    required String url,
    required String courseId,
  }) {
    final course = courseById(courseId);
    if (firebaseEnabled) {
      if (course == null) {
        return;
      }
      unawaited(
        (_repository as ApiRepository)
            .updateLesson(
              lessonId: lesson.id,
              title: title,
              url: url,
            )
            .then((_) => _loadSignedInApiData())
            .catchError(_rememberError),
      );
      return;
    }

    lesson.title = title.trim();
    lesson.url = url.trim();
    lesson.courseId = courseId;
    if (course != null) {
      lesson.classId = course.classId;
    }
    notifyListeners();
  }

  void deleteLesson(Lesson lesson) {
    if (firebaseEnabled) {
      unawaited(
        (_repository as ApiRepository)
            .deleteLesson(lesson.id)
            .then((_) => _loadSignedInApiData())
            .catchError(_rememberError),
      );
      return;
    }
    lessons.remove(lesson);
    notifyListeners();
  }

  void addGuestVideo({
    required String title,
    required String url,
    required String description,
    required String courseId,
  }) {
    guestVideos.insert(
      0,
      GuestContentItem(
        id: 'guest-video-${DateTime.now().microsecondsSinceEpoch}',
        title: title.trim(),
        url: url.trim(),
        description: description.trim(),
        courseId: courseId,
        createdAt: DateTime.now(),
      ),
    );
    notifyListeners();
  }

  void addArchiveFile({
    required String title,
    required String url,
    required String description,
    required String courseId,
  }) {
    archiveFiles.insert(
      0,
      GuestContentItem(
        id: 'archive-${DateTime.now().microsecondsSinceEpoch}',
        title: title.trim(),
        url: url.trim(),
        description: description.trim(),
        courseId: courseId,
        createdAt: DateTime.now(),
      ),
    );
    notifyListeners();
  }

  void deleteGuestVideo(GuestContentItem item) {
    guestVideos.remove(item);
    notifyListeners();
  }

  void updateGuestVideo({
    required GuestContentItem item,
    required String title,
    required String url,
    required String description,
    required String courseId,
  }) {
    item.title = title.trim();
    item.url = url.trim();
    item.description = description.trim();
    item.courseId = courseId;
    notifyListeners();
  }

  void deleteArchiveFile(GuestContentItem item) {
    archiveFiles.remove(item);
    notifyListeners();
  }

  void updateArchiveFile({
    required GuestContentItem item,
    required String title,
    required String url,
    required String description,
    required String courseId,
  }) {
    item.title = title.trim();
    item.url = url.trim();
    item.description = description.trim();
    item.courseId = courseId;
    notifyListeners();
  }

  Future<void> addNotification({
    required String title,
    required String body,
  }) async {
    if (firebaseEnabled) {
      try {
        await (_repository as ApiRepository).addNotification(
          title: title,
          body: body,
        );
        await _loadSignedInApiData();
      } catch (error) {
        _rememberError(error);
        rethrow;
      }
      return;
    }

    notifications.insert(
      0,
      AppNotification(
        id: 'n-${DateTime.now().microsecondsSinceEpoch}',
        title: title.trim(),
        body: body.trim(),
        createdAt: DateTime.now(),
      ),
    );
    notifyListeners();
  }

  Future<void> updateNotification({
    required AppNotification notification,
    required String title,
    required String body,
  }) async {
    if (firebaseEnabled) {
      notifications.removeWhere((item) => item.id == notification.id);
      notifications.insert(
        0,
        AppNotification(
          id: notification.id,
          title: title.trim(),
          body: body.trim(),
          createdAt: notification.createdAt,
        ),
      );
      notifyListeners();
      return;
    }

    final index = notifications.indexWhere(
      (item) => item.id == notification.id,
    );
    if (index == -1) {
      return;
    }

    notifications[index] = AppNotification(
      id: notification.id,
      title: title.trim(),
      body: body.trim(),
      createdAt: notification.createdAt,
    );
    notifyListeners();
  }

  Future<void> deleteNotification(AppNotification notification) async {
    if (firebaseEnabled) {
      notifications.removeWhere((item) => item.id == notification.id);
      notifyListeners();
      return;
    }

    notifications.removeWhere((item) => item.id == notification.id);
    notifyListeners();
  }

  void setThemeMode(ThemeMode value) {
    themeMode = value;
    notifyListeners();
  }

  void setLanguageCode(String value) {
    languageCode = value;
    notifyListeners();
  }

  List<AppUser> get pendingStudents => users
      .where(
        (user) =>
            user.role == UserRole.student &&
            user.status == AccountStatus.pending,
      )
      .toList();

  List<AppUser> get teachers =>
      users.where((user) => user.role == UserRole.teacher).toList();

  List<AppUser> get students =>
      users.where((user) => user.role == UserRole.student).toList();

  SchoolClass? classById(String? id) {
    if (id == null) {
      return null;
    }
    return classes.where((schoolClass) => schoolClass.id == id).firstOrNull;
  }

  Course? courseById(String? id) {
    if (id == null) {
      return null;
    }
    return courses.where((course) => course.id == id).firstOrNull;
  }
}

class StoreScope extends InheritedNotifier<SchoolStore> {
  const StoreScope({
    required SchoolStore super.notifier,
    required super.child,
    super.key,
  });

  static SchoolStore of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<StoreScope>();
    assert(scope != null, 'StoreScope is missing');
    return scope!.notifier!;
  }
}

class EpsilonApp extends StatefulWidget {
  const EpsilonApp({required this.firebaseStatus, super.key});

  final FirebaseBootstrap firebaseStatus;

  @override
  State<EpsilonApp> createState() => _EpsilonAppState();
}

class _EpsilonAppState extends State<EpsilonApp> {
  late final SchoolStore store = SchoolStore(
    firebaseEnabled: widget.firebaseStatus.isReady,
  );

  @override
  Widget build(BuildContext context) {
    return StoreScope(
      notifier: store,
      child: AnimatedBuilder(
        animation: store,
        builder: (context, _) {
          return MaterialApp(
            debugShowCheckedModeBanner: false,
            title: 'Epsilon Academy',
            locale: Locale(store.languageCode),
            themeMode: store.themeMode,
            builder: (context, child) {
              return Directionality(
                textDirection: TextDirection.rtl,
                child: child ?? const SizedBox.shrink(),
              );
            },
            theme: ThemeData(
              colorScheme: ColorScheme.fromSeed(
                seedColor: const Color(0xFF0F766E),
                primary: const Color(0xFF0F766E),
                secondary: const Color(0xFFEAB308),
              ),
              scaffoldBackgroundColor: const Color(0xFFF7F8FA),
              useMaterial3: true,
              inputDecorationTheme: InputDecorationTheme(
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                filled: true,
                fillColor: Colors.white,
              ),
              cardTheme: CardThemeData(
                elevation: 0,
                color: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                  side: const BorderSide(color: Color(0xFFE5E7EB)),
                ),
              ),
            ),
            darkTheme: ThemeData(
              colorScheme: ColorScheme.fromSeed(
                seedColor: const Color(0xFF2F5BEA),
                brightness: Brightness.dark,
              ),
              scaffoldBackgroundColor: const Color(0xFF0F172A),
              useMaterial3: true,
              inputDecorationTheme: InputDecorationTheme(
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                filled: true,
                fillColor: const Color(0xFF111827),
              ),
            ),
            home: StartupSplashGate(firebaseStatus: widget.firebaseStatus),
          );
        },
      ),
    );
  }
}

class StartupSplashGate extends StatefulWidget {
  const StartupSplashGate({required this.firebaseStatus, super.key});

  final FirebaseBootstrap firebaseStatus;

  @override
  State<StartupSplashGate> createState() => _StartupSplashGateState();
}

class _StartupSplashGateState extends State<StartupSplashGate> {
  bool showSplash = true;
  Timer? splashTimer;

  @override
  void initState() {
    super.initState();
    splashTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) {
        setState(() => showSplash = false);
      }
    });
  }

  @override
  void dispose() {
    splashTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (showSplash) {
      return const StartupSplashScreen();
    }

    return OnboardingGate(firebaseStatus: widget.firebaseStatus);
  }
}

class StartupSplashScreen extends StatelessWidget {
  const StartupSplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(28),
            child: Image(
              image: AssetImage('assets/onboarding/splash.jpeg'),
              fit: BoxFit.contain,
            ),
          ),
        ),
      ),
    );
  }
}

class OnboardingGate extends StatefulWidget {
  const OnboardingGate({required this.firebaseStatus, super.key});

  final FirebaseBootstrap firebaseStatus;

  @override
  State<OnboardingGate> createState() => _OnboardingGateState();
}

class _OnboardingGateState extends State<OnboardingGate> {
  static const _onboardingSeenKey = 'epsilon_onboarding_seen';
  final pageController = PageController();
  bool onboardingDone = true;
  bool checkedOnboarding = false;

  @override
  void initState() {
    super.initState();
    loadOnboardingState();
  }

  @override
  void dispose() {
    pageController.dispose();
    super.dispose();
  }

  Future<void> loadOnboardingState() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) {
      return;
    }
    setState(() {
      onboardingDone = prefs.getBool(_onboardingSeenKey) ?? false;
      checkedOnboarding = true;
    });
  }

  Future<void> finishOnboarding() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_onboardingSeenKey, true);
    if (!mounted) {
      return;
    }
    setState(() => onboardingDone = true);
  }

  void showContentPage() {
    pageController.animateToPage(
      1,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
    );
  }

  void showWelcomePage() {
    pageController.animateToPage(
      0,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!checkedOnboarding) {
      return const Scaffold(
        backgroundColor: Colors.white,
        body: SizedBox.expand(),
      );
    }

    if (onboardingDone) {
      return AppShell(firebaseStatus: widget.firebaseStatus);
    }

    return Scaffold(
      backgroundColor: Colors.white,
      body: PageView(
        controller: pageController,
        physics: const ClampingScrollPhysics(),
        children: [
          OnboardingImagePage(
            imagePath: 'assets/onboarding/welcome.jpeg',
            actions: [
              OnboardingTapZone(
                key: const ValueKey('onboarding-start'),
                rect: const RelativeRect.fromLTRB(0.09, 0.72, 0.09, 0.20),
                onTap: showContentPage,
              ),
              OnboardingTapZone(
                key: const ValueKey('onboarding-skip-welcome'),
                rect: const RelativeRect.fromLTRB(0.28, 0.84, 0.28, 0.08),
                onTap: finishOnboarding,
              ),
            ],
          ),
          OnboardingImagePage(
            imagePath: 'assets/onboarding/content.jpeg',
            actions: [
              OnboardingTapZone(
                key: const ValueKey('onboarding-skip-content'),
                rect: const RelativeRect.fromLTRB(0.72, 0.02, 0.04, 0.90),
                onTap: finishOnboarding,
              ),
              OnboardingTapZone(
                key: const ValueKey('onboarding-next-content'),
                rect: const RelativeRect.fromLTRB(0.75, 0.88, 0.08, 0.03),
                onTap: finishOnboarding,
              ),
              OnboardingTapZone(
                key: const ValueKey('onboarding-back-content'),
                rect: const RelativeRect.fromLTRB(0.08, 0.88, 0.75, 0.03),
                onTap: showWelcomePage,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class OnboardingTapZone {
  const OnboardingTapZone({
    required this.key,
    required this.rect,
    required this.onTap,
  });

  final Key key;
  final RelativeRect rect;
  final VoidCallback onTap;
}

class OnboardingImagePage extends StatelessWidget {
  const OnboardingImagePage({
    required this.imagePath,
    required this.actions,
    super.key,
  });

  final String imagePath;
  final List<OnboardingTapZone> actions;
  static const double _designAspectRatio = 663 / 1119;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      bottom: false,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final availableWidth = constraints.maxWidth;
          final availableHeight = constraints.maxHeight;
          final maxPanelWidth = availableWidth.clamp(0.0, 430.0);
          final widthFromHeight = availableHeight * _designAspectRatio;
          final panelWidth = maxPanelWidth < widthFromHeight
              ? maxPanelWidth
              : widthFromHeight;
          final panelHeight = panelWidth / _designAspectRatio;

          return Center(
            child: SizedBox(
              width: panelWidth,
              height: panelHeight,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image.asset(
                    imagePath,
                    fit: BoxFit.contain,
                    alignment: Alignment.center,
                  ),
                  for (final action in actions)
                    Positioned(
                      left: panelWidth * action.rect.left,
                      top: panelHeight * action.rect.top,
                      right: panelWidth * action.rect.right,
                      bottom: panelHeight * action.rect.bottom,
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          key: action.key,
                          splashColor: Colors.transparent,
                          highlightColor: Colors.transparent,
                          onTap: action.onTap,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class AppShell extends StatelessWidget {
  const AppShell({required this.firebaseStatus, super.key});

  final FirebaseBootstrap firebaseStatus;

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final user = store.currentUser;

    if (user == null) {
      return AuthScreen(firebaseStatus: firebaseStatus);
    }

    if (user.status == AccountStatus.pending) {
      return StatusScreen(
        title: 'حسابك بانتظار القبول',
        message: 'سيظهر لك محتوى قسمك بعد موافقة الإدارة على الحساب.',
        icon: Icons.hourglass_top_rounded,
        color: Colors.orange.shade700,
      );
    }

    if (user.status == AccountStatus.blocked) {
      return StatusScreen(
        title: 'تم تجميد الحساب',
        message: 'يرجى التواصل مع الإدارة لاستعادة صلاحية الدخول.',
        icon: Icons.block_rounded,
        color: Colors.red.shade700,
      );
    }

    if (user.status == AccountStatus.rejected) {
      return StatusScreen(
        title: 'تم رفض الحساب',
        message: 'لم يتم قبول إثبات الدفع أو بيانات التسجيل لهذا الحساب.',
        icon: Icons.cancel_rounded,
        color: Colors.red.shade700,
      );
    }

    return switch (user.role) {
      UserRole.admin => const AdminDashboard(),
      UserRole.teacher => const TeacherDashboard(),
      UserRole.student => const StudentDashboard(),
    };
  }
}

class AuthScreen extends StatefulWidget {
  const AuthScreen({required this.firebaseStatus, super.key});

  final FirebaseBootstrap firebaseStatus;

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  bool registerMode = false;

  @override
  Widget build(BuildContext context) {
    const loginBlue = Color(0xFF2F5BEA);

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned(
              left: 4,
              top: 2,
              child: IconButton(
                color: const Color(0xFF111827),
                onPressed: () {
                  if (registerMode) {
                    setState(() => registerMode = false);
                  }
                },
                icon: const Icon(Icons.arrow_back_rounded),
              ),
            ),
            Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(18, 18, 18, 12),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 8),
                      Center(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: SizedBox(
                            width: 260,
                            height: 160,
                            child: Image.asset(
                              'assets/onboarding/welcome.jpeg',
                              fit: BoxFit.cover,
                              alignment: const Alignment(0, -0.45),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        registerMode ? 'إنشاء حساب جديد' : 'مرحبا بك مجددا',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          color: const Color(0xFF111827),
                          fontWeight: FontWeight.w800,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        registerMode
                            ? 'أدخل بياناتك وانتظر موافقة الإدارة'
                            : 'سجل دخولك للمتابعة',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: const Color(0xFF6B7280),
                          fontWeight: FontWeight.w500,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 20),
                      if (!widget.firebaseStatus.isReady) ...[
                        FirebaseSetupBanner(
                          message:
                              widget.firebaseStatus.errorMessage ??
                              'Firebase غير متصل حاليًا.',
                        ),
                        const SizedBox(height: 16),
                      ],
                      registerMode
                          ? const RegisterCard()
                          : const LoginCard(primaryColor: loginBlue),
                      const SizedBox(height: 18),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            registerMode
                                ? 'لديك حساب بالفعل؟'
                                : 'ليس لديك حساب؟',
                            style: const TextStyle(
                              color: Color(0xFF6B7280),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          TextButton(
                            onPressed: () {
                              setState(() => registerMode = !registerMode);
                            },
                            child: Text(
                              registerMode ? 'تسجيل الدخول' : 'إنشاء حساب',
                              style: const TextStyle(
                                color: loginBlue,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (!registerMode)
                        TextButton(
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const GuestPage(),
                            ),
                          ),
                          style: TextButton.styleFrom(
                            padding: EdgeInsets.zero,
                            minimumSize: const Size(0, 24),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          child: const Text(
                            'يمكنك أيضا الدخول كزائر',
                            style: TextStyle(
                              color: loginBlue,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      const AuthFooterLinks(),
                      const SizedBox(height: 8),
                      const DeveloperCredit(),
                    ],
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

class LoginCard extends StatefulWidget {
  const LoginCard({required this.primaryColor, super.key});

  final Color primaryColor;

  @override
  State<LoginCard> createState() => _LoginCardState();
}

class _LoginCardState extends State<LoginCard> {
  final emailController = TextEditingController();
  final passwordController = TextEditingController();
  bool obscurePassword = true;
  String? error;

  @override
  void dispose() {
    emailController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(color: Colors.white),
      child: Padding(
        padding: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: emailController,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(
                hintText: 'البريد الإلكتروني أو رقم هاتفك',
                suffixIcon: Icon(Icons.mail_outline_rounded),
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 15,
                ),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: passwordController,
              obscureText: obscurePassword,
              decoration: InputDecoration(
                hintText: 'كلمة المرور',
                suffixIcon: const Icon(Icons.lock_outline_rounded),
                prefixIcon: IconButton(
                  tooltip: obscurePassword
                      ? 'إظهار كلمة المرور'
                      : 'إخفاء كلمة المرور',
                  onPressed: () =>
                      setState(() => obscurePassword = !obscurePassword),
                  icon: Icon(
                    obscurePassword
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                  ),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 15,
                ),
              ),
            ),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ForgotPasswordPage()),
                ),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.only(top: 6),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text(
                  'نسيت كلمة المرور؟',
                  style: TextStyle(
                    color: Color(0xFF4B5563),
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              ),
            ),
            if (error != null) ...[
              const SizedBox(height: 8),
              Text(error!, style: TextStyle(color: Colors.red.shade700)),
            ],
            const SizedBox(height: 16),
            SizedBox(
              height: 52,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: widget.primaryColor,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                onPressed: () async {
                  final ok = await StoreScope.of(
                    context,
                  ).login(emailController.text, passwordController.text);
                  if (!mounted) {
                    return;
                  }
                  setState(() {
                    error = ok ? null : 'بيانات الدخول غير صحيحة.';
                  });
                },
                child: const Text(
                  'تسجيل الدخول',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class AuthFooterLinks extends StatelessWidget {
  const AuthFooterLinks({super.key});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 6,
      runSpacing: 0,
      children: [
        TextButton(
          onPressed: () => Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => const AboutPage())),
          child: const Text('من نحن'),
        ),
        TextButton(
          onPressed: () => Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => const PrivacyPolicyPage())),
          child: const Text('سياسة الخصوصية'),
        ),
        TextButton(
          onPressed: () => Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => const ContactUsPage())),
          child: const Text('تواصل معنا'),
        ),
      ],
    );
  }
}

class ForgotPasswordPage extends StatefulWidget {
  const ForgotPasswordPage({super.key});

  @override
  State<ForgotPasswordPage> createState() => _ForgotPasswordPageState();
}

class _ForgotPasswordPageState extends State<ForgotPasswordPage> {
  final emailController = TextEditingController();
  String? message;
  bool success = false;
  bool sending = false;

  @override
  void dispose() {
    emailController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);

    return Scaffold(
      backgroundColor: const Color(0xFFF7F9FF),
      appBar: const EpsilonAppBar(title: 'نسيت كلمة السر', showLogout: false),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          const HeaderPanel(
            title: 'استعادة كلمة المرور',
            subtitle: 'أدخل بريدك الإلكتروني لإرسال رابط إعادة التعيين',
            icon: Icons.lock_reset_rounded,
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: 'البريد الإلكتروني',
            icon: Icons.mail_outline_rounded,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: emailController,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(
                    labelText: 'البريد الإلكتروني',
                    prefixIcon: Icon(Icons.mail_outline_rounded),
                  ),
                ),
                if (message != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    message!,
                    style: TextStyle(
                      color: success
                          ? Colors.green.shade700
                          : Colors.red.shade700,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
                const SizedBox(height: 14),
                FilledButton.icon(
                  onPressed: sending
                      ? null
                      : () async {
                          final email = emailController.text.trim();
                          if (email.isEmpty) {
                            setState(() {
                              success = false;
                              message = 'أدخل البريد الإلكتروني أولا.';
                            });
                            return;
                          }

                          setState(() {
                            sending = true;
                            message = null;
                          });

                          try {
                            await store.sendPasswordResetEmail(email);
                            if (!mounted) {
                              return;
                            }
                            setState(() {
                              success = true;
                              message =
                                  'تم إرسال رابط إعادة تعيين كلمة المرور إن كان البريد مسجلا.';
                            });
                          } on Object catch (error) {
                            if (!mounted) {
                              return;
                            }
                            setState(() {
                              success = false;
                              message =
                                  'تعذر إرسال الرابط: ${friendlyFirebaseError(error)}';
                            });
                          } finally {
                            if (mounted) {
                              setState(() => sending = false);
                            }
                          }
                        },
                  icon: const Icon(Icons.send_rounded),
                  label: Text(sending ? 'جار الإرسال...' : 'إرسال الرابط'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const InfoContentPage(
      title: 'من نحن',
      icon: Icons.school_rounded,
      paragraphs: [
        'Epsilon Education تطبيق تعليمي يجمع الطلاب والأساتذة والإدارة في مكان واحد.',
        'هدفنا تنظيم الدروس حسب الأقسام والمواد، وتسهيل متابعة المحتوى التعليمي بطريقة واضحة وآمنة.',
      ],
    );
  }
}

class PrivacyPolicyPage extends StatelessWidget {
  const PrivacyPolicyPage({super.key});

  static final Uri privacyPolicyUrl = Uri.parse(
    'https://epsilon-academy-said-42b07.web.app/privacy-policy/',
  );
  static final Uri deleteAccountUrl = Uri.parse(
    'https://epsilon-academy-said-42b07.web.app/delete-account/',
  );

  Future<void> openUrl(Uri url) async {
    await launchUrl(url, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F9FF),
      appBar: const EpsilonAppBar(
        title: 'سياسة الخصوصية',
        showLogout: false,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          const HeaderPanel(
            title: 'سياسة الخصوصية',
            subtitle: 'Epsilon Education',
            icon: Icons.privacy_tip_rounded,
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: 'سياسة الخصوصية',
            icon: Icons.privacy_tip_rounded,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'نستخدم بيانات الحساب فقط لإدارة الدخول، الأقسام، المواد، والدروس داخل التطبيق.',
                  style: TextStyle(
                    color: Color(0xFF374151),
                    height: 1.55,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  'صور إثبات الدفع تحفظ للتحقق الإداري ولا تظهر إلا للإدارة المختصة.',
                  style: TextStyle(
                    color: Color(0xFF374151),
                    height: 1.55,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  'لا نشارك بيانات المستخدمين مع جهات خارجية داخل هذا الإصدار من التطبيق.',
                  style: TextStyle(
                    color: Color(0xFF374151),
                    height: 1.55,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 16),
                _PolicyLinkButton(
                  icon: Icons.open_in_new_rounded,
                  title: 'رابط سياسة الخصوصية',
                  subtitle: privacyPolicyUrl.toString(),
                  onTap: () => openUrl(privacyPolicyUrl),
                ),
                const SizedBox(height: 10),
                _PolicyLinkButton(
                  icon: Icons.delete_outline_rounded,
                  title: 'رابط طلب حذف الحساب',
                  subtitle: deleteAccountUrl.toString(),
                  onTap: () => openUrl(deleteAccountUrl),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PolicyLinkButton extends StatelessWidget {
  const _PolicyLinkButton({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      style: OutlinedButton.styleFrom(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.all(12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      onPressed: onTap,
      child: Row(
        textDirection: TextDirection.rtl,
        children: [
          Icon(icon, color: const Color(0xFF2457D6)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Color(0xFF172033),
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  textDirection: TextDirection.ltr,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF5C6575),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          const Icon(Icons.arrow_back_ios_new_rounded, size: 16),
        ],
      ),
    );
  }
}
class ContactUsPage extends StatelessWidget {
  const ContactUsPage({super.key});

  Future<void> openWhatsApp() async {
    final uri = Uri.parse(
      'https://wa.me/22249677414?text=${Uri.encodeComponent('السلام عليكم، أريد التواصل مع إدارة Epsilon Education')}',
    );
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F9FF),
      appBar: const EpsilonAppBar(title: 'تواصل معنا', showLogout: false),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          const HeaderPanel(
            title: 'تواصل معنا',
            subtitle: 'نحن قريبون منك متى احتجت إلى مساعدة',
            icon: Icons.support_agent_rounded,
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: 'الدعم والمساعدة',
            icon: Icons.favorite_rounded,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'نسعد برسائلكم وملاحظاتكم، فكل سؤال منكم يساعدنا على جعل تجربة التعلم أوضح وأسهل وأقرب لاحتياجاتكم.',
                  style: TextStyle(
                    color: Color(0xFF374151),
                    height: 1.6,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF25D366),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  onPressed: openWhatsApp,
                  icon: const Icon(Icons.chat_rounded),
                  label: const Text(
                    'التواصل عبر واتساب',
                    style: TextStyle(fontWeight: FontWeight.w900),
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  '49677414',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Color(0xFF0F766E),
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          const DeveloperCredit(),
        ],
      ),
    );
  }
}

class DeveloperCredit extends StatelessWidget {
  const DeveloperCredit({super.key});

  @override
  Widget build(BuildContext context) {
    return const Text(
      'تم التطوير بواسطة المطور محمد سعيد مختار الله',
      textAlign: TextAlign.center,
      style: TextStyle(
        color: Color(0xFF6B7280),
        fontSize: 12,
        fontWeight: FontWeight.w700,
      ),
    );
  }
}

class GuestPage extends StatelessWidget {
  const GuestPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F9FF),
      appBar: const EpsilonAppBar(title: 'الدخول كزائر', showLogout: false),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          const HeaderPanel(
            title: 'مرحبا بك كزائر',
            subtitle: 'تصفح فكرة التطبيق قبل إنشاء حسابك',
            icon: Icons.person_search_rounded,
          ),
          const SizedBox(height: 16),
          GuestActionCard(
            title: 'الفيديوهات المجانية',
            subtitle: 'شاهد محتوى تعليمي متاح للجميع',
            icon: Icons.play_circle_rounded,
            color: const Color(0xFF2F5BEA),
            onTap: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const FreeVideosPage())),
          ),
          const SizedBox(height: 12),
          GuestActionCard(
            title: 'الأرشيف',
            subtitle: 'ملفات ومحتوى محفوظ سننظمه لاحقا',
            icon: Icons.archive_rounded,
            color: const Color(0xFF0F766E),
            onTap: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const ArchivePage())),
          ),
        ],
      ),
    );
  }
}

class GuestActionCard extends StatelessWidget {
  const GuestActionCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.color,
    required this.onTap,
    super.key,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFE8EEFF)),
          ),
          child: Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: color, size: 30),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: Color(0xFF111827),
                        fontSize: 17,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: Color(0xFF6B7280),
                        height: 1.35,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.arrow_back_ios_new_rounded, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}

class FreeVideosPage extends StatelessWidget {
  const FreeVideosPage({super.key});

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);

    return GuestContentPage(
      title: 'الفيديوهات المجانية',
      subtitle: 'محتوى مجاني متاح للزوار',
      icon: Icons.play_circle_rounded,
      emptyText: 'لا توجد فيديوهات مجانية حاليا.',
      items: store.guestVideos,
      viewerKind: SecureContentKind.video,
    );
  }
}

class ArchivePage extends StatelessWidget {
  const ArchivePage({super.key});

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);

    return GuestContentPage(
      title: 'الأرشيف',
      subtitle: 'ملفات PDF محفوظة للزوار',
      icon: Icons.archive_rounded,
      emptyText: 'لا توجد ملفات في الأرشيف حاليا.',
      items: store.archiveFiles,
      viewerKind: SecureContentKind.pdf,
    );
  }
}

class GuestContentPage extends StatefulWidget {
  const GuestContentPage({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.emptyText,
    required this.items,
    required this.viewerKind,
    super.key,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final String emptyText;
  final List<GuestContentItem> items;
  final SecureContentKind viewerKind;

  @override
  State<GuestContentPage> createState() => _GuestContentPageState();
}

class _GuestContentPageState extends State<GuestContentPage> {
  String? selectedCourseId;

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final courses = [...store.courses]
      ..sort((a, b) => a.title.compareTo(b.title));
    final filteredItems = selectedCourseId == null
        ? <GuestContentItem>[]
        : widget.items
              .where((item) => item.courseId == selectedCourseId)
              .toList();

    return Scaffold(
      backgroundColor: const Color(0xFFF7F9FF),
      appBar: EpsilonAppBar(title: widget.title, showLogout: false),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          HeaderPanel(
            title: widget.title,
            subtitle: widget.subtitle,
            icon: widget.icon,
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: 'اختر القسم',
            icon: Icons.menu_book_rounded,
            child: courses.isEmpty
                ? const EmptyState(text: 'لا توجد أقسام متاحة حاليا.')
                : DropdownButtonFormField<String>(
                    initialValue: selectedCourseId,
                    decoration: const InputDecoration(
                      labelText: 'القسم',
                      prefixIcon: Icon(Icons.school_rounded),
                    ),
                    items: courses
                        .map(
                          (course) => DropdownMenuItem(
                            value: course.id,
                            child: Text(course.title),
                          ),
                        )
                        .toList(),
                    onChanged: (value) =>
                        setState(() => selectedCourseId = value),
                  ),
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: selectedCourseId == null
                ? 'محتوى القسم'
                : store.courseById(selectedCourseId)?.title ?? widget.title,
            icon: widget.icon,
            child: selectedCourseId == null
                ? const EmptyState(text: 'اختر القسم لعرض المحتوى الخاص به.')
                : filteredItems.isEmpty
                ? EmptyState(text: widget.emptyText)
                : Column(
                    children: filteredItems
                        .map(
                          (item) => GuestContentTile(
                            item: item,
                            icon: widget.icon,
                            viewerKind: widget.viewerKind,
                          ),
                        )
                        .toList(),
                  ),
          ),
        ],
      ),
    );
  }
}

class GuestContentTile extends StatelessWidget {
  const GuestContentTile({
    required this.item,
    required this.icon,
    required this.viewerKind,
    super.key,
  });

  final GuestContentItem item;
  final IconData icon;
  final SecureContentKind viewerKind;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: const Color(0xFF2F5BEA)),
      title: Text(
        item.title,
        style: const TextStyle(fontWeight: FontWeight.w900),
      ),
      subtitle: Text(
        item.description.trim().isEmpty ? 'اضغط للعرض' : item.description,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: const Icon(Icons.arrow_back_ios_new_rounded, size: 16),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => SecureContentViewerPage(
            title: item.title,
            url: item.url,
            kind: viewerKind,
          ),
        ),
      ),
    );
  }
}

class InfoContentPage extends StatelessWidget {
  const InfoContentPage({
    required this.title,
    required this.icon,
    required this.paragraphs,
    super.key,
  });

  final String title;
  final IconData icon;
  final List<String> paragraphs;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F9FF),
      appBar: EpsilonAppBar(title: title, showLogout: false),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          HeaderPanel(title: title, subtitle: 'Epsilon Education', icon: icon),
          const SizedBox(height: 16),
          SectionCard(
            title: title,
            icon: icon,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: paragraphs
                  .map(
                    (paragraph) => Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Text(
                        paragraph,
                        style: const TextStyle(
                          color: Color(0xFF374151),
                          height: 1.55,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }
}

class RegisterCard extends StatefulWidget {
  const RegisterCard({super.key});

  @override
  State<RegisterCard> createState() => _RegisterCardState();
}

class _RegisterCardState extends State<RegisterCard> {
  final nameController = TextEditingController();
  final emailController = TextEditingController();
  final passwordController = TextEditingController();
  String? error;

  @override
  void dispose() {
    nameController.dispose();
    emailController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: 'اسم الطالب',
                prefixIcon: Icon(Icons.badge_outlined),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: emailController,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(
                labelText: 'البريد الإلكتروني',
                prefixIcon: Icon(Icons.mail_outline_rounded),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: passwordController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'كلمة المرور',
                prefixIcon: Icon(Icons.lock_outline_rounded),
              ),
            ),
            if (store.courses.isEmpty) ...[
              const SizedBox(height: 10),
              const EmptyState(text: 'لا توجد أقسام متاحة حاليا.'),
            ],
            if (error != null) ...[
              const SizedBox(height: 10),
              Text(error!, style: TextStyle(color: Colors.red.shade700)),
            ],
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () {
                if (nameController.text.trim().isEmpty ||
                    emailController.text.trim().isEmpty ||
                    passwordController.text.length < 6 ||
                    store.courses.isEmpty) {
                  setState(
                    () => error =
                        'أكمل البيانات، ويجب أن تكون كلمة المرور 6 أحرف على الأقل، مع توفر قسم واحد على الأقل.',
                  );
                  return;
                }

                setState(() => error = null);
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => StudentCourseSelectionPage(
                      name: nameController.text.trim(),
                      email: emailController.text.trim(),
                      password: passwordController.text,
                    ),
                  ),
                );
              },
              icon: const Icon(Icons.arrow_back_rounded),
              label: const Text('اختيار القسم'),
            ),
          ],
        ),
      ),
    );
  }
}

class StudentCourseSelectionPage extends StatelessWidget {
  const StudentCourseSelectionPage({
    required this.name,
    required this.email,
    required this.password,
    super.key,
  });

  final String name;
  final String email;
  final String password;

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);

    return Scaffold(
      backgroundColor: const Color(0xFFF7F9FF),
      appBar: AppBar(
        backgroundColor: const Color(0xFFF7F9FF),
        surfaceTintColor: const Color(0xFFF7F9FF),
        elevation: 0,
        centerTitle: true,
        leading: IconButton(
          tooltip: 'رجوع',
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.arrow_back_rounded),
        ),
        title: const Text(
          'اختر قسمك',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
        actions: [
          IconButton(
            tooltip: 'بحث',
            onPressed: () {},
            icon: const Icon(Icons.search_rounded),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 24),
        children: [
          const Text(
            'اختر القسم الذي تريد التسجيل به للبدء في رحلتك التعليمية',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Color(0xFF6B7280),
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 20),
          Row(
            textDirection: TextDirection.rtl,
            children: [
              Container(
                width: 4,
                height: 24,
                decoration: BoxDecoration(
                  color: const Color(0xFF2F5BEA),
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                'الأقسام المتاحة',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (store.courses.isEmpty)
            const SectionCard(
              title: 'لا توجد أقسام',
              icon: Icons.menu_book_rounded,
              child: EmptyState(text: 'انتظر الإدارة حتى تضيف قسما متاحا.'),
            )
          else
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: store.courses.length,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
                childAspectRatio: 0.82,
              ),
              itemBuilder: (context, index) {
                final course = store.courses[index];
                return StudentCourseCard(
                  course: course,
                  onSelect: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => StudentPaymentPage(
                        name: name,
                        email: email,
                        password: password,
                        courseId: course.id,
                      ),
                    ),
                  ),
                );
              },
            ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFFEAF1FF),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Row(
              children: [
                Icon(Icons.info_rounded, color: Color(0xFF2F5BEA)),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'جميع الأقسام وموادها يتم تحديثها باستمرار للحصول على جديد المحتوى التعليمي.',
                    style: TextStyle(
                      color: Color(0xFF374151),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class StudentCourseCard extends StatelessWidget {
  const StudentCourseCard({
    required this.course,
    required this.onSelect,
    super.key,
  });

  final Course course;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final schoolClass = store.classById(course.classId);
    final accent = courseAccent(course.title);
    final icon = courseIcon(course.title);

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE8EEFF)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF1F2937).withValues(alpha: 0.04),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Stack(
        children: [
          PositionedDirectional(
            top: -1,
            end: 2,
            child: Icon(Icons.bookmark_rounded, color: accent, size: 22),
          ),
          PositionedDirectional(
            top: 18,
            end: 2,
            child: Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: accent, size: 38),
            ),
          ),
          Positioned.fill(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: 70, top: 10),
                  child: Text(
                    courseShortTitle(course.title),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: accent,
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                const SizedBox(height: 7),
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: 70),
                  child: Text(
                    courseTitleLine(course.title, schoolClass?.level),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFF111827),
                      fontWeight: FontWeight.w800,
                      fontSize: 12,
                      height: 1.25,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  course.description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF6B7280),
                    height: 1.35,
                    fontSize: 10.5,
                  ),
                ),
                if (course.price.trim().isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: StatusPill(text: course.price),
                  ),
                ],
                const Spacer(),
                SizedBox(
                  height: 34,
                  child: OutlinedButton.icon(
                    onPressed: onSelect,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: accent,
                      side: BorderSide(color: accent.withValues(alpha: 0.55)),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(9),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    icon: const Icon(Icons.arrow_back_rounded, size: 16),
                    label: const FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        'اختر القسم',
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class StudentPaymentPage extends StatefulWidget {
  const StudentPaymentPage({
    required this.name,
    required this.email,
    required this.password,
    required this.courseId,
    super.key,
  });

  final String name;
  final String email;
  final String password;
  final String courseId;

  @override
  State<StudentPaymentPage> createState() => _StudentPaymentPageState();
}

class _StudentPaymentPageState extends State<StudentPaymentPage>
    with SingleTickerProviderStateMixin {
  final picker = ImagePicker();
  final paymentSenderPhoneController = TextEditingController();
  late final AnimationController attentionController;
  late final Animation<double> pulseAnimation;
  XFile? proofImage;
  bool submitted = false;
  String? error;

  @override
  void initState() {
    super.initState();
    attentionController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat(reverse: true);
    pulseAnimation = Tween<double>(begin: 0.96, end: 1.04).animate(
      CurvedAnimation(parent: attentionController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    paymentSenderPhoneController.dispose();
    attentionController.dispose();
    super.dispose();
  }

  Future<void> pickProofImage() async {
    final image = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 82,
    );
    if (image == null) {
      return;
    }

    setState(() {
      proofImage = image;
      error = null;
    });
  }

  Future<void> submitRequest() async {
    final image = proofImage;
    if (image == null) {
      setState(() => error = 'يرجى إرسال صورة إثبات الدفع أولا.');
      return;
    }
    if (paymentSenderPhoneController.text.trim().isEmpty) {
      setState(() => error = 'اكتب الرقم الذي تم إرسال المبلغ منه.');
      return;
    }

    try {
      await StoreScope.of(context).registerStudent(
        name: widget.name,
        email: widget.email,
        password: widget.password,
        courseId: widget.courseId,
        paymentProofPath: image.path,
        paymentSenderPhone: paymentSenderPhoneController.text,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        submitted = true;
        error = null;
      });
    } on Object catch (exception) {
      if (!mounted) {
        return;
      }
      setState(() => error = 'تعذر إرسال الطلب: $exception');
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final course = store.courseById(widget.courseId);
    final coursePrice = course?.price.trim() ?? '';
    final paymentAmount = coursePrice.isNotEmpty
        ? coursePrice
        : store.paymentAmount;

    return Scaffold(
      backgroundColor: const Color(0xFFF7F9FF),
      appBar: const EpsilonAppBar(title: 'الدفع', showLogout: false),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          AdminPageHeader(
            title: 'إثبات الدفع',
            subtitle: 'ادفع عبر الرقم التالي ثم أرسل صورة الإثبات',
            icon: Icons.receipt_long_rounded,
            color: const Color(0xFF2F5BEA),
          ),
          const SizedBox(height: 16),
          PaymentAttentionCard(
            paymentNumber: store.paymentNumber,
            paymentAmount: paymentAmount,
            pulseAnimation: pulseAnimation,
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: 'بيانات الطلب',
            icon: Icons.person_outline_rounded,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                InfoRow(label: 'الاسم', value: widget.name),
                InfoRow(label: 'البريد', value: widget.email),
                InfoRow(label: 'القسم', value: course?.title ?? 'غير محدد'),
                TextField(
                  controller: paymentSenderPhoneController,
                  enabled: !submitted,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: 'الرقم الذي أرسلت منه المبلغ',
                    hintText: 'مثال: 49677414',
                    prefixIcon: Icon(Icons.phone_iphone_rounded),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: 'صورة إثبات الدفع',
            icon: Icons.image_outlined,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                PaymentProofPreview(imagePath: proofImage?.path),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: submitted ? null : pickProofImage,
                  icon: const Icon(Icons.upload_file_rounded),
                  label: Text(
                    proofImage == null
                        ? 'اختيار صورة إثبات الدفع'
                        : 'تغيير الصورة',
                  ),
                ),
                if (error != null) ...[
                  const SizedBox(height: 10),
                  Text(error!, style: TextStyle(color: Colors.red.shade700)),
                ],
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: submitted ? null : submitRequest,
                  icon: const Icon(Icons.send_rounded),
                  label: const Text('إرسال الطلب للإدارة'),
                ),
              ],
            ),
          ),
          if (submitted) ...[
            const SizedBox(height: 16),
            SectionCard(
              title: 'تم إرسال الطلب',
              icon: Icons.mark_email_read_rounded,
              child: Column(
                children: [
                  const Text(
                    'تم إنشاء الحساب وإرسال إثبات الدفع إلى الإدارة. سيبقى الحساب بانتظار القبول.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('العودة لتسجيل الدخول'),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class PaymentAttentionCard extends StatelessWidget {
  const PaymentAttentionCard({
    required this.paymentNumber,
    required this.paymentAmount,
    required this.pulseAnimation,
    super.key,
  });

  final String paymentNumber;
  final String paymentAmount;
  final Animation<double> pulseAnimation;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF2F5BEA),
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF2F5BEA).withValues(alpha: 0.24),
            blurRadius: 26,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: Row(
        children: [
          ScaleTransition(
            scale: pulseAnimation,
            child: Container(
              width: 62,
              height: 62,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: Colors.white24),
              ),
              child: const Icon(
                Icons.payments_rounded,
                color: Colors.white,
                size: 34,
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'سعر الانضمام',
                  style: TextStyle(
                    color: Color(0xFFE8EEFF),
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                SelectableText(
                  paymentAmount.trim().isEmpty
                      ? 'لم تحدده الإدارة بعد'
                      : paymentAmount,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0,
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'رقم الدفع',
                  style: TextStyle(
                    color: Color(0xFFE8EEFF),
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                SelectableText(
                  paymentNumber.isEmpty ? 'لم تضفه الإدارة بعد' : paymentNumber,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'بعد الدفع ارفع صورة الإيصال ليتم تفعيل حسابك.',
                  style: TextStyle(color: Color(0xFFE8EEFF), height: 1.35),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class InfoRow extends StatelessWidget {
  const InfoRow({required this.label, required this.value, super.key});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Text(
            '$label:',
            style: const TextStyle(
              color: Color(0xFF6B7280),
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    );
  }
}

class PaymentProofPreview extends StatelessWidget {
  const PaymentProofPreview({
    required this.imagePath,
    this.emptyText = 'لم يتم اختيار صورة بعد',
    this.height = 190,
    super.key,
  });

  final String? imagePath;
  final String emptyText;
  final double height;

  @override
  Widget build(BuildContext context) {
    final path = imagePath;
    final image = path == null
        ? null
        : path.startsWith('http')
        ? Image.network(path, fit: BoxFit.cover)
        : Image.file(File(path), fit: BoxFit.cover);

    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: image == null
          ? null
          : () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => PaymentProofDetailsPage(imagePath: path!),
              ),
            ),
      child: Container(
        height: height,
        decoration: BoxDecoration(
          color: const Color(0xFFF3F6FF),
          border: Border.all(color: const Color(0xFFD8E2FF)),
          borderRadius: BorderRadius.circular(14),
        ),
        clipBehavior: Clip.antiAlias,
        child:
            image ??
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.add_photo_alternate_rounded,
                  size: 42,
                  color: Color(0xFF2F5BEA),
                ),
                const SizedBox(height: 8),
                Text(emptyText),
              ],
            ),
      ),
    );
  }
}

class PaymentProofDetailsPage extends StatelessWidget {
  const PaymentProofDetailsPage({required this.imagePath, super.key});

  final String imagePath;

  @override
  Widget build(BuildContext context) {
    final image = imagePath.startsWith('http')
        ? Image.network(imagePath, fit: BoxFit.contain)
        : Image.file(File(imagePath), fit: BoxFit.contain);

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('إثبات الدفع'),
      ),
      body: Center(
        child: InteractiveViewer(minScale: 0.8, maxScale: 5, child: image),
      ),
    );
  }
}

class FirebaseSetupBanner extends StatelessWidget {
  const FirebaseSetupBanner({required this.message, super.key});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFBEB),
        border: Border.all(color: const Color(0xFFFACC15)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline_rounded, color: Color(0xFFA16207)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: Color(0xFF713F12)),
            ),
          ),
        ],
      ),
    );
  }
}

class StatusScreen extends StatelessWidget {
  const StatusScreen({
    required this.title,
    required this.message,
    required this.icon,
    required this.color,
    super.key,
  });

  final String title;
  final String message;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: EpsilonAppBar(title: title),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 72, color: color),
              const SizedBox(height: 16),
              Text(
                title,
                style: Theme.of(context).textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(message, textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    );
  }
}

class AdminDashboard extends StatelessWidget {
  const AdminDashboard({super.key});

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final admin = store.currentUser;

    return Scaffold(
      backgroundColor: const Color(0xFFF7F9FF),
      appBar: const EpsilonAppBar(title: 'لوحة الإدارة'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          AdminHeroPanel(
            title: 'مرحبا ${admin?.name ?? 'بالإدارة'}',
            subtitle: store.pendingStudents.isEmpty
                ? 'كل الطلبات مرتبة حاليا'
                : '${store.pendingStudents.length} طلب يحتاج مراجعة',
            value: store.pendingStudents.length.toString(),
          ),
          const SizedBox(height: 16),
          Text(
            'الإدارة السريعة',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (context, constraints) {
              final isWide = constraints.maxWidth > 560;
              final width = isWide
                  ? (constraints.maxWidth - 12) / 2
                  : constraints.maxWidth;

              return Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  SizedBox(
                    width: width,
                    child: AdminNavButton(
                      title: 'الحسابات',
                      metric: '${store.pendingStudents.length} طلب دفع',
                      subtitle: 'قبول، تجميد، أو رفض الطلاب',
                      icon: Icons.manage_accounts_rounded,
                      color: const Color(0xFF2F5BEA),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const AdminAccountsPage(),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: width,
                    child: AdminNavButton(
                      title: 'كشف طلابنا',
                      metric: '${store.students.length} طالب',
                      subtitle: 'جدول الطلاب مرتبا حسب القسم',
                      icon: Icons.table_chart_rounded,
                      color: const Color(0xFF0891B2),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const AdminStudentsReportPage(),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: width,
                    child: AdminNavButton(
                      title: 'الأساتذة',
                      metric: '${store.teachers.length} حساب',
                      subtitle: 'إنشاء ومتابعة حسابات الأساتذة',
                      icon: Icons.co_present_rounded,
                      color: const Color(0xFF0F766E),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const AdminTeachersPage(),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: width,
                    child: AdminNavButton(
                      title: 'الأقسام',
                      metric: '${store.courses.length} قسم',
                      subtitle: 'إنشاء الأقسام ومواد كل قسم',
                      icon: Icons.menu_book_rounded,
                      color: const Color(0xFF7C3AED),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const AdminCoursesPage(),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: width,
                    child: AdminNavButton(
                      title: 'محتوى الزائر',
                      metric:
                          '${store.guestVideos.length + store.archiveFiles.length} عنصر',
                      subtitle: 'الفيديوهات المجانية وملفات الأرشيف',
                      icon: Icons.public_rounded,
                      color: const Color(0xFFF97316),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const AdminGuestContentPage(),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class AdminStudentsReportPage extends StatefulWidget {
  const AdminStudentsReportPage({super.key});

  @override
  State<AdminStudentsReportPage> createState() =>
      _AdminStudentsReportPageState();
}

class _AdminStudentsReportPageState extends State<AdminStudentsReportPage> {
  static const allCoursesFilter = 'all';
  String selectedCourseId = allCoursesFilter;

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final courses = [...store.courses]
      ..sort((a, b) => a.title.compareTo(b.title));
    final students = [...store.students]
      ..sort((a, b) {
        final courseA = store.courseById(a.courseId)?.title ?? 'غير محدد';
        final courseB = store.courseById(b.courseId)?.title ?? 'غير محدد';
        final courseCompare = courseA.compareTo(courseB);
        if (courseCompare != 0) {
          return courseCompare;
        }
        return a.name.compareTo(b.name);
      });
    final filteredStudents = selectedCourseId == allCoursesFilter
        ? students
        : students
              .where((student) => student.courseId == selectedCourseId)
              .toList();

    return Scaffold(
      backgroundColor: const Color(0xFFF7F9FF),
      appBar: const EpsilonAppBar(title: 'كشف طلابنا', showLogout: false),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          AdminPageHeader(
            title: 'كشف طلابنا',
            subtitle: 'جدول منظم لجميع الطلاب مع فلترة حسب القسم',
            icon: Icons.table_chart_rounded,
            color: const Color(0xFF0891B2),
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: 'فلترة الكشف',
            icon: Icons.filter_alt_rounded,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: selectedCourseId,
                  decoration: const InputDecoration(
                    labelText: 'القسم',
                    prefixIcon: Icon(Icons.menu_book_rounded),
                  ),
                  items: [
                    const DropdownMenuItem(
                      value: allCoursesFilter,
                      child: Text('كل الأقسام'),
                    ),
                    ...courses.map(
                      (course) => DropdownMenuItem(
                        value: course.id,
                        child: Text(course.title),
                      ),
                    ),
                  ],
                  onChanged: (value) {
                    if (value == null) {
                      return;
                    }
                    setState(() => selectedCourseId = value);
                  },
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: ReportStatCard(
                        label: 'إجمالي الطلاب',
                        value: store.students.length.toString(),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ReportStatCard(
                        label: 'المعروض الآن',
                        value: filteredStudents.length.toString(),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: 'جدول الطلاب',
            icon: Icons.grid_on_rounded,
            child: filteredStudents.isEmpty
                ? const EmptyState(text: 'لا توجد حسابات طلاب في هذا القسم.')
                : LayoutBuilder(
                    builder: (context, constraints) {
                      return SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            minWidth: max(760, constraints.maxWidth),
                          ),
                          child: DataTable(
                            headingRowColor: WidgetStateProperty.all(
                              const Color(0xFFEAF6FB),
                            ),
                            border: TableBorder.all(
                              color: const Color(0xFFE2E8F0),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            columns: const [
                              DataColumn(label: Text('#')),
                              DataColumn(label: Text('الاسم')),
                              DataColumn(label: Text('البريد')),
                              DataColumn(label: Text('القسم')),
                              DataColumn(label: Text('الحالة')),
                              DataColumn(label: Text('رقم الدفع')),
                            ],
                            rows: [
                              for (
                                var index = 0;
                                index < filteredStudents.length;
                                index++
                              )
                                _studentReportRow(
                                  store,
                                  filteredStudents[index],
                                  index + 1,
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  DataRow _studentReportRow(SchoolStore store, AppUser student, int index) {
    final course = store.courseById(student.courseId);

    return DataRow(
      cells: [
        DataCell(Text(index.toString())),
        DataCell(Text(student.name)),
        DataCell(Text(student.email)),
        DataCell(Text(course?.title ?? 'غير محدد')),
        DataCell(Text(statusLabel(student.status))),
        DataCell(Text(student.paymentSenderPhone ?? '-')),
      ],
    );
  }
}

class ReportStatCard extends StatelessWidget {
  const ReportStatCard({required this.label, required this.value, super.key});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFEAF6FB),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFCDEAF4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: Color(0xFF0E7490),
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: const Color(0xFF164E63),
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

class AdminHeroPanel extends StatelessWidget {
  const AdminHeroPanel({
    required this.title,
    required this.subtitle,
    required this.value,
    super.key,
  });

  final String title;
  final String subtitle;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF2F5BEA),
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF2F5BEA).withValues(alpha: 0.22),
            blurRadius: 24,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: Color(0xFFE8EEFF),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          Container(
            width: 70,
            height: 70,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Colors.white24),
            ),
            child: Center(
              child: Text(
                value,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class AdminNavButton extends StatelessWidget {
  const AdminNavButton({
    required this.title,
    required this.metric,
    required this.subtitle,
    required this.icon,
    required this.color,
    required this.onTap,
    super.key,
  });

  final String title;
  final String metric;
  final String subtitle;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      shadowColor: const Color(0xFF1F2937).withValues(alpha: 0.08),
      elevation: 6,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(icon, color: color),
                  ),
                  const Spacer(),
                  const Icon(
                    Icons.arrow_back_rounded,
                    color: Color(0xFF9CA3AF),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                title,
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 6),
              Text(
                metric,
                style: TextStyle(color: color, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              Text(
                subtitle,
                style: const TextStyle(color: Color(0xFF6B7280), height: 1.4),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class AdminPageHeader extends StatelessWidget {
  const AdminPageHeader({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.color,
    super.key,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE8EEFF)),
      ),
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(icon, color: color, size: 28),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: Color(0xFF6B7280),
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class AccountStatusFilters extends StatelessWidget {
  const AccountStatusFilters({required this.students, super.key});

  final List<AppUser> students;

  int count(AccountStatus status) {
    return students.where((student) => student.status == status).length;
  }

  @override
  Widget build(BuildContext context) {
    final chips = [
      StatusFilterData(
        label: 'بانتظار الدفع',
        value: count(AccountStatus.pending),
        color: const Color(0xFFF59E0B),
      ),
      StatusFilterData(
        label: 'نشط',
        value: count(AccountStatus.active),
        color: const Color(0xFF10B981),
      ),
      StatusFilterData(
        label: 'مجمد',
        value: count(AccountStatus.blocked),
        color: const Color(0xFF64748B),
      ),
      StatusFilterData(
        label: 'مرفوض',
        value: count(AccountStatus.rejected),
        color: const Color(0xFFEF4444),
      ),
    ];

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: chips
            .map(
              (chip) => Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 9,
                  ),
                  decoration: BoxDecoration(
                    color: chip.color.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: chip.color.withValues(alpha: 0.18),
                    ),
                  ),
                  child: Row(
                    children: [
                      Text(
                        chip.value.toString(),
                        style: TextStyle(
                          color: chip.color,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        chip.label,
                        style: const TextStyle(
                          color: Color(0xFF374151),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            )
            .toList(),
      ),
    );
  }
}

class StatusFilterData {
  const StatusFilterData({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final int value;
  final Color color;
}

class AdminAccountsPage extends StatelessWidget {
  const AdminAccountsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final students = store.students;

    return Scaffold(
      backgroundColor: const Color(0xFFF7F9FF),
      appBar: const EpsilonAppBar(title: 'الحسابات'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          AdminPageHeader(
            title: 'مراجعة حسابات الطلاب',
            subtitle: 'تحقق من إثبات الدفع ثم قرر حالة الحساب',
            icon: Icons.receipt_long_rounded,
            color: const Color(0xFF2F5BEA),
          ),
          const SizedBox(height: 16),
          AccountStatusFilters(students: students),
          const SizedBox(height: 16),
          const CreateStudentForm(),
          const SizedBox(height: 16),
          SectionCard(
            title: 'طلبات الطلاب وإثباتات الدفع',
            icon: Icons.receipt_long_rounded,
            child: store.pendingStudents.isEmpty
                ? const EmptyState(text: 'لا توجد طلبات دفع بانتظار المراجعة.')
                : Column(
                    children: store.pendingStudents
                        .map((student) => PaymentReviewTile(user: student))
                        .toList(),
                  ),
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: 'كل حسابات الطلاب',
            icon: Icons.people_alt_rounded,
            child: students.isEmpty
                ? const EmptyState(text: 'لا توجد حسابات طلاب بعد.')
                : Column(
                    children: students
                        .map(
                          (student) => UserTile(
                            user: student,
                            trailing: AccountActionButton(user: student),
                          ),
                        )
                        .toList(),
                  ),
          ),
        ],
      ),
    );
  }
}

class PaymentReviewTile extends StatelessWidget {
  const PaymentReviewTile({required this.user, super.key});

  final AppUser user;

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFAFBFF),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE3E9FF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          UserTile(user: user, compact: true),
          InfoRow(
            label: 'رقم المرسل',
            value: user.paymentSenderPhone?.trim().isNotEmpty == true
                ? user.paymentSenderPhone!
                : 'غير مضاف',
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: PaymentProofPreview(
              imagePath: user.paymentProofPath,
              emptyText: 'لم تصل صورة إثبات دفع',
              height: 150,
            ),
          ),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => store.approveUser(user),
                  icon: const Icon(Icons.check_rounded),
                  label: const Text('قبول'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => store.blockUser(user),
                  icon: const Icon(Icons.pause_circle_outline_rounded),
                  label: const Text('تجميد'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => store.rejectUser(user),
                  icon: const Icon(Icons.close_rounded),
                  label: const Text('رفض'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class CreateStudentForm extends StatefulWidget {
  const CreateStudentForm({super.key});

  @override
  State<CreateStudentForm> createState() => _CreateStudentFormState();
}

class _CreateStudentFormState extends State<CreateStudentForm> {
  final nameController = TextEditingController();
  final emailController = TextEditingController();
  final passwordController = TextEditingController(text: '123456');
  String? courseId;

  @override
  void dispose() {
    nameController.dispose();
    emailController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    if (store.courses.isNotEmpty &&
        !store.courses.any((course) => course.id == courseId)) {
      courseId = store.courses.first.id;
    }

    return SectionCard(
      title: 'إنشاء حساب طالب',
      icon: Icons.person_add_alt_1_rounded,
      child: Column(
        children: [
          TextField(
            controller: nameController,
            decoration: const InputDecoration(labelText: 'اسم الطالب'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: emailController,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(labelText: 'البريد الإلكتروني'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: passwordController,
            decoration: const InputDecoration(labelText: 'كلمة المرور'),
          ),
          const SizedBox(height: 10),
          store.courses.isEmpty
              ? const EmptyState(text: 'أنشئ قسما قبل إضافة طالب.')
              : DropdownButtonFormField<String>(
                  initialValue: courseId,
                  decoration: const InputDecoration(labelText: 'القسم'),
                  items: store.courses
                      .map(
                        (course) => DropdownMenuItem(
                          value: course.id,
                          child: Text(course.title),
                        ),
                      )
                      .toList(),
                  onChanged: (value) => setState(() => courseId = value),
                ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: () {
                if (nameController.text.trim().isEmpty ||
                    emailController.text.trim().isEmpty ||
                    passwordController.text.length < 6 ||
                    courseId == null) {
                  return;
                }

                store.createStudentByAdmin(
                  name: nameController.text,
                  email: emailController.text,
                  password: passwordController.text,
                  courseId: courseId!,
                );
                nameController.clear();
                emailController.clear();
              },
              icon: const Icon(Icons.add_rounded),
              label: const Text('إضافة الطالب'),
            ),
          ),
        ],
      ),
    );
  }
}

class AdminTeachersPage extends StatelessWidget {
  const AdminTeachersPage({super.key});

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);

    return Scaffold(
      backgroundColor: const Color(0xFFF7F9FF),
      appBar: const EpsilonAppBar(title: 'الأساتذة'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          AdminPageHeader(
            title: 'إدارة الأساتذة',
            subtitle: 'اربط كل أستاذ بقسم ومادة واحدة',
            icon: Icons.co_present_rounded,
            color: const Color(0xFF0F766E),
          ),
          const SizedBox(height: 16),
          const CreateTeacherForm(),
          const SizedBox(height: 16),
          SectionCard(
            title: 'حسابات الأساتذة',
            icon: Icons.co_present_rounded,
            child: store.teachers.isEmpty
                ? const EmptyState(text: 'لا يوجد أساتذة بعد.')
                : Column(
                    children: store.teachers
                        .map(
                          (teacher) => UserTile(
                            user: teacher,
                            trailing: AccountActionButton(user: teacher),
                          ),
                        )
                        .toList(),
                  ),
          ),
        ],
      ),
    );
  }
}

class AdminCoursesPage extends StatelessWidget {
  const AdminCoursesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);

    return Scaffold(
      backgroundColor: const Color(0xFFF7F9FF),
      appBar: const EpsilonAppBar(title: 'الأقسام'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          AdminPageHeader(
            title: 'الأقسام والمواد',
            subtitle: 'أضف قسما مثل البكالوريا وحدد مواده',
            icon: Icons.menu_book_rounded,
            color: const Color(0xFF7C3AED),
          ),
          const SizedBox(height: 16),
          const PaymentNumberForm(),
          const SizedBox(height: 16),
          const CreateCourseForm(),
          const SizedBox(height: 16),
          SectionCard(
            title: 'الأقسام المضافة',
            icon: Icons.menu_book_rounded,
            child: store.courses.isEmpty
                ? const EmptyState(text: 'لا توجد أقسام بعد.')
                : Column(
                    children: store.courses
                        .map(
                          (course) => ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.menu_book_rounded),
                            title: Text(course.title),
                            isThreeLine: true,
                            subtitle: Text(
                              'السعر: ${course.price.trim().isEmpty ? 'غير محدد' : course.price}\nالمواد: ${course.subjects.join('، ')}',
                            ),
                            trailing: IconButton(
                              tooltip: 'حذف',
                              onPressed: () => store.deleteCourse(course),
                              icon: const Icon(Icons.delete_outline_rounded),
                            ),
                          ),
                        )
                        .toList(),
                  ),
          ),
        ],
      ),
    );
  }
}

class AdminGuestContentPage extends StatelessWidget {
  const AdminGuestContentPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F9FF),
      appBar: const EpsilonAppBar(title: 'محتوى الزائر'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          const AdminPageHeader(
            title: 'محتوى الزائر',
            subtitle: 'أضف روابط Google Drive التي تظهر قبل تسجيل الدخول',
            icon: Icons.public_rounded,
            color: Color(0xFFF97316),
          ),
          const SizedBox(height: 16),
          GuestActionCard(
            title: 'الفيديوهات المجانية',
            subtitle: 'إضافة وتعديل وحذف الفيديوهات المجانية',
            icon: Icons.play_circle_rounded,
            color: const Color(0xFF2F5BEA),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const AdminGuestContentManagerPage(
                  type: GuestContentType.video,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          GuestActionCard(
            title: 'الأرشيف PDF',
            subtitle: 'إضافة وتعديل وحذف ملفات PDF',
            icon: Icons.picture_as_pdf_rounded,
            color: const Color(0xFF0F766E),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const AdminGuestContentManagerPage(
                  type: GuestContentType.archive,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

enum GuestContentType { video, archive }

class AdminGuestContentManagerPage extends StatelessWidget {
  const AdminGuestContentManagerPage({required this.type, super.key});

  final GuestContentType type;

  bool get isVideo => type == GuestContentType.video;

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final items = isVideo ? store.guestVideos : store.archiveFiles;

    return Scaffold(
      backgroundColor: const Color(0xFFF7F9FF),
      appBar: EpsilonAppBar(
        title: isVideo ? 'الفيديوهات المجانية' : 'الأرشيف PDF',
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          AdminPageHeader(
            title: isVideo ? 'الفيديوهات المجانية' : 'الأرشيف PDF',
            subtitle: isVideo
                ? 'أضف روابط الفيديوهات المجانية وعدلها بسهولة'
                : 'أضف روابط ملفات PDF وعدلها بسهولة',
            icon: isVideo
                ? Icons.play_circle_rounded
                : Icons.picture_as_pdf_rounded,
            color: isVideo ? const Color(0xFF2F5BEA) : const Color(0xFF0F766E),
          ),
          const SizedBox(height: 16),
          GuestContentForm(type: type),
          const SizedBox(height: 16),
          GuestContentList(
            title: isVideo ? 'الفيديوهات المنشورة' : 'ملفات الأرشيف',
            icon: isVideo
                ? Icons.play_circle_rounded
                : Icons.picture_as_pdf_rounded,
            items: items,
            emptyText: isVideo
                ? 'لا توجد فيديوهات مجانية بعد.'
                : 'لا توجد ملفات في الأرشيف بعد.',
            type: type,
          ),
        ],
      ),
    );
  }
}

class GuestContentForm extends StatefulWidget {
  const GuestContentForm({required this.type, super.key});

  final GuestContentType type;

  @override
  State<GuestContentForm> createState() => _GuestContentFormState();
}

class _GuestContentFormState extends State<GuestContentForm> {
  final titleController = TextEditingController();
  final urlController = TextEditingController();
  final descriptionController = TextEditingController();
  String? selectedCourseId;

  bool get isVideo => widget.type == GuestContentType.video;

  @override
  void dispose() {
    titleController.dispose();
    urlController.dispose();
    descriptionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);

    return SectionCard(
      title: isVideo ? 'رفع فيديو مجاني' : 'رفع ملف للأرشيف',
      icon: isVideo ? Icons.play_circle_rounded : Icons.picture_as_pdf_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: titleController,
            decoration: InputDecoration(
              labelText: isVideo ? 'عنوان الفيديو' : 'عنوان الملف',
            ),
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            initialValue: selectedCourseId,
            decoration: const InputDecoration(
              labelText: 'القسم',
              prefixIcon: Icon(Icons.menu_book_rounded),
            ),
            items: store.courses
                .map(
                  (course) => DropdownMenuItem(
                    value: course.id,
                    child: Text(course.title),
                  ),
                )
                .toList(),
            onChanged: (value) => setState(() => selectedCourseId = value),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: urlController,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'رابط Google Drive',
              prefixIcon: Icon(Icons.link_rounded),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: descriptionController,
            minLines: 2,
            maxLines: 3,
            decoration: const InputDecoration(labelText: 'وصف مختصر'),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: () {
                if (titleController.text.trim().isEmpty ||
                    urlController.text.trim().isEmpty ||
                    selectedCourseId == null) {
                  return;
                }

                if (isVideo) {
                  store.addGuestVideo(
                    title: titleController.text,
                    url: urlController.text,
                    description: descriptionController.text,
                    courseId: selectedCourseId!,
                  );
                } else {
                  store.addArchiveFile(
                    title: titleController.text,
                    url: urlController.text,
                    description: descriptionController.text,
                    courseId: selectedCourseId!,
                  );
                }

                titleController.clear();
                urlController.clear();
                descriptionController.clear();
                setState(() => selectedCourseId = null);
              },
              icon: const Icon(Icons.add_rounded),
              label: Text(isVideo ? 'إضافة الفيديو' : 'إضافة الملف'),
            ),
          ),
        ],
      ),
    );
  }
}

class GuestContentList extends StatelessWidget {
  const GuestContentList({
    required this.title,
    required this.icon,
    required this.items,
    required this.emptyText,
    required this.type,
    super.key,
  });

  final String title;
  final IconData icon;
  final List<GuestContentItem> items;
  final String emptyText;
  final GuestContentType type;

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);

    return SectionCard(
      title: title,
      icon: icon,
      child: items.isEmpty
          ? EmptyState(text: emptyText)
          : Column(
              children: items
                  .map(
                    (item) => ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(icon),
                      title: Text(item.title),
                      subtitle: Text(
                        [
                          'القسم: ${store.courseById(item.courseId)?.title ?? 'غير محدد'}',
                          item.description.trim().isEmpty
                              ? item.url
                              : item.description,
                        ].join('\n'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'تعديل',
                            onPressed: () => showDialog<void>(
                              context: context,
                              builder: (_) => EditGuestContentDialog(
                                item: item,
                                type: type,
                              ),
                            ),
                            icon: const Icon(Icons.edit_rounded),
                          ),
                          IconButton(
                            tooltip: 'حذف',
                            onPressed: () {
                              if (type == GuestContentType.video) {
                                store.deleteGuestVideo(item);
                              } else {
                                store.deleteArchiveFile(item);
                              }
                            },
                            icon: const Icon(Icons.delete_outline_rounded),
                          ),
                        ],
                      ),
                    ),
                  )
                  .toList(),
            ),
    );
  }
}

class EditGuestContentDialog extends StatefulWidget {
  const EditGuestContentDialog({
    required this.item,
    required this.type,
    super.key,
  });

  final GuestContentItem item;
  final GuestContentType type;

  @override
  State<EditGuestContentDialog> createState() => _EditGuestContentDialogState();
}

class _EditGuestContentDialogState extends State<EditGuestContentDialog> {
  late final TextEditingController titleController;
  late final TextEditingController urlController;
  late final TextEditingController descriptionController;
  late String? selectedCourseId;

  bool get isVideo => widget.type == GuestContentType.video;

  @override
  void initState() {
    super.initState();
    titleController = TextEditingController(text: widget.item.title);
    urlController = TextEditingController(text: widget.item.url);
    descriptionController = TextEditingController(
      text: widget.item.description,
    );
    selectedCourseId = widget.item.courseId;
  }

  @override
  void dispose() {
    titleController.dispose();
    urlController.dispose();
    descriptionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);

    return AlertDialog(
      title: Text(isVideo ? 'تعديل الفيديو' : 'تعديل الملف'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: titleController,
              decoration: InputDecoration(
                labelText: isVideo ? 'عنوان الفيديو' : 'عنوان الملف',
              ),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              initialValue: selectedCourseId,
              decoration: const InputDecoration(
                labelText: 'القسم',
                prefixIcon: Icon(Icons.menu_book_rounded),
              ),
              items: store.courses
                  .map(
                    (course) => DropdownMenuItem(
                      value: course.id,
                      child: Text(course.title),
                    ),
                  )
                  .toList(),
              onChanged: (value) => setState(() => selectedCourseId = value),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: urlController,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'رابط Google Drive',
                prefixIcon: Icon(Icons.link_rounded),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: descriptionController,
              minLines: 2,
              maxLines: 3,
              decoration: const InputDecoration(labelText: 'وصف مختصر'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('إلغاء'),
        ),
        FilledButton(
          onPressed: () {
            if (titleController.text.trim().isEmpty ||
                urlController.text.trim().isEmpty ||
                selectedCourseId == null) {
              return;
            }

            if (isVideo) {
              store.updateGuestVideo(
                item: widget.item,
                title: titleController.text,
                url: urlController.text,
                description: descriptionController.text,
                courseId: selectedCourseId!,
              );
            } else {
              store.updateArchiveFile(
                item: widget.item,
                title: titleController.text,
                url: urlController.text,
                description: descriptionController.text,
                courseId: selectedCourseId!,
              );
            }
            Navigator.of(context).pop();
          },
          child: const Text('حفظ'),
        ),
      ],
    );
  }
}

class TeacherDashboard extends StatelessWidget {
  const TeacherDashboard({super.key});

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final teacher = store.currentUser!;
    final teacherSection = store.courseById(teacher.courseId);
    final teacherSections = store.courses
        .where(
          (course) =>
              course.id == teacher.courseId &&
              course.subjects.contains(teacher.subject),
        )
        .toList();
    final teacherLessons =
        store.lessons.where((lesson) => lesson.teacherId == teacher.id).toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

    return Scaffold(
      backgroundColor: const Color(0xFFF7F9FF),
      appBar: const EpsilonAppBar(title: 'لوحة الأستاذ'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          HeaderPanel(
            title: 'مرحبًا ${teacher.name}',
            subtitle:
                '${teacher.subject ?? 'مادة عامة'} - ${teacherSection?.title ?? 'بدون قسم'}',
            icon: Icons.co_present_rounded,
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: 'مادتي داخل القسم',
            icon: Icons.subject_rounded,
            child: teacherSections.isEmpty
                ? const EmptyState(text: 'لا يوجد قسم مرتبط بمادتك حاليا.')
                : Column(
                    children: teacherSections
                        .map(
                          (course) => ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(
                              courseIcon(course.title),
                              color: courseAccent(course.title),
                            ),
                            title: Text(course.title),
                            subtitle: Text(
                              'المادة: ${teacher.subject ?? 'مادة عامة'}',
                            ),
                          ),
                        )
                        .toList(),
                  ),
          ),
          const SizedBox(height: 16),
          const CreateLessonForm(),
          const SizedBox(height: 16),
          SectionCard(
            title: 'إدارة دروسي',
            icon: Icons.video_library_rounded,
            child: teacherLessons.isEmpty
                ? const EmptyState(text: 'لم تقم بإضافة دروس بعد.')
                : Column(
                    children: teacherLessons
                        .map((lesson) => TeacherLessonTile(lesson: lesson))
                        .toList(),
                  ),
          ),
        ],
      ),
    );
  }
}

class StudentDashboard extends StatelessWidget {
  const StudentDashboard({super.key});

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final student = store.currentUser!;
    final selectedSection = store.courseById(student.courseId);
    final visibleSections = store.courses
        .where(
          (course) =>
              course.isActive &&
              (student.courseId == null || course.id == student.courseId),
        )
        .toList();
    final visibleLessons =
        store.lessons
            .where(
              (lesson) =>
                  lesson.isPublished &&
                  (student.courseId == null ||
                      lesson.courseId == student.courseId),
            )
            .toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final lessonsBySubject = <String, List<Lesson>>{};
    for (final subject in selectedSection?.subjects ?? <String>[]) {
      lessonsBySubject[subject] = [];
    }
    for (final lesson in visibleLessons) {
      lessonsBySubject.putIfAbsent(lesson.subject, () => []).add(lesson);
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF7F9FF),
      appBar: const EpsilonAppBar(title: 'دروسي'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          HeaderPanel(
            title: 'مرحبًا ${student.name}',
            subtitle: selectedSection == null
                ? 'لم يتم ربطك بقسم بعد'
                : 'قسم ${selectedSection.title}',
            icon: Icons.person_rounded,
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: 'قسمي',
            icon: Icons.menu_book_rounded,
            child: visibleSections.isEmpty
                ? const EmptyState(text: 'لا يوجد قسم مفعل لهذا الحساب.')
                : Column(
                    children: visibleSections
                        .map(
                          (course) => ListTile(
                            leading: const Icon(Icons.book_rounded),
                            title: Text(course.title),
                            subtitle: Text(
                              'المواد: ${course.subjects.join('، ')}',
                            ),
                          ),
                        )
                        .toList(),
                  ),
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: 'مواد قسمي',
            icon: Icons.folder_special_rounded,
            child: lessonsBySubject.isEmpty
                ? const EmptyState(text: 'لا توجد مواد في هذا القسم.')
                : Column(
                    children: lessonsBySubject.entries
                        .map(
                          (entry) => SubjectCard(
                            subject: entry.key,
                            lessons: entry.value,
                          ),
                        )
                        .toList(),
                  ),
          ),
        ],
      ),
    );
  }
}

class CreateTeacherForm extends StatefulWidget {
  const CreateTeacherForm({super.key});

  @override
  State<CreateTeacherForm> createState() => _CreateTeacherFormState();
}

class _CreateTeacherFormState extends State<CreateTeacherForm> {
  final nameController = TextEditingController();
  final emailController = TextEditingController();
  final passwordController = TextEditingController(text: '123456');
  String? classId;
  String? courseId;
  String? subject;
  String? message;
  bool isSaving = false;

  @override
  void dispose() {
    nameController.dispose();
    emailController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final availableSections = store.courses;
    if (availableSections.isNotEmpty &&
        !availableSections.any((course) => course.id == courseId)) {
      courseId = availableSections.first.id;
      classId = availableSections.first.classId;
      subject = availableSections.first.subjects.firstOrNull;
    }
    final selectedCourse = store.courseById(courseId);
    if (selectedCourse != null && !selectedCourse.subjects.contains(subject)) {
      subject = selectedCourse.subjects.firstOrNull;
    }

    return SectionCard(
      title: 'إنشاء حساب أستاذ',
      icon: Icons.person_add_rounded,
      child: Column(
        children: [
          TextField(
            controller: nameController,
            decoration: const InputDecoration(labelText: 'اسم الأستاذ'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: emailController,
            decoration: const InputDecoration(labelText: 'البريد الإلكتروني'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: passwordController,
            decoration: const InputDecoration(labelText: 'كلمة المرور'),
          ),
          const SizedBox(height: 10),
          availableSections.isEmpty
              ? const EmptyState(text: 'أنشئ قسما قبل إضافة أستاذ.')
              : DropdownButtonFormField<String>(
                  initialValue: courseId,
                  decoration: const InputDecoration(labelText: 'القسم'),
                  items: availableSections
                      .map(
                        (course) => DropdownMenuItem(
                          value: course.id,
                          child: Text(course.title),
                        ),
                      )
                      .toList(),
                  onChanged: (value) => setState(() {
                    courseId = value;
                    final section = store.courseById(value);
                    classId = section?.classId;
                    subject = section?.subjects.firstOrNull;
                  }),
                ),
          const SizedBox(height: 10),
          selectedCourse == null
              ? const EmptyState(text: 'اختر القسم لتظهر مواده.')
              : DropdownButtonFormField<String>(
                  initialValue: subject,
                  decoration: const InputDecoration(labelText: 'المادة'),
                  items: selectedCourse.subjects
                      .map(
                        (item) =>
                            DropdownMenuItem(value: item, child: Text(item)),
                      )
                      .toList(),
                  onChanged: (value) => setState(() => subject = value),
                ),
          const SizedBox(height: 12),
          if (message != null) ...[
            Text(
              message!,
              style: TextStyle(
                color: message!.startsWith('تم')
                    ? Colors.green.shade700
                    : Colors.red.shade700,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 10),
          ],
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: isSaving
                  ? null
                  : () async {
                      if (nameController.text.trim().isEmpty ||
                          emailController.text.trim().isEmpty ||
                          passwordController.text.length < 6 ||
                          classId == null ||
                          courseId == null ||
                          subject == null) {
                        setState(() {
                          message =
                              'أكمل البيانات وتأكد أن كلمة المرور 6 أحرف على الأقل.';
                        });
                        return;
                      }

                      setState(() {
                        isSaving = true;
                        message = null;
                      });

                      try {
                        await store.createTeacher(
                          name: nameController.text,
                          email: emailController.text,
                          password: passwordController.text,
                          classId: classId!,
                          courseId: courseId!,
                          subject: subject!,
                        );
                        if (!mounted) {
                          return;
                        }
                        nameController.clear();
                        emailController.clear();
                        setState(
                          () => message = 'تم إنشاء حساب الأستاذ بنجاح.',
                        );
                      } on Object catch (error) {
                        if (!mounted) {
                          return;
                        }
                        setState(
                          () => message =
                              'فشل إنشاء الأستاذ: ${friendlyFirebaseError(error)}',
                        );
                      } finally {
                        if (mounted) {
                          setState(() => isSaving = false);
                        }
                      }
                    },
              icon: const Icon(Icons.add_rounded),
              label: Text(isSaving ? 'جار الإضافة...' : 'إضافة الأستاذ'),
            ),
          ),
        ],
      ),
    );
  }
}

class CreateCourseForm extends StatefulWidget {
  const CreateCourseForm({super.key});

  @override
  State<CreateCourseForm> createState() => _CreateCourseFormState();
}

class _CreateCourseFormState extends State<CreateCourseForm> {
  final titleController = TextEditingController();
  final descriptionController = TextEditingController();
  final priceController = TextEditingController();
  final subjectsController = TextEditingController(
    text: 'الرياضيات، الفيزياء، الكيمياء',
  );

  @override
  void dispose() {
    titleController.dispose();
    descriptionController.dispose();
    priceController.dispose();
    subjectsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);

    return SectionCard(
      title: 'إنشاء قسم',
      icon: Icons.add_circle_outline_rounded,
      child: Column(
        children: [
          TextField(
            controller: titleController,
            decoration: const InputDecoration(labelText: 'اسم القسم'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: descriptionController,
            minLines: 2,
            maxLines: 3,
            decoration: const InputDecoration(labelText: 'وصف القسم'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: priceController,
            keyboardType: TextInputType.text,
            decoration: const InputDecoration(
              labelText: 'سعر الانضمام لهذا القسم',
              hintText: 'مثال: 500 أوقية',
              prefixIcon: Icon(Icons.sell_rounded),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: subjectsController,
            minLines: 1,
            maxLines: 2,
            decoration: const InputDecoration(
              labelText: 'مواد القسم',
              hintText: 'مثال: رياضيات، فيزياء، كيمياء',
            ),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: () {
                if (titleController.text.trim().isEmpty) {
                  return;
                }
                store.createCourse(
                  title: titleController.text,
                  classId: store.defaultClassId,
                  description: descriptionController.text.trim().isEmpty
                      ? 'دروس وتمارين وملخصات منظمة للطلاب'
                      : descriptionController.text,
                  price: priceController.text,
                  subjects: parseSubjects(subjectsController.text),
                );
                titleController.clear();
                descriptionController.clear();
                priceController.clear();
              },
              icon: const Icon(Icons.add_rounded),
              label: const Text('إضافة القسم'),
            ),
          ),
        ],
      ),
    );
  }
}

class PaymentNumberForm extends StatefulWidget {
  const PaymentNumberForm({super.key});

  @override
  State<PaymentNumberForm> createState() => _PaymentNumberFormState();
}

class _PaymentNumberFormState extends State<PaymentNumberForm> {
  final numberController = TextEditingController();
  final amountController = TextEditingController();
  bool initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!initialized) {
      numberController.text = StoreScope.of(context).paymentNumber;
      amountController.text = StoreScope.of(context).paymentAmount;
      initialized = true;
    }
  }

  @override
  void dispose() {
    numberController.dispose();
    amountController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);

    return SectionCard(
      title: 'إعدادات الدفع',
      icon: Icons.payments_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: amountController,
            keyboardType: TextInputType.text,
            decoration: const InputDecoration(
              labelText: 'سعر افتراضي عند عدم تحديد سعر القسم',
              prefixIcon: Icon(Icons.sell_rounded),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: numberController,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(
              labelText: 'رقم الدفع الذي يظهر للطلاب',
              prefixIcon: Icon(Icons.phone_android_rounded),
            ),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: () {
                store.updatePaymentAmount(amountController.text);
                store.updatePaymentNumber(numberController.text);
              },
              icon: const Icon(Icons.save_rounded),
              label: const Text('حفظ إعدادات الدفع'),
            ),
          ),
        ],
      ),
    );
  }
}

class CreateClassForm extends StatefulWidget {
  const CreateClassForm({super.key});

  @override
  State<CreateClassForm> createState() => _CreateClassFormState();
}

class _CreateClassFormState extends State<CreateClassForm> {
  final nameController = TextEditingController();
  final levelController = TextEditingController();

  @override
  void dispose() {
    nameController.dispose();
    levelController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);

    return SectionCard(
      title: 'إنشاء قسم',
      icon: Icons.add_business_rounded,
      child: Column(
        children: [
          TextField(
            controller: nameController,
            decoration: const InputDecoration(labelText: 'اسم القسم'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: levelController,
            decoration: const InputDecoration(labelText: 'المستوى'),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: () {
                if (nameController.text.trim().isEmpty ||
                    levelController.text.trim().isEmpty) {
                  return;
                }

                store.createClass(
                  name: nameController.text,
                  level: levelController.text,
                );
                nameController.clear();
                levelController.clear();
              },
              icon: const Icon(Icons.add_rounded),
              label: const Text('إضافة القسم'),
            ),
          ),
        ],
      ),
    );
  }
}

class CreateLessonForm extends StatefulWidget {
  const CreateLessonForm({super.key});

  @override
  State<CreateLessonForm> createState() => _CreateLessonFormState();
}

class _CreateLessonFormState extends State<CreateLessonForm> {
  final titleController = TextEditingController();
  final urlController = TextEditingController();
  String? courseId;

  @override
  void dispose() {
    titleController.dispose();
    urlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final teacher = store.currentUser!;
    final availableCourses = store.courses
        .where(
          (course) =>
              course.id == teacher.courseId &&
              course.subjects.contains(teacher.subject),
        )
        .toList();

    if (availableCourses.isEmpty) {
      return const SectionCard(
        title: 'إضافة درس',
        icon: Icons.add_link_rounded,
        child: EmptyState(text: 'لا يوجد قسم يحتوي على مادتك حاليا.'),
      );
    }

    courseId ??= availableCourses.first.id;

    return SectionCard(
      title: 'إضافة رابط درس',
      icon: Icons.add_link_rounded,
      child: Column(
        children: [
          TextField(
            controller: titleController,
            decoration: const InputDecoration(labelText: 'عنوان الدرس'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: urlController,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'رابط فيديو Google Drive',
              hintText: 'ضع رابط المشاركة من Google Drive',
            ),
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            initialValue: courseId,
            decoration: const InputDecoration(labelText: 'القسم'),
            items: availableCourses
                .map(
                  (course) => DropdownMenuItem(
                    value: course.id,
                    child: Text(course.title),
                  ),
                )
                .toList(),
            onChanged: (value) => setState(() => courseId = value),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: () {
                if (titleController.text.trim().isEmpty ||
                    urlController.text.trim().isEmpty ||
                    teacher.classId == null ||
                    courseId == null) {
                  return;
                }

                store.createLesson(
                  title: titleController.text,
                  url: urlController.text,
                  classId: teacher.classId!,
                  courseId: courseId!,
                );
                titleController.clear();
                urlController.clear();
              },
              icon: const Icon(Icons.publish_rounded),
              label: const Text('نشر الدرس'),
            ),
          ),
        ],
      ),
    );
  }
}

class EpsilonAppBar extends StatelessWidget implements PreferredSizeWidget {
  const EpsilonAppBar({required this.title, this.showLogout = true, super.key});

  final String title;
  final bool showLogout;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    final canGoBack = Navigator.of(context).canPop();
    final store = StoreScope.of(context);
    final unreadCount = store.unreadNotificationCount;

    return AppBar(
      backgroundColor: const Color(0xFFF7F9FF),
      surfaceTintColor: const Color(0xFFF7F9FF),
      elevation: 0,
      leading: canGoBack
          ? IconButton(
              tooltip: 'رجوع',
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.arrow_back_rounded),
            )
          : showLogout
          ? IconButton(
              tooltip: 'الإعدادات',
              onPressed: () => Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const SettingsPage())),
              icon: const Icon(Icons.settings_rounded),
            )
          : null,
      title: const SizedBox.shrink(),
      actions: showLogout
          ? [
              IconButton(
                tooltip: 'الإشعارات',
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const NotificationsPage()),
                ),
                icon: NotificationBellIcon(unreadCount: unreadCount),
              ),
              IconButton(
                tooltip: 'خروج',
                onPressed: () => store.logout(),
                icon: const Icon(Icons.logout_rounded),
              ),
            ]
          : null,
    );
  }
}

class NotificationBellIcon extends StatelessWidget {
  const NotificationBellIcon({required this.unreadCount, super.key});

  final int unreadCount;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        const Icon(Icons.notifications_rounded),
        if (unreadCount > 0)
          Positioned(
            right: -5,
            top: -6,
            child: Container(
              constraints: const BoxConstraints(minWidth: 17, minHeight: 17),
              padding: const EdgeInsets.symmetric(horizontal: 4),
              decoration: BoxDecoration(
                color: const Color(0xFFEF4444),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: Colors.white, width: 1.5),
              ),
              alignment: Alignment.center,
              child: Text(
                unreadCount > 9 ? '9+' : unreadCount.toString(),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.w900,
                  height: 1,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final currentPasswordController = TextEditingController();
  final newPasswordController = TextEditingController();
  final confirmPasswordController = TextEditingController();
  String? message;
  bool success = false;

  @override
  void dispose() {
    currentPasswordController.dispose();
    newPasswordController.dispose();
    confirmPasswordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final user = store.currentUser;

    return Scaffold(
      backgroundColor: const Color(0xFFF7F9FF),
      appBar: const EpsilonAppBar(title: 'الإعدادات', showLogout: false),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          HeaderPanel(
            title: user?.name ?? 'الحساب',
            subtitle: user == null
                ? 'إعدادات الحساب'
                : '${roleLabel(user.role)} - ${statusLabel(user.status)}',
            icon: Icons.settings_rounded,
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: 'معلومات الحساب',
            icon: Icons.account_circle_rounded,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                InfoRow(label: 'الاسم', value: user?.name ?? '-'),
                InfoRow(label: 'البريد', value: user?.email ?? '-'),
                InfoRow(label: 'الدور', value: roleLabel(user?.role)),
              ],
            ),
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: 'تغيير كلمة المرور',
            icon: Icons.lock_reset_rounded,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: currentPasswordController,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'كلمة المرور الحالية',
                    prefixIcon: Icon(Icons.lock_outline_rounded),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: newPasswordController,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'كلمة المرور الجديدة',
                    prefixIcon: Icon(Icons.password_rounded),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: confirmPasswordController,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'تأكيد كلمة المرور',
                    prefixIcon: Icon(Icons.verified_user_outlined),
                  ),
                ),
                if (message != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    message!,
                    style: TextStyle(
                      color: success
                          ? Colors.green.shade700
                          : Colors.red.shade700,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
                const SizedBox(height: 14),
                FilledButton.icon(
                  onPressed: () async {
                    if (newPasswordController.text !=
                        confirmPasswordController.text) {
                      setState(() {
                        success = false;
                        message = 'كلمة المرور الجديدة غير متطابقة.';
                      });
                      return;
                    }

                    final changed = await store.changeCurrentPassword(
                      currentPassword: currentPasswordController.text,
                      newPassword: newPasswordController.text,
                    );
                    if (!mounted) {
                      return;
                    }

                    setState(() {
                      success = changed;
                      message = changed
                          ? 'تم تغيير كلمة المرور بنجاح.'
                          : 'تأكد من كلمة المرور الحالية وأن الجديدة 6 أحرف على الأقل.';
                    });

                    if (changed) {
                      currentPasswordController.clear();
                      newPasswordController.clear();
                      confirmPasswordController.clear();
                    }
                  },
                  icon: const Icon(Icons.save_rounded),
                  label: const Text('حفظ كلمة المرور'),
                ),
              ],
            ),
          ),
          SectionCard(
            title: 'اللغة',
            icon: Icons.language_rounded,
            child: LanguageSettings(languageCode: store.languageCode),
          ),
        ],
      ),
    );
  }
}

class NotificationsPage extends StatefulWidget {
  const NotificationsPage({super.key});

  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<NotificationsPage> {
  final titleController = TextEditingController();
  final bodyController = TextEditingController();
  bool isPublishing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      unawaited(StoreScope.of(context).markNotificationsRead());
    });
  }

  @override
  void dispose() {
    titleController.dispose();
    bodyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final canPublish = store.currentUser?.role == UserRole.admin;

    return Scaffold(
      backgroundColor: const Color(0xFFF7F9FF),
      appBar: const EpsilonAppBar(title: 'الإشعارات', showLogout: false),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          HeaderPanel(
            title: 'الإشعارات',
            subtitle: canPublish
                ? 'اكتب إشعارا ليظهر لجميع المستخدمين'
                : 'آخر الرسائل والتنبيهات من الإدارة',
            icon: Icons.notifications_active_rounded,
          ),
          const SizedBox(height: 16),
          if (canPublish) ...[
            SectionCard(
              title: 'نشر إشعار',
              icon: Icons.campaign_rounded,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: titleController,
                    textAlign: TextAlign.right,
                    textDirection: TextDirection.rtl,
                    decoration: const InputDecoration(
                      labelText: 'عنوان الإشعار',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: bodyController,
                    textAlign: TextAlign.right,
                    textDirection: TextDirection.rtl,
                    minLines: 2,
                    maxLines: 3,
                    decoration: const InputDecoration(labelText: 'نص الإشعار'),
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton.icon(
                      onPressed: isPublishing
                          ? null
                          : () async {
                              if (titleController.text.trim().isEmpty ||
                                  bodyController.text.trim().isEmpty) {
                                return;
                              }

                              setState(() => isPublishing = true);
                              try {
                                await store.addNotification(
                                  title: titleController.text,
                                  body: bodyController.text,
                                );
                                titleController.clear();
                                bodyController.clear();
                                if (!context.mounted) {
                                  return;
                                }
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('تم نشر الإشعار للجميع'),
                                  ),
                                );
                              } catch (_) {
                                if (!context.mounted) {
                                  return;
                                }
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      store.lastError ??
                                          'تعذر نشر الإشعار. تحقق من صلاحية الأدمن.',
                                    ),
                                  ),
                                );
                              } finally {
                                if (mounted) {
                                  setState(() => isPublishing = false);
                                }
                              }
                            },
                      icon: isPublishing
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.send_rounded),
                      label: Text(
                        isPublishing ? 'جاري النشر...' : 'نشر للجميع',
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],
          SectionCard(
            title: 'كل الإشعارات',
            icon: Icons.notifications_none_rounded,
            child: store.notifications.isEmpty
                ? const EmptyState(text: 'لا توجد إشعارات حاليا.')
                : Column(
                    children: store.notifications
                        .map(
                          (item) => NotificationTile(
                            notification: item,
                            canManage: canPublish,
                          ),
                        )
                        .toList(),
                  ),
          ),
        ],
      ),
    );
  }
}

class NotificationTile extends StatelessWidget {
  const NotificationTile({
    required this.notification,
    required this.canManage,
    super.key,
  });

  final AppNotification notification;
  final bool canManage;

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const CircleAvatar(
        backgroundColor: Color(0xFFEAF1FF),
        child: Icon(
          Icons.notifications_active_rounded,
          color: Color(0xFF2F5BEA),
        ),
      ),
      title: Text(notification.title),
      subtitle: Text(notification.body),
      trailing: canManage
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'تعديل',
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) =>
                        EditNotificationDialog(notification: notification),
                  ),
                  icon: const Icon(Icons.edit_rounded),
                ),
                IconButton(
                  tooltip: 'حذف',
                  onPressed: () async {
                    final confirm = await showDialog<bool>(
                      context: context,
                      builder: (_) =>
                          DeleteNotificationDialog(notification: notification),
                    );
                    if (confirm != true || !context.mounted) {
                      return;
                    }

                    try {
                      await store.deleteNotification(notification);
                      if (!context.mounted) {
                        return;
                      }
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('تم حذف الإشعار')),
                      );
                    } catch (_) {
                      if (!context.mounted) {
                        return;
                      }
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(store.lastError ?? 'تعذر حذف الإشعار.'),
                        ),
                      );
                    }
                  },
                  icon: const Icon(Icons.delete_outline_rounded),
                ),
              ],
            )
          : null,
    );
  }
}

class EditNotificationDialog extends StatefulWidget {
  const EditNotificationDialog({required this.notification, super.key});

  final AppNotification notification;

  @override
  State<EditNotificationDialog> createState() => _EditNotificationDialogState();
}

class _EditNotificationDialogState extends State<EditNotificationDialog> {
  late final TextEditingController titleController;
  late final TextEditingController bodyController;
  bool isSaving = false;

  @override
  void initState() {
    super.initState();
    titleController = TextEditingController(text: widget.notification.title);
    bodyController = TextEditingController(text: widget.notification.body);
  }

  @override
  void dispose() {
    titleController.dispose();
    bodyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);

    return AlertDialog(
      title: const Text('تعديل الإشعار'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: titleController,
              textAlign: TextAlign.right,
              textDirection: TextDirection.rtl,
              decoration: const InputDecoration(labelText: 'عنوان الإشعار'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: bodyController,
              textAlign: TextAlign.right,
              textDirection: TextDirection.rtl,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(labelText: 'نص الإشعار'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: isSaving ? null : () => Navigator.of(context).pop(),
          child: const Text('إلغاء'),
        ),
        FilledButton(
          onPressed: isSaving
              ? null
              : () async {
                  if (titleController.text.trim().isEmpty ||
                      bodyController.text.trim().isEmpty) {
                    return;
                  }

                  setState(() => isSaving = true);
                  try {
                    await store.updateNotification(
                      notification: widget.notification,
                      title: titleController.text,
                      body: bodyController.text,
                    );
                    if (!context.mounted) {
                      return;
                    }
                    Navigator.of(context).pop();
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('تم تعديل الإشعار')),
                    );
                  } catch (_) {
                    if (!context.mounted) {
                      return;
                    }
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(store.lastError ?? 'تعذر تعديل الإشعار.'),
                      ),
                    );
                  } finally {
                    if (mounted) {
                      setState(() => isSaving = false);
                    }
                  }
                },
          child: Text(isSaving ? 'جار الحفظ...' : 'حفظ'),
        ),
      ],
    );
  }
}

class DeleteNotificationDialog extends StatelessWidget {
  const DeleteNotificationDialog({required this.notification, super.key});

  final AppNotification notification;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('حذف الإشعار'),
      content: Text('هل تريد حذف "${notification.title}"؟'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('إلغاء'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('حذف'),
        ),
      ],
    );
  }
}

class LanguageSettings extends StatelessWidget {
  const LanguageSettings({required this.languageCode, super.key});

  final String languageCode;

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);

    return SegmentedButton<String>(
      segments: const [
        ButtonSegment(value: 'ar', label: Text('العربية')),
        ButtonSegment(value: 'fr', label: Text('Français')),
      ],
      selected: {languageCode},
      onSelectionChanged: (values) => store.setLanguageCode(values.first),
    );
  }
}

class SectionCard extends StatelessWidget {
  const SectionCard({
    required this.title,
    required this.icon,
    required this.child,
    super.key,
  });

  final String title;
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE8EEFF)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF1F2937).withValues(alpha: 0.04),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: const Color(0xFF2F5BEA).withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, color: const Color(0xFF2F5BEA), size: 20),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

class HeaderPanel extends StatelessWidget {
  const HeaderPanel({
    required this.title,
    required this.subtitle,
    required this.icon,
    super.key,
  });

  final String title;
  final String subtitle;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF2F5BEA),
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF2F5BEA).withValues(alpha: 0.18),
            blurRadius: 22,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Row(
        children: [
          Icon(icon, color: Colors.white, size: 44),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: const TextStyle(color: Color(0xFFE8EEFF)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class UserTile extends StatelessWidget {
  const UserTile({
    required this.user,
    this.trailing,
    this.compact = false,
    super.key,
  });

  final AppUser user;
  final Widget? trailing;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final course = store.courseById(user.courseId);

    return Container(
      margin: EdgeInsets.only(bottom: compact ? 0 : 10),
      padding: EdgeInsets.all(compact ? 0 : 12),
      decoration: compact
          ? null
          : BoxDecoration(
              color: const Color(0xFFFAFBFF),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFFE8EEFF)),
            ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 23,
                backgroundColor: const Color(0xFF2F5BEA).withValues(alpha: 0.1),
                child: Icon(
                  user.role == UserRole.teacher
                      ? Icons.co_present_rounded
                      : Icons.person_rounded,
                  color: const Color(0xFF2F5BEA),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      user.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      [
                        user.email,
                        if (course != null) course.title,
                      ].join(' - '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      softWrap: false,
                      style: const TextStyle(
                        color: Color(0xFF6B7280),
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 8),
                    StatusBadge(status: user.status),
                  ],
                ),
              ),
            ],
          ),
          if (trailing != null) ...[
            const SizedBox(height: 12),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: trailing!,
            ),
          ],
        ],
      ),
    );
  }
}

class StatusBadge extends StatelessWidget {
  const StatusBadge({required this.status, super.key});

  final AccountStatus status;

  Color get color {
    return switch (status) {
      AccountStatus.pending => const Color(0xFFF59E0B),
      AccountStatus.active => const Color(0xFF10B981),
      AccountStatus.blocked => const Color(0xFF64748B),
      AccountStatus.rejected => const Color(0xFFEF4444),
    };
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          statusLabel(status),
          style: TextStyle(
            color: color,
            fontSize: 11,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
    );
  }
}

class AccountActionButton extends StatelessWidget {
  const AccountActionButton({required this.user, super.key});

  final AppUser user;

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final blocked = user.status == AccountStatus.blocked;

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      alignment: WrapAlignment.start,
      children: [
        OutlinedButton.icon(
          onPressed: () =>
              blocked ? store.activateUser(user) : store.blockUser(user),
          icon: Icon(
            blocked
                ? Icons.lock_open_rounded
                : Icons.pause_circle_outline_rounded,
          ),
          label: Text(blocked ? 'تفعيل' : 'تجميد'),
        ),
        OutlinedButton.icon(
          onPressed: () => showDialog<void>(
            context: context,
            builder: (_) => DeleteAccountDialog(user: user),
          ),
          icon: const Icon(Icons.delete_outline_rounded),
          label: const Text('حذف'),
        ),
      ],
    );
  }
}

class DeleteAccountDialog extends StatefulWidget {
  const DeleteAccountDialog({required this.user, super.key});

  final AppUser user;

  @override
  State<DeleteAccountDialog> createState() => _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends State<DeleteAccountDialog> {
  bool isDeleting = false;
  String? error;

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);

    return AlertDialog(
      title: const Text('حذف الحساب'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('هل تريد حذف حساب "${widget.user.name}" نهائيا؟'),
          if (error != null) ...[
            const SizedBox(height: 10),
            Text(error!, style: TextStyle(color: Colors.red.shade700)),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: isDeleting ? null : () => Navigator.of(context).pop(),
          child: const Text('إلغاء'),
        ),
        FilledButton(
          onPressed: isDeleting
              ? null
              : () async {
                  setState(() {
                    isDeleting = true;
                    error = null;
                  });
                  try {
                    await store.deleteUser(widget.user);
                    if (context.mounted) {
                      Navigator.of(context).pop();
                    }
                  } on Object catch (exception) {
                    if (mounted) {
                      setState(() {
                        isDeleting = false;
                        error =
                            'تعذر حذف الحساب: ${friendlyFirebaseError(exception)}';
                      });
                    }
                  }
                },
          child: Text(isDeleting ? 'جار الحذف...' : 'حذف'),
        ),
      ],
    );
  }
}

class TeacherLessonTile extends StatelessWidget {
  const TeacherLessonTile({required this.lesson, super.key});

  final Lesson lesson;

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final course = store.courseById(lesson.courseId);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFAFBFF),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE8EEFF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const CircleAvatar(
                backgroundColor: Color(0xFFEAF1FF),
                child: Icon(
                  Icons.play_circle_rounded,
                  color: Color(0xFF2F5BEA),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      lesson.title,
                      style: const TextStyle(fontWeight: FontWeight.w900),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${course?.title ?? 'قسم'} - ${lesson.subject}',
                      style: const TextStyle(
                        color: Color(0xFF6B7280),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => SecureVideoPage(lesson: lesson),
                  ),
                ),
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('تشغيل'),
              ),
              OutlinedButton.icon(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => EditLessonDialog(lesson: lesson),
                ),
                icon: const Icon(Icons.edit_rounded),
                label: const Text('تعديل'),
              ),
              OutlinedButton.icon(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => DeleteLessonDialog(lesson: lesson),
                ),
                icon: const Icon(Icons.delete_outline_rounded),
                label: const Text('حذف'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class EditLessonDialog extends StatefulWidget {
  const EditLessonDialog({required this.lesson, super.key});

  final Lesson lesson;

  @override
  State<EditLessonDialog> createState() => _EditLessonDialogState();
}

class _EditLessonDialogState extends State<EditLessonDialog> {
  late final TextEditingController titleController;
  late final TextEditingController urlController;
  String? courseId;

  @override
  void initState() {
    super.initState();
    titleController = TextEditingController(text: widget.lesson.title);
    urlController = TextEditingController(text: widget.lesson.url);
    courseId = widget.lesson.courseId;
  }

  @override
  void dispose() {
    titleController.dispose();
    urlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final teacher = store.currentUser!;
    final availableCourses = store.courses
        .where(
          (course) =>
              course.id == teacher.courseId &&
              course.subjects.contains(teacher.subject),
        )
        .toList();
    if (availableCourses.isNotEmpty &&
        !availableCourses.any((course) => course.id == courseId)) {
      courseId = availableCourses.first.id;
    }

    return AlertDialog(
      title: const Text('تعديل الدرس'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: titleController,
              decoration: const InputDecoration(labelText: 'عنوان الدرس'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: urlController,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(labelText: 'رابط Google Drive'),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              initialValue: courseId,
              decoration: const InputDecoration(labelText: 'القسم'),
              items: availableCourses
                  .map(
                    (course) => DropdownMenuItem(
                      value: course.id,
                      child: Text(course.title),
                    ),
                  )
                  .toList(),
              onChanged: (value) => setState(() => courseId = value),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('إلغاء'),
        ),
        FilledButton(
          onPressed: () {
            if (titleController.text.trim().isEmpty ||
                urlController.text.trim().isEmpty ||
                courseId == null) {
              return;
            }

            store.updateLesson(
              lesson: widget.lesson,
              title: titleController.text,
              url: urlController.text,
              courseId: courseId!,
            );
            Navigator.of(context).pop();
          },
          child: const Text('حفظ'),
        ),
      ],
    );
  }
}

class DeleteLessonDialog extends StatelessWidget {
  const DeleteLessonDialog({required this.lesson, super.key});

  final Lesson lesson;

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);

    return AlertDialog(
      title: const Text('حذف الدرس'),
      content: Text('هل تريد حذف "${lesson.title}"؟'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('إلغاء'),
        ),
        FilledButton(
          onPressed: () {
            store.deleteLesson(lesson);
            Navigator.of(context).pop();
          },
          child: const Text('حذف'),
        ),
      ],
    );
  }
}

class SubjectCard extends StatelessWidget {
  const SubjectCard({required this.subject, required this.lessons, super.key});

  final String subject;
  final List<Lesson> lessons;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: const Color(0xFFFAFBFF),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE8EEFF)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) =>
                SubjectLessonsPage(subject: subject, lessons: lessons),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: const Color(0xFF2F5BEA).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(
                  Icons.folder_special_rounded,
                  color: Color(0xFF2F5BEA),
                  size: 25,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      subject,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      lessons.isEmpty
                          ? 'لا توجد دروس بعد'
                          : 'اضغط لعرض دروس المادة',
                      style: const TextStyle(
                        color: Color(0xFF6B7280),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              StatusPill(text: '${lessons.length} فيديو'),
              const SizedBox(width: 8),
              const Icon(Icons.chevron_left_rounded, color: Color(0xFF9CA3AF)),
            ],
          ),
        ),
      ),
    );
  }
}

class SubjectLessonsPage extends StatelessWidget {
  const SubjectLessonsPage({
    required this.subject,
    required this.lessons,
    super.key,
  });

  final String subject;
  final List<Lesson> lessons;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F9FF),
      appBar: EpsilonAppBar(title: subject, showLogout: false),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          HeaderPanel(
            title: subject,
            subtitle: '${lessons.length} فيديو متوفر',
            icon: Icons.folder_special_rounded,
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: 'دروس المادة',
            icon: Icons.play_circle_outline_rounded,
            child: lessons.isEmpty
                ? const EmptyState(text: 'لا توجد دروس منشورة لهذه المادة بعد.')
                : Column(
                    children: lessons
                        .map((lesson) => SecureLessonTile(lesson: lesson))
                        .toList(),
                  ),
          ),
        ],
      ),
    );
  }
}

class SecureLessonTile extends StatelessWidget {
  const SecureLessonTile({required this.lesson, super.key});

  final Lesson lesson;

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final course = store.courseById(lesson.courseId);

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const CircleAvatar(
        backgroundColor: Color(0xFFEAF1FF),
        child: Icon(Icons.play_arrow_rounded, color: Color(0xFF2F5BEA)),
      ),
      title: Text(
        lesson.title,
        style: const TextStyle(fontWeight: FontWeight.w800),
      ),
      subtitle: Text(course?.title ?? 'درس فيديو'),
      trailing: FilledButton(
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => SecureVideoPage(lesson: lesson)),
        ),
        child: const Text('مشاهدة'),
      ),
    );
  }
}

class StatusPill extends StatelessWidget {
  const StatusPill({required this.text, super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFF2F5BEA).withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Color(0xFF2F5BEA),
          fontSize: 11,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

class SecureVideoPage extends StatefulWidget {
  const SecureVideoPage({required this.lesson, super.key});

  final Lesson lesson;

  @override
  State<SecureVideoPage> createState() => _SecureVideoPageState();
}

class _SecureVideoPageState extends State<SecureVideoPage> {
  @override
  Widget build(BuildContext context) {
    return SecureContentViewerPage(
      title: widget.lesson.title,
      url: widget.lesson.url,
      kind: SecureContentKind.video,
    );
  }
}

enum SecureContentKind { video, pdf }

class SecureContentViewerPage extends StatefulWidget {
  const SecureContentViewerPage({
    required this.title,
    required this.url,
    required this.kind,
    super.key,
  });

  final String title;
  final String url;
  final SecureContentKind kind;

  @override
  State<SecureContentViewerPage> createState() =>
      _SecureContentViewerPageState();
}

class _SecureContentViewerPageState extends State<SecureContentViewerPage> {
  static const secureChannel = MethodChannel('epsilon/secure_window');
  late final WebViewController controller;

  @override
  void initState() {
    super.initState();
    enableSecureWindow();
    controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      ..loadRequest(Uri.parse(toDrivePreviewUrl(widget.url)));
  }

  @override
  void dispose() {
    disableSecureWindow();
    super.dispose();
  }

  Future<void> enableSecureWindow() async {
    try {
      await secureChannel.invokeMethod<void>('enable');
    } on Object {
      // iOS does not offer a reliable screenshot block like Android FLAG_SECURE.
    }
  }

  Future<void> disableSecureWindow() async {
    try {
      await secureChannel.invokeMethod<void>('disable');
    } on Object {
      // Keep navigation smooth on platforms without the native hook.
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: EpsilonAppBar(title: widget.title, showLogout: false),
      body: WebViewWidget(controller: controller),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({required this.text, super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(color: Colors.grey.shade700),
      ),
    );
  }
}

String statusLabel(AccountStatus status) {
  return switch (status) {
    AccountStatus.pending => 'بانتظار القبول',
    AccountStatus.active => 'نشط',
    AccountStatus.blocked => 'مجمد',
    AccountStatus.rejected => 'مرفوض',
  };
}

String roleLabel(UserRole? role) {
  return switch (role) {
    UserRole.admin => 'إدارة',
    UserRole.teacher => 'أستاذ',
    UserRole.student => 'طالب',
    null => '-',
  };
}

Color courseAccent(String title) {
  final colors = [
    const Color(0xFF2F5BEA),
    const Color(0xFF10B981),
    const Color(0xFF7C3AED),
    const Color(0xFFF97316),
    const Color(0xFF0EA5E9),
    const Color(0xFFDB2777),
  ];
  return colors[title.hashCode.abs() % colors.length];
}

IconData courseIcon(String title) {
  final lower = title.toLowerCase();
  if (title.contains('رياض') || lower.contains('math')) {
    return Icons.calculate_rounded;
  }
  if (title.contains('فيزياء') ||
      title.contains('كيمياء') ||
      lower.contains('chem') ||
      lower.contains('physics')) {
    return Icons.science_rounded;
  }
  if (title.contains('حياة') ||
      title.contains('أرض') ||
      lower.contains('bio')) {
    return Icons.biotech_rounded;
  }
  if (title.contains('باك') || title.toLowerCase().contains('bac')) {
    return Icons.school_rounded;
  }
  if (title.contains('ذكاء') || lower.contains('ai')) {
    return Icons.psychology_rounded;
  }
  return Icons.menu_book_rounded;
}

String courseShortTitle(String title) {
  final trimmed = title.trim();
  if (trimmed.isEmpty) {
    return 'قسم';
  }
  if (trimmed.length <= 12) {
    return trimmed;
  }
  return '${trimmed.substring(0, 11)}...';
}

String courseTitleLine(String title, String? level) {
  if (level != null && level.trim().isNotEmpty) {
    return level;
  }
  return title;
}

List<String> parseSubjects(String raw) {
  final subjects = raw
      .split(RegExp(r'[,،\n]'))
      .map((subject) => subject.trim())
      .where((subject) => subject.isNotEmpty)
      .toSet()
      .toList();

  return subjects.isEmpty ? ['مادة عامة'] : subjects;
}

String toDrivePreviewUrl(String url) {
  final trimmed = url.trim();
  final idMatch =
      RegExp(r'/d/([^/]+)').firstMatch(trimmed) ??
      RegExp(r'id=([^&]+)').firstMatch(trimmed);

  if (idMatch == null) {
    return trimmed;
  }

  final fileId = idMatch.group(1);
  if (fileId == null || fileId.isEmpty) {
    return trimmed;
  }

  return 'https://drive.google.com/file/d/$fileId/preview';
}
