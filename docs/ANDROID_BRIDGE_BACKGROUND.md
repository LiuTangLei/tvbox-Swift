# Android Bridge Background Notes

## Current State

- `HeadlessServerService` is shared by the Android mobile and leanback flavors. Each `HomeActivity` starts it after the app is opened.
- The service starts Nano/Bridge as a foreground service and declares the Android foreground-service type `dataSync`.
- Leanback has a boot receiver today. Mobile currently starts the service after the user opens the app.
- Some Bridge work is HTTP-only, but Jar UI and detail-UI fallback paths still need a foreground Android `Activity` or bring the host app back to the front.

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
2. Add an explicit server status surface and a user-visible server start/stop affordance if Android becomes a regular Bridge appliance.
3. Decide whether production long-running serving remains `dataSync`, moves to a more appropriate foreground-service declaration, or uses an Android runtime that stays actively hosted by another deployment layer.
4. Test three levels separately: app sent Home, screen locked shortly after start, and long idle/Doze behavior on a physical phone.

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
