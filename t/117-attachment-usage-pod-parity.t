use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use lib "$Bin/lib";
use Test::MandatoryDb qw(setup_mandatory_db_env);

setup_mandatory_db_env( $Bin, tempdir( CLEANUP => 1 ) );

# TGT-163 (found via a scheduled improvement hunt): the same Usage/POD
# drift class TGT-119/TGT-157/TGT-159 already caught 3 times had no test
# for cli/attachment.pl. Matches t/113-reply-usage-pod-parity.t's own
# established pattern - cli/attachment.pl has no --help flag of its own,
# so the Usage string only ever prints on the argument-refusal path
# (wrong number/shape of positional args), triggered here via a genuine
# subprocess invocation with no arguments at all.

sub read_source {
    open my $fh, '<', "$Bin/../cli/attachment.pl" or die $!;
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

my $full_output = qx{$^X "$Bin/../cli/attachment.pl" 2>&1};
is( $? >> 8, 2, 'cli/attachment.pl with no arguments refuses with exit 2' ) or diag $full_output;
die "cli/attachment.pl produced no output\n" unless length $full_output;

my ($usage_output) = $full_output =~ /^(Usage:.*)$/m;
die "cli/attachment.pl produced no Usage: line\n" unless defined $usage_output;

my $source = read_source();

my ($synopsis) = $source =~ /=head1 SYNOPSIS\n\n(.*?)\n\n=head1/s;
die "SYNOPSIS section not found in cli/attachment.pl's POD\n" unless $synopsis;

my $usage_flags    = extract_flags($usage_output);
my $synopsis_flags = extract_flags($synopsis);

for my $flag ( sort keys %$usage_flags ) {
    ok( $synopsis_flags->{$flag}, "Usage string mentions $flag, and so does the POD SYNOPSIS" );
}

for my $flag ( sort keys %$synopsis_flags ) {
    ok( $usage_flags->{$flag}, "the POD SYNOPSIS mentions $flag, and so does the Usage string" );
}

done_testing();
