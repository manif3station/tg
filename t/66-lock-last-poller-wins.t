use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Temp qw(tempdir);
use File::Spec;
use POSIX qw(:sys_wait_h);

require D2TG::Lock;

# TGT-084 (live user request + live production incident): only one
# poller may hold the lock at a time, and the LAST one to try wins - a
# new acquire() call kills whatever live process currently holds the
# lock, instead of refusing to start. This replaces TGT-062's original
# "refuse to start, name the PID to kill manually" behavior.

{
    my $dir  = tempdir( CLEANUP => 1 );
    my $lock = File::Spec->catfile( $dir, 'poller.pid' );

    # A real child process acquires the lock and then sleeps, exactly
    # like a real, healthy, long-running poller holding it.
    my $pid = fork();
    die "fork failed: $!" unless defined $pid;

    if ( $pid == 0 ) {
        D2TG::Lock::acquire($lock);
        sleep 30;    # would be killed by the parent long before this
        exit 0;
    }

    # Give the child a moment to actually acquire and write its PID.
    my $tries = 0;
    while ( $tries++ < 100 ) {
        last if kill( 0, $pid ) && -e $lock;
        select( undef, undef, undef, 0.01 );
    }
    ok( kill( 0, $pid ), 'the child process is alive and holding the lock before the new acquire() call' );

    # A new "last one wins" acquire() call against the SAME path must
    # kill the existing live holder and take over.
    my $acquired = eval { D2TG::Lock::acquire($lock) };
    my $err = $@;

    ok( $acquired, 'acquire() succeeds by taking over from the existing live holder (TGT-084)' ) or diag("acquire() died: $err");

    # The old process must actually be dead now, not merely about to be.
    my $dead_tries = 0;
    while ( $dead_tries++ < 100 && kill( 0, $pid ) ) {
        select( undef, undef, undef, 0.01 );
    }
    ok( !kill( 0, $pid ), 'the existing live holder was actually killed, not merely ignored' );

    waitpid( $pid, WNOHANG );    # reap if already dead; harmless if not

    D2TG::Lock::release($lock);
}

{
    # Regression, reshaped for TGT-084: N fresh processes racing for a
    # never-before-held lock no longer guarantees "exactly one call to
    # acquire() ever returns true" - under "last one wins", a racer that
    # finds another racer's freshly-written PID alive now kills and
    # retakes it rather than refusing, so more than one caller can
    # transiently believe it won before being pre-empted itself. The
    # invariant that must still hold is the one TGT-062/TGT-064 actually
    # care about: once the race settles, exactly ONE process is left
    # alive, and it is the one the lock file actually names.
    #
    # Each racer is launched via a "shepherd" process: the shepherd forks
    # the actual worker and then blocks in waitpid() on it for the
    # worker's whole lifetime, reaping it the instant it dies. This
    # matters mechanically: kill(0,$pid) keeps reporting a killed process
    # as "alive" until something reaps it, and only its real parent can
    # do that. An earlier version of this test instead double-forked to
    # orphan the worker to init, expecting init to reap it - that broke
    # under `docker compose run ... bash -lc '...'`, where the container
    # entrypoint is plain bash acting as PID 1, which does NOT run a
    # reaping loop for reparented orphans (no tini/dumb-init in this
    # image) - workers became permanent zombies and the race never
    # converged. A shepherd that is the worker's own direct, permanent
    # parent has no such dependency on the container's PID 1 behavior.
    my $dir  = tempdir( CLEANUP => 1 );
    my $lock = File::Spec->catfile( $dir, 'poller.pid' );

    my $n = 4;
    pipe( my $gate_read, my $gate_write ) or die "pipe: $!";

    my ( @worker_pids, @shepherd_pids );
    for ( 1 .. $n ) {
        pipe( my $announce_read, my $announce_write ) or die "pipe: $!";

        my $shepherd_pid = fork();
        die "fork failed: $!" unless defined $shepherd_pid;

        if ( $shepherd_pid == 0 ) {
            close $announce_read;

            my $worker_pid = fork();
            die "fork failed: $!" unless defined $worker_pid;

            if ( $worker_pid == 0 ) {
                close $announce_write;
                close $gate_write;
                my $buf;
                sysread( $gate_read, $buf, 1 );
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

            # The shepherd itself inherited its own copies of the gate
            # pipe's ends (from the fork chain) and must close both -
            # otherwise its still-open $gate_write keeps the pipe's
            # write end alive even after the main test process closes
            # its own copy, so the worker's sysread() below never sees
            # EOF and blocks at the gate forever, and the shepherd
            # itself then blocks forever in the waitpid() below waiting
            # for a worker that can never proceed: a real deadlock this
            # test hit and had to be fixed.
            close $gate_read;
            close $gate_write;

            waitpid( $worker_pid, 0 );    # reap the worker the instant it dies, whenever that is
            exit 0;
        }

        close $announce_write;
        my $worker_pid = <$announce_read>;
        chomp $worker_pid;
        close $announce_read;

        push @worker_pids,   $worker_pid;
        push @shepherd_pids, $shepherd_pid;
    }

    close $gate_read;
    close $gate_write;    # closing without writing releases every worker's gate at once

    # Give the race (including any TGT-084 kill-and-reclaim takeovers)
    # time to fully settle before inspecting who's left. Poll for
    # convergence with a generous overall budget rather than a fixed
    # short sleep - a worst-case cascade of kill-and-wait takeovers
    # scales with how slow the environment is (Devel::Cover
    # instrumentation, parallel `prove -j` contention, etc). "Settled"
    # means BOTH exactly one worker is alive AND the lock file already
    # names that same survivor - a laggard racer still deep in its own
    # retry loop can still preempt the current apparent survivor a
    # moment later, so checking alive-count alone, once, is not enough.
    my $read_lock_pid = sub {
        open my $fh, '<', $lock or return undef;
        my $pid = <$fh>;
        close $fh;
        return undef unless defined $pid;
        chomp $pid;
        return $pid;
    };

    my $deadline = time() + 60;
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

    is( scalar @alive, 1,
        'exactly one of N racing fresh processes is still alive once the race settles - the TOCTOU guarantee (TGT-064) still holds as a survivor invariant under TGT-084'
    );

    is( $winner_pid, $alive[0], 'the lock file names exactly the one surviving process' );

    kill( 'KILL', $_ ) for @worker_pids;
    waitpid( $_, 0 ) for @shepherd_pids;    # each shepherd exits right after reaping its own worker
}

done_testing();
