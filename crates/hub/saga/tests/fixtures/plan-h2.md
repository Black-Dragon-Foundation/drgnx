# Orchard sync: Implementation Plan

> **For agentic workers:** work task by task; steps use checkbox syntax.

**Goal:** apples are counted once, baskets are weighed twice, nothing is lost.

## Global Constraints

- Rule one: no network in tests.
- Rule two:

  ```text
  ## Task 99: this is inside a fence and is not a task
  # neither is this
  ```

## Waves (parallel worktrees, merge order)

| Wave | Tasks | Notes |
|---|---|---|
| A | 0, 1, 2 | foundations |
| B | 3, 3b | `weigh` and `count` |

# Wave A — foundations

## Task 0 (manager): base and skeletons

**Model:** none (manager)

**Files:** Create `crates/orchard/src/lib.rs`.

- [x] **Step 1: Cut the branch** from `base`.
- [x] **Step 2: Commit** `orchard: skeleton`.

## Task 1: `basket` — the weighing record

**Model:** sonnet.

**Files:** Create `crates/orchard/src/{basket,scale}.rs`, `tests/basket.rs`;
docs `docs/basket.md`.

**Interfaces:**
- Produces: `basket::weigh(items: &[Apple]) -> Grams`;
  `basket::split(b: Basket, n: usize) -> Vec<Basket>`.
- Consumes: `apple::Apple` from Task 0.

- [ ] **Step 1: Tests:** `weigh_sums_items`, `split_keeps_total`.
- [ ] **Step 2: Implement; Step 3: commit** `orchard: baskets weighed`.

### A sub-heading inside task 1

Notes that stay in the task body.

## Task 2: `press` — juice

**Model:** opus (a risky parser) · **Slot:** heavy

**Files:** Create `crates/orchard/src/press.rs`.

- [ ] **Step 1: Tests**
  with a continuation line.
- [x] **Step 2: Implement**

# Wave B — the harvest

## Task 3: `harvest`

**Model:** sonnet

- [ ] **Step 1:** do it.

## Task 3b: `harvest` — late fruit

**Model:** sonnet

- [ ] **Step 1:** do it later.

## Exit criteria

1. Everything weighs twice.
2. Nothing is lost.
