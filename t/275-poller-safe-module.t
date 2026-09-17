use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

# TGT-275 (filed via TGT-273's own REQ-029 audit): lib/D2TG/Poller.pm is
# over the board's 500-line-per-module cap. This ticket relocates the 8
# non-run_once helper functions (open_store_or_die, run_once_safe,
# _record_message_safe, _record_message_and_track_offset,
# _classify_store_error, store_write_safe, persist_offset_safe,
# skill_version_check_safe) into a new D2TG::Poller::Safe module,
# matching this session's own TGT-263/265/267 zero-forwarder precedent
# for a small caller count.

require D2TG::Poller;
require D2TG::Poller::Safe;

my @relocated = qw(
  open_store_or_die
  run_once_safe
  record_message_safe
  record_message_and_track_offset
  classify_store_error
  store_write_safe
  persist_offset_safe
  skill_version_check_safe
);

for my $name (@relocated) {
    ok( D2TG::Poller::Safe->can($name), "D2TG::Poller::Safe owns $name" );
}

for my $old_name (qw(open_store_or_die run_once_safe store_write_safe persist_offset_safe skill_version_check_safe)) {
    ok( !D2TG::Poller->can($old_name), "D2TG::Poller no longer defines $old_name (moved to Poller::Safe)" );
}

for my $private_old (qw(_record_message_safe _record_message_and_track_offset _classify_store_error)) {
    ok( !D2TG::Poller->can($private_old), "D2TG::Poller no longer defines $private_old (moved to Poller::Safe)" );
}

done_testing();
