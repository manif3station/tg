use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;

use lib "$Bin/../lib";
require D2TG::Transcribe;

# TGT-216 (found via a scheduled JOB-005 doc-accuracy hunt): TGT-140
# replaced D2TG::Transcribe's flat 300s-per-tier transcription timeout
# with a duration-scaled one (floored at $TIMEOUT=300, capped at
# $TIMEOUT_CEILING=3600 per tier) - but D2TG::Config::write_heartbeat's
# own POD and cli/poller.pl's matching comment (TGT-116's original
# rationale) still cited the pre-TGT-140 figures ('300s each', 'up to
# ~900s' for the full 3-tier ladder), directly contradicting the
# already-correct post-TGT-140 figures documented three POD sections
# away in D2TG::Config::heartbeat_age's own POD (which correctly uses
# $TIMEOUT_CEILING=3600). This test computes the real current worst-case
# figures from D2TG::Transcribe's own constants (never a re-typed
# literal, so it can't silently go stale the same way) and checks both
# doc locations state them.

my ( $per_tier_worst_case, $full_ladder_worst_case );
{
    no warnings 'once';
    $per_tier_worst_case = $D2TG::Transcribe::TIMEOUT_CEILING;
    $full_ladder_worst_case = $per_tier_worst_case * scalar(@D2TG::Transcribe::MODEL_TIERS);
}

# TGT-267: D2TG::Config's own POD (including write_heartbeat/
# heartbeat_age's timeout-figure text this test checks) moved out of
# Config.pm into Config.pod when the CLI flag-parsing cluster was
# extracted - checking Config.pod here instead of Config.pm.
for my $file (qw(lib/D2TG/Config.pod cli/poller.pl)) {
    open my $fh, '<', File::Spec->catfile( $Bin, '..', $file ) or die $!;
    my $text = do { local $/; <$fh> };
    close $fh;

    unlike( $text, qr/\b300s each\b|\b300s per tier\b/, "$file: no longer states the stale 300s-per-tier figure anywhere" );
    unlike( $text, qr/~?900s\b/, "$file: no longer states the stale ~900s full-ladder figure anywhere" );
    like( $text, qr/\bmedium->small->base\b.{0,200}\b\Q$per_tier_worst_case\Es\b|\b\Q$per_tier_worst_case\Es\b.{0,200}\bmedium->small->base\b/s,
        "$file: states the real per-tier worst case (${per_tier_worst_case}s) near the retry-ladder description" );
    like( $text, qr/\bmedium->small->base\b.{0,200}\b\Q$full_ladder_worst_case\Es\b|\b\Q$full_ladder_worst_case\Es\b.{0,200}\bmedium->small->base\b/s,
        "$file: states the real full-ladder worst case (${full_ladder_worst_case}s) near the retry-ladder description" );
}

done_testing();
