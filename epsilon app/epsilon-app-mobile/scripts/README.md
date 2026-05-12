# Epsilon Firebase Scripts

## Seed Demo Data

1. Create a Firebase service account key from:
   Firebase Console > Project settings > Service accounts > Generate new private key.
2. Save it outside git, for example:
   `scripts/service-account.json`
3. Run:

```sh
cd scripts
npm install
GOOGLE_APPLICATION_CREDENTIALS="$PWD/service-account.json" npm run seed
```

This creates the demo admin, teacher, student, classes, courses, and lesson.
