//! The conflict count of a 3-way merge.  Pattern D (pure: no process but `git merge-file`, no clock).

use verdandi::threeway::conflicts;

const BASE: &str = "a\nb\nc\nd\ne\nf\ng\nh\n";

#[test]
fn conflicts_counts_each_hunk_both_sides_changed() {
    let ours = BASE.replace("b\n", "B ours\n").replace("g\n", "G ours\n");
    let theirs = BASE
        .replace("b\n", "B theirs\n")
        .replace("g\n", "G theirs\n");
    assert_eq!(conflicts(BASE, &ours, &theirs).unwrap(), 2);
    let one = BASE.replace("g\n", "G theirs\n");
    assert_eq!(conflicts(BASE, &ours, &one).unwrap(), 1);
}

#[test]
fn a_clean_merge_has_no_conflict() {
    let ours = BASE.replace("b\n", "B\n");
    let theirs = BASE.replace("g\n", "G\n");
    assert_eq!(conflicts(BASE, &ours, &theirs).unwrap(), 0);
    // the same change on both sides is no conflict either
    assert_eq!(conflicts(BASE, &ours, &ours).unwrap(), 0);
    assert!(verdandi::merge3(BASE, &ours, &theirs).unwrap().0);
}
