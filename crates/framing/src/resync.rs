//! Cut an encoded stream at every offset, hand the tail to a decoder that has
//! just arrived, and count what it makes of it.
//!
//! This is the whole comparison. It is here rather than in the firmware
//! because a board can be joined halfway a few dozen times in an evening and
//! this does it at every byte of every stream, which is the only way to see
//! the difference between "usually recovers" and "recovers by construction".

use alloc::vec::Vec;

use crate::{cobs, length_prefix, Deframer, Start, MAX_PAYLOAD};

/// What one decoder did with one cut.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct Cut {
    /// Messages delivered that were not sent — a decode that found a boundary
    /// where there was none.
    pub false_frames: usize,
    /// Messages that were sent whole after the cut and never came out.
    pub lost: usize,
    /// Stream bytes consumed before the first correctly delivered message.
    /// `None` if none ever arrived.
    pub bytes_to_recover: Option<usize>,
}

/// Totals over every cut of one stream.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct Report {
    pub cuts: usize,
    /// Cuts where everything after the cut arrived, and nothing else did.
    pub clean: usize,
    pub false_frames: usize,
    pub lost: usize,
    /// Worst case over all cuts, in bytes, of the wait before the first
    /// correct message. `None` if some cut never recovered at all.
    pub worst_bytes_to_recover: Option<usize>,
}

/// A payload corpus and the stream it encodes to.
pub struct Stream {
    pub payloads: Vec<Vec<u8>>,
    pub wire: Vec<u8>,
    /// Offset in `wire` where each payload's frame begins.
    pub starts: Vec<usize>,
}

/// Build a stream with one encoder.
pub fn build(
    payloads: &[Vec<u8>],
    encode: fn(&[u8], &mut [u8]) -> Result<usize, crate::Error>,
) -> Stream {
    let mut wire = Vec::new();
    let mut starts = Vec::new();
    let mut out = [0u8; 4 * MAX_PAYLOAD];
    for p in payloads {
        starts.push(wire.len());
        let n = encode(p, &mut out).unwrap();
        wire.extend_from_slice(&out[..n]);
    }
    Stream {
        payloads: payloads.to_vec(),
        wire,
        starts,
    }
}

/// Feed `stream.wire[cut..]` to a decoder that has just joined, and classify.
pub fn cut_at<D: Start>(stream: &Stream, cut: usize) -> Cut {
    // What a correct decoder owes us: every message whose frame begins at or
    // after the cut. A message the cut lands inside is not owed — half of it
    // is gone and no decoder can invent it.
    let expected: Vec<&Vec<u8>> = stream
        .starts
        .iter()
        .zip(&stream.payloads)
        .filter(|(start, _)| **start >= cut)
        .map(|(_, p)| p)
        .collect();

    let mut d = D::joined();
    let mut next = 0usize;
    let mut result = Cut::default();

    for (i, &b) in stream.wire[cut..].iter().enumerate() {
        if d.feed(b).is_some() {
            let got = d.payload();
            // Align by matching rather than by position. A decoder that misses
            // one message and then delivers every later one perfectly has made
            // one mistake, not one per message — and scoring it the other way
            // was this measurement's own first bug.
            match expected[next..]
                .iter()
                .position(|e| e.as_slice() == got)
            {
                Some(pos) => {
                    if result.bytes_to_recover.is_none() {
                        result.bytes_to_recover = Some(i + 1);
                    }
                    // Anything skipped over was owed and never came. Counting
                    // it here rather than at the end is the difference between
                    // "one message was dropped" and "nothing went wrong",
                    // which is a difference this comparison is entirely about.
                    result.lost += pos;
                    next += pos + 1;
                }
                None => result.false_frames += 1,
            }
        }
    }
    result.lost += expected.len() - next;
    result
}

/// Sweep every cut of a stream.
pub fn sweep<D: Start>(stream: &Stream) -> Report {
    let mut r = Report {
        cuts: stream.wire.len(),
        ..Report::default()
    };
    let mut worst = Some(0usize);
    for cut in 0..stream.wire.len() {
        let c = cut_at::<D>(stream, cut);
        r.false_frames += c.false_frames;
        r.lost += c.lost;
        if c.false_frames == 0 && c.lost == 0 {
            r.clean += 1;
        }
        // The wait is only a question where a whole message begins strictly
        // after the cut. A cut that lands on the last message's first byte has
        // nothing left to recover *to*, so it is not evidence about waiting.
        if stream.starts.iter().any(|s| *s > cut) {
            match (worst, c.bytes_to_recover) {
                (Some(w), Some(b)) => worst = Some(w.max(b)),
                (_, None) => worst = None,
                (None, _) => {}
            }
        }
    }
    r.worst_bytes_to_recover = worst;
    r
}

/// A deterministic corpus that contains the things that hurt: the magic byte,
/// the delimiter, lengths that look like headers, and runs of both.
///
/// Deterministic because a fixture that changes between runs cannot be a
/// number in a README. The generator is a plain LCG so anyone can regenerate
/// it in any language.
pub fn corpus() -> Vec<Vec<u8>> {
    let mut out: Vec<Vec<u8>> = Vec::new();

    // Hand-picked cases first, because these are the ones a reader should be
    // able to find in the stream by eye.
    out.push(b"hello".to_vec());
    out.push(alloc::vec![length_prefix::MAGIC; 4]);
    out.push(alloc::vec![cobs::DELIMITER; 4]);
    // A payload that spells a plausible frame header: magic, then a length of
    // five, then five bytes. Inside a longer message this is a trap for a
    // decoder hunting for the magic byte.
    out.push(alloc::vec![
        length_prefix::MAGIC,
        5,
        0,
        b'a',
        b'b',
        b'c',
        b'd',
        b'e'
    ]);

    // Then pseudo-random payloads over the whole byte range, which is where
    // both hazards occur without being planted.
    let mut state: u32 = 0x1985_1226;
    let mut next = || {
        state = state.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
        (state >> 24) as u8
    };
    for i in 0..24 {
        let len = 1 + (i * 7) % 40;
        out.push((0..len).map(|_| next()).collect());
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn report_both() -> (Report, Report) {
        let payloads = corpus();
        let lp = build(&payloads, length_prefix::encode);
        let cb = build(&payloads, cobs::encode);
        (
            sweep::<length_prefix::Deframer>(&lp),
            sweep::<cobs::Deframer>(&cb),
        )
    }

    /// The table the README quotes. Run with `--nocapture` to see it.
    #[test]
    fn print_the_table() {
        let (lp, cb) = report_both();
        std::println!(
            "               cuts  clean  invented  lost  worst wait"
        );
        for (name, r) in [("length-prefix", lp), ("cobs         ", cb)] {
            std::println!(
                "{name}  {:4}  {:5}  {:8}  {:4}  {:?}",
                r.cuts,
                r.clean,
                r.false_frames,
                r.lost,
                r.worst_bytes_to_recover
            );
        }
    }

    /// The finding, and it is not the one the comparison was set up to expect.
    ///
    /// Length-prefix loses **fewer** messages than COBS. What it does instead
    /// is worse: it delivers messages nobody sent.
    #[test]
    fn length_prefix_invents_messages_and_cobs_does_not() {
        let (lp, cb) = report_both();
        assert_eq!(cb.false_frames, 0, "COBS invented a message");
        assert!(
            lp.false_frames > 0,
            "length-prefix invented nothing on this corpus — the trap payload is gone"
        );
        assert!(
            lp.lost < cb.lost,
            "the trade being measured has changed shape"
        );
    }

    /// Where the invented messages come from, named exactly.
    ///
    /// The corpus contains one payload that spells a plausible header:
    /// `A5 05 00` then five bytes. A decoder that joined the stream inside it
    /// reads that as *magic, length five*, and hands its caller `abcde` — a
    /// message that was never sent, assembled entirely out of the middle of
    /// one that was.
    #[test]
    fn the_invented_message_is_the_payload_that_spells_a_header() {
        let payloads = corpus();
        let lp = build(&payloads, length_prefix::encode);
        let mut invented = Vec::new();
        for cut in 0..lp.wire.len() {
            let mut d = <length_prefix::Deframer as Start>::joined();
            for &b in &lp.wire[cut..] {
                if d.feed(b).is_some() {
                    let got = d.payload().to_vec();
                    if !payloads.contains(&got) {
                        invented.push((cut, got));
                        break;
                    }
                }
            }
        }
        assert_eq!(invented.len(), 3, "invented: {invented:?}");
        for (_, payload) in &invented {
            assert_eq!(payload.as_slice(), b"abcde");
        }
    }

    /// COBS pays for that with a loss it cannot avoid: **exactly one message
    /// per cut that lands on a message boundary**, because a decoder arriving
    /// at a boundary cannot tell it from arriving in the middle. It throws the
    /// first block away rather than risk emitting half of somebody else's.
    ///
    /// That is a decision, not a law — see `Start::joined`. An optimistic COBS
    /// decoder would deliver those 28 and would be the one inventing messages.
    #[test]
    fn cobs_loses_exactly_one_message_per_boundary() {
        let (_, cb) = report_both();
        assert_eq!(cb.lost, corpus().len());
    }

    /// Both recover inside one message, which is the one thing they agree on.
    /// A stream of 40-byte messages is resynchronised within about two of them
    /// whichever scheme carried it.
    #[test]
    fn both_recover_within_a_message_or_two() {
        let (lp, cb) = report_both();
        for r in [lp, cb] {
            let worst = r.worst_bytes_to_recover.expect("a cut never recovered");
            assert!(worst < 3 * MAX_PAYLOAD, "worst wait {worst} bytes");
        }
    }

    #[test]
    fn a_stream_read_from_the_start_is_exact_for_both() {
        // The control. Whatever the sweep says about joining halfway, both
        // schemes have to be exactly right when read from byte zero, or the
        // comparison is measuring a bug.
        let payloads = corpus();
        for (wire, got) in [
            (
                build(&payloads, length_prefix::encode),
                length_prefix::decode_all as fn(&[u8]) -> Vec<Vec<u8>>,
            ),
            (
                build(&payloads, cobs::encode),
                cobs::decode_all as fn(&[u8]) -> Vec<Vec<u8>>,
            ),
        ] {
            assert_eq!(got(&wire.wire), payloads);
        }
    }
}

#[cfg(test)]
mod wire_fixtures {
    use crate::*;
    #[test]
    fn print_the_frames_check_sh_sends() {
        let payload = [length_prefix::MAGIC, 5, 0, b'a', b'b', b'c', b'd', b'e'];
        let mut out = [0u8; 64];
        let n = length_prefix::encode(&payload, &mut out).unwrap();
        std::println!("lp   whole: {:02x?}", &out[..n]);
        std::println!("lp   tail3: {:02x?}", &out[3..n]);
        let n = cobs::encode(&payload, &mut out).unwrap();
        std::println!("cobs whole: {:02x?}", &out[..n]);
        std::println!("cobs tail3: {:02x?}", &out[3..n]);
        let n = cobs::encode(b"hello", &mut out).unwrap();
        std::println!("cobs hello: {:02x?}", &out[..n]);
        let n = length_prefix::encode(b"hello", &mut out).unwrap();
        std::println!("lp   hello: {:02x?}", &out[..n]);
    }
}
