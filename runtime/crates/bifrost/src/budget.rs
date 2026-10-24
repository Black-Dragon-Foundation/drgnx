//! Cost and budget arithmetic (Task 18).

use crate::usage::Usage;

/// A provider's price per million tokens. (Task 17's `Provider.price` uses this type.)
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Price {
    pub input_per_m: f64,
    pub output_per_m: f64,
}

/// What a response cost: the provider's own figure, else the price, else 0.0.
pub fn cost(u: &Usage, price: Option<&Price>) -> f64 {
    if let Some(c) = u.cost {
        return c;
    }
    match price {
        Some(p) => {
            (u.input as f64 * p.input_per_m + u.output as f64 * p.output_per_m) / 1_000_000.0
        }
        None => 0.0,
    }
}

/// Whether `spent` has reached `budget` (reaching it counts).
pub fn over(spent: f64, budget: f64) -> bool {
    spent >= budget
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn equal_is_over() {
        assert!(over(1.0, 1.0));
        assert!(over(1.5, 1.0));
        assert!(!over(0.99, 1.0));
    }

    #[test]
    fn price_when_no_cost() {
        let p = Price {
            input_per_m: 3.0,
            output_per_m: 15.0,
        };
        let mut u = Usage {
            input: 1_000_000,
            output: 100_000,
            ..Usage::default()
        };
        assert!((cost(&u, Some(&p)) - 4.5).abs() < 1e-9);
        assert_eq!(cost(&u, None), 0.0);
        u.cost = Some(0.25);
        assert_eq!(cost(&u, Some(&p)), 0.25);
    }
}
