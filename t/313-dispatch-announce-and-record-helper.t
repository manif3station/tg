use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";

require D2TG::Poller::Dispatch;

package main;

# TGT-313 (found via a JOB-004 improvement hunt, reviewing TGT-312's own
# freshly-shipped diff): handle_plain_update's text branch and
# voice-success branch each duplicate an identical-shaped
# defined($message_id)-branching announce/record block - the same
# duplication shape that let TGT-311's own regression (TGT-312) happen.
# This extracts a shared private helper, _announce_and_record, called
# from both branches instead. Pure refactor: no behavior change, the
# existing suite (t/04, t/17, t/24, t/312, etc.) is the regression guard,
# so this ticket's own "red" test only proves the new helper exists -
# matching TGT-279's own precedent for a pure-extraction refactor.

ok( D2TG::Poller::Dispatch->can('_announce_and_record'),
    'D2TG::Poller::Dispatch::_announce_and_record exists - the shared helper both the text and voice-success branches now call' );

done_testing();
