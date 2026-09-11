package Test::CaptureStdio;

use strict;
use warnings;
use Exporter qw(import);
use File::Temp qw(tempfile);

our @EXPORT_OK = qw(capture_stdio run_capturing_stderr);

# TGT-203 (found via a scheduled JOB-004 improvement hunt): the exact
# same 8-line helper was hand-copied into 6 separate test files
# (t/59/77/183/184/185/186), differing only in each file's own
# hardcoded /tmp/d2tg-NNN-stderr.$$ suffix - matching this project's
# own established "found it twice, extract it" duplication-removal
# precedent. Uses File::Temp::tempfile instead of a hand-rolled
# $$-suffixed path, so no caller needs to pick a unique suffix at all.
# Deliberately distinct from t/202's own fork+setpgrp+timeout+kill
# helper - that one exists specifically because ITS subprocess can
# hang indefinitely pre-fix; every one of these 6 callers' subprocess
# already always exits on its own (they assert a startup-time
# refusal), so a plain backtick-and-wait is sufficient and simpler.
sub run_capturing_stderr {
    my (@cmd) = @_;
    my ( undef, $err_file ) = tempfile( UNLINK => 0 );
    my $out = `@cmd 2>$err_file`;
    my $rc  = $? >> 8;
    my $err = do { open my $fh, '<', $err_file or die $!; local $/; <$fh> };
    unlink $err_file;
    return ( $out, $rc, $err );
}

sub capture_stdio {
    my ($code) = @_;

    my ( $out_fh, $out_path ) = tempfile( UNLINK => 1 );
    my ( $err_fh, $err_path ) = tempfile( UNLINK => 1 );

    open my $saved_stdout, '>&', \*STDOUT or die $!;
    open my $saved_stderr, '>&', \*STDERR or die $!;
    open STDOUT, '>&', $out_fh or die $!;
    open STDERR, '>&', $err_fh or die $!;

    my @result = $code->();

    open STDOUT, '>&', $saved_stdout or die $!;
    open STDERR, '>&', $saved_stderr or die $!;

    close $out_fh;
    close $err_fh;
    open my $out_read, '<', $out_path or die $!;
    open my $err_read, '<', $err_path or die $!;
    local $/;
    my $captured_out = <$out_read>;
    my $captured_err = <$err_read>;

    return ( \@result, $captured_out, $captured_err );
}

1;

=head1 NAME

Test::CaptureStdio - shared test helper for capturing real STDOUT/STDERR

=head1 SYNOPSIS

    use Test::CaptureStdio qw(capture_stdio);

    my ( $result, $stdout, $stderr ) = capture_stdio( sub {
        return D2TG::Transcribe::_run(@cmd);
    } );

=head1 DESCRIPTION

Used by tests that need to prove a subprocess's own console output never
reaches the real STDOUT/STDERR (e.g. D2TG::Transcribe::_run and
D2TG::TTS::_run redirecting a forked/spawned child's descriptors,
TGT-030/TGT-033) - a mock cannot exercise this, since the property under
test is genuine OS-level file descriptor redirection.

=head1 FUNCTIONS

=head2 capture_stdio($coderef)

Temporarily redirects the real C<STDOUT>/C<STDERR> to tempfiles, runs
C<$coderef> with no arguments, restores the original descriptors, and
returns a 3-element list: an arrayref of whatever C<$coderef> returned,
the captured stdout text, and the captured stderr text.

=head2 run_capturing_stderr(@cmd)

TGT-203: runs an external command (typically one of this skill's own
C<cli/*.pl> entrypoints) via backtick, capturing its STDOUT return
value normally and its STDERR to a tempfile. Returns a 3-element list:
C<($stdout, $exit_code, $stderr)>. For a command whose subprocess
always exits on its own (e.g. a startup-time refusal) - if a
subprocess can instead hang indefinitely, use a bounded fork+setpgrp+
timeout+kill approach instead (see C<t/202-duplicate-bot-pair-refused.t>'s
own local helper, deliberately not merged into this one).

=cut
