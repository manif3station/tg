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

# TGT-276: the 5 call sites (edited/plain/voice/media/fallback
# branches) moved out of D2TG::Poller::run_once into
# D2TG::Poller::Dispatch's 3 handler functions, along with the branch
# bodies that contain them.
my $source_path = "$Bin/../lib/D2TG/Poller/Dispatch.pm";
open my $fh, '<', $source_path or die $!;
local $/;
my $source = <$fh>;
close $fh;

my $safe_source_path = "$Bin/../lib/D2TG/Poller/Safe.pm";
open my $safe_fh, '<', $safe_source_path or die $!;
local $/;
my $safe_source = <$safe_fh>;
close $safe_fh;

my $duplicate_pattern_count = () = $safe_source =~ /\$offset_cap = \$update_id if !\$recorded && !defined \$offset_cap;/g;

is( $duplicate_pattern_count, 0,
    'the duplicated 2-line offset_cap-bookkeeping pattern appears 0 times outside the new helper (TGT-181 AC)' );

# TGT-275: relocated into D2TG::Poller::Safe (its own name losing the
# leading underscore, becoming a public helper alongside the other 7
# relocated non-run_once functions) to bring D2TG::Poller.pm under the
# board's 500-line-per-module cap. run_once itself (still in Poller.pm)
# now calls it via its fully-qualified name.
my $helper_defined = $safe_source =~ /sub record_message_and_track_offset/;
ok( $helper_defined, 'the record_message_and_track_offset helper exists in D2TG::Poller::Safe' );

my $call_site_count = () = $source =~ /D2TG::Poller::Safe::record_message_and_track_offset\(/g;

# TGT-313: the plain-text and transcribed-voice branches' own call
# sites were consolidated into the shared _announce_and_record helper's
# single call site, dropping this from 5 to 4 (edited, the shared
# helper, downloaded media, fallback media) - the sub definition itself
# is still not matched by this pattern (no trailing open-paren
# immediately after in the same form).
is( $call_site_count, 4, 'the new helper is called from exactly 4 places in source (plain text and transcribed voice now share one call site via _announce_and_record, TGT-313)' );

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
# TGT-232 (found via a scheduled JOB-004 improvement hunt): each call
# site now also passes bot_key => $bot_token (threading the poller's
# own active bot token through to D2TG::Store's newly bot_key-scoped
# messages table) - these regexes were widened to allow that trailing
# argument without weakening what they actually check (the call site,
# its arguments up to $safe_text/$safe_transcript/local_path, and its
# surrounding branch-identifying context are all still asserted
# exactly as before).
# TGT-276: $offset_cap_ref is now passed into these handler functions
# already as a reference (the caller in run_once takes \$offset_cap
# once, at the dispatch call site) - the handler itself just threads
# $offset_cap_ref straight through, no further backslash-ref needed.
#
# TGT-311 (explicit user-requested architecture change): the plain-text
# and transcribed-voice announce lines no longer interpolate
# $safe_text/$safe_transcript inline (only a FETCH WITH command does,
# via print_fetch_template) - the anchor text below was updated to the
# new print line's own distinguishing shape, still uniquely identifying
# each branch.
#
# TGT-313 (found via a JOB-004 improvement hunt): the plain-text and
# transcribed-voice branches' own record_message_and_track_offset call
# sites moved out of handle_plain_update entirely, into a single shared
# _announce_and_record helper both branches now call (the exact
# duplication this ticket set out to remove - see Dispatch.pm's own
# comment above the helper). So the source now contains that one call
# site once (inside the helper), not twice (once inline per branch) -
# call_site_count drops from 5 to 4, and the 'plain text branch'/
# 'transcribed voice branch' anchors below are replaced with a single
# anchor for the helper's own call, plus two anchors confirming each
# branch calls the helper with the right label/content mapping.
my %expected_near = (
    'edited text branch (has_text)' => qr/\$has_text \)\s*\{\s*\n\s*D2TG::Poller::Safe::record_message_and_track_offset\(\s*\$store,\s*\$offset_cap_ref,\s*\$update_id,\s*\$chat_id,\s*\$message_id,\s*\$sender,\s*\$safe_text,\s*bot_key\s*=>\s*\$bot_token\s*\)/,
    'shared _announce_and_record helper (plain text and transcribed voice branches)' => qr/sub _announce_and_record.*?D2TG::Poller::Safe::record_message_and_track_offset\(\s*\$store,\s*\$offset_cap_ref,\s*\$update_id,\s*\$chat_id,\s*\$message_id,\s*\$sender,\s*\$safe_content,\s*bot_key\s*=>\s*\$bot_token\s*\)/s,
    'downloaded media branch (local_path)' => qr/D2TG::Poller::Safe::record_message_and_track_offset\(\s*\$store,\s*\$offset_cap_ref,\s*\$update_id,\s*\$chat_id,\s*\$message_id,\s*\$sender,\s*"\$media_kind\$caption_note",\s*local_path\s*=>\s*\$local_path,\s*bot_key\s*=>\s*\$bot_token\s*\)/,
    'fallback media branch'         => qr/D2TG::Poller::Safe::record_message_and_track_offset\(\s*\$store,\s*\$offset_cap_ref,\s*\$update_id,\s*\$chat_id,\s*\$message_id,\s*\$sender,\s*"\$media_kind\$caption_note",\s*bot_key\s*=>\s*\$bot_token\s*\)\s*;\s*\n\s*\}\s*\n\s*\}/,
);

for my $label ( sort keys %expected_near ) {
    like( $source, $expected_near{$label}, "the helper is called with the right arguments, adjacent to the expected branch-identifying context, for the $label (source-text check, not a parser - see comment above)" );
}

# TGT-313: confirm each branch actually calls _announce_and_record with
# the right label and content variable - a call-site count/regex check
# alone (above) could still pass if, say, both branches passed the same
# label or the wrong content variable, since the helper's own body is
# only checked once. Anchor each branch's own call to the helper by its
# distinguishing surrounding text, same discipline as the direct call
# sites above.
my %expected_helper_call_near = (
    'plain text branch calls the helper with label NEW TG, content $safe_text' =>
      qr/if \( defined \$text && length \$text \) \{.*?_announce_and_record\(\s*ts\s*=>\s*\$ts,\s*chat_id\s*=>\s*\$chat_id,\s*sender\s*=>\s*\$sender,\s*msg_note\s*=>\s*\$msg_note,\s*reply_ctx\s*=>\s*\$reply_ctx,\s*message_id\s*=>\s*\$message_id,\s*label\s*=>\s*'NEW TG',\s*safe_content\s*=>\s*\$safe_text,/s,
    'transcribed voice branch calls the helper with label NEW TG VOICE, content $safe_transcript' =>
      qr/transcribing\.\.\..*?_announce_and_record\(\s*ts\s*=>\s*\$ts,\s*chat_id\s*=>\s*\$chat_id,\s*sender\s*=>\s*\$sender,\s*msg_note\s*=>\s*\$msg_note,\s*reply_ctx\s*=>\s*\$reply_ctx,\s*message_id\s*=>\s*\$message_id,\s*label\s*=>\s*'NEW TG VOICE',\s*safe_content\s*=>\s*\$safe_transcript,/s,
);

for my $label ( sort keys %expected_helper_call_near ) {
    like( $source, $expected_helper_call_near{$label}, "$label (source-text check, not a parser)" );
}

done_testing();
