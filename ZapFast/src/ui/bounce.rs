//! A scroll area with a spring edge, the way HarmonyOS lists and carousels
//! answer a finger that keeps going past the first or last item.
//!
//! egui clamps a scroll offset to the content, so the edge has to be drawn by
//! passing an offset past the clamp and letting the scroll area clamp its
//! stored state again afterwards. [`ScrollArea`] wraps `egui::ScrollArea`,
//! notices the wheel or touchpad delta that the area could not use at its
//! edge, spends it on a small displacement, and pulls that displacement back
//! with a damped spring.
//!
//! Every list, picker, dialog and media strip uses this wrapper, so the edge
//! behaves the same in all of them, with a smaller limit on the sideways
//! strips than on the vertical lists.

use egui::{
    Id, IdSalt, Rect, Ui, Vec2, Vec2b,
    scroll_area::{ScrollAreaOutput, ScrollBarVisibility, ScrollSource},
};

/// How hard the spring pulls the content back to the edge.
const STIFFNESS: f32 = 225.0;
/// Critical damping: no overshoot, so the edge settles instead of wobbling.
const DAMPING: f32 = 30.0;
/// How long after the last input the displaced content is released. Short
/// enough to feel immediate, long enough that a stream of touchpad events is
/// one gesture rather than a series of starts and stops.
const RELEASE_AFTER: f64 = 0.06;
/// The physics step, independent of the frame time, so a slow or jittery
/// frame cannot make the spring ring.
const PHYSICS_STEP: f32 = 1.0 / 120.0;
/// The furthest a vertical list may be pulled, in points.
const MAX_VERTICAL: f32 = 80.0;
/// The furthest a sideways strip may be pulled, in points.
const MAX_HORIZONTAL: f32 = 48.0;
/// How much of the unused scroll delta becomes displacement. The rest is the
/// rubber band's resistance.
const RESISTANCE: f32 = 0.35;
/// Below these the spring has come to rest.
const REST_POSITION: f32 = 0.25;
const REST_SPEED: f32 = 2.0;

/// The displacement and velocity of one scroll area's edge, plus what the
/// last frame knew about its bounds.
#[derive(Clone, Copy)]
struct BounceState {
    position: Vec2,
    velocity: Vec2,
    /// Where the current gesture wants the content. Input moves this target;
    /// the spring follows it, so a bursty touchpad event stream is smoothed
    /// out. After [`RELEASE_AFTER`] without input the target returns to zero.
    target: Vec2,
    /// Input time of the last overscroll movement.
    last_input: f64,
    /// The stored offset and the furthest it could be, from the last frame.
    base: Vec2,
    max: Vec2,
    enabled: Vec2b,
    /// The frame the spring last advanced, so extra layout passes do not make
    /// it move two or three times per painted frame.
    frame: u64,
}

impl Default for BounceState {
    fn default() -> Self {
        Self {
            position: Vec2::ZERO,
            velocity: Vec2::ZERO,
            target: Vec2::ZERO,
            last_input: f64::NEG_INFINITY,
            base: Vec2::ZERO,
            max: Vec2::ZERO,
            enabled: Vec2b::FALSE,
            frame: 0,
        }
    }
}

impl BounceState {
    fn limit(&self) -> Vec2 {
        Vec2::new(
            if self.enabled.x { MAX_HORIZONTAL } else { 0.0 },
            if self.enabled.y { MAX_VERTICAL } else { 0.0 },
        )
    }

    fn clamp_position(&mut self) {
        let limit = self.limit();
        self.position = Vec2::new(
            self.position.x.clamp(-limit.x, limit.x),
            self.position.y.clamp(-limit.y, limit.y),
        );
        self.target = Vec2::new(
            self.target.x.clamp(-limit.x, limit.x),
            self.target.y.clamp(-limit.y, limit.y),
        );
    }

    fn tick(&mut self, dt: f32, now: f64) {
        if now - self.last_input > RELEASE_AFTER {
            self.target = Vec2::ZERO;
        }
        if self.position == Vec2::ZERO && self.velocity == Vec2::ZERO && self.target == Vec2::ZERO {
            return;
        }
        // Sub-step so the result does not depend on how long the last frame
        // took. A frame longer than 50 ms is clamped by the caller.
        let mut remaining = dt;
        while remaining > 0.0 {
            let step = remaining.min(PHYSICS_STEP);
            let acceleration = (self.target - self.position) * STIFFNESS - self.velocity * DAMPING;
            self.velocity += acceleration * step;
            self.position += self.velocity * step;
            remaining -= step;
        }
        self.clamp_position();
        if self.target == Vec2::ZERO
            && self.position.length() < REST_POSITION
            && self.velocity.length() < REST_SPEED
        {
            self.position = Vec2::ZERO;
            self.velocity = Vec2::ZERO;
        }
    }

    fn active(&self) -> bool {
        self.position != Vec2::ZERO || self.velocity != Vec2::ZERO || self.target != Vec2::ZERO
    }

    /// The offset to hand the inner scroll area for this frame, if the edge is
    /// still where the spring started.
    fn offsets(&mut self) -> (Option<f32>, Option<f32>) {
        let mut x = None;
        let mut y = None;
        if self.enabled.x && self.position.x != 0.0 && self.max.x > 0.0 {
            if self.position.x > 0.0 && self.base.x <= 0.5 {
                x = Some(-self.position.x);
            } else if self.position.x < 0.0 && self.base.x >= self.max.x - 0.5 {
                x = Some(self.max.x - self.position.x);
            } else {
                self.position.x = 0.0;
                self.velocity.x = 0.0;
            }
        }
        if self.enabled.y && self.position.y != 0.0 && self.max.y > 0.0 {
            if self.position.y > 0.0 && self.base.y <= 0.5 {
                y = Some(-self.position.y);
            } else if self.position.y < 0.0 && self.base.y >= self.max.y - 0.5 {
                y = Some(self.max.y - self.position.y);
            } else {
                self.position.y = 0.0;
                self.velocity.y = 0.0;
            }
        }
        (x, y)
    }
}

/// Keeps the auto-salts of scroll areas that do not name one stable from frame
/// to frame.
#[derive(Clone, Copy, Default)]
struct AutoSalts {
    pass: u64,
    next: u64,
}

/// The bounce-aware equivalent of [`egui::ScrollArea`].
pub struct ScrollArea {
    inner: egui::ScrollArea,
    enabled: Vec2b,
    key_salt: Option<IdSalt>,
}

impl ScrollArea {
    pub fn vertical() -> Self {
        Self::new(Vec2b::new(false, true))
    }

    pub fn horizontal() -> Self {
        Self::new(Vec2b::new(true, false))
    }

    pub fn both() -> Self {
        Self::new(Vec2b::TRUE)
    }

    fn new(enabled: Vec2b) -> Self {
        Self {
            inner: egui::ScrollArea::new(enabled),
            enabled,
            key_salt: None,
        }
    }

    pub fn id_salt(mut self, salt: impl egui::AsIdSalt) -> Self {
        // The same salt identifies the scroll state and the spring. Hashing a
        // borrow gives the same value the inner area hashes.
        self.key_salt = Some(IdSalt::new(&salt));
        self.inner = self.inner.id_salt(salt);
        self
    }

    pub fn auto_shrink(mut self, auto_shrink: impl Into<Vec2b>) -> Self {
        self.inner = self.inner.auto_shrink(auto_shrink);
        self
    }

    pub fn max_height(mut self, max_height: f32) -> Self {
        self.inner = self.inner.max_height(max_height);
        self
    }

    pub fn max_width(mut self, max_width: f32) -> Self {
        self.inner = self.inner.max_width(max_width);
        self
    }

    pub fn min_scrolled_height(mut self, height: f32) -> Self {
        self.inner = self.inner.min_scrolled_height(height);
        self
    }

    pub fn min_scrolled_width(mut self, width: f32) -> Self {
        self.inner = self.inner.min_scrolled_width(width);
        self
    }

    pub fn stick_to_bottom(mut self, stick: bool) -> Self {
        self.inner = self.inner.stick_to_bottom(stick);
        self
    }

    pub fn scroll_source(mut self, source: ScrollSource) -> Self {
        self.inner = self.inner.scroll_source(source);
        self
    }

    pub fn animated(mut self, animated: bool) -> Self {
        self.inner = self.inner.animated(animated);
        self
    }

    pub fn scroll_bar_visibility(mut self, visibility: ScrollBarVisibility) -> Self {
        self.inner = self.inner.scroll_bar_visibility(visibility);
        self
    }

    pub fn scroll_offset(mut self, offset: Vec2) -> Self {
        self.inner = self.inner.scroll_offset(offset);
        self
    }

    pub fn vertical_scroll_offset(mut self, offset: f32) -> Self {
        self.inner = self.inner.vertical_scroll_offset(offset);
        self
    }

    pub fn horizontal_scroll_offset(mut self, offset: f32) -> Self {
        self.inner = self.inner.horizontal_scroll_offset(offset);
        self
    }

    pub fn on_hover_cursor(mut self, cursor: egui::CursorIcon) -> Self {
        self.inner = self.inner.on_hover_cursor(cursor);
        self
    }

    pub fn on_drag_cursor(mut self, cursor: egui::CursorIcon) -> Self {
        self.inner = self.inner.on_drag_cursor(cursor);
        self
    }

    pub fn show<R>(
        mut self,
        ui: &mut Ui,
        add_contents: impl FnOnce(&mut Ui) -> R,
    ) -> ScrollAreaOutput<R> {
        let (key, mut state) = self.begin(ui);
        self.apply_offsets(&mut state);
        let output = self.inner.show(ui, add_contents);
        Self::finish(self.enabled, ui, key, state, &output);
        output
    }

    pub fn show_rows<R>(
        mut self,
        ui: &mut Ui,
        row_height_sans_spacing: f32,
        total_rows: usize,
        add_contents: impl FnOnce(&mut Ui, std::ops::Range<usize>) -> R,
    ) -> ScrollAreaOutput<R> {
        let (key, mut state) = self.begin(ui);
        self.apply_offsets(&mut state);
        let output = self
            .inner
            .show_rows(ui, row_height_sans_spacing, total_rows, add_contents);
        Self::finish(self.enabled, ui, key, state, &output);
        output
    }

    pub fn show_viewport<R>(
        mut self,
        ui: &mut Ui,
        add_contents: impl FnOnce(&mut Ui, Rect) -> R,
    ) -> ScrollAreaOutput<R> {
        let (key, mut state) = self.begin(ui);
        self.apply_offsets(&mut state);
        let output = self.inner.show_viewport(ui, add_contents);
        Self::finish(self.enabled, ui, key, state, &output);
        output
    }

    /// The key of this scroll area's spring. Named salts are shared with the
    /// scroll state; unnamed ones follow the order of the unnamed areas.
    fn key(&self, ui: &mut Ui) -> Id {
        if let Some(salt) = self.key_salt {
            ui.id().with(salt)
        } else {
            let pass = ui.ctx().cumulative_pass_nr();
            let counter_id = Id::new("zapfast-scroll-bounce-auto");
            let mut auto = ui
                .ctx()
                .data(|data| data.get_temp::<AutoSalts>(counter_id))
                .unwrap_or_default();
            if auto.pass != pass {
                auto.pass = pass;
                auto.next = 0;
            }
            let key = ui.id().with(("zapfast-scroll-bounce", auto.next));
            auto.next = auto.next.saturating_add(1);
            ui.ctx().data_mut(|data| data.insert_temp(counter_id, auto));
            key
        }
    }

    fn begin(&self, ui: &mut Ui) -> (Id, BounceState) {
        let key = self.key(ui);
        let mut state = ui
            .ctx()
            .data(|data| data.get_temp::<BounceState>(key))
            .unwrap_or_default();
        state.enabled = self.enabled;
        let frame = ui.ctx().cumulative_frame_nr();
        if state.frame != frame {
            state.frame = frame;
            let dt = ui.input(|input| input.stable_dt).clamp(0.001, 0.05);
            let now = ui.input(|input| input.time);
            state.tick(dt, now);
        }
        if state.active() {
            ui.ctx().request_repaint();
        }
        (key, state)
    }

    fn apply_offsets(&mut self, state: &mut BounceState) {
        let (x, y) = state.offsets();
        let inner = std::mem::replace(&mut self.inner, egui::ScrollArea::neither());
        self.inner = match (x, y) {
            (Some(x), Some(y)) => inner.scroll_offset(Vec2::new(x, y)),
            (Some(x), None) => inner.horizontal_scroll_offset(x),
            (None, Some(y)) => inner.vertical_scroll_offset(y),
            (None, None) => inner,
        };
    }

    fn finish<R>(
        enabled: Vec2b,
        ui: &mut Ui,
        key: Id,
        mut state: BounceState,
        output: &ScrollAreaOutput<R>,
    ) {
        state.base = output.state.offset;
        state.max = (output.content_size - output.inner_rect.size()).max(Vec2::ZERO);
        if ui.is_enabled() && ui.rect_contains_pointer(output.inner_rect) {
            let delta = ui.input(|input| input.smooth_scroll_delta);
            let mut used = Vec2::ZERO;
            if enabled.x && state.max.x > 0.0 {
                if state.base.x <= 0.5 && delta.x > 0.0 {
                    state.target.x += delta.x * RESISTANCE;
                    used.x = delta.x;
                } else if state.base.x >= state.max.x - 0.5 && delta.x < 0.0 {
                    state.target.x += delta.x * RESISTANCE;
                    used.x = delta.x;
                }
            }
            if enabled.y && state.max.y > 0.0 {
                if state.base.y <= 0.5 && delta.y > 0.0 {
                    state.target.y += delta.y * RESISTANCE;
                    used.y = delta.y;
                } else if state.base.y >= state.max.y - 0.5 && delta.y < 0.0 {
                    state.target.y += delta.y * RESISTANCE;
                    used.y = delta.y;
                }
            }
            if used != Vec2::ZERO {
                ui.input_mut(|input| {
                    input.smooth_scroll_delta -= used;
                });
                state.clamp_position();
                state.last_input = ui.input(|input| input.time);
                // The spring starts moving next frame.
                ui.ctx().request_repaint();
            }
        }
        ui.ctx().data_mut(|data| data.insert_temp(key, state));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_spring_comes_back_to_the_edge() {
        let mut state = BounceState {
            enabled: Vec2b::TRUE,
            ..Default::default()
        };
        state.position = Vec2::new(40.0, -60.0);
        for _ in 0..240 {
            state.tick(1.0 / 120.0, 0.0);
        }
        assert_eq!(state.position, Vec2::ZERO);
        assert_eq!(state.velocity, Vec2::ZERO);
    }

    #[test]
    fn the_spring_does_not_pass_its_limit() {
        let mut state = BounceState {
            enabled: Vec2b::TRUE,
            ..Default::default()
        };
        state.position = Vec2::new(500.0, -500.0);
        state.clamp_position();
        assert_eq!(state.position, Vec2::new(MAX_HORIZONTAL, -MAX_VERTICAL));
    }
}
