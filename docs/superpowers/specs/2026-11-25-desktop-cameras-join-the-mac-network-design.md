# OpenCine desktop: cameras join the Mac's network

Date: 2026-11-25. The owner chose approach A on 2026-11-24. This builds on
`2026-11-05-opencine-desktop-design.md` and `2026-11-24-desktop-single-window-tabs-design.md`.

## Why

On a phone, the first-pairing wizard's step 3 has the phone join the camera's own Wi-Fi. A Mac app
cannot do that, so on the Mac the Pocket and Luna modules dead-end at step 3 today:

- Pocket throws "this Mac cannot join a camera's Wi-Fi by itself".
- Luna asks the owner to join by hand in macOS settings.

On a computer the camera has to come to the computer: it joins a Wi-Fi network that the computer can
also reach. Windows later works the same way.

## Goals

- On the Mac, pairing a new Pocket or Luna ends with the camera on the Mac's network and live in its
  tab. There is no camera Wi-Fi step and no trip to System Settings.
- The owner names the network and types its password once. Every camera paired after that joins the
  same network without asking again, with a way to change it.
- The setup works whether the Mac is on that network by Wi-Fi or by Ethernet through the same router.

## Non-goals

- The Mac creating its own network with Internet Sharing (approach B, a later "no router" option).
- Joining the camera's own Wi-Fi on the Mac.
- The Nikon module (USB and HDMI capture) is unchanged.
- The full "this iPhone" copy pass across the apps. Only the screens this flow shows get Mac wording.
- Any change on iPhone, iPad or Android.

## Approaches considered

- **A, chosen: cameras join a router or venue Wi-Fi that the Mac is also on.** It uses the existing
  shared Wi-Fi station route, which both apps already have.
- B: the Mac shares its own network (Internet Sharing). An app cannot turn it on, and it does not
  carry over to Windows. Kept for later.

## What exists (verified 2026-11-25)

- Both cameras can be moved onto a station network straight after Bluetooth pairing, with no
  camera Wi-Fi session first:
  - DJI: `DjiAppleConnectionRun.run` goes from pairing to `runStation`.
  - Luna: `moveOverBluetooth`, then `LunaStationJoin` (join 112).
  - Both accept an `.addRoute` for an unsaved sighting. For Luna this is
    `LunaIntegration.connect(_:onto:)`, which today is only called from tests.
- The network picker and password pages exist and are shared (`StationNetworkSetupView`).
  Passwords are kept in the Keychain:
  - Pocket: `MultiviewNetworkStore`.
  - Luna: `LunaSecureStore` stations.
- Camera discovery on the network exists:
  - DJI: subnet sweep plus a `getWifiSsid` identity check.
  - Luna: port 6666 probe plus a serial check.
- Gaps on the Mac:
  - The pairing wizard always picks the camera Wi-Fi route.
  - DJI's station path still tries to join the Mac to the network itself
    (`DjiAppleSharedWiFiPath.joinHost`, `NEHotspotConfigurationManager.apply`).
  - Both station paths assume Wi-Fi is `en0`.
  - The Mac's current network name reads as nil: there is no Wi-Fi info entitlement, and some
    `!macCatalyst` returns nil.
  - The wizard and network pages say "this iPhone" and "iOS asks to join".

## Design

**The Mac's camera network.** Each module keeps one camera network: a network name, its password in
the Keychain, and whether it was confirmed. It is the station network that this module's cameras
join on the Mac.

- The first pairing asks for it, using the existing network and password pages. On the Mac those
  pages offer:
  - the network the Mac is on, when it can be read;
  - networks saved before;
  - other network (typed name);
  - cameras' scan results where the camera can scan (DJI).
- Camera Wi-Fi and phone hotspot are not offered.
- After the first pairing, the wizard shows "Cameras join <network>" with a Change action and does
  not ask again.
- The camera network belongs to each module. The Pocket and Luna modules each ask once.

**Pairing on the Mac.** After the camera approves over Bluetooth, the module connects the new
camera with the station route to the camera network (`.addRoute` with `.infrastructureNetwork` from
the sighting). It never uses the camera Wi-Fi route.

- The wizard's third step becomes "Join your network", with the body "The camera joins <network>,
  the same network as this Mac." The step progress mapping is unchanged.
- A failure keeps the wizard's existing retry and shows the integration's own message. That
  includes the known camera network quirks (Nano and WPA3-only, Pocket 4 Pro and Wi-Fi 7 MLO,
  5 GHz-only networks).

**Which interface.** On the Mac, the station path and discovery stop assuming `en0`. They use every
active IPv4 interface on a private subnet, Wi-Fi or Ethernet. Discovery sweeps the /24 of each
interface, the default route's interface first. The rule that picks the interfaces is a pure
function in shared code, with tests.

**The Mac's network name.** The Mac builds get the Wi-Fi info entitlement and ask for location
permission, as iOS already does, so `NEHotspotNetwork.fetchCurrent` can name the current Wi-Fi.
When it cannot (Ethernet, permission refused), the page lists saved networks and the typed option.
The page never blocks on it.

**DJI on the Mac.** `joinHost` does not try to join the Mac to the network. It checks that the Mac
has a usable interface (as above) and goes on. Luna already skips the host join on Catalyst.

**Words.** A small shared helper names the host device: "this iPhone", "this iPad" or "this Mac".
The wizard, the station network pages and the step titles in this flow use it. On iPhone and iPad
their words do not change.

**What carries to Windows.** The rules live in shared, platform-neutral code with tests:

- route choice on a computer host;
- the camera network record and its reuse;
- the interface pick;
- the step copy.

## How it is checked

- Unit tests for the route choice on a Mac host, the camera network reuse, the interface pick, the
  Mac step copy, and iPhone copy staying unchanged.
- Hardware, owner: on this Mac, pair the Pocket and the Luna onto the studio Wi-Fi, once over the
  Mac's Wi-Fi and once over Ethernet. Each shows live in its tab, and a second camera of either kind
  joins without asking for the password. These go on the desktop hardware checklist.

## Left to the builder

- Where the camera network record lives: an extension of each app's existing store is fine.
- The exact copy of the Change action and of the "Cameras join" line, within the words rule above.
- Whether the interface pick lives in `OpenCineApple` or `OpenCineCore`, as long as it is shared
  and tested.
