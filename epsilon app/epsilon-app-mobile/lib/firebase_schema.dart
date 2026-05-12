enum FirebaseRole {
  admin('admin'),
  teacher('teacher'),
  student('student');

  const FirebaseRole(this.value);

  final String value;
}

enum FirebaseAccountStatus {
  pending('pending'),
  active('active'),
  blocked('blocked');

  const FirebaseAccountStatus(this.value);

  final String value;
}

abstract final class FirebaseCollections {
  static const users = 'users';
  static const classes = 'classes';
  static const courses = 'courses';
  static const lessons = 'lessons';
  static const settings = 'settings';
  static const notifications = 'notifications';
  static const guestVideos = 'guestVideos';
  static const archiveFiles = 'archiveFiles';
}

abstract final class UserFields {
  static const name = 'name';
  static const email = 'email';
  static const role = 'role';
  static const status = 'status';
  static const classId = 'classId';
  static const courseId = 'courseId';
  static const subject = 'subject';
  static const paymentProofUrl = 'paymentProofUrl';
  static const paymentSenderPhone = 'paymentSenderPhone';
  static const activeDeviceId = 'activeDeviceId';
  static const lastLoginAt = 'lastLoginAt';
  static const createdAt = 'createdAt';
}

abstract final class CourseFields {
  static const title = 'title';
  static const classId = 'classId';
  static const description = 'description';
  static const subjects = 'subjects';
  static const price = 'price';
  static const isActive = 'isActive';
  static const createdAt = 'createdAt';
}

abstract final class LessonFields {
  static const title = 'title';
  static const url = 'url';
  static const teacherId = 'teacherId';
  static const classId = 'classId';
  static const courseId = 'courseId';
  static const subject = 'subject';
  static const isPublished = 'isPublished';
  static const createdAt = 'createdAt';
}

abstract final class SettingsFields {
  static const paymentNumber = 'paymentNumber';
  static const paymentAmount = 'paymentAmount';
  static const updatedAt = 'updatedAt';
}

abstract final class NotificationFields {
  static const title = 'title';
  static const body = 'body';
  static const createdAt = 'createdAt';
}

abstract final class GuestContentFields {
  static const title = 'title';
  static const url = 'url';
  static const description = 'description';
  static const courseId = 'courseId';
  static const createdAt = 'createdAt';
}
