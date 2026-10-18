# Contributing to Macin

Thanks for helping. Bug reports, ideas and pull requests are welcome.

## Getting started

```sh
./scripts/build-app.sh debug
open build/Macin.app
swift test
```

## Guidelines

- Keep changes small and focused. One pull request per fix or feature.
- Run `swift test` before opening a pull request, and add tests for logic in `FootprintCore`.
- Match the style of the code around your change.
- Write user-facing text in short, simple English.
- Use public macOS APIs only. No private frameworks.
- Safety first: anything that deletes files must go through the existing cleanup flow (move to Trash, with user confirmation). Never delete without asking.
- The AI assistant must only use the fixed read-only tools in `AgentToolbox`. Never let a model run its own commands.
- Don't add tracking, analytics or network calls that the user didn't ask for.

## Reporting bugs

Open an issue with:

- macOS version and Mac model (Apple silicon or Intel).
- What you did, what you expected and what happened.
- Screenshots if they help.

## Security issues

Please don't open a public issue. See [SECURITY.md](SECURITY.md).
