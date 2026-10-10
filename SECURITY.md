# Security policy

OpenCine is shared camera software. Apps provide transport, permissions, secure storage and
optional services; the shared platform supplies contracts, integrations, media and UI.

## Supported source

This is a source candidate. Include the OpenCine commit and the consuming app's pinned commit
when reporting a vulnerability. A source fix does not update an installed app until that app
adopts and verifies the change.

## Report privately

Do not open a public issue for a vulnerability. Use
[GitHub private vulnerability reporting](https://github.com/erik-sutton95/OpenCine/security/advisories/new).
Describe the affected component, reproduction steps, impact and source versions. For an
app-specific vulnerability, use that app's security policy; maintainers can coordinate a shared
fix privately.

Do not include camera Wi-Fi passwords, pairing credentials, signing material, service tokens,
private captures or identifying operator information in public reports or Git history.
Sanitize diagnostic evidence before sharing it.

## Trust boundaries

- Core and portable media code stay independent of UI, apps and integrations.
- Integrations own their wire behavior and keep UI out. Commands retain current-session and
  per-operation admission; unknown observations do not imply permission to write.
- Apps own permissions and credential configuration. Shared storage adapters use explicit host
  configuration; saved-camera records do not serve as credential stores.
- Native picture and clip owners keep source, cancellation and lifetime fences. An available
  picture is not permission to send a camera command.
- Developer harnesses and impairment scenarios are SIMULATED or controlled. They do not ship
  as products or replace normal hardware verification.

See [AGENTS.md](AGENTS.md), [the native runtime guide](docs/native-runtime/README.md) and
[the Android platform guide](docs/platform/README.md) for the corresponding ownership rules.
Coordinate disclosure with the maintainer; reporter credit is optional. This policy makes no
claim that all dependencies, camera firmware or app integrations have been security audited.
