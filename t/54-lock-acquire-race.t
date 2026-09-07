use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Temp qw(tempdir);
use File::Spec;
use POSIX qw(:sys_wait_h);

require D2TG::Lock;

# TGT-064: D2TG::Lock::acquire's original check-then-write sequence
# (exists? -> read PID -> liveness check -> open '>') was not atomic, so
# two processes racing to acquire() the SAME fresh (non-existent) lock
# path could both pass the liveness check before either wrote the file.
# Fork N real children, hold them all at a starting gate via a shared
# pipe, then release them simultaneously to race for the same lock -
# with the fix (O_CREAT|O_EXCL), exactly one must win.
{
    my $dir  = tempdir( CLEANUP => 1 );
    my $lock = File::Spec->catfile( $dir, 'poller.pid' );

    my $n = 8;
    pipe( my $gate_read, my $gate_write ) or die "pipe: $!";

    my @pids;
    for ( 1 .. $n ) {
        my $pid = fork();
        die "fork failed: $!" unless defined $pid;

        if ( $pid == 0 ) {
            close $gate_write;
            my $buf;
            sysread( $gate_read, $buf, 1 );    # block until the gate opens
            close $gate_read;

            my $ok = eval { D2TG::Lock::acquire($lock) };

            # A winner must stay alive for longer than any loser's retry
            # loop could possibly run (50 retries * 10ms = 500ms max) -
            # otherwise a loser can legitimately see this process as
            # already-dead mid-race and correctly reclaim the lock, which
            # is D2TG::Lock's own by-design stale-lock recovery, not the
            # atomicity bug this test targets. A real d2 tg.poller stays
            # alive for its whole polling loop, never exiting a moment
            # after acquiring the lock the way a naive test process would.
            sleep 1 if $ok;

            exit( $ok ? 0 : 1 );
        }

        push @pids, $pid;
    }

    close $gate_read;
    close $gate_write;    # closing without writing releases every reader at once (EOF)

    my $wins = 0;
    for my $pid (@pids) {
        waitpid( $pid, 0 );
        $wins++ if ( $? >> 8 ) == 0;
    }

    is( $wins, 1, "exactly one of $n racing processes wins the lock" );

    open my $fh, '<', $lock or die $!;
    my $winner_pid = <$fh>;
    close $fh;
    chomp $winner_pid;
    ok( ( grep { $_ == $winner_pid } @pids ), 'the lock file names one of the actual racing children' );
}

# Exhausted-retries path: a lock file that exists but never contains a
# readable PID (garbage content) forces every retry into the "pid
# unreadable, sleep and retry" branch, eventually exhausting all of
# them.
{
    my $dir  = tempdir( CLEANUP => 1 );
    my $lock = File::Spec->catfile( $dir, 'poller.pid' );

    open my $fh, '>', $lock or die $!;
    print {$fh} "not-a-pid\n";
    close $fh;

    eval { D2TG::Lock::acquire($lock) };
    like( $@, qr/could not acquire \Q$lock\E - contended for too long/,
        'acquire dies with a clear message after exhausting all retries against an unreadable lock file' );
}

done_testing();
