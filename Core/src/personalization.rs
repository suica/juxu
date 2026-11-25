use crate::neural::{NeuralView, RwkvState};
use std::collections::HashMap;
use std::fmt::Write;

const CONTEXT_MASK: u64 = 0xFFFF_FFFF_FFFF;
const MAX_CONTEXTS: usize = 4_096;
const CONTEXTS_AFTER_PRUNE: usize = 3_072;
const HALF_LIFE: f32 = 2_048.0;
const OPTIONS_PER_CONTEXT: usize = 4;
const STATE_SAMPLES_PER_CONTEXT: usize = 4;
const STATE_NEIGHBORHOOD: u32 = 5;
const MAX_STATE_DISTANCE: u32 = 22;

fn han(c: char) -> bool {
    ('\u{3400}'..='\u{9fff}').contains(&c)
}

/// Up to three preceding Han characters, independent of the decoder's word boundaries.
#[derive(Clone, Copy, Default)]
pub(crate) struct Context(u64);

impl Context {
    pub fn with_chars(chars: impl IntoIterator<Item = char>) -> Self {
        chars.into_iter().fold(Self::default(), Self::push)
    }

    pub fn push(self, c: char) -> Self {
        if han(c) {
            Self(((self.0 << 16) | c as u64) & CONTEXT_MASK)
        } else {
            Self::default()
        }
    }

    fn suffixes(self) -> impl Iterator<Item = (u64, f32)> {
        [0.50, 1.10, 1.65]
            .into_iter()
            .enumerate()
            .zip([0xFFFF, 0xFFFF_FFFF, CONTEXT_MASK])
            .take_while(move |&((i, _), _)| self.0 >> (16 * i) != 0)
            .map(move |((_, limit), mask)| (self.0 & mask, limit))
    }

    fn three_chars(self) -> Option<u64> {
        (self.0 > u32::MAX as u64).then_some(self.0)
    }
}

#[derive(Clone, Copy, Default)]
struct Continuation {
    ch: u16,
    weight: f32,
}

#[derive(Clone, Copy, Default)]
struct StateSample {
    signature: u128,
    continuation: Continuation,
}

pub(crate) fn state_signature(state: &RwkvState) -> u128 {
    // Signs of the next-token projection retain similarities between RWKV states.
    // The projection has already seen the whole available prefix.
    state
        .p1_q
        .iter()
        .take(128)
        .enumerate()
        .fold(0, |bits, (i, &q)| bits | (u128::from(q > 0) << i))
}

#[derive(Clone, Default)]
pub(crate) struct Counts {
    tick: u64,
    total: f32,
    options: [Continuation; OPTIONS_PER_CONTEXT],
    states: [StateSample; STATE_SAMPLES_PER_CONTEXT],
}

#[derive(Clone, Default)]
pub(crate) struct ContinuationUndo {
    prev_tick: u64,
    prev_uni_tick: u64,
    prev_uni_total: f32,
    prev_state_model: Option<u64>,
    rows: Vec<(u64, Option<Counts>)>,
    unigrams: Vec<(u16, Option<(u64, f32)>)>,
}

impl Counts {
    fn decay(&self, now: u64) -> f32 {
        (-(now.saturating_sub(self.tick) as f32) / HALF_LIFE).exp2()
    }

    fn observe(&mut self, ch: u16, weight: f32, now: u64) {
        let decay = self.decay(now);
        self.tick = now;
        let scale = if self.total * decay > 64.0 {
            32.0 / self.total
        } else {
            decay
        };
        self.total *= scale;
        for option in self
            .options
            .iter_mut()
            .chain(self.states.iter_mut().map(|s| &mut s.continuation))
        {
            option.weight *= scale;
        }
        self.total += weight;
        let index = self
            .options
            .iter()
            .position(|option| option.ch == ch)
            .unwrap_or_else(|| {
                self.options
                    .iter()
                    .enumerate()
                    .min_by(|(_, a), (_, b)| a.weight.total_cmp(&b.weight))
                    .map_or(0, |(index, _)| index)
            });
        let option = &mut self.options[index];
        if option.ch != ch {
            *option = Continuation { ch, weight: 0.0 };
        }
        option.weight += weight;
    }

    fn observe_state(&mut self, ch: u16, signature: u128, weight: f32) {
        if let Some(sample) = self.states.iter_mut().find(|sample| {
            sample.continuation.ch == ch
                && (sample.signature ^ signature).count_ones() <= STATE_NEIGHBORHOOD
        }) {
            sample.continuation.weight += weight;
            return;
        }
        if let Some(slot) = self
            .states
            .iter_mut()
            .min_by(|a, b| a.continuation.weight.total_cmp(&b.continuation.weight))
        {
            *slot = StateSample {
                signature,
                continuation: Continuation { ch, weight },
            };
        }
    }

    fn score(&self, ch: u16, limit: f32, now: u64) -> f32 {
        let Some(option) = self.options.iter().find(|option| option.ch == ch) else {
            return 0.0;
        };
        let decay = self.decay(now);
        let weight = option.weight * decay;
        let support = weight / (weight + 3.0);
        let preference = weight / (self.total * decay + 1.0);
        limit * support * preference
    }

    /// Compute `(nearest_distance, weighted_support, weighted_matches)` across kNN state samples.
    fn knn_state_stats(&self, sig: u128, ch: u16, decay: f32) -> Option<(u32, f32, f32)> {
        let mut nearest = u32::MAX;
        for sample in &self.states {
            if sample.continuation.ch == 0 {
                continue;
            }
            let w = sample.continuation.weight * decay;
            if w < 0.1 {
                continue;
            }
            let dist = (sample.signature ^ sig).count_ones();
            if dist <= MAX_STATE_DISTANCE && dist < nearest {
                nearest = dist;
            }
        }
        if nearest == u32::MAX {
            return None;
        }
        let mut support = 0.0f32;
        let mut matches = 0.0f32;
        for sample in &self.states {
            if sample.continuation.ch == 0 {
                continue;
            }
            let w = sample.continuation.weight * decay;
            if w < 0.1 {
                continue;
            }
            let dist = (sample.signature ^ sig).count_ones();
            if dist <= nearest + STATE_NEIGHBORHOOD {
                let dw = w / (1.0 + (dist - nearest) as f32);
                support += dw;
                if sample.continuation.ch == ch {
                    matches += dw;
                }
            }
        }
        (support > 0.0).then_some((nearest, support, matches))
    }

    fn state_bonus(&self, ch: u16, state: &RwkvState, now: u64) -> f32 {
        if !self
            .states
            .iter()
            .any(|sample| sample.continuation.ch == ch)
        {
            return 0.0;
        }
        let decay = self.decay(now);
        let Some((nearest, support, matches)) =
            self.knn_state_stats(state_signature(state), ch, decay)
        else {
            return 0.0;
        };
        let similarity = 1.0 - nearest as f32 / 32.0;
        2.25 * similarity * (support / (support + 3.0)) * (matches / (support + 1.0))
    }

    /// Estimate `(p_cache, lambda)` from suffix n-gram counts at this context row.
    fn cache_suffix_prob(&self, ch: u16, max_lambda: f32, support_k: f32, now: u64) -> (f32, f32) {
        let decay = self.decay(now);
        let total = self.total * decay;
        if total < 0.25 {
            return (0.0, 0.0);
        }
        let support = total / (total + support_k);
        let lambda = max_lambda * support;
        let w = self
            .options
            .iter()
            .find(|o| o.ch == ch)
            .map_or(0.0, |o| o.weight * decay);
        let p_cache = (w / (total + 0.5)).clamp(0.0, 0.99);
        (p_cache, lambda)
    }

    /// Estimate `(p_cache, lambda)` from RWKV `p1_q` 128-bit state-signature kNN samples.
    fn cache_state_prob(&self, ch: u16, state: &RwkvState, now: u64) -> (f32, f32) {
        let decay = self.decay(now);
        let Some((nearest, support, matches)) =
            self.knn_state_stats(state_signature(state), ch, decay)
        else {
            return (0.0, 0.0);
        };
        let similarity = (1.0 - nearest as f32 / 32.0).clamp(0.0, 1.0);
        let lambda = 0.68 * similarity * (support / (support + 1.5));
        let p_cache = (matches / (support + 0.5)).clamp(0.0, 0.99);
        (p_cache, lambda)
    }
}

const MAX_UNIGRAMS: usize = 1_024;
const UNIGRAMS_AFTER_PRUNE: usize = 768;

#[derive(Default)]
pub(crate) struct PersonalContinuations {
    tick: u64,
    rows: HashMap<u64, Counts>,
    /// 0-gram personal unigram prior `(last_tick, weight)` so rare sentence-initial characters
    /// survive pure-char beam search after a single explicit selection without phrase dictionary rules.
    unigrams: HashMap<u16, (u64, f32)>,
    uni_tick: u64,
    uni_total: f32,
    state_model: Option<u64>,
}

impl PersonalContinuations {
    pub fn is_empty(&self) -> bool {
        self.rows.is_empty() && self.unigrams.is_empty()
    }

    pub fn matches_model(&self, view: &NeuralView<'_>) -> bool {
        self.state_model == Some(view.offs.profile_id)
    }

    /// Capture a compact undo record (`< 1 KB`) of all context rows and unigram slots that would
    /// be touched when observing `(prefix, text)`, enabling instant exact rollback on Backspace.
    pub fn capture_undo_before(&self, prefix: &[char], text: &str) -> ContinuationUndo {
        let mut rows = Vec::new();
        let mut unigrams = Vec::new();
        let mut context = Context::with_chars(prefix.iter().copied());
        for ch in text.chars() {
            if han(ch) {
                let ch_u16 = ch as u16;
                if !unigrams.iter().any(|&(k, _)| k == ch_u16) {
                    unigrams.push((ch_u16, self.unigrams.get(&ch_u16).copied()));
                }
                for (key, _) in context.suffixes() {
                    if !rows.iter().any(|&(k, _)| k == key) {
                        rows.push((key, self.rows.get(&key).cloned()));
                    }
                }
            }
            context = context.push(ch);
        }
        ContinuationUndo {
            prev_tick: self.tick,
            prev_uni_tick: self.uni_tick,
            prev_uni_total: self.uni_total,
            prev_state_model: self.state_model,
            rows,
            unigrams,
        }
    }

    pub fn apply_undo(&mut self, undo: ContinuationUndo) {
        self.tick = undo.prev_tick;
        self.uni_tick = undo.prev_uni_tick;
        self.uni_total = undo.prev_uni_total;
        self.state_model = undo.prev_state_model;
        for (key, prev_row) in undo.rows {
            if let Some(row) = prev_row {
                self.rows.insert(key, row);
            } else {
                self.rows.remove(&key);
            }
        }
        for (ch, prev_uni) in undo.unigrams {
            if let Some(val) = prev_uni {
                self.unigrams.insert(ch, val);
            } else {
                self.unigrams.remove(&ch);
            }
        }
    }

    fn observe_unigram(&mut self, ch: u16, weight: f32) {
        let decay = (-(self.tick.saturating_sub(self.uni_tick) as f32) / HALF_LIFE).exp2();
        self.uni_tick = self.tick;
        self.uni_total = (self.uni_total * decay).min(256.0) + weight;
        let entry = self.unigrams.entry(ch).or_insert((self.tick, 0.0));
        let edecay = (-(self.tick.saturating_sub(entry.0) as f32) / HALF_LIFE).exp2();
        entry.0 = self.tick;
        entry.1 = (entry.1 * edecay).min(32.0) + weight;
        if self.unigrams.len() > MAX_UNIGRAMS {
            let now = self.tick;
            let mut by_w: Vec<(u16, f32)> = self
                .unigrams
                .iter()
                .map(|(&k, &(t, w))| (k, w * (-(now.saturating_sub(t) as f32) / HALF_LIFE).exp2()))
                .collect();
            let remove = by_w.len() - UNIGRAMS_AFTER_PRUNE;
            by_w.select_nth_unstable_by(remove, |a, b| {
                a.1.total_cmp(&b.1).then_with(|| a.0.cmp(&b.0))
            });
            for (k, _) in by_w.into_iter().take(remove) {
                self.unigrams.remove(&k);
            }
        }
    }

    fn cache_unigram_prob(&self, ch: u16) -> (f32, f32) {
        let Some(&(etick, ew)) = self.unigrams.get(&ch) else {
            return (0.0, 0.0);
        };
        let edecay = (-(self.tick.saturating_sub(etick) as f32) / HALF_LIFE).exp2();
        let w = ew * edecay;
        if w < 0.25 {
            return (0.0, 0.0);
        }
        let tdecay = (-(self.tick.saturating_sub(self.uni_tick) as f32) / HALF_LIFE).exp2();
        let total = self.uni_total * tdecay;
        let p_uni = (w / (total.max(w) + 8.0)).clamp(0.0, 0.25);
        let lambda = 0.14 * (w / (w + 2.0));
        (p_uni, lambda)
    }

    #[allow(clippy::too_many_arguments)]
    fn observe_with<F>(
        &mut self,
        prefix: &[char],
        text: &str,
        confirmed: bool,
        first_choice: Option<&str>,
        profile_id: Option<u64>,
        mut on_char: F,
    ) where
        F: FnMut(usize, char, bool, Option<u64>, &mut HashMap<u64, Counts>, f32),
    {
        if let Some(pid) = profile_id {
            if self.state_model != Some(pid) {
                for row in self.rows.values_mut() {
                    row.states = [StateSample::default(); STATE_SAMPLES_PER_CONTEXT];
                }
                self.state_model = Some(pid);
            }
        }
        let base_weight = if confirmed { 1.0 } else { 0.25 };
        let mut context = Context::with_chars(prefix.iter().copied());
        let first_chars: Option<Vec<char>> = first_choice
            .filter(|&fc| fc != text)
            .map(|fc| fc.chars().collect());
        let mut diverged = false;
        for (idx, ch) in text.chars().enumerate() {
            let different = if let Some(ref fc) = first_chars {
                let d = fc.get(idx).copied() != Some(ch);
                if d {
                    diverged = true;
                }
                d || diverged
            } else {
                false
            };
            if han(ch) {
                self.tick = self.tick.saturating_add(1);
                let weight = if different {
                    base_weight + 2.5
                } else {
                    base_weight
                };
                for (key, _) in context.suffixes() {
                    self.rows
                        .entry(key)
                        .or_default()
                        .observe(ch as u16, weight, self.tick);
                }
                if different {
                    self.observe_unigram(ch as u16, 3.5);
                } else if confirmed && idx == 0 {
                    self.observe_unigram(ch as u16, 0.45);
                }
                on_char(idx, ch, true, context.three_chars(), &mut self.rows, weight);
            } else {
                on_char(idx, ch, false, None, &mut self.rows, 0.0);
            }
            context = context.push(ch);
        }
        if self.rows.len() > MAX_CONTEXTS {
            let mut by_weight: Vec<_> = self
                .rows
                .iter()
                .map(|(&key, row)| (key, row.total * row.decay(self.tick)))
                .collect();
            let remove = by_weight.len() - CONTEXTS_AFTER_PRUNE;
            by_weight.select_nth_unstable_by(remove, |a, b| {
                a.1.total_cmp(&b.1).then_with(|| a.0.cmp(&b.0))
            });
            for (key, _) in by_weight.into_iter().take(remove) {
                self.rows.remove(&key);
            }
        }
    }

    /// A rejected first choice increases evidence at every differing character.
    pub fn observe(
        &mut self,
        prefix: &[char],
        text: &str,
        confirmed: bool,
        first_choice: Option<&str>,
        mut neural: Option<(NeuralView<'_>, RwkvState)>,
    ) {
        let profile_id = neural.as_ref().map(|(view, _)| view.offs.profile_id);
        self.observe_with(
            prefix,
            text,
            confirmed,
            first_choice,
            profile_id,
            |_, ch, is_han, three_key, rows, weight| {
                if !is_han {
                    neural = None;
                    return;
                }
                if let Some((model, state)) = neural.as_mut() {
                    if let Some(key) = three_key {
                        if let Some(row) = rows.get_mut(&key) {
                            row.observe_state(ch as u16, state_signature(state), weight);
                        }
                    }
                    model.step_token(model.char_to_token(ch), state);
                }
            },
        );
    }

    /// Observe a committed pure-CJK sequence using pre-stepped `state_signature`s collected during
    /// a single shared commit unroll, avoiding redundant `step_token` calls on commit.
    pub fn observe_prestepped_sigs(
        &mut self,
        prefix: &[char],
        text: &str,
        confirmed: bool,
        first_choice: Option<&str>,
        profile_id: u64,
        pre_step_sigs: &[u128],
    ) {
        self.observe_with(
            prefix,
            text,
            confirmed,
            first_choice,
            Some(profile_id),
            |idx, ch, is_han, three_key, rows, weight| {
                if !is_han {
                    return;
                }
                if let (Some(key), Some(&sig)) = (three_key, pre_step_sigs.get(idx)) {
                    if let Some(row) = rows.get_mut(&key) {
                        row.observe_state(ch as u16, sig, weight);
                    }
                }
            },
        );
    }

    pub fn score(&self, mut context: Context, text: &str) -> f32 {
        let mut score = 0.0;
        for ch in text.chars() {
            if han(ch) {
                let mut best = 0.0f32;
                for (key, limit) in context.suffixes() {
                    if let Some(row) = self.rows.get(&key) {
                        best = best.max(row.score(ch as u16, limit, self.tick));
                    }
                }
                score += best;
            }
            context = context.push(ch);
        }
        score
    }

    pub fn state_bonus(&self, context: Context, ch: char, state: &RwkvState) -> f32 {
        let Some(row) = context.three_chars().and_then(|key| self.rows.get(&key)) else {
            return 0.0;
        };
        if !han(ch) {
            return 0.0;
        }
        row.state_bonus(ch as u16, state, self.tick)
    }

    /// Unified Neural Cache LM probability-space interpolation:
    /// `P_final(ch | h) = (1 - lambda) * exp(rwkv_logp) + lambda * P_cache(ch | h_sig, suffix, uni)`
    /// Returns the calibrated log-probability in nats.
    pub fn interpolate_logp(
        &self,
        rwkv_logp: f32,
        context: Context,
        ch: char,
        state: Option<&RwkvState>,
    ) -> f32 {
        if self.is_empty() || !han(ch) {
            return rwkv_logp;
        }
        let ch_u16 = ch as u16;
        let mut best_p = 0.0f32;
        let mut best_lambda = 0.0f32;

        // 1. Prefer RWKV state-signature kNN distribution at 3-char context when available
        if let Some(st) = state {
            if let Some(row) = context.three_chars().and_then(|key| self.rows.get(&key)) {
                let (p_st, l_st) = row.cache_state_prob(ch_u16, st, self.tick);
                if l_st > 0.04 {
                    best_p = p_st;
                    best_lambda = l_st;
                }
            }
        }

        // 2. Fall back to 1..=3 char suffix continuations when RWKV state kNN did not match.
        if best_lambda < 0.04 {
            let max_lambdas = [0.22f32, 0.58, 0.75];
            let support_ks = [2.5f32, 1.5, 1.5];
            for (idx, (key, _)) in context.suffixes().enumerate() {
                if let Some(row) = self.rows.get(&key) {
                    let i = idx.min(2);
                    let (p_suf, l_suf) =
                        row.cache_suffix_prob(ch_u16, max_lambdas[i], support_ks[i], self.tick);
                    if l_suf * p_suf > best_lambda * best_p
                        || (best_lambda < 0.04 && l_suf > best_lambda)
                    {
                        best_p = p_suf;
                        best_lambda = l_suf;
                    }
                }
            }
        }

        // 3. Fall back to 0-gram personal unigram prior ONLY for rare/surprising characters (`rwkv_logp < -5.5`).
        if best_lambda < 0.04 && rwkv_logp < -5.5 && !self.unigrams.is_empty() {
            let (p_uni, l_uni) = self.cache_unigram_prob(ch_u16);
            if l_uni * p_uni > best_lambda * best_p {
                best_p = p_uni;
                best_lambda = l_uni;
            }
        }

        if best_lambda <= 1e-4 {
            return rwkv_logp;
        }
        if best_p <= 0.0 {
            return rwkv_logp + (1.0 - best_lambda).max(1e-6).ln();
        }
        let p_rwkv = rwkv_logp.clamp(-30.0, -0.001).exp();
        let p_final = ((1.0 - best_lambda) * p_rwkv + best_lambda * best_p).clamp(1e-13, 0.999);
        p_final.ln()
    }

    pub fn write_to(&self, out: &mut String) {
        if self.is_empty() {
            return;
        }
        let _ = writeln!(out, "CONT_SEQ\t{}", self.tick);
        if let Some(model) = self.state_model {
            let _ = writeln!(out, "CONT_MODEL\t{model:x}");
        }
        if !self.unigrams.is_empty() {
            let _ = write!(out, "CONT_UNI\t{}\t{:.4}", self.uni_tick, self.uni_total);
            for (&ch, &(t, w)) in &self.unigrams {
                let _ = write!(out, "\t{:x}:{}:{:.4}", ch, t, w);
            }
            out.push('\n');
        }
        for (&key, row) in &self.rows {
            let _ = write!(out, "CONT\t{key:x}\t{}\t{:.4}", row.tick, row.total);
            for option in row.options.iter().filter(|option| option.ch != 0) {
                let _ = write!(out, "\t{:x}:{:.4}", option.ch, option.weight);
            }
            for sample in row
                .states
                .iter()
                .filter(|sample| sample.continuation.ch != 0)
            {
                let _ = write!(
                    out,
                    "\t{:x}:{:x}:{:.4}",
                    sample.continuation.ch, sample.signature, sample.continuation.weight
                );
            }
            out.push('\n');
        }
    }

    pub fn load_clock(&mut self, value: &str) {
        if let Ok(tick) = value.parse::<u64>() {
            self.tick = self.tick.max(tick);
        }
    }

    pub fn load_model(&mut self, value: &str) {
        self.state_model = u64::from_str_radix(value, 16).ok();
    }

    pub fn load_unigrams(&mut self, fields: &[&str]) {
        let [tick_s, total_s, items @ ..] = fields else {
            return;
        };
        let (Ok(tick), Ok(total)) = (tick_s.parse::<u64>(), total_s.parse::<f32>()) else {
            return;
        };
        if !total.is_finite() || total < 0.0 {
            return;
        }
        self.uni_tick = self.uni_tick.max(tick);
        self.uni_total = total;
        self.tick = self.tick.max(tick);
        for item in items {
            let mut it = item.split(':');
            let (Some(ch_s), Some(t_s), Some(w_s)) = (it.next(), it.next(), it.next()) else {
                continue;
            };
            let (Ok(ch), Ok(t), Ok(w)) = (
                u16::from_str_radix(ch_s, 16),
                t_s.parse::<u64>(),
                w_s.parse::<f32>(),
            ) else {
                continue;
            };
            if char::from_u32(ch as u32).is_some_and(han) && w.is_finite() && w > 0.0 {
                self.unigrams.insert(ch, (t, w));
            }
        }
    }

    pub fn load_row(&mut self, fields: &[&str]) {
        if self.rows.len() >= MAX_CONTEXTS {
            return;
        }
        let [key, tick, total, options @ ..] = fields else {
            return;
        };
        let (Ok(key), Ok(tick), Ok(total)) = (
            u64::from_str_radix(key, 16),
            tick.parse::<u64>(),
            total.parse::<f32>(),
        ) else {
            return;
        };
        if key == 0 || key > CONTEXT_MASK || !total.is_finite() || total <= 0.0 {
            return;
        }
        let mut row = Counts {
            tick,
            total,
            ..Counts::default()
        };
        let mut text_slots = row.options.iter_mut();
        let mut state_slots = row.states.iter_mut();
        for field in options {
            let Some((ch, value)) = field.split_once(':') else {
                return;
            };
            let (signature, weight) = value
                .split_once(':')
                .map_or((None, value), |(signature, weight)| {
                    (Some(signature), weight)
                });
            let (Ok(ch), Ok(weight)) = (u16::from_str_radix(ch, 16), weight.parse::<f32>()) else {
                return;
            };
            if !char::from_u32(ch as u32).is_some_and(han)
                || !weight.is_finite()
                || weight < 0.0
                || weight > total + 0.0001
            {
                return;
            }
            let continuation = Continuation { ch, weight };
            if let Some(signature) = signature {
                let (Some(slot), Ok(signature)) =
                    (state_slots.next(), u128::from_str_radix(signature, 16))
                else {
                    return;
                };
                *slot = StateSample {
                    signature,
                    continuation,
                };
            } else {
                let Some(slot) = text_slots.next() else {
                    return;
                };
                *slot = continuation;
            }
        }
        self.tick = self.tick.max(tick);
        self.rows.insert(key, row);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn evidence_favors_reselection_and_decays() {
        let prefix = ['审', '核'];
        let context = Context::with_chars(prefix);
        let mut confirmed = PersonalContinuations::default();
        confirmed.observe(&prefix, "安全材料", true, None, None);
        let mut chosen = PersonalContinuations::default();
        chosen.observe(&prefix, "安全材料", true, Some("案例材料"), None);
        let mut automatic = PersonalContinuations::default();
        automatic.observe(&prefix, "安全材料", false, None, None);

        let score = chosen.score(context, "安全资料");
        assert!(score > confirmed.score(context, "安全资料"));
        assert!(confirmed.score(context, "安全资料") > automatic.score(context, "安全资料"));
        let split_context = "安全".chars().fold(context, Context::push);
        let split_score = chosen.score(context, "安全") + chosen.score(split_context, "资料");
        assert!((score - split_score).abs() < 1e-6);
        assert_eq!(chosen.score(context, "案例资料"), 0.0);

        chosen.tick += 8 * HALF_LIFE as u64;
        assert!(chosen.score(context, "安全资料") < score * 0.01);
    }
}
