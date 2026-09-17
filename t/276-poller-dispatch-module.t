use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

# TGT-276 (filed via TGT-275's own REQ-029 audit): lib/D2TG/Poller.pm's
# run_once was still ~520 lines dispatching 3 top-level branches
# (message_reaction, edited_message, and the plain-text/voice/media
# fallback) sharing local state. Splitting them into private functions
# WITHIN the same file would not reduce the module's line count at all
# (nothing removed, only reorganized) - so, matching the
# D2TG::Poller::Safe/Format precedent, the 3 branch handlers (plus
# their own extensive historical comment blocks, moved to this new
# module's own POD) were relocated into a new D2TG::Poller::Dispatch
# module. run_once itself becomes a short dispatch loop.

require D2TG::Poller;
require D2TG::Poller::Dispatch;

for my $name (qw(handle_message_reaction handle_edited_message handle_plain_update)) {
    ok( D2TG::Poller::Dispatch->can($name), "D2TG::Poller::Dispatch owns $name" );
}

done_testing();
