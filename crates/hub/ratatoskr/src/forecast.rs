//! Forecasts (docs/develop/hub.md, "Forecasts"): the sweep that turns finished tasks into samples, and what a plan or
//! a session will take, from the history of similar tasks.
//!
//! A sample is derived from the `step` and `spend` tables ([`norn::forecast::sample`]), so a restart, a sweep that
//! runs twice and the backfill of history are the same code: [`sweep`] takes what is due, a page at a time.
//!
//! A forecast ([`for_tasks`]) picks a reference class per task, resamples whole observations over the plan's
//! dependencies on the runner's slots ([`crate::runner::agent_slots`]), widens a thin class and scales the p90 by past
//! misses.  Tokens are priced at today's rates ([`rates_for`]), not at the sample's own cost.

use crate::agents::lock;
use crate::agents::session::find_profile;
use crate::dispatch::Caller;
use crate::front::Front;
use crate::settings::{AgentProfile, ModelPrice, profiles::Provider};
use norn::forecast::model::{self, Class, Level, Obs, Rates, Usage, Want};
use norn::forecast::sample::{self, Made, ProfileFacts, SampleRow};
use norn::forecast::sim;
use runstav::methods::forecast as wire;
use runstav::methods::matrix::{Role, Unit};
use runstav::wire::Error;
use serde_json::{Map, Value, json};
use std::collections::{BTreeMap, HashMap};
use std::path::Path;

/// Samples taken per read.
const PAGE: i64 = 100;
/// The cache time to live a profile is assumed to have.
const DEFAULT_TTL_SECS: f64 = 300.0;
/// A wake's context when the history does not know it.
const DEFAULT_CONTEXT: u64 = 300_000;
/// The forecasts read this many samples.
const HISTORY: i64 = 5000;
/// The latest (forecast, actual) pairs a class is calibrated from.
const PAIRS: i64 = 200;

/// The profiles by name (the user's first, then the built-in ones).
fn profiles_by_name(front: &Front) -> HashMap<String, AgentProfile> {
    let cur = front.settings.current();
    let mut out = HashMap::new();
    for p in cur
        .loaded
        .values
        .agents_profiles
        .iter()
        .chain(&crate::settings::defaults().profiles)
    {
        out.entry(p.name.clone()).or_insert_with(|| p.clone());
    }
    out
}

/// The matrix role a sample's job role runs as.
fn role_of(job_role: &str) -> Role {
    match job_role {
        "manager" => Role::Manager,
        "chat" => Role::Chat,
        _ => Role::Worker,
    }
}

/// The cache time to live, in seconds, of a session of PROFILE in ROLE: the hour when Claude Code gives it (a
/// subscription's main conversation) or when the lock asks for it (a gateway worker or manager), else five minutes.
pub fn ttl_of(profile: &AgentProfile, role: Role) -> f64 {
    match profile.provider() {
        Some(Provider::Claude)
            if profile.ai.is_none() || lock::gateway_long_cache(profile, role) =>
        {
            lock::LONG_CACHE_SECS
        }
        _ => DEFAULT_TTL_SECS,
    }
}

/// The rates of PROFILE in PRICES: the longest row key that is a prefix of its model id; else, for a gateway profile,
/// its provider's `:price (IN . OUT)` (GATEWAY), with every cache token at the input rate; else the row named for
/// its CLI (`claude`).  None: unpriced.
pub fn rates_in(
    prices: &[ModelPrice],
    profile: &AgentProfile,
    gateway: Option<(f64, f64)>,
) -> Option<Rates> {
    let row_rates = |r: &ModelPrice| Rates {
        input: r.input,
        output: r.output,
        cache_read: r.cache_read.unwrap_or(r.input),
        write_5m: r.write_5m.unwrap_or(r.input),
        write_1h: r.write_1h.unwrap_or(r.input),
    };
    let by_model = profile.model.as_deref().and_then(|m| {
        prices
            .iter()
            .filter(|r| m.starts_with(&r.key))
            .max_by_key(|r| r.key.len())
    });
    if let Some(r) = by_model {
        return Some(row_rates(r));
    }
    if profile.ai.is_some()
        && let Some((input, output)) = gateway
    {
        return Some(Rates {
            input,
            output,
            cache_read: input,
            write_5m: input,
            write_1h: input,
        });
    }
    let cli = cli_name(profile.provider()?);
    prices.iter().find(|r| r.key == cli).map(row_rates)
}

/// The CLI's name, which is also its meter's and the price table's.
fn cli_name(p: Provider) -> &'static str {
    match p {
        Provider::Claude => "claude",
        Provider::Codex => "codex",
        Provider::Gemini => "gemini",
        Provider::Kimi => "kimi",
        Provider::DeepSeek => "deepseek",
    }
}

/// A day, in seconds.
const DAY: f64 = 86_400.0;

/// A meter that resets more than a day away is the week's; else the pace speaks of this window.
pub fn window_of(resets_at: Option<f64>, now: f64) -> wire::PaceWindow {
    match resets_at {
        Some(r) if r - now > DAY => wire::PaceWindow::Week,
        _ => wire::PaceWindow::Short,
    }
}

/// The meter's share for each estimated dollar: its rises over HISTORY (a reset is not a fall) divided by USD_EST,
/// what agents on that provider reported in the same time.  The meter is the account's, so use outside drgnx raises
/// it: an estimate, high if anything.  None with no spend or no rise.
pub fn share_per_usd_of(history: &[(f64, f64)], usd_est: f64) -> Option<f64> {
    let rises = crate::budget::rise_total(history);
    (usd_est > 0.0 && rises > 0.0).then(|| rises / usd_est)
}

/// [`share_per_usd_of`] over PROVIDER's kept readings and the `usd-est` its steps booked since the first of them.
pub async fn share_per_usd(front: &Front, provider: &str, window: &str, now: f64) -> Option<f64> {
    let history = front.core.budgets.history(provider, window, now);
    let first = history.first()?.0;
    let provider = provider.to_owned();
    let usd_est = front
        .writer
        .db
        .read(move |c| {
            Ok(c.query_row(
                "select coalesce(sum(cost), 0.0) from step where cost_unit = 'usd-est' and provider = ?1 and start >= ?2",
                (&provider, first),
                |r| r.get::<_, f64>(0),
            )?)
        })
        .await
        .ok()?;
    share_per_usd_of(&history, usd_est)
}

/// The plan's effect on a meter: ADDED is the share the plan adds.  `runs_out_p90`: the used share, the plan's high
/// share and what the current rate adds before the reset reach 1 (with no reset known, the first two).  Then the
/// forecast warns.
pub fn pace_effect(
    pace: &runstav::methods::timeline::Pace,
    added: Option<wire::Range>,
    now: f64,
) -> (wire::PaceEffect, Option<String>) {
    let hours_left = pace
        .resets_at
        .map_or(0.0, |r| ((r - now) / 3600.0).max(0.0));
    let projected =
        pace.used_share + added.map_or(0.0, |a| a.p90) + pace.rate_per_hour * hours_left;
    let runs_out_p90 = added.is_some() && projected >= 1.0;
    let exhausted_after = added.and_then(|a| {
        let left = 1.0 - pace.used_share - a.p50;
        if left <= 0.0 {
            return Some(now);
        }
        let at = now + left / pace.rate_per_hour * 3600.0;
        (pace.rate_per_hour > 0.0 && pace.resets_at.is_none_or(|r| at <= r)).then_some(at)
    });
    let effect = wire::PaceEffect {
        provider: pace.provider.clone(),
        used_share: pace.used_share,
        added_share: added,
        exhausted_at: pace.exhausted_at,
        exhausted_after,
        resets_at: pace.resets_at,
        window: window_of(pace.resets_at, now),
        estimate: true,
        runs_out_p90,
    };
    let warning = runs_out_p90.then(|| {
        format!(
            "the plan's p90 would use up the {} limit before it resets (an estimate)",
            pace.provider
        )
    });
    (effect, warning)
}

/// [`rates_in`] with the hub's price table and PROFILE's gateway price.
pub fn rates_for(front: &Front, profile: &AgentProfile) -> Option<Rates> {
    let cur = front.settings.current();
    rates_in(
        &cur.loaded.values.agents_model_prices,
        profile,
        crate::runner::profile_price(front, &profile.name),
    )
}

/// The date of the oldest dated row of PRICES; empty when none is dated.
pub fn prices_as_of(prices: &[ModelPrice]) -> String {
    prices
        .iter()
        .filter_map(|r| r.as_of.as_deref())
        .min()
        .unwrap_or_default()
        .to_owned()
}

/// What a task was forecast from, in words.
pub fn basis_label(level: Level, n: u32, other_model: bool, role: &str, profile: &str) -> String {
    match level {
        Level::Prior => "no history: prior".to_owned(),
        Level::Project => format!("{n} {role} tasks on {profile}, this project"),
        Level::Profile => format!("{n} {role} tasks on {profile}"),
        Level::Role if other_model => format!("{n} {role} tasks on another model, repriced"),
        Level::Role => format!("{n} {role} tasks on other profiles"),
        Level::Any => format!("{n} tasks of other roles, repriced"),
    }
}

/// R with its p90 scaled by FACTOR and held at p50 or above (the factor can be below 1); p50 is not touched.
pub fn calibrate(r: wire::Range, factor: f64) -> wire::Range {
    wire::Range {
        p50: r.p50,
        p90: (r.p90 * factor).max(r.p50),
    }
}

fn wire_range(r: sim::Range) -> wire::Range {
    wire::Range {
        p50: r.p50,
        p90: r.p90,
    }
}

/// R, offsets from ORIGIN, as times from the same clock (ORIGIN 0: offsets as they are).
fn at_clock(r: sim::Range, origin: f64) -> wire::Range {
    wire::Range {
        p50: origin + r.p50,
        p90: origin + r.p90,
    }
}

fn unit_of(s: &str) -> Option<Unit> {
    serde_json::from_value(Value::String(s.to_owned())).ok()
}

fn unit_name(u: Unit) -> &'static str {
    match u {
        Unit::Usd => "usd",
        _ => "usd-est",
    }
}

/// The cost ranges of one entry, `usd` before `usd-est`; each widened by N, then calibrated by FACTOR when there is
/// one.  The second list is the same before calibration, which is what `forecast_made` keeps.
fn cost_ranges(
    by_unit: &BTreeMap<String, sim::Range>,
    n: u32,
    factor: Option<f64>,
) -> (Vec<wire::CostRange>, Vec<wire::CostRange>) {
    let mut kept = Vec::new();
    let mut shown = Vec::new();
    for unit in ["usd", "usd-est"] {
        let (Some(r), Some(u)) = (by_unit.get(unit), unit_of(unit)) else {
            continue;
        };
        let w = wire_range(sim::widen(*r, n));
        let c = factor.map_or(w, |f| calibrate(w, f));
        let range = |r: wire::Range| wire::CostRange {
            unit: u,
            p50: r.p50,
            p90: r.p90,
            estimate: u == Unit::UsdEst,
        };
        kept.push(range(w));
        shown.push(range(c));
    }
    (shown, kept)
}

/// A sample as the model sees it.
fn obs_of(r: &SampleRow) -> Obs {
    Obs {
        role: r.role.clone(),
        profile: r.profile.clone(),
        model: r.model.clone(),
        project: r.project.clone(),
        brief_bytes: u64::try_from(r.brief_bytes).unwrap_or(0),
        usage: Usage {
            input: u64::try_from(r.tokens_in).unwrap_or(0),
            output: u64::try_from(r.tokens_out).unwrap_or(0),
            cache_read: u64::try_from(r.cache_read).unwrap_or(0),
            cache_write: u64::try_from(r.cache_write).unwrap_or(0),
        },
        active_secs: r.active_secs,
        wall_secs: r.wall_secs,
        wakes: u32::try_from(r.wakes).unwrap_or(0),
        cold_wakes: u32::try_from(r.cold_wakes).unwrap_or(0),
        context: r.context.and_then(|c| u64::try_from(c).ok()),
        cost: r.cost.zip(r.cost_unit.clone()),
    }
}

/// A class of forecasts: role, profile and model.
type ClassKey = (String, String, Option<String>);

/// What the history says, read once: the samples (newest first), each class's (p90, actual) pairs and the whole
/// plans' pairs.
struct History {
    samples: Vec<SampleRow>,
    pairs: HashMap<ClassKey, Vec<(f64, f64)>>,
    plans: Vec<(f64, f64)>,
}

async fn history(front: &Front, wants: &[Want]) -> Result<History, Error> {
    let mut keys: Vec<(String, String, Option<String>)> = wants
        .iter()
        .map(|w| (w.role.clone(), w.profile.clone(), w.model.clone()))
        .collect();
    keys.sort();
    keys.dedup();
    front
        .writer
        .db
        .read(move |c| {
            let samples = sample::all(c, HISTORY)?;
            let mut pairs = HashMap::new();
            for k in keys {
                let got = sample::made_pairs(c, &k.0, &k.1, k.2.as_deref(), PAIRS)?;
                pairs.insert(k, got);
            }
            let plans = sample::plan_pairs(c, PAIRS)?;
            Ok(History {
                samples,
                pairs,
                plans,
            })
        })
        .await
        .map_err(crate::coord::fail)
}

/// What is known of a running job's tasks ([`sim::Fixed`], one per want, times from NOW) and NOW, the wall clock they
/// are measured from.
struct Remaining {
    fixed: Vec<sim::Fixed>,
    now: f64,
}

/// F, the simulation's work, off the async worker when the runtime has others to give it to (the hub's).
fn off_worker<T>(f: impl FnOnce() -> T) -> T {
    match tokio::runtime::Handle::try_current().map(|h| h.runtime_flavor()) {
        Ok(tokio::runtime::RuntimeFlavor::MultiThread) => tokio::task::block_in_place(f),
        _ => f(),
    }
}

/// One more run like these WANTS: the forecast, and the `forecast_made` rows of it (the plan's `JOB#N`, and the
/// plan's total as `JOB`), each with the p90 as it stood before calibration.  PLAIN weighs every observation of a
/// class alike (a session has no brief).  With REMAINING, what is left of a running job ([`sim::simulate_fixed`]):
/// times are wall-clock, done tasks their actuals (neither widened nor calibrated), and the totals what remains.
async fn build(
    front: &Front,
    job_key: &str,
    wants: Vec<Want>,
    plain: bool,
    remaining: Option<&Remaining>,
) -> Result<(wire::Forecast, Vec<Made>), Error> {
    let fixed: &[sim::Fixed] = remaining.map_or(&[], |r| r.fixed.as_slice());
    let origin = remaining.map_or(0.0, |r| r.now);
    let hist = history(front, &wants).await?;
    let (managers, tasks): (Vec<&SampleRow>, Vec<&SampleRow>) =
        hist.samples.iter().partition(|r| r.role == "manager");
    let mut all: Vec<Obs> = tasks.iter().map(|r| obs_of(r)).collect();
    let history_len = all.len();
    let prior = model::prior();
    let mut classes: Vec<Class> = wants
        .iter()
        .map(|w| model::reference_class(w, &all[..history_len], &prior))
        .collect();
    if plain {
        for c in &mut classes {
            c.picks.iter_mut().for_each(|p| p.1 = 1.0);
        }
    }
    all.extend(prior);

    let profiles: Vec<Option<AgentProfile>> = wants
        .iter()
        .map(|w| find_profile(front, &w.profile))
        .collect();
    let rates: Vec<Option<Rates>> = profiles
        .iter()
        .map(|p| p.as_ref().and_then(|p| rates_for(front, p)))
        .collect();
    let ttls: Vec<f64> = wants
        .iter()
        .zip(&profiles)
        .map(|(w, p)| {
            p.as_ref()
                .map_or(DEFAULT_TTL_SECS, |p| ttl_of(p, role_of(&w.role)))
        })
        .collect();
    let units: Vec<&'static str> = profiles
        .iter()
        .map(|p| {
            unit_name(if p.as_ref().is_some_and(|p| p.ai.is_some()) {
                Unit::Usd
            } else {
                Unit::UsdEst
            })
        })
        .collect();

    let price = |i: usize, o: &Obs| -> Option<(String, f64)> {
        match &rates[i] {
            Some(r) => Some((units[i].to_owned(), model::usd(&o.usage, r, ttls[i]))),
            // no rate known: a sample's own cost serves only on the same profile
            None => (o.profile.as_deref() == Some(wants[i].profile.as_str()))
                .then(|| o.cost.clone().map(|(amount, unit)| (unit, amount)))
                .flatten(),
        }
    };
    let wake_price = |i: usize, o: &Obs| -> Option<(String, f64)> {
        let r = rates[i].as_ref()?;
        let cold = model::wake_usd(
            o.context.unwrap_or(DEFAULT_CONTEXT),
            ttls[i] * 2.0 + 1.0,
            ttls[i],
            r,
        );
        Some((units[i].to_owned(), f64::from(o.cold_wakes) * cold))
    };

    let mut seed_parts: Vec<String> = vec![job_key.to_owned()];
    for w in &wants {
        seed_parts.push(format!(
            "{}|{}|{}|{}|{:?}|{}|{:?}",
            w.n,
            w.role,
            w.profile,
            w.model.as_deref().unwrap_or(""),
            w.project,
            w.brief_bytes,
            w.deps
        ));
    }
    let seed = sim::seed_of(&seed_parts.iter().map(String::as_str).collect::<Vec<_>>());
    let slots = crate::runner::agent_slots(front);
    let (totals, wake_totals) = off_worker(|| {
        (
            sim::simulate_fixed(
                &wants,
                &classes,
                &all,
                &price,
                slots,
                seed,
                sim::DRAWS,
                fixed,
            ),
            sim::simulate_fixed(
                &wants,
                &classes,
                &all,
                &wake_price,
                slots,
                seed,
                sim::DRAWS,
                fixed,
            ),
        )
    });

    let made_at = crate::clock::wall_secs();
    let mut out_tasks = Vec::new();
    let mut made = Vec::new();
    let mut unpriced: Vec<String> = Vec::new();
    let mut past_every_run: Vec<String> = Vec::new();
    for (i, w) in wants.iter().enumerate() {
        let class = &classes[i];
        let at = remaining.map(|_| match fixed.get(i) {
            Some(sim::Fixed::Done { .. }) => wire::TaskAt::Done,
            Some(sim::Fixed::Running { .. }) => wire::TaskAt::Running,
            _ => wire::TaskAt::Waiting,
        });
        let is_done = at == Some(wire::TaskAt::Done);
        // a done task's actuals are what they are: no class floor, no calibration
        let n = if is_done { u32::MAX } else { class.n };
        let factor = hist
            .pairs
            .get(&(w.role.clone(), w.profile.clone(), w.model.clone()))
            .and_then(|p| sim::conformal(p))
            .filter(|_| !is_done);
        let t = &totals.per_task[i];
        if t.past_every_run {
            past_every_run.push(format!("T{} is past every run like it", w.n));
        }
        let tokens = wire_range(sim::widen(t.tokens, n));
        let active = wire_range(sim::widen(t.active, n));
        let (cost, cost_kept) = cost_ranges(&t.cost, n, factor);
        if cost.is_empty() && !unpriced.contains(&w.profile) {
            unpriced.push(w.profile.clone());
        }
        let shown = |r: wire::Range| factor.map_or(r, |f| calibrate(r, f));
        out_tasks.push(wire::TaskForecast {
            n: u64::try_from(w.n).unwrap_or(0),
            role: w.role.clone(),
            profile: w.profile.clone(),
            provider: profiles[i]
                .as_ref()
                .and_then(|p| p.provider())
                .map(|p| cli_name(p).to_owned()),
            basis: wire::Basis {
                level: basis_level(class.level),
                n: class.n,
                other_model: class.other_model,
                calibrated: factor.is_some(),
                label: basis_label(class.level, class.n, class.other_model, &w.role, &w.profile),
            },
            tokens: shown(tokens),
            active_secs: shown(active),
            cost,
            start: at_clock(t.start, origin),
            finish: at_clock(t.finish, origin),
            at,
        });
        made.push(Made {
            job: job_key.to_owned(),
            task: format!("{job_key}#{}", w.n),
            made_at,
            role: Some(w.role.clone()),
            profile: Some(w.profile.clone()),
            model: w.model.clone(),
            tokens_p50: tokens.p50,
            tokens_p90: tokens.p90,
            secs_p50: active.p50,
            secs_p90: active.p90,
            cost_p50: cost_kept.first().map(|c| c.p50),
            cost_p90: cost_kept.first().map(|c| c.p90),
            cost_unit: cost_kept.first().map(|c| unit_name(c.unit).to_owned()),
            basis: out_tasks[i].basis.label.clone(),
            n: i64::from(class.n),
            start_p50: t.start.p50,
            start_p90: t.start.p90,
            finish_p50: t.finish.p50,
            finish_p90: t.finish.p90,
        });
    }
    let min_n = classes.iter().map(|c| c.n).min().unwrap_or(0);
    let tokens = wire_range(sim::widen(totals.tokens, min_n));
    let active = wire_range(sim::widen(totals.active, min_n));
    let wall = wire_range(sim::widen(totals.wall, min_n));
    // the plan's total is calibrated by whole plans' misses, as a task is by its class's: a task's factor holds for
    // the task alone and says nothing of a sum's p90, so the total has pairs of its own (the plan's p90 as it stood,
    // against what its tasks used).  Its tokens' factor scales the p90 of every unit, as a task's does; the Autonomous
    // rule's spend and week checks read these.  A session's forecast is one run, not a plan: none
    let plan_factor = if plain {
        None
    } else {
        sim::conformal(&hist.plans)
    };
    let plan_shown = move |r: wire::Range| plan_factor.map_or(r, |f| calibrate(r, f));
    let (cost, cost_kept) = cost_ranges(&totals.cost, min_n, plan_factor);
    made.push(Made {
        job: job_key.to_owned(),
        task: job_key.to_owned(),
        made_at,
        role: None,
        profile: None,
        model: None,
        tokens_p50: tokens.p50,
        tokens_p90: tokens.p90,
        secs_p50: wall.p50,
        secs_p90: wall.p90,
        cost_p50: cost_kept.first().map(|c| c.p50),
        cost_p90: cost_kept.first().map(|c| c.p90),
        cost_unit: cost_kept.first().map(|c| unit_name(c.unit).to_owned()),
        basis: format!("{} tasks", wants.len()),
        n: i64::from(min_n),
        start_p50: 0.0,
        start_p90: 0.0,
        finish_p50: wall.p50,
        finish_p90: wall.p90,
    });
    let wake = (totals.cold_wakes.p90 > 0.0).then(|| wire::WakeLine {
        cold_wakes: wire_range(totals.cold_wakes),
        cost: cost_ranges(&wake_totals.cost, min_n, None).0,
    });
    let manager = manager_line(front, &managers);
    // the effect on each subscription's meter that a task of the plan runs on
    let on_subscription: Vec<Option<&'static str>> = profiles
        .iter()
        .map(|p| {
            p.as_ref()
                .filter(|p| p.ai.is_none())
                .and_then(|p| p.provider())
                .map(cli_name)
        })
        .collect();
    let mut meters: Vec<&'static str> = Vec::new();
    for name in on_subscription.iter().flatten() {
        if !meters.contains(name) {
            meters.push(name);
        }
    }
    let mut pace = Vec::new();
    let mut warnings = past_every_run;
    for name in meters {
        // the provider's window that binds first: the fullest
        let Some(meter) = front
            .core
            .budgets
            .pace(Some(name), made_at)
            .into_iter()
            .max_by(|a, b| a.used_share.total_cmp(&b.used_share))
        else {
            continue;
        };
        let added = match share_per_usd(front, name, &meter.window, made_at).await {
            Some(ratio) => {
                let own = |i: usize, o: &Obs| {
                    if on_subscription[i] == Some(name) {
                        price(i, o)
                    } else {
                        None
                    }
                };
                let t = off_worker(|| {
                    sim::simulate_fixed(
                        &wants,
                        &classes,
                        &all,
                        &own,
                        slots,
                        seed,
                        sim::DRAWS,
                        fixed,
                    )
                });
                t.cost.get("usd-est").map(|r| {
                    plan_shown(wire::Range {
                        p50: r.p50 * ratio,
                        p90: r.p90 * ratio,
                    })
                })
            }
            None => None,
        };
        let (effect, warning) = pace_effect(&meter, added, made_at);
        pace.push(effect);
        warnings.extend(warning);
    }
    let cur = front.settings.current();
    let forecast = wire::Forecast {
        tasks: out_tasks,
        tokens: plan_shown(tokens),
        active_secs: plan_shown(active),
        wall_secs: plan_shown(wall),
        cost,
        unpriced,
        wake,
        manager,
        pace,
        warnings,
        prices_as_of: prices_as_of(&cur.loaded.values.agents_model_prices),
        made_at,
        baseline: None,
    };
    Ok((forecast, made))
}

fn basis_level(l: Level) -> wire::BasisLevel {
    match l {
        Level::Project => wire::BasisLevel::Project,
        Level::Profile => wire::BasisLevel::Profile,
        Level::Role => wire::BasisLevel::Role,
        Level::Any => wire::BasisLevel::Any,
        Level::Prior => wire::BasisLevel::Prior,
    }
}

/// A manager's own spend per task, from the `manager` samples (one per finished job, tokens and time over its
/// tasks); none while there are none.  Shown beside a plan's total and never in it.
fn manager_line(front: &Front, rows: &[&SampleRow]) -> Option<wire::TaskForecast> {
    let first = rows.first()?;
    let per = |f: &dyn Fn(&SampleRow) -> f64| -> wire::Range {
        let mut v: Vec<f64> = rows.iter().map(|r| f(r) / r.tasks.max(1) as f64).collect();
        v.sort_by(f64::total_cmp);
        wire::Range {
            p50: sim::quantile(&v, 0.5),
            p90: sim::quantile(&v, 0.9),
        }
    };
    let tokens = per(&|r| (r.tokens_in + r.tokens_out + r.cache_read + r.cache_write) as f64);
    let active = per(&|r| r.active_secs);
    let profile = first.profile.clone().unwrap_or_else(|| "manager".into());
    let found = find_profile(front, &profile);
    let cost = match found
        .as_ref()
        .and_then(|p| rates_for(front, p).map(|r| (p, r)))
    {
        Some((p, r)) => {
            let ttl = ttl_of(p, Role::Manager);
            let unit = if p.ai.is_some() {
                Unit::Usd
            } else {
                Unit::UsdEst
            };
            let range = per(&|row| model::usd(&obs_of(row).usage, &r, ttl));
            vec![wire::CostRange {
                unit,
                p50: range.p50,
                p90: range.p90,
                estimate: unit == Unit::UsdEst,
            }]
        }
        None => Vec::new(),
    };
    let n = u32::try_from(rows.len()).unwrap_or(u32::MAX);
    Some(wire::TaskForecast {
        n: 0,
        role: "manager".into(),
        profile,
        provider: None,
        basis: wire::Basis {
            level: wire::BasisLevel::Role,
            n,
            other_model: false,
            calibrated: false,
            label: format!("{n} manager jobs, per task"),
        },
        tokens,
        active_secs: active,
        cost,
        start: wire::Range::default(),
        finish: wire::Range::default(),
        at: None,
    })
}

/// The forecast of WANTS, a plan of job JOB_KEY, and the rows to keep of it.
pub async fn for_job(
    front: &Front,
    job_key: &str,
    wants: Vec<Want>,
) -> Result<(wire::Forecast, Vec<Made>), Error> {
    build(front, job_key, wants, false, None).await
}

/// The forecast of WANTS, a plan of job JOB_KEY.
pub async fn for_tasks(
    front: &Front,
    job_key: &str,
    wants: Vec<Want>,
) -> Result<wire::Forecast, Error> {
    Ok(for_job(front, job_key, wants).await?.0)
}

/// The wants of a job from its data: `tasks` (number, role, dependencies, body, model), the profile each task names or
/// is reassigned to, else its role's route, and the project the job runs in.
pub(crate) fn wants_from(front: &Front, job_id: &str, data: &Map<String, Value>) -> Vec<Want> {
    let project = data
        .get("project")
        .and_then(Value::as_str)
        .map(str::to_owned);
    let routes = data.get("routes").and_then(Value::as_object);
    data.get("tasks")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|t| {
            let n = t.get("n")?.as_i64()?;
            let role = t.get("role").and_then(Value::as_str).unwrap_or("implement");
            let named = crate::runner::data_for(data, "profiles", &format!("{job_id}#{n}"))
                .and_then(Value::as_str);
            let profile = named
                .or_else(|| routes.and_then(|r| r.get(role)).and_then(Value::as_str))
                .map(str::to_owned)
                .or_else(|| crate::runner::route(front, role).into_iter().next())
                .unwrap_or_else(|| "claude".into());
            // a named profile runs its own model; with none named, the model the plan asked for is the hint
            let hint = t.get("model").and_then(Value::as_str).map(str::to_owned);
            let runs = find_profile(front, &profile).and_then(|p| p.model);
            Some(Want {
                n,
                role: role.to_owned(),
                model: if named.is_some() { runs } else { hint.or(runs) },
                profile,
                project: project.clone(),
                brief_bytes: t
                    .get("body")
                    .and_then(Value::as_str)
                    .map_or(0, |b| b.len() as u64),
                deps: t
                    .get("deps")
                    .and_then(Value::as_array)
                    .into_iter()
                    .flatten()
                    .filter_map(Value::as_i64)
                    .collect(),
            })
        })
        .collect()
}

/// `forecast/get`: a job's forecast, from its data as proposed; with `remaining`, what is left of it from now.
pub async fn get(
    front: &Front,
    _caller: &Caller,
    p: wire::ForecastParams,
) -> Result<wire::Forecast, Error> {
    if p.remaining == Some(true) {
        return remaining_forecast(front, p.job.as_str(), crate::clock::wall_secs()).await;
    }
    job_forecast(front, p.job.as_str()).await
}

/// What job JOB's tasks (one per want) have done, from their steps at NOW: a finished or dropped task its first start,
/// last end, cost and tokens; a task with a step and not finished is running since its first start; the rest are
/// open.  With it, the job's newest step id (what the cache is keyed on).
async fn fixed_of(
    front: &Front,
    job: &str,
    wants: &[Want],
    tasks: &[norn::read::tasks::Task],
    now: f64,
) -> Result<(Vec<sim::Fixed>, i64), Error> {
    use norn::read::steps::{Scope, rollup};
    let status: HashMap<i64, Option<String>> = tasks
        .iter()
        .map(|t| (t.row.n, t.row.status.clone()))
        .collect();
    let asked: Vec<(String, bool)> = wants
        .iter()
        .map(|w| {
            let done = matches!(
                status.get(&w.n).cloned().flatten().as_deref(),
                Some("done" | "dropped" | "accepted" | "parked" | "superseded")
            );
            (format!("{job}#{}", w.n), done)
        })
        .collect();
    let prefix = format!("{job}#");
    front
        .writer
        .db
        .read(move |c| {
            let mut fixed = Vec::with_capacity(asked.len());
            for (tid, done) in &asked {
                let r = rollup(c, Scope::Task, tid)?;
                let t = &r.tokens;
                let tokens = (t.input + t.output + t.cache_read + t.cache_write) as f64;
                fixed.push(match (done, r.first) {
                    (true, first) => sim::Fixed::Done {
                        start: first.unwrap_or(now) - now,
                        finish: r.last.or(first).unwrap_or(now) - now,
                        cost: r.cost_by_unit.into_iter().collect(),
                        tokens,
                    },
                    (false, Some(first)) => sim::Fixed::Running {
                        start: first - now,
                        elapsed: (now - first).max(0.0),
                    },
                    (false, None) => sim::Fixed::Open,
                });
            }
            let last: i64 = c.query_row(
                "select coalesce(max(id), 0) from step where substr(task, 1, length(?1)) = ?1",
                [&prefix],
                |r| r.get(0),
            )?;
            Ok((fixed, last))
        })
        .await
        .map_err(crate::coord::fail)
}

/// The remaining forecasts kept, by (job, newest step id): a new step misses, and so do 5 s.
type RemainingKept = HashMap<(String, i64), (tokio::time::Instant, wire::Forecast)>;

static REMAINING_CACHE: std::sync::Mutex<Option<RemainingKept>> = std::sync::Mutex::new(None);

const REMAINING_CACHE_SECS: u64 = 5;
const REMAINING_CACHE_MAX: usize = 64;

/// What is left of job ID at NOW ([`Remaining`]), with the baseline of an approved job.
pub(crate) async fn remaining_forecast(
    front: &Front,
    id: &str,
    now: f64,
) -> Result<wire::Forecast, Error> {
    let l = crate::runner::load(front, id, false)
        .await?
        .ok_or_else(|| crate::runner::invalid(format!("No job {id}")))?;
    let data = match &l.job.data {
        Some(Value::Object(m)) => m.clone(),
        _ => Map::new(),
    };
    let wants = wants_from(front, id, &data);
    if wants.is_empty() {
        return Err(crate::runner::invalid(format!(
            "Job {id} has no tasks to forecast"
        )));
    }
    let (fixed, last) = fixed_of(front, id, &wants, &l.tasks, now).await?;
    let key = (id.to_owned(), last);
    let at = crate::clock::now();
    let kept = REMAINING_CACHE
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .as_ref()
        .and_then(|c| c.get(&key).cloned())
        .filter(|(t, _)| at.duration_since(*t).as_secs() < REMAINING_CACHE_SECS);
    if let Some((_, f)) = kept {
        return Ok(f);
    }
    let r = Remaining { fixed, now };
    let (mut forecast, _) = build(front, id, wants, false, Some(&r)).await?;
    if l.job.status.as_deref() != Some("proposed") {
        forecast.baseline = baseline_of(front, id).await?;
    }
    let mut cache = REMAINING_CACHE
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let cache = cache.get_or_insert_with(HashMap::new);
    if cache.len() >= REMAINING_CACHE_MAX {
        cache.clear();
    }
    cache.insert(key, (at, forecast.clone()));
    Ok(forecast)
}

/// JOB's forecast, with the baseline of an approved one.
pub(crate) async fn job_forecast(front: &Front, id: &str) -> Result<wire::Forecast, Error> {
    let id = id.to_owned();
    let l = crate::runner::load(front, &id, false)
        .await?
        .ok_or_else(|| crate::runner::invalid(format!("No job {id}")))?;
    let data = match &l.job.data {
        Some(Value::Object(m)) => m.clone(),
        _ => Map::new(),
    };
    let wants = wants_from(front, &id, &data);
    if wants.is_empty() {
        return Err(crate::runner::invalid(format!(
            "Job {id} has no tasks to forecast"
        )));
    }
    let mut forecast = for_tasks(front, &id, wants).await?;
    if l.job.status.as_deref() != Some("proposed") {
        forecast.baseline = baseline_of(front, &id).await?;
    }
    Ok(forecast)
}

/// What the proposal of JOB said when each task would start and end, read back from `forecast_made`; none when none
/// was kept.  Approval and resume never write it again: the baseline is the proposal's.
async fn baseline_of(front: &Front, job: &str) -> Result<Option<wire::Baseline>, Error> {
    let key = job.to_owned();
    let rows = front
        .writer
        .db
        .read(move |c| sample::baseline(c, &key))
        .await
        .map_err(|e| crate::runner::invalid(format!("the baseline does not read: {e}")))?;
    let Some(plan) = rows.iter().find(|r| r.task == job) else {
        return Ok(None);
    };
    let tasks = rows
        .iter()
        .filter_map(|r| {
            let n = r.task.strip_prefix(job)?.strip_prefix('#')?.parse().ok()?;
            Some(wire::BaselineTask {
                n,
                start: wire::Range {
                    p50: r.start_p50,
                    p90: r.start_p90,
                },
                finish: wire::Range {
                    p50: r.finish_p50,
                    p90: r.finish_p90,
                },
            })
        })
        .collect();
    Ok(Some(wire::Baseline {
        made_at: plan.made_at,
        tasks,
        finish: wire::Range {
            p50: plan.finish_p50,
            p90: plan.finish_p90,
        },
    }))
}

/// One plan of a `forecast/plan`: its wants as the job would make them, its version (the plan's hash), and, when a job of
/// it runs, that job and its own forecast.
#[derive(Clone)]
pub(crate) struct PlanIn {
    pub id: String,
    pub hash: String,
    pub wants: Vec<Want>,
    pub running: Option<(String, wire::Forecast)>,
}

/// The wants of several plans as one job's: plan I's task N becomes `I * 1000 + N` (its dependencies too), so one
/// simulation draws them together on the runner's slots.
pub(crate) fn joint_wants(plans: &[&PlanIn]) -> Vec<Want> {
    plans
        .iter()
        .enumerate()
        .flat_map(|(i, p)| {
            let base = (i as i64 + 1) * 1000;
            p.wants.iter().map(move |w| Want {
                n: base + w.n,
                deps: w.deps.iter().map(|d| base + d).collect(),
                ..w.clone()
            })
        })
        .collect()
}

/// The answers kept for the plans' versions: a plan edit (its hash) misses, the clock does too (new history).
#[derive(Default)]
pub(crate) struct PlanCache {
    kept: HashMap<String, (tokio::time::Instant, wire::Forecast)>,
}

const PLAN_CACHE_SECS: u64 = 60;
const PLAN_CACHE_MAX: usize = 64;

impl PlanCache {
    fn key(plans: &[&PlanIn]) -> String {
        let mut k: Vec<String> = plans
            .iter()
            .map(|p| format!("{}@{}", p.id, p.hash))
            .collect();
        k.sort();
        k.join("|")
    }

    pub(crate) fn get(
        &self,
        plans: &[&PlanIn],
        now: tokio::time::Instant,
    ) -> Option<wire::Forecast> {
        let (at, f) = self.kept.get(&Self::key(plans))?;
        (now.duration_since(*at).as_secs() < PLAN_CACHE_SECS).then(|| f.clone())
    }

    pub(crate) fn put(&mut self, plans: &[&PlanIn], now: tokio::time::Instant, f: wire::Forecast) {
        if self.kept.len() >= PLAN_CACHE_MAX {
            self.kept.clear();
        }
        self.kept.insert(Self::key(plans), (now, f));
    }
}

static PLAN_CACHE: std::sync::Mutex<Option<PlanCache>> = std::sync::Mutex::new(None);

/// The forecast over PLANS together: those with a running job are not in the draw (they have their own); the rest are
/// drawn as one job on the runner's slots.  Nothing is recorded.
pub(crate) async fn plan_forecast(
    front: &Front,
    plans: Vec<PlanIn>,
) -> Result<wire::PlanForecast, Error> {
    let (running, open): (Vec<&PlanIn>, Vec<&PlanIn>) =
        plans.iter().partition(|p| p.running.is_some());
    let now = crate::clock::now();
    let cached = PLAN_CACHE
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .as_ref()
        .and_then(|c| c.get(&open, now));
    let forecast = match cached {
        Some(f) => f,
        None => {
            let wants = joint_wants(&open);
            let (f, _made) = if wants.is_empty() {
                // no plan to draw: the empty forecast of no tasks
                build(front, "forecast/plan", Vec::new(), false, None).await?
            } else {
                for_job(front, "forecast/plan", wants).await?
            };
            PLAN_CACHE
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .get_or_insert_with(PlanCache::default)
                .put(&open, now, f.clone());
            f
        }
    };
    Ok(wire::PlanForecast {
        forecast,
        running: running
            .into_iter()
            .filter_map(|p| {
                let (job, remaining) = p.running.clone()?;
                Some(wire::RunningPlan {
                    plan: p.id.clone(),
                    job,
                    remaining,
                })
            })
            .collect(),
    })
}

/// `forecast/plan`: the plans from the graph; a running job's is what remains of it (`forecast/get` with `remaining`).
pub async fn plan(front: &Front, p: wire::ForecastPlanParams) -> Result<wire::PlanForecast, Error> {
    let mut ins = Vec::new();
    for id in p.plans.into_inner() {
        let (_, read) = crate::runner::effects::plan_for_job(front, id.as_str()).await?;
        let key = id.as_str().to_owned();
        let running = {
            let k = key.clone();
            front
                .writer
                .db
                .read(move |c| {
                    Ok(c.query_row(
                        "select id from job where plan = ?1 and status in ('running', 'paused') \
                         order by created desc limit 1",
                        [&k],
                        |r| r.get::<_, String>(0),
                    )
                    .ok())
                })
                .await
                .map_err(|e| crate::runner::invalid(format!("the plan's job does not read: {e}")))?
        };
        let running = match running {
            Some(job) => {
                let f = remaining_forecast(front, &job, crate::clock::wall_secs()).await?;
                Some((job, f))
            }
            None => None,
        };
        let mut data = Map::new();
        data.insert(
            "tasks".into(),
            Value::Array(
                read.tasks
                    .iter()
                    .map(|t| {
                        let mut o =
                            json!({"n": t.n, "role": t.role, "deps": t.deps, "body": t.body});
                        if let Some(m) = &t.model {
                            o["model"] = json!(m);
                        }
                        o
                    })
                    .collect(),
            ),
        );
        let profiles: Map<String, Value> = read
            .tasks
            .iter()
            .filter_map(|t| Some((format!("{key}#{}", t.n), json!(t.profile.as_ref()?))))
            .collect();
        if !profiles.is_empty() {
            data.insert("profiles".into(), Value::Object(profiles));
        }
        if let Some(repo) = &read.repo
            && let Ok(Some(project)) = crate::graph::project_of(Path::new(repo)).await
        {
            data.insert("project".into(), json!(project.id));
        }
        ins.push(PlanIn {
            hash: read.hash.clone(),
            wants: wants_from(front, &key, &data),
            id: key,
            running,
        });
    }
    plan_forecast(front, ins).await
}

/// What `session:<sid>` says of the session: its profile, its project, and the role its work has (a worker's is that of
/// the task it last worked on, else `implement`; a manager's and a chat's are their own).
struct SessionFacts {
    profile: String,
    role: String,
    project: Option<String>,
}

async fn session_facts(front: &Front, sid: &str) -> Result<Option<SessionFacts>, Error> {
    let (key, task_sid) = (format!("session:{sid}"), sid.to_owned());
    let read = front.writer.db.read(move |c| {
        let Some(e) = urdr::graph::entity::by_id(c, &key)? else {
            return Ok(None);
        };
        let field = |k: &str| e.data.get(k).and_then(Value::as_str).map(str::to_owned);
        let role = match field("role").as_deref() {
            Some("manager") => "manager".to_owned(),
            Some("chat") => "chat".to_owned(),
            _ => {
                let task: Option<String> = c
                    .query_row(
                        "select task from step where session = ?1 and task is not null order by id desc limit 1",
                        [&task_sid],
                        |r| r.get(0),
                    )
                    .ok();
                task.and_then(|t| norn::read::tasks::task_row(c, &t).ok().flatten())
                    .and_then(|t| t.role)
                    .unwrap_or_else(|| "implement".to_owned())
            }
        };
        Ok(Some(SessionFacts {
            profile: field("profile").unwrap_or_else(|| "claude".to_owned()),
            role,
            project: None,
        }))
    });
    read.await.map_err(crate::coord::fail)
}

/// `forecast/session`: one more run like a session: one task of its role and profile (or P's profile), the class's
/// plain picks, nothing recorded.
pub async fn session(
    front: &Front,
    p: wire::SessionForecastParams,
) -> Result<wire::Forecast, Error> {
    let sid = p.session.as_str().to_owned();
    let facts = session_facts(front, &sid)
        .await?
        .ok_or_else(|| crate::runner::invalid(format!("No session {sid}")))?;
    let profile = p.profile.map_or(facts.profile, |b| b.into_inner());
    let want = Want {
        n: 1,
        role: facts.role,
        model: find_profile(front, &profile).and_then(|p| p.model),
        profile,
        project: facts.project,
        brief_bytes: 0,
        deps: Vec::new(),
    };
    Ok(build(front, &sid, vec![want], true, None).await?.0)
}

/// `forecast/accuracy`: how past forecasts fared against what the tasks took, per role and profile.
pub async fn accuracy(front: &Front, p: wire::AccuracyParams) -> Result<wire::Accuracy, Error> {
    let (role, profile) = (
        p.role.map(|t| t.as_str().to_owned()),
        p.profile.map(|t| t.as_str().to_owned()),
    );
    let rows: Vec<(String, Option<String>, f64, f64, f64)> = front
        .writer
        .db
        .read(|c| {
            let mut st = c.prepare(
                "select m.role, m.profile, m.tokens_p50, m.tokens_p90, \
                 s.tokens_in + s.tokens_out + s.cache_read + s.cache_write \
                 from forecast_made m join forecast_sample s on s.task = m.task where m.role is not null",
            )?;
            let rows = st.query_map([], |r| {
                Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get::<_, i64>(4)? as f64))
            })?;
            Ok(rows.collect::<Result<_, _>>()?)
        })
        .await
        .map_err(crate::coord::fail)?;
    type Group = BTreeMap<(String, Option<String>), Vec<(f64, f64, f64)>>;
    let mut groups: Group = BTreeMap::new();
    for (r, pr, p50, p90, actual) in rows {
        if role.as_ref().is_some_and(|x| *x != r)
            || profile.as_ref().is_some_and(|x| Some(x) != pr.as_ref())
        {
            continue;
        }
        groups.entry((r, pr)).or_default().push((p50, p90, actual));
    }
    let rows = groups
        .into_iter()
        .map(|((role, profile), v)| {
            let n = v.len();
            let covered = v.iter().filter(|(_, p90, a)| a <= p90).count();
            let mut ratios: Vec<f64> = v
                .iter()
                .filter(|(p50, _, _)| *p50 > 0.0)
                .map(|(p50, _, a)| a / p50)
                .collect();
            ratios.sort_by(f64::total_cmp);
            wire::AccuracyRow {
                role,
                profile,
                n: u32::try_from(n).unwrap_or(u32::MAX),
                coverage: covered as f64 / n as f64,
                median_ratio: sim::quantile(&ratios, 0.5),
            }
        })
        .collect();
    Ok(wire::Accuracy { rows })
}

/// Sample every finished task that is due, page by page, until none is.  Best effort: a store that is not ready
/// ends the sweep, and the next one starts again.
pub async fn sweep(front: &Front) {
    let profiles = profiles_by_name(front);
    loop {
        let m = profiles.clone();
        let page = front
            .writer
            .db
            .read(move |c| {
                let facts = |profile: Option<&str>, role: &str| {
                    let p = profile.and_then(|p| m.get(p));
                    ProfileFacts {
                        model: p.and_then(|p| p.model.clone()),
                        ttl_secs: p.map_or(DEFAULT_TTL_SECS, |p| ttl_of(p, role_of(role))),
                    }
                };
                let due = sample::due(c, PAGE)?;
                let n = due.len();
                let mut rows = Vec::new();
                for task in due {
                    rows.extend(sample::gather(c, &task, &facts)?);
                }
                Ok((n, rows))
            })
            .await;
        let (due, mut rows) = match page {
            Ok(p) => p,
            Err(e) => {
                tracing::debug!("forecast sweep: {e}");
                return;
            }
        };
        if rows.is_empty() {
            return;
        }
        let at = crate::clock::wall_secs();
        for r in &mut rows {
            r.at = at;
        }
        let wrote = front
            .writer
            .write(&crate::runner::service(), "forecast/sample", move |tx| {
                for r in &rows {
                    sample::put(tx, r)?;
                }
                Ok(())
            })
            .await;
        if let Err(e) = wrote {
            tracing::debug!("forecast sweep: {e}");
            return;
        }
        if i64::try_from(due).unwrap_or(PAGE) < PAGE {
            return;
        }
    }
}

/// `forecast/start`: the start step of a proposed job (docs/develop/hub.md, "The start step"): the forecast of the job, as
/// [`crate::work::map::budget_detail::start_of`] reads it.
pub async fn start(
    front: &Front,
    caller: &Caller,
    p: wire::StartParams,
) -> Result<wire::StartView, Error> {
    let f = get(
        front,
        caller,
        wire::ForecastParams {
            job: p.job,
            remaining: None,
        },
    )
    .await?;
    Ok(crate::work::map::budget_detail::view_of(
        &crate::work::map::budget_detail::start_of(&f, p.utc_offset),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::settings::{AgentProfile, defaults};
    use norn::forecast::model::Level;
    use runstav::methods::forecast::{BasisLevel, Range, SessionForecastParams};
    use runstav::types::Id;

    fn profile(model: Option<&str>, command: &str, ai: Option<&str>) -> AgentProfile {
        AgentProfile {
            name: "p".into(),
            command: vec![command.into()],
            env: Vec::new(),
            mode: None,
            ai: ai.map(str::to_owned),
            model: model.map(str::to_owned),
            tracker_tools: None,
            doc: None,
            provider: None,
            job_safe: false,
            acp_v2: None,
        }
    }

    fn shipped() -> Vec<crate::settings::ModelPrice> {
        defaults().values.agents_model_prices.clone()
    }

    /// Pure (D): an id longer than a row's key picks the row with the longest key that is its prefix.
    #[test]
    fn a_model_id_takes_the_longest_matching_prefix() {
        let p = profile(Some("claude-opus-5-5-20261001"), "claude-agent-acp", None);
        let r = rates_in(&shipped(), &p, None).unwrap();
        assert_eq!((r.input, r.output, r.cache_read), (4.0, 20.0, 0.2));
        let s = profile(Some("claude-sonnet-5-5"), "claude-agent-acp", None);
        assert_eq!(rates_in(&shipped(), &s, None).unwrap().input, 2.0);
        // a bare "claude" row never beats a longer one
        let mut table = shipped();
        table.push(crate::settings::ModelPrice {
            key: "claude-".into(),
            input: 99.0,
            output: 99.0,
            cache_read: None,
            write_5m: None,
            write_1h: None,
            as_of: None,
        });
        assert_eq!(rates_in(&table, &p, None).unwrap().input, 4.0);
    }

    /// Pure (D): a Claude profile with no model set is the table's `claude` row.
    #[test]
    fn a_claude_profile_with_no_model_takes_the_claude_row() {
        let p = profile(None, "claude-agent-acp", None);
        assert_eq!(rates_in(&shipped(), &p, None).unwrap().output, 20.0);
    }

    /// Pure (D): with no row for the model, a gateway provider's `:price (IN . OUT)` serves, cache tokens at the
    /// input rate.
    #[test]
    fn a_gateway_provider_price_serves_when_no_row_matches() {
        let p = profile(Some("kimi-k3"), "claude-agent-acp", Some("claude-moonshot"));
        let r = rates_in(&shipped(), &p, Some((3.0, 15.0))).unwrap();
        assert_eq!(
            (r.input, r.output, r.cache_read, r.write_5m, r.write_1h),
            (3.0, 15.0, 3.0, 3.0, 3.0)
        );
    }

    /// Pure (D).
    #[test]
    fn no_row_and_no_price_is_none() {
        let p = profile(Some("gpt-5"), "codex-acp", None);
        assert_eq!(rates_in(&shipped(), &p, None), None);
        // a subscription profile never takes a gateway price
        assert_eq!(rates_in(&shipped(), &p, Some((1.0, 1.0))), None);
    }

    /// Pure (D).
    #[test]
    fn the_default_table_has_the_dated_rows() {
        let t = shipped();
        assert_eq!(prices_as_of(&t), "2026-11-01");
        let key = |k: &str| t.iter().find(|r| r.key == k).unwrap();
        let haiku = key("claude-haiku-5-5");
        assert_eq!((haiku.input, haiku.output), (0.5, 2.5));
        assert_eq!(haiku.write_5m, Some(0.625));
        let fable = key("claude-fable-5-1");
        assert_eq!(
            (fable.input, fable.output, fable.write_1h),
            (10.0, 50.0, Some(20.0))
        );
        assert_eq!(key("claude").input, key("claude-opus-5-5").input);
        assert_eq!(prices_as_of(&[]), "");
    }

    /// Pure (D): who set the TTL decides it.
    #[test]
    fn ttl_follows_who_set_it() {
        let sub = profile(None, "claude-agent-acp", None);
        let gw = profile(None, "claude-agent-acp", Some("claude-openrouter"));
        let codex = profile(None, "codex-acp", None);
        for role in [Role::Worker, Role::Manager, Role::Chat] {
            assert_eq!(ttl_of(&sub, role), 3600.0, "{role:?}");
        }
        assert_eq!(ttl_of(&gw, Role::Worker), 3600.0);
        assert_eq!(ttl_of(&gw, Role::Manager), 3600.0);
        assert_eq!(ttl_of(&gw, Role::Chat), 300.0);
        assert_eq!(ttl_of(&codex, Role::Worker), 300.0);
    }

    /// Pure (D).
    #[test]
    fn a_forecast_says_its_basis_in_words() {
        assert_eq!(
            basis_label(Level::Project, 12, false, "implement", "sonnet"),
            "12 implement tasks on sonnet, this project"
        );
        assert_eq!(
            basis_label(Level::Profile, 7, false, "implement", "sonnet"),
            "7 implement tasks on sonnet"
        );
        assert_eq!(
            basis_label(Level::Role, 9, true, "review", "sonnet"),
            "9 review tasks on another model, repriced"
        );
        assert_eq!(
            basis_label(Level::Any, 11, true, "review", "sonnet"),
            "11 tasks of other roles, repriced"
        );
        assert_eq!(
            basis_label(Level::Prior, 0, false, "implement", "sonnet"),
            "no history: prior"
        );
    }

    /// Pure (D): the factor scales p90 and never takes it below p50; p50 is never touched.
    #[test]
    fn a_calibrated_task_says_so_and_scales_p90_only() {
        let r = Range {
            p50: 100.0,
            p90: 200.0,
        };
        assert_eq!(
            calibrate(r, 2.0),
            Range {
                p50: 100.0,
                p90: 400.0
            }
        );
        assert_eq!(
            calibrate(r, 0.25),
            Range {
                p50: 100.0,
                p90: 100.0
            }
        );
    }

    fn front(dir: &std::path::Path) -> Front {
        Front::new(
            runstav::proof::Cap::generate().unwrap(),
            dir.join("hub-x.sock"),
            crate::store::WorkDb::spawn(dir.join("work.db")).unwrap(),
            norn::store::CoordDb::spawn(dir.join("work.db")),
        )
    }

    async fn session_entity(front: &Front, sid: &str, data: serde_json::Value) {
        use urdr::graph::entity::{self, EntityNew, Origin};
        let id = format!("session:{sid}");
        front
            .writer
            .write(&crate::runner::service(), "agents/start", move |tx| {
                entity::create(
                    tx,
                    EntityNew {
                        id: id.clone(),
                        kind: "session".into(),
                        project: None,
                        title: Some("s".into()),
                        status: None,
                        body: None,
                        priority: None,
                        assignee: None,
                        data: data.clone(),
                        origin: Origin::Recorded,
                        source: None,
                    },
                )
                .map(drop)
                .map_err(|e| norn::store::CoordError::Refused(e.to_string()))
            })
            .await
            .unwrap();
    }

    /// Pure (D): a store in a temp folder, a fixed seed.  A session's forecast is one task of its role and
    /// profile, from the prior on a fresh store, and records nothing.
    #[tokio::test(flavor = "multi_thread")]
    async fn a_sessions_forecast_is_one_task_of_its_role_and_profile() {
        let dir = tempfile::tempdir().unwrap();
        let f = front(dir.path());
        session_entity(
            &f,
            "s1",
            serde_json::json!({"profile": "sonnet", "role": "worker", "job": null}),
        )
        .await;
        let got = session(
            &f,
            SessionForecastParams {
                session: Id::new("s1").unwrap(),
                profile: None,
            },
        )
        .await
        .unwrap();
        assert_eq!(got.tasks.len(), 1);
        let t = &got.tasks[0];
        assert_eq!(
            (t.role.as_str(), t.profile.as_str()),
            ("implement", "sonnet")
        );
        assert_eq!(t.basis.level, BasisLevel::Prior);
        assert!(t.tokens.p90 > t.tokens.p50);
        // no price for a profile that is not configured: unpriced, never zero
        assert!(t.cost.is_empty());
        assert_eq!(got.unpriced, ["sonnet"]);
        let made = f
            .writer
            .db
            .read(|c| {
                Ok(c.query_row("select count(*) from forecast_made", [], |r| {
                    r.get::<_, i64>(0)
                })?)
            })
            .await
            .unwrap();
        assert_eq!(made, 0);
    }

    /// Pure (D): a thin class never prints a tight range, and a priced profile has one unit.
    #[tokio::test(flavor = "multi_thread")]
    async fn a_priced_session_forecast_has_its_unit() {
        let dir = tempfile::tempdir().unwrap();
        let f = front(dir.path());
        session_entity(
            &f,
            "s2",
            serde_json::json!({"profile": "claude", "role": "worker", "job": null}),
        )
        .await;
        let got = session(
            &f,
            SessionForecastParams {
                session: Id::new("s2").unwrap(),
                profile: None,
            },
        )
        .await
        .unwrap();
        let t = &got.tasks[0];
        assert_eq!(t.cost.len(), 1);
        assert_eq!(t.cost[0].unit, Unit::UsdEst);
        assert!(t.cost[0].estimate && t.cost[0].p50 > 0.0);
        assert!(got.unpriced.is_empty());
        assert_eq!(got.prices_as_of, "2026-11-01");
    }

    fn meter(used: f64, rate: f64, resets_at: Option<f64>) -> runstav::methods::timeline::Pace {
        runstav::methods::timeline::Pace {
            provider: "claude".into(),
            used_share: used,
            rate_per_hour: rate,
            exhausted_at: None,
            resets_at,
            estimate: true,
            window: "week".into(),
            rate_7d_per_hour: None,
            history: Vec::new(),
        }
    }

    /// Pure (D): the share per dollar is the meter's rises over what was spent in estimated dollars.
    #[test]
    fn share_per_usd_divides_rises_by_estimated_spend() {
        let history = [(0.0, 0.1), (900.0, 0.2)];
        let got = share_per_usd_of(&history, 20.0).unwrap();
        assert!((got - 0.005).abs() < 1e-12, "{got}");
    }

    /// Pure (D): a store in a temp folder.  `share_per_usd` reads the `usd-est` the provider's steps booked since the
    /// meter's first reading: not another provider's, not another unit, not a step from before the readings.
    #[tokio::test(flavor = "multi_thread")]
    async fn share_per_usd_reads_the_estimated_spend_of_real_steps() {
        use norn::write::steps::{StepClass, StepEnd, StepNew, close, open};
        let dir = tempfile::tempdir().unwrap();
        let f = front(dir.path());
        session_entity(
            &f,
            "s1",
            serde_json::json!({"profile": "claude", "role": "worker", "job": null}),
        )
        .await;
        let scope: runstav::methods::timeline::BudgetScope =
            serde_json::from_value(serde_json::json!({"worker": "w1"})).unwrap();
        f.core
            .budgets
            .reading(&scope, "claude", "5h", 0.10, None, 1000.0);
        f.core
            .budgets
            .reading(&scope, "claude", "5h", 0.20, None, 1900.0);
        f.writer
            .write(&crate::runner::service(), "test/steps", |tx| {
                // (provider, start, cost, unit)
                for (provider, start, cost, unit) in [
                    ("claude", 500.0, 50.0, "usd-est"), // before the first reading
                    ("claude", 1100.0, 4.0, "usd-est"),
                    ("claude", 1200.0, 6.0, "usd-est"),
                    ("claude", 1300.0, 9.0, "tokens"), // another unit
                    ("codex", 1400.0, 30.0, "usd-est"), // another provider
                ] {
                    let id = open(
                        tx,
                        StepNew {
                            session: "session:s1".into(),
                            task: None,
                            plan: None,
                            project: None,
                            agent: None,
                            provider: Some(provider.into()),
                            class: StepClass::Think,
                            start,
                            tool: None,
                            tool_kind: None,
                            message_id: None,
                            turn_id: None,
                            snapshot: None,
                            log_version: None,
                            acp: None,
                            machine: None,
                            slots: None,
                        },
                    )?;
                    close(
                        tx,
                        id,
                        StepEnd {
                            end: start + 1.0,
                            cost: Some(cost),
                            cost_unit: Some(unit.into()),
                            ..StepEnd::default()
                        },
                    )?;
                }
                Ok(())
            })
            .await
            .unwrap();
        // the meter rose 0.10 while 4 + 6 estimated dollars were booked
        let got = share_per_usd(&f, "claude", "5h", 2000.0).await.unwrap();
        assert!((got - 0.01).abs() < 1e-12, "{got}");
        assert_eq!(
            share_per_usd(&f, "codex", "5h", 2000.0).await,
            None,
            "no meter readings"
        );
    }

    /// Pure (D): use outside drgnx raises the share per dollar, and the effect says it is an estimate.
    #[test]
    fn outside_use_makes_it_higher_and_it_is_labelled_an_estimate() {
        let ours = share_per_usd_of(&[(0.0, 0.1), (900.0, 0.2)], 20.0).unwrap();
        let with_outside = share_per_usd_of(&[(0.0, 0.1), (900.0, 0.25)], 20.0).unwrap();
        assert!(with_outside > ours);
        let (effect, _) = pace_effect(&meter(0.2, 0.0, None), None, 0.0);
        assert!(effect.estimate);
    }

    /// Pure (D): no estimated spend, or a meter that never rose, has no pace: the view says so.
    #[test]
    fn no_usd_est_or_no_rises_gives_none() {
        assert_eq!(share_per_usd_of(&[(0.0, 0.5), (900.0, 0.5)], 20.0), None);
        assert_eq!(share_per_usd_of(&[(0.0, 0.1), (900.0, 0.2)], 0.0), None);
        assert_eq!(share_per_usd_of(&[], 5.0), None);
        let (effect, warning) = pace_effect(&meter(0.2, 0.0, None), None, 0.0);
        assert_eq!(effect.added_share, None);
        assert!(!effect.runs_out_p90 && warning.is_none());
    }

    /// Pure (D): used 0.6 and 0.01 an hour with the reset 72 h away, and a plan whose p90 adds 0.2, runs out first.
    #[test]
    fn a_plan_that_outruns_the_reset_warns() {
        let now = 1_000_000.0;
        let m = meter(0.6, 0.01, Some(now + 72.0 * 3600.0));
        let added = wire::Range { p50: 0.1, p90: 0.2 };
        let (effect, warning) = pace_effect(&m, Some(added), now);
        assert!(effect.runs_out_p90);
        assert!(warning.unwrap().contains("claude"));
        assert_eq!(effect.added_share, Some(added));
        // the middle share alone also runs out at this rate: when, is before the reset
        assert!(
            effect
                .exhausted_after
                .is_some_and(|t| t < now + 72.0 * 3600.0)
        );
        // a small plan on a slow meter does not
        let slow = meter(0.3, 0.001, Some(now + 72.0 * 3600.0));
        let small = wire::Range {
            p50: 0.01,
            p90: 0.02,
        };
        let (effect, warning) = pace_effect(&slow, Some(small), now);
        assert!(!effect.runs_out_p90 && warning.is_none());
    }

    /// Pure (D): a reset more than a day off is the week, else this window.
    #[test]
    fn resets_more_than_a_day_off_is_the_week_else_this_window() {
        let now = 5_000.0;
        assert_eq!(
            window_of(Some(now + 2.0 * 86_400.0), now),
            wire::PaceWindow::Week
        );
        assert_eq!(window_of(Some(now + 7_200.0), now), wire::PaceWindow::Short);
        assert_eq!(window_of(None, now), wire::PaceWindow::Short);
    }

    /// A finished plan PLAN of one task: what its forecast said of the whole plan (a tokens p90 of P90, before
    /// calibration) and what its task used (ACTUAL tokens).
    fn finished_plan(
        tx: &mut norn::store::WTx<'_>,
        plan: &str,
        p90: f64,
        actual: i64,
    ) -> Result<(), norn::store::CoordError> {
        use norn::write::jobs::{NewJob, NewTask, job_create, job_set};
        job_create(
            tx,
            NewJob {
                id: plan.into(),
                title: "p".into(),
                plan: None,
                repo: None,
                tasks: vec![NewTask {
                    n: 1,
                    title: "t".into(),
                    role: Some("docs".into()),
                    deps: Vec::new(),
                }],
                data: None,
            },
            1.0,
        )?;
        job_set(tx, plan, Some("done"), None, 2.0)?;
        sample::record_made(
            tx,
            &[Made {
                job: plan.into(),
                task: plan.into(),
                made_at: 1.0,
                role: None,
                profile: None,
                model: None,
                tokens_p50: p90 / 2.0,
                tokens_p90: p90,
                secs_p50: 1.0,
                secs_p90: 2.0,
                cost_p50: None,
                cost_p90: None,
                cost_unit: None,
                basis: "1 tasks".into(),
                n: 0,
                start_p50: 0.0,
                start_p90: 0.0,
                finish_p50: 2.0,
                finish_p90: 3.0,
            }],
        )?;
        sample::put(
            tx,
            &SampleRow {
                task: format!("{plan}#1"),
                job: plan.into(),
                project: None,
                role: "docs".into(),
                profile: Some("claude".into()),
                provider: None,
                model: None,
                brief_bytes: 0,
                tasks: 1,
                tokens_in: actual,
                tokens_out: 0,
                cache_read: 0,
                cache_write: 0,
                turns: 1,
                active_secs: 60.0,
                wall_secs: 60.0,
                job_wait_secs: 0.0,
                wakes: 0,
                cold_wakes: 0,
                context: None,
                cost: None,
                cost_unit: None,
                outcome: "done".into(),
                last_step: 1,
                at: 2.0,
            },
        )
    }

    /// Pure (D): a store in a temp folder, a fixed seed.  Nine finished plans each used 3× the tokens their total's
    /// p90 said.  The next plan's total p90, of tokens and of cost (what the Autonomous rule reads), is scaled by that
    /// factor and p50 is not; the row kept for later calibration holds the p90 before it.
    #[tokio::test(flavor = "multi_thread")]
    async fn the_plan_total_is_calibrated_by_past_plans() {
        let dir = tempfile::tempdir().unwrap();
        let f = front(dir.path());
        f.writer
            .write(&crate::runner::service(), "test/history", |tx| {
                for k in 1..=9 {
                    finished_plan(tx, &format!("P{k}"), 100.0, 300)?;
                }
                Ok(())
            })
            .await
            .unwrap();
        let want = |n: i64| Want {
            n,
            role: "implement".into(),
            profile: "claude".into(),
            model: None,
            project: None,
            brief_bytes: 1000,
            deps: Vec::new(),
        };
        let (fc, made) = for_job(&f, "J", vec![want(1), want(2)]).await.unwrap();
        let plan = made.iter().find(|m| m.task == "J").unwrap();
        assert!(
            (fc.tokens.p90 - 3.0 * plan.tokens_p90).abs() < 1e-6,
            "{} against {}",
            fc.tokens.p90,
            plan.tokens_p90
        );
        assert_eq!(fc.tokens.p50, plan.tokens_p50);
        let (cost, kept) = (&fc.cost[0], plan.cost_p90.unwrap());
        assert!(
            (cost.p90 - 3.0 * kept).abs() < 1e-6,
            "{} against {kept}",
            cost.p90
        );
        assert_eq!(cost.p50, plan.cost_p50.unwrap());
    }

    fn want_of(n: i64, deps: &[i64]) -> Want {
        Want {
            n,
            role: "implement".into(),
            profile: "claude".into(),
            model: None,
            project: None,
            brief_bytes: 1000,
            deps: deps.to_vec(),
        }
    }

    fn plan_in(id: &str, hash: &str, tasks: i64) -> PlanIn {
        PlanIn {
            id: id.into(),
            hash: hash.into(),
            wants: (1..=tasks)
                .map(|n| want_of(n, if n > 1 { &[1] } else { &[] }))
                .collect(),
            running: None,
        }
    }

    /// Pure (D): a store in a temp folder, a fixed seed.  Three plans of four tasks drawn together finish by a later
    /// time than one of them, but earlier than the plans one after another: the joint p90 is below the sum of the
    /// plans' own p90s (the slots run them side by side, and the sum of quantiles over-counts).
    #[tokio::test(flavor = "multi_thread")]
    async fn a_spec_total_is_a_joint_draw_not_a_sum_of_p90s() {
        let dir = tempfile::tempdir().unwrap();
        let f = front(dir.path());
        let plans = [
            plan_in("plan:j-a", "1", 4),
            plan_in("plan:j-b", "1", 4),
            plan_in("plan:j-c", "1", 4),
        ];
        let joint = plan_forecast(&f, plans.to_vec()).await.unwrap();
        let mut sum_wall = 0.0;
        let mut sum_tokens = 0.0;
        for p in &plans {
            let one = plan_forecast(&f, vec![p.clone()]).await.unwrap();
            sum_wall += one.forecast.wall_secs.p90;
            sum_tokens += one.forecast.tokens.p90;
        }
        assert!(
            joint.forecast.wall_secs.p90 < sum_wall,
            "{} against {sum_wall}",
            joint.forecast.wall_secs.p90
        );
        assert!(
            joint.forecast.tokens.p90 < sum_tokens,
            "{} against {sum_tokens}",
            joint.forecast.tokens.p90
        );
        assert_eq!(joint.forecast.tasks.len(), 12);
        assert!(joint.running.is_empty());
    }

    /// Pure (D): a plan with a running job is answered with that job's own forecast and is not in the draw: adding it
    /// changes nothing of the joint forecast (Review Focus 5: a spec's total is never the sum of a running plan's too).
    #[tokio::test(flavor = "multi_thread")]
    async fn a_spec_with_a_running_plan_is_not_summed() {
        let dir = tempfile::tempdir().unwrap();
        let f = front(dir.path());
        let alone = plan_forecast(&f, vec![plan_in("plan:r-a", "1", 3)])
            .await
            .unwrap();
        let own = plan_forecast(&f, vec![plan_in("plan:r-run", "1", 6)])
            .await
            .unwrap()
            .forecast;
        let mut running = plan_in("plan:r-run", "1", 6);
        running.running = Some(("job-1".into(), own.clone()));
        let both = plan_forecast(&f, vec![plan_in("plan:r-a", "1", 3), running])
            .await
            .unwrap();
        assert_eq!(both.forecast.tokens, alone.forecast.tokens);
        assert_eq!(both.forecast.tasks.len(), 3);
        assert_eq!(both.running.len(), 1);
        assert_eq!(
            (both.running[0].plan.as_str(), both.running[0].job.as_str()),
            ("plan:r-run", "job-1")
        );
        assert_eq!(both.running[0].remaining, own);
    }

    /// Pure (D): an answer is kept for the plans' versions and not served for another one: a plan edit (its hash)
    /// misses, the same version hits, and a minute on misses too.
    #[test]
    fn the_cache_misses_after_a_plan_edit() {
        let mut c = PlanCache::default();
        let now = crate::clock::now();
        let a = plan_in("plan:a", "h1", 1);
        let fc = |t: f64| wire::Forecast {
            tasks: Vec::new(),
            tokens: Range { p50: t, p90: t },
            active_secs: Range::default(),
            wall_secs: Range::default(),
            cost: Vec::new(),
            unpriced: Vec::new(),
            wake: None,
            manager: None,
            pace: Vec::new(),
            warnings: Vec::new(),
            prices_as_of: String::new(),
            made_at: 0.0,
            baseline: None,
        };
        c.put(&[&a], now, fc(1.0));
        assert_eq!(c.get(&[&a], now).map(|f| f.tokens.p50), Some(1.0));
        let edited = plan_in("plan:a", "h2", 1);
        assert!(c.get(&[&edited], now).is_none(), "an edited plan is a miss");
        let later = now + std::time::Duration::from_secs(PLAN_CACHE_SECS + 1);
        assert!(c.get(&[&a], later).is_none(), "a minute on is a miss");
    }

    /// The perf lane's rows `forecast-plan-hit` (5 ms) and `forecast-plan-miss` (300 ms): 12 plans of 20 tasks drawn
    /// together, the first call (a miss) and the repeats (hits).  Ignored in normal runs: release, pinned
    /// (`perf-exclusive.sh env DRGNX_PERF_CPUS=4 cargo test --release -p ratatoskr --lib -- --ignored
    /// --nocapture forecast_plan_perf`).
    #[tokio::test(flavor = "multi_thread")]
    #[ignore = "timing: perf lane, the plan forecast's miss and hit budgets"]
    async fn forecast_plan_perf() {
        let dir = tempfile::tempdir().unwrap();
        let f = front(dir.path());
        let plans: Vec<PlanIn> = (0..12)
            .map(|i| plan_in(&format!("plan:perf-{i}"), "1", 20))
            .collect();
        let t = std::time::Instant::now();
        plan_forecast(&f, plans.clone()).await.unwrap();
        let miss = t.elapsed();
        let mut hits = Vec::new();
        for _ in 0..50 {
            let t = std::time::Instant::now();
            plan_forecast(&f, plans.clone()).await.unwrap();
            hits.push(t.elapsed());
        }
        hits.sort();
        let hit = hits[(hits.len() * 95).div_ceil(100) - 1];
        println!("forecast-plan: miss {miss:?}, hit p95 {hit:?}");
        assert!(
            miss < std::time::Duration::from_millis(300),
            "miss {miss:?}"
        );
        assert!(hit < std::time::Duration::from_millis(5), "hit p95 {hit:?}");
    }

    /// A job J of TASKS tasks, each needing the one before, with its tasks' data as a proposal keeps it; tasks
    /// numbered in DONE are finished, each with one closed step that ended before NOW.
    async fn half_done_job(f: &Front, tasks: i64, done: &[i64], now: f64) {
        use norn::write::jobs::{NewJob, NewTask, job_create, job_set};
        use norn::write::steps::{StepClass, StepEnd, StepNew, close, open};
        let done = done.to_vec();
        f.writer
            .write(&crate::runner::service(), "test/job", move |tx| {
                let deps = |n: i64| if n > 1 { vec![n - 1] } else { Vec::new() };
                let data: Vec<Value> = (1..=tasks)
                    .map(|n| json!({"n": n, "role": "implement", "deps": deps(n), "body": "b"}))
                    .collect();
                job_create(
                    tx,
                    NewJob {
                        id: "J".into(),
                        title: "j".into(),
                        plan: None,
                        repo: None,
                        tasks: (1..=tasks)
                            .map(|n| NewTask {
                                n,
                                title: format!("t{n}"),
                                role: Some("implement".into()),
                                deps: deps(n),
                            })
                            .collect(),
                        data: Some(json!({"tasks": data, "routes": {"implement": "claude"}})),
                    },
                    1.0,
                )?;
                job_set(tx, "J", Some("running"), None, 2.0)?;
                for n in &done {
                    let tid = format!("J#{n}");
                    norn::write::tasks::force_status(tx, &tid, "done", None, now)?;
                    let start = now - 1000.0 * (3 - n) as f64;
                    let id = open(
                        tx,
                        StepNew {
                            session: format!("session:s{n}"),
                            task: Some(tid.clone()),
                            plan: None,
                            project: None,
                            agent: None,
                            provider: None,
                            class: StepClass::Think,
                            start,
                            tool: None,
                            tool_kind: None,
                            message_id: None,
                            turn_id: None,
                            snapshot: None,
                            log_version: None,
                            acp: None,
                            machine: None,
                            slots: None,
                        },
                    )?;
                    close(
                        tx,
                        id,
                        StepEnd {
                            end: start + 600.0,
                            cost: Some(0.5),
                            cost_unit: Some("usd-est".into()),
                            ..StepEnd::default()
                        },
                    )?;
                }
                Ok(())
            })
            .await
            .unwrap();
    }

    /// Pure (D): a store in a temp folder, a fixed seed.  With two of four chained tasks done, what remains of the job
    /// (the running plan `forecast/plan` shows) ends sooner than the whole job's forecast, and costs less; the done
    /// tasks are their actuals at the wall clock, the next one starts no earlier than now.
    #[tokio::test(flavor = "multi_thread")]
    async fn a_half_done_plans_remaining_is_under_its_whole_forecast() {
        let dir = tempfile::tempdir().unwrap();
        let f = front(dir.path());
        let now = 1_000_000.0;
        half_done_job(&f, 4, &[1, 2], now).await;
        let whole = job_forecast(&f, "J").await.unwrap();
        let left = remaining_forecast(&f, "J", now).await.unwrap();
        assert!(
            left.wall_secs.p50 < whole.wall_secs.p50,
            "{} against {}",
            left.wall_secs.p50,
            whole.wall_secs.p50
        );
        assert!(left.tokens.p50 < whole.tokens.p50);
        let at: Vec<Option<wire::TaskAt>> = left.tasks.iter().map(|t| t.at).collect();
        use wire::TaskAt::{Done, Waiting};
        assert_eq!(at, [Some(Done), Some(Done), Some(Waiting), Some(Waiting)]);
        assert_eq!(
            left.tasks[0].start,
            Range {
                p50: now - 2000.0,
                p90: now - 2000.0
            }
        );
        assert_eq!(left.tasks[1].finish.p50, now - 400.0);
        assert_eq!(left.tasks[1].finish.p90, now - 400.0);
        assert!(left.tasks[2].start.p50 >= now, "{:?}", left.tasks[2].start);
        // a proposal's forecast has no state on its tasks
        assert!(whole.tasks.iter().all(|t| t.at.is_none()));
    }

    /// The perf lane's row `forecast-remaining` (300 ms): what remains of a 40-task job, half done, asked once (a
    /// miss of the cache).  Ignored in normal runs: release, pinned (`perf-exclusive.sh env DRGNX_PERF_CPUS=4 cargo
    /// test --release -p ratatoskr --lib -- --ignored --nocapture forecast_remaining_perf`).
    #[tokio::test(flavor = "multi_thread")]
    #[ignore = "timing: perf lane, what remains of a 40-task job within 300 ms"]
    async fn forecast_remaining_perf() {
        let dir = tempfile::tempdir().unwrap();
        let f = front(dir.path());
        let now = 1_000_000.0;
        half_done_job(&f, 40, &(1..=20).collect::<Vec<_>>(), now).await;
        let t = std::time::Instant::now();
        remaining_forecast(&f, "J", now).await.unwrap();
        let took = t.elapsed();
        println!("forecast-remaining: {took:?}");
        assert!(took < std::time::Duration::from_millis(300), "{took:?}");
    }

    /// Pure (D): the runner's tick and the forecast count slots with one function.
    #[test]
    fn the_slot_count_is_the_runners() {
        let dir = tempfile::tempdir().unwrap();
        let f = front(dir.path());
        assert_eq!(crate::runner::agent_slots(&f), crate::runner::MAX_AGENTS);
        assert!(include_str!("runner/tick.rs").contains("agent_slots("));
        assert!(!include_str!("runner/tick.rs").contains("count < MAX_AGENTS"));
    }
}
