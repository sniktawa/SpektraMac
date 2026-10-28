# Contributing to SpektraMac

Thanks for helping. SpektraMac has one maintainer, [@nainajnahO](https://github.com/nainajnahO), so most of this is
about making a change easy to review. Everyone taking part follows the [code of conduct](CODE_OF_CONDUCT.md).

## Before you start

- **A bug, something you'd like, or an accessibility barrier?**
  [Open an issue](https://github.com/nainajnahO/SpektraMac/issues/new/choose) and pick its form, which asks for what's
  needed.
- **A security problem?** Don't open an issue: report it privately, as [SECURITY.md](SECURITY.md) says.
- **Small fixes**, such as a crash, a typo or a wrong label, can go straight to a pull request.
- **Anything bigger**, such as a new control, a change to the simulation or a reworked view, starts with an issue, so
  we can agree on it before you spend time on it. To take on an open issue, say so in it.

## Native first

SpektraMac is meant to be a Mac app through and through: built on what Apple's frameworks already do, and looking and
behaving like the apps Apple makes. This is often called platform-native development, and it applies to the engine and
the interface alike.

- **Reach for the framework before writing your own.** When Apple's frameworks have a ready-made way to do a step, use
  it, for image processing, decoding and analysis as much as for layout and controls. Code written by hand to do the
  same job is usually weaker by design: Apple's version is tuned for the Mac's GPU and hardware, tested across far more
  uses than this app's, and improved with each macOS at no cost here. Write your own only when no framework does the
  job, and say why in a comment.
- **Port the model, not the code.** The engine follows Spektrafilm's physics, not its Python line by line (an
  idiomatic port rather than a literal one). A framework that does a step a little differently is still the better
  choice when the difference is measured and stays small, and when it's faster or more accurate in its own right.
  Matching the original exactly isn't the goal in itself. [docs/porting.md](docs/porting.md) shows each place the
  engine does this, measured.
- **Look and behave like a Mac app.** Follow Apple's
  [Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/), and use the system's
  own controls, materials, windows, menus and shortcuts, so the app looks current on each macOS without work of its
  own. When in doubt, do it the way Apple's own apps do. A custom control is for when the system has none, and should
  then look and work like a system one, accessibility included.

## Build and test

Build and run the app as in the README's [Build from source](README.md#build-from-source): macOS 26.5 or newer,
Xcode 27, and your own signing team or **Sign to Run Locally**.

Run the engine's tests with:

```sh
swift test -c release -Xswiftc -enable-testing --package-path Engine
```

Optimized, they take about a minute on an M1 Pro instead of six; `-enable-testing` keeps the `@testable import` they
rely on. The app has no tests of its own, so a pull request says what you tried in it.

### Runtime checks

The tests check what the engine computes, not how it reaches memory: a read past the end of a value, a data race
between threads or a shader reading outside a buffer can work on one Mac and fail on another. Before a release, and
after changing a kernel's arguments (what a `setBytes` passes, or a struct a kernel reads), run the tests under
Xcode's three runtime checks. Each should pass with no reports:

```sh
# Metal API and shader validation: about a minute
MTL_SHADER_VALIDATION=1 MTL_DEBUG_LAYER=1 swift test -c release -Xswiftc -enable-testing --package-path Engine
# Address Sanitizer: about 20 minutes
swift test --sanitize=address -Xswiftc -enable-testing --package-path Engine
# Thread Sanitizer: about 20 minutes
swift test --sanitize=thread -Xswiftc -enable-testing --package-path Engine
```

The sanitizers build unoptimized, hence the time. Under validation, Core Image prints `Error creating PSO for the uber
shader: ci_ubershader_r4` about 140 times: that's Core Image's own shader, not the engine's, and expected. These cover
the engine only; the app's own code has no tests to run them on.

### Reference data

The parity tests compare every stage against dumps from the original Python Spektrafilm, at commit `3bb2c2d`, in
`golden/<case>/`: one float32 `.npy` per pipeline tap, the film's spectral lookup table and the parameters used.
The dumps (about 550 MB) aren't in the repository; make them with that Spektrafilm, installed as the README's
[Faithful to Spektrafilm](README.md#faithful-to-spektrafilm) says:

```sh
~/.local/share/uv/tools/spektrafilm/bin/python tools/golden.py
```

Without `golden/`, those tests are skipped. `golden/manifest.json` (committed) names the commit and holds a checksum of
every file, so `git diff` shows whether a regeneration changed anything. `tools/export_tables.py` exported the engine's
bundled data in `Engine/Sources/SpektraEngine/Resources/` the same way. The top of each script says what it writes.

So unless you've made `golden/`, the parity tests won't run for you. Say so in the pull request, and the maintainer
runs them.

To see how far SpektraMac is from another Spektrafilm commit, a branch such as `dev` or a newer `main`, run
`tools/check-upstream.sh <ref>`. It needs [uv](https://docs.astral.sh/uv/) and leaves your own install alone: it makes
the bundled data and the reference data from that commit in a temporary folder, diffs the data against
`Resources/` (`parameters.json` lists every parameter and its default), runs the tests against that reference data
and prints the largest difference per stage.

Every Monday, a workflow ([`upstream.yml`](.github/workflows/upstream.yml), `tools/upstream-moved.sh`) checks whether
Spektrafilm's `main` has moved past that commit, and if it has, opens or updates one issue, "Upstream Spektrafilm has
moved", listing the new commits and flagging those that touch the profiles, the parameter schema or the model.

## Changing the simulation

The engine ports Spektrafilm at commit `3bb2c2d` stage by stage, and the parity tests hold it to that. A change to a
ported stage should still match, or differ only by what the tests measure and allow (see [Native first](#native-first)):
say by how much in the pull request. If it changes a step's speed or result, regenerate
[docs/porting.md](docs/porting.md)'s table and images with `tools/port_report.py`, and say why in its text if the step
now works differently. Anything meant to render differently from Spektrafilm starts with an issue.

Before a pull request that touches the engine's speed or memory, run `tools/benchmark.sh` on an idle Mac (about five
minutes). It times the README's renders and the saves of a 50 and a 100 MP photo, with and without a diffusion filter,
and fails, naming the row, when a time is more than 15 % slower or a peak more than 10 % higher than
`tools/benchmark-baseline.tsv`. Put its table in the pull request. The committed baseline is the maintainer's MacBook
Pro (M1 Pro, 16 GB): on another Mac, record your own on `main` first with `tools/benchmark.sh --update`, and don't
commit it. A change that makes renders faster or leaner on purpose records the new baseline in the same pull request.

## Code

- Keep a change to what its issue asks: no abstractions, files or options for later.
- No dead code: no commented-out code, unused imports or unreachable branches.
- The app and the engine build in Swift 6 language mode. Keep them free of warnings.
- Comments say why, and match the code around them.

## Pull requests

- One issue per branch, cut from the latest `main`.
- Fill in the description's template: the issue it closes, what changed and why, the tests you ran, and what's not
  yet tried on the Mac.
- Pull requests are squash-merged, so the title becomes the commit on `main`.

## Licence

SpektraMac is a derivative of Spektrafilm and is licensed under the GNU GPL v3 (see [LICENSE](LICENSE)). Under
GitHub's [terms of service](https://docs.github.com/en/site-policy/github-terms/github-terms-of-service#6-contributions-under-repository-license),
what you contribute is licensed the same way. The film and paper profile data come from Spektrafilm under CC BY-SA
4.0. Credit anything you bring in from elsewhere.
