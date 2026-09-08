use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Temp;
use File::Spec;
use File::Basename;

require D2TG::Transcribe;

# TGT-100 (live user request via Telegram): a long voice note transcribed
# with the fixed default 'medium' model could exceed $TIMEOUT (300s) and
# get killed, losing the transcript entirely. select_model picks a
# smaller/faster multilingual model as duration grows, so transcribe()
# stays within the timeout instead of being silently lost.

for my $case (
    [ 0,    'medium' ],
    [ 299,  'medium' ],
    [ 300,  'medium' ],
    [ 301,  'small' ],
    [ 899,  'small' ],
    [ 900,  'small' ],
    [ 901,  'base' ],
    [ 3600, 'base' ],
)
{
    my ( $duration, $expected ) = @$case;
    is( D2TG::Transcribe::select_model($duration), $expected,
        "select_model($duration) returns '$expected'" );
}

{
    my @whisper_calls;
    my $runner = sub {
        push @whisper_calls, [@_];
        return 0;
    };

    # Simulate a long (20 minute) voice note via an injected duration_fn,
    # confirm transcribe() picks the 'base' tier automatically.
    my $tempdir = File::Temp::tempdir( CLEANUP => 1 );
    my $audio_path = File::Spec->catfile( $tempdir, 'voice.ogg' );
    open my $fh, '>', $audio_path or die $!;
    close $fh;

    eval {
        D2TG::Transcribe::transcribe(
            $audio_path,
            runner      => $runner,
            duration_fn => sub { return 1200; },
        );
    };

    ok( @whisper_calls, 'runner was invoked' );
    my $call = $whisper_calls[0];
    my ($model_idx) = grep { $call->[$_] eq '--model' } 0 .. $#$call;
    is( $call->[ $model_idx + 1 ], 'base',
        'transcribe() automatically selects the base model for a 20-minute (1200s) voice note' );
}

{
    my @whisper_calls;
    my $runner = sub {
        push @whisper_calls, [@_];
        return 0;
    };

    my $tempdir = File::Temp::tempdir( CLEANUP => 1 );
    my $audio_path = File::Spec->catfile( $tempdir, 'voice.ogg' );
    open my $fh, '>', $audio_path or die $!;
    close $fh;

    eval {
        D2TG::Transcribe::transcribe(
            $audio_path,
            runner      => $runner,
            duration_fn => sub { return 1200; },
            model       => 'small',
        );
    };

    my $call = $whisper_calls[0];
    my ($model_idx) = grep { $call->[$_] eq '--model' } 0 .. $#$call;
    is( $call->[ $model_idx + 1 ], 'small',
        'an explicitly-passed model overrides automatic duration-based selection' );
}

{
    # An unparseable/failed duration probe deliberately falls back to
    # the 'medium' tier (select_model(0)) - the same model transcribe()
    # always used before TGT-100, so a probe failure never behaves worse
    # than pre-TGT-100 code did. Exercised via duration_fn returning
    # undef, matching what a failed ffprobe run produces.
    my @whisper_calls;
    my $runner = sub {
        push @whisper_calls, [@_];
        return 0;
    };

    my $tempdir = File::Temp::tempdir( CLEANUP => 1 );
    my $audio_path = File::Spec->catfile( $tempdir, 'voice.ogg' );
    open my $fh, '>', $audio_path or die $!;
    close $fh;

    eval {
        D2TG::Transcribe::transcribe(
            $audio_path,
            runner      => $runner,
            duration_fn => sub { return undef; },
        );
    };

    my $call = $whisper_calls[0];
    my ($model_idx) = grep { $call->[$_] eq '--model' } 0 .. $#$call;
    is( $call->[ $model_idx + 1 ], 'medium',
        'an undef/unparseable duration falls back to the medium tier, not a crash or a smaller model' );
}

{
    # _probe_duration itself (the real default, not an injected
    # duration_fn) - exercised via a fake `ffprobe` script placed on
    # PATH, since the real ffmpeg/ffprobe binary isn't guaranteed to be
    # installed in every test environment. This still exercises the
    # real list-form pipe open(), just against a stand-in binary.
    my $bin_dir = File::Temp::tempdir( CLEANUP => 1 );
    my $fake_ffprobe = File::Spec->catfile( $bin_dir, 'ffprobe' );

    open my $fh, '>', $fake_ffprobe or die $!;
    print {$fh} "#!/bin/sh\necho '123.45'\n";
    close $fh;
    chmod 0755, $fake_ffprobe;

    local $ENV{PATH} = "$bin_dir:$ENV{PATH}";

    is( D2TG::Transcribe::_probe_duration('/any/path.ogg'), 123.45,
        '_probe_duration parses a well-formed ffprobe duration line' );
}

{
    # A failing/garbage-output ffprobe falls back to 0 (medium tier),
    # never dies and never returns something select_model can't handle.
    my $bin_dir = File::Temp::tempdir( CLEANUP => 1 );
    my $fake_ffprobe = File::Spec->catfile( $bin_dir, 'ffprobe' );

    open my $fh, '>', $fake_ffprobe or die $!;
    print {$fh} "#!/bin/sh\nexit 1\n";
    close $fh;
    chmod 0755, $fake_ffprobe;

    local $ENV{PATH} = "$bin_dir:$ENV{PATH}";

    is( D2TG::Transcribe::_probe_duration('/any/path.ogg'), 0,
        '_probe_duration falls back to 0 when ffprobe produces no usable output' );
}

{
    # TGT-100 follow-up (Michael's measured throughput data, msg #133/134):
    # duration-based tiering alone is insufficient - per-host throughput
    # varies (medium measured at ~5.6x real time on his host). The real
    # guarantee comes from automatically retrying at a faster model tier
    # when the current one times out, not just guessing a duration
    # threshold.
    my @whisper_calls;

    my $tempdir = File::Temp::tempdir( CLEANUP => 1 );
    my $audio_path = File::Spec->catfile( $tempdir, 'voice.ogg' );
    open my $fh, '>', $audio_path or die $!;
    close $fh;

    # transcribe() needs a real output file for the second (successful)
    # attempt to read back - write it now so it's already there.
    my ($name) = File::Basename::fileparse( $audio_path, qr/\.[^.]*/ );

    my $text = eval {
        D2TG::Transcribe::transcribe(
            $audio_path,
            runner      => sub {
                my (@cmd) = @_;
                push @whisper_calls, [@cmd];
                if ( @whisper_calls == 1 ) {
                    die "D2TG::Transcribe::_run: command timed out after 300s and was killed\n";
                }
                my ($out_dir_idx) = grep { $cmd[$_] eq '--output_dir' } 0 .. $#cmd;
                my $out_dir = $cmd[ $out_dir_idx + 1 ];
                open my $out_fh, '>', File::Spec->catfile( $out_dir, "$name.txt" ) or die $!;
                print {$out_fh} "transcribed on retry";
                close $out_fh;
                return 0;
            },
            duration_fn => sub { return 200; },    # would normally pick 'medium'
        );
    };

    is( $@, '', 'transcribe() does not die when a retry at a faster tier succeeds' ) or diag($@);
    is( $text, 'transcribed on retry', 'the successful retry transcript is returned' );
    is( scalar(@whisper_calls), 2, 'whisper was invoked exactly twice (initial timeout + one retry)' );
    is( $whisper_calls[0][ ( grep { $whisper_calls[0][$_] eq '--model' } 0 .. $#{ $whisper_calls[0] } )[0] + 1 ],
        'medium', 'the first attempt used the initially-selected medium tier' );
    is( $whisper_calls[1][ ( grep { $whisper_calls[1][$_] eq '--model' } 0 .. $#{ $whisper_calls[1] } )[0] + 1 ],
        'small', 'the retry attempt stepped down to the next faster tier (small)' );
}

{
    # Every tier times out, including base - transcribe() finally dies
    # with one clear error instead of retrying forever.
    my @whisper_calls;
    my $runner = sub {
        push @whisper_calls, [@_];
        die "D2TG::Transcribe::_run: command timed out after 300s and was killed\n";
    };

    my $tempdir = File::Temp::tempdir( CLEANUP => 1 );
    my $audio_path = File::Spec->catfile( $tempdir, 'voice.ogg' );
    open my $fh, '>', $audio_path or die $!;
    close $fh;

    eval {
        D2TG::Transcribe::transcribe(
            $audio_path,
            runner      => $runner,
            duration_fn => sub { return 200; },
        );
    };

    like( $@, qr/timed out/, 'transcribe() finally dies with a timeout error after exhausting every tier' );
    is( scalar(@whisper_calls), 3, 'exactly 3 attempts were made (medium, small, base) before giving up' );
}

{
    # An explicitly-passed model must NEVER get the automatic
    # retry-on-timeout fallback - explicit means explicit.
    my @whisper_calls;
    my $runner = sub {
        push @whisper_calls, [@_];
        die "D2TG::Transcribe::_run: command timed out after 300s and was killed\n";
    };

    my $tempdir = File::Temp::tempdir( CLEANUP => 1 );
    my $audio_path = File::Spec->catfile( $tempdir, 'voice.ogg' );
    open my $fh, '>', $audio_path or die $!;
    close $fh;

    eval {
        D2TG::Transcribe::transcribe(
            $audio_path,
            runner => $runner,
            model  => 'medium',
        );
    };

    like( $@, qr/timed out/, 'an explicit model still dies on timeout' );
    is( scalar(@whisper_calls), 1, 'an explicit model is never automatically retried at a different tier' );
}

done_testing();
