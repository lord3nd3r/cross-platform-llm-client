# PrivateLM

[![Live Web App](https://img.shields.io/badge/Live_Demo-Try_Web_App-02569B?style=for-the-badge&logo=flutter&logoColor=white)](https://ai-chat-orailnoor.web.app/)

A production-ready, cross-platform AI chat client built with Flutter. It unifies local on-device LLM inference (Android) with cloud API access, giving users full control over how their models run.

![Image generation tested on Moto G71 (Snapdragon), Oneplus 10r (Mediatek), Pixel 6A (Tensor), Poco F1 (Snapdragon), Samsung s23 (Snapdragon) 4 steps fast](PrivateLM.png)
_Image generation tested on Moto G71 (Snapdragon), Oneplus 10r (Mediatek), Pixel 6A (Tensor), Poco F1 (Snapdragon), Samsung s23 (Snapdragon) 4 steps fast_

![Generated on pixel 6 with 20 step](IMG_2390.png)
_Generated on pixel 6 with 20 step_

---

## What It Does

- **Local text on Android and iOS** — GGUF models through llama.cpp (Vulkan on Android, Metal on iOS) and, on Android, LiteRT-LM (`.litertlm`). Web and macOS do not run local text models.
- **Local images on Android** — `.safetensors` image models through the bundled stable-diffusion plugin. Web has an experimental WebGPU path that is not part of the main navigation.
- **Cloud APIs** — OpenAI, Anthropic, Gemini, Kimi, Stability, NVIDIA, OpenRouter, DeepSeek, and a custom OpenAI-compatible base URL. The default provider is OpenRouter.
- **Chats stay on device** — Sessions live in Hive. API keys are kept in the platform keystore (Android) or keychain (iOS), not in Hive. Android backup of app data is disabled. On web, the browser store is not hardware-backed.
- **Local OpenAI server** — Android/iOS can serve the loaded model on loopback. Network mode requires an API key.
- **Phone cluster** — An Android phone can spread a GGUF model across paired phones. Workers listen on the LAN only through a pairing gate; llama.cpp RPC itself stays on `127.0.0.1`. A computer running llama.cpp `rpc-server` can be added by address. That upstream server has no pairing secret, so only add a machine you started, on a network you trust.
- **Android updates** — The app checks GitHub releases for `lord3nd3r/cross-platform-llm-client`. Those APKs must be signed with the same key as the installed build.
- **Crash reports are off** until you turn them on in Settings. They are not sent when Firebase config is absent.
- **Device automation is not a feature.** The old task planner that asked a model for ADB commands is removed. The app does not run shell commands.

---

## Technical Architecture

### Stack

- **Framework:** Flutter 3.x (Dart >=3.3.0)
- **State Management:** GetX
- **Local Storage:** Hive
- **Networking:** Dio + `package:http`
- **Background Execution:** `flutter_background_service` + `flutter_local_notifications`
- **Push Notifications:** Firebase Core + Firebase Messaging

### Inference Pipeline

```
┌─────────────────────────────────────────────────────────────┐
│                        UI Layer                              │
│   ChatView / ModelView / ServerView / SettingsView          │
└──────────────────────────┬──────────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────────┐
│                    Controllers (GetX)                        │
│   ChatController · ModelController · SettingsController     │
│   SettingsController · HomeController                       │
└──────────────────────────┬──────────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────────┐
│                      Services                                │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────┐ │
│  │ InferenceService│  │  CloudService   │  │DownloadSvc  │ │
│  │  (local GGUF)   │  │ (OpenAI/Claude/ │  │ (model dl)  │ │
│  │                 │  │  Gemini/Kimi)   │  │             │ │
│  └─────────────────┘  └─────────────────┘  └─────────────┘ │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────┐ │
│  │  HiveService    │  │ DeviceInfoSvc   │  │ExecutionSvc │ │
│  │  ( persistence) │  │  (RAM/GPU tier) │  │ (bg tasks)  │ │
│  └─────────────────┘  └─────────────────┘  └─────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

### Local Inference (Android)

The app uses `llama_flutter_android`, a custom Flutter plugin wrapping `llama.cpp` for ARM64 devices. At runtime it:

1. **Detects GPU capabilities** via Vulkan to determine offload layers.
2. **Selects thread count** based on device tier (ultra / high / mid / low).
3. **Loads the GGUF model** with progress streaming.
4. **Generates tokens** via `generateChat()` with native chat-template support (ChatML, Llama-3, Gemma, Phi).
5. **Falls back** to manual prompt construction if native templates fail.

Idle detection (5s) and hard timeouts (180s) keep the UX responsive even on underpowered hardware.

### Cloud Inference

`CloudService` normalizes four different API shapes into a single interface:

- **OpenAI** — standard `/v1/chat/completions`
- **Anthropic** — Messages API with separate system param
- **Google Gemini** — `generateContent` with inline image base64
- **Kimi** — OpenAI-compatible endpoint from Moonshot AI

API keys are stored in Hive and never transmitted anywhere except to the provider's endpoint.

### Cross-Platform Abstraction

Local inference is conditionally compiled:

- **Android** → `inference_android.dart` (full llama.cpp engine)
- **Web** → `inference_stub.dart` (cloud-only, local coming soon)
- **iOS** → `inference_android.dart` (full llama.cpp engine via Metal GPU)

The `InferenceService` exposes `supportsLocalInference` so the UI can hide local-model UI on unsupported platforms.

---

## Supported Platforms

| Platform | Local text | Local images | Cloud APIs | Cluster master | Notes |
| -------- | ---------- | ------------ | ---------- | -------------- | ----- |
| Android  | Yes        | Yes          | Yes        | Yes            | minSdk 28. Phone workers and explicit `rpc-server` computers. |
| iOS      | Yes        | No           | Yes        | No             | Can be a paired worker. Metal for GGUF. Sideload IPA. |
| Web      | No         | Experimental WebGPU only | Yes | No | No local GGUF/LiteRT. API keys are browser storage. |
| macOS project | No   | No           | Builds as a Flutter shell | No | Not a supported local-inference target. |

### iOS / iPad (Installation via AltServer)
The iOS/iPad release is distributed as a sideloadable IPA file. Due to the RAM requirements for local models, iPad is the recommended iOS target, but it can be installed on iPhones.

Here is how you can install the app using AltStore and AltServer:

**Prerequisites:**
* Ensure **AltServer** is installed and running on your Mac or Windows PC.
* Your iOS device must be connected to the same Wi-Fi network as your computer, or connected directly via a USB cable.
* You must have **AltStore** successfully installed on your iOS device.

**Installation Steps:**
1. **Download the IPA:** Go to the [Releases](https://github.com/orailnoor/cross-platform-llm-client/releases) page on your iOS device (using Safari) and download the latest `PrivateLM-iOS.zip` package, extract it to get the `.ipa` file.
2. **Open in AltStore:**
   * Locate the extracted `.ipa` file in your device's "Files" app.
   * Tap the **Share** button and select **AltStore** from the list of apps.
   * *Alternatively*, you can open the AltStore app, go to the **My Apps** tab, tap the **"+" (plus)** icon in the top-left corner, and select the downloaded IPA file.
3. **Install:** AltStore will begin installing the app. You may be prompted to enter your Apple ID credentials if this is your first time.
4. **Enable Developer Mode:** On iOS 16 and later, ensure "Developer Mode" is enabled in your device's Settings (`Settings > Privacy & Security > Developer Mode`) to launch the sideloaded app.
5. **Launch:** Once installation is finished, PrivateLM will appear in the **My Apps** tab in AltStore and on your device's home screen!

*Note: Sideloaded apps via AltStore expire after 7 days, but AltStore will attempt to automatically refresh them in the background when connected to the same Wi-Fi as your computer running AltServer.*

---

## Build Configuration

### Prerequisites

- Flutter SDK >=3.3.0 (this tree was last migrated with stable `66dd93f9`)
- Android SDK, JDK 17, and the NDK for Android builds
- `minSdk` is 28
- The stable-diffusion sources are a git submodule. Clone them before an Android image build:

```bash
git submodule update --init
flutter pub get
```

### Android

```bash
flutter pub get
flutter build apk --debug
```

Release APKs require a stable signing key. Copy
`android/key.properties.example` to `android/key.properties`, fill in the
keystore values, and keep both the key and its backup. Android accepts an APK
upgrade only when it is signed with the same key as the installed APK.

```bash
cp android/key.properties.example android/key.properties
flutter build apk --release --split-per-abi
```

Never rotate the signing key between GitHub releases. The per-ABI APKs must
also keep increasing the build number in `pubspec.yaml`.

### iOS

```bash
flutter pub get
cd ios
pod install
flutter build ios
```

### Web

```bash
flutter pub get
flutter build web --release
```

---

Release APKs are signed with `android/key.properties` (see `android/key.properties.example`). Do not publish a debug-signed APK. Do not rotate that key between updates. This repo does not contain a keystore or Firebase `google-services.json`. Add those locally if you ship Crashlytics or Play/GitHub release builds.

A Windows or desktop `rpc-server` is not authenticated by llama.cpp. PrivateLM will connect only to the address you type. It does not scan for open RPC ports. Keep that process off untrusted networks.

## License

MIT — see [LICENSE](./LICENSE) for details.
