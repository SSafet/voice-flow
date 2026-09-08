# VF-36: Revocable phone distraction controls

Assessment: 8 September 2026. Research deliverable; no new monitoring or restrictions have been enabled.

## Recommendation

Build Android first: an explicitly started focus session, local selected-app usage totals, and optional reminders. Let the agent propose a bounded plan; the phone owns permission checks, expiry, and an always available **Stop focus** action. Start without screenshots, VPN interception, device management, or expanding the existing dictation accessibility grant. Follow with optional, separately consented, dismissible overlays if reminders prove too weak.

This is a friction tool, not an unbreakable blocker. It must be easy for Safet to stop, even offline or when the agent fails. iOS is feasible as a separate Screen Time implementation, but cannot supply the same general screen observation and remote usage-data pipeline.

## What the connected phone proves

Read-only ADB inspection found Samsung SM-S938B, Android 16 / API 36, August 2026 security patch, Voice Flow installed, and both Usage Access and overlay settings resolvable. Voice Flow's overlay app-op is allowed; usage access has no recorded grant. The manifest does not yet request usage access. The expected Tailscale package is not installed on this phone, although the companion architecture supports Tailscale. Raw results: [device-capabilities.json](device-capabilities.json).

The existing accessibility service only handles transcript insertion: its event callback is empty, it subscribes to focus events, and it declares neither screenshot capability nor a distraction monitor. Existing overlay permission is not consent to a new monitoring feature. ADB's shell authority does not prove that the app can read other apps' usage. No usage history, screen contents, credentials, or other app data were collected. These are capability and configuration checks, not an implemented intervention or battery benchmark.

## Platform feasibility

| Capability | Android personal phone | iOS personal phone |
|---|---|---|
| App usage | UsageStatsManager exposes app totals/events after a separate user grant in Usage Access settings. Query incrementally and mark missing access/data visibly. [Android API](https://developer.android.com/reference/android/app/usage/UsageStatsManager) | Family Controls authorizes Screen Time; Device Activity provides schedule/threshold callbacks and reports. Report extensions are sandboxed against network requests and exporting sensitive report contents. Do not promise an unrestricted app-usage feed to a remote agent. [Apple report API](https://developer.apple.com/documentation/deviceactivity/deviceactivityreport) |
| Screen context | MediaProjection needs user consent per session; Android 14+ requires the appropriate foreground-service declaration and single-use projection token. Stop/revoke ends observation. Capture can expose messages and passwords; protected surfaces may not be captured. [MediaProjection](https://developer.android.com/media/grow/media-projection) | ReplayKit provides recording/broadcasting with user-facing controls, not silent always-on observation of arbitrary apps. Exclude it from the minimal design. [ReplayKit](https://developer.apple.com/documentation/replaykit), [system broadcast picker](https://developer.apple.com/documentation/replaykit/rpsystembroadcastpickerview) |
| Accessibility context/actions | A separately enabled service can observe configured events and act on exposed UI; API 30+ screenshots require declared capability. This is much broader access than usage totals and is unnecessary for the first version. [AccessibilityService](https://developer.android.com/reference/android/accessibilityservice/AccessibilityService) | No equivalent general third-party AccessibilityService for inspecting and operating arbitrary apps. Use the supported Screen Time controls. [Family Controls](https://developer.apple.com/documentation/familycontrols) |
| Reminders/friction | Notifications and permissioned, dismissible overlays are feasible. These do not suspend an app and may be suppressed by OS notification settings or background execution limits. Delivery and latency need physical-device validation. | Screen Time can shield user-selected apps/categories/domains under individual authorization. Users can revoke from Settings; individual authorization does not prevent deleting the app. [Apple WWDC example](https://developer.apple.com/videos/play/wwdc2022/110336/) |
| Hard suspension | setPackagesSuspended is a device/profile-owner management feature, not authority available to the existing ordinary app. Work-profile controls do not give general control of personal-profile apps. Do not enroll this personal phone or require a reset. [Android Enterprise](https://developer.android.com/work/dpc/security) | ManagedSettings shields are the supported route; Family Controls capability and distribution entitlement approval are prerequisites. Device Activity extensions enforce approved schedules. [Family Controls setup](https://developer.apple.com/documentation/familycontrols) |
| Network blocking | VpnService could filter traffic but only one VPN service can run per user/profile. A new VPN replaces the current one, conflicting with a future Tailscale connection. It also cannot block offline distractions. Exclude from this version. [Android VPN](https://developer.android.com/develop/connectivity/vpn) | Not needed for Screen Time shielding. Do not promise arbitrary packet inspection or bypass Apple's entitlement requirements. |

## Distribution and privacy constraints

Google Play explicitly prohibits accessibility automation that autonomously initiates, plans, and executes actions or decisions for ordinary assistants. Deterministic user-defined rules are distinguished from that prohibition, but accessibility declarations and prominent disclosure still apply. The current companion is sideloaded, so Play distribution approval is not its installation gate; that does not remove OS permission boundaries or justify concealed monitoring. Keep any future agent output as a proposed plan, with deterministic enforcement of user-approved scope. [Google Play policy](https://support.google.com/googleplay/android-developer/answer/10964491?hl=en)

iOS distribution requires requesting the Family Controls entitlement for the app and relevant Screen Time extensions. Prefer individual authorization for this self-control use case, with native app selection. Do not treat opaque selection tokens as freely exportable usage details. [Apple Family Controls](https://developer.apple.com/documentation/familycontrols)

For this personal-use proposal, informed local consent and data minimization are design requirements. The platform sources establish API and distribution constraints, not a blanket legal determination for collecting third-party messages or commercial deployment. Any wider release needs review of its actual data flows and applicable law.

## Smallest implementation

1. Add a Focus page: state (Off / Active until time / Paused), selected apps, per-session time budget, reminder threshold, and visible permissions. Default Off; no automatic enabling after pairing or an assistant request.
2. Add separate grants for usage observation and notifications. Existing dictation/overlay permissions remain independent. Open the native settings screen, then recheck app-op on return and before every read; a denied grant means unavailable, never zero usage.
3. Persist a local session ID, revision, selected packages, start/expiry, limits, and enabled state. The agent may propose or adjust within a grant the user explicitly approved. It cannot add apps, extend expiry, resume after Stop, or acquire permissions beyond that grant.
4. Start with on-open usage summaries and scheduled reminders. For timely foreground-app detection, prototype a visible user-started foreground service and validate its allowable service type/background limits on target Android before promising enforcement latency. Do not reuse the microphone service type for usage monitoring. OS-delayed observation must be shown as delayed.
5. Keep coarse totals locally, recommended retention seven days. Store no UI text/screenshots. Sharing a daily summary to Mac/agent is a separate opt-in with a preview and delete control; no raw event stream upload. Encrypt transfers before sending sensitive usage data: the current companion permits cleartext HTTP, so local-network sync alone is insufficient protection.
6. Optional second increment: user-approved dismissible overlay at the threshold, with Continue, Pause, and Stop. Never cover system permission screens, emergency calling, Settings, or the app's own stop action. A model may explain a reminder but is not on the enforcement path.

## Kill switch contract

**Stop focus** in the app and ongoing notification works locally in one action. Atomically persist Off and increment the grant revision first; cancel collectors, callbacks, timers and pending notifications; remove overlays; reject any stale in-flight agent plan. Clear expiry/restart jobs. Check Off/revision before every observation or intervention, including after asynchronous work. A process restart, phone reboot, or remote reconnect stays Off. Pausing immediately removes interventions and observation too; resume is explicit. A separate Delete focus data action erases retained local data and requests deletion of any opted-in synced copies.

Permission rows show OS status and a link to revoke each special grant. Revoking usage access stops its collector immediately upon detection; other features such as dictation still work. Native force-stop/uninstall remains an escape. Any future projection stops and releases its display, and any future VPN closes its interface; neither is in the first increment.

On iOS, stop monitoring and clear every Voice Flow named ManagedSettingsStore so extensions cannot leave shields behind. Persist Off/revision in the shared container and make extensions check it before shielding. **Disconnect Screen Time** also calls revokeAuthorization and checks actual authorization status; Settings provides independent revocation. [Apple revoke API](https://developer.apple.com/documentation/familycontrols/authorizationcenter/revokeauthorization(completionhandler:)), [clearing stores example](https://developer.apple.com/videos/play/wwdc2022/110336/)

## Tradeoffs and implementation proof required

Usage totals are lower sensitivity and expected lower energy than repeated screenshots, but still reveal habits and are not precise proof of attention. Notifications are cheap but bypassable. Event polling and overlays need background execution and use more energy; continuous capture plus remote vision is the highest sensitivity, network, and battery option. These are engineering expectations, not measured percentages.

Before shipping implementation, run on this phone: deny/grant/revoke each capability, exceed a selected-app budget, verify unrelated apps remain unaffected, stop while an agent reply is in flight, lose connectivity, force-stop/relaunch/reboot, change clock/timezone, and verify the Off state and no stale intervention. Record notification/overlay latency under battery optimization and compare matched idle plus active-use battery sessions with Focus off/on. iOS separately needs a real entitled-device trial of threshold shields, all-store clearing, extension races, Settings revocation, and offline stop. No iOS device or entitlement was tested in this research ticket.

VF-36's feasibility, tradeoff, capability, and kill-switch deliverables are complete. Implementation is the proposed next project, not evidence claimed by this assessment.
