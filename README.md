# Macin

Macin is a native macOS app that explains what is happening on your Mac in plain words: disk space, memory, processor and heat, apps, battery and network. It can also answer questions about your Mac with an AI assistant that checks real data before it answers.

Everything runs on your Mac. Macin has no account, no tracking and no server.

## Features

- **Home**: disk space and the state of your Mac at a glance.
- **Storage**: finds space that is safe to clean (caches, logs, developer files, Trash) and shows scan history. Nothing is deleted without your confirmation, and items go to the Trash.
- **Memory**: memory pressure, swap and the apps using the most memory.
- **Performance**: processor load, heat level and apps that stay busy.
- **Applications**: installed apps, their size and the data they keep, with a safe uninstall.
- **Battery**: charge, condition, drain over time and energy use by app.
- **Network**: connection, Wi-Fi signal and a step-by-step internet check.
- **Ask Your Mac**: an AI assistant that runs read-only checks on your Mac (like `sw_vers`, `pmset`, `df`, `du`) and answers only from the results.
- **Menu bar panel**: a small live summary.

## Requirements

- macOS 14 Sonoma or later.
- Swift 6 toolchain (Xcode 16 or later, or the Swift command line tools).
- For Apple's on-device AI model: macOS 26 or later with Apple Intelligence turned on. Without it, you can connect your own model (see below).

## Build and run

```sh
git clone https://github.com/nsourov/macin.git
cd macin
./scripts/build-app.sh
open build/Macin.app
```

`build-app.sh` builds a release version, creates the app icon and signs the app. If you have an Apple Development or Developer ID certificate it uses it. Otherwise the app is signed locally ("ad hoc"), which is fine for running it on your own Mac.

To use a specific certificate:

```sh
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/build-app.sh
```

For a debug build:

```sh
./scripts/build-app.sh debug
```

## Tests

```sh
swift test
```

## Ask Your Mac

The assistant picks from a fixed list of read-only tools. Macin runs the tool, gives the result to the AI model, and the model writes the answer. Macin then checks the answer: numbers and macOS names must come from the tool results, otherwise the answer is not shown.

The AI can never run its own commands, change settings or delete anything.

Model options (AI Settings in the app):

- **Apple on-device model**: runs inside macOS. Nothing leaves your Mac.
- **Your own model**: any OpenAI-compatible server, for example [Ollama](https://ollama.com) (`http://localhost:11434/v1`) or [LM Studio](https://lmstudio.ai) (`http://localhost:1234/v1`). If you use a remote server, your question and the tool results are sent to it. An API key, if you add one, is stored in your Keychain.

Macin never downloads a model.

## Privacy

- Macin reads disk usage, process, battery and network information from macOS. This data stays on your Mac.
- History is stored in `~/Library/Application Support/MacFootprint/`.
- Network checks contact public test addresses (Apple, Cloudflare, Google, or ones you add) only after you agree. Automatic checks are off unless you turn them on.
- The only other data that can leave your Mac is what you send to your own AI server, if you set one up.

## Project layout

```
Sources/FootprintCore   Core logic: scanning, detectors, memory, battery, network, assistant checks
Sources/MacFootprint    The SwiftUI app
Tests/FootprintCoreTests
scripts/                Build script and icon generator
docs/decisions/         Design notes
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE)
