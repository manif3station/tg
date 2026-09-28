#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

require D2TG::TTS;

# TGT-354 (found via a scheduled JOB-003 hourly bug hunt, live-reproduced
# against the real gtts-cli binary): D2TG::TTS::synthesize used to call
# the runner as (gtts-cli, $text, --output, $mp3_path) - $text as a raw
# positional argument with nothing protecting it from Click's own option
# parser. Confirmed live: 'gtts-cli -1 degrees outside --output /tmp/x'
# fails with 'Error: No such option: -1', exit 2 - reordered to place a
# literal '--' immediately before $text, AFTER --output (confirmed live
# that '--' before --output ALSO breaks it, differently: Click then
# treats --output itself as a second positional argument).

{
    my @calls;
    my $runner = sub { push @calls, [@_]; return 0; };

    D2TG::TTS::synthesize( '-1 degrees outside', runner => $runner );

    my $gtts_argv = $calls[0];
    my ($dash_index) = grep { $gtts_argv->[$_] eq '--' } 0 .. $#$gtts_argv;
    ok( defined $dash_index, "gtts-cli's own argv includes a '--' separator" );
    is( $gtts_argv->[ $dash_index + 1 ], '-1 degrees outside',
        "the dash-leading text immediately follows '--', protecting it from gtts-cli's own option parser" );

    my ($output_index) = grep { $gtts_argv->[$_] eq '--output' } 0 .. $#$gtts_argv;
    ok( $output_index < $dash_index, "--output appears BEFORE the '--' separator, not after (a Codex-caught ordering trap)" );
}

done_testing();
