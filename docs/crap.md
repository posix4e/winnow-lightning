# Method complexity and coverage

`scripts/check-crap` inventories every first-party function and initializer
body under `Sources`, including conditional build variants. The gate is 12:

```
CRAP = CC² × (1 − executable-line coverage)³ + CC
```

SwiftLint 0.65.1 supplies the syntax decision count, including switch cases.
Its counter starts at zero, so CC includes one additional entry path. The
compiler supplies declaration ranges and LLVM supplies executable lines;
covered lines are unioned across package, Research app and normal app tests.
Named nested functions are measured separately and their lines do not inflate
the enclosing method. Accessors and standalone closures are outside the
SwiftLint function/initializer rule; the report states this limitation.

Unmeasured functions retain `coverage: null` and `crap: null`. The gate uses
the conservative bound at zero coverage, never assuming missing tests passed.
For example, unmeasured CC 3 has bound 12; unmeasured CC 4 has bound 20 and
fails. There are no method or file exclusions, case omissions or suppressions.

Capture a source manifest immediately before instrumented builds. Reports
reject mismatched source hashes. `scripts/ci-crap` exports compiled package and
simulator app profiles, preserving the binaries and profile paths in a receipt.
It rejects absent or ambiguous evidence rather than launching a replacement
test run. The existing Lightning CI job runs the full package suite, Research
Lightning/background app suites and the complete normal app suite, then uploads
the report and test evidence. The recorded Research payment and normal
Bitcoin/multisig UI journeys also contribute instrumented coverage. Research deliberately lacks iCloud capability and
defaults to advanced Lightning controls; normal-only capability/default-mode
assertions run in the normal configuration. No coverage lines are removed from
the resulting metric.

For a local audit:

```sh
scripts/install-crap-swiftlint
scripts/check-crap snapshot --output /tmp/crap/source-manifest.json
swift test --enable-code-coverage --scratch-path /tmp/crap/package
# Build and run ResearchDebug and Debug app tests with -enableCodeCoverage YES.
scripts/ci-crap --package-build /tmp/crap/package \
  --derived-data /tmp/crap/app --variant ResearchDebug \
  --additional-app /tmp/crap/app Debug \
  --manifest /tmp/crap/source-manifest.json --output /tmp/crap/report
```

The installer prints the pinned SwiftLint location outside GitHub Actions;
place that directory on `PATH` before reporting. A preliminary report can use
`check-crap report --report-only`, but that option does not satisfy the CI gate.

When a local package run precedes an App-only edit and app rebuild, retain its
original snapshot and pass `--package-manifest` alongside the final `--manifest`.
The collector verifies every first-party source file represented by the package
coverage still has the same hash. A changed compiled file requires a new package
run. Both snapshots and the verified file list are retained with the report.
