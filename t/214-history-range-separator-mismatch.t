use strict;
use warnings;
use Test::More;
use File::Temp qw(tempfile);
use FindBin qw($Bin);
use lib "$Bin/../lib";

require D2TG::Store;

# TGT-214 (found via a scheduled JOB-003 hourly bug hunt, live-verified
# against a real SQLite comparison): D2TG::Store::messages_in_range
# compares --since/--until against created_at with a plain SQL string
# comparison. created_at's real stored format is SQLite's own
# CURRENT_TIMESTAMP default, SPACE-separated ("2026-09-01 08:00:00"),
# but cli/history.pl's own documented and TGT-209-validated --since/
# --until form uses 'T' as the separator ("2026-09-01T00:00:00") - the
# exact form shown in its own SYNOPSIS/usage text. Since 'T' (0x54)
# sorts after the space character (0x20), a --since value carrying a
# time-of-day component becomes lexicographically greater than every
# created_at row sharing that same calendar date, regardless of the
# row's actual time of day - silently excluding same-day messages that
# should genuinely match.
#
# t/39-message-history-range.t's own existing coverage never catches
# this because it manually writes created_at using the SAME T-separator
# as its since/until values - consistently T-separated on both sides,
# so the mismatch this ticket fixes is never exercised. This file uses
# realistic SPACE-separated created_at values (matching what
# CURRENT_TIMESTAMP/record_message actually store) to reproduce it.

sub new_store {
    my ( undef, $db_path ) = tempfile( SUFFIX => '.sqlite', UNLINK => 1 );
    return D2TG::Store->new( db_path => $db_path, admin_chat_id => 999 );
}

sub record_at {
    my ( $store, $message_id, $created_at ) = @_;
    $store->record_message( 999, $message_id, 'bob', "msg $message_id" );
    $store->{dbh}->do(
        'UPDATE messages SET created_at = ? WHERE chat_id = 999 AND message_id = ?',
        undef, $created_at, $message_id,
    );
    return;
}

{
    my $store = new_store();
    record_at( $store, 1, '2026-09-01 08:00:00' );
    record_at( $store, 2, '2026-09-01 20:00:00' );

    my @ranged = $store->messages_in_range( since => '2026-09-01T00:00:00' );

    is( scalar @ranged, 2,
        'a since value at midnight (T-separated) still includes both same-day messages, stored space-separated' );
}

{
    my $store = new_store();
    record_at( $store, 1, '2026-09-01 08:00:00' );
    record_at( $store, 2, '2026-09-01 20:00:00' );

    my @ranged = $store->messages_in_range( since => '2026-09-01T12:00:00' );

    is( scalar @ranged, 1, 'a since value mid-day correctly excludes the earlier same-day message' );
    is( $ranged[0]{message_id}, 2, 'and correctly includes the later same-day message' );
}

{
    my $store = new_store();
    record_at( $store, 1, '2026-08-31 23:59:59' );
    record_at( $store, 2, '2026-09-01 08:00:00' );

    my @ranged = $store->messages_in_range( until => '2026-09-01T12:00:00' );

    is( scalar @ranged, 2, 'an until value with a time component correctly includes same-day messages before it' );
}

# Regression: date-only --since/--until (no time component, TGT-209's
# other accepted shape) still works consistently. Note: a date-only
# --until is compared as midnight of that date (datetime()'s own
# expansion of a bare date), so it does NOT include the rest of that
# same day - this matches this ticket's own narrow scope (fixing the
# separator mismatch, not redefining date-only --until's inclusive/
# exclusive semantics, which is a separate design question) and was
# already true before this fix (a date-only until never matched a
# same-day timestamped row under the pre-fix lexicographic comparison
# either).
{
    my $store = new_store();
    record_at( $store, 1, '2026-09-01 08:00:00' );
    record_at( $store, 2, '2026-09-02 08:00:00' );

    my @ranged = $store->messages_in_range( since => '2026-09-01', until => '2026-09-02' );

    is( scalar @ranged, 1, 'date-only since/until spanning two calendar days matches exactly the earlier day\'s message' );
    is( $ranged[0]{message_id}, 1, 'the correct message is matched' );
}

done_testing();
