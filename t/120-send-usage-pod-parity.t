use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use lib "$Bin/lib";
use Test::MandatoryDb qw(setup_mandatory_db_env);

setup_mandatory_db_env( $Bin, tempdir( CLEANUP => 1 ) );

# TGT-163 (found via a scheduled improvement hunt): same Usage/POD
# drift class TGT-119/TGT-157/TGT-159 already caught 3 times, no test
# for cli/send.pl. No --help of its own - the Usage string only ever
# prints when chat_id/file_path are missing/malformed, triggered here
# via a genuine subprocess invocation with no arguments at all.

sub read_source {
    open my $fh, '<', "$Bin/../cli/send.pl" or die $!;
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

my $full_output = qx{$^X "$Bin/../cli/send.pl" 2>&1};
is( $? >> 8, 2, 'cli/send.pl with no arguments refuses with exit 2' ) or diag $full_output;
die "cli/send.pl produced no output\n" unless length $full_output;

my ($usage_output) = $full_output =~ /^(Usage:.*)$/m;
die "cli/send.pl produced no Usage: line\n" unless defined $usage_output;

my $source = read_source();

my ($synopsis) = $source =~ /=head1 SYNOPSIS\n\n(.*?)\n\n=head1/s;
die "SYNOPSIS section not found in cli/send.pl's POD\n" unless $synopsis;

my $usage_flags    = extract_flags($usage_output);
my $synopsis_flags = extract_flags($synopsis);

for my $flag ( sort keys %$usage_flags ) {
    ok( $synopsis_flags->{$flag}, "Usage string mentions $flag, and so does the POD SYNOPSIS" );
}

for my $flag ( sort keys %$synopsis_flags ) {
    ok( $usage_flags->{$flag}, "the POD SYNOPSIS mentions $flag, and so does the Usage string" );
}

done_testing();
