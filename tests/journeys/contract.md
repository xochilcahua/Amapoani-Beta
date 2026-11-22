# AHAMPO live user journeys

The speaker starts a new read from the current selection in the active browser. One physical click reads that selection, or the current draft if the selection is empty or unavailable. Every new click resolves the source again. Playback preserves the draft and uses an immutable snapshot. A blank draft with no readable selection produces a quiet inline or status message. It leaves the capsule in place and opens no menu, permission prompt, or window and adds no buttons. Only the explicit access command can start permission setup.

This supplement supersedes the earlier unavailable-selection requirement to offer a separate Read Draft action and the earlier placement of Copy and Clear in the compact capsule. The previously sealed artifacts remain evidence for the original requirements. This supplement adds a separate gate for these updated journeys.

## Recorded by the live runner

Start with a signed candidate, a fresh standard capsule with an empty disposable draft, the local browser fixture foregrounded, and a reviewer with permission to send test mouse and keyboard events. The application’s own selection-access state is independent of the reviewer’s access. The runner verifies the executable hash, exact launched bundle, single PID, fixture identity and blank draft before input. Fixture text is synthetic.

| Case | Mandatory observations |
| --- | --- |
| layout | Compact exposes an editable one-line draft and Expand, with Copy and Clear absent. Expanded exposes Copy and Clear on the left before the right-side Collapse chevron. Both sizes retain exactly the same draft. |
| empty | With no selection and an empty draft, one physical speaker click shows a short inline or status message. The browser stays foregrounded. There is no transport, menu, extra button, prompt, or navigation. The draft stays empty. |
| fresh-page | With the capsule already visible and page A highlighted across inline nodes, one physical speaker click starts Follow Along with page A’s exact text. The same browser window and selection remain active. Stop returns to the exact original draft. |
| reselect | Highlight page B after stopping page A. One click reads precisely page B. The browser remains active and the draft stays exact. |
| textarea | Highlight the separate native browser textarea. One click reads exactly its text, keeps the browser and its field selection active, and preserves the draft. |
| deselection | Clear the last browser selection, then click once. Follow Along opens on the exact draft and does not replay the previous text. Browser focus and draft persist. |
| wake | Hide the idle capsule with Escape, select page B and summon via Option–Shift–Space. A physical speaker click while that fixture is active reads the exact current selection. The draft persists. |
| reopen | Reopen the candidate through Launch Services while it is running. The original PID, capsule and draft persist. Pick page A, then one physical speaker click reads the exact current selection and preserves the draft. |
| unavailable | With the app’s selection access unavailable and the browser fixture visibly highlighted, one speaker click enters playback of the exact draft. The browser stays active. There is no Read Draft action, access prompt, menu, or navigation. |
| transport | Observe the native Seek value advancing after the speaker click. Pause holds the position, Resume advances the same timeline and Stop restores the ordinary capsule and exact draft. Follow Along remains the original exact source. |
| edit-undo | Edit the draft from playback’s Draft view with keyboard input while paused. The exact original passage stays read-only in Follow Along and playback resumes on its timeline. Stop preserves the independent edited draft. Command–Z restores the original text in one undo. |

The granted runs cover the full sequence on Zen, Safari and Helium. Stock Firefox and Chrome spot checks cover page and textarea selections. The unavailable run covers empty, unavailable, transport and edit-undo on an approved fixture browser. Each run records completed, failed and blocked cases. A blocked or omitted run leaves its required cases unqualified.

## Recorded by the independent reviewer

| Case | Mandatory observations and evidence |
| --- | --- |
| visual-light | Record tightly cropped candidate images for compact, expanded and playback. Compare each to the approved Graphite references. Controls and text remain readable, the shell and control wells are flat, the editor alone fades, and the status message is quiet and unclipped. Verify control placement in both sizes. |
| visual-dark | Repeat the three states and the inline status check in dark appearance. Include screenshots, contrast observations and clipped-content inspection. |
| accessibility | With keyboard and macOS VoiceOver, reach and identify draft, speaker, expand/collapse, Copy and Clear in expanded, and transport. Verify logical focus order, named actions, a read-only spoken passage, announced status for the empty case, hidden compact Copy/Clear and retained browser text selection. Include a keyboard and VoiceOver transcript. |
| explicit-permission | Record the candidate Settings access state and exact path before the unavailable run. Verify a speaker click does not trigger system permission UI. Use only the labeled access command to open the expected OS permission route, then record actual granted status before granted runs. Capture the available settings, navigation and result without changing other applications. |
| audible-offline | With networking unavailable and bundled or local English assets already ready, listen to the first sentence of highlighted browser text and the draft fallback. Confirm the audible words against the exact fixture, silence during pause, resumed speech from the same passage, and silence on Stop. Record network state and timestamps tied to the candidate run. |
| draft-workflow | Type and paste disposable text through real controls. Check Copy in expanded pastes the full exact text into the disposable fixture textarea, Clear empties it, one Undo restores it, and redo works. Recheck caret and draft across compact/expanded. Preserve the user’s clipboard and dismiss only fixture windows. |
| native-textedit | In a new untitled TextEdit document with synthetic text, verify selected native text reads with one speaker click, remains selected and keeps the draft intact. Save no fixture document. |
| dictation | Perform offline English dictation into the draft and a new disposable native field. Include pause, resume, elapsed time, one verified final insertion, Undo, and Escape cancellation. Capture observations for destination, preliminary preview and original text preservation. |
| playback-navigation | Exercise audio-available backward/forward seek, click-to-phrase, follow/manual-scroll behavior, Draft, Compact and natural completion. Confirm the timeline and highlighted text remain consistent. |
| lifecycle | Show the default capsule, drag and reopen to the stored position, confirm one process, and verify localized settings persist. Record model readiness and offload separately with an isolated test setup. |

## Scoring and release gate

Record every mandatory observation with a timestamped reference to a log, screenshot, video or operator transcript. Include the candidate identity, fixture hash and test environment. For each case an independent reviewer scores functionality, usability, accessibility and visual fidelity on a 0–10 scale and records the reason for each deduction. Each dimension must reach **8.5** and all mandatory observations must hold. A failure, block, skip, missing row, missing evidence, unverified preflight, candidate change or score below 8.5 fails the gate. A log of worker output or an initial Play label cannot substitute for live transport progress. Record manual aspects that automation cannot observe, including actual audio output, system prompts and visual fidelity. The original gate may contain broader requirements outside these journeys.
