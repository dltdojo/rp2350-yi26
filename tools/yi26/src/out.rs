//! Output plumbing: a very small JSON writer, and the `--explain` channel.
//!
//! There is no `serde` here on purpose. This tool emits a handful of fixed
//! shapes, and two dependencies that a learner has to compile before they can
//! debug anything is already two. Escaping is the only part of JSON that is
//! easy to get wrong, so that is the part that gets a tested function.

use std::io::Write;

/// Flags that every command respects.
#[derive(Clone, Copy, Default)]
pub struct Opts {
    /// Machine-readable output on stdout. For scripts and AI agents.
    pub json: bool,
    /// Print the equivalent hand-typed commands on stderr, then act anyway.
    pub explain: bool,
}

/// What a command would look like done by hand.
///
/// `shell` is empty when there is no reasonable shell equivalent — in that
/// case `notes` has to say *why*, because "use the tool" is not an
/// explanation. That rule is why this type has two fields instead of one.
pub struct Explanation {
    pub shell: &'static [&'static str],
    pub notes: &'static [&'static str],
}

pub fn explain(opts: &Opts, e: &Explanation) {
    if !opts.explain {
        return;
    }
    let err = &mut std::io::stderr();
    if e.shell.is_empty() {
        let _ = writeln!(err, "# by hand: not reasonably possible — see below");
    } else {
        let _ = writeln!(err, "# by hand:");
        for line in e.shell {
            let _ = writeln!(err, "$ {line}");
        }
    }
    for note in e.notes {
        let _ = writeln!(err, "# {note}");
    }
    let _ = writeln!(err);
}

/// Escapes a string into a quoted JSON string.
pub fn esc(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            // Everything below 0x20 must be escaped; \u form covers the rest.
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

pub fn kv_str(k: &str, v: &str) -> String {
    format!("{}:{}", esc(k), esc(v))
}

pub fn kv_opt(k: &str, v: Option<&str>) -> String {
    match v {
        Some(v) => kv_str(k, v),
        None => format!("{}:null", esc(k)),
    }
}

pub fn kv_num(k: &str, v: u64) -> String {
    format!("{}:{}", esc(k), v)
}

pub fn kv_bool(k: &str, v: bool) -> String {
    format!("{}:{}", esc(k), v)
}

pub fn kv_raw(k: &str, v: &str) -> String {
    format!("{}:{}", esc(k), v)
}

pub fn obj(fields: &[String]) -> String {
    format!("{{{}}}", fields.join(","))
}

pub fn arr(items: &[String]) -> String {
    format!("[{}]", items.join(","))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn escapes_the_things_that_break_parsers() {
        assert_eq!(esc(r#"a"b"#), r#""a\"b""#);
        assert_eq!(esc(r"a\b"), r#""a\\b""#);
        assert_eq!(esc("a\nb"), r#""a\nb""#);
        assert_eq!(esc("a\u{1}b"), "\"a\\u0001b\"");
        // A device path with a space in it — real mount points have these.
        assert_eq!(esc("/media/me/RP 2350"), r#""/media/me/RP 2350""#);
    }

    #[test]
    fn objects_and_arrays_compose() {
        let o = obj(&[kv_str("a", "1"), kv_num("b", 2), kv_bool("c", true), kv_opt("d", None)]);
        assert_eq!(o, r#"{"a":"1","b":2,"c":true,"d":null}"#);
        assert_eq!(arr(&[o.clone(), o]), format!("[{},{}]", r#"{"a":"1","b":2,"c":true,"d":null}"#, r#"{"a":"1","b":2,"c":true,"d":null}"#));
    }
}
