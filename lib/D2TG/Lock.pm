package D2TG::Lock;

use strict;
use warnings;
use Fcntl qw(O_CREAT O_EXCL O_WRONLY);

use constant _RECLAIM_RETRIES => 50;
use constant _RECLAIM_RETRY_DELAY => 0.01;

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
            die "Another d2 tg.poller (PID $pid) is already running for this "
              . "--db/-d/D2TG_DB storage location - kill it first (kill $pid) "
              . "or wait for it to exit.\n";
        }

        if ( defined $pid ) {
            open my $fh, '>', $path
              or die "D2TG::Lock: cannot write $path: $!\n";
            print {$fh} "$$\n";
            close $fh;
            return 1;
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

=head1 FUNCTIONS

=head2 acquire($lock_path)

Its primary path (TGT-064) is C<sysopen> with C<O_CREAT|O_EXCL> - a
kernel-atomic "create only if it doesn't already exist" - so two
processes racing to acquire a fresh C<$lock_path> at once cannot both
succeed; a genuine check-then-write race existed here before TGT-064
(verified with a real 8-process fork-based race test, C<t/54-*.t>).

When C<$lock_path> already exists, dies with a clear message naming the
PID already holding the lock if it names a still-live process (checked
via C<kill(0, $pid)>, which sends no signal but confirms the process
exists) other than the caller's own C<$$> - the own-PID case is treated
as already-held-successfully, not a conflict, since C<cli/poller>'s
version-triggered self-restart (TGT-036) C<exec>s in place, keeping the
same PID. A lock file naming a PID that is no longer live (the classic
case here: a hard C<kill -9>, or any death that skipped cleanup) is
silently reclaimed rather than treated as a conflict - a stale lock must
never itself become the reason a poller can't restart after a crash. If
the file exists but has no readable PID line yet (another process's
C<O_CREAT> landed a moment ago and hasn't written its own PID), retries
the atomic create up to 50 times with a 10ms delay rather than guessing
and overwriting - guessing wrong there would let two racing processes
both "win" this exact narrow window, defeating the whole point of the
atomic primary path above.

=head2 release($lock_path)

Removes C<$lock_path> only if it still names the caller's own C<$$> - a
lock already reclaimed by a newer process (this process died without
releasing, and something else has since started) is never removed out
from under that newer owner. A silent no-op if C<$lock_path> doesn't
exist at all.

=cut
