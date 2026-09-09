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

# Run the actual script's --help path in a real subprocess and extract
# flags from what it genuinely prints (a Codex review finding on an
# earlier draft: extracting from the enclosing `if (...) { ... }`
# source block instead included the argument-detection condition
# itself, so `-h`/`--help` would always appear "mentioned" even if a
# future edit removed them from the printed usage text - this closes
# that gap).
my $help_output = qx{$^X "$Bin/../cli/poller.pl" --help 2>&1};
die "cli/poller.pl --help produced no output\n" unless length $help_output;

my $source = read_source();

my ($synopsis) = $source =~ /=head1 SYNOPSIS\n\n(.*?)\n\n=head1/s;
die "SYNOPSIS section not found in cli/poller.pl's POD\n" unless $synopsis;

my $help_flags     = extract_flags($help_output);
my $synopsis_flags = extract_flags($synopsis);

for my $flag ( sort keys %$help_flags ) {
    ok( $synopsis_flags->{$flag}, "--help mentions $flag, and so does the POD SYNOPSIS" );
}

for my $flag ( sort keys %$synopsis_flags ) {
    ok( $help_flags->{$flag}, "the POD SYNOPSIS mentions $flag, and so does --help" );
}

done_testing();
