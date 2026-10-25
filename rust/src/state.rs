//! The interactive authentication state machine.
//!
//! The login flow is modelled as a finite state machine. The *driver*
//! (see [`crate::auth_core::AuthSession::run`]) advances the machine;
//! events travel **up** to the UI (Dart) on an `mpsc` channel and user
//! input travels **back down** on a command channel:
//!
//! ```text
//!                ┌────────────────────┐
//!   (new)        │        Idle        │◀──────────────────────────┐
//!                └─────────┬──────────┘                           │
//!          StartLogin      │                                      │
//!                          ▼                                      │
//!                ┌────────────────────┐   Credentials             │
//!                │  NeedsCredentials  │ ──────┐                   │
//!                └────────────────────┘       ▼                   │
//!                                   ┌────────────────────┐        │
//!                                   │      Working       │        │
//!                                   │  discharge, no OTP) │        │
//!                                   └───┬──────────────┬──┘        │
//!                                   └────────────────────┘        │
//!                       discharge ok  │              │ 2FA       │
//!                                     ▼              ▼ required  │
//!                    ┌────────────────────┐  ┌────────────────────┐│
//!                    │     Succeeded      │  │   Needs2FACode     ││
//!                    └─────────┬──────────┘  └─────────┬──────────┘│
//!                              │ Logout                │ code      │
//!                              ▼                       ▼           │
//!                         (session               (retry with OTP) ─┘
//!                          ended, back            on failure → loop
//!                          to Idle)               to Needs2FACode
//!
//!   Any state ──Cancel──▶ Cancelled (terminal; driver exits)
//!   Any error            ──▶ Failed event + back to Idle
//! ```
//!
//! Invariants (enforced by [`AuthStateMachine::transition`], not assumed):
//!
//! * only one login flow runs at a time;
//! * `Credentials` is only accepted in `NeedsCredentials`;
//! * `TwoFactorCode` is only accepted in `Needs2FACode`;
//! * `Cancel` works from any state;
//! * after `Succeeded`, only `Logout` or `Cancel` are accepted.

use crate::error::{AuthenticationError, Result};
use serde::{Deserialize, Serialize};
use std::collections::VecDeque;
use std::sync::{Arc, Mutex, PoisonError};
use zeroize::Zeroizing;

/// Input events pushed *down* from the UI to the state machine.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum UiEvent {
    /// Begin a login for the configured store.
    #[serde(rename = "start_login")]
    StartLogin {
        /// Description attached to the session, e.g. `"my-app@phone"`.
        description: String,
    },
    /// Deliver Ubuntu One email + password (answers
    /// [`MachineEvent::NeedsCredentials`]).
    Credentials {
        /// Ubuntu One account email.
        email: String,
        /// Ubuntu One account password (in memory only, never persisted).
        password: String,
    },
    /// Deliver the 2FA one-time code (answers [`MachineEvent::Needs2FACode`]).
    #[serde(rename = "two_factor_code")]
    TwoFactorCode {
        /// TOTP / SMS code from the user.
        code: String,
    },
    /// Restore a previously persisted credential pair (e.g. after an app
    /// relaunch, from Flutter Secure Storage). Accepted in `Idle`.
    RestoreCredentials {
        /// The serialized [`crate::storage::Credentials`] JSON.
        json: String,
    },
    /// End the session (accepted in `Succeeded`; mid-flow it is an error).
    Logout,
    /// Abort the current flow (accepted in any state).
    Cancel,
}

/// Events emitted *up* from the state machine to the UI (Dart).
///
/// Every variant is a plain, self-contained value — no borrows, no
/// closures — so it serializes 1:1 into Dart objects via
/// `flutter_rust_bridge` / UniFFI.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum MachineEvent {
    /// The machine is waiting for email + password.
    #[serde(rename = "needs_credentials")]
    NeedsCredentials,

    /// Ubuntu One requires a 2FA one-time code.
    #[serde(rename = "needs_2fa_code")]
    Needs2FACode,

    /// Login succeeded; credentials have been persisted.
    Succeeded {
        /// The email the session is bound to.
        email: String,
        /// `true` when a 2FA code was required and supplied.
        used_two_factor: bool,
        /// The persisted credentials as JSON. **Save this string in
        /// Flutter Secure Storage** (or your platform keychain/keystore)
        /// so the next app launch can call `restore_credentials()`.
        credentials_json: String,
    },

    /// The session was ended by the user.
    #[serde(rename = "logged_out")]
    LoggedOut,

    /// The flow was aborted by the user.
    Cancelled {
        /// Human-readable reason.
        reason: String,
    },

    /// A terminal error occurred; the machine is back in `Idle`.
    Failed {
        /// The typed error.
        error: AuthenticationError,
    },
}

/// Snapshot of the machine for debugging / UI status indicators.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum MachineState {
    /// No flow in progress.
    Idle,
    /// Waiting for email + password.
    #[serde(rename = "needs_credentials")]
    NeedsCredentials,
    /// Network work in flight (transient).
    Working,
    /// Waiting for the 2FA code.
    #[serde(rename = "needs_2fa_code")]
    Needs2FACode,
    /// Logged in.
    Succeeded,
    /// Aborted (until the driver exits and a new flow starts).
    Cancelled,
}

impl MachineState {
    /// Stable string form (e.g. `"needs_2fa_code"`).
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Idle => "idle",
            Self::NeedsCredentials => "needs_credentials",
            Self::Working => "working",
            Self::Needs2FACode => "needs_2fa_code",
            Self::Succeeded => "succeeded",
            Self::Cancelled => "cancelled",
        }
    }
}

/// Command channel from UI → machine.
pub type UiEventSender = tokio::sync::mpsc::UnboundedSender<UiEvent>;
/// Event channel from machine → UI.
pub type MachineEventSender = tokio::sync::mpsc::UnboundedSender<MachineEvent>;
/// Event channel from machine → UI.
pub type MachineEventReceiver = tokio::sync::mpsc::UnboundedReceiver<MachineEvent>;
/// Shared state cell readable from both the driver task and the FFI side.
pub type SharedState = Arc<Mutex<MachineState>>;

/// The interactive login state machine.
///
/// Owns the current state (in a shared cell so the FFI side can poll it)
/// and the event channel toward the UI. The *command channel* is owned by
/// the driver task (see [`crate::auth_core`]), which owns the flow
/// orchestration: network calls and the interactive 2FA pause.
pub struct AuthStateMachine {
    state: SharedState,
    events: MachineEventSender,
    /// Buffered events so the FFI side can pull them via `drain_events()`.
    buffer: EventBuffer,
    /// Email/password carried between `NeedsCredentials` and `Needs2FACode`
    /// (in memory only; cleared on success/cancel).
    pending: std::sync::Mutex<Option<(String, Zeroizing<String>)>>,
}

impl AuthStateMachine {
    /// Wire up a machine sharing `state` with the FFI side.
    pub fn new(state: SharedState, events: MachineEventSender, buffer: EventBuffer) -> Self {
        AuthStateMachine {
            state,
            events,
            buffer,
            pending: std::sync::Mutex::new(None),
        }
    }

    /// Current state (lock is held for nanoseconds).
    pub fn state(&self) -> MachineState {
        *self
            .state
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
    }

    /// Unconditional state write (driver only).
    pub fn set_state(&self, s: MachineState) {
        *self
            .state
            .lock()
            .unwrap_or_else(PoisonError::into_inner) = s;
    }

    /// Record a terminal failure: reset to `Idle` and emit `Failed`.
    pub fn fail(&self, error: AuthenticationError) {
        self.set_state(MachineState::Idle);
        self.emit(MachineEvent::Failed { error });
    }

    /// Record a user cancellation: move to `Cancelled` and emit `Cancelled`.
    /// (The driver returns the machine to `Idle` so a new flow can start.)
    pub fn finish_cancelled(&self, reason: String) {
        self.set_state(MachineState::Cancelled);
        self.emit(MachineEvent::Cancelled { reason });
    }

    /// Guarded transition: only allowed when the current state is one of
    /// `from`.
    pub fn transition(&self, from: &[MachineState], to: MachineState) -> Result<()> {
        let mut guard = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        if !from.contains(&*guard) {
            return Err(AuthenticationError::InvalidStateTransition(format!(
                "cannot transition from '{}' to '{}'",
                guard.as_str(),
                to.as_str()
            )));
        }
        *guard = to;
        Ok(())
    }

    /// Emit an event to the UI: buffer it for `drain_events()` *and* push
    /// it on the channel (for push-style subscribers). A closed channel is
    /// swallowed — there is nothing sensible to do about it.
    pub fn emit(&self, event: MachineEvent) {
        self.buffer.push(event.clone());
        let _ = self.events.send(event);
    }

    /// The machine's event buffer (shared with the FFI handle).
    pub fn buffer(&self) -> &EventBuffer {
        &self.buffer
    }

    /// Stash credentials for the 2FA retry (driver only).
    pub fn stash_credentials(&self, email: String, password: String) {
        // Zeroizing wipes the password from memory when it is replaced or
        // dropped, limiting the window a co-located process (or a core dump)
        // can recover it from the heap.
        *self
            .pending
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) =
            Some((email, Zeroizing::new(password)));
    }

    /// Read stashed credentials (driver only).
    pub fn take_pending_credentials(&self) -> Option<(String, String)> {
        // Clone the values out. The stored password is a Zeroizing wrapper;
        // we only copy the bytes here, and the stored original is wiped when
        // it is next replaced or dropped.
        self.pending
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_ref()
            .map(|(e, p)| (e.clone(), (**p).to_string()))
    }

    /// Clear stashed credentials (driver only).
    pub fn clear_pending_credentials(&self) {
        *self
            .pending
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = None;
    }
}

/// Small in-memory queue used by the FFI runtime to buffer machine events
/// between `drain_events()` calls.
///
/// Cloning is cheap and **shares** the same underlying queue (Arc inside),
/// so the driver (in the state machine) and the FFI handle can both refer
/// to the same buffer.
#[derive(Default)]
pub struct EventBuffer {
    inner: Arc<Mutex<VecDeque<MachineEvent>>>,
}

impl Clone for EventBuffer {
    fn clone(&self) -> Self {
        EventBuffer {
            inner: std::sync::Arc::clone(&self.inner),
        }
    }
}

impl EventBuffer {
    pub fn new() -> Self {
        EventBuffer::default()
    }

    pub fn push(&self, e: MachineEvent) {
        self.inner
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .push_back(e);
    }

    pub fn pop(&self) -> Option<MachineEvent> {
        self.inner
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .pop_front()
    }

    pub fn len(&self) -> usize {
        self.inner
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

#[allow(dead_code)]
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn state_strings_are_stable() {
        assert_eq!(MachineState::Idle.as_str(), "idle");
        assert_eq!(
            MachineState::Needs2FACode.as_str(),
            "needs_2fa_code"
        );
        assert_eq!(
            MachineState::NeedsCredentials.as_str(),
            "needs_credentials"
        );
        assert_eq!(MachineState::Succeeded.as_str(), "succeeded");
        assert_eq!(MachineState::Working.as_str(), "working");
        assert_eq!(MachineState::Cancelled.as_str(), "cancelled");
    }

    #[test]
    fn transition_guard_rejects_illegal_moves() {
        let state: SharedState = Arc::new(Mutex::new(MachineState::Idle));
        let (tx, _rx) = tokio::sync::mpsc::unbounded_channel::<MachineEvent>();
        let m = AuthStateMachine::new(state, tx, EventBuffer::new());

        // Legal: Idle → NeedsCredentials.
        m.transition(&[MachineState::Idle], MachineState::NeedsCredentials)
            .expect("legal");
        assert_eq!(m.state(), MachineState::NeedsCredentials);

        // Illegal: NeedsCredentials → Needs2FACode (must go through Working).
        let err = m
            .transition(&[MachineState::Idle], MachineState::Needs2FACode)
            .expect_err("illegal");
        assert_eq!(
            err,
            AuthenticationError::InvalidStateTransition(
                "cannot transition from 'needs_credentials' to 'needs_2fa_code'".into()
            )
        );
        assert_eq!(m.state(), MachineState::NeedsCredentials);
    }

    #[test]
    fn event_buffer_fifo() {
        let buf = EventBuffer::new();
        assert!(buf.is_empty());
        buf.push(MachineEvent::NeedsCredentials);
        buf.push(MachineEvent::Needs2FACode);
        assert_eq!(buf.len(), 2);
        assert_eq!(buf.pop(), Some(MachineEvent::NeedsCredentials));
        assert_eq!(buf.pop(), Some(MachineEvent::Needs2FACode));
        assert_eq!(buf.pop(), None);
    }

    #[test]
    fn ui_events_serialize_with_stable_tags() {
        let v = serde_json::to_value(UiEvent::TwoFactorCode {
            code: "123456".into(),
        })
        .expect("ser");
        assert_eq!(v["type"], "two_factor_code");
        assert_eq!(v["code"], "123456");

        let v = serde_json::to_value(MachineEvent::Needs2FACode).expect("ser");
        assert_eq!(v["type"], "needs_2fa_code");
    }
}
