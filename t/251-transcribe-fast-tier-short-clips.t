use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Temp;
use File::Spec;

require D2TG::Transcribe;

# TGT-251 (Michael, live via Telegram msg #446, 2026-09-15): "The voice
# note transcribing is very slow. A short 30 seconds voice note sent
# from TG to the tg.poller take like forever." select_model routed any
# duration <=300s (including a 30s clip) to 'medium', the largest/slowest
# tier - lib/D2TG/Transcribe.pm's own comments (TGT-100 follow-up,
# Michael's measured throughput data) already documented medium at ~5.6x
# real time on his host, so a 30s clip legitimately took ~168s of wall
# time before ever completing. A genuinely short, parsed duration now
# gets the fastest tier ('base') straight away.

for my $case (
    [ 1,   'base' ],
    [ 30,  'base' ],
    [ 60,  'base' ],
    [ 61,  'medium' ],
    [ 299, 'medium' ],
    [ 300, 'medium' ],
    [ 301, 'small' ],
    [ 900, 'small' ],
    [ 901, 'base' ],
)
{
    my ( $duration, $expected ) = @$case;
    is( D2TG::Transcribe::select_model($duration), $expected,
        "select_model($duration) returns '$expected'" );
}

# The unparsed/failed-probe invariant (duration coerced to 0, t/74's own
# documented guarantee: "a probe failure never behaves worse than
# pre-TGT-100 code did") must NOT be swept into the new fast tier just
# because 0 <= 60 - an unknown duration is not the same claim as a
# confirmed-short one.
is( D2TG::Transcribe::select_model(0), 'medium',
    'select_model(0) (failed/unparsed probe) still falls back to medium, not the new fast tier' );
is( D2TG::Transcribe::select_model(undef), 'medium',
    'select_model(undef) still falls back to medium, not the new fast tier' );
is( D2TG::Transcribe::select_model('garbage'), 'medium',
    'select_model(a non-numeric string) still falls back to medium, not the new fast tier' );

{
    my @whisper_calls;
    my $runner = sub {
        push @whisper_calls, [@_];
        return 0;
    };

    my $tempdir    = File::Temp::tempdir( CLEANUP => 1 );
    my $audio_path = File::Spec->catfile( $tempdir, 'voice.ogg' );
    open my $fh, '>', $audio_path or die $!;
    close $fh;

    eval {
        D2TG::Transcribe::transcribe(
            $audio_path,
            runner      => $runner,
            duration_fn => sub { return 30; },
        );
    };

    ok( @whisper_calls, 'runner was invoked' );
    my $call = $whisper_calls[0];
    my ($model_idx) = grep { $call->[$_] eq '--model' } 0 .. $#$call;
    is( $call->[ $model_idx + 1 ], 'base',
        'transcribe() automatically selects the base model for a 30-second voice note' );
}

done_testing();
