use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;

# TGT-146 (scheduled hourly bug hunt, JOB-003): cli/retry-download.pl's
# own success-path print interpolated $result_or_error - the raw local
# filesystem path D2TG::Download::retry_failed_download returns on
# success - directly into its "RETRY OK" stdout line, leaking a real
# path onto the target project's tira.policy.bridge (monitor-output,
# visible to anyone who can read that board). This is the exact class
# of leak TGT-133 closed everywhere else (D2TG::Poller's own
# _print_attachment_template, cli/attachment.pl); this one entrypoint
# was missed because it prints retry_failed_download's raw return value
# directly instead of going through the same never-expose-the-real-path
# indirection.
#
# A full functional test would need to mock both D2TG::Telegram's
# get_file HTTP call and the subsequent raw byte-fetch, for which this
# script has no injectable seam (unlike D2TG::Download::retry_failed_
# download itself, which t/83-failed-download-queue.t already covers
# via an injected `ua`) - so this is a structural/source-inspection
# regression test instead, matching this project's own precedent
# (t/88-poller-help-pod-parity.t) for exactly this situation.

my $script_path = File::Spec->catfile( $Bin, '..', 'cli', 'retry-download.pl' );
open my $fh, '<', $script_path or die "can't read $script_path: $!";
local $/;
my $source = <$fh>;
close $fh;

my ($success_line) = $source =~ /^\s*(print "RETRY OK.*?;\n)/ms;
ok( defined $success_line, 'found the RETRY OK success print statement in cli/retry-download.pl' );

unlike( $success_line, qr/\$result_or_error/,
    'the RETRY OK success line never interpolates the raw local path ($result_or_error) - TGT-146' );

like( $success_line, qr/GET ATTACHMENT WITH/,
    'the RETRY OK success line instead names the d2 tg.attachment fetch command' );

done_testing();
