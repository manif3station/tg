package D2TG::Subprocess;

use strict;
use warnings;
use File::Spec;
use POSIX ();

sub fork_in_own_process_group {
    my (%args) = @_;

    my @cmd    = @{ $args{cmd} };
    my $forker = $args{forker} || sub { return CORE::fork() };

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
        open( STDOUT, '>', File::Spec->devnull ) or POSIX::_exit(126);
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

=head1 NAME

D2TG::Subprocess - shared fork+setpgrp+devnull+exec preamble for a killable subprocess

=head1 SYNOPSIS

    my $pid = D2TG::Subprocess::fork_in_own_process_group(
        cmd    => [ 'whisper', $audio_path, '--model', $model ],
        forker => \&coderef,    # optional, defaults to a plain fork()
    );

=head1 DESCRIPTION

TGT-144 (found via a scheduled improvement hunt): D2TG::TTS::_run and
D2TG::Transcribe::_run each independently accumulated the identical
subprocess-launch preamble across separate Codex review rounds
(TGT-127 for TTS, TGT-128 for Transcribe) - fork, die on fork failure,
in the child put it in its own process group and redirect
STDOUT/STDERR to devnull before exec, then in the parent redundantly
set the same process group to close a race a Codex review caught
(a timeout/signal firing before the child's own C<setpgrp> call would
otherwise target a process group that doesn't exist yet). This module
extracts exactly that shared preamble - each caller's own distinct
wait/timeout/kill-escalation logic (TTS's C<alarm>+C<SIGALRM>, TGT-127;
Transcribe's C<waitpid> poll loop, TGT-128/TGT-031) stays in its own
module unchanged, since that difference is a deliberate design choice,
not duplication to remove.

=head1 FUNCTIONS

=head2 fork_in_own_process_group(cmd => \@cmd, forker => \&coderef)

Forks C<$forker> (default: a plain C<fork()> call; tests inject a fake
here to exercise the fork-failure path, matching
L<D2TG::Transcribe/_run>'s own established C<$FORKER> pattern - a real
C<fork()> is not something a test can reliably make fail on demand).
Dies with a message containing C<"fork failed"> if C<$forker> returns
C<undef>.

In the child: C<setpgrp(0, 0)> puts it in its own process group (so a
caller's timeout/shutdown signal can reach the whole subprocess tree,
not just this immediate child - important since a shelled-out command
like C<whisper> or C<ffmpeg> commonly spawns children of its own),
redirects C<STDOUT>/C<STDERR> onto C<File::Spec-E<gt>devnull> (so the
external command's own console chatter never leaks onto the caller's
real stdout/stderr), then C<exec>s C<@cmd> - never via a shell, so no
injection risk. C<POSIX::_exit(126)> if the devnull redirect itself
fails (before C<exec> is even attempted), C<POSIX::_exit(127)> if
C<exec> itself fails - two distinguishable codes, matching
L<D2TG::TTS/_run>'s own pre-extraction convention. A Codex review
caught this needed care: C<D2TG::Transcribe::_run>'s own pre-extraction
code used C<127> for I<both> failure kinds, so this is a deliberate,
narrow reconciliation onto TTS's richer distinction for both callers -
not literal per-caller preservation - judged acceptable because neither
C<_run> implementation, nor anything else in this project, ever
inspects the specific exit code beyond "did it fail".

In the parent: redundantly calls C<setpgrp($pid, $pid)> too (eval-
guarded, since it can legitimately fail if the child has already
exited) - the same race-closing pattern the child's own C<setpgrp> call
protects against, from the other direction. Returns the child's pid;
the caller owns everything after that (waiting, timing out, killing).

=cut
