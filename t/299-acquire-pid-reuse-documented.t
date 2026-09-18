use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;

# TGT-299 (found via a user-requested comprehensive bug/improvement
# sweep): acquire()'s "last one wins" SIGKILL takeover path reads a PID
# via _read_pid, confirms liveness with kill(0, $pid), then issues
# kill('KILL', $pid). In the narrow window between the liveness check
# and the kill, if the original process dies and the OS recycles that
# exact PID for an unrelated process, acquire() would SIGKILL an
# innocent process. This exact PID-reuse risk class is already
# explicitly documented and accepted for find_other_pollers (a
# read-only reporting function) but was neither documented nor
# mitigated for acquire()'s own path - which is materially riskier
# since it actually kills, not just reports. Per this ticket's own
# acceptance criteria, documenting the accepted risk (matching
# find_other_pollers' precedent) is an acceptable resolution alongside
# narrowing the window; narrowing it further in Perl (no atomic
# "confirm-then-kill" primitive exists) would not meaningfully reduce
# the window, so this ticket documents it explicitly instead.

my $module_path = File::Spec->catfile( $Bin, '..', 'lib', 'D2TG', 'Lock.pm' );
open my $fh, '<', $module_path or die "can't read $module_path: $!";
local $/;
my $source = <$fh>;
close $fh;

# Extract just the acquire() POD section (up to the next =head2) so
# this doesn't pass merely because SOME other part of the file
# mentions PID reuse.
my ($acquire_pod) = $source =~ /(=head2 acquire\(\$lock_path\).*?)(?=\n=head2 )/s;
ok( defined $acquire_pod, 'found the acquire() POD section' );

like( $acquire_pod, qr/PID.{0,20}reus/is,
    'acquire()\'s own POD explicitly documents the PID-reuse race window in its SIGKILL takeover path' );

like( $acquire_pod, qr/kill\(0, \$pid\)/, 'the documented risk is anchored to the liveness-check-then-kill sequence' );

done_testing();
