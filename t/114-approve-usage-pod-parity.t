use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use lib "$Bin/lib";
use Test::MandatoryDb qw(setup_mandatory_db_env);

setup_mandatory_db_env( $Bin, tempdir( CLEANUP => 1 ) );

# TGT-159 (found via a scheduled improvement hunt, a systematic sweep
# across all cli/*.pl scripts after TGT-157 found the same pattern in
# cli/reply.pl): cli/approve.pl's own STDERR Usage string and its own
# POD SYNOPSIS are two independently hand-maintained copies of the same
# flag set - nothing enforces they stay in sync, so a flag added and
# forgotten in one would silently drift with no test failure. This test
# checks flag-set parity only (a missing/extra flag), not full-string
# match (wording, bracket/optionality notation, or ordering can still
# differ) - a deliberately loose check, matching t/113-reply-usage-pod-
# parity.t's own established precedent - adapted for cli/approve.pl:
# the Usage string only ever prints on the argument-refusal path
# (missing/malformed chat_id), which this test triggers for real via a
# genuine subprocess invocation with no
# arguments at all.

sub read_source {
    open my $fh, '<', "$Bin/../cli/approve.pl" or die $!;
    local $/;
    return <$fh>;
}

sub extract_flags {
    my ($text) = @_;
    my %flags;
    while ( $text =~ /(--[a-z][a-z0-9_-]*\b|-[a-z]\b)/g ) {
        $flags{$1} = 1;
    }
    return \%flags;
}

my $full_output = qx{$^X "$Bin/../cli/approve.pl" 2>&1};
is( $? >> 8, 2, 'cli/approve.pl with no arguments refuses with exit 2' ) or diag $full_output;
die "cli/approve.pl produced no output\n" unless length $full_output;

my ($usage_output) = $full_output =~ /^(Usage:.*)$/m;
die "cli/approve.pl produced no Usage: line\n" unless defined $usage_output;

my $source = read_source();

my ($synopsis) = $source =~ /=head1 SYNOPSIS\n\n(.*?)\n\n=head1/s;
die "SYNOPSIS section not found in cli/approve.pl's POD\n" unless $synopsis;

my $usage_flags    = extract_flags($usage_output);
my $synopsis_flags = extract_flags($synopsis);

for my $flag ( sort keys %$usage_flags ) {
    ok( $synopsis_flags->{$flag}, "Usage string mentions $flag, and so does the POD SYNOPSIS" );
}

for my $flag ( sort keys %$synopsis_flags ) {
    ok( $usage_flags->{$flag}, "the POD SYNOPSIS mentions $flag, and so does the Usage string" );
}

done_testing();
