<div align="center">
  <img src="docs/images/icon.png" width="128" height="128" alt="Macin icon">
  <h1>Macin</h1>
  <p><strong>Understand your Mac in plain words.</strong></p>
  <p>Storage, memory, performance, apps, battery and network in one native app,<br>plus an AI assistant that checks your Mac before it answers.</p>

  <p>
    <img src="https://img.shields.io/badge/macOS-14%2B-000000?style=flat-square&logo=apple&logoColor=white" alt="macOS 14+">
    <img src="https://img.shields.io/badge/Swift-6-F05138?style=flat-square&logo=swift&logoColor=white" alt="Swift 6">
    <img src="https://img.shields.io/badge/SwiftUI-native-0A84FF?style=flat-square" alt="SwiftUI">
    <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green?style=flat-square" alt="MIT License"></a>
    <a href="https://github.com/nsourov/macin/actions/workflows/test.yml"><img src="https://img.shields.io/github/actions/workflow/status/nsourov/macin/test.yml?style=flat-square&label=tests" alt="Tests"></a>
  </p>

  <p>
    <a href="#install">Install</a> ·
    <a href="#features">Features</a> ·
    <a href="#ask-your-mac">Ask Your Mac</a> ·
    <a href="#privacy">Privacy</a> ·
    <a href="#faq">FAQ</a> ·
    <a href="#contributing">Contributing</a>
  </p>
</div>

---

## Why Macin?

Most Mac tools show you numbers. Macin tells you what they mean.

- **Plain words**: "Memory is fine, using a lot is normal on a Mac" instead of a wall of charts.
- **Safe by design**: nothing is deleted without your confirmation, and cleaned items go to the Trash.
- **Private**: no account, no tracking, no server. Everything runs on your Mac.
- **Light**: a native SwiftUI app that uses very little memory and energy.

## Install

> [!NOTE]
> Ready-made downloads are coming soon. For now, build it from source. It takes about a minute.

```sh
git clone https://github.com/nsourov/macin.git
cd macin
./scripts/build-app.sh
open build/Macin.app
```

Move `build/Macin.app` to your Applications folder if you want to keep it.

**Requirements**

- macOS 14 Sonoma or later
- Xcode 16 or later (or the Swift 6 command line tools)
- For Apple's on-device AI: macOS 26 or later with Apple Intelligence turned on

## Features

### 🏠 Home
Disk space and the health of your Mac at a glance.

### 💾 Storage
- Finds space that is safe to clean: caches, logs, developer files and the Trash
- Shows what changed since the last scan
- Every item is reviewed by you, then moved to the Trash

### 🧠 Memory
- Memory pressure as macOS reports it, swap and compressed memory
- The apps using the most memory, grouped by app

### ⚡ Performance
- Processor load and heat level
- Apps that keep the processor busy over time

### 📦 Applications
- Installed apps with their size and the data they keep
- Live memory, processor and energy use for running apps
- Safe uninstall that also finds leftover files

### 🔋 Battery
- Charge, condition and drain over time
- Energy use by app

### 🌐 Network
- Connection and Wi-Fi signal
- Step-by-step internet check that shows where a problem is

### 📊 Menu bar
A small live panel with memory, processor, disk, battery and the busiest apps.

## Ask Your Mac

Ask questions like *"Why is my Mac slow?"*, *"What is using my battery?"* or *"How big is my Downloads folder?"*.

The assistant doesn't guess. It works in a loop:

1. The AI picks the checks it needs from a fixed list of read-only tools.
2. Macin runs them, using commands like `sw_vers`, `pmset`, `top`, `df` and `du`, and macOS APIs.
3. The AI writes the answer from the real results.
4. Macin checks the answer. Numbers and names that didn't come from the checks are rejected.

You can see every check and command it ran under each answer.

**Safety:** the AI can never run its own commands, change settings or delete anything.

**Choose your model** in AI Settings:

| Model | Where it runs |
|---|---|
| Apple on-device model | Inside macOS. Nothing leaves your Mac. |
| Your own model | Any OpenAI-compatible server, like [Ollama](https://ollama.com) or [LM Studio](https://lmstudio.ai) |

Macin never downloads a model.

## Privacy

- All measurements stay on your Mac. History is stored in `~/Library/Application Support/MacFootprint/`.
- Network checks contact public test addresses (Apple, Cloudflare, Google, or ones you add) only after you agree. Automatic checks are off unless you turn them on.
- If you connect your own AI server, your question and the check results are sent to that server. API keys are stored in your Keychain.

## FAQ

<details>
<summary><strong>Why does free space differ from other apps?</strong></summary>

Macin shows the same number as Finder. It includes "purgeable" space that macOS can free by itself when needed. Tools like `df` show only space that is completely empty right now, so their number is a bit smaller.
</details>

<details>
<summary><strong>Why can't I see some system processes?</strong></summary>

macOS doesn't let normal apps read processes owned by the system or other users. Macin uses only public APIs and doesn't install a privileged helper, so those processes are hidden.
</details>

<details>
<summary><strong>Is it safe to clean what Macin suggests?</strong></summary>

Macin only suggests items from known categories like caches, logs and developer files, and it explains each one. You review everything, and items go to the Trash, so you can restore them.
</details>

<details>
<summary><strong>Does Ask Your Mac work without Apple Intelligence?</strong></summary>

Yes, if you connect your own model (for example Ollama running on your Mac). Without any AI model, the rest of Macin works as normal.
</details>

## Build from source

```sh
./scripts/build-app.sh          # release build in build/Macin.app
./scripts/build-app.sh debug    # debug build
swift test                      # run the tests
```

The build script signs the app with your Apple Development or Developer ID certificate if you have one, otherwise it signs it locally. To pick a certificate:

```sh
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/build-app.sh
```

<details>
<summary><strong>Project layout</strong></summary>

```
Sources/FootprintCore      Core logic: scanning, cleanup rules, memory, battery, network, assistant checks
Sources/MacFootprint       The SwiftUI app
Tests/FootprintCoreTests   Unit tests
scripts/                   Build script and icon generator
docs/decisions/            Design notes
```
</details>

## Contributing

Bug reports, ideas and pull requests are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) first. For security problems, see [SECURITY.md](SECURITY.md).

## License

Macin is released under the [MIT License](LICENSE).
