package D2TG::Lock;

use strict;
use warnings;
use Fcntl qw(O_CREAT O_EXCL O_WRONLY);
use POSIX qw(WNOHANG);

use constant _RECLAIM_RETRIES => 50;
use constant _RECLAIM_RETRY_DELAY => 0.01;
use constant _KILL_WAIT_RETRIES => 500;
use constant _KILL_WAIT_DELAY => 0.02;

sub acquire {
    my ($path) = @_;

    for ( 1 .. _RECLAIM_RETRIES ) {

        # Primary path (TGT-064): O_CREAT|O_EXCL atomically creates the
        # file only if it does not already exist - the kernel, not a
        # check-then-write race, decides who wins when two processes
        # attempt this at once against a fresh path.
        if ( sysopen( my $fh, $path, O_CREAT | O_EXCL | O_WRONLY ) ) {
            print {$fh} "$$\n";
            close $fh;
            return 1;
        }

        # The file already exists - decide whether it's a live conflict,
        # our own (exec-restart, TGT-036), or reclaimable (a stale PID
        # left by an unclean death).
        my $pid = _read_pid($path);

        if ( defined $pid && $pid != $$ && kill( 0, $pid ) ) {

            # TGT-084 (live user request + live production incident):
            # last poller wins - kill the existing live holder instead
            # of refusing to start. SIGKILL, not SIGTERM: a poller's own
            # graceful SIGTERM handling can be delayed up to
            # DEFAULT_HARD_TIMEOUT by an in-flight long-poll call (see
            # D2TG::Poller's own KNOWN LIMITATION), which would make
            # "last one wins" take up to that long to actually happen.
            kill( 'KILL', $pid );

            for ( 1 .. _KILL_WAIT_RETRIES ) {

                # A killed PID that happens to be our own child (as in
                # the test harness's fork-based simulation) becomes a
                # zombie the instant it dies, and kill(0,$pid) keeps
                # reporting a zombie as "alive" until something reaps
                # it. waitpid(...,WNOHANG) is a harmless no-op for a PID
                # that isn't our child (returns -1 immediately), so it's
                # safe to always attempt the reap here rather than
                # trying to know in advance whether $pid is ours.
                waitpid( $pid, WNOHANG );
                last unless kill( 0, $pid );
                select( undef, undef, undef, _KILL_WAIT_DELAY );
            }

            if ( kill( 0, $pid ) ) {
                die "D2TG::Lock: PID $pid did not die after SIGKILL - cannot take over "
                  . "the lock at $path.\n";
            }

            # Fall through to the next loop iteration: the file may now
            # be stale (still names the dead PID) or, if the old
            # process's own SIGTERM-armed cleanup somehow ran first,
            # already removed - either way the existing reclaim/create
            # logic above handles it correctly on retry.
            next;
        }

        if ( defined $pid ) {

            # $pid names a dead (or, pre-TGT-084, never-live) process:
            # reclaim by unlinking the stale file and retrying the
            # atomic O_CREAT|O_EXCL path from the top, rather than
            # overwriting it in place with a non-atomic open('>', ...).
            # Before TGT-084 this branch could only ever be reached by
            # one live process at a time (any other live contender died
            # instead of racing to reclaim), so the lack of atomicity
            # here was latent, not exercised. TGT-084 makes it common:
            # several racers can independently SIGKILL the same PID and
            # then all land here within the same instant, and an
            # in-place overwrite would let more than one of them believe
            # it won. unlink+retry closes that gap by routing every
            # reclaim back through the same kernel-atomic create used
            # for a brand-new lock file.
            unlink $path;
            next;
        }

        # $pid is undefined: the file exists but has no readable PID line
        # yet - almost certainly another process's O_CREAT just landed
        # and it hasn't written its PID line yet. Overwriting it here
        # would let two racing processes both "win" this exact narrow
        # window - retry the atomic create instead of guessing.
        select( undef, undef, undef, _RECLAIM_RETRY_DELAY );
    }

    die "D2TG::Lock: could not acquire $path - contended for too long\n";
}

sub release {
    my ($path) = @_;

    return unless -e $path;

    my $pid = _read_pid($path);
    unlink $path if defined $pid && $pid == $$;

    return;
}

sub _read_pid {
    my ($path) = @_;

    open my $fh, '<', $path or return undef;
    my $pid = <$fh>;
    close $fh;

    return undef unless defined $pid;
    chomp $pid;

    return $pid =~ /^\d+$/ ? $pid : undef;
}

1;

=head1 NAME

D2TG::Lock - single-instance PID-file lock for d2 tg.poller

=head1 SYNOPSIS

    D2TG::Lock::acquire($lock_path);
    ...
    D2TG::Lock::release($lock_path);

=head1 DESCRIPTION

TGT-062, a live production incident: a previous C<d2 tg.poller> process
suspended via job control (C<Ctrl-Z>, not killed) still held an open
connection to Telegram, silently competing with a freshly started
poller for the same bot token's C<getUpdates> long-poll slot (Telegram
allows only one active consumer per token) - the visible, newly-started
poller stopped showing new messages until the stale one was found and
force-killed. A stopped process cannot be interrupted by any in-process
signal handler (including L<D2TG::Telegram>'s own TGT-044 hard timeout),
since the OS never schedules it to run, so the only fix that actually
prevents this is refusing to start a second instance in the first place.

TGT-084, a second live production incident: a monitor job kept
restarting C<d2 tg.poller> while a still-live previous instance held the
lock, and this module's original "refuse to start, name the PID to kill
manually" behavior meant every restart attempt just failed again in a
loop, since nobody was actually killing the stale instance by hand.
Michael, live: I<"only 1 poller can be run and the last one to run is
the winner and the one is running will be killed and replaced by the
new process">. C<acquire> no longer refuses when it finds a live
conflicting PID - see below.

=head1 FUNCTIONS

=head2 acquire($lock_path)

Its primary path (TGT-064) is C<sysopen> with C<O_CREAT|O_EXCL> - a
kernel-atomic "create only if it doesn't already exist" - so two
processes racing to acquire a fresh C<$lock_path> at once cannot both
succeed; a genuine check-then-write race existed here before TGT-064
(verified with a real 8-process fork-based race test, C<t/54-*.t>).

When C<$lock_path> already exists and names a still-live process (checked
via C<kill(0, $pid)>, which sends no signal but confirms the process
exists) other than the caller's own C<$$> - the own-PID case is treated
as already-held-successfully, not a conflict, since C<cli/poller.pl>'s
version-triggered self-restart (TGT-036) C<exec>s in place, keeping the
same PID - TGT-084's "last one wins" takes over: sends that process
C<SIGKILL> (not C<SIGTERM>: L<D2TG::Poller>'s own known limitation means
graceful shutdown handling can be delayed up to C<DEFAULT_HARD_TIMEOUT>
by an in-flight long-poll call, which would make a "last one wins"
takeover take just as long to actually happen), waits in a short bounded
loop (C<_KILL_WAIT_RETRIES> x C<_KILL_WAIT_DELAY>, 10 seconds by
default) for C<kill(0, $pid)> to start failing, then retries the whole
acquire loop from the top so the reclaim logic below picks up the
now-dead PID's lock file. If the target still hasn't died once that
bounded wait is exhausted, C<acquire> dies naming the PID - this should
be rare, since C<SIGKILL> cannot be caught or blocked, but a genuinely
pathological process (or a severely overloaded host where the kernel
itself is slow to deliver and reap) could still exceed the bound.

Because more than one live process can be trying this at once (each
racer is entitled to take over from whoever it currently finds), more
than one caller can transiently believe it has won before being
pre-empted itself moments later - this is expected under "last one
wins," not a bug. What must still hold, and does (C<t/54-*.t>,
C<t/66-*.t>), is that the race always settles to exactly one process
left alive holding a lock file that names it.

A lock file naming a PID that is no longer live (a hard C<kill -9>, an
unclean death, or a target this function itself just killed) is
reclaimed by unlinking the stale file and retrying the atomic
C<O_CREAT|O_EXCL> path from the top, rather than overwriting it in
place. Before TGT-084 this reclaim path could only ever be reached by
one live process at a time (any rival simply refused instead of racing
to reclaim), so a plain, non-atomic overwrite there was never actually
exercised concurrently; TGT-084 makes several racers reaching it at the
same instant a real, exercised scenario, so it's routed through the same
kernel-atomic create used for a brand-new lock instead. If the file
exists but has no readable PID line yet (another process's C<O_CREAT>
landed a moment ago and hasn't written its own PID), retries the atomic
create up to 50 times with a 10ms delay rather than guessing and
overwriting - guessing wrong there would let two racing processes both
"win" this exact narrow window, defeating the whole point of the atomic
primary path above.

=head2 release($lock_path)

Removes C<$lock_path> only if it still names the caller's own C<$$> - a
lock already reclaimed by a newer process (this process died without
releasing, and something else has since started) is never removed out
from under that newer owner. A silent no-op if C<$lock_path> doesn't
exist at all.

=cut
