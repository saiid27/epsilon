import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_storage/firebase_storage.dart';

import 'firebase_schema.dart';

class FirebaseRepository {
  FirebaseRepository({
    FirebaseAuth? auth,
    FirebaseFirestore? firestore,
    FirebaseFunctions? functions,
    FirebaseStorage? storage,
  }) : auth = auth ?? FirebaseAuth.instance,
       firestore = firestore ?? FirebaseFirestore.instance,
       functions = functions ?? FirebaseFunctions.instance,
       storage = storage ?? FirebaseStorage.instance;

  final FirebaseAuth auth;
  final FirebaseFirestore firestore;
  final FirebaseFunctions functions;
  final FirebaseStorage storage;

  CollectionReference<Map<String, dynamic>> get users =>
      firestore.collection(FirebaseCollections.users);

  CollectionReference<Map<String, dynamic>> get classes =>
      firestore.collection(FirebaseCollections.classes);

  CollectionReference<Map<String, dynamic>> get courses =>
      firestore.collection(FirebaseCollections.courses);

  CollectionReference<Map<String, dynamic>> get lessons =>
      firestore.collection(FirebaseCollections.lessons);

  CollectionReference<Map<String, dynamic>> get notifications =>
      firestore.collection(FirebaseCollections.notifications);

  CollectionReference<Map<String, dynamic>> get guestVideos =>
      firestore.collection(FirebaseCollections.guestVideos);

  CollectionReference<Map<String, dynamic>> get archiveFiles =>
      firestore.collection(FirebaseCollections.archiveFiles);

  DocumentReference<Map<String, dynamic>> get appSettings =>
      firestore.collection(FirebaseCollections.settings).doc('app');

  Future<void> _ensureCallableAuth() async {
    final user = auth.currentUser;
    if (user == null) {
      throw FirebaseAuthException(
        code: 'not-signed-in',
        message: 'سجل الدخول كإدارة ثم أعد المحاولة.',
      );
    }

    await user.getIdToken(true);
  }

  bool _isUnauthenticatedError(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('unauthenticated') ||
        text.contains('not-signed-in') ||
        text.contains('no authenticated user');
  }

  bool _isEmailAlreadyUsedError(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('email-already-in-use') ||
        text.contains('email-already-exists') ||
        text.contains('email_exists') ||
        text.contains('already in use');
  }

  bool _isBootstrapAdminEmail(String? email) {
    return {
      'admin@demo.com',
      'saiidfatis@gmail.com',
      'mohamedsaiidmohameden@gmail.com',
    }.contains(email?.trim().toLowerCase());
  }

  Future<void> _ensureActiveAdmin() async {
    final user = auth.currentUser;
    if (user == null) {
      throw FirebaseAuthException(
        code: 'not-signed-in',
        message: 'سجل الدخول كإدارة ثم أعد المحاولة.',
      );
    }

    if (_isBootstrapAdminEmail(user.email)) {
      await users.doc(user.uid).set({
        UserFields.name: user.displayName?.trim().isNotEmpty == true
            ? user.displayName!.trim()
            : 'إدارة المدرسة',
        UserFields.email: user.email!.trim().toLowerCase(),
        UserFields.role: FirebaseRole.admin.value,
        UserFields.status: FirebaseAccountStatus.active.value,
        UserFields.createdAt: FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      return;
    }

    final snapshot = await users.doc(user.uid).get();
    final data = snapshot.data();
    if (data?[UserFields.role] != FirebaseRole.admin.value ||
        data?[UserFields.status] != FirebaseAccountStatus.active.value) {
      throw FirebaseException(
        plugin: 'epsilon',
        code: 'permission-denied',
        message: 'هذا الحساب لا يملك صلاحية الإدارة.',
      );
    }
  }

  Future<User> _createAuthUserWithoutSwitchingAdmin({
    required String name,
    required String email,
    required String password,
  }) async {
    final secondaryApp = await Firebase.initializeApp(
      name: 'accountCreator-${DateTime.now().microsecondsSinceEpoch}',
      options: Firebase.app().options,
    );
    final secondaryAuth = FirebaseAuth.instanceFor(app: secondaryApp);
    final normalizedEmail = email.trim().toLowerCase();

    try {
      UserCredential credential;
      try {
        credential = await secondaryAuth.createUserWithEmailAndPassword(
          email: normalizedEmail,
          password: password,
        );
      } on Object catch (error) {
        if (!_isEmailAlreadyUsedError(error)) {
          rethrow;
        }
        credential = await secondaryAuth.signInWithEmailAndPassword(
          email: normalizedEmail,
          password: password,
        );
      }
      final createdUser = credential.user;
      if (createdUser == null) {
        throw FirebaseAuthException(
          code: 'user-not-created',
          message: 'تعذر إنشاء الحساب.',
        );
      }
      await createdUser.updateDisplayName(name.trim());
      return createdUser;
    } finally {
      await secondaryAuth.signOut();
      await secondaryApp.delete();
    }
  }

  Future<void> _writeTeacherProfileWithAdminToken({
    required String adminIdToken,
    required String uid,
    required String name,
    required String email,
    required String classId,
    required String courseId,
    required String subject,
  }) async {
    final projectId = Firebase.app().options.projectId;
    if (projectId.isEmpty) {
      throw FirebaseException(
        plugin: 'epsilon',
        code: 'missing-project-id',
        message: 'Firebase project id is missing.',
      );
    }

    final uri = Uri.https(
      'firestore.googleapis.com',
      '/v1/projects/$projectId/databases/(default)/documents/${FirebaseCollections.users}/$uid',
    );
    final client = HttpClient();

    try {
      final request = await client.patchUrl(uri);
      request.headers.contentType = ContentType.json;
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer $adminIdToken',
      );
      request.write(
        jsonEncode({
          'fields': {
            UserFields.name: {'stringValue': name.trim()},
            UserFields.email: {'stringValue': email.trim().toLowerCase()},
            UserFields.role: {'stringValue': FirebaseRole.teacher.value},
            UserFields.status: {
              'stringValue': FirebaseAccountStatus.active.value,
            },
            UserFields.classId: {'stringValue': classId},
            UserFields.courseId: {'stringValue': courseId},
            UserFields.subject: {'stringValue': subject.trim()},
            UserFields.createdAt: {
              'timestampValue': DateTime.now().toUtc().toIso8601String(),
            },
          },
        }),
      );

      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final body = await utf8.decodeStream(response);
        throw FirebaseException(
          plugin: 'epsilon',
          code: 'teacher-profile-write-failed',
          message: body,
        );
      }
    } finally {
      client.close(force: true);
    }
  }

  Future<UserCredential> signIn({
    required String email,
    required String password,
  }) {
    return auth.signInWithEmailAndPassword(
      email: email.trim().toLowerCase(),
      password: password,
    );
  }

  Future<void> setStudentActiveDevice({
    required String uid,
    required String deviceId,
  }) {
    return users.doc(uid).update({
      UserFields.activeDeviceId: deviceId,
      UserFields.lastLoginAt: FieldValue.serverTimestamp(),
    });
  }

  Future<UserCredential> createStudentAccount({
    required String name,
    required String email,
    required String password,
    required String classId,
    required String courseId,
    required String paymentProofPath,
    required String paymentSenderPhone,
  }) async {
    final credential = await auth.createUserWithEmailAndPassword(
      email: email.trim().toLowerCase(),
      password: password,
    );
    final user = credential.user;

    if (user == null) {
      return credential;
    }

    final paymentProofUrl = await uploadPaymentProof(
      uid: user.uid,
      filePath: paymentProofPath,
    );

    await users.doc(user.uid).set({
      UserFields.name: name.trim(),
      UserFields.email: email.trim().toLowerCase(),
      UserFields.role: FirebaseRole.student.value,
      UserFields.status: FirebaseAccountStatus.pending.value,
      UserFields.classId: classId,
      UserFields.courseId: courseId,
      UserFields.paymentProofUrl: paymentProofUrl,
      UserFields.paymentSenderPhone: paymentSenderPhone.trim(),
      UserFields.createdAt: FieldValue.serverTimestamp(),
    });

    return credential;
  }

  Future<String> uploadPaymentProof({
    required String uid,
    required String filePath,
  }) async {
    final ref = storage.ref('payment_proofs/$uid.jpg');
    await ref.putFile(File(filePath));
    return ref.getDownloadURL();
  }

  Future<void> approveUser(String uid) {
    return users.doc(uid).update({
      UserFields.status: FirebaseAccountStatus.active.value,
    });
  }

  Future<void> blockUser(String uid) {
    return users.doc(uid).update({
      UserFields.status: FirebaseAccountStatus.blocked.value,
    });
  }

  Future<void> updateAccountStatus(String uid, String status) async {
    await _ensureCallableAuth();
    await functions.httpsCallable('updateAccountStatus').call<void>({
      'uid': uid,
      'status': status,
    });
  }

  Future<void> deleteUserAccount(String uid) async {
    await _ensureCallableAuth();
    await functions.httpsCallable('deleteUserAccount').call<void>({'uid': uid});
  }

  Future<void> createTeacherAccount({
    required String name,
    required String email,
    required String password,
    required String classId,
    required String courseId,
    required String subject,
  }) async {
    await _ensureCallableAuth();

    try {
      await functions.httpsCallable('createTeacher').call<void>({
        'name': name,
        'email': email.trim().toLowerCase(),
        'password': password,
        'classId': classId,
        'courseId': courseId,
        'subject': subject,
      });
    } on Object catch (error) {
      if (!_isUnauthenticatedError(error)) {
        rethrow;
      }

      await _ensureActiveAdmin();
      final adminIdToken = await auth.currentUser?.getIdToken(true);
      if (adminIdToken == null) {
        throw FirebaseAuthException(
          code: 'not-signed-in',
          message: 'سجل الدخول كإدارة ثم أعد المحاولة.',
        );
      }
      final teacher = await _createAuthUserWithoutSwitchingAdmin(
        name: name,
        email: email,
        password: password,
      );
      await _writeTeacherProfileWithAdminToken(
        adminIdToken: adminIdToken,
        uid: teacher.uid,
        name: name,
        email: email,
        classId: classId,
        courseId: courseId,
        subject: subject,
      );
    }
  }

  Future<void> createStudentByAdmin({
    required String name,
    required String email,
    required String password,
    required String classId,
    required String courseId,
  }) async {
    await _ensureCallableAuth();
    await functions.httpsCallable('createStudent').call<void>({
      'name': name,
      'email': email,
      'password': password,
      'classId': classId,
      'courseId': courseId,
    });
  }

  Future<void> createCourse({
    required String title,
    required String classId,
    required String description,
    required String price,
    required List<String> subjects,
  }) {
    return courses.add({
      CourseFields.title: title.trim(),
      CourseFields.classId: classId,
      CourseFields.description: description.trim(),
      CourseFields.price: price.trim(),
      CourseFields.subjects: subjects,
      CourseFields.isActive: true,
      CourseFields.createdAt: FieldValue.serverTimestamp(),
    });
  }

  Future<void> createLesson({
    required String title,
    required String url,
    required String teacherId,
    required String classId,
    required String courseId,
    required String subject,
  }) {
    return lessons.add({
      LessonFields.title: title.trim(),
      LessonFields.url: url.trim(),
      LessonFields.teacherId: teacherId,
      LessonFields.classId: classId,
      LessonFields.courseId: courseId,
      LessonFields.subject: subject.trim(),
      LessonFields.isPublished: true,
      LessonFields.createdAt: FieldValue.serverTimestamp(),
    });
  }

  Future<void> updateLesson({
    required String lessonId,
    required String title,
    required String url,
    required String classId,
    required String courseId,
  }) {
    return lessons.doc(lessonId).update({
      LessonFields.title: title.trim(),
      LessonFields.url: url.trim(),
      LessonFields.classId: classId,
      LessonFields.courseId: courseId,
    });
  }

  Future<void> deleteLesson(String lessonId) {
    return lessons.doc(lessonId).delete();
  }

  Future<void> deleteCourse(String courseId) {
    return courses.doc(courseId).delete();
  }

  Future<void> updatePaymentNumber(String value) {
    return appSettings.set({
      SettingsFields.paymentNumber: value.trim(),
      SettingsFields.updatedAt: FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> updatePaymentAmount(String value) {
    return appSettings.set({
      SettingsFields.paymentAmount: value.trim(),
      SettingsFields.updatedAt: FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> addNotification({required String title, required String body}) {
    return functions.httpsCallable('publishNotification').call<void>({
      NotificationFields.title: title.trim(),
      NotificationFields.body: body.trim(),
    });
  }

  Future<void> updateNotification({
    required String id,
    required String title,
    required String body,
  }) {
    return notifications.doc(id).update({
      NotificationFields.title: title.trim(),
      NotificationFields.body: body.trim(),
    });
  }

  Future<void> deleteNotification(String id) {
    return notifications.doc(id).delete();
  }

  Future<void> addGuestVideo({
    required String title,
    required String url,
    required String description,
    required String courseId,
  }) {
    return guestVideos.add({
      GuestContentFields.title: title.trim(),
      GuestContentFields.url: url.trim(),
      GuestContentFields.description: description.trim(),
      GuestContentFields.courseId: courseId,
      GuestContentFields.createdAt: FieldValue.serverTimestamp(),
    });
  }

  Future<void> addArchiveFile({
    required String title,
    required String url,
    required String description,
    required String courseId,
  }) {
    return archiveFiles.add({
      GuestContentFields.title: title.trim(),
      GuestContentFields.url: url.trim(),
      GuestContentFields.description: description.trim(),
      GuestContentFields.courseId: courseId,
      GuestContentFields.createdAt: FieldValue.serverTimestamp(),
    });
  }

  Future<void> updateGuestVideo({
    required String id,
    required String title,
    required String url,
    required String description,
    required String courseId,
  }) {
    return guestVideos.doc(id).update({
      GuestContentFields.title: title.trim(),
      GuestContentFields.url: url.trim(),
      GuestContentFields.description: description.trim(),
      GuestContentFields.courseId: courseId,
    });
  }

  Future<void> updateArchiveFile({
    required String id,
    required String title,
    required String url,
    required String description,
    required String courseId,
  }) {
    return archiveFiles.doc(id).update({
      GuestContentFields.title: title.trim(),
      GuestContentFields.url: url.trim(),
      GuestContentFields.description: description.trim(),
      GuestContentFields.courseId: courseId,
    });
  }

  Future<void> deleteGuestVideo(String id) {
    return guestVideos.doc(id).delete();
  }

  Future<void> deleteArchiveFile(String id) {
    return archiveFiles.doc(id).delete();
  }

  Future<void> changePassword(String newPassword) {
    final user = auth.currentUser;
    if (user == null) {
      throw FirebaseAuthException(
        code: 'not-signed-in',
        message: 'No authenticated user.',
      );
    }
    return user.updatePassword(newPassword);
  }

  Future<void> sendPasswordResetEmail(String email) {
    return auth.sendPasswordResetEmail(email: email.trim().toLowerCase());
  }

  Future<void> signOut() {
    return auth.signOut();
  }
}
