use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;

require File::Spec->catfile( $Bin, 'lib', 'Test', 'CaptureStdio.pm' );
Test::CaptureStdio->import(qw(run_capturing_stderr));

# TGT-231 (found via a scheduled JOB-003 hourly bug hunt): cli/reply.pl
# and cli/send.pl call D2TG::Reply::extract_bot_flag(@ARGV) directly
# inside their own --bot branch with no eval wrapper, unlike
# cli/approve.pl/cli/retry-download.pl, which already eval-wrap the
# identical call. extract_bot_flag delegates to
# D2TG::Config::shift_flag_value, which dies ("--bot requires a
# value\n") when --bot is immediately followed by another flag
# (TGT-074's own validation) - that die propagated completely
# uncaught, crashing both scripts with Perl's raw exit-255 default
# instead of this project's own established clean-refusal convention.
# Live-reproduced pre-fix: `perl cli/reply.pl --bot --caption hi 123
# hello` printed only "--bot requires a value" and exited 255.

my $reply_cli = File::Spec->catfile( $Bin, '..', 'cli', 'reply.pl' );
my $send_cli  = File::Spec->catfile( $Bin, '..', 'cli', 'send.pl' );

{
    local $ENV{D2TG_DB};
    my ( $out, $rc, $err ) = run_capturing_stderr( $reply_cli, '--bot', '--db', 'somealias', '123', 'hello' );
    isnt( $rc, 255, 'cli/reply --bot --db ... (malformed --bot swallowing --db) does not crash with Perl\'s raw exit 255' );
    is( $rc, 1, 'cli/reply --bot --db ... exits 1, matching this file\'s own --db branch convention' );
    like( $err, qr/--bot requires a value/, 'the STDERR message names --bot as requiring a value' );
}

{
    local $ENV{D2TG_DB};
    my ( $out, $rc, $err ) = run_capturing_stderr( $send_cli, '--bot', '--caption', 'hi', '123', '/etc/hostname' );
    isnt( $rc, 255, 'cli/send --bot --caption ... (malformed --bot swallowing --caption) does not crash with Perl\'s raw exit 255' );
    is( $rc, 1, 'cli/send --bot --caption ... exits 1, matching cli/reply\'s own convention' );
    like( $err, qr/--bot requires a value/, 'the STDERR message names --bot as requiring a value' );
}

# Regression: a well-formed --bot <token> usage must still work exactly
# as before on both scripts (this fix must not break the happy path).
{
    local $ENV{D2TG_DB};
    my ( $out, $rc, $err ) = run_capturing_stderr( $reply_cli, '--bot' );
    is( $rc, 1, 'cli/reply --bot (bare trailing, nothing after it) still exits 1, unaffected by this fix' );
}

done_testing();
