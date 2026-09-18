use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;

# TGT-304 (Michael's own answer to Q-018, after a deepened investigation
# into a live incident report of a stale MEDIA DOWNLOAD ERROR line
# appearing alongside a poller version-change restart): the root cause
# is outside this repo (most likely Tira's own monitor-job feeder
# re-surfacing captured output at restart time - every code path in
# this repo that can print that exact text was traced and ruled out).
# Per Michael's decision, this ticket ships a diagnostic instead of a
# fix: the restart-announcement line now includes this process's own
# PID and a precise timestamp, so any future occurrence can be checked
# directly against process listings/timing to confirm (or finally
# disprove) that conclusion.

my $script_path = File::Spec->catfile( $Bin, '..', 'cli', 'poller.pl' );
open my $fh, '<', $script_path or die "can't read $script_path: $!";
local $/;
my $source = <$fh>;
close $fh;

my ($restart_line) = $source =~ /(print "d2tg poller detected version change.*?\\n";)/s;
ok( defined $restart_line, 'found the restart-announcement print line' );

like( $restart_line, qr/\$\$/, 'the restart-announcement line includes this process\'s own PID ($$)' );
like( $restart_line, qr/scalar\s*\(?\s*localtime|strftime|time\(\)/, 'the restart-announcement line includes a timestamp' );

done_testing();
