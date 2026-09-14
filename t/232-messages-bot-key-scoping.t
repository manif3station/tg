use strict;
use warnings;
use Test::More;
use File::Temp qw(tempfile);
use FindBin qw($Bin);
use lib "$Bin/../lib";

require D2TG::Store;

# TGT-232 (found via a scheduled JOB-004 improvement hunt): every other
# per-chat D2TG::Store table (allow_list/pending TGT-098,
# pending_chat_ids TGT-215, failed_downloads TGT-219/225) was migrated
# to bot_key-scoping during the multi-bot rollout - the messages table
# was the one gap. Telegram's own message_id is a per-bot counter
# (TGT-063), so two different bots sharing a chat_id can legitimately
# produce colliding (chat_id, message_id) pairs; record_message's own
# unscoped ON CONFLICT(chat_id, message_id) silently overwrote one
# bot's row with another's.

sub new_store {
    my ( undef, $db_path ) = tempfile( SUFFIX => '.sqlite', UNLINK => 1 );
    return D2TG::Store->new( db_path => $db_path, admin_chat_id => 999 );
}

{
    my $store = new_store();

    $store->record_message( 111, 55, 'ada', 'hello from bot A', bot_key => 'botA' );
    $store->record_message( 111, 55, 'bob', 'hello from bot B', bot_key => 'botB' );

    my $row_a = $store->get_message( 111, 55, bot_key => 'botA' );
    my $row_b = $store->get_message( 111, 55, bot_key => 'botB' );

    is( $row_a->{sender}, 'ada', "bot A's own row survives independently, not overwritten by bot B" );
    is( $row_b->{sender}, 'bob', "bot B's own row survives independently, not overwritten by bot A" );
}

{
    my $store = new_store();
    $store->record_message( 111, 55, 'ada', 'hello', bot_key => 'botA' );
    $store->record_message( 111, 55, 'bob', 'hi',    bot_key => 'botB' );

    is( $store->is_read( 111, 55, bot_key => 'botA' ), 0, 'botA row starts unread' );
    $store->mark_read( 111, 55, bot_key => 'botA' );
    is( $store->is_read( 111, 55, bot_key => 'botA' ), 1, 'marking botA read only affects botA' );
    is( $store->is_read( 111, 55, bot_key => 'botB' ), 0, "botB's own row is unaffected by botA's mark_read" );
}

{
    my $store = new_store();
    $store->record_message( 111, 55, 'ada', 'hello', bot_key => 'botA' );
    $store->record_message( 111, 55, 'bob', 'hi',    bot_key => 'botB' );

    my @unread_a = $store->unread_messages( bot_key => 'botA' );
    is( scalar @unread_a, 1, 'unread_messages(bot_key=>botA) returns only botA\'s own row' );
    is( $unread_a[0]{sender}, 'ada', 'the correct row is returned' );

    my @unread_all = $store->unread_messages;
    is( scalar @unread_all, 2, 'unread_messages with no bot_key still lists every bot\'s own entries, matching failed_downloads\'s own convention' );
}

{
    my $store = new_store();
    $store->record_message( 111, 55, 'ada', 'hello', bot_key => 'botA', local_path => '/tmp/a.jpg' );
    $store->record_message( 111, 55, 'bob', 'hi',    bot_key => 'botB', local_path => '/tmp/b.jpg' );

    is( $store->get_attachment_path( 111, 55, bot_key => 'botA' ), '/tmp/a.jpg', "botA's own attachment path is independent" );
    is( $store->get_attachment_path( 111, 55, bot_key => 'botB' ), '/tmp/b.jpg', "botB's own attachment path is independent" );
}

# Regression: single-bot mode (no bot_key ever passed) behaves exactly
# as before - one row per (chat_id, message_id), unscoped listing/
# lookup still works, matching every existing pre-TGT-232 test's usage.
{
    my $store = new_store();
    $store->record_message( 222, 77, 'ada', 'first' );
    $store->record_message( 222, 77, 'ada', 'second' );

    my $row = $store->get_message( 222, 77 );
    is( $row->{summary}, 'second', 're-recording under the default (unscoped) bot_key still upserts the same row as before' );

    is( $store->is_read( 222, 77 ), 0, 'default bot_key is_read still works unscoped' );
    $store->mark_read( 222, 77 );
    is( $store->is_read( 222, 77 ), 1, 'default bot_key mark_read still works unscoped' );

    my @unread = $store->unread_messages;
    is( scalar @unread, 0, 'default bot_key unread_messages still works unscoped' );

    my @recent = $store->recent_messages(5);
    is( scalar @recent, 1, 'default bot_key recent_messages still works unscoped' );

    my @ranged = $store->messages_in_range;
    is( scalar @ranged, 1, 'default bot_key messages_in_range still works unscoped' );
}

done_testing();
