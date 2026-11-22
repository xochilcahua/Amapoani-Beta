# Domain glossary

These names describe the planned behavior. They do not commit the implementation to a particular framework or file structure.

| Term | Meaning |
| --- | --- |
| Overlay | The shortcut-invoked window containing speech controls and an editable draft. |
| Invocation | One request to show the overlay, associated with the external context observed before the overlay takes focus. |
| Selection | Text highlighted in an external application. It is not necessarily the normal clipboard contents. |
| Destination | The external editable control and insertion position associated with an invocation. A foreground application or window alone is insufficient identification. |
| Draft | Text in the overlay's own editor. It can be edited, copied, pasted, and read aloud. Dictation inserts text at a valid caret or appends it on a new line. |
| Dictation | Recording speech and producing text in its spoken language. Translation is a separate behavior and is not requested. |
| Reading | Generating and playing spoken audio from selected text or draft text. |
| Reading snapshot | The immutable copy of source text captured when the speaker action starts. Later draft edits do not change it. |
| Follow Along | The read-only playback view of the reading snapshot. The highlight tracks the current passage and clicking the text seeks on the playback timeline. |
| Compact playback | The player with the passage and draft hidden and the transport controls visible. |
| Dictation preview | A separate view of provisional recognition text before the completed transcript is delivered. |
| Automatic unload | A policy that releases loaded models and retained session data after the configured interval with the overlay hidden and no speech work in progress. |
| Keep Loaded | A persistent preference that keeps already-loaded models in memory when the capsule is closed. Opening the capsule starts preloading under either preference. |
| Delivery | An attempt to insert completed dictation into a destination. A successful transcription does not by itself establish successful delivery. |
| Interaction session | Owns the draft and speech workflow across capsule invocations until idle expiry or quit. Each invocation and speech task has its own identity and external context. |
| Model library | Discovers, verifies, installs, and removes compatible files in a shared model folder. |
| Asset set | Model weights plus the voice and frontend files a specific runtime needs for a named capability. |
| Model residency | A loaded model consumes runtime memory. Installed assets occupy disk space independently of residency. |
| Speech worker | Proposed disposable process containing model loading and inference work. Its lifecycle is intended to make idle resource use measurable. |
| Desktop capability | What the current application, OS permissions, and desktop session actually allow: shortcut, selection capture, destination inspection, or insertion. |
| Frozen baseline | The reviewed acceptance tests, fixtures, expected results, scoring rules, runner, and environment definitions whose approved bytes cannot be changed during implementation. |

Architecture discussions use **module**, **interface**, **implementation**, **seam**, **adapter**, **depth**, **leverage**, and **locality** as defined by the codebase-design skill.
