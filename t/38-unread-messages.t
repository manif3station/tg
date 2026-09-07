use strict;
use warnings;
use Test::More;
use File::Temp qw(tempfile);
use FindBin qw($Bin);
use lib "$Bin/../lib";

require D2TG::Store;

sub new_store {
    my ( undef, $db_path ) = tempfile( SUFFIX => '.sqlite', UNLINK => 1 );
    return D2TG::Store->new( db_path => $db_path, admin_chat_id => 999 );
}

{
    my $store = new_store();
    $store->record_message( 999, 100, 'bob', 'first' );
    $store->record_message( 999, 101, 'bob', 'second' );
    $store->record_message( 999, 102, 'bob', 'third' );
    $store->mark_read( 999, 101 );

    my @unread = $store->unread_messages;

    is( scalar @unread, 2, 'unread_messages returns only the unread rows' );
    my %ids = map { $_->{message_id} => 1 } @unread;
    ok( $ids{100} && $ids{102}, 'the two genuinely unread messages are both present' );
    ok( !$ids{101}, 'the read message is excluded' );
    is( $unread[0]{sender}, 'bob', 'each row carries the sender' );
    ok( defined $unread[0]{summary}, 'each row carries the summary' );
    ok( defined $unread[0]{created_at}, 'each row carries created_at' );
}

{
    my $store = new_store();

    my @unread = $store->unread_messages;

    is( scalar @unread, 0, 'no stored messages at all means an empty unread list, not a crash' );
}

{
    my $store = new_store();
    $store->record_message( 999, 200, 'bob', 'hi' );
    $store->mark_read( 999, 200 );

    my @unread = $store->unread_messages;

    is( scalar @unread, 0, 'a fully-read store returns an empty unread list' );
}

done_testing();
