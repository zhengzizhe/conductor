# Feedback Feature

## Entry Points

Conductor now keeps two feedback paths separate:

- In-app feedback: the top-right `text.bubble` icon opens a local feedback dialog. This form collects an email address, issue details, app version metadata, the GitHub release URL, and the current update channel.
- GitHub Issue: the dialog also includes a separate button for public issues. It opens the browser at the pre-filled GitHub Issue URL and does not submit the in-app form.

This distinction is intentional so users do not confuse private notification-oriented feedback with public GitHub discussion.

## Validation

The in-app form requires:

- A valid email address.
- A non-empty issue description.

Phone numbers are not supported. Pure phone-number-like values such as `13800138000` or `+8613800138000` are rejected by `FeedbackEmailValidator`.

## API

The request builder and client boundary live in:

- `Sources/ConductorApp/FeedbackSupport.swift`

The default domain is:

```swift
FeedbackClient.defaultDomain == "http://zzzplus.cloud"
```

Change this value, or initialize `FeedbackClient(domain:)`, when the real service domain is ready.

The reserved endpoint is:

```text
POST {domain}/api/feedback
Content-Type: application/json
```

The feedback service currently supports HTTP only. Do not configure this endpoint with `https://` until the service adds TLS support.

Request payload:

```json
{
  "email": "user@example.com",
  "message": "Issue details from the in-app feedback dialog.",
  "appVersion": "1.2.3 (45)",
  "releaseURL": "https://github.com/zhengzizhe/conductor/releases/latest",
  "updateChannel": "manual-github-release"
}
```

Response payload uses the shared three-part shape:

```json
{
  "code": 0,
  "message": "ok",
  "data": {}
}
```

`code == 0` means the feedback was accepted by the service. Any other `code` is treated as a business failure even when the HTTP status is `200`; the app keeps the dialog open and shows `message` so the user can retry. Non-2xx HTTP responses are treated as transport failures and are shown to users as a generic retry message; technical details such as HTTP status codes are logged only.

## Update Metadata

Current update metadata is explicit:

- `releaseURL`: `https://github.com/zhengzizhe/conductor/releases/latest`
- `updateChannel`: `manual-github-release`

When automatic updates are added, update `FeedbackClient.updateChannel` and the localized update-method copy in `FeedbackSheetView`.
