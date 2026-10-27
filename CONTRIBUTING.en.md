# Contributing to Araso

[한국어](CONTRIBUTING.md)

Bug reports, words Araso reads in the wrong language, and code are all welcome. One maintainer
reviews everything, so answers can take a while.

## Before you start

**Every PR starts from an issue.** A PR without one isn't reviewed until it has one.

1. Open an [issue](https://github.com/nyttastudio/araso/issues/new/choose) first: the bug form for
   a bug, the suggestion form for a feature or an improvement.
2. Start working once the maintainer has answered on the direction and labeled the issue
   `accepted`: bugs, features and doc fixes alike. Changing course after a large PR is costly for both sides.
3. Link the issue in the PR description with `Closes #<number>`. A bot comments on a PR that isn't
   linked to an `accepted` issue, and edits that comment once it is.

Labels come in three kinds ([.github/labels.yml](.github/labels.yml)): one **kind** (`bug`,
`enhancement`, `docs`, `ci`), a **status** on issues (`accepted`, `needs-info`, `duplicate`,
`wontfix`), and any number of **areas** (`area: korean`, `area: decision`, `platform: windows`, `platform: linux`…). An
issue gets its kind from its form and an area from the form's dropdown; a bot gives a PR the kind and
area labels of the issue it links and labels for the files it changes, so you don't label it yourself.

Questions, install problems and security issues don't go in issues:

- **Questions and install problems** go to
  [Discussions](https://github.com/nyttastudio/araso/discussions).
- **Security issues** (a path by which typed text could leak, for example): report them
  [privately](https://github.com/nyttastudio/araso/security/advisories/new), not in a public issue.

Forks and ports to other platforms are welcome, but please don't distribute them under the name
Araso, so they aren't mistaken for the official versions.

## Setup

- macOS with **Xcode 26 or later** (Swift 6.2 or later). Xcode 16 (Swift 6.1) can't build it. CI runs
  on `macos-latest`.
- The accuracy tools need only `python3` (no packages).
- For Windows, see [docs/windows-port.md](docs/windows-port.md). Windows-only code can't run on a Mac;
  the PR's Windows CI builds and tests it. To check that the C++ compiles, use
  `windows/scripts/check-cross.sh` (zig).
- For Linux, see [docs/linux-port.md](docs/linux-port.md). With Docker, also on a Mac,
  `linux/scripts/typing-test/run.sh` builds, tests and types for real on a clean Ubuntu; the PR's
  Linux CI runs the same.

The words the code uses (Lingering Shift, Word, Reading…) are in [GLOSSARY.md](GLOSSARY.md). The
fullest account of the structure and its pitfalls is [AGENTS.md](AGENTS.md), written for AI agents
but readable by people.

## Build and test

```sh
swift build
swift test                                   # everything (Swift Testing, a few seconds)
swift test --filter MixedWordTests           # one suite
swift run araso-cli -v "dkssud hello"        # English/Korean decision with scores
```

All typing logic is in `Sources/ArasoCore`, and that's what most tests cover; `InputSession` is
tested through `FakeTextField`. A change to `InputSession` reaches Windows and Linux too, so also run
`swift test --filter ServiceTests`.

## Trying it in real typing

Tests aren't enough: a split once looked right in the CLI and never reached real typing.

```sh
scripts/install.sh                           # release build, self-test, install into ~/Library/Input Methods
/usr/bin/log show --last 10m --predicate 'subsystem == "com.nyttastudio.inputmethod.Araso"' --info --debug
```

- A change reaches real typing only after `scripts/install.sh`. A copy started with `open` or from
  `build/` never gets input method connections.
- **Signing:** with an Apple Development certificate in the keychain (Xcode makes one for a free
  Apple account too), Araso starts again by itself after a reinstall. Signed ad hoc, without one,
  it has to be removed (−) and added again (+) in **System Settings → Keyboard → Input Sources →
  Edit…** after every reinstall.
- Don't mix it with a copy installed from the official pkg (`/Library/Input Methods`): uninstall
  that one before using `install.sh`.
- Use `/usr/bin/log`, not `log`: zsh's builtin `log` shadows it and prints nothing.
- `scripts/typing-test/run.sh` takes over the keyboard and pointer for about a minute; don't use the
  Mac meanwhile.

## Changing a decision rule

When you change how a word is read as English, Korean or Japanese, or how a word splits, check that
**no other words now split or read wrongly**, not only that the case you fixed works.

```sh
tools/prepare.sh                             # downloads the evaluation data into tools/data once (gitignored)
```

- Type every row of `tools/data/eval.tsv` (English, Korean, Japanese) through an `InputSession` with
  Japanese on, and count Hangul next to kana.
- For English, also run `tools/data/en_50k.txt` through `araso-cli -v`.
- For English + particle use `tools/eval_particles.py`; for URLs and paths, `tools/eval_urls.py`.
- For a remembered word + particle, run `DictionarySplitCheckTests`; from a worktree it needs
  `ARASO_TOOLS_DATA=<main checkout>/tools/data`.
- Fix a wrong split with the scores (`Weights`) or the word lists, not with a rule for that case.

Put the numbers from before and after (accuracy, wrong splits) in the PR description.

## Rules

- **Never log typed text.** Log the key kind and the app only.
- If you change something users see, update **README.md and README.en.md together**.
- UI strings go through `L("English key")`, with Korean in
  `Resources/ko.lproj/Localizable.strings`.
- A new data file under `Sources/ArasoCore/Data` has to be added to `scripts/build-app.sh` too, or
  the app won't have it.
- There is no built-in list of apps in `apps.json`; don't add defaults for a particular app.

## Commits and PRs

- One change per PR.
- A commit message says in one sentence what now works and how (see `git log`). English is
  preferred, Korean is fine. PR titles and descriptions can be in either language.
- main takes linear history only (squash or rebase merges). To bring a branch up to date, rebase it
  on main rather than merging main in.
- On your first PR, CI runs once the maintainer approves it.
- CI (`test`) has to pass to merge. If you touched `InputSession` or `ArasoService`, check the
  Windows and Linux CI too.
- AI tools are fine. Have them read [AGENTS.md](AGENTS.md) (Claude Code reads it through
  CLAUDE.md). In the PR, write what you ran and checked yourself.

## License

Contributions are released under the project's [MIT License](LICENSE).
