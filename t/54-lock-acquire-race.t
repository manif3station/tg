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
#
# TGT-084 update: "last one wins" means a racer that finds another
# racer's freshly-written PID alive now kills and retakes it instead of
# refusing, so more than one caller can transiently believe it won
# before being pre-empted itself - "exactly one call to acquire() ever
# returns true" is no longer the invariant to check. What must still
# hold (and is what TGT-064 actually cared about) is that once the race
# settles, exactly one process is left alive holding the lock. Racers
# are launched via a double-fork so each is reparented to init rather
# than staying a sibling of the others - this matches the real topology
# (an old poller and its replacement are unrelated processes) and
# matters mechanically: kill(0,$pid) keeps reporting a killed process as
# "alive" until something reaps it, and only its real parent can do
# that.
{
    my $dir  = tempdir( CLEANUP => 1 );
    my $lock = File::Spec->catfile( $dir, 'poller.pid' );

    my $n = 8;
    pipe( my $gate_read, my $gate_write ) or die "pipe: $!";

    my @worker_pids;
    for ( 1 .. $n ) {
        pipe( my $announce_read, my $announce_write ) or die "pipe: $!";

        my $launcher_pid = fork();
        die "fork failed: $!" unless defined $launcher_pid;

        if ( $launcher_pid == 0 ) {
            close $announce_read;

            my $worker_pid = fork();
            die "fork failed: $!" unless defined $worker_pid;

            if ( $worker_pid == 0 ) {
                close $announce_write;
                close $gate_write;
                my $buf;
                sysread( $gate_read, $buf, 1 );    # block until the gate opens
                close $gate_read;

                eval { D2TG::Lock::acquire($lock) };

                # Whether this racer won outright, was pre-empted
                # mid-race, or lost outright, just sit here - the test
                # process inspects who is still alive once the dust
                # settles.
                sleep 5;
                exit 0;
            }

            print {$announce_write} "$worker_pid\n";
            close $announce_write;
            exit 0;    # orphan the worker before it even reaches the gate
        }

        close $announce_write;
        my $worker_pid = <$announce_read>;
        chomp $worker_pid;
        close $announce_read;

        waitpid( $launcher_pid, 0 );    # reap the launcher right away
        push @worker_pids, $worker_pid;
    }

    close $gate_read;
    close $gate_write;    # closing without writing releases every reader at once (EOF)

    # Give the cascade of kill-and-reclaim takeovers (TGT-084) time to
    # fully settle. Each racer's own acquire() call can, in the worst
    # case, need to kill-and-wait for several other racers in turn
    # before it either wins or is itself killed, and that wait scales
    # with how slow the environment is (e.g. under Devel::Cover
    # instrumentation, or parallel `prove -j` contention) - so poll for
    # convergence with a generous overall budget instead of a fixed
    # short sleep. "Settled" means BOTH exactly one worker is alive AND
    # the lock file already names that same survivor and stays that way
    # across a short confirmation window - a laggard racer still deep in
    # its own retry loop can still preempt the current apparent survivor
    # a moment later, so checking alive-count alone, once, is not enough.
    my $read_lock_pid = sub {
        open my $fh, '<', $lock or return undef;
        my $pid = <$fh>;
        close $fh;
        return undef unless defined $pid;
        chomp $pid;
        return $pid;
    };

    my $deadline = time() + 30;
    my ( @alive, $winner_pid );
    while ( time() < $deadline ) {
        @alive      = grep { kill( 0, $_ ) } @worker_pids;
        $winner_pid = $read_lock_pid->();
        last
          if @alive == 1
          && defined $winner_pid
          && $winner_pid == $alive[0];
        select( undef, undef, undef, 0.05 );
    }

    is( scalar @alive, 1, "exactly one of $n racing processes is still alive once the race settles" );
    is( $winner_pid, $alive[0], 'the lock file names exactly the one surviving process' );

    kill( 'KILL', $_ ) for @worker_pids;
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
