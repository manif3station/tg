use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;

# TGT-288 (found via a scheduled JOB-004 improvement hunt): 7 test files
# deliberately read another package's variable/sub by full qualification
# exactly once (to avoid desyncing a doc-accuracy assertion from the real
# constant/sub, e.g. t/81's own comment) - a legitimate, intentional
# pattern that Perl's strict-vars warning system nonetheless flags as
# "used only once: possible typo", cluttering every full-suite run's
# output with real-but-benign noise. This runs each affected file as a
# real subprocess and asserts its STDERR carries none of that noise.

my @files = qw(
  t/22-transcribe-timeout.t
  t/23-transcribe-quiet-output.t
  t/40-db-alias-resolution.t
  t/80-poller-status.t
  t/81-poller-heartbeat-staleness.t
  t/212-skills-md-status-threshold-accurate.t
  t/216-heartbeat-doc-timeout-figures-accurate.t
);

for my $rel (@files) {
    my $path = File::Spec->catfile( $Bin, '..', $rel );
    my $err  = `"$^X" -I"$Bin/../lib" -I"$Bin/lib" "$path" 2>&1 1>/dev/null`;
    unlike( $err, qr/used only once: possible typo/, "$rel: no 'used only once' warning" );
}

done_testing();
