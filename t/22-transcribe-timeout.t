use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use Time::HiRes qw(time);
use POSIX ();

require D2TG::Transcribe;

{
    local $D2TG::Transcribe::TIMEOUT = 1;

    my $start = time();
    my $rc = eval { D2TG::Transcribe::_run( $^X, '-e', 'sleep 30' ) };
    my $error   = $@;
    my $elapsed = time() - $start;

    ok( $elapsed < 10, "a hung command is killed well before its own 30s sleep finishes (took ${elapsed}s)" )
      or diag("elapsed was $elapsed seconds");
    like( $error, qr/timed out/i, '_run dies with a timeout-specific error when the command is killed' );
}

{
    local $D2TG::Transcribe::TIMEOUT = 30;

    is( D2TG::Transcribe::_run( $^X, '-e', 'exit 0' ), 0, '_run still returns 0 for a command that exits 0 quickly' );
    isnt( D2TG::Transcribe::_run( $^X, '-e', 'exit 3' ), 0, '_run still returns non-zero for a command that exits non-zero' );
}

{
    local $D2TG::Transcribe::TIMEOUT = 30;

    is( $D2TG::Transcribe::CURRENT_PID, undef, 'no pid tracked before any _run call' );

    D2TG::Transcribe::_run( $^X, '-e', 'exit 0' );

    is( $D2TG::Transcribe::CURRENT_PID, undef, 'CURRENT_PID is cleared again once _run returns' );
}

{
    D2TG::Transcribe::kill_current();
    ok( 1, 'kill_current is a no-op (does not die) when nothing is running' );
}

{
    my $pid = fork();
    die "test fork failed: $!" unless defined $pid;

    if ( $pid == 0 ) {
        exec( $^X, '-e', 'sleep 30' ) or POSIX::_exit(127);
    }

    local $D2TG::Transcribe::CURRENT_PID = $pid;
    D2TG::Transcribe::kill_current();

    waitpid( $pid, 0 );
    ok( ( $? & 127 ) != 0, 'kill_current actually signals the tracked pid, ending it before its own sleep would' );
}

{
    local $D2TG::Transcribe::FORKER = sub { return undef };

    eval { D2TG::Transcribe::_run( $^X, '-e', 'exit 0' ) };
    like( $@, qr/fork failed/, '_run dies clearly when fork() itself fails' );
}

done_testing();
