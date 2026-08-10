# Automated URL Shortener — Design

**Date:** 2026-08-10
**Status:** Approved

## Summary

Add an opt-in preference that automatically shortens long URLs in outgoing
messages before they are sent. The user chooses one of three services
(TinyURL, is.gd, v.gd) and a minimum URL length (default 40 characters)
below which URLs are left alone.

## Requirements

- Off by default; enabled via a preference checkbox.
- Service picker with exactly three options: TinyURL, is.gd, v.gd.
  All three have free, no-API-key GET endpoints.
- User-configurable minimum URL length, default 40. URLs shorter than the
  threshold are never touched.
- Shortening happens automatically on send — no per-message action.
- A network failure or timeout must never eat a message: on any error the
  original URL is sent unchanged.

## Architecture

### Interception point

`TVCMainWindow -inputText:asCommand:` — the single choke point for
user-typed input, before text is handed to `IRCClient`.

- If the feature is disabled, or the message contains no qualifying URLs,
  the send proceeds synchronously exactly as today (zero change to the
  common path).
- If qualifying URLs are present, the send is deferred: each URL is
  shortened asynchronously, results are substituted into the message, and
  the send then continues through the normal `IRCClient` path.
- Only plain messages and `/me` actions are processed. Other `/commands`
  are sent untouched.
- Programmatic sends (scripts, plugins, internal client traffic) are not
  affected because they do not pass through this input path.

Rejected alternatives:

- **Hook inside `IRCClient sendText:`** — that path is synchronous and
  shared by many internal features; making it async is invasive.
- **Bundled plugin via `THOPluginProtocol` input interception** — the
  interception API is synchronous, so async network calls don't fit.

### `TXURLShortener`

New class in `Sources/App/Classes/Library/`, modeled on `TXImageUploader`:

- Injectable `NSURLSession` (defaults to `+[NSURLSession sharedSession]`).
- `- (void)shortenURL:(NSString *)url completion:(void (^)(NSString *_Nullable shortURL, NSError *_Nullable error))completion;`
  Uses the currently selected service. Completion always on the main queue.
- Pure helpers exposed for testing:
  - `+ requestURLForService:originalURL:` — builds the GET request URL with
    proper percent-encoding.
  - `+ shortURLFromResponseData:statusCode:error:` — validates the response
    (2xx status, body is a single http(s) URL; is.gd/v.gd error bodies are
    rejected).
- Per-request timeout ~10 seconds.

Service endpoints:

| Service | Endpoint |
|---------|----------|
| TinyURL | `https://tinyurl.com/api-create.php?url=<encoded>` |
| is.gd   | `https://is.gd/create.php?format=simple&url=<encoded>` |
| v.gd    | `https://v.gd/create.php?format=simple&url=<encoded>` |

### Detection and substitution

- URLs are found with `NSDataDetector` (link type) over the message's plain
  text.
- Only `http`/`https` links whose absolute string length is ≥ the threshold
  qualify.
- Multiple URLs in one message are shortened concurrently; the message is
  sent once all requests complete or time out.
- If a shortened result is not actually shorter than the original, the
  original is kept.
- On any per-URL failure the original URL for that link is kept; the
  message still sends.

## Preferences

Three new keys on `TPCPreferences`, with defaults registered alongside the
existing keys:

| Defaults key | Accessor | Type | Default |
|--------------|----------|------|---------|
| `AutomaticallyShortenOutgoingLinks` | `+shortenOutgoingURLs` | BOOL | NO |
| `URLShortenerService` | `+urlShortenerService` | integer enum (0 = TinyURL, 1 = is.gd, 2 = v.gd) | 0 |
| `URLShortenerMinimumLength` | `+urlShortenerMinimumLength` | integer | 40 |

UI lives in the **Behavior** pane (`contentViewBehavior`) of
`TDCPreferencesController`:

- Checkbox: "Automatically shorten links in sent messages"
- Popup button: service (TinyURL / is.gd / v.gd)
- Number field: "Only shorten links longer than [ 40 ] characters"
- Popup and field are enabled only when the checkbox is on.
- Controls are bound through user defaults bindings, matching the
  surrounding controls in the pane.

## Error handling

- Request timeout (~10s), non-2xx status, empty/invalid body, or a body
  that is not a single http(s) URL → treat as failure, keep original URL.
- No user-facing error dialogs; the worst case is simply that the original
  long URL is sent, matching what would happen with the feature off.

## Testing

Unit tests in the existing `Tests/` target, no live network:

- `requestURLForService:originalURL:` — correct endpoint per service,
  proper percent-encoding of query characters (`&`, `?`, unicode).
- `shortURLFromResponseData:statusCode:error:` — accepts a valid short URL
  body; rejects error bodies, non-2xx statuses, empty data, non-URL bodies.
- URL detection/substitution — threshold filtering, multiple URLs,
  non-http schemes ignored, commands other than messages/`/me` untouched,
  result-longer-than-original keeps original.

## As-built deviations

- **Overlap-safe substitution.** Code review found that when one detected URL
  is a prefix of another, replacing the shorter first corrupted the longer
  (nondeterministically, per dictionary order). Substitution now iterates
  mappings sorted by original length descending (commit 3adce3231), and —
  after final review found the asymmetric case where the longer URL's
  request failed — replaces only `NSDataDetector` link matches whose text
  exactly equals the original URL (commit b3e955c7c), so a failed longer
  URL is never rewritten from the inside. Both cases have deterministic
  regression tests (23 checks total).
- **Cmd-Return actions are shortened too.** The interception guard accepts
  `IRCRemoteCommandPrivmsgAction` in addition to `IRCRemoteCommandPrivmsg`
  (commit 3a9020b8e) — the spec's "plain messages and `/me` actions" scope
  otherwise excluded actions sent via Cmd-Return. The async send-ordering
  tradeoff (a deferred message may arrive after a later one) is documented
  in a code comment at the shorten call site.
- **Xib stackView extras.** The preferences row stackView carries
  `visibilityPriorities`/`customSpacing` children mirrored from the file's
  existing stackView precedent, which the plan anticipated as a possible
  ibtool requirement.
- **Verification.** Full `xcodebuild` of scheme "Textual (Debug)" succeeded
  with zero warnings in the files this feature touched; standalone test
  suite passes 23/23.
