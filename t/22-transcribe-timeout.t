use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use Time::HiRes qw(time);
use POSIX ();
use File::Temp qw(tempfile);

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
    # TGT-131: kill_current must reach the whole process group _run's
    # own timeout path already does (TGT-128) - a grandchild the tracked
    # process itself spawns must not survive a shutdown-triggered kill
    # just because the timeout path was the only one fixed.
    my ( $fh, $pidfile ) = tempfile( UNLINK => 0 );
    close $fh;

    my $script = <<'PERL';
setpgrp(0, 0);
my $gc = fork();
if ( $gc == 0 ) {
    exec( 'sleep', '30' );
    exit 1;
}
open my $out, '>', $ARGV[0] or exit 1;
print $out "$gc\n";
close $out;
sleep(30);
PERL

    my $pid = fork();
    die "test fork failed: $!" unless defined $pid;

    if ( $pid == 0 ) {
        exec( $^X, '-e', $script, $pidfile ) or POSIX::_exit(127);
    }

    # A Codex review finding: a fixed sleep here is flaky (can silently
    # skip the meaningful assertion below if the pidfile isn't written
    # yet) - poll for the pidfile actually having content instead, with
    # a generous deadline.
    my $pidfile_ready = 0;
    for ( 1 .. 50 ) {
        if ( -s $pidfile ) {
            $pidfile_ready = 1;
            last;
        }
        select( undef, undef, undef, 0.1 );
    }

    ok( $pidfile_ready, 'the grandchild was actually spawned and its pid written before kill_current was called' );

    local $D2TG::Transcribe::CURRENT_PID = $pid;
    D2TG::Transcribe::kill_current();

    waitpid( $pid, 0 );

    open my $in, '<', $pidfile or die $!;
    my $grandchild_pid = <$in>;
    close $in;
    chomp $grandchild_pid if defined $grandchild_pid;
    unlink $pidfile;

    SKIP: {
        skip 'no /proc on this platform to inspect process state', 1 unless -d '/proc';
        skip 'grandchild pid was never written (process did not reach that far in time)', 1
          unless defined $grandchild_pid && length $grandchild_pid;

        my $actually_running = 1;
        for ( 1 .. 20 ) {
            if ( open my $pfh, '<', "/proc/$grandchild_pid/stat" ) {
                my $line = <$pfh>;
                close $pfh;
                my ($state) = $line =~ /^\d+\s+\([^)]*\)\s+(\S)/;
                $actually_running = defined($state) && $state !~ /^[ZX]$/;
            }
            else {
                $actually_running = 0;
            }
            last unless $actually_running;
            select( undef, undef, undef, 0.1 );
        }

        ok( !$actually_running,
            "kill_current also terminated the tracked process's own grandchild (pid $grandchild_pid), not just the direct pid" );
    }
}

{
    local $D2TG::Transcribe::FORKER = sub { return undef };

    eval { D2TG::Transcribe::_run( $^X, '-e', 'exit 0' ) };
    like( $@, qr/fork failed/, '_run dies clearly when fork() itself fails' );
}

done_testing();
