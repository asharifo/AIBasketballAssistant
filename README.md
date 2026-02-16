# AIBallz (HoopVision) iOS App

AIBallz is a SwiftUI iOS application that performs near real-time basketball shot analysis from camera frames, detects shot outcomes (make/miss), stores shot history locally, and requests form feedback from a backend API.  
The app currently supports authenticated sessions with Auth0 and a local-first analysis flow powered by Vision + Core ML.

## Table of Contents

- [Overview](#overview)
- [Core Features](#core-features)
- [Technical Architecture](#technical-architecture)
- [End-to-End Runtime Flow](#end-to-end-runtime-flow)
- [Project Structure](#project-structure)
- [Requirements](#requirements)
- [Configuration](#configuration)
- [Auth0 Setup](#auth0-setup)
- [Feedback Backend Contract](#feedback-backend-contract)
- [Build and Run](#build-and-run)
- [Testing](#testing)
- [Data Storage and Security](#data-storage-and-security)
- [Known Limitations](#known-limitations)
- [Troubleshooting](#troubleshooting)

## Overview

- App target: `AIBallz` (display name is configured as `HoopVision` in build settings).
- UI framework: SwiftUI (`TabView` with Analysis, History, Account).
- Local persistence: SwiftData model container for `ShotRecord`.
- Real-time video pipeline:
  - `AVCaptureSession` camera stream + recorder
  - Vision human body/hand pose estimation
  - Core ML object detection model (`best.mlpackage`) for basketball + hoop
  - Custom shot-state machine and tracker heuristics
- Auth/session:
  - Auth0 Authorization Code + PKCE via `ASWebAuthenticationSession`
  - Keychain-backed credential storage
- Backend integration:
  - POST shot + motion windows to `/v1/shot-feedback`
  - Optional bearer token from the active Auth0 session

## Core Features

1. **Authentication**
   - Login and sign-up via Auth0.
   - Session bootstrap + refresh token flow.
   - Logout with Auth0 browser logout and local credential cleanup.

2. **Live Shot Analysis**
   - Camera preview with overlaid detections and pose keypoints.
   - Running counters: total shots and makes.
   - Make/miss detection using a custom state machine over tracked ball/hoop trajectories.

3. **Shot History and Metrics**
   - SwiftData-backed shot records.
   - Time range filters (`Week`, `Month`, `All Time`).
   - Charts (`Charts` framework) for attempts vs makes.
   - Per-shot detail page including LLM form feedback text.

4. **Backend Feedback Integration**
   - Sends shot metadata plus recent pose/detection windows.
   - Persists backend feedback result per shot.
   - Graceful fallback message on backend errors.

## Technical Architecture

### UI Layer

- `AIBallz/AIBallzApp.swift`
  - Creates `AuthManager` as app-wide `EnvironmentObject`.
  - Initializes SwiftData container for `ShotRecord`.
- `AIBallz/ContentView.swift`
  - Root state gate:
    - `loading` -> spinner
    - `unauthenticated` -> `AuthenticationView`
    - `authenticated` -> `MainTabView`
- `AIBallz/Views/...`
  - `VideoAnalysisView`: live pipeline orchestration, persistence, feedback requests
  - `ShotHistoryView`, `ShotDetailView`: historical analytics + details
  - `AccountView`: current user profile + logout

### Camera + Vision + ML Layer

- `AIBallz/Managers/Camera/CameraManager.swift`
  - Configures `AVCaptureSession` with:
    - movie file output for recording
    - video data output for live frame processing
  - Forces portrait rotation for preview and outputs.
  - Saves recordings to Photos.

- `AIBallz/Managers/PoseEstimation/PoseEstimator.swift`
  - Runs:
    - `VNDetectHumanBodyPoseRequest`
    - `VNDetectHumanHandPoseRequest` (max 2 hands)
  - Throttled to 15 FPS.
  - Maintains a sliding pose window:
    - max duration: 5 seconds
    - max frames: 90

- `AIBallz/Managers/YOLOModel/BallHoopDetector.swift`
  - Loads generated Core ML model class `best` from `best.mlpackage`.
  - Uses `VNCoreMLRequest` to detect:
    - `Basketball`
    - `Basketball Hoop`
  - Tracks objects with prediction/association logic for occlusion tolerance.
  - Maintains detection window:
    - max duration: 5 seconds
    - max frames: 90
  - Shot detection state machine:
    - `idle` -> `tracking` -> `cooldown`
    - infers make/miss from rim crossing and post-crossing center alignment.

### Auth Layer

- `AIBallz/Managers/AuthManager/AuthManager.swift`
  - Authorization Code + PKCE flow.
  - Token exchange and refresh through Auth0 `/oauth/token`.
  - Lightweight ID token payload decode for user identity fields.
- `AIBallz/Managers/AuthManager/AuthCredentialsStore.swift`
  - Stores `AuthCredentials` in iOS Keychain.
- `AIBallz/Managers/AuthManager/WebAuthenticationSessionHandler.swift`
  - Wraps `ASWebAuthenticationSession`.

### Persistence + Backend Layer

- `AIBallz/Managers/Database/ShotRecord.swift`
  - SwiftData model: `timestamp`, `isMake`, `shotIndex`, `llmFormFeedback`.
- `AIBallz/Managers/BackendAPI/FeedbackManager.swift`
  - Encodes JSON payload and posts to feedback backend.
  - Uses `FEEDBACK_API_BASE_URL` from environment (preferred) or Info.plist.

## End-to-End Runtime Flow

1. App starts -> AuthManager bootstraps session.
2. Authenticated user opens Analysis tab.
3. Camera session starts; each frame is sent to:
   - `PoseEstimator.process(sampleBuffer:)`
   - `BallHoopDetector.process(sampleBuffer:)`
4. Detector updates shot counters.
5. New shots are persisted as `ShotRecord` entries.
6. For newly created shots, app snapshots current pose + detection windows.
7. App calls backend `POST /v1/shot-feedback`.
8. Response feedback text is written back to the shot record.
9. History tab renders persisted records and aggregate charts.

## Project Structure

```text
AIBallz/
├── AIBallz.xcodeproj
├── AIBallz/
│   ├── AIBallzApp.swift
│   ├── ContentView.swift
│   ├── Info.plist
│   ├── config/
│   │   └── Dev.xcconfig
│   ├── Managers/
│   │   ├── AuthManager/
│   │   ├── BackendAPI/
│   │   ├── Camera/
│   │   ├── Database/
│   │   ├── PoseEstimation/
│   │   └── YOLOModel/
│   └── Views/
│       ├── Authentication/
│       ├── VideoAnalysis/
│       ├── ShotHistory/
│       └── Account/
├── AIBallzTests/
└── AIBallzUITests/
```

## Requirements

- macOS with Xcode (tested with current Xcode toolchain in this repo environment).
- iOS Simulator or physical iPhone/iPad.
- iOS deployment target:
  - App target: iOS 18.0
  - Test targets: iOS 18.5
- No third-party Swift package dependencies are required.

## Configuration

The app reads runtime values from `AIBallz/Info.plist` (and for feedback endpoint, optionally from process environment).

### Configuration Precedence

- `Auth0Config` reads values from `Info.plist` only.
- `FeedbackManager` reads in this order:
  1. Process environment variable `FEEDBACK_API_BASE_URL`
  2. `Info.plist` key `FEEDBACK_API_BASE_URL`

In Xcode, you can set `FEEDBACK_API_BASE_URL` per scheme via:  
`Product -> Scheme -> Edit Scheme -> Run -> Arguments -> Environment Variables`.

### Required Info.plist Keys

- `AUTH0_DOMAIN`
- `AUTH0_CLIENT_ID`
- `AUTH0_CALLBACK_SCHEME`
- `AUTH0_AUDIENCE` (optional in code path but present in current app config)
- `FEEDBACK_API_BASE_URL`

### URL Scheme

`CFBundleURLTypes` must include the same callback scheme as `AUTH0_CALLBACK_SCHEME`.

### Camera/Photo Usage Strings

These usage descriptions are set through build settings (`INFOPLIST_KEY_*`) in the Xcode project:

- `NSCameraUsageDescription`
- `NSPhotoLibraryUsageDescription`

### ATS / Local Networking

`NSAllowsLocalNetworking` is enabled in Info.plist, which helps local/LAN backend development scenarios.

### Note on `Dev.xcconfig`

`AIBallz/config/Dev.xcconfig` exists in the project, but current runtime config values are stored directly in `Info.plist`.  
If you want environment-specific app config, switch plist values to build-setting substitutions and keep secrets out of source control.

## Auth0 Setup

Create a **Native** Auth0 application and configure:

1. **Domain** -> `AUTH0_DOMAIN`
2. **Client ID** -> `AUTH0_CLIENT_ID`
3. **Allowed Callback URL**
   - `<AUTH0_CALLBACK_SCHEME>://<AUTH0_DOMAIN>/ios/<BUNDLE_ID>/callback`
4. **Allowed Logout URL**
   - `<AUTH0_CALLBACK_SCHEME>://<AUTH0_DOMAIN>/ios/<BUNDLE_ID>/logout`
5. Optional API audience -> `AUTH0_AUDIENCE`

`<BUNDLE_ID>` is your app target bundle identifier (default currently: `com.example.ASharifov.AIBallz`).

## Feedback Backend Contract

### Endpoint

- `POST {FEEDBACK_API_BASE_URL}/v1/shot-feedback`

### Headers

- `Content-Type: application/json`
- Optional: `Authorization: Bearer <access_token>`

### Request Body (shape)

```json
{
  "shot": {
    "shotIndex": 12,
    "isMake": true,
    "timestamp": "2026-02-16T23:51:00Z"
  },
  "poseWindow": [
    {
      "timestamp": 12345.678,
      "bodyJoints": {
        "leftShoulder": { "x": 0.41, "y": 0.72 }
      },
      "hands": [
        {
          "indexTip": { "x": 0.56, "y": 0.31 }
        }
      ]
    }
  ],
  "detectionWindow": [
    {
      "timestamp": 12345.678,
      "ball": {
        "confidence": 0.88,
        "bbox": { "x": 0.2, "y": 0.3, "width": 0.1, "height": 0.1 }
      },
      "hoop": {
        "confidence": 0.93,
        "bbox": { "x": 0.6, "y": 0.5, "width": 0.2, "height": 0.2 }
      }
    }
  ]
}
```

### Response Body

```json
{
  "feedback": "Keep your elbow aligned under the ball on release."
}
```

## Build and Run

### Xcode

1. Open `AIBallz.xcodeproj`.
2. Select scheme `AIBallz`.
3. Pick a simulator or connected device.
4. Run.

### CLI Build (simulator)

```bash
xcodebuild \
  -scheme AIBallz \
  -project AIBallz.xcodeproj \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

This command was validated in this repository environment.

## Testing

Run tests with:

```bash
xcodebuild \
  -scheme AIBallz \
  -project AIBallz.xcodeproj \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' \
  CODE_SIGNING_ALLOWED=NO \
  test
```

Current tests are mostly template-level smoke tests (`AIBallzTests`, `AIBallzUITests`).

## Data Storage and Security

- **Auth tokens**: stored in iOS Keychain (`AuthCredentialsStore`).
- **Shot history**: stored locally via SwiftData.
- **Networked feedback payload**: contains shot metadata + short rolling pose/detection windows.

Security notes for production hardening:

1. Do not commit production Auth0 identifiers or backend URLs in plaintext.
2. Prefer environment-specific xcconfig files and CI-injected secrets.
3. Consider stricter ATS policy if backend moves off local development.

## Known Limitations

1. Upload flow UI exists, but uploaded video analysis is not wired yet (explicit alert in `VideoAnalysisView`).
2. Shot detection is heuristic-based; difficult angles/occlusions can affect make/miss accuracy.
3. Feedback calls are one-shot per created record (no retry queue/backoff).
4. Automated coverage for detection logic and auth edge cases is currently minimal.
5. Camera pipeline is configured around portrait capture/preview assumptions.

## Troubleshooting

1. **"Auth0 configuration is missing"**
   - Verify all required Auth0 keys in `Info.plist`.
   - Confirm callback scheme matches `CFBundleURLTypes`.

2. **Feedback errors (`missing base URL` / server error)**
   - Verify `FEEDBACK_API_BASE_URL`.
   - Ensure backend is reachable from simulator/device.
   - For physical devices, do not use `127.0.0.1` unless backend runs on-device.

3. **No camera frames or permission issues**
   - Confirm camera permission has been granted in iOS Settings.
   - Validate usage description strings are present in built Info.plist.

4. **No shots appearing in history**
   - Ensure ball and hoop are both detected in the live view.
   - Check detector counters in HUD; records are created when `shots` increments.
