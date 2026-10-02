# Physical network topology matrix (one phone)

Which camera combinations one phone could run at once, judged from each integration's routes
(plan 8.4). **Nothing here is hardware-tested.** The harness only proves that the software
composes and that `ResourceAdmission` rejects what one phone cannot hold; it never joined a
network or opened a USB device.

Status vocabulary (plan 14.5):

- **Qualified:** a recorded physical matrix passed. **No combination is qualified.** Same-brand
  Multi View qualification belongs to each brand app (Pocket, OpenZCine), not to this harness.
- **Feasible, untested:** the claims do not conflict and nothing known rules it out. Needs a
  physical run before anyone calls it supported.
- **Infeasible:** ruled out, with the reason. `ResourceAdmission` rejects the ones it can model.

Routes per integration (`Composition.factories`):

| Integration | Routes | Claim |
|---|---|---|
| DJI Osmo Pocket | Camera access point (SoftAP); station mode on a router or hotspot (provisioned over BLE) | `cameraAccessPoint`, `infrastructureNetwork`, `bluetoothCommissioning` while provisioning |
| Nikon Z | Camera access point; infrastructure network (PTP/IP, JPEG live view); USB-C (PTP) | `cameraAccessPoint`, `infrastructureNetwork`, `usbInterface` |
| Insta360 Luna | Its own access point only (192.168.42.x, one per phone; BLE consent) | `cameraAccessPoint` |
| HDMI capture | UVC capture device on USB: picture only | `usbInterface` |

## Matrix

| # | Combination on one phone | Status | Reason / what a physical run must check |
|---|---|---|---|
| 1 | Several Pockets in station mode on one router | Feasible, untested here | Same network, no claim conflict. Pocket's own Multi View (4 tiles) is the brand app's qualification, not this harness's. |
| 2 | Pockets (station) + Nikon Z (infrastructure) on one router | Feasible, untested | Same infrastructure network. Check: router multicast/discovery for both, combined bitrate, decoder count. |
| 3 | Pocket (station or SoftAP) + Nikon Z over USB | Feasible, untested | Wi-Fi and USB are distinct claims. Check: USB-C host power for the body, PTP/USB transport on iOS (not yet packaged, VENDOR-02). |
| 4 | Nikon Z USB control + HDMI picture of the same body | Feasible, untested | Two USB interfaces (`usb:ptp`, `usb:uvc`) of one device; admission allows it. Needs a powered hub; UVC capture support differs by platform and device (verify on the target phone or tablet). |
| 5 | Nikon Z (infrastructure) + HDMI capture of another camera | Feasible, untested | Wi-Fi + USB. The capture entry has no control and no recording state. |
| 6 | Luna + anything on Wi-Fi (Pocket station/SoftAP, Nikon infrastructure/AP) | **Infeasible** on iPhone | The phone has one Wi-Fi association and Luna offers no shared-network route. Admission: `wifiNetworkConflict`. Android: see note A. |
| 7 | Two Lunas | **Infeasible** | One Luna access point per phone (`LunaWiFi` is process-wide by design); two APs need two associations. Admission: `wifiNetworkConflict`. |
| 8 | Two camera access points of any brands (Pocket SoftAP + Nikon AP, two Pocket SoftAPs, ...) | **Infeasible** on iPhone | One Wi-Fi association. Admission: `wifiNetworkConflict` / `accessPointTaken`. Android: note A. |
| 9 | Luna (its AP) + Nikon Z over USB | Feasible, untested | Wi-Fi + USB are distinct. Check: iOS keeps the camera-AP association while USB is active; Luna adapter on Android still lives in the app. |
| 10 | Luna (its AP) + HDMI capture | Feasible, untested | As 9, picture-only second entry. |
| 11 | Any camera route + Frame.io upload | Feasible only with an explicit internet hop | While on a camera AP there is no internet; the hop takes the Wi-Fi from that camera (OpenCineFrameIO README). Untested in combination. |
| 12 | Commissioning one camera over BLE while another commissions | Serialize | `bluetoothCommissioning` admits one device at a time (`commissioningInProgress`). |
| 13 | More entries than the app's qualified count | App policy | `ResourceBudget.qualifiedEntries` (for example 4) rejects with `overQualifiedLimit`; raising it needs device performance runs, not a constant change. |
| 14 | Luna on phone A, other cameras on phone B, joined by relay | Out of scope | Two processes on two devices; relay (OpenCineRelay) is untested across brands. |

Note A (Android): some Android devices support two concurrent Wi-Fi station connections
(STA+STA, for example a local-only network beside the primary one). Rows 6 and 8 might become
feasible there. `ResourceClaim` assumes one association per phone, so admission rejects them on
every platform today; enabling them needs a per-device capability in the budget and a physical
run. Untested.

## What would move a row to qualified

A recorded physical run (plan 11.4) on named phone and camera models and firmware: connect,
picture on every entry, a group record with per-camera confirmation, a picture failure that does
not fabricate a stopped recording, and teardown that never stops a recording. Record it under the
owning app, then link it here.
