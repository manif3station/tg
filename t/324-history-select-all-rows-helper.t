use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

require D2TG::Store::History;

package main;

# TGT-324 (found via a live JOB-004 improvement hunt): unread_messages,
# recent_messages, and messages_in_range each independently build their
# own $sql/@bind, but all three end with the exact same 2 lines - "my
# $rows = $self->{dbh}->selectall_arrayref( $sql, { Slice => {} },
# @bind ); return @$rows;" - byte-identical in all 3. Collapsed into
# one shared _select_all_rows($self, $sql, @bind) helper, called from
# all 3 sites. Pure refactor: byte-identical behavior for every
# existing scenario.
#
# Matching TGT-279/313/314/318/320's own precedent for a
# pure-extraction refactor, a genuinely-red can()-based structural
# test rather than a new-behavior test, since there is no new
# behavior.

ok( D2TG::Store::History->can('_select_all_rows'),
    'D2TG::Store::History::_select_all_rows exists - the shared helper collapsing all 3 query methods\' own identical selectall_arrayref+return shape' );

done_testing();
