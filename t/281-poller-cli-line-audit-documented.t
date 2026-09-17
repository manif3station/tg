use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;

# TGT-281: cli/poller.pl's raw 766-line count was flagged by a pipeline-
# continuity wc -l sweep as never having been audited against the same
# 500-line-per-module convention this session applied to lib/D2TG/*.pm.
# Investigation found no genuinely cohesive, safely-extractable cluster:
# every remaining block is order-dependent startup/shutdown sequencing or
# the main poll loop's own inline sequencing for this one entrypoint, with
# every actual reusable behavior already delegated to lib/D2TG:: (Config,
# Lock, Store, Telegram, Poller::Safe, Download, Transcribe,
# Transcribe::Retry) and independently unit-tested there. The raw line
# count itself is also misleading in the same way TGT-280 found for
# D2TG::Telegram.pm's embedded POD: here the bulk of the file is
# incident-documentation comments, not code or POD.
#
# This is a documentation-outcome ticket (no code change) - the two
# assertions below are the honest TDD equivalent for that outcome: the
# first locks in the actual finding (a regression guard against a future
# change quietly growing this script's REAL code past the cap while
# staying under the raw-line radar via comment density), the second
# proves the investigation's conclusion was actually written down,
# matching this session's own established investigation-write-up
# convention (TGT-274, TGT-279's Telegram.pm survey).

my $poller_path = File::Spec->catfile( $Bin, '..', 'cli', 'poller.pl' );
open my $fh, '<', $poller_path or die "can't open $poller_path: $!";
my ( $total, $comment, $blank, $pod ) = ( 0, 0, 0, 0 );
my $in_pod = 0;
while ( my $line = <$fh> ) {
    $total++;
    if ( $line =~ /^=\w/ ) { $in_pod = 1; }
    if ($in_pod) {
        $pod++;
        $in_pod = 0 if $line =~ /^=cut/;
        next;
    }
    if ( $line =~ /^\s*$/ )  { $blank++;   next; }
    if ( $line =~ /^\s*#/ )  { $comment++; next; }
}
close $fh;

my $code_lines = $total - $comment - $blank - $pod;

cmp_ok( $code_lines, '<', 500,
    'cli/poller.pl real (non-comment, non-blank, non-POD) code stays under the 500-line module cap' );

my $policies_path = File::Spec->catfile( $Bin, '..', 'docs', 'POLICIES.md' );
open my $pfh, '<', $policies_path or die "can't open $policies_path: $!";
my $policies = do { local $/; <$pfh> };
close $pfh;

like( $policies, qr/TGT-281/, 'docs/POLICIES.md documents the TGT-281 investigation outcome' );
like( $policies, qr/no.{0,20}extract/i,
    'docs/POLICIES.md records the no-extraction rationale for cli/poller.pl' );

done_testing();
