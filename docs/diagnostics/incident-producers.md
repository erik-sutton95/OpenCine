# Incident producer context and observations

`FeedIncidentRuntime.sessionContext` constructs incident context from the shared
diagnostics host and `DiagnosticsDevice`. Producers provide the observed camera
family, optional firmware and generation values. Raw text is redacted before it
is bounded. A session gets a fresh ephemeral identity; no serial, operator name
or identifier comes from a camera.

`FeedIncidentRateSampler` samples cumulative `FeedIncidentStageCounts` using a
monotonic clock. Its optional observed rates distinguish measured zero from an
unavailable stage, first reading, invalid interval or counter reset. A duplicate
or reversed clock reading cannot consume the latest baseline. A changed
`FeedIncidentCounterEpoch` seeds a new baseline even if the successor's counts
are larger. The original numeric `FeedIncidentRates` members and initializer
remain available for existing policy and callers; `rates.observed` carries the
measurement availability. Older stored records decode without that field.

Age helpers require both readings from the same clock domain. Missing, invalid
or future observations stay absent. Source adapters choose the appropriate wall
or monotonic clock; the sampler does not convert between clock domains.

Apple's `incidentDecoder` and Android's decoder extension only project existing
native observations. JPEG adapters retain their own observed stages. Raster
publication is not presentation, and an access unit is not a transport packet
or proof of synchronous native decode acceptance.

Beginning a bound session ends a live predecessor and saves its summary before
beginning the successor. The replacement time is captured on admission, using
an injectable monotonic clock. Captured sources reject retired submissions,
including delayed end, disconnect, repair, snapshot and generation updates.
Android `FeedIncidentBindings` provides the same contract for injected legacy
sinks and a host's read-only owner identity check. Swift producers use the
runtime's captured source directly. Existing native frame ownership, lifecycle
classification, transport recovery and camera commands are unchanged.
