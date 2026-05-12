const admin = require("firebase-admin");

admin.initializeApp({
  credential: admin.credential.applicationDefault(),
});

const auth = admin.auth();
const db = admin.firestore();
const now = admin.firestore.FieldValue.serverTimestamp();

const demoUsers = [
  {
    key: "admin",
    email: "admin@demo.com",
    password: "123456",
    profile: {
      name: "إدارة المدرسة",
      role: "admin",
      status: "active",
    },
  },
  {
    key: "teacher",
    email: "teacher@demo.com",
    password: "123456",
    profile: {
      name: "الأستاذ أحمد",
      role: "teacher",
      status: "active",
      classId: "class-1a",
      subject: "الرياضيات",
    },
  },
  {
    key: "student",
    email: "student@demo.com",
    password: "123456",
    profile: {
      name: "الطالب محمد",
      role: "student",
      status: "active",
      classId: "class-1a",
    },
  },
];

const classes = [
  {id: "class-1a", name: "الفصل الأول أ", level: "السنة الأولى"},
  {id: "class-2b", name: "الفصل الثاني ب", level: "السنة الثانية"},
  {id: "class-3c", name: "الفصل الثالث ج", level: "السنة الثالثة"},
];

async function getOrCreateUser(userConfig) {
  try {
    return await auth.getUserByEmail(userConfig.email);
  } catch (error) {
    if (error.code !== "auth/user-not-found") {
      throw error;
    }

    return auth.createUser({
      email: userConfig.email,
      password: userConfig.password,
      displayName: userConfig.profile.name,
      disabled: userConfig.profile.status === "blocked",
    });
  }
}

async function seed() {
  const usersByKey = {};

  for (const schoolClass of classes) {
    await db.collection("classes").doc(schoolClass.id).set({
      name: schoolClass.name,
      level: schoolClass.level,
      createdAt: now,
    }, {merge: true});
  }

  for (const userConfig of demoUsers) {
    const user = await getOrCreateUser(userConfig);
    usersByKey[userConfig.key] = user.uid;

    await db.collection("users").doc(user.uid).set({
      ...userConfig.profile,
      email: userConfig.email,
      createdAt: now,
    }, {merge: true});
  }

  await db.collection("courses").doc("course-math-basics").set({
    title: "أساسيات الرياضيات",
    classId: "class-1a",
    isActive: true,
    createdAt: now,
  }, {merge: true});

  await db.collection("courses").doc("course-review-2b").set({
    title: "مراجعة الفصل الثاني",
    classId: "class-2b",
    isActive: true,
    createdAt: now,
  }, {merge: true});

  await db.collection("lessons").doc("lesson-equations-intro").set({
    title: "مقدمة في المعادلات",
    url: "https://example.com/math-lesson",
    teacherId: usersByKey.teacher,
    classId: "class-1a",
    courseId: "course-math-basics",
    subject: "الرياضيات",
    isPublished: true,
    createdAt: now,
  }, {merge: true});

  console.log("Seed completed.");
  console.log("Admin: admin@demo.com / 123456");
  console.log("Teacher: teacher@demo.com / 123456");
  console.log("Student: student@demo.com / 123456");
}

seed()
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
