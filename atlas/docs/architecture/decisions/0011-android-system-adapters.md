# ADR 0011: Neutral Android system adapters

Status: Accepted for local implementation on 2026-10-02; candidate until consumer checks and integration.

Keystore and installed credential storage need Android framework APIs, so they live in the small `:platform` module while incident policy, privacy redaction and capture math live in existing `:media`; putting them in DJI couples other integrations to a camera manufacturer, and putting them in portable Media couples policy to Android. Apps supply every preferences namespace, key alias and key shape, and compatibility wrappers preserve existing public JVM paths, the AES/GCM envelope with no AAD, and plaintext migration while consumers migrate under add/migrate/remove. The DJI EV wire offset stays in its adapter, and redaction accepts a caller policy for safe diagnostic network names rather than detecting a manufacturer in shared Media.
