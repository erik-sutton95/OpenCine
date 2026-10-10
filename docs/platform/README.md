# Android platform support

`Android/platform` (`com.opencapture.opencine:platform`, package
`com.opencapture.opencine.platform`) contains Android system adapters. It imports Android and
JVM frameworks only and depends on no integration, UI or app. Portable policy belongs in
Core or Media; this target parallels the platform-specific role of `OpenCineApple`.

`KeystoreSeal(alias)` seals UTF-8 values with a device-only Android Keystore AES key and
opens the existing Base64-IV, colon, Base64-payload envelope (AES/GCM/NoPadding, 128-bit tag,
no AAD). Unavailable keys, malformed envelopes and authentication failures return `null`.

`CameraWifiCredentialStore(context, configuration)` receives a
`CameraWifiStorageConfiguration` with every preferences namespace, Keystore alias, camera
SSID/password key suffix and SSID index prefix supplied by the caller. A new app chooses
these values once as its installed-data contract. The helper does not derive them from an
app name, bundle or integration, and existing apps must retain their original values during
migration.

The store writes encrypted credentials separately from saved-camera JSON. `load(cameraId)`
requires a nonempty SSID and password; `passphrase(ssid)` reads the trimmed SSID index and
retains an encrypted empty passphrase as an empty string. Legacy plaintext camera passwords
migrate through `save` after a failed decrypt only when they contain no envelope separator;
failed sealing writes nothing, unreadable ciphertext is retained, and repeated `remove` is
safe. Existing compatibility wrappers retain their original namespaces and public paths
while consumers migrate explicitly.

`LocalVPNProbe.isActive(context)` reports whether any network carries `TRANSPORT_VPN`;
`noteIfActive(context, log)` hands the caller's journal the VPN notice once per process. The
operator copy and the live-feed hint policy are Core's `LocalVPNFilter`.

No credential value, encrypted envelope or key material belongs in logs. Unit tests use
synthetic values and injected preferences/crypto; installed upgrade checks use synthetic
fixtures in the actual app UID, because Keystore access is owned by that UID.
