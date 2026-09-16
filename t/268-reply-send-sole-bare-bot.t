use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;

require File::Spec->catfile( $Bin, 'lib', 'Test', 'CaptureStdio.pm' );
Test::CaptureStdio->import(qw(run_capturing_stderr));

# TGT-268 (found via a scheduled JOB-003 hourly bug hunt): TGT-264 fixed
# D2TG::Reply::Args::extract_bot_flag to die "--bot requires a value"
# for a sole bare --bot argument, instead of silently falling through.
# But cli/reply.pl and cli/send.pl each independently special-cased
# "if (@ARGV >= 2) { call extract_bot_flag_or_die } else { shift @ARGV }"
# around their own --bot branch - so when --bot is the ONLY remaining
# argument, both scripts take the else branch, silently discard it, and
# fall through to a generic Usage error instead of TGT-264's own clear
# message. t/231's own last block already asserts `cli/reply --bot`
# exits 1 (unaffected by ITS fix), but never checked the STDERR text -
# this file closes that gap for both scripts, checking the actual
# message, not just the exit code.

my $reply_cli = File::Spec->catfile( $Bin, '..', 'cli', 'reply.pl' );
my $send_cli  = File::Spec->catfile( $Bin, '..', 'cli', 'send.pl' );

{
    local $ENV{D2TG_DB};
    my ( $out, $rc, $err ) = run_capturing_stderr( $reply_cli, '--bot' );
    is( $rc, 1, 'cli/reply --bot (sole argument) exits 1' );
    like( $err, qr/--bot requires a value/, 'cli/reply --bot (sole argument) dies "--bot requires a value", not a generic Usage error' );
}

{
    local $ENV{D2TG_DB};
    my ( $out, $rc, $err ) = run_capturing_stderr( $send_cli, '--bot' );
    is( $rc, 1, 'cli/send --bot (sole argument) exits 1' );
    like( $err, qr/--bot requires a value/, 'cli/send --bot (sole argument) dies "--bot requires a value", not a generic Usage error' );
}

done_testing();
