# Epsilon

تطبيق تعليمي مبني باستخدام Flutter وFirebase لثلاثة أدوار: إدارة، أساتذة، وطلاب.

## التشغيل

```bash
flutter pub get
flutter run
```

## Firebase Backend

تم تجهيز ملفات الباك داخل المشروع:

- `firebase.json`: إعداد Firebase CLI.
- `firestore.rules`: قواعد أمان Firestore حسب الدور والفصل.
- `firestore.indexes.json`: الفهارس المطلوبة للاستعلامات.
- `functions/`: Cloud Functions لعمليات الإدارة الحساسة.
- `scripts/seed_demo_data.js`: سكربت يضيف بيانات البداية.

### ربط المشروع بحساب Firebase

ثبّت الأدوات مرة واحدة:

```bash
npm install -g firebase-tools
dart pub global activate flutterfire_cli
firebase login
```

اربط التطبيق بمشروع Firebase:

```bash
flutterfire configure
```

بعدها سيظهر ملف مثل:

```text
lib/firebase_options.dart
```

ويجب تعديل `lib/main.dart` لاستخدام `DefaultFirebaseOptions.currentPlatform`.

### نشر الباك

بعد اختيار مشروعك في Firebase:

```bash
firebase use --add
cd functions
npm install
cd ..
firebase deploy --only firestore,functions
```

### إضافة البيانات التجريبية

من Firebase Console أنشئ Service Account key وضعه هنا:

```text
scripts/service-account.json
```

ثم شغّل:

```bash
cd scripts
npm install
GOOGLE_APPLICATION_CREDENTIALS="$PWD/service-account.json" npm run seed
```

حسابات البداية:

- الإدارة: `admin@demo.com` / `123456`
- الأستاذ: `teacher@demo.com` / `123456`
- الطالب: `student@demo.com` / `123456`

## أهم الملفات

- `lib/main.dart`: نقطة بداية التطبيق والواجهة الأولى.
- `lib/firebase_repository.dart`: طبقة التعامل مع Firebase Auth وFirestore.
- `lib/firebase_schema.dart`: أسماء المجموعات والحقول والحالات.
- `firestore.rules`: صلاحيات القراءة والكتابة.
- `functions/src/index.ts`: عمليات الباك الخاصة بالأدمن.
- `scripts/seed_demo_data.js`: إنشاء بيانات البداية في Firebase.
- `pubspec.yaml`: إعدادات المشروع والحزم.
- `android/`: ملفات تشغيل وبناء Android.
- `ios/`: ملفات تشغيل وبناء iOS.
