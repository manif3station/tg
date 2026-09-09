use strict;
use warnings;
use Test::More;
use File::Temp qw(tempfile);
use FindBin qw($Bin);
use lib "$Bin/../lib";

require D2TG::Store;
require D2TG::Reply;

# TGT-114: a reply sent seconds apart with near-identical text (e.g. a
# retry after a transient send_reply failure, or an agent accidentally
# re-running the same d2 tg.reply command) currently has no
# de-duplication - it goes out twice. D2TG::Store::is_recent_duplicate_reply
# checks whether the same text was already sent to the same chat (and
# bot) within a short window; D2TG::Reply::send_reply refuses to send a
# match rather than delivering it twice.

my ( undef, $db_path ) = tempfile( SUFFIX => '.sqlite', UNLINK => 1 );
my $store = D2TG::Store->new( db_path => $db_path, admin_chat_id => 1 );

ok( !$store->is_recent_duplicate_reply( 999, 'hello there' ), 'no duplicate when nothing has been sent yet' );

$store->record_sent_text( 999, 501, text => 'hello there' );

ok( $store->is_recent_duplicate_reply( 999, 'hello there' ), 'the same text to the same chat, sent moments ago, is flagged as a duplicate' );
ok( !$store->is_recent_duplicate_reply( 999, 'a different message' ), 'different text to the same chat is not a duplicate' );
ok( !$store->is_recent_duplicate_reply( 1000, 'hello there' ), 'the same text to a DIFFERENT chat is not a duplicate' );

# Bot isolation (TGT-098/105's own precedent): the same text to the same
# chat but a DIFFERENT bot must not be flagged.
{
    my $bot_store = D2TG::Store->new( db_path => ( tempfile( SUFFIX => '.sqlite', UNLINK => 1 ) )[1], admin_chat_id => 1 );
    $bot_store->record_sent_text( 999, 601, text => 'shared chat text', bot_key => 'bot-a' );

    ok( $bot_store->is_recent_duplicate_reply( 999, 'shared chat text', bot_key => 'bot-a' ), 'flagged for the same bot that sent it' );
    ok( !$bot_store->is_recent_duplicate_reply( 999, 'shared chat text', bot_key => 'bot-b' ), 'NOT flagged for a different bot sharing the same chat_id' );
}

# Window expiry: a match outside the window must not be flagged.
{
    my $window_store = D2TG::Store->new( db_path => ( tempfile( SUFFIX => '.sqlite', UNLINK => 1 ) )[1], admin_chat_id => 1 );
    $window_store->{dbh}->do(
        "INSERT INTO sent_replies (chat_id, bot_key, text_message_id, text, created_at) VALUES (?, ?, ?, ?, datetime('now', '-1 hour'))",
        undef, 999, '', 701, 'stale text',
    );

    ok( !$window_store->is_recent_duplicate_reply( 999, 'stale text' ), 'a match from an hour ago (outside the default window) is not flagged' );
    ok( $window_store->is_recent_duplicate_reply( 999, 'stale text', window_seconds => 4000 ), 'the same match IS flagged with an explicitly widened window' );
}

# D2TG::Reply::send_reply wiring: a duplicate is refused, not sent twice.
package Fake::DedupTelegram;

sub new {
    my ( $class, %args ) = @_;
    return bless { calls => 0 }, $class;
}

sub send_message {
    my ( $self, $chat_id, $text ) = @_;
    $self->{calls}++;
    return [ { message_id => 801 } ];
}

sub send_voice {
    my ( $self, $chat_id, $path ) = @_;
    return { message_id => 802 };
}

package main;

{
    my $store    = D2TG::Store->new( db_path => ( tempfile( SUFFIX => '.sqlite', UNLINK => 1 ) )[1], admin_chat_id => 1 );
    my $telegram = Fake::DedupTelegram->new;

    D2TG::Reply::send_reply(
        telegram   => $telegram,
        chat_id    => 999,
        text       => 'do not repeat me',
        synthesize => sub { return ( tempfile( SUFFIX => '.ogg' ) )[1] },
        store      => $store,
    );
    is( $telegram->{calls}, 1, 'the first send_reply call actually sends' );

    eval {
        D2TG::Reply::send_reply(
            telegram   => $telegram,
            chat_id    => 999,
            text       => 'do not repeat me',
            synthesize => sub { return ( tempfile( SUFFIX => '.ogg' ) )[1] },
            store      => $store,
        );
    };
    like( $@, qr/duplicate/i, 'a second send_reply call with the same text to the same chat moments later dies with a clear duplicate message' );
    is( $telegram->{calls}, 1, 'send_message was never called a second time - the duplicate never actually reached Telegram' );
}

{
    # Regression: without a store, dedup checking must not apply (no
    # behavior change for a caller that never opts in).
    my $telegram = Fake::DedupTelegram->new;

    D2TG::Reply::send_reply(
        telegram   => $telegram,
        chat_id    => 999,
        text       => 'no store means no dedup',
        synthesize => sub { return ( tempfile( SUFFIX => '.ogg' ) )[1] },
    );
    D2TG::Reply::send_reply(
        telegram   => $telegram,
        chat_id    => 999,
        text       => 'no store means no dedup',
        synthesize => sub { return ( tempfile( SUFFIX => '.ogg' ) )[1] },
    );
    is( $telegram->{calls}, 2, 'without a store, an identical send is never refused - unchanged from before this ticket' );
}

done_testing();
