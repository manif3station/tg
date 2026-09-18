package D2TG::Subprocess;

use strict;
use warnings;
use File::Spec;
use POSIX ();

sub fork_in_own_process_group {
    my (%args) = @_;

    my @cmd    = @{ $args{cmd} };
    my $forker = $args{forker} || sub { return CORE::fork() };

    # TGT-179: optional, defaults to the original devnull-only
    # behavior for every existing caller (TTS/Transcribe's own _run,
    # neither of which need the child's stdout captured). A caller
    # that DOES need it (D2TG::Transcribe::_probe_duration's ffprobe
    # call) passes a path instead - still never inherits the parent's
    # own real STDOUT, matching this module's whole reason to exist.
    my $stdout = $args{stdout};

    my $pid = $forker->();
    die "D2TG::Subprocess::fork_in_own_process_group: fork failed: $!\n"
      unless defined $pid;

    if ( $pid == 0 ) {
        setpgrp( 0, 0 );

        # A Codex review finding: D2TG::TTS::_run's own pre-extraction
        # code distinguished a devnull-redirect setup failure (126)
        # from an exec failure (127) - collapsing both to the same
        # code here would be an observable (if narrow) behavior change
        # for a ticket that promises none. Preserved exactly.
        open( STDOUT, '>', $stdout // File::Spec->devnull ) or POSIX::_exit(126);
        open( STDERR, '>', File::Spec->devnull ) or POSIX::_exit(126);
        exec(@cmd) or POSIX::_exit(127);
    }

    # Redundant, deliberately: without the parent ALSO calling setpgrp
    # on the child immediately after fork, there is a race - a caller
    # checking/signalling the process group before the child's own
    # setpgrp(0,0) above has run would target a process group that
    # does not exist yet. Calling it here too closes that race
    # regardless of scheduling order. eval-guarded since it can
    # legitimately fail (e.g. the child already exited).
    eval { setpgrp( $pid, $pid ) };

    return $pid;
}

1;
