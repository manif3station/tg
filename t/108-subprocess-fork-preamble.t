use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Temp qw(tempdir);
use File::Spec;

require D2TG::Subprocess;

# TGT-144 (scheduled improvement hunt, JOB-004): D2TG::TTS::_run and
# D2TG::Transcribe::_run each independently accumulated the identical
# fork+setpgrp-race-closing+devnull-redirect+exec preamble across
# separate Codex review rounds (TGT-127/TGT-128). Pure refactor - this
# extracts exactly that shared preamble into its own testable function;
# each module's own distinct wait/timeout/kill-escalation logic is
# unchanged.

{
    my $tempdir = tempdir( CLEANUP => 1 );
    my $marker  = File::Spec->catfile( $tempdir, 'ran' );

    my $pid = D2TG::Subprocess::fork_in_own_process_group(
        cmd => [ 'sh', '-c', "echo hi > '$marker'" ],
    );

    ok( defined $pid && $pid > 0, 'returns a real child pid' );
    waitpid( $pid, 0 );
    ok( -e $marker, 'the command genuinely ran (marker file created)' );
}

{
    # A deliberately fake, non-zero, non-existent pid - proves the
    # caller-supplied forker coderef is actually used (not ignored)
    # without ever risking a real fork or mutating this test process's
    # own process group (a real pid, including $$, must never be used
    # here for that reason).
    my $forker_was_called = 0;
    my $pid = D2TG::Subprocess::fork_in_own_process_group(
        cmd    => [ 'true' ],
        forker => sub { $forker_was_called = 1; return 999999; },
    );
    ok( $forker_was_called, 'a caller-supplied forker coderef is actually invoked' );
    is( $pid, 999999, 'and its return value is what gets returned as the pid' );
}

eval {
    D2TG::Subprocess::fork_in_own_process_group(
        cmd    => [ 'true' ],
        forker => sub { return undef },
    );
};
like( $@, qr/fork failed/, 'dies with a "fork failed" message when the forker returns undef' );

{
    # Codex review finding: the redirection to devnull - the whole
    # reason this preamble exists (an external command's own console
    # chatter must never leak onto the caller's real stdout/stderr) -
    # was untested. Run a command that writes to both stdout and
    # stderr, capture THIS test process's own real stdout/stderr while
    # it runs, and confirm none of the child's output appears there.
    my $tempdir = tempdir( CLEANUP => 1 );
    my $out_capture = File::Spec->catfile( $tempdir, 'captured_out' );
    my $err_capture = File::Spec->catfile( $tempdir, 'captured_err' );

    open( my $saved_stdout, '>&', \*STDOUT ) or die $!;
    open( my $saved_stderr, '>&', \*STDERR ) or die $!;
    open( STDOUT, '>', $out_capture ) or die $!;
    open( STDERR, '>', $err_capture ) or die $!;

    my $pid = D2TG::Subprocess::fork_in_own_process_group(
        cmd => [ 'sh', '-c', 'echo to-stdout; echo to-stderr >&2' ],
    );
    waitpid( $pid, 0 );

    open( STDOUT, '>&', $saved_stdout ) or die $!;
    open( STDERR, '>&', $saved_stderr ) or die $!;

    open my $fh, '<', $out_capture or die $!;
    local $/;
    my $captured = <$fh>;
    close $fh;

    is( $captured, '', 'the child\'s own stdout/stderr never leaks onto this process\'s real streams - redirected to devnull' );
}

{
    # Codex review finding: setup-failure (the devnull redirect itself
    # failing) and exec-failure are distinguishable exit codes (126 vs
    # 127, matching D2TG::TTS::_run's own pre-extraction convention) -
    # untested. Exercise the exec-failure path directly (a command that
    # cannot exist) and confirm it's 127, not the setup-failure code.
    my $pid = D2TG::Subprocess::fork_in_own_process_group(
        cmd => [ '/this/command/does/not/exist/anywhere' ],
    );
    waitpid( $pid, 0 );
    is( $? >> 8, 127, 'an exec() failure (command not found) exits 127, distinguishable from a setup failure' );
}

{
    # The child's own process group must be set (TGT-127/128's own
    # race-closing behavior: both parent and child call setpgrp,
    # redundantly, so a caller reading the group right after this
    # returns always sees it set regardless of scheduling order).
    my $pid = D2TG::Subprocess::fork_in_own_process_group( cmd => [ 'sleep', '5' ] );
    my $pgrp = getpgrp($pid);
    is( $pgrp, $pid, 'the child is in its own process group (pgrp == pid), not the caller\'s' );
    kill( 'KILL', $pid );
    waitpid( $pid, 0 );
}

done_testing();
