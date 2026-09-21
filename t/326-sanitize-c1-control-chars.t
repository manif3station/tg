use strict;
use warnings;
use Test::More;

use D2TG::Poller::Format;

# TGT-326 (found via a live JOB-003 hourly bug hunt): sanitize_for_stdout
# stripped the 7-bit control ranges (0x00-0x08, 0x0B-0x1F including ESC
# 0x1B, and DEL 0x7F) but not the C1 control range (0x80-0x9F) - live-
# reproduced: 0x9B (the 8-bit CSI, the same terminal-escape-sequence
# introducer as ESC+'[' in 7-bit form) passed through unstripped.

is(
    D2TG::Poller::Format::sanitize_for_stdout("a\x{9b}b"),
    'ab',
    '0x9B (8-bit CSI) is stripped, matching how 0x1B (7-bit ESC) already is'
);

is(
    D2TG::Poller::Format::sanitize_for_stdout(
        "hello\x{9b}31mRED\x{9b}0m world"
    ),
    'hello31mRED0m world',
    'stripping the CSI introducer neutralizes the escape sequence - the parameter/final bytes remain as inert plain text, not an active escape'
);

# the entire C1 range (0x80-0x9F) should be stripped, not just 0x9B
my $full_c1 = join( '', map { chr($_) } 0x80 .. 0x9F );
is(
    D2TG::Poller::Format::sanitize_for_stdout( "x${full_c1}y" ),
    'xy',
    'the entire C1 control range (0x80-0x9F) is stripped'
);

# existing 7-bit behavior must be unchanged by this fix
is(
    D2TG::Poller::Format::sanitize_for_stdout("a\x1bb"),
    'ab',
    '7-bit ESC (0x1B) is still stripped (pre-existing behavior unchanged)'
);

is(
    D2TG::Poller::Format::sanitize_for_stdout("line1\nline2"),
    'line1\nline2',
    'newline collapsing to a literal \n is still unchanged'
);

done_testing();
