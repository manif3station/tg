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

        # TGT-102 (bug-hunt finding): re-acquiring our own already-held
        # lock (exactly what cli/poller.pl's version-triggered
        # self-restart does every time, since exec() preserves the PID)
        # must be an immediate no-op success - it must never fall
        # through into the fallback reclaim path below and
        # unlink+recreate a file that was never actually stale. Without
        # this explicit check, the narrow window between that unlink and
        # the atomic recreate let an independently-started second
        # poller's own acquire() land in between, read the
        # just-recreated PID as a live conflict, and SIGKILL the
        # legitimately self-restarting process.
        if ( defined $pid && $pid == $$ ) {
            return 1;
        }

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

sub is_held {
    my ($path) = @_;

    my $pid = _read_pid($path);
    return undef unless defined $pid;

    # TGT-111: a pure liveness probe - kill(0, $pid) sends no signal, it
    # only asks the kernel whether $pid exists. This must NEVER call
    # acquire() to answer a status question - acquire() would try to
    # evict a genuinely live poller per TGT-084's own "last one wins"
    # policy, which is exactly the kind of side effect a read-only
    # status check must not risk causing.
    #
    # Codex review finding: kill(0, $pid) returning false means EITHER
    # "no such process" OR "process exists but we lack permission to
    # signal it" ($!{EPERM}) - the latter still means the process is
    # alive, just owned by a different user. Not expected in this
    # project's normal single-user operation, but treating EPERM as
    # "dead" would be a real, if narrow, correctness gap.
    return $pid if kill( 0, $pid );
    return $pid if $!{EPERM};
    return undef;
}

sub find_other_pollers {
    my (%args) = @_;

    my $own_pid  = $args{own_pid}  // $$;
    my $proc_dir = $args{proc_dir} // '/proc';

    # Codex review finding (TGT-113): the default pattern must match a
    # single argv element as a whole path/basename, anchored so it
    # cannot match mid-string - a bare qr/poller\.pl/ against a
    # NUL-joined-as-spaces cmdline would false-positive on
    # "not-a-poller.pl", "poller.pl.bak", "--note=poller.pl", or even a
    # match spanning two unrelated argv elements. Requiring a preceding
    # "/" or start-of-string, and requiring the element to END in
    # "poller.pl", rejects all of those while still matching either the
    # bare basename or any full/relative path ending in it.
    my $pattern = $args{pattern} // qr{(?:^|/)poller\.pl$};

    my @found;

    opendir( my $dh, $proc_dir ) or return @found;
    for my $entry ( readdir $dh ) {
        next unless $entry =~ /^\d+$/;
        next if $entry == $own_pid;

        open my $fh, '<', "$proc_dir/$entry/cmdline" or next;
        my $cmdline = do { local $/; <$fh> };
        close $fh;

        next unless defined $cmdline;

        # cmdline is NUL-separated argv - match each element on its own
        # rather than joining with spaces and matching the whole string,
        # which would let an anchored pattern span two unrelated
        # elements (e.g. ".../poller" followed by ".pl-shaped-arg").
        my @argv = split /\0/, $cmdline;
        push @found, $entry if grep { $_ =~ $pattern } @argv;
    }
    closedir $dh;

    return @found;
}

sub classify_other_poller_token {
    my ( $pid, %args ) = @_;

    my $own_token = $args{own_token};
    my $proc_dir  = $args{proc_dir} // '/proc';

    # TGT-141: find_other_pollers' own warning already hedged with "If
    # genuinely another live poller sharing this bot token" without
    # ever checking the token - on a host running several sibling
    # projects from this skill (each with its own distinct D2TG_TOKEN),
    # that made the warning fire routinely for the single most common,
    # entirely benign case. This never guesses: any input it can't read
    # or compare confidently is 'unknown', never 'same' or 'different'.
    return 'unknown' unless defined $own_token;

    open my $fh, '<', "$proc_dir/$pid/environ" or return 'unknown';
    local $/;
    my $environ = <$fh>;
    close $fh;

    return 'unknown' unless defined $environ;

    for my $pair ( split /\0/, $environ ) {
        if ( $pair =~ /^D2TG_TOKEN=(.*)\z/s ) {
            return $1 eq $own_token ? 'same' : 'different';
        }
    }

    return 'unknown';
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
