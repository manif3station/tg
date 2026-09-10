use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Temp;
use File::Spec;
use Time::HiRes qw(time);

require D2TG::Transcribe;

# TGT-179 (JOB-003 scheduled hourly bug hunt finding, reproduced live in
# a developer-dashboard:latest container via a stalled-FIFO ffprobe
# call): _probe_duration's open('-|', 'ffprobe', ...) had no timeout at
# all, unlike every sibling subprocess call in this codebase (whisper,
# gtts-cli/ffmpeg, HTTP downloads - all guarded by SIGALRM/
# _with_hard_timeout per TGT-035/044/126/127). It runs synchronously in
# transcribe() before the retry loop's own timeout scoping even begins,
# so a hang here blocks the ENTIRE single-threaded poller indefinitely
# for every chat, not just the one triggering it.

{
    local $D2TG::Transcribe::PROBE_TIMEOUT = 1;

    # Same fake-ffprobe-on-PATH technique t/74-transcribe-dynamic-model.t
    # already uses (the real ffprobe binary isn't guaranteed to be
    # installed in every test environment) - here it hangs instead of
    # producing output, reproducing the live incident.
    my $bin_dir      = File::Temp::tempdir( CLEANUP => 1 );
    my $fake_ffprobe = File::Spec->catfile( $bin_dir, 'ffprobe' );
    open my $fh, '>', $fake_ffprobe or die $!;
    print {$fh} "#!/bin/sh\nsleep 30\necho '123.45'\n";
    close $fh;
    chmod 0755, $fake_ffprobe;

    local $ENV{PATH} = "$bin_dir:$ENV{PATH}";

    my $started  = time();
    my $duration = D2TG::Transcribe::_probe_duration('/any/path.ogg');
    my $elapsed  = time() - $started;

    is( $duration, 0, 'a hung ffprobe falls back to 0 (medium tier) - the same fallback every other probe-failure mode already uses - instead of blocking forever' );
    ok( $elapsed < 5, "returned within the bounded timeout window, not after the hung process's own 30s sleep (elapsed=${elapsed}s)" );
}

{
    # Confirm the existing, already-tested fast paths (well-formed
    # output, garbage/failing output - both covered in
    # t/74-transcribe-dynamic-model.t) are unaffected by the new
    # timeout wrapper - same fake-ffprobe technique, generous timeout.
    local $D2TG::Transcribe::PROBE_TIMEOUT = 10;

    my $bin_dir      = File::Temp::tempdir( CLEANUP => 1 );
    my $fake_ffprobe = File::Spec->catfile( $bin_dir, 'ffprobe' );
    open my $fh, '>', $fake_ffprobe or die $!;
    print {$fh} "#!/bin/sh\necho '42.5'\n";
    close $fh;
    chmod 0755, $fake_ffprobe;

    local $ENV{PATH} = "$bin_dir:$ENV{PATH}";

    is( D2TG::Transcribe::_probe_duration('/any/path.ogg'), 42.5,
        'a normal, fast ffprobe call still works exactly as before under the new hard-timeout wrapper' );
}

done_testing();
