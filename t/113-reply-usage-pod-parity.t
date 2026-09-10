use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use lib "$Bin/lib";
use Test::MandatoryDb qw(setup_mandatory_db_env);

setup_mandatory_db_env( $Bin, tempdir( CLEANUP => 1 ) );

# TGT-157 (found via a scheduled improvement hunt): cli/reply.pl's own
# STDERR Usage string and its own POD SYNOPSIS are two independently
# hand-maintained copies of the same flag list - nothing enforces they
# stay in sync, so a flag added/renamed in one and forgotten in the
# other would silently drift with no test failure. Matches
# t/88-poller-help-pod-parity.t's own established pattern for
# cli/poller.pl, adapted since cli/reply.pl has no --help flag of its
# own - the Usage string only ever prints on the argument-refusal path
# (missing/malformed chat_id or text), which this test triggers for real
# via a genuine subprocess invocation with no arguments at all.

sub read_source {
    open my $fh, '<', "$Bin/../cli/reply.pl" or die $!;
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

# Invoking with no arguments at all reliably hits the refusal path
# (undef $chat_id) regardless of env - D2TG_TOKEN/D2TG_CHAT_ID are
# irrelevant to this specific check, which only needs the argv-shape
# refusal to fire.
my $full_output = qx{$^X "$Bin/../cli/reply.pl" 2>&1};
is( $? >> 8, 2, 'cli/reply.pl with no arguments refuses with exit 2' ) or diag $full_output;
die "cli/reply.pl produced no output\n" unless length $full_output;

# Codex review finding: scan only the actual Usage: line, not the whole
# captured stderr/stdout - an unrelated warning elsewhere in the output
# could otherwise smuggle in a flag-shaped token and mask a real drift.
my ($usage_output) = $full_output =~ /^(Usage:.*)$/m;
die "cli/reply.pl produced no Usage: line\n" unless defined $usage_output;

my $source = read_source();

my ($synopsis) = $source =~ /=head1 SYNOPSIS\n\n(.*?)\n\n=head1/s;
die "SYNOPSIS section not found in cli/reply.pl's POD\n" unless $synopsis;

my $usage_flags    = extract_flags($usage_output);
my $synopsis_flags = extract_flags($synopsis);

for my $flag ( sort keys %$usage_flags ) {
    ok( $synopsis_flags->{$flag}, "Usage string mentions $flag, and so does the POD SYNOPSIS" );
}

for my $flag ( sort keys %$synopsis_flags ) {
    ok( $usage_flags->{$flag}, "the POD SYNOPSIS mentions $flag, and so does the Usage string" );
}

done_testing();
