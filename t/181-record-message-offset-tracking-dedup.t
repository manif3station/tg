use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);

# TGT-181 (found via a scheduled improvement hunt): the 2-line
# _record_message_safe + offset_cap bookkeeping pattern TGT-178
# introduced appears 5 times verbatim in run_once - matching this
# project's own established "found it twice, extract it" convention
# (TGT-167/170/171/172/177). Extracted into a single helper,
# _record_message_and_track_offset, called from all 5 sites.

my $source_path = "$Bin/../lib/D2TG/Poller.pm";
open my $fh, '<', $source_path or die $!;
local $/;
my $source = <$fh>;
close $fh;

my $duplicate_pattern_count = () = $source =~ /\$offset_cap = \$update_id if !\$recorded && !defined \$offset_cap;/g;

is( $duplicate_pattern_count, 0,
    'the duplicated 2-line offset_cap-bookkeeping pattern appears 0 times outside the new helper (TGT-181 AC)' );

my $helper_defined = $source =~ /sub _record_message_and_track_offset/;
ok( $helper_defined, 'the new _record_message_and_track_offset helper exists' );

my $call_site_count = () = $source =~ /_record_message_and_track_offset\(/g;

# 5 call sites + the sub definition itself is not matched by this
# pattern (it has no trailing open-paren immediately after in the same
# form) - so this should be exactly 5.
is( $call_site_count, 5, 'the new helper is called from exactly 5 places - one per original call site' );

# Codex QA-stage review finding: a bare count/regex check alone can
# pass even if a call moved out of its intended branch, was dropped
# from one branch and duplicated in another, or had its arguments
# reordered/dropped - none of which a global count would catch. Anchor
# each of the 5 expected call sites to a nearby, distinguishing string
# literal already unique to that branch, so a call with the wrong
# ARGUMENTS, or missing from its expected neighborhood entirely, is
# caught. This is still a source-text regex, not a parser - a second
# Codex review round correctly noted it cannot prove AST-level branch
# membership (e.g. a comment or string literal containing the same
# text would also match), only that the right-shaped call sits near
# the right neighboring text. That is a real, accepted limitation, not
# a full substitute for either a parser-based check or genuine
# per-branch behavioral tests (which t/178/t/100 only provide for the
# plain-text branch today, not voice/media/edited/fallback - a
# pre-existing gap from TGT-178, out of this pure-refactor ticket's
# own scope to close).
my %expected_near = (
    'edited text branch (has_text)' => qr/\$has_text \)\s*\{\s*\n\s*_record_message_and_track_offset\(\s*\$store,\s*\\\$offset_cap,\s*\$update_id,\s*\$chat_id,\s*\$message_id,\s*\$sender,\s*\$safe_text\s*\)/,
    'plain text branch'             => qr/NEW TG \[\$chat_id\] \$sender: \$safe_text.*?_record_message_and_track_offset\(\s*\$store,\s*\\\$offset_cap,\s*\$update_id,\s*\$chat_id,\s*\$message_id,\s*\$sender,\s*\$safe_text\s*\)/s,
    'transcribed voice branch'      => qr/NEW TG VOICE \[\$chat_id\] \$sender: \$safe_transcript.*?_record_message_and_track_offset\(\s*\$store,\s*\\\$offset_cap,\s*\$update_id,\s*\$chat_id,\s*\$message_id,\s*\$sender,\s*\$safe_transcript\s*\)/s,
    'downloaded media branch (local_path)' => qr/_record_message_and_track_offset\(\s*\$store,\s*\\\$offset_cap,\s*\$update_id,\s*\$chat_id,\s*\$message_id,\s*\$sender,\s*"\$media_kind\$caption_note",\s*local_path\s*=>\s*\$local_path\s*\)/,
    'fallback media branch'         => qr/_record_message_and_track_offset\(\s*\$store,\s*\\\$offset_cap,\s*\$update_id,\s*\$chat_id,\s*\$message_id,\s*\$sender,\s*"\$media_kind\$caption_note"\s*\)\s*;\s*\n\s*\}\s*\n\s*\}\s*\n\s*\}/,
);

for my $label ( sort keys %expected_near ) {
    like( $source, $expected_near{$label}, "the helper is called with the right arguments, adjacent to the expected branch-identifying context, for the $label (source-text check, not a parser - see comment above)" );
}

done_testing();
