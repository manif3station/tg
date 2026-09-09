use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Temp;
use File::Spec;
use File::Basename;

require D2TG::Transcribe;

# TGT-140 (external review finding, confirmed live by Michael msg #165):
# $TIMEOUT stayed a flat 300s constant even after TGT-100 taught
# select_model to tier the whisper model by probed audio duration - a
# clip picked as the fastest/default tier could still legitimately run
# past 300s wall-clock at real per-host throughput (measured: a 102.48s
# clip took 571s on medium, no GPU). The hard timeout used by _run must
# scale with the same duration signal select_model already computes,
# not stay fixed.

is( D2TG::Transcribe::_scaled_timeout(10), 300,
    'a short clip is floored at the original 300s timeout, never given less than before' );

is( D2TG::Transcribe::_scaled_timeout(200), 1600,
    'a mid-length clip gets a proportionally scaled budget (duration * multiplier)' );

is( D2TG::Transcribe::_scaled_timeout(10000), 3600,
    'an extremely long clip is capped at a sane ceiling, not scaled without bound' );

{
    # Codex QA-stage review finding: capping at the fixed ceiling after
    # flooring at $TIMEOUT could undercut a caller-configured $TIMEOUT
    # larger than the default ceiling - the ceiling itself must adapt
    # to never go below whatever $TIMEOUT is currently set to.
    local $D2TG::Transcribe::TIMEOUT = 7200;

    is( D2TG::Transcribe::_scaled_timeout(10), 7200,
        'a configured $TIMEOUT above the default ceiling is never undercut by a short-clip floor' );

    is( D2TG::Transcribe::_scaled_timeout(10000), 7200,
        'a configured $TIMEOUT above the default ceiling is never undercut by an extremely long clip either' );
}

{
    # An automatically-selected model (duration_fn supplied a real
    # duration) must run under a scaled timeout, not the flat package
    # default.
    my $seen_timeout;
    my $runner = sub {
        $seen_timeout = $D2TG::Transcribe::TIMEOUT;
        return 0;
    };

    my $tempdir = File::Temp::tempdir( CLEANUP => 1 );
    my $audio_path = File::Spec->catfile( $tempdir, 'voice.ogg' );
    open my $fh, '>', $audio_path or die $!;
    close $fh;

    my ($name) = File::Basename::fileparse( $audio_path, qr/\.[^.]*/ );

    my $runner_wrapper = sub {
        my (@cmd) = @_;
        $seen_timeout = $D2TG::Transcribe::TIMEOUT;
        my ($out_dir_idx) = grep { $cmd[$_] eq '--output_dir' } 0 .. $#cmd;
        my $out_dir = $cmd[ $out_dir_idx + 1 ];
        open my $out_fh, '>', File::Spec->catfile( $out_dir, "$name.txt" ) or die $!;
        print {$out_fh} "ok";
        close $out_fh;
        return 0;
    };

    D2TG::Transcribe::transcribe(
        $audio_path,
        runner      => $runner_wrapper,
        duration_fn => sub { return 200; },
    );

    is( $seen_timeout, 1600,
        'transcribe() with an automatically-selected model runs under the duration-scaled timeout, not the flat 300s default' );
}

{
    # An explicitly-passed model keeps the original flat package
    # timeout unchanged - scaling only applies to the automatic path,
    # matching the same scope restriction as TGT-100's own
    # retry-on-timeout (explicit means explicit).
    my $seen_timeout;
    my $tempdir = File::Temp::tempdir( CLEANUP => 1 );
    my $audio_path = File::Spec->catfile( $tempdir, 'voice.ogg' );
    open my $fh, '>', $audio_path or die $!;
    close $fh;

    my ($name) = File::Basename::fileparse( $audio_path, qr/\.[^.]*/ );

    my $runner = sub {
        my (@cmd) = @_;
        $seen_timeout = $D2TG::Transcribe::TIMEOUT;
        my ($out_dir_idx) = grep { $cmd[$_] eq '--output_dir' } 0 .. $#cmd;
        my $out_dir = $cmd[ $out_dir_idx + 1 ];
        open my $out_fh, '>', File::Spec->catfile( $out_dir, "$name.txt" ) or die $!;
        print {$out_fh} "ok";
        close $out_fh;
        return 0;
    };

    D2TG::Transcribe::transcribe(
        $audio_path,
        runner => $runner,
        model  => 'medium',
    );

    is( $seen_timeout, $D2TG::Transcribe::TIMEOUT,
        'an explicitly-passed model is never scaled - it keeps the flat package default' );
    is( $seen_timeout, 300, 'the flat default is still 300s' );
}

done_testing();
