# Streaming services

The facts behind `StreamServicePreset.all`, checked against each service's own documentation on
2026-11-18. "Unconfirmed" means no official page stated it; the value comes from the plan's
starting point or a secondary source and must be proven by the hardware pass (a real stream to
each service) before an external build.

Engine defaults from the spec: H.264, 2 second keyframe interval, AAC-LC stereo at 48 kHz and
160 kbps, about 3 Mbps at 720p and 6 Mbps at 1080p. Presets are `rtmps://` only; a Custom server may
be plain `rtmp://` with a warning (owner, 2026-11-20).

## Twitch

| Fact | Value | Source |
|---|---|---|
| Server | `rtmps://ingest.global-contribute.live-video.net/app` (the "Default" entry); port 443 unconfirmed | [ingest.twitch.tv/ingests](https://ingest.twitch.tv/ingests) |
| Maximum bitrate | 6 Mbps for most broadcasters (unconfirmed: secondary sources) | Twitch Broadcasting Guidelines did not load |
| Codecs, keyframe | H.264, AAC, 2 s (unconfirmed: secondary sources) | same |
| Key | Broadcaster dashboard on twitch.tv; the menu path in the hint (Creator Dashboard, Settings, Stream) is from secondary guides | [dev.twitch.tv/docs/video-broadcast](https://dev.twitch.tv/docs/video-broadcast/) |

## YouTube

| Fact | Value | Source |
|---|---|---|
| Server | `rtmps://a.rtmps.youtube.com/live2` (hostname unconfirmed); RTMPS on port 443; Live Control Room shows the RTMPS URL behind the lock icon | [RTMPS ingestion](https://developers.google.com/youtube/v3/live/guides/rtmps-ingestion), [answer 10364924](https://support.google.com/youtube/answer/10364924) |
| Bitrate (H.264, minimum to recommended) | 720p30: 3 to 8 Mbps. 1080p30: 5 to 14 Mbps. 1080p60: 6 to 17 Mbps | [answer 2853702](https://support.google.com/youtube/answer/2853702) |
| Keyframe | 2 s recommended, at most 4 s | same |
| Audio | AAC or MP3; stereo recommended at 44.1 kHz and 128 kbps | same |
| Key | YouTube Studio, Create, Go live, Stream tab; the key persists between streams | [answer 2907883](https://support.google.com/youtube/answer/2907883) |

## Facebook

| Fact | Value | Source |
|---|---|---|
| Server | `rtmps://rtmp-api.facebook.com:443/rtmp/`; RTMPS is mandatory. The plan's starting point `live-api-s.facebook.com` appears only in secondary sources | [getting started](https://developers.facebook.com/docs/live-video-api/getting-started), [overview](https://developers.facebook.com/docs/live-video-api/overview) |
| Video | H.264 (level 4.1, 4.2 for 1080p60), at most 1920x1080. 720p30: 1.5 to 4 Mbps. 1080p30: 3 to 6 Mbps. 1080p60: 4.5 to 9 Mbps | [Live Video API reference](https://developers.facebook.com/docs/live-video-api/reference) |
| Keyframe | 2 s recommended, at most 4 s | same |
| Audio | AAC-LC stereo, 44.1 or 48 kHz, 128 kbps preferred, at most 256 kbps | same |
| Key | Live Producer, Streaming software (menu path and persistent key option unconfirmed) | secondary |

## Instagram

| Fact | Value | Source |
|---|---|---|
| Server | Issued together with the key on instagram.com, Create, Live; the key refreshes every time. Whether the URL is `rtmps://` is unconfirmed (the post says "Custom RTMP") | [Instagram Live Producer](https://about.instagram.com/blog/tips-and-tricks/instagram-live-producer/) |
| Video | 9:16 recommended, 720x1280, 2.25 to 6 Mbps, 30 fps recommended (60 supported) | same |
| Audio | 44.1 kHz stereo, up to 256 kbps | same |
| Keyframe | unconfirmed | |

## TikTok (not a preset)

The request in OpenPocketCine discussion 54 also names TikTok LIVE. It has no preset because the
spec's preset list is Twitch, YouTube, Facebook and Instagram; a TikTok key goes through Custom.
What is known: LIVE needs an account aged 18 or over with 1,000 followers, varying by region
([TikTok FAQ](https://www.tiktok.com/support/faq_detail?id=7543604790438451768)); TikTok LIVE Studio
gives a "Server URL and Stream Key" to accounts with access
([TikTok blog](https://www.tiktok.com/live/creator-networks/en/blog/how-to-go-live-on-tiktok)).
Unconfirmed: whether ordinary accounts get keys, and whether the server URL is `rtmps://`. TikTok
often issues plain `rtmp://`, which Custom accepts with the unencrypted warning (owner,
2026-11-20). The Custom key hint says where TikTok shows its server and key.

## Where the services differ from the spec's defaults

None refuses the defaults, so the presets keep them. For the owner's review:

- YouTube recommends 44.1 kHz audio at 128 kbps for stereo; the engine sends 48 kHz at 160 kbps,
  which Facebook documents as accepted. 3 Mbps at 720p is YouTube's minimum, not its recommendation.
- Facebook caps 720p30 at 4 Mbps and 1080p30 at 6 Mbps; the defaults sit inside both.
- Instagram documents 44.1 kHz audio and does not say its server is `rtmps://`. Its preset accepts
  only `rtmps://`; an `rtmp://` Instagram address would have to go through Custom.
- TikTok may issue plain `rtmp://` addresses; Custom accepts them with the unencrypted warning.
