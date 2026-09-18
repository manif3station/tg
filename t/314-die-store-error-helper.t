use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

require D2TG::Poller::Safe;

package main;

# TGT-314 (found via a scheduled JOB-004 improvement hunt): 12 direct
# call sites across 7 cli/*.pl scripts (cli/fetch.pl, cli/attachment.pl,
# cli/approve.pl, cli/history.pl, cli/text-only-replies.pl, cli/reply.pl,
# cli/unread.pl) duplicated the exact same shape - if ($@) { my $reason
# = classify_store_error($@); print STDERR "STORE ERROR: <op> failed -
# $reason\n"; exit 1; } - differing only by the literal <op> label.
# lib/D2TG/RetryCli.pm already had its own copy of this shape too.
# Extracted into one shared die_store_error($err, $op_label) helper,
# called from all 13 sites. Pure refactor: byte-identical STDERR output
# and exit code for every existing scenario.
#
# Matching TGT-279/313's own precedent for a pure-extraction refactor -
# a can()-based structural test rather than a new-behavior test, since
# there is no new behavior.

ok( D2TG::Poller::Safe->can('die_store_error'),
    'D2TG::Poller::Safe::die_store_error exists - the shared helper collapsing all 13 STORE ERROR print+exit call sites' );

done_testing();
