use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Temp;
use File::Spec;
use File::Basename;

require D2TG::Transcribe;

# TGT-359: a live bug-hunt investigation found the 'medium' tier was
# OOM-killed 5/5 attempts transcribing a real 4-minute clip on a
# memory-constrained host. Before this fix, an OOM-killed whisper
# subprocess was NOT detected as a distinct failure at all: _run()'s own
# waitpid-reap branch blindly returned "$? >> 8", which is 0 for a
# process terminated by an uncaught signal (the exit-status bits are
# only meaningful for a normal exit) - so a SIGKILLed whisper looked
# like a *successful* run to transcribe(), which then failed later and
# less clearly ("whisper did not produce the expected output") instead
# of retrying at a lighter tier the way an actual timeout already does.

{
    # _run() itself must recognise a signal-terminated child and die
    # with a distinguishing message, not silently treat it as success.
    my $err = eval { D2TG::Transcribe::_run( 'perl', '-e', 'kill 9, $$' ); 1 } ? '' : $@;
    like( $err, qr/killed by signal 9/i,
        '_run() detects a SIGKILLed subprocess and dies with a clear "killed by signal" error, not a false success' );
}

{
    # transcribe()'s retry-on-failure loop must treat a signal-killed
    # subprocess the same way it already treats a timeout: retry at the
    # next tier in @MODEL_TIERS, for an auto-selected model.
    my @whisper_calls;

    my $tempdir    = File::Temp::tempdir( CLEANUP => 1 );
    my $audio_path = File::Spec->catfile( $tempdir, 'voice.ogg' );
    open my $fh, '>', $audio_path or die $!;
    close $fh;

    my ($name) = File::Basename::fileparse( $audio_path, qr/\.[^.]*/ );

    my $text = eval {
        D2TG::Transcribe::transcribe(
            $audio_path,
            runner => sub {
                my (@cmd) = @_;
                push @whisper_calls, [@cmd];
                if ( @whisper_calls == 1 ) {
                    die "D2TG::Transcribe::_run: command was killed by signal 9 (possibly OOM)\n";
                }
                my ($out_dir_idx) = grep { $cmd[$_] eq '--output_dir' } 0 .. $#cmd;
                my $out_dir = $cmd[ $out_dir_idx + 1 ];
                open my $out_fh, '>', File::Spec->catfile( $out_dir, "$name.txt" ) or die $!;
                print {$out_fh} "transcribed after oom retry";
                close $out_fh;
                return 0;
            },
            duration_fn => sub { return 150; },    # auto-selects 'small' post-TGT-359
        );
    };

    is( $@, '', 'transcribe() does not die when a retry after an OOM kill succeeds' ) or diag($@);
    is( $text, 'transcribed after oom retry', 'the successful post-OOM retry transcript is returned' );
    is( scalar(@whisper_calls), 2, 'whisper was invoked exactly twice (initial OOM kill + one retry)' );
    is( $whisper_calls[0][ ( grep { $whisper_calls[0][$_] eq '--model' } 0 .. $#{ $whisper_calls[0] } )[0] + 1 ],
        'small', 'the first attempt used the initially-selected small tier' );
    is( $whisper_calls[1][ ( grep { $whisper_calls[1][$_] eq '--model' } 0 .. $#{ $whisper_calls[1] } )[0] + 1 ],
        'base', 'the retry attempt stepped down to the next lighter tier (base)' );
}

{
    # An explicitly-passed model must NEVER get the automatic
    # retry-on-OOM fallback either - explicit means explicit, matching
    # the existing timeout invariant.
    my @whisper_calls;
    my $runner = sub {
        push @whisper_calls, [@_];
        die "D2TG::Transcribe::_run: command was killed by signal 9 (possibly OOM)\n";
    };

    my $tempdir    = File::Temp::tempdir( CLEANUP => 1 );
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

    like( $@, qr/killed by signal/, 'an explicit model still dies on an OOM kill' );
    is( scalar(@whisper_calls), 1, 'an explicit model is never automatically retried after an OOM kill' );
}

{
    # TGT-362 (found via Codex's own adversarial review of TGT-359):
    # the retry regex matched /timed out|killed by signal/ anywhere in
    # $error - an unrelated failure whose message merely contains one of
    # those phrases as a substring (e.g. embedded in an interpolated
    # file path) would trigger an unwanted retry instead of surfacing
    # the real error. The regex must be anchored to _run's own known
    # die-message prefix, not a bare substring search.
    my @whisper_calls;
    my $runner = sub {
        push @whisper_calls, [@_];
        die "D2TG::Transcribe::transcribe: whisper did not produce the expected output /tmp/some/path/with timed out in it.txt: No such file or directory\n";
    };

    my $tempdir    = File::Temp::tempdir( CLEANUP => 1 );
    my $audio_path = File::Spec->catfile( $tempdir, 'voice.ogg' );
    open my $fh, '>', $audio_path or die $!;
    close $fh;

    eval {
        D2TG::Transcribe::transcribe(
            $audio_path,
            runner      => $runner,
            duration_fn => sub { return 150; },
        );
    };

    like( $@, qr/did not produce the expected output/,
        'an unrelated error that merely contains "timed out" as a substring propagates unchanged' );
    is( scalar(@whisper_calls), 1,
        'an unrelated error containing "timed out" as a substring does NOT trigger a retry' );
}

done_testing();
