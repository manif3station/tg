use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;
use File::Temp;
use lib "$Bin/../lib";

require File::Spec->catfile( $Bin, 'lib', 'Test', 'CaptureStdio.pm' );
Test::CaptureStdio->import(qw(run_capturing_stderr));

require D2TG::Reply;

# TGT-236 (found via a scheduled JOB-004 improvement hunt): 7 cli/*.pl
# scripts each repeated the identical eval-wrapped
# D2TG::Reply::extract_bot_flag(@ARGV) block (eval-call, check $@,
# print STDERR + exit 1) instead of calling one shared helper - the
# exact duplication class that already caused TGT-068/074/231.
# D2TG::Reply::extract_bot_flag_or_die centralizes the eval+die part;
# extract_bot_flag itself is unchanged.

{
    # Happy path: a well-formed --bot <token> is parsed through exactly
    # like calling extract_bot_flag directly.
    my ( $bot_token, @rest ) = D2TG::Reply::extract_bot_flag_or_die( '--bot', 'tok123', 'x', 'y' );
    is( $bot_token, 'tok123', 'extract_bot_flag_or_die returns the token when --bot is well-formed' );
    is_deeply( \@rest, [ 'x', 'y' ], 'extract_bot_flag_or_die returns the remaining args' );
}

{
    # No --bot present at all: undef token, args untouched - matches
    # extract_bot_flag's own bare pass-through behavior exactly.
    my ( $bot_token, @rest ) = D2TG::Reply::extract_bot_flag_or_die( 'x', 'y' );
    ok( !defined $bot_token, 'extract_bot_flag_or_die returns undef when --bot is absent' );
    is_deeply( \@rest, [ 'x', 'y' ], 'extract_bot_flag_or_die leaves other args untouched when --bot is absent' );
}

# The helper's own die path exits 1 with a clear STDERR message
# instead of propagating a raw exception - exercised via a tiny
# one-liner since extract_bot_flag_or_die calls exit() directly.
{
    my $libdir = File::Spec->catfile( $Bin, '..', 'lib' );
    my ( undef, $probe ) = File::Temp::tempfile( SUFFIX => '.pl', UNLINK => 1 );
    open my $fh, '>', $probe or die $!;
    print $fh "use lib '$libdir';\nrequire D2TG::Reply;\nD2TG::Reply::extract_bot_flag_or_die('--bot', '-x');\n";
    close $fh;
    my ( $out, $rc, $err ) = run_capturing_stderr( $^X, $probe );
    is( $rc, 1, "extract_bot_flag_or_die's own die path exits 1, not a raw uncaught exception" );
    like( $err, qr/--bot requires a value/, "extract_bot_flag_or_die's own die path prints extract_bot_flag's error to STDERR" );
}

# Regression: all 7 scripts now call the shared helper instead of
# duplicating the eval-wrap themselves, but must refuse malformed
# --bot input identically to before this refactor. '-x' unambiguously
# looks like a flag (D2TG::Config::shift_flag_value's own regex), so
# this triggers extract_bot_flag's "--bot requires a value" die
# regardless of each script's own other flags/argv-parsing order -
# unlike '--db', which several scripts strip out in a separate pass
# before --bot is ever examined, so it wouldn't reliably reach
# extract_bot_flag as the "next" token in every script.
for my $script (qw(history.pl attachment.pl unread.pl retry-download.pl approve.pl reply.pl send.pl)) {
    my $cli = File::Spec->catfile( $Bin, '..', 'cli', $script );
    local $ENV{D2TG_DB};
    my ( $out, $rc, $err ) = run_capturing_stderr( $cli, '--bot', '-x' );
    isnt( $rc, 255, "cli/$script --bot -x (malformed --bot) does not crash with Perl's raw exit 255" );
    is( $rc, 1, "cli/${script}'s --bot -x exits 1 via the shared helper" );
    like( $err, qr/--bot requires a value/, "cli/${script}'s STDERR names --bot as requiring a value" );
}

done_testing();
