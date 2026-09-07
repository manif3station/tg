package Test::CaptureStdio;

use strict;
use warnings;
use Exporter qw(import);
use File::Temp qw(tempfile);

our @EXPORT_OK = qw(capture_stdio);

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

=cut
