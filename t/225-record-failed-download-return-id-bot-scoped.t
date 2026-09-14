use strict;
use warnings;
use Test::More;
use File::Temp qw(tempfile);
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";

require D2TG::Store;

# TGT-225 (found via a scheduled JOB-003 hourly bug hunt): TGT-219
# widened failed_downloads's own UNIQUE constraint and its
# INSERT...ON CONFLICT clause to (chat_id, bot_key, message_id), but
# record_failed_download's own id-lookup SELECT right below it was
# never given the matching "AND bot_key = ?" - it still filters only
# by (chat_id, message_id). With two rows sharing the same chat_id and
# message_id but different bot_key (reachable since Telegram's own
# message_id is per-chat, not per-bot - two bots in the same group can
# both fail to download media for the same real chat message), the
# SELECT can return the wrong row's id.

sub new_store {
    my ( undef, $db_path ) = tempfile( SUFFIX => '.sqlite', UNLINK => 1 );
    return D2TG::Store->new( db_path => $db_path, admin_chat_id => 999 );
}

{
    my $store = new_store();

    my $id_a = $store->record_failed_download( 111, 55, 'fileA', bot_key => 'tokenA', error => 'boom' );
    my $id_b = $store->record_failed_download( 111, 55, 'fileB', bot_key => 'tokenB', error => 'boom' );

    isnt( $id_a, $id_b, 'two different bot_keys sharing the same (chat_id, message_id) get two different returned ids' );

    my $row_a = $store->failed_downloads( bot_key => 'tokenA' )->[0];
    my $row_b = $store->failed_downloads( bot_key => 'tokenB' )->[0];

    is( $id_a, $row_a->{id}, "tokenA's returned id matches tokenA's own stored row" );
    is( $id_b, $row_b->{id}, "tokenB's returned id matches tokenB's own stored row" );
}

# Regression: single-bot mode (bot_key constant/default) is unaffected -
# a re-queue of the SAME (chat_id, bot_key, message_id) still refreshes
# the existing row and returns its own (unchanged) id.
{
    my $store = new_store();

    my $id_1 = $store->record_failed_download( 222, 77, 'fileX', error => 'first' );
    my $id_2 = $store->record_failed_download( 222, 77, 'fileY', error => 'second' );

    is( $id_1, $id_2, 'a re-queue under the same (implicit default) bot_key refreshes the existing row and returns the same id' );
}

done_testing();
