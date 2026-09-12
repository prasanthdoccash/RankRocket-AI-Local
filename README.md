<div align="center">

  <h1>RankRocket AI</h1>

  <p><strong>Private, local AI for Android and iOS.<br/>Powerful inference without sending conversations to the cloud.</strong></p>


  [Overview](#overview) · [Download](#download) · [Features](#features) · [Quick Start](#quick-start) · [Local API](#local-api-server) · [Roadmap](#roadmap)

</div>

---

## Overview

**RankRocket AI** is a commercial, mobile-first application that runs supported open-source AI models directly on your **Android or iOS device**. Inference and conversations stay on the device, while licensing, updates, and optional purchases are managed through the RankRocket service.

RankRocket AI is distributed as a commercial product. Availability, model access, licensing terms, and subscription options may vary by release and platform.

> A private AI workspace that runs **on your phone**, with device-aware performance controls.

RankRocket AI is currently distributed for supported Android and iOS devices. Additional platforms may be offered in future commercial releases.

**Watch the RankRocket AI setup and demo:** [https://youtu.be/2Pnv68iHIaQ](https://youtu.be/2Pnv68iHIaQ)

[![RankRocket AI Demo](https://img.youtube.com/vi/2Pnv68iHIaQ/maxresdefault.jpg)](https://youtu.be/2Pnv68iHIaQ)

---

## Download

### Android APK — Latest Release

| APK | Architecture | Best For | Size |
|-----|-------------|----------|------|
| **RankRocket AI.apk** | Android APK | Current supported Android devices | See the latest private release |

> Downloads are provided to licensed customers through the official RankRocket distribution channel. Do not redistribute commercial builds.

> **Not sure which to pick?** Download `arm64-v8a` — it works on virtually all modern Android phones.

### iOS

iOS builds and installation instructions are provided through the official RankRocket distribution channel for licensed customers.

---

## Features

| Feature | Description |
|---------|-------------|
| **On-device inference** | Run supported GGUF language models locally on compatible devices |
| **Privacy-first chat** | Conversations and chat history are stored locally; inference does not require a cloud AI API |
| **Offline operation** | Continue using downloaded models without an active internet connection |
| **Model library** | Browse, download, import, manage, load, unload, and delete supported models |
| **Performance modes** | Battery Saver, Balanced, Performance, and Full Power profiles |
| **Device-aware tuning** | RAM, CPU, GPU backend, model compatibility, and Android thermal status guidance |
| **Chat history** | Persistent local conversations with search and management controls |
| **Live inference metrics** | Loading progress, generation status, and tokens-per-second feedback |
| **Local OpenAI API** | Optional localhost REST API with OpenAI-compatible model and chat-completion endpoints |
| **Commercial licensing** | Device-bound trials, license expiry tracking, release/version status, and account management |
| **Google Play billing** | Monthly and annual subscription product support with server-side purchase verification |
| **Multi-platform foundation** | Flutter foundation for Android, iOS, Windows, macOS, and Linux builds |

---

## Quick Start

### Android

1. Download the current APK from the official RankRocket distribution channel
2. On your phone: **Settings → Install unknown apps** → allow your browser
3. Tap the downloaded APK to install
4. Open the app, go to **Models** tab, download a model, and start chatting

### iOS

iOS availability and installation instructions are provided directly to licensed customers through the official RankRocket distribution channel.

### Other platforms

The application is built on a multi-platform foundation. Commercial availability is currently focused on supported Android and iOS releases.

---

## Model and device guidance

RankRocket AI recommends selecting a model that matches the device’s available RAM, CPU/GPU support, and thermal headroom. The model library includes lightweight options such as Qwen 2.5 1.5B/3B and SmolLM2 1.7B, alongside larger supported models for capable devices.

The app classifies models as **Recommended**, **Compatible**, **Heavy**, or **Not recommended** and can show device-specific performance guidance before loading. Models are downloaded or imported through the **Models** tab.

---

## Local API Server

**RankRocket AI** includes a built-in **OpenAI-compatible REST API** so authorized local tools can connect to the running model.

### Setup

1. Load a model in the app
2. Go to **Settings → Local API Server** and toggle it **ON**
3. Use `http://127.0.0.1:4891/v1` as your base URL

### Endpoints

```bash
# List loaded models
curl http://127.0.0.1:4891/v1/models

# Chat completion (non-streaming)
curl http://127.0.0.1:4891/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"local","messages":[{"role":"user","content":"Tell me something true that no one wants to hear."}]}'

# Chat completion (streaming)
curl -N http://127.0.0.1:4891/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"local","stream":true,"messages":[{"role":"user","content":"Write a brutally honest analysis of social media."}]}'
```

> **API Key:** Use `local` for any client that requires a non-empty key value.

---

## Roadmap

| Feature | Status |
|---------|--------|
| On-device local AI chat | **Available** |
| Model loading, progress, cancel, and unload | **Available** |
| Persistent local chat history | **Available** |
| Model library and custom model import | **Available** |
| Device-aware performance profiles | **Available** |
| Local OpenAI-compatible API server | **Available** |
| Commercial device licensing | **Available** |
| Google Play subscription support | **Available** |
| AI Agent Mode | Planned |
| Web search integration | Planned |
| Voice interaction | Planned |
| Image/vision model support | Planned |

---

## Support

RankRocket AI is a commercial product. For licensing, installation, account, billing, or model-compatibility support, contact the RankRocket team through the official customer support channel.

The core application source, build instructions, and internal deployment details are not included in this commercial product README.

---

## License

RankRocket AI is commercial software. Use, redistribution, reverse engineering, and commercial exploitation are subject to the applicable RankRocket AI license and terms of service. This repository is private and does not grant rights to access or redistribute the core application.

---

<div align="center">
  <sub>Built with ❤️ using Flutter · Powered by <a href="https://github.com/ggerganov/llama.cpp">llama.cpp</a></sub>
</div>
