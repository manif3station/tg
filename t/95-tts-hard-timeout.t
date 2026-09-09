use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use Time::HiRes qw(time);

require D2TG::TTS;

{
    local $D2TG::TTS::HARD_TIMEOUT = 1;

    my $started = time();
    eval { D2TG::TTS::_run( $^X, '-e', 'sleep 30' ) };
    my $error   = $@;
    my $elapsed = time() - $started;

    ok( $error, '_run died rather than waiting out the hung command' );
    like( $error, qr/timed out/i, 'the error names a timeout, not a generic failure' );
    ok( $elapsed < 5, "died within the bounded timeout window, not after the hung command's own 30s sleep (elapsed=${elapsed}s)" );
}

{
    local $D2TG::TTS::HARD_TIMEOUT = 1;

    my $error = eval {
        D2TG::TTS::synthesize( 'hello', runner => \&D2TG::TTS::_run, );
        1;
    } ? undef : $@;

    # This exercises the real default-runner code path (not an injected
    # fake) via synthesize()'s own gtts-cli step, using the real `gtts-cli`
    # command name - which will simply fail to exec (no such binary in the
    # test environment) well within the 1s bound, proving synthesize()
    # propagates a runner failure/die correctly either way (exec failure or
    # a genuine hang would both surface here, whichever occurs first).
    ok( $error, 'synthesize propagates a real _run failure (exec-not-found or timeout) rather than hanging' );
}

{
    # A thrown runner error (as opposed to a non-zero return, already
    # covered by t/13-tts.t) must still clean up both temp files and
    # re-throw - synthesize()'s own eval-wrapping around the gtts-cli
    # call exists specifically so a real _run timeout (which dies,
    # rather than returning non-zero) is not left half-cleaned-up.
    my $runner = sub { die "boom: injected gtts-cli failure\n"; };

    my $error = eval { D2TG::TTS::synthesize( 'hello', runner => $runner ); 1 } ? undef : $@;

    like( $error, qr/boom: injected gtts-cli failure/, 'synthesize re-throws a thrown gtts-cli-step runner error unchanged' );
}

{
    # Same, but for the ffmpeg step - gtts succeeds (rc 0), then ffmpeg's
    # own call throws.
    my $calls  = 0;
    my $runner = sub {
        $calls++;
        die "boom: injected ffmpeg failure\n" if $calls == 2;
        return 0;
    };

    my $error = eval { D2TG::TTS::synthesize( 'hello', runner => $runner ); 1 } ? undef : $@;

    like( $error, qr/boom: injected ffmpeg failure/, 'synthesize re-throws a thrown ffmpeg-step runner error unchanged' );
}

done_testing();
