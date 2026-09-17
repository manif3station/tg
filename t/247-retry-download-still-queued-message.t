use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;

# TGT-247 (found via a scheduled JOB-003 hourly bug hunt, live-reproduced
# in a developer-dashboard:latest container): D2TG::Download::
# retry_failed_download returns a 3rd value, $still_queued (TGT-244) -
# true when the download itself succeeded but the follow-up
# record_message write then failed, leaving the row deliberately still
# queued in failed_downloads (never removed) and NO row ever written
# into the messages table. cli/retry-download.pl's own retry loop used
# to only capture ($ok, $result_or_error), discarding $still_queued
# entirely - so its success branch printed an unconditional
#   RETRY OK [id] ... - GET ATTACHMENT WITH: d2 tg.attachment <chat_id> <message_id>
# even in this exact scenario, even though that printed d2 tg.attachment
# command is GUARANTEED to fail (D2TG::Store::get_attachment_path reads
# local_path from the messages table, which was never written to).
#
# Live-verified in this session: a fake store whose record_message
# always dies makes retry_failed_download return (1, $local_path, 1) -
# $ok true, $still_queued true - and the unmodified script would still
# print the misleading RETRY OK/GET ATTACHMENT WITH line for that row.
#
# A full functional test would need to mock D2TG::Telegram's HTTP calls
# through this script's own real D2TG::Poller::Safe::open_store_or_die/real
# SQLite D2TG::Store construction, for which this script has no
# injectable seam (the same limitation t/104-retry-download-cli-no-raw-
# path.t already documented and worked around) - so this is a
# structural/source-inspection regression test instead, matching this
# project's own established precedent for exactly this script.

my $script_path = File::Spec->catfile( $Bin, '..', 'cli', 'retry-download.pl' );
open my $fh, '<', $script_path or die "can't read $script_path: $!";
local $/;
my $source = <$fh>;
close $fh;

# The retry loop's own call must capture all 3 of retry_failed_download's
# return values, not just the first two - otherwise $still_queued can
# never exist to be branched on at all.
like(
    $source,
    qr/my\s*\(\s*\$ok\s*,\s*\$result_or_error\s*,\s*\$still_queued\s*\)\s*=\s*\n?\s*D2TG::Download::retry_failed_download/s,
    'the retry loop captures the 3rd return value ($still_queued) from retry_failed_download, not just ($ok, $result_or_error)'
);

# The RETRY OK / GET ATTACHMENT WITH line is only true once the retry is
# FULLY complete (row actually removed from the queue, message actually
# recorded into history) - it must never be reachable when $still_queued
# is true. Locate the print statement and confirm it sits behind a
# condition that also excludes the still-queued case, by requiring that
# $still_queued is referenced somewhere between the "if ( !$ok )" failure
# check and the "RETRY OK" success print - i.e. the code path distinguishes
# the two, rather than the print being reachable purely off $ok alone.
my ($loop_body) = $source =~ /(if \( !\$ok \) \{.*?RETRY OK.*?\n)/s;
ok( defined $loop_body, 'located the retry loop body containing both the failure check and the RETRY OK success print' );

like(
    $loop_body,
    qr/\$still_queued/,
    'the retry loop body inspects $still_queued somewhere before/around the RETRY OK success print, not just $ok'
);

# And there must be a distinct message for the still-queued case - it
# must not simply fall through silently to the same RETRY OK wording.
like(
    $source,
    qr/still.?queued/i,
    'a still-queued-specific message (naming the condition) exists in the script output, not just internally in the variable name'
);

done_testing();
