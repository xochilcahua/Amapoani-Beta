use serde::{Deserialize, Serialize};
use std::collections::VecDeque;
use std::ffi::{CStr, CString, c_char};

#[derive(Serialize, PartialEq, Default)]
#[serde(rename_all = "snake_case")]
enum Phase {
    #[default]
    Standard,
    Loading,
    Playing,
    PlaybackPaused,
    Recording,
    DictationPaused,
    Finishing,
}

#[derive(Deserialize, Serialize, Default)]
#[serde(rename_all = "snake_case")]
enum ReadingView {
    #[default]
    Follow,
    Draft,
    Compact,
}

#[derive(Serialize)]
pub struct Session {
    phase: Phase,
    reading_view: ReadingView,
    draft: String,
    caret: Option<usize>,
    snapshot: Option<String>,
    preview: String,
    recovery: Option<String>,
    #[serde(skip)]
    queued_recoveries: VecDeque<String>,
    task: u64,
    #[serde(skip)]
    next: u64,
    #[serde(skip)]
    external: bool,
    expanded: bool,
    visible: bool,
    hidden_since: Option<u64>,
    idle_ms: u64,
    keep_loaded: bool,
    offload: bool,
}

impl Default for Session {
    fn default() -> Self {
        Self {
            phase: Phase::Standard,
            reading_view: ReadingView::Follow,
            draft: String::new(),
            caret: None,
            snapshot: None,
            preview: String::new(),
            recovery: None,
            queued_recoveries: VecDeque::new(),
            task: 0,
            next: 0,
            external: false,
            expanded: false,
            visible: false,
            hidden_since: None,
            idle_ms: 300_000,
            keep_loaded: false,
            offload: false,
        }
    }
}

#[derive(Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
enum Event {
    Show { now: u64 },
    Hide { now: u64 },
    Tick { now: u64 },
    Policy { idle_ms: u64, keep_loaded: bool, now: u64 },
    Expand { expanded: bool },
    Draft { text: String, caret: Option<usize> },
    Read { source: Option<String> },
    Play { task: u64 },
    ReadingView { view: ReadingView },
    Pause { task: u64 },
    ReadDone { task: u64 },
    Dictate { external: bool },
    Preview { task: u64, text: String },
    Finish { task: u64 },
    RecognitionFailed { task: u64 },
    Transcript { task: u64, text: String },
    EditRecovery { text: String },
    InsertRecovery,
    ClearRecovery,
    Cancel,
}

impl Session {
    fn begin(&mut self, phase: Phase) {
        self.next += 1;
        self.task = self.next;
        self.phase = phase;
        self.hidden_since = None;
    }

    fn end(&mut self) {
        self.phase = Phase::Standard;
        self.snapshot = None;
        self.preview.clear();
        self.task = 0;
    }

    fn insert(&mut self, text: &str) {
        let text = text.trim();
        if text.is_empty() {
            return;
        }
        let Some(offset) = self.caret.and_then(|caret| utf16_position(&self.draft, caret)) else {
            if !self.draft.is_empty() && !self.draft.ends_with('\n') {
                self.draft.push('\n');
            }
            self.draft.push_str(text);
            self.caret = Some(self.draft.encode_utf16().count());
            return;
        };
        let (prefix, suffix) = self.draft.split_at(offset);
        let mut inserted = String::new();
        if prefix.chars().last().is_some_and(|c| !c.is_whitespace()) {
            inserted.push(' ');
        }
        inserted.push_str(text);
        if suffix.chars().next().is_some_and(|c| !c.is_whitespace() && !".,;:!?)]}".contains(c)) {
            inserted.push(' ');
        }
        let end = prefix.encode_utf16().count() + inserted.encode_utf16().count();
        self.draft.insert_str(offset, &inserted);
        self.caret = Some(end);
    }

    fn reading(&self) -> bool {
        matches!(self.phase, Phase::Loading | Phase::Playing | Phase::PlaybackPaused)
    }

    fn apply(&mut self, event: Event) {
        self.offload = false;
        match event {
            Event::Show { now } => {
                let _ = now;
                self.visible = true;
                self.hidden_since = None;
            }
            Event::Hide { now } if self.phase == Phase::Standard => {
                self.visible = false;
                self.hidden_since = Some(now);
                self.expanded = false;
            }
            Event::Tick { now } if !self.visible && !self.keep_loaded && self.phase == Phase::Standard => {
                if self.hidden_since.is_some_and(|since| now.saturating_sub(since) >= self.idle_ms) {
                    self.hidden_since = None;
                    self.draft.clear();
                    self.caret = None;
                    self.recovery = None;
                    self.queued_recoveries.clear();
                    self.offload = true;
                }
            }
            Event::Policy { idle_ms, keep_loaded, now } => {
                if self.keep_loaded && !keep_loaded && !self.visible {
                    self.hidden_since = Some(now);
                }
                self.idle_ms = idle_ms;
                self.keep_loaded = keep_loaded;
            }
            Event::Expand { expanded } => self.expanded = expanded,
            Event::Draft { text, caret } => {
                self.draft = text;
                self.caret = caret;
            }
            Event::Read { source } if self.phase == Phase::Standard => {
                let text = source.as_deref().filter(|s| !s.trim().is_empty()).unwrap_or(&self.draft);
                if !text.trim().is_empty() {
                    self.snapshot = Some(text.to_owned());
                    self.reading_view = ReadingView::Follow;
                    self.begin(Phase::Loading);
                }
            }
            Event::Play { task } if self.task == task && self.phase == Phase::Loading => {
                self.phase = Phase::Playing;
            }
            Event::ReadingView { view } if self.reading() => self.reading_view = view,
            Event::Pause { task } if self.task == task => {
                self.phase = match self.phase {
                    Phase::Playing => Phase::PlaybackPaused,
                    Phase::PlaybackPaused => Phase::Playing,
                    Phase::Recording => Phase::DictationPaused,
                    Phase::DictationPaused => Phase::Recording,
                    _ => return,
                };
            }
            Event::ReadDone { task } if self.task == task && self.reading() => self.end(),
            Event::Dictate { external } if self.phase == Phase::Standard => {
                self.external = external;
                self.preview.clear();
                self.begin(Phase::Recording);
            }
            Event::Preview { task, text } if self.task == task &&
                matches!(self.phase, Phase::Recording | Phase::DictationPaused) => self.preview = text,
            Event::Finish { task } if self.task == task &&
                matches!(self.phase, Phase::Recording | Phase::DictationPaused) => self.phase = Phase::Finishing,
            Event::RecognitionFailed { task } if self.task == task && self.phase == Phase::Finishing =>
                self.phase = Phase::DictationPaused,
            Event::Transcript { task, text } if self.task == task && self.phase == Phase::Finishing => {
                if !text.trim().is_empty() {
                    if self.external {
                        if self.recovery.is_some() {
                            self.queued_recoveries.push_back(text);
                        } else {
                            self.recovery = Some(text);
                        }
                    } else {
                        self.insert(&text);
                        self.expanded = true;
                    }
                }
                self.end();
            }
            Event::EditRecovery { text } if self.phase == Phase::Standard && self.recovery.is_some() => {
                self.recovery = Some(text);
            }
            Event::InsertRecovery if self.phase == Phase::Standard => {
                if let Some(text) = self.recovery.take() {
                    self.insert(&text);
                    self.expanded = true;
                    self.recovery = self.queued_recoveries.pop_front();
                }
            }
            Event::ClearRecovery => self.recovery = self.queued_recoveries.pop_front(),
            Event::Cancel => self.end(),
            _ => {}
        }
    }
}

fn utf16_position(text: &str, offset: usize) -> Option<usize> {
    let mut units = 0;
    for (index, scalar) in text.char_indices() {
        if units == offset {
            return Some(index);
        }
        units += scalar.len_utf16();
    }
    (units == offset).then_some(text.len())
}

#[unsafe(no_mangle)]
pub extern "C" fn ahampo_session_create() -> *mut Session {
    Box::into_raw(Box::new(Session::default()))
}

/// # Safety
/// Use a live session pointer from ahampo_session_create, once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ahampo_session_destroy(session: *mut Session) {
    if !session.is_null() {
        drop(unsafe { Box::from_raw(session) });
    }
}

/// # Safety
/// The session must be exclusively borrowed and request must be a valid C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ahampo_session_apply(session: *mut Session, request: *const c_char) -> *mut c_char {
    let Some(session) = (unsafe { session.as_mut() }) else { return std::ptr::null_mut() };
    if request.is_null() {
        return std::ptr::null_mut();
    }
    let bytes = unsafe { CStr::from_ptr(request) }.to_bytes();
    let Ok(event) = serde_json::from_slice(bytes) else { return std::ptr::null_mut() };
    session.apply(event);
    serde_json::to_vec(session).ok().and_then(|bytes| CString::new(bytes).ok())
        .map_or(std::ptr::null_mut(), CString::into_raw)
}

/// # Safety
/// Pass a pointer returned by ahampo_session_apply, once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ahampo_string_free(response: *mut c_char) {
    if !response.is_null() {
        drop(unsafe { CString::from_raw(response) });
    }
}
