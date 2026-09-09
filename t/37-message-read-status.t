use strict;
use warnings;
use Test::More;
use File::Temp qw(tempfile);
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";

require D2TG::Store;
require D2TG::Reply;
require Fake::ReplyTelegram;

package main;

sub new_store {
    my ( undef, $db_path ) = tempfile( SUFFIX => '.sqlite', UNLINK => 1 );
    return D2TG::Store->new( db_path => $db_path, admin_chat_id => 999 );
}

{
    my $store = new_store();
    $store->record_message( 999, 100, 'bob', 'hello' );

    is( $store->is_read( 999, 100 ), 0, 'a newly recorded message is unread' );

    $store->mark_read( 999, 100 );

    is( $store->is_read( 999, 100 ), 1, 'mark_read makes is_read true' );
}

{
    my $store = new_store();

    is( $store->is_read( 999, 12345 ), 0, 'a message with no stored record at all reads as unread, not a crash' );
}

{
    my $store = new_store();
    $store->record_message( 999, 100, 'bob', 'hello' );
    $store->record_message( 999, 101, 'bob', 'world' );

    $store->mark_read( 999, 100 );

    is( $store->is_read( 999, 100 ), 1, 'marked message is read' );
    is( $store->is_read( 999, 101 ), 0, 'a different message in the same chat is unaffected' );
}

{
    my $store = new_store();
    $store->record_message( 999, 100, 'bob', 'hello' );

    my $telegram = Fake::ReplyTelegram->new;

    D2TG::Reply::send_reply(
        telegram             => $telegram,
        chat_id              => 999,
        text                 => 'hi',
        synthesize           => sub { my ( $fh, $p ) = File::Temp::tempfile( SUFFIX => '.ogg' ); print {$fh} 'x'; close $fh; return $p; },
        reply_to_message_id  => 100,
        store                => $store,
    );

    is( $store->is_read( 999, 100 ), 1, 'a successful reply with reply_to_message_id and store marks that message read' );
}

{
    my $store = new_store();
    $store->record_message( 999, 100, 'bob', 'hello' );

    my $telegram = Fake::ReplyTelegram->new( fail_voice => 1 );

    eval {
        D2TG::Reply::send_reply(
            telegram             => $telegram,
            chat_id              => 999,
            text                 => 'hi',
            synthesize           => sub { my ( $fh, $p ) = File::Temp::tempfile( SUFFIX => '.ogg' ); print {$fh} 'x'; close $fh; return $p; },
            reply_to_message_id  => 100,
            store                => $store,
        );
    };

    ok( $@, 'the send failed as expected' );
    is( $store->is_read( 999, 100 ), 0, 'a FAILED reply send does NOT mark the message read' );
}

{
    my $store = new_store();
    $store->record_message( 999, 100, 'bob', 'hello' );

    my $telegram = Fake::ReplyTelegram->new;

    D2TG::Reply::send_reply(
        telegram   => $telegram,
        chat_id    => 999,
        text       => 'hi',
        synthesize => sub { my ( $fh, $p ) = File::Temp::tempfile( SUFFIX => '.ogg' ); print {$fh} 'x'; close $fh; return $p; },
        store      => $store,
    );

    is( $store->is_read( 999, 100 ), 0, 'a reply with no reply_to_message_id given never marks anything read' );
}

done_testing();
