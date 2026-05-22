# Android Bridge Background Notes

## Current State

- `TVBridge` now has its own `BridgeServerService` host in addition to the shared Android app `HeadlessServerService` path.
- `BridgeServerService` starts Nano/Bridge as a `connectedDevice` foreground service, keeps a persistent notification, and holds partial CPU, Wi-Fi high-performance, and multicast locks while running.
- The service registers screen, unlock, power, and network callbacks; screen-off handling rechecks the server and reschedules the watchdog without launching UI.
- A watchdog alarm uses `setAndAllowWhileIdle()` to recheck the service roughly every 9 minutes, and an earlier 1-minute recheck is scheduled after task removal or unexpected service destruction.
- Boot, package replace, unlock, and common quick-boot broadcasts request service startup.
- `BridgeActivity` exposes user-visible entries for notification permission, all-files access, battery optimization allowlist, app settings, and common vendor autostart/background settings.
- Some Bridge work is HTTP-only, but Jar UI and detail-UI fallback paths still need a foreground Android `Activity` or a visible/operable Android host surface.
- A previous 1-pixel Activity keep-alive experiment was removed from the default path after Huawei `ZRHungService` force-stopped the whole package when `BridgeKeepAliveActivity` appeared during screen-off. On Huawei/Honor, background UI tricks are more dangerous than a recoverable service stop.

## Feasibility

Background or lock-screen serving is feasible after the Android app has started the foreground service. Health checks, source requests, proxy requests, and already-authorized playback should keep working while the app is not the visible Activity on ordinary devices.

It is not safe to promise "all functions" in every background state:

- Android 12 and newer restrict starting foreground services from a background app. Start the server while the app is visible or from an allowed user-visible path.
- Android 15 places a background runtime budget on `dataSync` foreground services. A Bridge server intended to run for very long sessions needs a service-type decision before production use.
- Doze suspends app network access and ignores wake locks during deep idle maintenance periods. Locking the screen alone is not the same as Doze, but long unplugged stationary idle time can enter it.
- Jar flows that need Android UI are not headless. They may require the Android app to be visible again even if Nano is still serving HTTP.
- Device-vendor battery policies can still stop or throttle long-running apps.

## Follow-Up Direction

1. Keep the normal development default on the mobile flavor and retain leanback smoke coverage.
2. Add an explicit diagnostics surface: foreground service state, battery allowlist state, notification permission, lock state, network type, watchdog schedule, current port, and recent Bridge errors.
3. Test four levels separately: app sent Home, screen locked shortly after start, long idle/Doze behavior, and vendor-specific background cleanup on a physical phone.
4. If TVBridge becomes a production Bridge appliance, prefer a controlled always-powered Android runtime or emulator appliance over relying on an unplugged phone.

## Huawei / Honor Notes

- Huawei `ZRHungService`, PowerGenie, System Manager, and related App Launch policies can force-stop an app instead of merely killing its process. Once force-stopped, ordinary receivers, alarms, and foreground-service restarts do not run until the user opens the app again.
- Do not start a keep-alive Activity from `ACTION_SCREEN_OFF` on Huawei/Honor. Android background-activity-launch rules already classify this as restricted behavior, and Huawei firmware may escalate it to a package force-stop.
- Required manual settings to test on Huawei/Honor: Battery > App launch > TVBridge > Manage manually, enable Auto-launch / Secondary launch / Run in background; Battery optimization > TVBridge > Don't allow optimization; System Manager smart tune-up/background cleanup disabled for TVBridge when available.
- If the device still uses PowerGenie-style killing and the app is not on Huawei's whitelist, there may be no app-side API that guarantees persistence. The practical options are an always-powered Android box/emulator appliance, MDM/device-owner provisioning, or user-side ADB removal/disablement of vendor task killers on a test device.

## VPS Appliance Option

A VPS-hosted Bridge is a good direction when the real product is "serve Jar-backed source and playback work to remote clients" rather than "keep a phone awake as a server":

- Fastest proof of concept: run a minimal Android Bridge worker in a headless Android runtime on the VPS. Keep Nano/Bridge, Jar loading, credential storage, proxying, and only the Android UI host surfaces that a Jar actually needs. Remove TV browsing and player UI from that worker.
- Lower-cost target: extract Jar paths that only need CatVod/Java networking and parsing into a JVM server module. This avoids Android rendering entirely for compatible spiders.
- Practical long-term target: use the JVM server as the primary Bridge and keep a small Android worker pool only for jars that require Android APIs, WebView, native Android libraries, or a real UI flow.

An Android runtime on a VPS avoids phone lock-screen and battery-policy behavior, but it is not automatically cheap. AOSP/Android Emulator style workers still carry an Android system image and need hardware acceleration to stay responsive under load. UI-bound jars also still need an Android render host; run that host on a virtual display or other controlled Android display surface instead of keeping the full TV UI alive.

Before a large split, classify the current jars by capability:

1. Headless Java/CatVod only.
2. Android API or Android storage/cookie dependent.
3. WebView/View/Dialog/Activity dependent.
4. Native ABI dependent.

That matrix decides which code can leave Android safely and which cases need an Android worker fallback.

## Android References

- https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start
- https://developer.android.com/develop/background-work/services/fgs/timeout
- https://developer.android.com/develop/background-work/services/fgs/service-types
- https://developer.android.com/training/monitoring-device-state/doze-standby
- https://developer.android.com/studio/run/emulator-commandline
- https://developer.android.com/studio/run/emulator-acceleration
- https://developer.android.com/reference/android/hardware/display/VirtualDisplay
