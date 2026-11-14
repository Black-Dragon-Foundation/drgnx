//! The forecast's model (docs/develop/hub.md, "Forecasts"): which finished tasks a new task resembles, what tokens
//! cost, and what a wake costs. Pure: no store, no clock.

/// Tokens by how they are priced.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Usage {
    pub input: u64,
    pub output: u64,
    pub cache_read: u64,
    pub cache_write: u64,
}

impl Usage {
    /// Every token, cache reads included: what a forecast's and a sample's "tokens" both mean.
    pub fn total(&self) -> u64 {
        self.input + self.output + self.cache_read + self.cache_write
    }
}

/// One finished task, as the model sees it.
#[derive(Debug, Clone, PartialEq)]
pub struct Obs {
    pub role: String,
    pub profile: Option<String>,
    pub model: Option<String>,
    pub project: Option<String>,
    pub brief_bytes: u64,
    pub usage: Usage,
    pub active_secs: f64,
    pub wall_secs: f64,
    pub wakes: u32,
    pub cold_wakes: u32,
    pub context: Option<u64>,
    /// The recorded amount and its unit.
    pub cost: Option<(f64, String)>,
}

/// One task of a plan, before it runs. `deps` name other tasks' `n`.
#[derive(Debug, Clone, PartialEq)]
pub struct Want {
    pub n: i64,
    pub role: String,
    pub profile: String,
    pub model: Option<String>,
    pub project: Option<String>,
    pub brief_bytes: u64,
    pub deps: Vec<i64>,
}

/// How close a task's reference class is to it, closest first.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Level {
    Project,
    Profile,
    Role,
    Any,
    Prior,
}

/// The observations a task is forecast from.
#[derive(Debug, Clone, PartialEq)]
pub struct Class {
    pub level: Level,
    /// How many observations of history are in the class; 0 for the prior.
    pub n: u32,
    /// Some of the class ran on a model other than the task's, so its tokens are carried and repriced.
    pub other_model: bool,
    /// (index, weight). The index is into the `obs` given to [`reference_class`]; a prior's picks count on past its
    /// end, into the `prior` given, so `simulate` takes `obs` followed by `prior`.
    pub picks: Vec<(usize, f64)>,
}

/// A level needs this many observations; fewer say too little about the spread of runs.
pub const MIN_CLASS: usize = 5;

/// Briefs below this count as this: a few lines more or less is no difference in the work.
const BRIEF_FLOOR: u64 = 1024;

/// The weight's width, in log bytes: a brief twice the size weighs 0.61, four times 0.14.
const BRIEF_SIGMA: f64 = 0.7;

type Fits<'a> = &'a dyn Fn(&Obs) -> bool;

/// The class of `want`: the first level with [`MIN_CLASS`] observations, each weighted by how near its brief is to
/// the want's, else `prior`, unweighted, because a prior has no brief to compare. A row with no project is in no
/// project, and a row with no model on another profile is taken as another model.
pub fn reference_class(want: &Want, obs: &[Obs], prior: &[Obs]) -> Class {
    let same_profile = |o: &Obs| o.role == want.role && o.profile.as_deref() == Some(&want.profile);
    let same_setup = |o: &Obs| same_profile(o) && o.model == want.model;
    let this_project =
        |o: &Obs| same_setup(o) && want.project.is_some() && o.project == want.project;
    let same_role = |o: &Obs| o.role == want.role;
    let any = |_: &Obs| true;
    let levels: [(Level, Fits<'_>); 4] = [
        (Level::Project, &this_project),
        (Level::Profile, &same_setup),
        (Level::Role, &same_role),
        (Level::Any, &any),
    ];
    for (level, fits) in levels {
        let members: Vec<(usize, &Obs)> = obs.iter().enumerate().filter(|(_, o)| fits(o)).collect();
        if members.len() >= MIN_CLASS {
            return Class {
                level,
                n: members.len() as u32,
                other_model: members.iter().any(|(_, o)| !same_model(want, o)),
                picks: members
                    .iter()
                    .map(|(i, o)| (*i, brief_weight(want.brief_bytes, o.brief_bytes)))
                    .collect(),
            };
        }
    }
    Class {
        level: Level::Prior,
        n: 0,
        other_model: false,
        picks: (0..prior.len()).map(|i| (obs.len() + i, 1.0)).collect(),
    }
}

fn same_model(want: &Want, o: &Obs) -> bool {
    o.model == want.model && (o.model.is_some() || o.profile.as_deref() == Some(&want.profile))
}

/// `exp(-(ln b - ln b0)² / (2 · 0.7²))`.
fn brief_weight(want: u64, got: u64) -> f64 {
    let ln = |bytes: u64| (bytes.max(BRIEF_FLOOR) as f64).ln();
    let distance = ln(got) - ln(want);
    (-(distance * distance) / (2.0 * BRIEF_SIGMA * BRIEF_SIGMA)).exp()
}

/// What to expect with no history: a base task at ×⅓, ×½, ×1, ×2 and ×3, so the range stays wide (Bai et al.,
/// arXiv 2604.22750, measured runs of one task differing up to 30×).
///
/// Measured, on this project's agents of 2026-10 (the development note `lean-agent-budget`): 19M cache reads per
/// agent, and output under 0.5 % of the tokens. The other figures are judgement. A task's wakes and context are not
/// scaled: the wakes are an assumed count, and context is a level a task reaches, not something it adds up.
pub fn prior() -> Vec<Obs> {
    const MINUTE: f64 = 60.0;
    [1.0 / 3.0, 0.5, 1.0, 2.0, 3.0]
        .map(|x: f64| {
            let tokens = |base: f64| (base * x).round() as u64;
            Obs {
                role: "prior".to_owned(),
                profile: None,
                model: None,
                project: None,
                brief_bytes: 0,
                usage: Usage {
                    input: tokens(60_000.0),
                    output: tokens(90_000.0),
                    cache_read: tokens(19_000_000.0),
                    cache_write: tokens(600_000.0),
                },
                active_secs: 40.0 * MINUTE * x,
                wall_secs: 60.0 * MINUTE * x,
                wakes: 2,
                cold_wakes: 1,
                context: Some(300_000),
                cost: None,
            }
        })
        .to_vec()
}

/// USD per million tokens.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Rates {
    pub input: f64,
    pub output: f64,
    pub cache_read: f64,
    pub write_5m: f64,
    pub write_1h: f64,
}

const PER_MTOK: f64 = 1_000_000.0;

/// A TTL up to this writes at the 5 minute rate.
const SHORT_TTL_SECS: f64 = 300.0;

fn write_rate(r: &Rates, ttl_secs: f64) -> f64 {
    if ttl_secs <= SHORT_TTL_SECS {
        r.write_5m
    } else {
        r.write_1h
    }
}

/// The price of `u`. Cache writes pay for the profile's TTL.
pub fn usd(u: &Usage, r: &Rates, ttl_secs: f64) -> f64 {
    (u.input as f64 * r.input
        + u.output as f64 * r.output
        + u.cache_read as f64 * r.cache_read
        + u.cache_write as f64 * write_rate(r, ttl_secs))
        / PER_MTOK
}

/// The price of waking a session of `context` tokens after a job of `job_secs`: a cache read while the cache lives,
/// after that a rewrite of the whole context. A wait of exactly the TTL is still warm, as a sample counts it.
pub fn wake_usd(context: u64, job_secs: f64, ttl_secs: f64, r: &Rates) -> f64 {
    let rate = if job_secs <= ttl_secs {
        r.cache_read
    } else {
        write_rate(r, ttl_secs)
    };
    context as f64 * rate / PER_MTOK
}

#[cfg(test)]
mod tests {
    use super::*;

    const KIB: u64 = 1024;
    const OPUS: Rates = Rates {
        input: 4.0,
        output: 20.0,
        cache_read: 0.20,
        write_5m: 5.0,
        write_1h: 8.0,
    };

    fn obs(role: &str, profile: &str, model: Option<&str>, project: Option<&str>) -> Obs {
        Obs {
            role: role.to_owned(),
            profile: Some(profile.to_owned()),
            model: model.map(str::to_owned),
            project: project.map(str::to_owned),
            brief_bytes: 4 * KIB,
            usage: Usage::default(),
            active_secs: 1.0,
            wall_secs: 1.0,
            wakes: 0,
            cold_wakes: 0,
            context: None,
            cost: None,
        }
    }

    fn want() -> Want {
        Want {
            n: 1,
            role: "implement".to_owned(),
            profile: "sonnet".to_owned(),
            model: Some("m1".to_owned()),
            project: Some("p".to_owned()),
            brief_bytes: 4 * KIB,
            deps: vec![],
        }
    }

    fn many(k: usize, o: Obs) -> Vec<Obs> {
        vec![o; k]
    }

    fn near(got: f64, expected: f64) {
        assert!((got - expected).abs() < 1e-9, "{got} is not {expected}");
    }

    #[test]
    fn the_first_level_with_five_samples_wins() {
        let obs = many(5, obs("implement", "sonnet", Some("m1"), Some("p")));
        let class = reference_class(&want(), &obs, &prior());
        assert_eq!(class.level, Level::Project);
        assert_eq!(class.n, 5);
        assert!(!class.other_model);
        assert_eq!(class.picks.len(), 5);
    }

    #[test]
    fn four_on_this_project_fall_back_to_the_profile_level() {
        let mut all = many(4, obs("implement", "sonnet", Some("m1"), Some("p")));
        all.push(obs("implement", "sonnet", Some("m1"), Some("elsewhere")));
        let class = reference_class(&want(), &all, &prior());
        assert_eq!(class.level, Level::Profile);
        assert_eq!(class.n, 5);
        assert!(!class.other_model);
    }

    #[test]
    fn a_new_model_on_the_same_profile_is_not_the_same_class() {
        let obs = many(5, obs("implement", "sonnet", Some("m0"), Some("p")));
        let class = reference_class(&want(), &obs, &prior());
        assert_eq!(class.level, Level::Role);
        assert!(class.other_model);
    }

    #[test]
    fn thin_history_falls_back_to_a_labelled_prior() {
        let obs = many(3, obs("implement", "sonnet", Some("m1"), Some("p")));
        let prior = prior();
        let class = reference_class(&want(), &obs, &prior);
        assert_eq!(class.level, Level::Prior);
        assert_eq!(class.n, 0);
        assert!(!class.other_model);
        assert_eq!(class.picks.len(), prior.len());
    }

    #[test]
    fn a_prior_pick_counts_on_past_the_history() {
        let obs = many(3, obs("implement", "sonnet", Some("m1"), Some("p")));
        let class = reference_class(&want(), &obs, &prior());
        assert_eq!(class.picks[0], (3, 1.0));
        assert_eq!(class.picks[4], (7, 1.0));
    }

    #[test]
    fn five_of_another_role_make_the_any_level() {
        let obs = many(5, obs("review", "opus", Some("m1"), Some("p")));
        let class = reference_class(&want(), &obs, &prior());
        assert_eq!(class.level, Level::Any);
        assert_eq!(class.n, 5);
        assert!(!class.other_model, "the same model on another profile");
    }

    #[test]
    fn another_profile_on_the_same_model_is_not_another_model() {
        let obs = many(5, obs("implement", "other", Some("m1"), Some("p")));
        let class = reference_class(&want(), &obs, &prior());
        assert_eq!(class.level, Level::Role);
        assert!(!class.other_model);
    }

    #[test]
    fn two_profiles_with_no_model_are_taken_as_different_models() {
        let mut want = want();
        want.model = None;
        let obs = many(5, obs("implement", "other", None, Some("p")));
        let class = reference_class(&want, &obs, &prior());
        assert_eq!(class.level, Level::Role);
        assert!(class.other_model);
    }

    #[test]
    fn no_project_is_not_a_project() {
        let mut want = want();
        want.project = None;
        let obs = many(5, obs("implement", "sonnet", Some("m1"), None));
        assert_eq!(reference_class(&want, &obs, &prior()).level, Level::Profile);
    }

    #[test]
    fn a_similar_brief_weighs_more() {
        let mut far = obs("implement", "sonnet", Some("m1"), Some("p"));
        far.brief_bytes = 64 * KIB;
        let mut all = vec![obs("implement", "sonnet", Some("m1"), Some("p"))];
        all.extend(many(4, far));
        let class = reference_class(&want(), &all, &prior());
        assert!(class.picks[0].1 / class.picks[1].1 > 5.0);
    }

    #[test]
    fn the_weight_follows_the_formula() {
        near(brief_weight(4 * KIB, 4 * KIB), 1.0);
        near(
            brief_weight(4 * KIB, 8 * KIB),
            (-(2f64.ln().powi(2)) / 0.98).exp(),
        );
        near(
            brief_weight(8 * KIB, 4 * KIB),
            brief_weight(4 * KIB, 8 * KIB),
        );
    }

    #[test]
    fn briefs_under_the_floor_weigh_the_same() {
        near(brief_weight(10, 1000), 1.0);
        near(brief_weight(0, 2 * KIB), brief_weight(KIB, 2 * KIB));
    }

    #[test]
    fn the_prior_spreads_its_base() {
        let prior = prior();
        assert_eq!(prior.len(), 5);
        let base = &prior[2];
        assert_eq!(base.usage.cache_read, 19_000_000);
        assert_eq!(base.usage.cache_write, 600_000);
        assert_eq!(base.usage.input, 60_000);
        assert_eq!(base.usage.output, 90_000);
        near(base.active_secs, 2400.0);
        near(base.wall_secs, 3600.0);
        assert_eq!(prior[0].usage.cache_read, 6_333_333);
        assert_eq!(prior[4].usage.cache_read, 57_000_000);
        near(prior[4].wall_secs, 10_800.0);
        for o in &prior {
            assert_eq!((o.wakes, o.cold_wakes, o.context), (2, 1, Some(300_000)));
            assert_eq!(o.cost, None);
        }
    }

    #[test]
    fn a_wake_within_the_ttl_is_a_cache_read() {
        near(wake_usd(300_000, 60.0, 3600.0, &OPUS), 0.06);
    }

    #[test]
    fn a_wake_after_a_five_minute_ttl_is_a_rewrite() {
        near(wake_usd(300_000, 600.0, 300.0, &OPUS), 1.50);
    }

    #[test]
    fn a_wake_after_an_hour_ttl_is_a_rewrite() {
        near(wake_usd(300_000, 7200.0, 3600.0, &OPUS), 2.40);
    }

    #[test]
    fn a_wait_of_exactly_the_ttl_is_warm() {
        near(wake_usd(300_000, 300.0, 300.0, &OPUS), 0.06);
    }

    #[test]
    fn usage_prices_each_token_class() {
        let u = Usage {
            input: 1_000_000,
            output: 1_000_000,
            cache_read: 1_000_000,
            cache_write: 1_000_000,
        };
        near(usd(&u, &OPUS, 3600.0), 4.0 + 20.0 + 0.2 + 8.0);
        near(usd(&u, &OPUS, 300.0), 4.0 + 20.0 + 0.2 + 5.0);
        assert_eq!(u.total(), 4_000_000);
    }
}
