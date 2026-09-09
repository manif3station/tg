use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);

# TGT-119 (found via a scheduled improvement hunt, reviewing TGT-107):
# cli/poller.pl's --help usage text and its own POD SYNOPSIS are two
# independently hand-maintained copies of the same flag list - nothing
# enforces they stay in sync, so a flag added/renamed in one and
# forgotten in the other would silently drift with no test failure.

sub read_source {
    open my $fh, '<', "$Bin/../cli/poller.pl" or die $!;
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

my $source = read_source();

my ($help_block) = $source =~
  /if \( grep \{ \$_ eq '--help' \|\| \$_ eq '-h' \} \@ARGV \) \{(.*?)\n\}/s;
die "--help block not found in cli/poller.pl\n" unless $help_block;

my ($synopsis) = $source =~ /=head1 SYNOPSIS\n\n(.*?)\n\n=head1/s;
die "SYNOPSIS section not found in cli/poller.pl's POD\n" unless $synopsis;

my $help_flags     = extract_flags($help_block);
my $synopsis_flags = extract_flags($synopsis);

for my $flag ( sort keys %$help_flags ) {
    ok( $synopsis_flags->{$flag}, "--help mentions $flag, and so does the POD SYNOPSIS" );
}

for my $flag ( sort keys %$synopsis_flags ) {
    ok( $help_flags->{$flag}, "the POD SYNOPSIS mentions $flag, and so does --help" );
}

done_testing();
