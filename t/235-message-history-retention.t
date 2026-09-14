use strict;
use warnings;
use Test::More;
use File::Temp qw(tempfile);
use FindBin qw($Bin);
use lib "$Bin/../lib";

require D2TG::Store;

# TGT-235: D2TG::Store's messages and sent_replies tables have no
# retention/eviction policy - every row is kept forever, unlike
# D2TG::Download::prune_vault which already caps the attachments
# vault's own disk usage. prune_history mirrors that pattern: an
# age-based cap, called once per poll cycle, no-op when nothing is
# past the window, configurable via an optional retention_days arg.

{
    my ( undef, $db ) = tempfile( SUFFIX => '.sqlite', UNLINK => 1 );
    my $store = D2TG::Store->new( db_path => $db );

    $store->record_message( 1, 1, 'Alice', 'old message' );
    $store->record_message( 1, 2, 'Alice', 'recent message' );

    # Backdate row 1 well past the default retention window; leave row
    # 2 fresh (CURRENT_TIMESTAMP, set by record_message itself).
    $store->{dbh}->do(
        q{UPDATE messages SET created_at = datetime('now', '-200 days') WHERE message_id = 1}
    );

    $store->prune_history;

    ok( !$store->get_message( 1, 1 ), 'row past the default retention window is pruned' );
    ok( $store->get_message( 1, 2 ),  'row within the default retention window survives' );
}

{
    # Configurable window: a caller-supplied retention_days overrides
    # the default, the same way prune_vault's max_bytes argument does.
    my ( undef, $db ) = tempfile( SUFFIX => '.sqlite', UNLINK => 1 );
    my $store = D2TG::Store->new( db_path => $db );

    $store->record_message( 1, 1, 'Alice', 'ten days old' );
    $store->{dbh}->do(
        q{UPDATE messages SET created_at = datetime('now', '-10 days') WHERE message_id = 1}
    );

    $store->prune_history( retention_days => 5 );

    ok( !$store->get_message( 1, 1 ), 'a row past a caller-supplied shorter retention window is pruned' );
}

{
    # No-op when nothing is past the window - matches prune_vault's own
    # untouched-when-under-cap behavior.
    my ( undef, $db ) = tempfile( SUFFIX => '.sqlite', UNLINK => 1 );
    my $store = D2TG::Store->new( db_path => $db );

    $store->record_message( 1, 1, 'Alice', 'fresh' );
    $store->prune_history;

    ok( $store->get_message( 1, 1 ), 'a store fully within the window is left untouched' );
}

{
    # sent_replies is pruned the same way.
    my ( undef, $db ) = tempfile( SUFFIX => '.sqlite', UNLINK => 1 );
    my $store = D2TG::Store->new( db_path => $db );

    $store->record_sent_text( 1, 100 );
    $store->{dbh}->do(
        q{UPDATE sent_replies SET created_at = datetime('now', '-200 days') WHERE text_message_id = 100}
    );
    $store->record_sent_text( 1, 200 );

    $store->prune_history;

    my ($old_row) = $store->{dbh}->selectrow_array(
        'SELECT 1 FROM sent_replies WHERE text_message_id = ?', undef, 100
    );
    my ($new_row) = $store->{dbh}->selectrow_array(
        'SELECT 1 FROM sent_replies WHERE text_message_id = ?', undef, 200
    );

    ok( !$old_row, 'an old sent_replies row past the retention window is pruned' );
    ok( $new_row,  'a recent sent_replies row survives' );
}

done_testing();
