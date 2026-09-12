use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;

use lib "$Bin/../lib";
require D2TG::Transcribe;

# TGT-212 (found via a scheduled JOB-005 doc-accuracy hunt): SKILLS.md's
# onboarding overview said d2 tg.status flags the heartbeat "stale past
# 20 minutes (TGT-116)" - TGT-116's original flat 1200s threshold, but
# TGT-147 (a later scheduled bug hunt) replaced it with one DERIVED from
# D2TG::Transcribe's own $TIMEOUT_CEILING/@MODEL_TIERS constants
# (currently 14400s/4h) specifically so it could never silently drift
# out of sync with the real transcription timeout again - cli/status.pl's
# own POD and docs/commands.md's d2 tg.status entry both already
# described this correctly; only SKILLS.md was never updated after that
# change. This test computes the real, current threshold the same way
# cli/status.pl itself does (never a re-typed literal, so this test
# can't silently go stale the same way) and checks SKILLS.md's own
# wording states that value, not the superseded flat 20-minute figure.

my $expected_hours = int(
    $D2TG::Transcribe::TIMEOUT_CEILING
      * scalar(@D2TG::Transcribe::MODEL_TIERS)
      * 4 / 3
) / 3600;

open my $fh, '<', File::Spec->catfile( $Bin, '..', 'SKILLS.md' ) or die $!;
my $skills_md = do { local $/; <$fh> };
close $fh;

my ($status_section) = $skills_md =~ /(`d2 tg\.status`.*?since "alive")/s;
die "D2TG test setup: could not find the d2 tg.status heartbeat-staleness sentence in SKILLS.md\n"
  unless defined $status_section;

unlike( $status_section, qr/\b20 minutes\b/,
    'SKILLS.md no longer states the superseded flat 20-minute staleness figure' );
like( $status_section, qr/\b${expected_hours}\s*hours?\b/,
    "SKILLS.md states the real, current derived threshold ($expected_hours hours)" );
like( $status_section, qr/TGT-147/,
    'SKILLS.md cites TGT-147, the ticket that made the threshold derived instead of a flat literal' );

done_testing();
