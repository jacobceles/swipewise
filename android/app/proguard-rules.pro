# R8 keep rules for the release build. Each rule names the thing Android or a library
# loads by NAME at runtime, which R8 cannot see and would otherwise rename or strip.
# Flutter's own embedding rules and the AndroidManifest components (activity, receivers,
# service) are kept automatically; Firebase and Play services ship their own rules.

# WorkManager instantiates its Room database reflectively through the no-arg constructor of
# the generated `WorkDatabase_Impl`. Stripping it crashed every release build on launch
# (AGP 9, 2026-08): NoSuchMethodException: androidx.work.impl.WorkDatabase_Impl.<init> []
-keep class * extends androidx.room.RoomDatabase { <init>(); }

# WorkManager stores a worker's class NAME (our ReregisterWorker) and builds it later with
# (Context, WorkerParameters) — possibly after an app update, so the name must be stable.
-keep class * extends androidx.work.ListenableWorker {
    <init>(android.content.Context, androidx.work.WorkerParameters);
}

# flutter_local_notifications ships no rules, but persists scheduled notifications (the
# payment-due reminders) as Gson JSON and rebuilds them by field name after a reboot.
-keep class com.dexterous.flutterlocalnotifications.** { *; }
-keepattributes Signature, *Annotation*, InnerClasses, EnclosingMethod
