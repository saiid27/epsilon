import {initializeApp} from "firebase-admin/app";
import {
  FieldValue,
  getFirestore,
} from "firebase-admin/firestore";
import {getAuth} from "firebase-admin/auth";
import {getMessaging} from "firebase-admin/messaging";
import {HttpsError, onCall} from "firebase-functions/v2/https";

initializeApp();

const db = getFirestore();
const auth = getAuth();
const messaging = getMessaging();

const collections = {
  users: "users",
  classes: "classes",
  courses: "courses",
  lessons: "lessons",
  notifications: "notifications",
};

type AppRole = "admin" | "teacher" | "student";
type AccountStatus = "pending" | "active" | "blocked" | "rejected";
type CallableAuth = {
  uid: string;
  token?: {
    email?: unknown;
    name?: unknown;
  };
};

const bootstrapAdminEmails = new Set([
  "admin@demo.com",
  "saiidfatis@gmail.com",
  "mohamedsaiidmohameden@gmail.com",
]);

interface UserProfile {
  name: string;
  email: string;
  role: AppRole;
  status: AccountStatus;
  classId?: string;
  courseId?: string;
  subject?: string;
}

const callableOptions = {
  invoker: "public" as const,
};

async function requireAdmin(authContext?: CallableAuth): Promise<void> {
  const uid = authContext?.uid;
  if (!uid) {
    throw new HttpsError("unauthenticated", "Authentication is required.");
  }

  const snapshot = await db.collection(collections.users).doc(uid).get();
  const profile = snapshot.data() as UserProfile | undefined;

  if (profile?.role === "admin" && profile.status === "active") {
    return;
  }

  const email = typeof authContext?.token?.email === "string" ?
    authContext.token.email.toLowerCase() :
    "";

  if (bootstrapAdminEmails.has(email)) {
    await db.collection(collections.users).doc(uid).set({
      name: typeof authContext?.token?.name === "string" ?
        authContext.token.name :
        "إدارة المدرسة",
      email,
      role: "admin",
      status: "active",
      updatedAt: FieldValue.serverTimestamp(),
      createdAt: snapshot.exists ?
        snapshot.get("createdAt") ?? FieldValue.serverTimestamp() :
        FieldValue.serverTimestamp(),
    }, {merge: true});
    return;
  }

  throw new HttpsError("permission-denied", "Admin access is required.");
}

function requireString(value: unknown, fieldName: string): string {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw new HttpsError("invalid-argument", `${fieldName} is required.`);
  }

  return value.trim();
}

export const createTeacher = onCall(callableOptions, async (request) => {
  await requireAdmin(request.auth);

  const name = requireString(request.data.name, "name");
  const email = requireString(request.data.email, "email").toLowerCase();
  const password = requireString(request.data.password, "password");
  const classId = requireString(request.data.classId, "classId");
  const courseId = requireString(request.data.courseId, "courseId");
  const subject = requireString(request.data.subject, "subject");

  const user = await auth.createUser({
    displayName: name,
    email,
    password,
    emailVerified: false,
    disabled: false,
  });

  await db.collection(collections.users).doc(user.uid).set({
    name,
    email,
    role: "teacher",
    status: "active",
    classId,
    courseId,
    subject,
    createdAt: FieldValue.serverTimestamp(),
  });

  return {uid: user.uid};
});

export const updateAccountStatus = onCall(callableOptions, async (request) => {
  await requireAdmin(request.auth);

  const uid = requireString(request.data.uid, "uid");
  const status = requireString(request.data.status, "status") as AccountStatus;

  if (!["pending", "active", "blocked", "rejected"].includes(status)) {
    throw new HttpsError("invalid-argument", "Unsupported account status.");
  }

  await db.collection(collections.users).doc(uid).update({
    status,
    updatedAt: FieldValue.serverTimestamp(),
  });

  await auth.updateUser(uid, {
    disabled: status === "blocked",
  });

  return {uid, status};
});

export const deleteUserAccount = onCall(callableOptions, async (request) => {
  await requireAdmin(request.auth);

  const uid = requireString(request.data.uid, "uid");

  if (uid === request.auth?.uid) {
    throw new HttpsError(
      "invalid-argument",
      "Admin account cannot delete itself.",
    );
  }

  await db.collection(collections.users).doc(uid).delete();
  await auth.deleteUser(uid);

  return {uid};
});

export const createStudent = onCall(callableOptions, async (request) => {
  await requireAdmin(request.auth);

  const name = requireString(request.data.name, "name");
  const email = requireString(request.data.email, "email").toLowerCase();
  const password = requireString(request.data.password, "password");
  const classId = requireString(request.data.classId, "classId");
  const courseId = requireString(request.data.courseId, "courseId");

  const user = await auth.createUser({
    displayName: name,
    email,
    password,
    emailVerified: false,
    disabled: false,
  });

  await db.collection(collections.users).doc(user.uid).set({
    name,
    email,
    role: "student",
    status: "active",
    classId,
    courseId,
    createdAt: FieldValue.serverTimestamp(),
  });

  return {uid: user.uid};
});

export const createCourse = onCall(callableOptions, async (request) => {
  await requireAdmin(request.auth);

  const title = requireString(request.data.title, "title");
  const classId = requireString(request.data.classId, "classId");
  const description = requireString(request.data.description, "description");
  const price = typeof request.data.price === "string" ?
    request.data.price.trim() :
    "";
  const subjects = Array.isArray(request.data.subjects) ?
    request.data.subjects.filter((item: unknown) => typeof item === "string") :
    [];

  const course = await db.collection(collections.courses).add({
    title,
    classId,
    description,
    price,
    subjects,
    isActive: true,
    createdAt: FieldValue.serverTimestamp(),
  });

  return {id: course.id};
});

export const createClass = onCall(callableOptions, async (request) => {
  await requireAdmin(request.auth);

  const name = requireString(request.data.name, "name");
  const level = requireString(request.data.level, "level");

  const schoolClass = await db.collection(collections.classes).add({
    name,
    level,
    createdAt: FieldValue.serverTimestamp(),
  });

  return {id: schoolClass.id};
});

export const publishNotification = onCall(callableOptions, async (request) => {
  await requireAdmin(request.auth);

  const title = requireString(request.data.title, "title");
  const body = requireString(request.data.body, "body");
  const notification = await db.collection(collections.notifications).add({
    title,
    body,
    createdAt: FieldValue.serverTimestamp(),
  });

  await messaging.send({
    topic: "all_users",
    notification: {
      title,
      body,
    },
    data: {
      type: "admin_notification",
      notificationId: notification.id,
    },
    android: {
      priority: "high",
      notification: {
        channelId: "epsilon_notifications",
        sound: "default",
      },
    },
    apns: {
      payload: {
        aps: {
          sound: "default",
        },
      },
    },
  });

  return {id: notification.id};
});
