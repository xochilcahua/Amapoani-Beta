# Run the live journeys

Use the [acceptance contract](contract.md) for observations and scoring. The runner drives the signed macOS capsule and a local test browser with screen-coordinate mouse clicks and native keyboard events. It uses Accessibility to locate controls and read their state. It never opens permission settings, writes to the clipboard, reads a private browser document, or clears text that it did not generate. Use a separate test session or pause other input while it runs.

## Prepare one candidate and fixture

From the AHAMPO checkout, set the exact signed candidate and an output directory for this review. Use the executable SHA-256 published with the candidate.

```sh
suite="$PWD/tests/journeys"
candidate="$PWD/build/current/AHAMPO.app"
sha='PASTE_THE_APPROVED_EXECUTABLE_SHA256_HERE'
output="$PWD/work/review/live-journey-01"
mkdir -p "$output"
shasum -a 256 "$candidate/Contents/MacOS/AHAMPO"
codesign --verify --strict "$candidate"
xcrun swiftc "$suite/Journey.swift" -o "$output/journey"
python3 "$suite/grade.py" --candidate "$candidate" --sha "$sha" --template > "$output/review.json"
```

Keep only that candidate running with the standard capsule visible and the draft empty. Close its Settings. Prepare the local English models before the audio tests. Open [browser.html](browser.html) in a disposable browser window, keep its controls visible, and bring that window to the front. If you launch the runner from Terminal, switch to the fixture during the five-second delay. The runner needs Accessibility and permission to post input events. This is separate from the candidate's permission to read selections.

## Run the unavailable-access case first

In AHAMPO Settings verify that the exact candidate has unavailable access, then close Settings. Record the setting and perform the unavailable run. The browser fixture may start with any of its selections. The runner chooses the required states.

```sh
sleep 5 && "$output/journey" --live "$candidate" "$sha" "$suite/browser.html" zen unavailable "$output/unavailable-zen"
```

For the explicit-permission case, record the state before and after using AHAMPO's labeled access command. Record any system navigation and grant for the exact candidate. The runner cannot verify the absence of every host permission dialog, so watch the screen during the unavailable run and record what happened.

## Run the granted browser cases

With the candidate's selection access confirmed, switch to the named fixture browser before each command. Run them sequentially. Each report goes to a new directory. If you retry, choose a fresh directory and retain the first result.

```sh
sleep 5 && "$output/journey" --live "$candidate" "$sha" "$suite/browser.html" zen granted "$output/granted-zen"
sleep 5 && "$output/journey" --live "$candidate" "$sha" "$suite/browser.html" safari granted "$output/granted-safari"
sleep 5 && "$output/journey" --live "$candidate" "$sha" "$suite/browser.html" helium granted "$output/granted-helium"
sleep 5 && "$output/journey" --live "$candidate" "$sha" "$suite/browser.html" firefox granted "$output/granted-firefox"
sleep 5 && "$output/journey" --live "$candidate" "$sha" "$suite/browser.html" chrome granted "$output/granted-chrome"
```

Each `readings.json` records the preflight, candidate and browser identities, observations and any blockers. A missing browser, inaccessible fixture or unready draft leaves the affected cases unqualified. The runner stops rather than sending input to an unverified process or browser tab. If a failure leaves synthetic text in the candidate, verify it is the fixture draft before removing it manually.

## Review and grade

Complete the manual observations in the contract and score each row in `review.json`. Store the evidence in the same output tree. Each reference supplies its relative `path`, ISO 8601 timestamp with timezone in `at`, and an `observation` describing what it proves. Use `pass` only when every observation for the row is supported. Record a reason for each score below 10 in `deductions`. For a scored live case, cite its runner report and any additional keyboard, listening or visual evidence. Record adverse and blocked observations as well.

```sh
python3 "$suite/grade.py" --candidate "$candidate" --sha "$sha" --review "$output/review.json" \
  --run "$output/unavailable-zen/readings.json" \
  --run "$output/granted-zen/readings.json" \
  --run "$output/granted-safari/readings.json" \
  --run "$output/granted-helium/readings.json" \
  --run "$output/granted-firefox/readings.json" \
  --run "$output/granted-chrome/readings.json" > "$output/grade.json"
```

Exit zero means all required live runs, evidence rows and scores qualified. Other exit codes and `grade.json` identify the incomplete gate. Keep the first recorded output and candidate identity when comparing revisions.
