# Image Paste/Drop Upload — Design

**Date:** 2026-07-29
**Status:** Approved (pending spec review)

## Goal

Let the user paste (Cmd-V) or drag-and-drop an image onto the message input
field. The image is auto-uploaded to catbox.moe, and the resulting direct URL is
inserted into the input field for the user to review and send manually. Nothing
is ever sent to a channel automatically.

## Decisions (from brainstorming)

- **Host:** catbox.moe — no API key, permanent uploads only (no litterbox in v1).
- **Send flow:** Insert URL into input; the user presses Enter to send. Never auto-send.
- **Triggers:** Clipboard image paste *and* drag-and-drop of an image file.
- **In-progress UX:** Insert a placeholder token immediately, swap it for the URL when done.
- **Errors:** Inline, non-modal — replace the placeholder with a brief failure note; keep image data (paste fallback). No alert dialogs.

## Components

### 1. `TXImageUploader` (new)

Location: `Sources/App/Classes/Library/`

The isolated upload unit. Knows nothing about the UI.

Interface:

```objc
- (void)uploadImageData:(NSData *)data
               filename:(NSString *)name
             completion:(void (^)(NSString * _Nullable url,
                                  NSError * _Nullable error))completion;
```

Behavior:

- Builds a `multipart/form-data` POST to `https://catbox.moe/user/api.php`.
  - Form field `reqtype=fileupload`.
  - File part `fileToUpload` with the image bytes and filename.
- Uses `NSURLSession` (async, off the main thread). The completion block is
  dispatched back to the main queue.
- The catbox response body **is** the direct URL as plain text on success.
  - Success = HTTP 200 **and** body begins with `https://`.
  - Otherwise construct an `NSError` (HTTP error, empty/non-URL body, transport error).
- No API key, anonymous upload.
- `NSURLSession` is injectable (initializer or property) so tests can supply a mock.

### 2. Paste / drop handling in `TVCMainWindowTextView`

Existing class: `Sources/App/Classes/Views/Main Window/TVCMainWindowTextView.m`
(already overrides `paste:` at line ~247).

- **Paste:** In `paste:`, inspect `NSPasteboard` for image content:
  - Image data types (`NSPasteboardTypePNG`, `NSPasteboardTypeTIFF`).
  - File URLs whose UTI conforms to `public.image`.
  - If an image is present, intercept and route to the uploader. Otherwise call
    `super` (unchanged behavior for text and other content).
- **Drag & drop:** Register for dragged types (file URLs + image data) and
  implement `draggingEntered:` / `draggingUpdated:` / `performDragOperation:`.
  Accept image file URLs and image data, routing the same way. Non-image drags
  fall through to default behavior.

## Data flow (placeholder swap)

1. Image detected → normalize to PNG `NSData`. Filename is always `image.png`
   (since bytes are re-encoded as PNG), regardless of the source's original
   name/format.
2. Insert a unique placeholder token at the caret immediately, e.g.
   `[uploading image #N…]`, where `N` is a monotonically increasing counter.
   The UI stays responsive; the user can keep typing.
3. Start `TXImageUploader` asynchronously.
4. **On success:** locate the exact placeholder token in `stringValue` and
   replace it with the URL. If the token was edited or deleted in the meantime,
   append the URL at the end of the field as a fallback (nothing is lost).
5. **On failure:** replace the token with `[image upload failed]`, then remove
   that note automatically after a few seconds. Nothing is auto-sent at any point.

Concurrent pastes/drops are supported through the numbered token (`#N`), so two
in-flight uploads never collide.

## Error handling

- Network error, HTTP non-200, non-URL response body, or catbox size limit
  (200 MB) → inline `[image upload failed]` per the flow above. No modal alerts.
- Zero-byte or non-image clipboard content → fall through to normal `paste:`
  behavior (image path is never entered).

## Testing

**Unit (`TXImageUploader`):**

- Inject a mock `NSURLSession`.
- Verify multipart body construction (boundary, `reqtype` field, file part).
- Verify response parsing:
  - HTTP 200 + `https://…` body → success URL.
  - HTTP 200 + error body (non-URL) → error.
  - HTTP non-200 → error.
  - Transport error → error.

**Manual:**

- Paste a screenshot → placeholder → URL appears in input.
- Drag a PNG and a JPG file onto the input → upload + URL.
- Paste plain text (regression) → unaffected.
- Oversized file → inline failure note that auto-clears.
- Two rapid pastes → two distinct tokens, both resolve correctly.

## Scope boundaries (YAGNI)

- catbox permanent uploads only; no litterbox/temporary-link option in v1.
- No preferences UI; host is hardcoded to catbox. The `TXImageUploader`
  interface is the seam for adding host selection or expiry later.
- All images normalized to PNG on upload; per-format passthrough (keep JPEG as
  JPEG) is a possible later refinement, not in v1.
