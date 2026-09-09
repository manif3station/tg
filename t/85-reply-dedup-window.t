use strict;
use warnings;
use Test::More;
use File::Temp qw(tempfile);
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";

require D2TG::Store;
require D2TG::Reply;
require Fake::ReplyTelegram;

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

# Codex review finding: window_seconds must be validated, not silently
# accept a negative/non-numeric value and build a nonsensical SQLite
# date modifier.
{
    my $bad_store = D2TG::Store->new( db_path => ( tempfile( SUFFIX => '.sqlite', UNLINK => 1 ) )[1], admin_chat_id => 1 );

    eval { $bad_store->is_recent_duplicate_reply( 999, 'x', window_seconds => -5 ) };
    like( $@, qr/non-negative/, 'a negative window_seconds is refused' );

    eval { $bad_store->is_recent_duplicate_reply( 999, 'x', window_seconds => 'banana' ) };
    like( $@, qr/non-negative/, 'a non-numeric window_seconds is refused' );

    ok( eval { $bad_store->is_recent_duplicate_reply( 999, 'x', window_seconds => 0 ); 1 },
        'window_seconds => 0 is accepted as a valid (if trivial) value, not refused' );
}

# Codex review finding (critical): CREATE TABLE IF NOT EXISTS alone is a
# no-op against a database whose sent_replies table already exists from
# a prior TGT-105-only install, without the text column TGT-114 adds -
# a real ALTER TABLE migration (mirroring messages.read_at's own
# pattern) must actually run against such a database.
{
    my ( undef, $upgrade_db_path ) = tempfile( SUFFIX => '.sqlite', UNLINK => 1 );

    # Simulate a pre-TGT-114 database: create sent_replies in its OLD
    # shape (no text column) via a bare DBI connection, bypassing
    # D2TG::Store::new's own (already-current) _ensure_schema entirely.
    require DBI;
    my $raw_dbh = DBI->connect( "dbi:SQLite:dbname=$upgrade_db_path", '', '', { RaiseError => 1 } );
    $raw_dbh->do(
        "CREATE TABLE sent_replies (
             chat_id INTEGER NOT NULL, bot_key TEXT NOT NULL DEFAULT '',
             text_message_id INTEGER NOT NULL, voice_message_id INTEGER,
             created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
             PRIMARY KEY (chat_id, bot_key, text_message_id)
         )"
    );
    $raw_dbh->disconnect;

    my $upgraded_store = D2TG::Store->new( db_path => $upgrade_db_path, admin_chat_id => 1 );

    ok( eval { $upgraded_store->record_sent_text( 999, 801, text => 'post-upgrade text' ); 1 },
        'record_sent_text succeeds against a database upgraded from the pre-TGT-114 schema' )
      or diag("died with: $@");
    ok( $upgraded_store->is_recent_duplicate_reply( 999, 'post-upgrade text' ),
        'is_recent_duplicate_reply works correctly after the migration' );
}

# D2TG::Reply::send_reply wiring: a duplicate is refused, not sent twice.
package main;

{
    my $store    = D2TG::Store->new( db_path => ( tempfile( SUFFIX => '.sqlite', UNLINK => 1 ) )[1], admin_chat_id => 1 );
    my $telegram = Fake::ReplyTelegram->new( text_message_id => 801, voice_message_id => 802 );

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
    my $telegram = Fake::ReplyTelegram->new( text_message_id => 801, voice_message_id => 802 );

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
