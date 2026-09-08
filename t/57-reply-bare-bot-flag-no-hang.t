use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;

my $reply_cli = File::Spec->catfile( $Bin, '..', 'cli', 'reply' );

use File::Temp qw(tempdir);
use lib "$Bin/lib";
use Test::MandatoryDb qw(setup_mandatory_db_env);
setup_mandatory_db_env( $Bin, tempdir( CLEANUP => 1 ) );

# TGT-068: cli/reply's flag-parsing loop must always make forward
# progress on @ARGV. A bare trailing --bot (no token following it)
# previously hung the process forever instead of falling through to the
# existing Usage error - verified live before this fix (exit 124 under a
# 3s timeout).
{
    my $pid = open( my $fh, '-|' );
    die "fork failed: $!" unless defined $pid;

    if ( $pid == 0 ) {
        open STDERR, '>&', \*STDOUT or die $!;
        exec( $reply_cli, '--bot' ) or exit 127;
    }

    my $timed_out = 0;
    local $SIG{ALRM} = sub { $timed_out = 1; kill 'KILL', $pid; };
    alarm(3);
    my $out = do { local $/; <$fh> };
    alarm(0);
    close $fh;
    waitpid( $pid, 0 ) unless $timed_out;

    ok( !$timed_out, 'cli/reply --bot (bare, no value) does not hang - exits within 3s' );
    unless ($timed_out) {
        like( $out, qr/Usage/i, 'cli/reply --bot (bare, no value) reports the same Usage error as any other malformed invocation' );
        isnt( $? >> 8, 0, 'cli/reply --bot (bare, no value) exits non-zero, like any other malformed invocation' );
    }
}

# The bare-trailing case must also hang-free when --bot follows a
# leading --db (the order the real REPLY WITH template never produces,
# but cli/reply's own docs say either order is accepted).
{
    my $pid = open( my $fh, '-|' );
    die "fork failed: $!" unless defined $pid;

    if ( $pid == 0 ) {
        open STDERR, '>&', \*STDOUT or die $!;
        exec( $reply_cli, '--db', 'testalias', '--bot' ) or exit 127;
    }

    my $timed_out = 0;
    local $SIG{ALRM} = sub { $timed_out = 1; kill 'KILL', $pid; };
    alarm(3);
    my $out = do { local $/; <$fh> };
    alarm(0);
    close $fh;
    waitpid( $pid, 0 ) unless $timed_out;

    ok( !$timed_out, '--db testalias --bot (bare, no value) does not hang either' );
    like( $out, qr/Usage/i, '--db testalias --bot (bare, no value) reports Usage' ) unless $timed_out;
}

# A normal --bot <token> pair must still be consumed correctly and
# never trip the Usage path meant for malformed invocations. Bounded
# with the same explicit fork+kill pattern as above (not eval/alarm
# around a blocking backtick, which would silently treat a timeout as a
# pass here too) since a well-formed invocation proceeds to a real
# network attempt (TTS synthesis, then a Telegram API call) rather than
# stopping at argument parsing.
{
    my $pid = open( my $fh, '-|' );
    die "fork failed: $!" unless defined $pid;

    if ( $pid == 0 ) {
        open STDERR, '>&', \*STDOUT or die $!;
        exec( $reply_cli, '--bot', 'faketoken123', '999999', 'hello', 'there' ) or exit 127;
    }

    my $timed_out = 0;
    local $SIG{ALRM} = sub { $timed_out = 1; kill 'KILL', $pid; };
    alarm(20);
    my $out = do { local $/; <$fh> };
    alarm(0);
    close $fh;
    waitpid( $pid, 0 ) unless $timed_out;

    ok( !$timed_out, 'a well-formed --bot <token> <chat_id> <text> invocation does not hang either' );
    unlike( $out, qr/Usage/i, 'a well-formed --bot <token> <chat_id> <text> invocation is not rejected as malformed' )
      unless $timed_out;
}

done_testing();
