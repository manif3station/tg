package Test::Capture;

use strict;
use warnings;
use Exporter qw(import);

our @EXPORT_OK = qw(capture_stdout capture_std);

# TGT-353 (found via a scheduled JOB-004 improvement hunt): capture_stdout
# and capture_std were duplicated byte-identically across 31 test files
# (verified via md5sum, not assumed) - the same "found it twice, extract
# it" class TGT-153 (Fake::UA) and TGT-203 (Test::CaptureStdio) already
# applied to this project's own test suite. Deliberately distinct from
# Test::CaptureStdio (TGT-203): that module redirects the real OS-level
# STDOUT/STDERR file descriptors via tempfiles, for proving a forked/
# spawned child's own console output never reaches them - these two
# functions instead redirect Perl's own selected output filehandle to
# an in-memory string via a plain `open $fh, '>', \$scalar`, for
# capturing what THIS process's own print/warn calls produced. Neither
# subsumes the other; both stay separate helpers for separate purposes.

sub capture_stdout {
    my ($code) = @_;
    my $out = '';
    open my $fh, '>', \$out or die $!;
    my $old = select $fh;
    $code->();
    select $old;
    close $fh;
    return $out;
}

sub capture_std {
    my ($code) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $out_fh, '>', \$out or die $!;
    my $old_out = select $out_fh;
    local *STDERR;
    open STDERR, '>', \$err or die $!;
    $code->();
    select $old_out;
    return ( $out, $err );
}

1;

=head1 NAME

Test::Capture - shared test helpers for capturing this process's own print/warn output

=head1 SYNOPSIS

    use Test::Capture qw(capture_stdout capture_std);

    my $stdout = capture_stdout( sub { print "hello\n" } );

    my ( $stdout, $stderr ) = capture_std( sub { print "hi\n"; warn "oops\n" } );

=head1 DESCRIPTION

TGT-353 (found via a scheduled JOB-004 improvement hunt): C<capture_stdout>
(stdout only) and C<capture_std> (stdout + stderr as a pair) were each
duplicated byte-identically across many test files - C<md5sum> identified
two exact-duplicate clusters (18 and 13 files) before extraction, not
assumed. Both redirect Perl's own C<select>-ed output filehandle to an
in-memory scalar for the duration of C<$coderef>, so they only see output
this same process's own C<print>/C<warn> calls produce - not a forked or
spawned child's own file descriptors (see L<Test::CaptureStdio> for that,
a deliberately separate concern, TGT-203).

=head1 FUNCTIONS

=head2 capture_stdout($coderef)

Runs C<$coderef> with no arguments, returns everything it printed to the
currently-selected output filehandle (ordinarily C<STDOUT>) as a single
string. C<warn> output is unaffected - it still reaches the real
C<STDERR>.

=head2 capture_std($coderef)

Runs C<$coderef> with no arguments, returns a 2-element list: everything
it printed (as C<capture_stdout> above), and everything it C<warn>ed,
captured separately.

=cut
