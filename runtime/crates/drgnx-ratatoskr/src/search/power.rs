//! Whether the machine runs on battery (the battery gate, proposed O-2: tier 2 waits for AC, a query uses the CPU
//! path, and the device is never measured on battery).
//!
//! Linux and Android read `<root>/class/power_supply/*/{type,online}` (`root` is `/sys`): on battery means a mains
//! supply exists and none is online. A machine with no mains supply (a desktop, a container) counts as on AC. macOS
//! reads `pmset -g ps`.

use std::path::Path;

/// The sysfs root the hub reads.
pub const SYS: &str = "/sys";

/// On battery, by this platform's rule. ROOT is the sysfs root (ignored on macOS).
pub fn on_battery(root: &Path) -> bool {
    #[cfg(target_os = "macos")]
    {
        let _ = root;
        std::process::Command::new("pmset")
            .args(["-g", "ps"])
            .output()
            .is_ok_and(|o| pmset_on_battery(&String::from_utf8_lossy(&o.stdout)))
    }
    #[cfg(not(target_os = "macos"))]
    {
        sysfs_on_battery(root)
    }
}

/// The sysfs rule: a `Mains` supply exists and none of them is online.
pub fn sysfs_on_battery(root: &Path) -> bool {
    let Ok(entries) = std::fs::read_dir(root.join("class/power_supply")) else {
        return false;
    };
    let read = |p: &Path| std::fs::read_to_string(p).unwrap_or_default();
    let (mut mains, mut online) = (false, false);
    for e in entries.flatten() {
        let dir = e.path();
        if read(&dir.join("type")).trim() == "Mains" {
            mains = true;
            online |= read(&dir.join("online")).trim() == "1";
        }
    }
    mains && !online
}

/// `pmset -g ps`'s first line names the source: `Now drawing from 'Battery Power'` or `'AC Power'`.
pub fn pmset_on_battery(text: &str) -> bool {
    text.lines()
        .next()
        .is_some_and(|l| l.contains("'Battery Power'"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn supply(root: &Path, name: &str, ty: &str, online: Option<&str>) {
        let d = root.join("class/power_supply").join(name);
        std::fs::create_dir_all(&d).unwrap();
        std::fs::write(d.join("type"), format!("{ty}\n")).unwrap();
        if let Some(o) = online {
            std::fs::write(d.join("online"), format!("{o}\n")).unwrap();
        }
    }

    /// Pattern D.
    #[test]
    fn reads_mains_online() {
        let root = tempfile::tempdir().unwrap();
        supply(root.path(), "BAT0", "Battery", None);
        supply(root.path(), "AC", "Mains", Some("0"));
        assert!(sysfs_on_battery(root.path()));
        supply(root.path(), "AC", "Mains", Some("1"));
        assert!(!sysfs_on_battery(root.path()));
        // two mains supplies: one online is enough
        supply(root.path(), "AC", "Mains", Some("0"));
        supply(root.path(), "ADP1", "Mains", Some("1"));
        assert!(!sysfs_on_battery(root.path()));
    }

    /// Pattern D.
    #[test]
    fn no_mains_supply_counts_as_ac() {
        let root = tempfile::tempdir().unwrap();
        assert!(!sysfs_on_battery(root.path()), "no power_supply at all");
        supply(root.path(), "BAT0", "Battery", None);
        supply(root.path(), "hidpp_battery_0", "Battery", None);
        assert!(!sysfs_on_battery(root.path()), "batteries but no mains");
        assert!(!sysfs_on_battery(Path::new("/nonexistent")));
    }

    /// Pattern D.
    #[test]
    fn pmset_output_parsed() {
        let battery = "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=4653155)\t84%; discharging; 5:12 remaining present: true\n";
        let ac = "Now drawing from 'AC Power'\n -InternalBattery-0 (id=4653155)\t100%; charged; 0:00 remaining present: true\n";
        assert!(pmset_on_battery(battery));
        assert!(!pmset_on_battery(ac));
        assert!(!pmset_on_battery(""));
        assert!(!pmset_on_battery("Now drawing from 'UPS Power'\n"));
    }
}
