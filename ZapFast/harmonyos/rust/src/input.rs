//! ArkUI's input events translated into what egui's `RawInput` expects.
//!
//! The XComponent reports touch, mouse, key, axis and focus events on the UI
//! thread. Each is turned into the egui events a desktop window manager would
//! produce: pointer moves and buttons for touches, wheel lines or touchpad
//! points for the axis, `Key` and `Text` for the keyboard, and
//! `WindowFocused` for focus changes.
//!
//! Coordinates from ArkUI are in vp, which is the unit egui counts in
//! (points), so they pass through unchanged: the host builds `RawInput` with a
//! screen rectangle in vp and sets `native_pixels_per_point` to the display
//! density, and egui_glow paints at that scale into the pixel surface.

use egui::{Key, Modifiers, Pos2, TouchPhase, Vec2};

/// Which ArkUI touch phase a finger reported.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TouchAction {
    Down,
    Move,
    Up,
    Cancel,
}

/// Which ArkUI mouse action the pointer reported.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MouseAction {
    Press,
    Release,
    Move,
    /// The pointer entered the component. ArkUI sends hover separately.
    Hover,
    Cancel,
}

/// Which button a mouse event names.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MouseButton {
    Left,
    Right,
    Middle,
    Back,
    Forward,
}

/// Whether a key went down or up.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum KeyAction {
    Down,
    Up,
}

/// One event as ArkUI reported it.
#[derive(Clone, Debug)]
pub enum OsEvent {
    Touch {
        action: TouchAction,
        id: i32,
        x: f32,
        y: f32,
        force: f32,
    },
    Mouse {
        action: MouseAction,
        x: f32,
        y: f32,
        button: MouseButton,
    },
    Key {
        action: KeyAction,
        /// The `OH_NativeXComponent_KeyCode` value, or ArkUI's `KeyCode`.
        code: i32,
    },
    /// Text committed by the keyboard or input method, already in UTF-8.
    Text(String),
    /// A wheel notch or a two-finger swipe. `scroll_step` is ArkUI's
    /// configured step, in lines, when the source reports one.
    Axis {
        horizontal: f32,
        vertical: f32,
        /// The wheel's configured step, or zero for a touchpad.
        scroll_step: f32,
        /// The event came from the mouse rather than a touch surface.
        mouse: bool,
    },
    Focus(bool),
}

/// The modifiers held, tracked from the keys themselves: ArkUI's mouse and
/// axis events carry no reliable modifier mask, but the keyboard reports
/// every modifier key.
#[derive(Clone, Copy, Debug, Default)]
pub struct Held {
    pub shift: bool,
    pub ctrl: bool,
    pub alt: bool,
    pub meta: bool,
    pub caps_lock: bool,
}

impl Held {
    pub fn modifiers(self) -> Modifiers {
        Modifiers {
            alt: self.alt,
            ctrl: self.ctrl,
            shift: self.shift,
            mac_cmd: false,
            command: self.ctrl || self.meta,
        }
    }
}

/// The state that carries from one event to the next.
#[derive(Default)]
pub struct Input {
    held: Held,
    /// Whether the ArkTS side forwards `keyText`, so printable keys are not
    /// also turned into text here (that would type every letter twice).
    pub text_bridge: bool,
    /// The last pointer position, so a press that carries no position can
    /// still be placed.
    pointer: Option<Pos2>,
    /// The egui touch identifier of the finger the pointer follows.
    touch: Option<egui::TouchId>,
}

impl Input {
    /// Translates one ArkUI event, appending it to `out`.
    pub fn push(&mut self, event: OsEvent, out: &mut Vec<egui::Event>) {
        match event {
            OsEvent::Touch {
                action,
                id,
                x,
                y,
                force,
            } => self.touch(action, id, x, y, force, out),
            OsEvent::Mouse {
                action,
                x,
                y,
                button,
            } => self.mouse(action, x, y, button, out),
            OsEvent::Key { action, code } => self.key(action, code, out),
            OsEvent::Text(text) => {
                self.text_bridge = true;
                out.push(egui::Event::Text(text));
            }
            OsEvent::Axis {
                horizontal,
                vertical,
                scroll_step,
                mouse,
            } => self.axis(horizontal, vertical, scroll_step, mouse, out),
            OsEvent::Focus(focused) => {
                out.push(egui::Event::WindowFocused(focused));
            }
        }
    }

    fn touch(
        &mut self,
        action: TouchAction,
        id: i32,
        x: f32,
        y: f32,
        force: f32,
        out: &mut Vec<egui::Event>,
    ) {
        let pos = Pos2::new(x, y);
        self.pointer = Some(pos);
        let touch_id = egui::TouchId::from(u64::try_from(id).unwrap_or(0));
        // The first finger drives the pointer, as a mouse does. A second
        // finger is reported as a touch only, so a pinch never moves the
        // bubble the first finger holds.
        let primary = self.touch.is_none_or(|current| current == touch_id);
        let phase = match action {
            TouchAction::Down => TouchPhase::Start,
            TouchAction::Move => TouchPhase::Move,
            TouchAction::Up => TouchPhase::End,
            TouchAction::Cancel => TouchPhase::Cancel,
        };
        out.push(egui::Event::Touch {
            device_id: egui::TouchDeviceId(0),
            id: touch_id,
            phase,
            pos,
            force: Some(force),
        });
        if !primary {
            return;
        }
        match action {
            TouchAction::Down => {
                self.touch = Some(touch_id);
                out.push(egui::Event::PointerMoved(pos));
                out.push(egui::Event::PointerButton {
                    pos,
                    button: egui::PointerButton::Primary,
                    pressed: true,
                    modifiers: self.held.modifiers(),
                });
            }
            TouchAction::Move => out.push(egui::Event::PointerMoved(pos)),
            TouchAction::Up => {
                out.push(egui::Event::PointerButton {
                    pos,
                    button: egui::PointerButton::Primary,
                    pressed: false,
                    modifiers: self.held.modifiers(),
                });
                self.touch = None;
            }
            TouchAction::Cancel => {
                self.touch = None;
                out.push(egui::Event::PointerGone);
            }
        }
    }

    fn mouse(
        &mut self,
        action: MouseAction,
        x: f32,
        y: f32,
        button: MouseButton,
        out: &mut Vec<egui::Event>,
    ) {
        let pos = Pos2::new(x, y);
        self.pointer = Some(pos);
        let pressed = match action {
            MouseAction::Press => Some(true),
            MouseAction::Release => Some(false),
            _ => None,
        };
        out.push(egui::Event::PointerMoved(pos));
        if let Some(pressed) = pressed {
            out.push(egui::Event::PointerButton {
                pos,
                button: match button {
                    MouseButton::Left => egui::PointerButton::Primary,
                    MouseButton::Right => egui::PointerButton::Secondary,
                    MouseButton::Middle => egui::PointerButton::Middle,
                    MouseButton::Back => egui::PointerButton::Extra1,
                    MouseButton::Forward => egui::PointerButton::Extra2,
                },
                pressed,
                modifiers: self.held.modifiers(),
            });
        }
        if action == MouseAction::Cancel {
            out.push(egui::Event::PointerGone);
        }
    }

    fn key(&mut self, action: KeyAction, code: i32, out: &mut Vec<egui::Event>) {
        let before = self.held;
        self.track_modifier(action, code);
        if self.held.modifiers() != before.modifiers() {
            out.push(egui::Event::ModifiersChanged(self.held.modifiers()));
        }
        let Some(key) = key_for(code) else {
            return;
        };
        let pressed = action == KeyAction::Down;
        out.push(egui::Event::Key {
            key,
            physical_key: None,
            pressed,
            repeat: false,
            modifiers: self.held.modifiers(),
        });
        // A soft keyboard or an input method commits text through `keyText`,
        // which ArkTS forwards; without that bridge, printable keys are typed
        // here so a hardware keyboard still writes. Enter and Tab are keys
        // the text field handles itself and must not also insert text.
        if pressed
            && !self.text_bridge
            && let Some(text) = typed_text(code, self.held.shift, self.held.caps_lock)
        {
            out.push(egui::Event::Text(text));
        }
    }

    fn track_modifier(&mut self, action: KeyAction, code: i32) {
        let pressed = action == KeyAction::Down;
        match code {
            2047 | 2048 => self.held.shift = pressed,
            2072 | 2073 => self.held.ctrl = pressed,
            2045 | 2046 => self.held.alt = pressed,
            2076 | 2077 => self.held.meta = pressed,
            2074 => self.held.caps_lock ^= pressed,
            _ => {}
        }
    }

    fn axis(
        &mut self,
        horizontal: f32,
        vertical: f32,
        scroll_step: f32,
        mouse: bool,
        out: &mut Vec<egui::Event>,
    ) {
        // A mouse wheel reports degrees (about 15 per notch) and includes the
        // user's scroll step; a touchpad reports an increment in pixels.
        // egui takes wheel notches in lines and touchpads in points, and its
        // delta is how far the content moves. ArkUI reports a positive
        // vertical axis for a backward scroll (content down), which is egui's
        // positive direction too. A touch surface moving two fingers up
        // reveals content below, which is egui's negative direction.
        let (unit, delta) = if mouse {
            // A notch reports 15 degrees times the user's scroll step.
            let per_notch = 15.0 * if scroll_step > 0.0 { scroll_step } else { 1.0 };
            (
                egui::MouseWheelUnit::Line,
                Vec2::new(-horizontal / per_notch, vertical / per_notch),
            )
        } else {
            (
                egui::MouseWheelUnit::Point,
                Vec2::new(-horizontal, -vertical),
            )
        };
        out.push(egui::Event::MouseWheel {
            unit,
            delta,
            phase: TouchPhase::Move,
            modifiers: self.held.modifiers(),
        });
    }
}

/// The egui key an ArkUI key code names, if it names one.
pub fn key_for(code: i32) -> Option<Key> {
    Some(match code {
        2000 => Key::Num0,
        2001 => Key::Num1,
        2002 => Key::Num2,
        2003 => Key::Num3,
        2004 => Key::Num4,
        2005 => Key::Num5,
        2006 => Key::Num6,
        2007 => Key::Num7,
        2008 => Key::Num8,
        2009 => Key::Num9,
        2012 => Key::ArrowUp,
        2013 => Key::ArrowDown,
        2014 => Key::ArrowLeft,
        2015 => Key::ArrowRight,
        2016 => Key::Enter,
        2042 => Key::Z,
        2017 => Key::A,
        2018 => Key::B,
        2019 => Key::C,
        2020 => Key::D,
        2021 => Key::E,
        2022 => Key::F,
        2023 => Key::G,
        2024 => Key::H,
        2025 => Key::I,
        2026 => Key::J,
        2027 => Key::K,
        2028 => Key::L,
        2029 => Key::M,
        2030 => Key::N,
        2031 => Key::O,
        2032 => Key::P,
        2033 => Key::Q,
        2034 => Key::R,
        2035 => Key::S,
        2036 => Key::T,
        2037 => Key::U,
        2038 => Key::V,
        2039 => Key::W,
        2040 => Key::X,
        2041 => Key::Y,
        2043 => Key::Comma,
        2044 => Key::Period,
        2045 => Key::AltLeft,
        2046 => Key::AltRight,
        2047 => Key::ShiftLeft,
        2048 => Key::ShiftRight,
        2049 => Key::Tab,
        2050 => Key::Space,
        2054 => Key::Enter,
        2055 => Key::Backspace,
        2056 => Key::Backtick,
        2057 => Key::Minus,
        2058 => Key::Equals,
        2059 => Key::OpenBracket,
        2060 => Key::CloseBracket,
        2061 => Key::Backslash,
        2062 => Key::Semicolon,
        2063 => Key::Quote,
        2064 => Key::Slash,
        2066 => Key::Plus,
        2068 => Key::PageUp,
        2069 => Key::PageDown,
        2070 => Key::Escape,
        2071 => Key::Delete,
        2072 => Key::ControlLeft,
        2073 => Key::ControlRight,
        2076 => Key::SuperLeft,
        2077 => Key::SuperRight,
        2081 => Key::Home,
        2082 => Key::End,
        2083 => Key::Insert,
        2090 => Key::F1,
        2091 => Key::F2,
        2092 => Key::F3,
        2093 => Key::F4,
        2094 => Key::F5,
        2095 => Key::F6,
        2096 => Key::F7,
        2097 => Key::F8,
        2098 => Key::F9,
        2099 => Key::F10,
        2100 => Key::F11,
        2101 => Key::F12,
        _ => return None,
    })
}

/// The text a printable key types with the given modifiers, in the US layout
/// the physical key codes follow. Letters honour Caps Lock and Shift, as a
/// keyboard does.
pub fn typed_text(code: i32, shift: bool, caps_lock: bool) -> Option<String> {
    let letter = (2017..=2042).contains(&code);
    if letter {
        let offset = u8::try_from(code - 2017).ok()?;
        let base = b'a' + offset;
        let upper = shift ^ caps_lock;
        let character = if upper {
            base.to_ascii_uppercase()
        } else {
            base
        };
        return Some(char::from(character).to_string());
    }
    let character = match code {
        2000..=2009 => {
            let digit = u8::try_from(code - 2000).ok()?;
            let unshifted = char::from(b'0' + digit);
            let shifted = match digit {
                0 => ')',
                1 => '!',
                2 => '@',
                3 => '#',
                4 => '$',
                5 => '%',
                6 => '^',
                7 => '&',
                8 => '*',
                9 => '(',
                _ => return None,
            };
            if shift { shifted } else { unshifted }
        }
        2050 => ' ',
        2043 => {
            if shift {
                '<'
            } else {
                ','
            }
        }
        2044 => {
            if shift {
                '>'
            } else {
                '.'
            }
        }
        2056 => {
            if shift {
                '~'
            } else {
                '`'
            }
        }
        2057 => {
            if shift {
                '_'
            } else {
                '-'
            }
        }
        2058 => {
            if shift {
                '+'
            } else {
                '='
            }
        }
        2059 => {
            if shift {
                '{'
            } else {
                '['
            }
        }
        2060 => {
            if shift {
                '}'
            } else {
                ']'
            }
        }
        2061 => {
            if shift {
                '|'
            } else {
                '\\'
            }
        }
        2062 => {
            if shift {
                ':'
            } else {
                ';'
            }
        }
        2063 => {
            if shift {
                '"'
            } else {
                '\''
            }
        }
        2064 => {
            if shift {
                '?'
            } else {
                '/'
            }
        }
        2010 => '*',
        _ => return None,
    };
    Some(character.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn push(input: &mut Input, event: OsEvent) -> Vec<egui::Event> {
        let mut out = Vec::new();
        input.push(event, &mut out);
        out
    }

    #[test]
    fn a_letter_key_types_its_character() {
        let mut input = Input::default();
        let events = push(
            &mut input,
            OsEvent::Key {
                action: KeyAction::Down,
                code: 2017,
            },
        );
        assert!(events.contains(&egui::Event::Text("a".to_owned())));
        assert!(events.iter().any(|event| matches!(
            event,
            egui::Event::Key {
                key: egui::Key::A,
                pressed: true,
                ..
            }
        )));
    }

    #[test]
    fn shift_types_a_capital() {
        let mut input = Input::default();
        push(
            &mut input,
            OsEvent::Key {
                action: KeyAction::Down,
                code: 2047,
            },
        );
        let events = push(
            &mut input,
            OsEvent::Key {
                action: KeyAction::Down,
                code: 2017,
            },
        );
        assert!(events.contains(&egui::Event::Text("A".to_owned())));
    }

    #[test]
    fn text_from_the_bridge_is_not_typed_twice() {
        let mut input = Input::default();
        let text = push(&mut input, OsEvent::Text("é".to_owned()));
        assert_eq!(text, vec![egui::Event::Text("é".to_owned())]);
        // The bridge carried this key, so the printable key adds no text.
        let key = push(
            &mut input,
            OsEvent::Key {
                action: KeyAction::Down,
                code: 2020,
            },
        );
        assert!(
            !key.iter()
                .any(|event| matches!(event, egui::Event::Text(_)))
        );
    }

    #[test]
    fn enter_is_a_key_and_never_a_character() {
        let mut input = Input::default();
        let events = push(
            &mut input,
            OsEvent::Key {
                action: KeyAction::Down,
                code: 2054,
            },
        );
        assert!(
            !events
                .iter()
                .any(|event| matches!(event, egui::Event::Text(_)))
        );
        assert!(events.iter().any(|event| matches!(
            event,
            egui::Event::Key {
                key: egui::Key::Enter,
                pressed: true,
                ..
            }
        )));
    }

    #[test]
    fn a_touch_presses_and_lifts_the_primary_button() {
        let mut input = Input::default();
        let down = push(
            &mut input,
            OsEvent::Touch {
                action: TouchAction::Down,
                id: 0,
                x: 12.0,
                y: 34.0,
                force: 0.5,
            },
        );
        assert!(down.contains(&egui::Event::PointerMoved(egui::pos2(12.0, 34.0))));
        assert!(down.iter().any(|event| matches!(
            event,
            egui::Event::PointerButton {
                pressed: true,
                button: egui::PointerButton::Primary,
                ..
            }
        )));
        let up = push(
            &mut input,
            OsEvent::Touch {
                action: TouchAction::Up,
                id: 0,
                x: 12.0,
                y: 34.0,
                force: 0.0,
            },
        );
        assert!(up.iter().any(|event| matches!(
            event,
            egui::Event::PointerButton {
                pressed: false,
                button: egui::PointerButton::Primary,
                ..
            }
        )));
    }

    fn wheel(mouse: bool, vertical: f32, scroll_step: f32) -> egui::Event {
        let mut input = Input::default();
        let events = push(
            &mut input,
            OsEvent::Axis {
                horizontal: 0.0,
                vertical,
                scroll_step,
                mouse,
            },
        );
        events.into_iter().next().expect("one wheel event")
    }

    #[test]
    fn a_wheel_notch_is_one_line() {
        // 15 degrees a notch, times the configured step of 3.
        match wheel(true, 45.0, 3.0) {
            egui::Event::MouseWheel { unit, delta, .. } => {
                assert_eq!(unit, egui::MouseWheelUnit::Line);
                assert!((delta.y - 1.0).abs() < 1e-6, "{delta:?}");
            }
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn a_backward_wheel_moves_the_content_down() {
        match wheel(true, 15.0, 0.0) {
            egui::Event::MouseWheel { delta, .. } => {
                assert!(delta.y > 0.0, "{delta:?}");
            }
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn a_touchpad_swipe_is_in_points_and_scrolls_up() {
        match wheel(false, 40.0, 0.0) {
            egui::Event::MouseWheel { unit, delta, .. } => {
                assert_eq!(unit, egui::MouseWheelUnit::Point);
                assert!(delta.y < 0.0, "{delta:?}");
            }
            other => panic!("{other:?}"),
        }
    }
}
